import AppKit

// Headless CLI mode (used for scripted exports and self-testing);
// otherwise launch the SwiftUI app.
if HeadlessRunner.runIfRequested() {
    exit(0)
}
PrompterApp.main()
