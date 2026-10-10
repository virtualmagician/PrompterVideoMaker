import Testing
import Foundation
@testable import PrompterVideoMaker

// Serialized: several tests read/write the shared "PVMSpeechLocale" default.
@Suite(.serialized) struct SpeechLanguageTests {

    private static let key = "PVMSpeechLocale"
    private static let german = "Guten Abend, meine Damen und Herren, ich freue mich sehr, heute hier zu sein."
    private static let english = "Good evening, ladies and gentlemen, I am delighted to be here with you tonight."

    /// Runs `body` with the persisted language choice set to `value`
    /// (nil = Automatic), then restores whatever was stored before.
    private func withStoredChoice(_ value: String?, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: Self.key)
        defer {
            if let previous { defaults.set(previous, forKey: Self.key) }
            else { defaults.removeObject(forKey: Self.key) }
        }
        if let value { defaults.set(value, forKey: Self.key) } else { defaults.removeObject(forKey: Self.key) }
        body()
    }

    // MARK: Detection

    @Test func detectsGerman() {
        let locale = SpeechLanguage.detect(fromScript: Self.german)
        #expect(locale?.language.languageCode?.identifier == "de")
    }

    @Test func detectsEnglish() {
        let locale = SpeechLanguage.detect(fromScript: Self.english)
        #expect(locale?.language.languageCode?.identifier == "en")
    }

    @Test func emptyOrTinyTextIsUndetermined() {
        #expect(SpeechLanguage.detect(fromScript: "") == nil)
        #expect(SpeechLanguage.detect(fromScript: "   \n  ") == nil)
        #expect(SpeechLanguage.detect(fromScript: "Hi") == nil)
    }

    // MARK: Resolution

    @Test func resolvePrefersStoredChoiceOverDetection() {
        withStoredChoice("fr_FR") {
            #expect(SpeechLanguage.preferredLocale?.identifier == "fr_FR")
            // German script text, but the explicit French choice wins.
            let locale = SpeechLanguage.resolve(scriptText: Self.german)
            #expect(locale?.language.languageCode?.identifier == "fr")
            #expect(SpeechLanguage.resolve(scriptText: nil)?.language.languageCode?.identifier == "fr")
        }
    }

    @Test func resolveDetectsWhenAutomatic() {
        withStoredChoice(nil) {
            #expect(SpeechLanguage.preferredLocale == nil)
            #expect(SpeechLanguage.resolve(scriptText: Self.german)?.language.languageCode?.identifier == "de")
            #expect(SpeechLanguage.resolve(scriptText: nil) == nil)
            #expect(SpeechLanguage.resolve(scriptText: "") == nil)
        }
        // "" is also Automatic.
        withStoredChoice("") {
            #expect(SpeechLanguage.preferredLocale == nil)
            #expect(SpeechLanguage.resolve(scriptText: Self.german)?.language.languageCode?.identifier == "de")
        }
    }

    @Test func preferredLocaleRoundTripsThroughDefaults() {
        withStoredChoice(nil) {
            SpeechLanguage.preferredLocale = Locale(identifier: "de_CH")
            #expect(UserDefaults.standard.string(forKey: Self.key) == "de_CH")
            #expect(SpeechLanguage.preferredLocale?.identifier == "de_CH")
            SpeechLanguage.preferredLocale = nil
            #expect(SpeechLanguage.preferredLocale == nil)
        }
    }

    // MARK: Matching a bare language to a supported regional locale

    @Test func bareLanguageMatchesSupportedRegion() {
        let supported = ["en_US", "en_GB", "de_AT", "de_CH", "de_DE", "fr_FR"].map { Locale(identifier: $0) }
        // Exact (case/separator-insensitive).
        #expect(SpeechLanguage.bestMatch(for: Locale(identifier: "de-CH"), in: supported)?.identifier == "de_CH")
        // Region requested but unsupported -> another region of the same language.
        let near = SpeechLanguage.bestMatch(for: Locale(identifier: "de_LU"), in: supported)
        #expect(near?.language.languageCode?.identifier == "de")
        // Bare language -> some supported variant of it (de_DE unless the system region applies).
        let bare = SpeechLanguage.bestMatch(for: Locale(identifier: "de"), in: supported)
        #expect(bare?.language.languageCode?.identifier == "de")
        // Unsupported language.
        #expect(SpeechLanguage.bestMatch(for: Locale(identifier: "ja"), in: supported) == nil)
    }

    @Test func sortedByNameDedupesAndOrders() {
        let sorted = SpeechLanguage.sortedByName(
            ["fr_FR", "de_DE", "en_US", "de_DE"].map { Locale(identifier: $0) })
        #expect(sorted.count == 3)
        let names = sorted.map { SpeechLanguage.displayName(for: $0) }
        #expect(names == names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    // MARK: Grouping keeps word offsets exact

    @Test func groupedSegmentsCarryExactWordTimings() {
        typealias W = Transcriber.TimedWord
        let words = [
            W(text: "Guten", start: 0.0, end: 0.4),
            W(text: "Abend", start: 0.4, end: 0.8),
            W(text: ",", start: 0.8, end: 0.85),       // detached punctuation
            W(text: "meine", start: 0.9, end: 1.2),
            W(text: "Damen.", start: 1.2, end: 1.6),  // sentence end -> flush
            W(text: "Schön", start: 1.7, end: 2.0),   // non-ASCII (UTF-16 offsets)
            W(text: "hier", start: 2.0, end: 2.3),
            W(text: "!", start: 2.3, end: 2.35),
        ]
        let segments = Transcriber.group(words: words)
        #expect(segments.count == 2)
        #expect(segments[0].text == "Guten Abend, meine Damen.")
        #expect(segments[1].text == "Schön hier!")

        for seg in segments {
            let timings = try! #require(seg.wordTimings)
            let ns = seg.text as NSString
            #expect(!timings.isEmpty)
            for t in timings {
                #expect(ns.substring(with: NSRange(location: t.location, length: t.length)) == t.word)
            }
        }
        // The detached comma was folded into "Abend".
        let first = segments[0].wordTimings!
        #expect(first.map(\.word) == ["Guten", "Abend,", "meine", "Damen."])
        #expect(first[1].location == 6 && first[1].length == 6)
        #expect(first[1].start == 0.4 && first[1].end == 0.85)
        #expect(segments[1].wordTimings!.map(\.word) == ["Schön", "hier!"])
    }
}
