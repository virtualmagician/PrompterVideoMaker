import Foundation
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

    @Published var pendingSRTImport: PendingSRTImport?
    @Published var transcribePhase: TranscribePhase = .idle
    @Published var exportPhase: ExportPhase = .idle
    @Published var emphasisPhase: EmphasisPhase = .idle
    @Published var errorMessage: String?

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
        guard let path = project.audioPath else { return }
        let url = URL(fileURLWithPath: path)
        audioPlayer = try? AVAudioPlayer(contentsOf: url)
        audioPlayer?.prepareToPlay()
    }

    private func teardownAudioPlayer() {
        audioPlayer?.stop()
        audioPlayer = nil
        lastLoadedAudioPath = nil
    }

    // MARK: - Playback

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard composition != nil, videoDuration > 0 else { return }
        if playheadVideoTime >= videoDuration - 0.01 { playheadVideoTime = 0 }
        playStartVideoTime = playheadVideoTime
        playStartDate = Date()
        isPlaying = true
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
    }

    func mergeWithNext(_ id: UUID) {
        project.script.mergeWithNext(segmentID: id)
    }

    func deleteSegment(_ id: UUID) {
        project.script.segments.removeAll { $0.id == id }
        project.script.normalize()
        if selectedSegmentID == id { selectedSegmentID = nil }
    }

    func nudgeStart(_ id: UUID, by delta: Double) {
        guard let i = project.script.segments.firstIndex(where: { $0.id == id }) else { return }
        project.script.segments[i].start = max(0, project.script.segments[i].start + delta)
        project.script.normalize()
    }

    func nudgeEnd(_ id: UUID, by delta: Double) {
        guard let i = project.script.segments.firstIndex(where: { $0.id == id }) else { return }
        let seg = project.script.segments[i]
        project.script.segments[i].end = max(seg.start, seg.end + delta)
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

    func openProject(url: URL) {
        do {
            let proj = try PrompterProject.load(from: url)
            project = proj
            projectFileURL = url
            selectedSegmentID = proj.script.segments.first?.id
            playheadVideoTime = 0
            isPlaying = false
        } catch {
            errorMessage = "Could not open project: \(error.localizedDescription)"
        }
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
    func stopRecordingAndAlign() {
        guard let url = recorder.stop() else {
            recordPhase = .failed("No recording was captured.")
            return
        }
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

    /// Cancels an in-flight recording/alignment and discards the partial
    /// take. Also used as the plain "Cancel" handler before recording starts.
    func cancelRecording() {
        recordAlignTask?.cancel()
        recordAlignTask = nil
        if recorder.isRecording, let url = recorder.stop() {
            try? FileManager.default.removeItem(at: url)
        }
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
            do { try project.save(to: url) } catch {
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
                projectFileURL = url
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
        let exporter = VideoExporter(composition: comp, audioURL: audioURL, outputURL: url)
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
