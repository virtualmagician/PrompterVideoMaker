import Foundation

/// One timed cue of the script.
struct Segment: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var text: String
    /// Seconds from the start of the source audio / SRT timeline.
    var start: TimeInterval
    var end: TimeInterval

    init(id: UUID = UUID(), text: String, start: TimeInterval, end: TimeInterval) {
        self.id = id
        self.text = text
        self.start = start
        self.end = max(end, start)
    }

    var duration: TimeInterval { end - start }
}

/// The full timed script.
struct Script: Codable, Equatable {
    var segments: [Segment]

    init(segments: [Segment] = []) {
        self.segments = segments
    }

    var isEmpty: Bool { segments.isEmpty }
    var firstStart: TimeInterval { segments.first?.start ?? 0 }
    var lastEnd: TimeInterval { segments.last?.end ?? 0 }

    /// Keep segments ordered and non-overlapping in time.
    mutating func normalize() {
        segments.sort { $0.start < $1.start }
        for i in segments.indices {
            segments[i].end = max(segments[i].end, segments[i].start)
            if i + 1 < segments.count {
                // Guarantee strictly increasing starts for the scroll curve.
                if segments[i + 1].start <= segments[i].start {
                    segments[i + 1].start = segments[i].start + 0.001
                }
            }
        }
    }

    mutating func offsetAll(by delta: TimeInterval) {
        for i in segments.indices {
            segments[i].start = max(0, segments[i].start + delta)
            segments[i].end = max(0, segments[i].end + delta)
        }
        normalize()
    }

    /// Split the segment at the given text index; timing is divided
    /// proportionally to character counts.
    mutating func split(segmentID: UUID, atTextIndex index: Int) {
        guard let i = segments.firstIndex(where: { $0.id == segmentID }) else { return }
        let seg = segments[i]
        let text = seg.text
        guard index > 0, index < text.count else { return }
        let splitIdx = text.index(text.startIndex, offsetBy: index)
        let a = String(text[..<splitIdx]).trimmingCharacters(in: .whitespaces)
        let b = String(text[splitIdx...]).trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty, !b.isEmpty else { return }
        let frac = Double(a.count) / Double(text.count)
        let mid = seg.start + seg.duration * frac
        segments[i] = Segment(id: seg.id, text: a, start: seg.start, end: mid)
        segments.insert(Segment(text: b, start: mid, end: seg.end), at: i + 1)
    }

    /// Merge the segment with the one following it.
    mutating func mergeWithNext(segmentID: UUID) {
        guard let i = segments.firstIndex(where: { $0.id == segmentID }), i + 1 < segments.count else { return }
        let a = segments[i], b = segments[i + 1]
        segments[i] = Segment(id: a.id, text: a.text + " " + b.text, start: a.start, end: max(a.end, b.end))
        segments.remove(at: i + 1)
    }
}

/// A saved project document (JSON).
struct PrompterProject: Codable, Equatable {
    var script: Script
    var style: StyleSettings
    var audioPath: String?

    init(script: Script = Script(), style: StyleSettings = StyleSettings(), audioPath: String? = nil) {
        self.script = script
        self.style = style
        self.audioPath = audioPath
    }

    static func load(from url: URL) throws -> PrompterProject {
        let data = try Data(contentsOf: url)
        var proj = try JSONDecoder().decode(PrompterProject.self, from: data)
        // Decodable bypasses Segment's initializer; restore timing invariants.
        proj.script.normalize()
        return proj
    }

    func save(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url)
    }
}
