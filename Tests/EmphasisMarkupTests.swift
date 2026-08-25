import Testing
import Foundation
@testable import PrompterVideoMaker

@Suite struct EmphasisMarkupTests {
    @Test func parsesBoldUnderlineAccent() {
        let (plain, runs) = EmphasisMarkup.parse("Say **this** loudly and __clearly__ with ==color==.")
        #expect(plain == "Say this loudly and clearly with color.")
        #expect(runs.count == 3)
        let bold = runs.first { $0.bold }!
        #expect((plain as NSString).substring(with: NSRange(location: bold.range.lowerBound, length: bold.range.count)) == "this")
        let ul = runs.first { $0.underline }!
        #expect((plain as NSString).substring(with: NSRange(location: ul.range.lowerBound, length: ul.range.count)) == "clearly")
        let ac = runs.first { $0.accent }!
        #expect((plain as NSString).substring(with: NSRange(location: ac.range.lowerBound, length: ac.range.count)) == "color")
    }

    @Test func multiWordSpansAndNesting() {
        let (plain, runs) = EmphasisMarkup.parse("**bold __both__ words** end")
        #expect(plain == "bold both words end")
        #expect(runs.contains { $0.underline })
        let bold = runs.first { $0.bold }!
        #expect(bold.range.lowerBound == 0)
        #expect((plain as NSString).substring(with: NSRange(location: bold.range.lowerBound, length: bold.range.count)) == "bold both words")
    }

    @Test func unmatchedAndSpacedMarkersStayLiteral() {
        #expect(EmphasisMarkup.strip("5 == 5 is true") == "5 == 5 is true")
        #expect(EmphasisMarkup.strip("a ** b") == "a ** b")
        #expect(EmphasisMarkup.strip("snake_case and __init__ style") == "snake_case and init style")
        #expect(EmphasisMarkup.strip("no markup at all") == "no markup at all")
    }

    @Test func stripRoundTrip() {
        let marked = "**Founders,** owners, __builders__, the ==community== here."
        #expect(EmphasisMarkup.strip(marked) == "Founders, owners, builders, the community here.")
        #expect(EmphasisMarkup.plainEquivalent(marked, "Founders, owners, builders, the ==community== here."))
        #expect(!EmphasisMarkup.plainEquivalent(marked, "Founders owners builders community here."))
    }

    @Test func suggesterValidationRejectsWordChanges() {
        let segs = [Segment(text: "Keep every word intact.", start: 0, end: 1)]
        // clear() must strip markup.
        let cleared = EmphasisSuggester.clear(segments: [Segment(text: "Keep **every** word intact.", start: 0, end: 1)])
        #expect(cleared[0].text == "Keep every word intact.")
        // plainEquivalent is the gate used by the suggester.
        #expect(EmphasisMarkup.plainEquivalent("Keep **every** word intact.", segs[0].text))
        #expect(!EmphasisMarkup.plainEquivalent("Keep **all** words intact.", segs[0].text))
    }
}
