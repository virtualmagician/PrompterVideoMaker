import SwiftUI
import UniformTypeIdentifiers

/// Root layout: SegmentListView | PreviewView+TransportBar | InspectorView,
/// plus the app's sheets (SRT import options, transcribe/export progress)
/// and window-wide drag & drop.
struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HSplitView {
            SegmentListView()
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)

            VStack(spacing: 0) {
                if appState.recordPaneVisible {
                    RecordingPane(recorder: appState.recorder)
                } else {
                    PreviewView()
                    Divider()
                    TransportBar()
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)

            InspectorView()
                .frame(minWidth: 300, idealWidth: 320, maxWidth: 340)
        }
        .toolbar {
            // Labeled buttons ordered by workflow: write/import a script,
            // record its timing, save, export the video.
            ToolbarItemGroup {
                Button {
                    appState.showNewScriptSheet = true
                } label: {
                    Label("New Script", systemImage: "square.and.pencil")
                        .labelStyle(.titleAndIcon)
                }
                .help("Write or paste a new script (⌘N)")

                Button {
                    appState.presentOpenPanel()
                } label: {
                    Label("Open", systemImage: "folder")
                        .labelStyle(.titleAndIcon)
                }
                .help("Open an SRT, audio file, or project (⌘O)")

                Button {
                    appState.openRecordPane()
                } label: {
                    Label("Record Timing", systemImage: "record.circle")
                        .labelStyle(.titleAndIcon)
                }
                .help("Read the script aloud (or pick an audio file) to set the timings")
                .disabled(appState.project.script.isEmpty)

                Button {
                    appState.saveProject()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                        .labelStyle(.titleAndIcon)
                }
                .help("Save Project (⌘S)")
                .disabled(appState.project.script.isEmpty)

                Button {
                    appState.presentExportPanel()
                } label: {
                    Label("Export Video", systemImage: "square.and.arrow.up.on.square")
                        .labelStyle(.titleAndIcon)
                }
                .help("Export the teleprompter video (⌘E)")
                .disabled(appState.composition == nil)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            appState.handleDrop(providers: providers)
        }
        .sheet(item: $appState.pendingSRTImport) { pending in
            SRTImportOptionsSheet(pending: pending)
        }
        .sheet(isPresented: transcribingBinding) {
            TranscribeProgressSheet()
        }
        .sheet(isPresented: exportingBinding) {
            ExportProgressSheet()
        }
        .sheet(isPresented: $appState.showNewScriptSheet) {
            NewScriptSheet()
        }
        .alert("Something Went Wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { appState.errorMessage != nil }, set: { if !$0 { appState.errorMessage = nil } })
    }
    private var transcribingBinding: Binding<Bool> {
        Binding(get: { appState.transcribePhase != .idle }, set: { if !$0 { appState.cancelTranscription() } })
    }
    private var exportingBinding: Binding<Bool> {
        Binding(get: { appState.exportPhase != .idle }, set: { if !$0 { appState.cancelExport() } })
    }
}

// MARK: - SRT import options ("strip speaker prefixes?")

private struct SRTImportOptionsSheet: View {
    @EnvironmentObject private var appState: AppState
    let pending: PendingSRTImport
    @State private var stripPrefixes = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Import Subtitles", systemImage: "captions.bubble")
                .font(.headline)
            Text(pending.url.lastPathComponent)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Toggle("Strip speaker name prefixes (e.g. \u{201C}Speaker 1:\u{201D})", isOn: $stripPrefixes)

            HStack {
                Spacer()
                Button {
                    appState.pendingSRTImport = nil
                } label: {
                    Text("Cancel")
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    appState.finishSRTImport(pending, stripPrefixes: stripPrefixes)
                } label: {
                    Text("Import")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

// MARK: - Transcribe progress

private struct TranscribeProgressSheet: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            switch appState.transcribePhase {
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                Text("Transcription Failed")
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Dismiss") { appState.transcribePhase = .idle }
            default:
                ProgressView(value: appState.transcribeProgressValue)
                    .frame(width: 220)
                Text("Transcribing Audio…")
                    .font(.headline)
                Text("\(Int(appState.transcribeProgressValue * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel") { appState.cancelTranscription() }
            }
        }
        .padding(28)
        .frame(width: 300)
    }
}

// MARK: - Export progress

private struct ExportProgressSheet: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            switch appState.exportPhase {
            case .done(let url):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.green)
                Text("Export Complete")
                    .font(.headline)
                Text(url.lastPathComponent)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack {
                    Button("Reveal in Finder") { appState.revealInFinder(url) }
                    Button("Done") { appState.exportPhase = .idle }
                        .keyboardShortcut(.defaultAction)
                }
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                Text("Export Failed")
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Dismiss") { appState.exportPhase = .idle }
            default:
                ProgressView(value: appState.exportProgressValue)
                    .frame(width: 220)
                Text("Exporting Video…")
                    .font(.headline)
                Text("\(Int(appState.exportProgressValue * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel") { appState.cancelExport() }
            }
        }
        .padding(28)
        .frame(width: 320)
    }
}
