import Foundation
import os.log
import Combine
import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// A file the user dropped/opened that needs a small decision (strip speaker
/// prefixes?) before it's actually imported.
struct PendingSRTImport: Identifiable {
    let id = UUID()
    let url: URL
}

enum TranscribePhase: Equatable {
    case idle
    case running(Double)
    case failed(String)
}

enum EmphasisPhase: Equatable {
    case idle
    case running(Double)
    case failed(String)
}

enum ExportPhase: Equatable {
    case idle
    case exporting(Double)
    case done(URL)
    case failed(String)
}

enum RecordPhase: Equatable {
    case idle
    case recording
    case aligning(Double)
    case done(matchRate: Double, audioURL: URL)
    case failed(String)
}

/// Words selected by clicking/dragging in the preview, for formatting.
struct WordSelection: Equatable {
    var segmentID: UUID
    var segmentIndex: Int
    /// UTF-16 range in the segment's PLAIN (marker-free) text.
    var plainRange: Range<Int>
    /// The plain text at selection time; edits elsewhere invalidate the
    /// selection instead of formatting the wrong characters.
    var plainText: String
}

private extension UTType {
    static var srtSubtitle: UTType { UTType(filenameExtension: "srt") ?? .plainText }
    static var prompterProject: UTType { UTType(filenameExtension: "prompterproj") ?? .json }
}

/// Central app state: the loaded project, playback clock, and the async
/// import/export/transcribe workflows. All UI reads and writes go through
/// this object.
@MainActor
final class AppState: ObservableObject {
    @Published var project: PrompterProject = PrompterProject(style: AppState.loadDefaultStyle())
    @Published var selectedSegmentID: UUID?
    @Published var playheadVideoTime: Double = 0
    @Published var isPlaying: Bool = false

    @Published private(set) var composition: PrompterComposition?
    /// Peak envelope of the project audio, shown as the timeline's second track.
    @Published private(set) var audioWaveform: AudioWaveform?

    @Published var pendingSRTImport: PendingSRTImport?
    @Published var transcribePhase: TranscribePhase = .idle
    @Published var exportPhase: ExportPhase = .idle
    @Published var emphasisPhase: EmphasisPhase = .idle
    @Published var errorMessage: String?

    @Published var wordSelection: WordSelection?
    @Published var recordPhase: RecordPhase = .idle
    @Published var showNewScriptSheet = false
    @Published var recordPaneVisible = false
    let recorder = AudioRecorder()

    /// Where the currently loaded project was opened from / last saved to.
    var projectFileURL: URL?

    private var playStartVideoTime: Double = 0
    private var playStartDate: Date = Date()

    private var audioPlayer: AVAudioPlayer?
    private var lastLoadedAudioPath: String?

    private var cancellables = Set<AnyCancellable>()
    private var waveformTask: Task<Void, Never>?
    private var transcribeTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var recordAlignTask: Task<Void, Never>?
    private var emphasisTask: Task<Void, Never>?

    var videoDuration: Double { composition?.videoDuration ?? 0 }

    var transcribeProgressValue: Double {
        if case .running(let p) = transcribePhase { return p }
        return 0
    }
    var exportProgressValue: Double {
        if case .exporting(let p) = exportPhase { return p }
        return 0
    }

    init() {
        $project
            .dropFirst()
            .debounce(for: .seconds(0.25), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildComposition() }
            .store(in: &cancellables)
    }

    // MARK: - Composition lifecycle

    private func rebuildComposition() {
        guard !project.script.isEmpty else {
            composition = nil
            teardownAudioPlayer()
            return
        }
        let comp = PrompterComposition(script: project.script, style: project.style)
        composition = comp
        playheadVideoTime = min(playheadVideoTime, comp.videoDuration)
        reloadAudioPlayerIfNeeded()
    }

    private func reloadAudioPlayerIfNeeded() {
        guard project.audioPath != lastLoadedAudioPath else { return }
        lastLoadedAudioPath = project.audioPath
        audioPlayer?.stop()
        audioPlayer = nil
        waveformTask?.cancel()
        audioWaveform = nil
        guard let path = project.audioPath else { return }
        let url = URL(fileURLWithPath: path)
        audioPlayer = try? AVAudioPlayer(contentsOf: url)
        audioPlayer?.prepareToPlay()
        waveformTask = Task { [weak self] in
            let wave = try? await Task.detached(priority: .utility) {
                try AudioWaveform.compute(url: url)
            }.value
            guard let self, !Task.isCancelled, self.project.audioPath == path else { return }
            self.audioWaveform = wave
        }
    }

    private func teardownAudioPlayer() {
        audioPlayer?.stop()
        audioPlayer = nil
        lastLoadedAudioPath = nil
        waveformTask?.cancel()
        audioWaveform = nil
    }

    // MARK: - Playback

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard composition != nil, videoDuration > 0 else { return }
        if playheadVideoTime >= videoDuration - 0.01 { playheadVideoTime = 0 }
        playStartVideoTime = playheadVideoTime
        playStartDate = Date()
        isPlaying = true
        wordSelection = nil
        syncAudioIfNeeded()
    }

    func pause() {
        isPlaying = false
        audioPlayer?.pause()
    }

    /// Pure read of "what time should the preview show right now" — safe to
    /// call from inside a TimelineView content closure without mutating state.
    func currentDisplayTime(at date: Date) -> Double {
        guard isPlaying else { return playheadVideoTime }
        let t = playStartVideoTime + date.timeIntervalSince(playStartDate)
        return min(max(t, 0), videoDuration)
    }

    /// Called from a `.onChange(of: context.date)` side effect (never from
    /// inside the TimelineView content closure body) so it never mutates
    /// state during a view update.
    func tick(date: Date) {
        guard isPlaying else { return }
        let dur = videoDuration
        let t = playStartVideoTime + date.timeIntervalSince(playStartDate)
        if t >= dur {
            playheadVideoTime = dur
            pause()
        } else {
            playheadVideoTime = max(0, t)
        }
        updateSelectionForPlayhead()
        syncAudioIfNeeded()
    }

    func seek(to time: Double) {
        playheadVideoTime = min(max(time, 0), videoDuration)
        if isPlaying {
            playStartVideoTime = playheadVideoTime
            playStartDate = Date()
        }
        let audioTime = playheadVideoTime - project.style.leadIn
        if audioTime >= 0 {
            audioPlayer?.currentTime = audioTime
        }
        if !isPlaying {
            audioPlayer?.pause()
        }
        updateSelectionForPlayhead()
    }

    func jumpToStart() { seek(to: 0) }
    func jumpToEnd() { seek(to: videoDuration) }

    /// Scrolls the prompter by ribbon pixels (positive = forward), driven by
    /// the scroll wheel / trackpad over the preview.
    func scrubByRibbonPixels(_ delta: CGFloat) {
        guard let comp = composition else { return }
        let current = comp.scrollOffset(atVideoTime: playheadVideoTime)
        seek(to: comp.videoTime(forScrollOffset: current + delta))
    }

    // MARK: - In-preview word selection & formatting

    /// Click/drag handler from the preview (canvas coords, top-down 1920x1080).
    /// Returns true when a word was hit (selection set or extended); false
    /// means the click landed on empty background.
    func previewClick(canvasPoint: CGPoint, extend: Bool) -> Bool {
        guard let comp = composition,
              let hit = comp.hitTestWord(canvasPoint: canvasPoint, atVideoTime: playheadVideoTime),
              hit.segmentIndex < project.script.segments.count else { return false }
        let segID = project.script.segments[hit.segmentIndex].id
        let plain = EmphasisMarkup.strip(project.script.segments[hit.segmentIndex].text)
        if extend, var sel = wordSelection, sel.segmentID == segID, sel.plainText == plain {
            sel.plainRange = min(sel.plainRange.lowerBound, hit.plainRange.lowerBound)
                ..< max(sel.plainRange.upperBound, hit.plainRange.upperBound)
            wordSelection = sel
        } else {
            wordSelection = WordSelection(
                segmentID: segID, segmentIndex: hit.segmentIndex,
                plainRange: hit.plainRange, plainText: plain)
        }
        return true
    }

    /// Canvas-space highlight boxes for the current selection at the playhead.
    var selectionHighlightRects: [CGRect] {
        guard let sel = wordSelection, let comp = composition,
              sel.segmentIndex < project.script.segments.count,
              project.script.segments[sel.segmentIndex].id == sel.segmentID,
              EmphasisMarkup.strip(project.script.segments[sel.segmentIndex].text) == sel.plainText
        else { return [] }
        return comp.highlightRects(segmentIndex: sel.segmentIndex, plainRange: sel.plainRange, atVideoTime: playheadVideoTime)
    }

    /// Toggles bold/italic/underline/accent on the selected words. The
    /// selection stays valid afterwards (plain text is unchanged), so formats
    /// can be stacked.
    func toggleFormat(_ attribute: EmphasisMarkup.Attribute) {
        guard let sel = wordSelection,
              let i = project.script.segments.firstIndex(where: { $0.id == sel.segmentID }) else { return }
        // The text may have been edited elsewhere since selection; formatting
        // a stale range would hit the wrong characters.
        guard EmphasisMarkup.strip(project.script.segments[i].text) == sel.plainText else {
            wordSelection = nil
            return
        }
        project.script.segments[i].text = EmphasisMarkup.toggle(
            attribute, in: project.script.segments[i].text, plainRange: sel.plainRange)
    }

    func clearWordSelection() { wordSelection = nil }

    // MARK: - Clamped timing edits (no overlaps possible)

    private static let minCueDuration = 0.1

    /// Spacer (empty-text) segments never constrain timing edits; clamping is
    /// against the nearest REAL neighbor, and any spacers passed over are
    /// re-anchored so segment order stays intact.
    private func isSpacer(_ s: Segment) -> Bool {
        s.text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func realPrevEnd(before i: Int) -> Double {
        project.script.segments[..<i].last(where: { !isSpacer($0) })?.end ?? 0
    }

    private func realNextStart(after i: Int) -> Double {
        project.script.segments[(i + 1)...].first(where: { !isSpacer($0) })?.start
            ?? .greatestFiniteMagnitude
    }

    /// Keeps spacers between `i` and its real neighbors inside the gaps after
    /// segment `i`'s times changed.
    private func reanchorSpacers(around i: Int) {
        let segs = project.script.segments
        let start = segs[i].start
        let end = segs[i].end
        var k = i - 1
        while k >= 0, isSpacer(segs[k]) {
            let cap = min(project.script.segments[k].start, start)
            project.script.segments[k].start = cap
            project.script.segments[k].end = min(project.script.segments[k].end, start)
            if project.script.segments[k].end < project.script.segments[k].start {
                project.script.segments[k].end = project.script.segments[k].start
            }
            k -= 1
        }
        k = i + 1
        while k < segs.count, isSpacer(segs[k]) {
            let floorT = max(project.script.segments[k].start, end)
            project.script.segments[k].start = floorT
            if project.script.segments[k].end < floorT {
                project.script.segments[k].end = floorT
            }
            k += 1
        }
    }

    func setStart(_ id: UUID, to value: Double) {
        guard let i = project.script.segments.firstIndex(where: { $0.id == id }) else { return }
        let prevEnd = realPrevEnd(before: i)
        let upper = project.script.segments[i].end - Self.minCueDuration
        project.script.segments[i].start = min(max(value, prevEnd), max(prevEnd, upper))
        reanchorSpacers(around: i)
    }

    func setEnd(_ id: UUID, to value: Double) {
        guard let i = project.script.segments.firstIndex(where: { $0.id == id }) else { return }
        let seg = project.script.segments[i]
        let nextStart = realNextStart(after: i)
        project.script.segments[i].end = max(seg.start + Self.minCueDuration, min(value, nextStart))
        reanchorSpacers(around: i)
    }

    /// Shifts a whole cue in time, clamped between its real neighbors.
    func moveSegment(_ id: UUID, by delta: Double) {
        guard let i = project.script.segments.firstIndex(where: { $0.id == id }) else { return }
        let seg = project.script.segments[i]
        let prevEnd = realPrevEnd(before: i)
        let nextStart = realNextStart(after: i)
        let hi = nextStart - seg.duration
        let newStart = min(max(seg.start + delta, prevEnd), max(prevEnd, hi))
        let d = newStart - seg.start
        project.script.segments[i].start += d
        project.script.segments[i].end += d
        reanchorSpacers(around: i)
    }

    /// Open panel for "align an audio file to the current script" — timings
    /// come from the file, the script text stays untouched.
    func presentAlignAudioPanel() {
        let panel = NSOpenPanel()
        panel.title = "Choose an Audio Recording"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.wav, .mp3, .mpeg4Audio, .aiff]
        if panel.runModal() == .OK, let url = panel.url {
            alignFromAudioFile(url: url)
        }
    }

    func selectSegment(_ id: UUID) {
        selectedSegmentID = id
        if let seg = project.script.segments.first(where: { $0.id == id }) {
            seek(to: seg.start + project.style.leadIn)
        }
    }

    func nextSegment() {
        let segs = project.script.segments
        guard !segs.isEmpty else { return }
        if let id = selectedSegmentID, let idx = segs.firstIndex(where: { $0.id == id }), idx + 1 < segs.count {
            selectSegment(segs[idx + 1].id)
        } else if let first = segs.first {
            selectSegment(first.id)
        }
    }

    func prevSegment() {
        let segs = project.script.segments
        guard !segs.isEmpty else { return }
        if let id = selectedSegmentID, let idx = segs.firstIndex(where: { $0.id == id }), idx > 0 {
            selectSegment(segs[idx - 1].id)
        } else if let first = segs.first {
            selectSegment(first.id)
        }
    }

    private func updateSelectionForPlayhead() {
        let scriptTime = playheadVideoTime - project.style.leadIn
        if let seg = project.script.segments.first(where: { scriptTime >= $0.start && scriptTime < $0.end }),
           selectedSegmentID != seg.id {
            selectedSegmentID = seg.id
        }
    }

    private func syncAudioIfNeeded() {
        guard let player = audioPlayer else { return }
        guard isPlaying, project.style.includeAudio else {
            if player.isPlaying { player.pause() }
            return
        }
        let target = playheadVideoTime - project.style.leadIn
        guard target >= 0 else {
            if player.isPlaying { player.pause() }
            return
        }
        if !player.isPlaying {
            player.currentTime = target
            player.play()
        } else if abs(player.currentTime - target) > 0.15 {
            player.currentTime = target
        }
    }

    // MARK: - Style defaults

    private static let defaultStyleKey = "PVMDefaultStyle"

    /// The user's saved default style, or the factory style if none saved
    /// (or if a saved one no longer decodes after an app update).
    static func loadDefaultStyle() -> StyleSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultStyleKey),
              let style = try? JSONDecoder().decode(StyleSettings.self, from: data) else {
            return StyleSettings()
        }
        return style
    }

    /// Persists the current style; new documents and future launches start
    /// from it.
    func saveCurrentStyleAsDefault() {
        if let data = try? JSONEncoder().encode(project.style) {
            UserDefaults.standard.set(data, forKey: Self.defaultStyleKey)
        }
    }

    func resetStyleToFactory() {
        UserDefaults.standard.removeObject(forKey: Self.defaultStyleKey)
        project.style = StyleSettings()
    }

    // MARK: - Global timing offset

    var globalOffset: Double { project.globalOffset ?? 0 }

    func applyGlobalOffset(_ delta: Double) {
        project.script.offsetAll(by: delta)
        project.globalOffset = (project.globalOffset ?? 0) + delta
    }

    // MARK: - Segment editing

    /// Inserts a blank spacer segment (renders as one empty line) after the
    /// given segment. Zero-length in time so scroll timing is unaffected.
    func insertEmptyLine(after id: UUID) {
        guard let i = project.script.segments.firstIndex(where: { $0.id == id }) else { return }
        let prev = project.script.segments[i]
        let blank = Segment(text: "", start: prev.end, end: prev.end)
        project.script.segments.insert(blank, at: i + 1)
        project.script.normalize()
    }

    func splitInHalf(_ id: UUID) {
        guard let seg = project.script.segments.first(where: { $0.id == id }) else { return }
        project.script.split(segmentID: id, atTextIndex: seg.text.count / 2)
        invalidateStaleWordSelection()
    }

    func mergeWithNext(_ id: UUID) {
        project.script.mergeWithNext(segmentID: id)
        invalidateStaleWordSelection()
    }

    func deleteSegment(_ id: UUID) {
        project.script.segments.removeAll { $0.id == id }
        project.script.normalize()
        if selectedSegmentID == id { selectedSegmentID = nil }
        invalidateStaleWordSelection()
    }

    /// Drops the preview word selection when its segment vanished or its text
    /// no longer matches the selection snapshot.
    private func invalidateStaleWordSelection() {
        guard let sel = wordSelection else { return }
        guard let seg = project.script.segments.first(where: { $0.id == sel.segmentID }),
              EmphasisMarkup.strip(seg.text) == sel.plainText else {
            wordSelection = nil
            return
        }
    }

    func nudgeStart(_ id: UUID, by delta: Double) {
        guard let seg = project.script.segments.first(where: { $0.id == id }) else { return }
        setStart(id, to: seg.start + delta)
    }

    func nudgeEnd(_ id: UUID, by delta: Double) {
        guard let seg = project.script.segments.first(where: { $0.id == id }) else { return }
        setEnd(id, to: seg.end + delta)
    }

    // MARK: - Import routing

    /// Presents a combined Open panel for SRT / audio / project files.
    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Script, Audio, or Project"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            .srtSubtitle, .prompterProject, .wav, .mp3, .mpeg4Audio, .aiff
        ]
        if panel.runModal() == .OK, let url = panel.url {
            importURL(url)
        }
    }

    /// Handles a drag-and-drop of files onto the window.
    func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
            var url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let u = item as? URL {
                url = u
            }
            guard let url else { return }
            Task { @MainActor in self?.importURL(url) }
        }
        return true
    }

    func importURL(_ url: URL) {
        Logger(subsystem: "com.marcotempest.PrompterVideoMaker", category: "open")
            .notice("importURL: \(url.path, privacy: .public)")
        // A file import replacing the script mid-take would make the later
        // alignment map the spoken words onto unrelated text.
        guard !recordPaneVisible else {
            errorMessage = "Finish or cancel Record Timing before importing files."
            return
        }
        switch url.pathExtension.lowercased() {
        case "srt":
            pendingSRTImport = PendingSRTImport(url: url)
        case "wav", "mp3", "m4a", "aif", "aiff":
            startTranscription(audioURL: url)
        case "prompterproj":
            openProject(url: url)
        default:
            errorMessage = "Unsupported file type: \(url.lastPathComponent)"
        }
    }

    private func loadText(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        throw CocoaError(.fileReadCorruptFile)
    }

    func finishSRTImport(_ pending: PendingSRTImport, stripPrefixes: Bool) {
        do {
            let text = try loadText(from: pending.url)
            let segments = try SRTParser.parse(text, stripSpeakerPrefixes: stripPrefixes)
            var script = Script(segments: segments)
            script.normalize()
            project.script = script
            project.globalOffset = nil
            selectedSegmentID = script.segments.first?.id
            pause()
            playheadVideoTime = 0
        } catch {
            errorMessage = "Could not parse \"\(pending.url.lastPathComponent)\": \(error.localizedDescription)"
        }
        pendingSRTImport = nil
    }

    /// Resets to a fresh, empty project (keeping the user's saved default
    /// style), confirming first when a script is loaded.
    func newProject() {
        if !project.script.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Start a New Project?"
            alert.informativeText = "The current script and settings will be replaced. Save the project first if you want to keep them."
            alert.addButton(withTitle: "New Project")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        pause()
        cancelRecording()
        cancelTranscription()
        cancelEmphasis()
        recordPaneVisible = false
        project = PrompterProject(style: AppState.loadDefaultStyle())
        projectFileURL = nil
        UserDefaults.standard.removeObject(forKey: Self.lastProjectKey)
        selectedSegmentID = nil
        playheadVideoTime = 0
        wordSelection = nil
    }

    func openProject(url: URL) {
        do {
            let proj = try PrompterProject.load(from: url)
            project = proj
            rememberProjectURL(url)
            selectedSegmentID = proj.script.segments.first?.id
            playheadVideoTime = 0
            isPlaying = false
        } catch {
            errorMessage = "Could not open project: \(error.localizedDescription)"
        }
    }

    // MARK: - Last-project persistence

    private static let lastProjectKey = "PVMLastProject"

    private func rememberProjectURL(_ url: URL) {
        projectFileURL = url
        UserDefaults.standard.set(url.path, forKey: Self.lastProjectKey)
    }

    /// Called shortly after launch: if no document was opened (via Finder or
    /// otherwise) and nothing is loaded yet, reopen the last saved project.
    func restoreLastProjectIfIdle() {
        guard project.script.isEmpty, pendingSRTImport == nil, transcribePhase == .idle else { return }
        guard let path = UserDefaults.standard.string(forKey: Self.lastProjectKey),
              FileManager.default.fileExists(atPath: path) else { return }
        openProject(url: URL(fileURLWithPath: path))
    }

    func startTranscription(audioURL: URL) {
        transcribeTask?.cancel()
        transcribePhase = .running(0)
        transcribeTask = Task {
            do {
                let segments = try await Transcriber.transcribe(audioURL: audioURL) { [weak self] p in
                    Task { @MainActor in
                        if case .running = self?.transcribePhase {
                            self?.transcribePhase = .running(p)
                        }
                    }
                }
                try Task.checkCancellation()
                var script = Script(segments: segments)
                script.normalize()
                project.script = script
                project.audioPath = audioURL.path
                project.globalOffset = nil
                selectedSegmentID = script.segments.first?.id
                pause()
                playheadVideoTime = 0
                transcribePhase = .idle
            } catch is CancellationError {
                transcribePhase = .idle
            } catch {
                transcribePhase = .failed(error.localizedDescription)
            }
        }
    }

    func cancelTranscription() {
        transcribeTask?.cancel()
        transcribeTask = nil
        transcribePhase = .idle
    }

    // MARK: - Emphasis suggestions

    func suggestEmphasis(model: String) {
        guard !project.script.isEmpty, emphasisPhase == .idle else { return }
        emphasisPhase = .running(0)
        let snapshot = project.script.segments
        emphasisTask = Task {
            do {
                let suggested = try await EmphasisSuggester.suggest(segments: snapshot, model: model) { [weak self] p in
                    Task { @MainActor in
                        if case .running = self?.emphasisPhase {
                            self?.emphasisPhase = .running(p)
                        }
                    }
                }
                try Task.checkCancellation()
                // The request can take a while; merge per segment id and only
                // where the text is unchanged since the snapshot, so edits,
                // clears, or a re-recorded script made meanwhile are never
                // clobbered by the stale result.
                var suggestion: [UUID: (original: String, suggested: String)] = [:]
                for (o, s) in zip(snapshot, suggested) {
                    suggestion[o.id] = (o.text, s.text)
                }
                for i in project.script.segments.indices {
                    let seg = project.script.segments[i]
                    if let (original, new) = suggestion[seg.id], seg.text == original {
                        project.script.segments[i].text = new
                    }
                }
                emphasisPhase = .idle
            } catch is CancellationError {
                // cancelEmphasis already reset the phase.
            } catch {
                // A cancelled/stale task must never overwrite a newer state.
                if !Task.isCancelled {
                    emphasisPhase = .failed(error.localizedDescription)
                }
            }
        }
    }

    func cancelEmphasis() {
        emphasisTask?.cancel()
        emphasisTask = nil
        emphasisPhase = .idle
    }

    func clearEmphasis() {
        // An explicit clear also aborts any in-flight suggestion, which would
        // otherwise re-apply markup when it completes.
        cancelEmphasis()
        project.script.segments = EmphasisSuggester.clear(segments: project.script.segments)
    }

    // MARK: - Write-in-app / record-and-align

    /// Builds a script directly from pasted text (see `NewScriptSheet`),
    /// estimating timings the same way SRT-less scripts always have.
    func createScript(fromText text: String, granularity: ScriptGranularity) {
        let script = ScriptImporter.script(fromPastedText: text, granularity: granularity)
        project.script = script
        project.audioPath = nil
        project.globalOffset = nil
        selectedSegmentID = script.segments.first?.id
        pause()
        playheadVideoTime = 0
        showNewScriptSheet = false
    }

    func startRecording() {
        do {
            try recorder.start()
            recordPhase = .recording
        } catch {
            recordPhase = .failed(error.localizedDescription)
        }
    }

    /// Stops the recorder, then transcribes the take and aligns it against
    /// the known script text to derive real per-segment timings.
    /// Opens the record pane, stopping any running preview playback first so
    /// audio/clock don't keep running headless behind the pane.
    func openRecordPane() {
        pause()
        recordPhase = .idle
        recordPaneVisible = true
    }

    /// The recorded take between recorder.stop() and successful alignment;
    /// deleted if the user cancels in that window. Never set for user-chosen
    /// audio files, which must never be deleted.
    private var pendingTakeURL: URL?

    func stopRecordingAndAlign() {
        guard let url = recorder.stop() else {
            recordPhase = .failed("No recording was captured.")
            return
        }
        pendingTakeURL = url
        recordAlignTask?.cancel()
        recordPhase = .aligning(0)
        recordAlignTask = Task {
            do {
                let words = try await Transcriber.timedWords(audioURL: url) { [weak self] p in
                    Task { @MainActor in
                        if case .aligning = self?.recordPhase {
                            self?.recordPhase = .aligning(p)
                        }
                    }
                }
                try Task.checkCancellation()
                let result = Aligner.align(script: project.script, words: words)
                project.script.segments = result.segments
                project.audioPath = url.path
                project.globalOffset = nil
                pause()
                playheadVideoTime = 0
                pendingTakeURL = nil // file now owned by project.audioPath
                recordPhase = .done(matchRate: result.matchRate, audioURL: url)
            } catch is CancellationError {
                recordPhase = .idle
            } catch {
                recordPhase = .failed(error.localizedDescription)
            }
        }
    }

    /// Cancels an in-flight recording/alignment and discards the partial
    /// take. Also used as the plain "Cancel" handler before recording starts.
    func cancelRecording() {
        recordAlignTask?.cancel()
        recordAlignTask = nil
        if recorder.isRecording, let url = recorder.stop() {
            try? FileManager.default.removeItem(at: url)
        } else if let url = pendingTakeURL {
            // Cancelled between stop() and alignment finishing.
            try? FileManager.default.removeItem(at: url)
        }
        pendingTakeURL = nil
        recordPhase = .idle
        recordPaneVisible = false
    }

    /// Closes the recording pane. While a recording/alignment is in flight
    /// this cancels it first (mirroring the old sheet's dismiss binding);
    /// otherwise it just resets the phase and hides the pane so the next
    /// visit starts clean.
    func closeRecordPane() {
        switch recordPhase {
        case .recording, .aligning:
            cancelRecording()
        default:
            recordPhase = .idle
            recordPaneVisible = false
        }
    }

    /// Same alignment tail as `stopRecordingAndAlign`, but starting from an
    /// existing audio file instead of a live recorder take. The script text
    /// is left completely untouched — only per-segment timings (and the
    /// attached audio) come from the file, since the Aligner preserves
    /// segment ids/texts and only rewrites `start`/`end`.
    func alignFromAudioFile(url: URL) {
        recordAlignTask?.cancel()
        recordPhase = .aligning(0)
        recordAlignTask = Task {
            do {
                let words = try await Transcriber.timedWords(audioURL: url) { [weak self] p in
                    Task { @MainActor in
                        if case .aligning = self?.recordPhase {
                            self?.recordPhase = .aligning(p)
                        }
                    }
                }
                try Task.checkCancellation()
                let result = Aligner.align(script: project.script, words: words)
                project.script.segments = result.segments
                project.audioPath = url.path
                project.globalOffset = nil
                pause()
                playheadVideoTime = 0
                recordPhase = .done(matchRate: result.matchRate, audioURL: url)
            } catch is CancellationError {
                recordPhase = .idle
            } catch {
                recordPhase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Save project

    func saveProject() {
        if let url = projectFileURL {
            do {
                try project.save(to: url)
                rememberProjectURL(url)
            } catch {
                errorMessage = "Could not save project: \(error.localizedDescription)"
            }
        } else {
            presentSaveProjectPanel()
        }
    }

    func presentSaveProjectPanel() {
        let panel = NSSavePanel()
        panel.title = "Save Project"
        panel.allowedContentTypes = [.prompterProject]
        panel.nameFieldStringValue = (projectFileURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + ".prompterproj"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try project.save(to: url)
                rememberProjectURL(url)
            } catch {
                errorMessage = "Could not save project: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Export

    func presentExportPanel() {
        guard composition != nil else {
            errorMessage = "Load a script before exporting."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Video"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = (projectFileURL?.deletingPathExtension().lastPathComponent ?? "Prompter") + ".mp4"
        if panel.runModal() == .OK, let url = panel.url {
            startExport(to: url)
        }
    }

    func startExport(to url: URL) {
        guard let comp = composition else { return }
        exportTask?.cancel()
        exportPhase = .exporting(0)
        let audioURL: URL? = (project.style.includeAudio ? project.audioPath.map { URL(fileURLWithPath: $0) } : nil)
        let titleCard = TitleCardInfo(
            projectName: projectFileURL?.deletingPathExtension().lastPathComponent ?? "Untitled",
            exportDate: Date(),
            videoDuration: comp.videoDuration
        )
        let exporter = VideoExporter(composition: comp, audioURL: audioURL, outputURL: url, titleCard: titleCard)
        exportTask = Task {
            do {
                try await exporter.export { [weak self] p in
                    Task { @MainActor in
                        if case .exporting = self?.exportPhase {
                            self?.exportPhase = .exporting(p)
                        }
                    }
                }
                try Task.checkCancellation()
                exportPhase = .done(url)
            } catch is CancellationError {
                exportPhase = .idle
            } catch {
                exportPhase = .failed(error.localizedDescription)
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
        exportTask = nil
        exportPhase = .idle
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
