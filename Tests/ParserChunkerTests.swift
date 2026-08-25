import Testing
import Foundation
@testable import PrompterVideoMaker

@Suite struct SRTParserTests {

    @Test func parsesBasicCue() throws {
        let text = "1\n00:00:01,000 --> 00:00:03,500\nHello world."
        let segments = try SRTParser.parse(text, stripSpeakerPrefixes: false)
        #expect(segments.count == 1)
        #expect(segments[0].text == "Hello world.")
        #expect(abs(segments[0].start - 1.0) < 1e-9)
        #expect(abs(segments[0].end - 3.5) < 1e-9)
    }

    /// Exercises BOM stripping, a cue with no index, a non-sequential index,
    /// dot-vs-comma millisecond separators, multi-line cue text joined with a
    /// single space, and extra/variable blank lines between cues.
    @Test func toleratesRealWorldVariationsAndRoundTrips() throws {
        let rawLines = [
            "1",
            "00:00:01,000 --> 00:00:03,500",
            "Hello world.",
            "",
            "00:00:04,250 --> 00:00:05,750",
            "Second cue has no leading index at all.",
            "",
            "99",
            "00:00:06.100 --> 00:00:08.750",
            "Third cue wraps",
            "across multiple",
            "physical lines.",
            "",
            "",
            "4",
            "00:00:09,000 --> 00:00:10,020",
            "Fourth cue follows extra blank lines and a non-sequential index."
        ]
        let synthetic = "\u{FEFF}" + rawLines.joined(separator: "\n")

        let segments = try SRTParser.parse(synthetic, stripSpeakerPrefixes: false)
        #expect(segments.count == 4)
        #expect(segments[0].text == "Hello world.")
        #expect(segments[1].text == "Second cue has no leading index at all.")
        #expect(segments[2].text == "Third cue wraps across multiple physical lines.")
        #expect(segments[3].text == "Fourth cue follows extra blank lines and a non-sequential index.")
        #expect(abs(segments[1].start - 4.25) < 1e-9)
        #expect(abs(segments[2].end - 8.75) < 1e-9)
        #expect(abs(segments[3].start - 9.0) < 1e-9)

        // Round trip: serialize, reparse, and confirm text/timing survive
        // (indices and blank-line formatting are not expected to match).
        let serialized = SRTParser.serialize(segments)
        let reparsed = try SRTParser.parse(serialized, stripSpeakerPrefixes: false)
        #expect(reparsed.count == segments.count)
        for (a, b) in zip(segments, reparsed) {
            #expect(a.text == b.text)
            #expect(abs(a.start - b.start) < 0.001)
            #expect(abs(a.end - b.end) < 0.001)
        }
    }

    @Test func dotAndCommaMillisecondSeparatorsAreEquivalent() throws {
        let commaText = "1\n00:00:01,500 --> 00:00:02,750\nComma cue."
        let dotText = "1\n00:00:01.500 --> 00:00:02.750\nDot cue."
        let commaSeg = try SRTParser.parse(commaText, stripSpeakerPrefixes: false)
        let dotSeg = try SRTParser.parse(dotText, stripSpeakerPrefixes: false)
        #expect(commaSeg.count == 1)
        #expect(dotSeg.count == 1)
        #expect(abs(commaSeg[0].start - dotSeg[0].start) < 1e-9)
        #expect(abs(commaSeg[0].end - dotSeg[0].end) < 1e-9)
    }

    @Test func serializeUsesStandardCommaFormat() {
        let segments = [Segment(text: "Hi.", start: 61.5, end: 63.25)]
        let out = SRTParser.serialize(segments)
        #expect(out.hasPrefix("1\n00:01:01,500 --> 00:01:03,250\nHi."))
    }

    @Test func throwsOnUnparsableTimestamp() {
        let bad = "1\nnot a timestamp\nSome text."
        #expect(throws: SRTParseError.self) {
            _ = try SRTParser.parse(bad, stripSpeakerPrefixes: false)
        }
    }

    // MARK: - Speaker prefix stripping

    @Test func stripsShortSpeakerPrefix() throws {
        let segs = try SRTParser.parse(
            "1\n00:00:00,000 --> 00:00:01,000\nSpeaker 1: Hello there.",
            stripSpeakerPrefixes: true
        )
        #expect(segs.first?.text == "Hello there.")
    }

    @Test func stripsNamedPrefix() throws {
        let segs = try SRTParser.parse(
            "1\n00:00:00,000 --> 00:00:01,000\nMarco: Good evening everyone.",
            stripSpeakerPrefixes: true
        )
        #expect(segs.first?.text == "Good evening everyone.")
    }

    @Test func keepsLongPrefixUnstripped() throws {
        let longLabel = "This is definitely not a short speaker name"
        #expect(longLabel.count > 24)
        let text = "\(longLabel): keep going"
        let segs = try SRTParser.parse(
            "1\n00:00:00,000 --> 00:00:01,000\n\(text)",
            stripSpeakerPrefixes: true
        )
        #expect(segs.first?.text == text)
    }

    @Test func keepsPunctuatedPrefixUnstripped() throws {
        let text = "Wait! Listen: this is important."
        let segs = try SRTParser.parse(
            "1\n00:00:00,000 --> 00:00:01,000\n\(text)",
            stripSpeakerPrefixes: true
        )
        #expect(segs.first?.text == text)
    }

    @Test func doesNotStripWhenDisabled() throws {
        let text = "Speaker 1: Hello there."
        let segs = try SRTParser.parse(
            "1\n00:00:00,000 --> 00:00:01,000\n\(text)",
            stripSpeakerPrefixes: false
        )
        #expect(segs.first?.text == text)
    }

    // MARK: - Real sample file

    @Test func parsesRealSampleFile() throws {
        let path = "/Users/marcotempest/Library/CloudStorage/Dropbox-Newmagic/Marco Tempest/PrompterVideoMaker/Sample_Input/sample_VO.srt"
        guard FileManager.default.fileExists(atPath: path) else { return }
        let text = try String(contentsOfFile: path, encoding: .utf8)

        let segments = try SRTParser.parse(text, stripSpeakerPrefixes: true)
        #expect(segments.count == 118)
        #expect(segments.first?.text == "Thank you, Peter, and good evening, everyone.")
        #expect(segments.last?.text == "Welcome to the Eighth Continent and welcome to the table.")
        for segment in segments {
            #expect(!segment.text.hasPrefix("Speaker 1:"))
            #expect(!segment.text.hasPrefix("Speaker 2:"))
            #expect(segment.end >= segment.start)
        }

        // Chunking the real transcript must lose no characters and respect maxWords.
        let maxWords = 8
        let chunked = Chunker.chunks(for: segments, maxWords: maxWords, alternate: true)
        #expect(chunked.count == segments.count)
        for (segment, chunks) in zip(segments, chunked) {
            #expect(chunks.map(\.text).joined(separator: " ") == segment.text)
            for chunk in chunks {
                #expect(chunk.text.split(separator: " ").count <= maxWords)
            }
        }
    }
}

@Suite struct ChunkerTests {

    static func sampleSegments() -> [Segment] {
        [
            Segment(text: "Thank you, Peter, and good evening, everyone.", start: 0, end: 3),
            Segment(text: "My name is Marco Tempest.", start: 3, end: 5),
            Segment(text: "I lead Creative Technology and Innovation at ETH Zurich Space.", start: 5, end: 9)
        ]
    }

    @Test func preservesAllText() {
        let segments = Self.sampleSegments()
        let chunked = Chunker.chunks(for: segments, maxWords: 4, alternate: true)
        #expect(chunked.count == segments.count)
        for (segment, chunks) in zip(segments, chunked) {
            let rejoined = chunks.map(\.text).joined(separator: " ")
            #expect(rejoined == segment.text)
        }
    }

    @Test func respectsMaxWords() {
        let segments = Self.sampleSegments()
        let maxWords = 4
        let chunked = Chunker.chunks(for: segments, maxWords: maxWords, alternate: true)
        for chunks in chunked {
            for chunk in chunks {
                #expect(chunk.text.split(separator: " ").count <= maxWords)
            }
        }
    }

    @Test func breaksAtSentenceEndersWithinWindow() {
        let segment = Segment(text: "Stop now. Keep going forward please", start: 0, end: 1)
        let chunked = Chunker.chunks(for: [segment], maxWords: 6, alternate: false)
        // "Stop now." ends a sentence at word 2, well inside the 6-word
        // budget, so the first chunk should end there rather than greedily
        // grabbing the full window.
        #expect(chunked[0].first?.text == "Stop now.")
    }

    @Test func breaksAtClausePunctuationWhenNoSentenceEnderFits() {
        let segment = Segment(text: "First, second, third fourth fifth sixth seventh", start: 0, end: 1)
        let chunked = Chunker.chunks(for: [segment], maxWords: 4, alternate: false)
        // No sentence ender within the first 4-word window, but "second,"
        // (word 2) is the latest comma break available.
        #expect(chunked[0].first?.text == "First, second,")
    }

    @Test func globalAlternationContinuesAcrossSegments() {
        let segments = Self.sampleSegments()
        let chunked = Chunker.chunks(for: segments, maxWords: 3, alternate: true)
        let flat = chunked.flatMap { $0 }
        #expect(flat.count > 1)
        for (i, chunk) in flat.enumerated() {
            #expect(chunk.colorIndex == i % 2)
        }
    }

    @Test func noAlternationWhenDisabled() {
        let segments = Self.sampleSegments()
        let chunked = Chunker.chunks(for: segments, maxWords: 3, alternate: false)
        for chunk in chunked.flatMap({ $0 }) {
            #expect(chunk.colorIndex == 0)
        }
    }

    @Test func singleWordLongerThanLimitStillProducesOneChunk() {
        let segment = Segment(text: "Supercalifragilisticexpialidocious", start: 0, end: 1)
        let chunked = Chunker.chunks(for: [segment], maxWords: 3, alternate: false)
        #expect(chunked[0].count == 1)
        #expect(chunked[0][0].text == "Supercalifragilisticexpialidocious")
    }

    @Test func emptySegmentTextProducesNoChunks() {
        let segment = Segment(text: "", start: 0, end: 1)
        let chunked = Chunker.chunks(for: [segment], maxWords: 5, alternate: true)
        #expect(chunked.count == 1)
        #expect(chunked[0].isEmpty)
    }
}
