import Testing
import Foundation
@testable import PrompterVideoMaker

/// Per-line scroll anchoring from word timings.
@Suite struct LineAnchorTests {

    // MARK: - Helpers

    private static let longText =
        "Magic is the art of making people believe that something impossible has just happened "
        + "right in front of their eyes, and every great performer knows that timing decides "
        + "whether the audience gasps or shrugs when the final reveal arrives."

    /// Whitespace-delimited words of `plain` with UTF-16 ranges.
    private func words(of plain: String) -> [(word: String, loc: Int, len: Int)] {
        let ns = plain as NSString
        var out: [(String, Int, Int)] = []
        var i = 0
        while i < ns.length {
            while i < ns.length, ns.substring(with: NSRange(location: i, length: 1)) == " " { i += 1 }
            let start = i
            while i < ns.length, ns.substring(with: NSRange(location: i, length: 1)) != " " { i += 1 }
            if i > start {
                out.append((ns.substring(with: NSRange(location: start, length: i - start)), start, i - start))
            }
        }
        return out
    }

    /// Word timings for a single-segment script where the FIRST word of
    /// wrapped line k starts at `lineStarts[k]`; words inside a line are
    /// spread evenly up to the next line's start (or `tail` for the last).
    private func timings(for segment: Segment, style: StyleSettings, lineStarts: [Double], tail: Double) -> [WordTiming] {
        let layout = RibbonLayout(script: Script(segments: [segment]), style: style)
        let plain = layout.segmentPlainTexts[0]
        let lines = layout.lines.filter { $0.segmentIndex == 0 && $0.range.length > 0 }
        let ws = words(of: plain)
        var out: [WordTiming] = []
        for (k, line) in lines.enumerated() {
            let inLine = ws.filter { $0.loc >= line.range.location && $0.loc < line.range.location + line.range.length }
            let t0 = lineStarts[k]
            let t1 = k + 1 < lines.count ? lineStarts[k + 1] : tail
            for (n, w) in inLine.enumerated() {
                let a = t0 + (t1 - t0) * Double(n) / Double(inLine.count)
                let b = t0 + (t1 - t0) * Double(n + 1) / Double(inLine.count)
                out.append(WordTiming(word: w.word, location: w.loc, length: w.len, start: a, end: b))
            }
        }
        return out
    }

    private func recognized(_ list: [(String, Double, Double)]) -> [Transcriber.TimedWord] {
        list.map { .init(text: $0.0, start: $0.1, end: $0.2) }
    }

    // MARK: - (a) Aligner emits word timings

    @Test func alignerEmitsWordTimingsWithPlainRanges() {
        let script = Script(segments: [
            Segment(text: "**Hello** there friend", start: 0, end: 1),
        ])
        let rec = recognized([("Hello", 1.0, 1.4), ("there", 1.5, 1.9), ("friend", 2.0, 2.6)])
        let r = Aligner.align(script: script, words: rec)
        let t = r.segments[0].wordTimings
        #expect(t != nil)
        #expect(t?.map(\.word) == ["Hello", "there", "friend"])
        #expect(t?.map(\.location) == [0, 6, 12])
        #expect(t?.map(\.length) == [5, 5, 6])
        #expect(t?.map(\.start) == [1.0, 1.5, 2.0])
        #expect(t?.map(\.end) == [1.4, 1.9, 2.6])
        // The ranges address the PLAIN text exactly.
        let plain = EmphasisMarkup.strip(r.segments[0].text) as NSString
        for w in t ?? [] {
            #expect(plain.substring(with: NSRange(location: w.location, length: w.length)) == w.word)
        }
    }

    @Test func alignerLeavesInterpolatedSegmentsWithoutTimings() {
        let script = Script(segments: [
            Segment(text: "First sentence here.", start: 0, end: 1),
            Segment(text: "Completely skipped words.", start: 1, end: 2),
            Segment(text: "Third sentence closes.", start: 2, end: 3),
        ])
        let rec = recognized([
            ("First", 0.5, 0.8), ("sentence", 0.9, 1.4), ("here", 1.5, 1.8),
            ("Third", 6.0, 6.3), ("sentence", 6.4, 6.9), ("closes", 7.0, 7.5),
        ])
        let r = Aligner.align(script: script, words: rec)
        #expect(r.segments[0].wordTimings?.count == 3)
        #expect(r.segments[1].wordTimings == nil)
        #expect(r.segments[2].wordTimings?.count == 3)
    }

    @Test func alignerDropsTimingsThatRunBackwards() {
        let script = Script(segments: [Segment(text: "one two three", start: 0, end: 1)])
        let rec = recognized([("one", 1.0, 1.2), ("two", 0.95, 1.3), ("three", 1.5, 1.8)])
        let r = Aligner.align(script: script, words: rec)
        let t = r.segments[0].wordTimings ?? []
        #expect(t.map(\.word) == ["one", "three"])
        for i in 1..<t.count { #expect(t[i].start >= t[i - 1].start) }
    }

    // MARK: - Script mutations

    @Test func offsetAllShiftsWordTimings() {
        var seg = Segment(text: "alpha beta", start: 2, end: 4)
        seg.wordTimings = [
            WordTiming(word: "alpha", location: 0, length: 5, start: 2.0, end: 2.5),
            WordTiming(word: "beta", location: 6, length: 4, start: 3.0, end: 4.0),
        ]
        var script = Script(segments: [seg])
        script.offsetAll(by: 1.5)
        let t = script.segments[0].wordTimings ?? []
        #expect(t.map(\.start) == [3.5, 4.5])
        #expect(t.map(\.end) == [4.0, 5.5])
        script.offsetAll(by: -10)
        let c = script.segments[0].wordTimings ?? []
        #expect(c.allSatisfy { $0.start >= 0 && $0.end >= 0 })
        #expect(c.map(\.start) == [0, 0])
    }

    @Test func splitAndMergeClearWordTimings() {
        var a = Segment(text: "alpha beta gamma delta", start: 0, end: 4)
        a.wordTimings = [WordTiming(word: "alpha", location: 0, length: 5, start: 0, end: 1)]
        var b = Segment(text: "epsilon", start: 4, end: 5)
        b.wordTimings = [WordTiming(word: "epsilon", location: 0, length: 7, start: 4, end: 5)]

        var script = Script(segments: [a, b])
        script.split(segmentID: a.id, atTextIndex: 11)
        #expect(script.segments.count == 3)
        #expect(script.segments[0].wordTimings == nil)
        #expect(script.segments[1].wordTimings == nil)
        #expect(script.segments[2].wordTimings != nil) // untouched

        var merged = Script(segments: [a, b])
        merged.mergeWithNext(segmentID: a.id)
        #expect(merged.segments.count == 1)
        #expect(merged.segments[0].wordTimings == nil)
    }

    // MARK: - (b) Per-line anchors drive the scroll

    @Test func lineAnchorsHitTheMarkerAtTheirWordTimes() {
        let style = StyleSettings()
        var seg = Segment(text: Self.longText, start: 0, end: 12)
        let lineCount = RibbonLayout(script: Script(segments: [seg]), style: style)
            .lines.filter { $0.range.length > 0 }.count
        #expect(lineCount >= 3)

        // Line 1 at 0, line 2 at 5.0, line 3 at 9.0, later lines squeezed
        // into the remaining 3 s.
        var starts: [Double] = [0, 5.0, 9.0]
        if lineCount > 3 {
            for k in 3..<lineCount {
                starts.append(9.0 + Double(k - 2) * (2.9 / Double(lineCount - 2)))
            }
        }
        seg.wordTimings = timings(for: seg, style: style, lineStarts: starts, tail: 12)

        let comp = PrompterComposition(script: Script(segments: [seg]), style: style)
        let lines = comp.layout.lines.filter { $0.segmentIndex == 0 && $0.range.length > 0 }
        #expect(lines.count == lineCount)

        let atFive = comp.scrollOffset(atVideoTime: 5.0 + style.leadIn)
        #expect(abs(atFive - (lines[1].centerY - style.markerY)) < 0.5)
        let atNine = comp.scrollOffset(atVideoTime: 9.0 + style.leadIn)
        #expect(abs(atNine - (lines[2].centerY - style.markerY)) < 0.5)
        // The cue start stays authoritative for the first line.
        let atZero = comp.scrollOffset(atVideoTime: 0.0 + style.leadIn)
        #expect(abs(atZero - (lines[0].centerY - style.markerY)) < 0.5)

        // Monotone, never backwards.
        var prev = -Double.infinity
        var t = 0.0
        while t <= comp.videoDuration {
            let o = Double(comp.scrollOffset(atVideoTime: t))
            #expect(o >= prev - 1e-9)
            prev = o
            t += 0.05
        }
    }

    // MARK: - (c) Edited text falls back to the single cue anchor

    @Test func editedTextFallsBackToSingleSegmentAnchor() {
        let style = StyleSettings()
        var seg = Segment(text: Self.longText, start: 0, end: 12)
        let lineCount = RibbonLayout(script: Script(segments: [seg]), style: style)
            .lines.filter { $0.range.length > 0 }.count
        var starts: [Double] = [0, 5.0, 9.0]
        if lineCount > 3 {
            for k in 3..<lineCount {
                starts.append(9.0 + Double(k - 2) * (2.9 / Double(lineCount - 2)))
            }
        }
        seg.wordTimings = timings(for: seg, style: style, lineStarts: starts, tail: 12)

        let good = PrompterComposition(script: Script(segments: [seg]), style: style)
        let goodMid = good.scrollOffset(atVideoTime: 5.0 + style.leadIn)

        // Edit 1: same-length replacement of the first word ("Magic" -> "Music").
        var edited = seg
        edited.text = "Music" + String(Self.longText.dropFirst(5))
        #expect(edited.text.utf16.count == Self.longText.utf16.count)
        // Edit 2: a prefix insertion shifts every range.
        var shifted = seg
        shifted.text = "Oh, " + Self.longText

        for e in [edited, shifted] {
            let comp = PrompterComposition(script: Script(segments: [e]), style: style)
            var noTimings = e
            noTimings.wordTimings = nil
            let ref = PrompterComposition(script: Script(segments: [noTimings]), style: style)
            for t in stride(from: 0.0, through: 12.0, by: 0.5) {
                let a = comp.scrollOffset(atVideoTime: t + style.leadIn)
                let b = ref.scrollOffset(atVideoTime: t + style.leadIn)
                #expect(abs(a - b) < 0.001, "stale timings must be ignored (t=\(t))")
            }
        }

        // Mid-cue pacing differs from the per-line version, and no longer
        // puts line 2 on the marker at t=5.
        let editedMid = PrompterComposition(script: Script(segments: [edited]), style: style)
            .scrollOffset(atVideoTime: 5.0 + style.leadIn)
        #expect(abs(editedMid - goodMid) > 10)
        let line2 = good.layout.lines.filter { $0.segmentIndex == 0 && $0.range.length > 0 }[1]
        #expect(abs(editedMid - (line2.centerY - style.markerY)) > 10)
    }

    // MARK: - Anchor rules

    @Test func crowdedLaterLinesAreDroppedAndFirstLineAnchorsSurvive() {
        let style = StyleSettings()
        var a = Segment(text: Self.longText, start: 0, end: 4)
        let layoutLines = RibbonLayout(script: Script(segments: [a]), style: style)
            .lines.filter { $0.range.length > 0 }.count
        // Line k>=2 arrives just before the next cue starts (3.9, 3.91, ...).
        var starts: [Double] = [0]
        for k in 1..<layoutLines { starts.append(3.9 + 0.01 * Double(k - 1)) }
        a.wordTimings = timings(for: a, style: style, lineStarts: starts, tail: 4)
        let b = Segment(text: "Second cue.", start: 4.0, end: 6)

        let script = Script(segments: [a, b])
        let layout = RibbonLayout(script: script, style: style)
        let anchors = PrompterComposition.scrollAnchors(script: script, layout: layout, markerY: style.markerY)
        // Later lines of A are all within 0.25 s of B's mandatory start.
        #expect(anchors.map(\.time) == [0.0, 4.0])
        #expect(abs(anchors[1].offset - (layout.segmentExtents[1].firstLineCenterY - style.markerY)) < 0.001)
    }

    @Test func laterLineTimesAreClampedIntoTheCue() {
        let style = StyleSettings()
        var a = Segment(text: Self.longText, start: 1.0, end: 9.0)
        let n = RibbonLayout(script: Script(segments: [a]), style: style)
            .lines.filter { $0.range.length > 0 }.count
        #expect(n >= 3)
        // Line 2 claims a time before the cue, every later line after its end.
        var starts: [Double] = [1.0, 0.5]
        for _ in 2..<n { starts.append(20.0) }
        a.wordTimings = timings(for: a, style: style, lineStarts: starts, tail: 21)

        let script = Script(segments: [a])
        let layout = RibbonLayout(script: script, style: style)
        let anchors = PrompterComposition.scrollAnchors(script: script, layout: layout, markerY: style.markerY)
        // Start stays 1.0; line 2 (clamped to 1.0) is dropped as too close;
        // line 3 clamps to the cue end 9.0; further lines collapse into it.
        #expect(anchors.map(\.time) == [1.0, 9.0])
    }

    @Test func segmentsWithoutTimingsKeepTheSingleAnchor() {
        let style = StyleSettings()
        let script = Script(segments: [
            Segment(text: "One short cue.", start: 0, end: 2),
            Segment(text: "Another short cue.", start: 2.5, end: 4),
        ])
        let layout = RibbonLayout(script: script, style: style)
        let anchors = PrompterComposition.scrollAnchors(script: script, layout: layout, markerY: style.markerY)
        #expect(anchors.map(\.time) == [0.0, 2.5])
    }
}
