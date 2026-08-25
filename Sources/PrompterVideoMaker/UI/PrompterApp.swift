import SwiftUI

// NOTE: intentionally NOT annotated `@main` — `main.swift` calls
// `PrompterApp.main()` explicitly (after checking for headless CLI mode),
// relying on the default `App.main()` implementation SwiftUI provides.
struct PrompterApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 1280, minHeight: 800)
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
