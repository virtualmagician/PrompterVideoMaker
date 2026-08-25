import Testing
import Foundation
@testable import PrompterVideoMaker

@Suite struct ScriptImporterTests {
    @Test func splitsSentences() {
        let text = "Hello everyone. This is a test!\nDoes it work? Yes it does."
        let pieces = ScriptImporter.split(text: text, granularity: .sentences)
        #expect(pieces == ["Hello everyone.", "This is a test!", "Does it work?", "Yes it does."])
    }

    @Test func decimalDotDoesNotSplit() {
        let pieces = ScriptImporter.split(text: "It costs 3.5 million euros. Truly.", granularity: .sentences)
        #expect(pieces == ["It costs 3.5 million euros.", "Truly."])
    }

    @Test func abbreviationDotsDoNotSplit() {
        let pieces = ScriptImporter.split(
            text: "Dr. Smith met Mr. Jones at the U.S. embassy. J. Doe arrived later.",
            granularity: .sentences
        )
        #expect(pieces == ["Dr. Smith met Mr. Jones at the U.S. embassy.", "J. Doe arrived later."])
    }

    @Test func splitsLinesAndParagraphsPreservingBreaks() {
        let text = "Line one\nLine two\n\nSecond paragraph\nstill second"
        #expect(ScriptImporter.split(text: text, granularity: .lines)
                == ["Line one", "Line two", "", "Second paragraph", "still second"])
        #expect(ScriptImporter.split(text: text, granularity: .paragraphs)
                == ["Line one Line two", "", "Second paragraph still second"])
    }

    @Test func blankLinesBecomeSpacerSegments() {
        let script = ScriptImporter.script(fromPastedText: "First cue.\n\n\nSecond cue.", granularity: .sentences)
        #expect(script.segments.count == 3)
        #expect(script.segments[1].text.isEmpty)
        // Spacers get a short pause so the estimated scroll rolls smoothly
        // through the blank row.
        #expect(abs(script.segments[1].duration - 0.5) < 0.01)
        #expect(script.segments[0].text == "First cue.")
        #expect(script.segments[2].text == "Second cue.")
    }

    @Test func lineBreaksForceCueBoundariesInSentenceMode() {
        // Two sentence fragments on separate lines must NOT be merged.
        let pieces = ScriptImporter.split(text: "no punctuation here\nand none here", granularity: .sentences)
        #expect(pieces == ["no punctuation here", "and none here"])
    }

    @Test func estimatedTimingsAreMonotone() {
        let script = ScriptImporter.script(fromPastedText: "One two three. Four five six seven. Eight.", granularity: .sentences)
        #expect(script.segments.count == 3)
        for i in 1..<script.segments.count {
            #expect(script.segments[i].start > script.segments[i - 1].start)
            #expect(script.segments[i - 1].end <= script.segments[i].start + 0.001)
        }
    }
}

@Suite struct AlignerTests {
    private func words(_ list: [(String, Double, Double)]) -> [Transcriber.TimedWord] {
        list.map { .init(text: $0.0, start: $0.1, end: $0.2) }
    }

    @Test func perfectReadingAlignsExactly() {
        let script = Script(segments: [
            Segment(text: "Hello everyone tonight.", start: 0, end: 1),
            Segment(text: "My name is Marco.", start: 1, end: 2),
        ])
        let rec = words([
            ("Hello", 2.0, 2.4), ("everyone", 2.5, 3.0), ("tonight", 3.1, 3.6),
            ("My", 5.0, 5.2), ("name", 5.3, 5.6), ("is", 5.7, 5.8), ("Marco", 5.9, 6.4),
        ])
        let r = Aligner.align(script: script, words: rec)
        #expect(r.matchRate > 0.99)
        #expect(abs(r.segments[0].start - 2.0) < 0.001)
        #expect(abs(r.segments[0].end - 3.6) < 0.001)
        #expect(abs(r.segments[1].start - 5.0) < 0.001)
        #expect(abs(r.segments[1].end - 6.4) < 0.001)
    }

    @Test func survivesStumblesAndRepeats() {
        let script = Script(segments: [
            Segment(text: "The quick brown fox jumps.", start: 0, end: 1),
        ])
        // Reader stumbles: repeats "the quick", inserts "uh".
        let rec = words([
            ("The", 1.0, 1.2), ("quick", 1.3, 1.6), ("uh", 1.7, 1.9),
            ("the", 2.0, 2.2), ("quick", 2.3, 2.6), ("brown", 2.7, 3.0),
            ("fox", 3.1, 3.4), ("jumps", 3.5, 3.9),
        ])
        let r = Aligner.align(script: script, words: rec)
        #expect(r.matchRate > 0.99)
        #expect(r.segments[0].start >= 1.0 && r.segments[0].start <= 2.0)
        #expect(abs(r.segments[0].end - 3.9) < 0.001)
    }

    @Test func skippedSegmentIsInterpolatedBetweenNeighbors() {
        let script = Script(segments: [
            Segment(text: "First sentence here.", start: 0, end: 1),
            Segment(text: "Completely skipped words.", start: 1, end: 2),
            Segment(text: "Third sentence closes.", start: 2, end: 3),
        ])
        let rec = words([
            ("First", 0.5, 0.8), ("sentence", 0.9, 1.4), ("here", 1.5, 1.8),
            ("Third", 6.0, 6.3), ("sentence", 6.4, 6.9), ("closes", 7.0, 7.5),
        ])
        let r = Aligner.align(script: script, words: rec)
        let mid = r.segments[1]
        #expect(mid.start >= 1.8 && mid.end <= 6.0 + 0.001)
        #expect(mid.end > mid.start)
        // Monotone overall.
        #expect(r.segments[0].end <= r.segments[1].start + 0.01)
        #expect(r.segments[1].end <= r.segments[2].start + 0.01)
    }

    @Test func fuzzyMatchesAbsorbASRVariance() {
        let script = Script(segments: [
            Segment(text: "Storytellers create wonderful illusions.", start: 0, end: 1),
        ])
        // ASR drops plural endings / slight variants.
        let rec = words([
            ("Storyteller", 1.0, 1.5), ("creates", 1.6, 2.0),
            ("wonderful", 2.1, 2.6), ("illusion", 2.7, 3.2),
        ])
        let r = Aligner.align(script: script, words: rec)
        #expect(r.matchRate > 0.99)
        #expect(abs(r.segments[0].start - 1.0) < 0.001)
        #expect(abs(r.segments[0].end - 3.2) < 0.001)
    }

    @Test func overlappingASRTimestampsNeverReorderSegments() {
        // "now" (last matched word before the hole) ENDS after "Outro"
        // (first matched word after the hole) STARTS — the interpolated
        // middle segment must still land between them in script order.
        let script = Script(segments: [
            Segment(text: "Intro begins now.", start: 0, end: 1),
            Segment(text: "Completely skipped words.", start: 1, end: 2),
            Segment(text: "Outro closes fast.", start: 2, end: 3),
        ])
        let rec = words([
            ("Intro", 10.0, 10.2), ("begins", 10.3, 10.5), ("now", 10.6, 10.8),
            ("Outro", 10.79, 11.0), ("closes", 11.1, 11.4), ("fast", 11.5, 11.8),
        ])
        let r = Aligner.align(script: script, words: rec)
        let texts = r.segments.map(\.text)
        #expect(texts == ["Intro begins now.", "Completely skipped words.", "Outro closes fast."])
        for i in 1..<r.segments.count {
            #expect(r.segments[i].start > r.segments[i - 1].start)
        }
    }

    @Test func emptyRecognitionKeepsScriptWithZeroRate() {
        let script = Script(segments: [Segment(text: "Anything at all.", start: 3, end: 5)])
        let r = Aligner.align(script: script, words: [])
        #expect(r.matchRate == 0)
        #expect(r.segments[0].start == 3 && r.segments[0].end == 5)
    }
}
