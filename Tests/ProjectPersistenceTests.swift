import Testing
import Foundation
@testable import PrompterVideoMaker

@Suite struct ProjectPersistenceTests {
    private func makeTempProject() throws -> URL {
        var p = PrompterProject()
        p.script = Script(segments: [
            Segment(text: "Persisted cue one.", start: 1, end: 3),
            Segment(text: "Persisted cue two.", start: 3.5, end: 6),
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pvm-test-\(UUID().uuidString).prompterproj")
        try p.save(to: url)
        return url
    }

    @Test func saveLoadRoundTripKeepsSegments() throws {
        let url = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try PrompterProject.load(from: url)
        #expect(loaded.script.segments.map(\.text) == ["Persisted cue one.", "Persisted cue two."])
    }

    @MainActor @Test func restoreLastProjectLoadsScriptOnLaunch() throws {
        let url = try makeTempProject()
        defer {
            try? FileManager.default.removeItem(at: url)
            UserDefaults.standard.removeObject(forKey: "PVMLastProject")
        }
        UserDefaults.standard.set(url.path, forKey: "PVMLastProject")

        let state = AppState()
        #expect(state.project.script.isEmpty)
        state.restoreLastProjectIfIdle()
        #expect(state.project.script.segments.count == 2)
        #expect(state.projectFileURL == url)
    }

    @MainActor @Test func restoreDoesNotClobberLoadedScript() throws {
        let url = try makeTempProject()
        defer {
            try? FileManager.default.removeItem(at: url)
            UserDefaults.standard.removeObject(forKey: "PVMLastProject")
        }
        UserDefaults.standard.set(url.path, forKey: "PVMLastProject")

        let state = AppState()
        state.project.script = Script(segments: [Segment(text: "From a double-clicked doc", start: 0, end: 2)])
        state.restoreLastProjectIfIdle()
        #expect(state.project.script.segments.map(\.text) == ["From a double-clicked doc"])
    }
}
