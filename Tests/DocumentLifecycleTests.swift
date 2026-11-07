import Testing
import Foundation
@testable import PrompterVideoMaker

@MainActor @Suite struct DocumentLifecycleTests {
    private func tempURL(_ ext: String = "prompterproj") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pvm-doc-\(UUID().uuidString).\(ext)")
    }

    private func edit(_ state: AppState) {
        state.project.script = Script(segments: [
            Segment(text: "Cue one.", start: 0, end: 2),
            Segment(text: "Cue two.", start: 2, end: 4),
        ])
    }

    @Test func freshStateIsCleanAndUntitled() {
        let s = AppState()
        #expect(!s.isDirty)
        #expect(s.documentTitle == "Untitled")
    }

    @Test func editThenWriteMarksClean() throws {
        let s = AppState()
        edit(s)
        #expect(s.isDirty)
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(s.writeProject(to: url))
        #expect(!s.isDirty)
        #expect(s.projectFileURL == url)
        #expect(s.documentTitle == url.deletingPathExtension().lastPathComponent)
        let loaded = try PrompterProject.load(from: url)
        #expect(loaded.script.segments.map(\.text) == ["Cue one.", "Cue two."])
        UserDefaults.standard.removeObject(forKey: "PVMLastProject")
    }

    @Test func importPathsResetDocumentIdentity() throws {
        let src = AppState()
        edit(src)
        let url = tempURL()
        let srt = tempURL("srt")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: srt)
            UserDefaults.standard.removeObject(forKey: "PVMLastProject")
        }
        src.writeProject(to: url)

        let s = AppState()
        s.openProject(url: url)
        #expect(s.projectFileURL == url)
        #expect(!s.isDirty)
        s.createScript(fromText: "Hello there. Another line.", granularity: .sentences)
        #expect(s.projectFileURL == nil)
        #expect(s.isDirty)

        try "1\n00:00:00,000 --> 00:00:02,000\nHello SRT\n".write(to: srt, atomically: true, encoding: .utf8)
        let s2 = AppState()
        s2.openProject(url: url)
        s2.finishSRTImport(PendingSRTImport(url: srt), stripPrefixes: false)
        #expect(s2.projectFileURL == nil)
        #expect(s2.isDirty)
    }

    @Test func newProjectWhenCleanDoesNotPrompt() {
        let s = AppState()
        var calls = 0
        s.confirmDiscard = { _ in calls += 1; return .cancel }
        s.newProject()
        #expect(calls == 0)
        #expect(s.project.script.isEmpty)
        #expect(s.projectFileURL == nil)
        #expect(!s.isDirty)
    }

    @Test func newProjectWhenDirtyHonoursDecision() {
        let s = AppState()
        edit(s)
        s.confirmDiscard = { _ in .cancel }
        s.newProject()
        #expect(!s.project.script.isEmpty)
        s.confirmDiscard = { _ in .discard }
        s.newProject()
        #expect(s.project.script.isEmpty)
        #expect(!s.isDirty)
    }

    @Test func saveWithMissingFileFallsToSaveAs() {
        let s = AppState()
        edit(s)
        let gone = tempURL()
        s.projectFileURL = gone   // never written: file does not exist
        let target = tempURL()
        defer {
            try? FileManager.default.removeItem(at: target)
            UserDefaults.standard.removeObject(forKey: "PVMLastProject")
        }
        var asked = 0
        s.saveAsPresenter = { asked += 1; return target }
        #expect(s.saveProject())
        #expect(asked == 1)
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(!FileManager.default.fileExists(atPath: gone.path))
        #expect(s.projectFileURL == target)
        #expect(!s.isDirty)
    }

    @Test func saveAsCancelledReturnsFalse() {
        let s = AppState()
        edit(s)
        s.saveAsPresenter = { nil }
        #expect(!s.saveProject())
        #expect(s.isDirty)
    }
}
