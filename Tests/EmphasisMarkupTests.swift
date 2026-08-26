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

    @Test func parsesItalicAndBoldTogether() {
        let (plain, runs) = EmphasisMarkup.parse("Say *this* and **that** or ***both***.")
        #expect(plain == "Say this and that or both.")
        #expect(runs.contains { $0.italic && !$0.bold })
        #expect(runs.contains { $0.bold && !$0.italic })
        // ***both*** = bold wrapping italic (or vice versa) on "both"
        let masks = EmphasisMarkup.characterAttributes(runs: runs, length: (plain as NSString).length)
        let idx = (plain as NSString).range(of: "both").location
        #expect(masks[idx].contains(.bold) && masks[idx].contains(.italic))
    }

    @Test func toggleAddsAndRemovesAttribute() {
        let marked = "Keep every word intact."
        let plain = EmphasisMarkup.strip(marked)
        let word = EmphasisMarkup.wordRange(inPlain: plain, at: 6)! // "every"
        let bolded = EmphasisMarkup.toggle(.bold, in: marked, plainRange: word)
        #expect(bolded == "Keep **every** word intact.")
        let unbolded = EmphasisMarkup.toggle(.bold, in: bolded, plainRange: word)
        #expect(unbolded == "Keep every word intact.")
        // Stacking italic on the bolded word nests canonically.
        let both = EmphasisMarkup.toggle(.italic, in: bolded, plainRange: word)
        #expect(EmphasisMarkup.strip(both) == plain)
        let (_, runs) = EmphasisMarkup.parse(both)
        #expect(runs.contains { $0.bold } && runs.contains { $0.italic })
    }

    @Test func toggleAcrossWordsMergesSpan() {
        let marked = "one two three four"
        let r = EmphasisMarkup.toggle(.bold, in: marked, plainRange: 4..<13) // "two three"
        #expect(r == "one **two three** four")
    }

    @Test func filteredKeepsOnlyRequestedAttributes() {
        let mixed = "A **bold** and __under__ and ==accent== word."
        let boldOnly = EmphasisMarkup.filtered(mixed, keeping: [.bold])
        #expect(boldOnly == "A **bold** and under and accent word.")
    }

    @Test func serializeRoundTripsThroughParse() {
        let original = "Mix **bold *inner italic* tail** and __u__ ends."
        let (plain, runs) = EmphasisMarkup.parse(original)
        let masks = EmphasisMarkup.characterAttributes(runs: runs, length: (plain as NSString).length)
        let rebuilt = EmphasisMarkup.serialize(plain: plain, characterAttributes: masks)
        let (plain2, runs2) = EmphasisMarkup.parse(rebuilt)
        #expect(plain2 == plain)
        let masks2 = EmphasisMarkup.characterAttributes(runs: runs2, length: (plain2 as NSString).length)
        // Attributes on whitespace at run boundaries are visually meaningless
        // and may normalize; compare every visible character.
        let ns = plain as NSString
        for i in 0..<ns.length where !Character(UnicodeScalar(ns.character(at: i))!).isWhitespace {
            #expect(masks2[i] == masks[i], "mask mismatch at \(i)")
        }
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
