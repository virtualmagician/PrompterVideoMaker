import SwiftUI
import AppKit
import os.log

/// Receives Finder "open document" events (double-clicked .prompterproj/.srt/
/// audio files), buffering any that arrive before the UI has attached.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var handler: (([URL]) -> Void)?
    private var pendingURLs: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        Logger(subsystem: "com.marcotempest.PrompterVideoMaker", category: "open")
            .notice("Finder open: \(urls.map(\.path).joined(separator: ", "), privacy: .public)")
        if let handler {
            handler(urls)
        } else {
            pendingURLs.append(contentsOf: urls)
        }
    }

    func attach(_ handler: @escaping ([URL]) -> Void) {
        self.handler = handler
        if !pendingURLs.isEmpty {
            handler(pendingURLs)
            pendingURLs = []
        }
    }
}

// NOTE: intentionally NOT annotated `@main` — `main.swift` calls
// `PrompterApp.main()` explicitly (after checking for headless CLI mode),
// relying on the default `App.main()` implementation SwiftUI provides.
struct PrompterApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 1280, minHeight: 800)
                .onOpenURL { url in
                    Logger(subsystem: "com.marcotempest.PrompterVideoMaker", category: "open")
                        .notice("onOpenURL: \(url.path, privacy: .public)")
                    appState.importURL(url)
                }
                .onAppear {
                    let state = appState
                    appDelegate.attach { urls in
                        Task { @MainActor in
                            urls.forEach { state.importURL($0) }
                        }
                    }
                    // Plain launch (no document): reopen the last project.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        state.restoreLastProjectIfIdle()
                    }
                }
        }
        .commands {
            // Replaces the default "New Window" item (also Cmd+N) with our
            // own "New Script…" so the shortcut isn't claimed twice.
            CommandGroup(replacing: .newItem) {
                Button("New Script…") {
                    appState.showNewScriptSheet = true
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("Open…") {
                    appState.presentOpenPanel()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Align Audio to Script…") {
                    appState.openRecordPane()
                    appState.presentAlignAudioPanel()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(appState.project.script.isEmpty)

                Divider()

                Button("Save Project") {
                    appState.saveProject()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(appState.project.script.isEmpty)

                Divider()

                Button("Export Video…") {
                    appState.presentExportPanel()
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(appState.composition == nil)
            }
        }
    }
}
