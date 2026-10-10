import Foundation
import NaturalLanguage
import Speech

/// Which language the on-device recognizer should use. Recognition used to
/// always resolve to the system locale (usually en_US), so non-English scripts
/// were recognized with an English model and aligned poorly.
enum SpeechLanguage {

    private static let defaultsKey = "PVMSpeechLocale"

    // MARK: - Supported locales

    /// Locales the on-device recognizer supports, sorted by localized name.
    /// macOS 26: `SpeechTranscriber.supportedLocales`; macOS 15 falls back to
    /// `SFSpeechRecognizer.supportedLocales()`.
    static func supportedLocales() async -> [Locale] {
        let locales: [Locale]
        if #available(macOS 26.0, *) {
            locales = Array(await SpeechTranscriber.supportedLocales)
        } else {
            locales = Array(SFSpeechRecognizer.supportedLocales())
        }
        return sortedByName(locales)
    }

    /// Human-readable name in the user's UI language, e.g. "German (Switzerland)".
    static func displayName(for locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    /// De-duplicated (by identifier) and sorted by localized name.
    static func sortedByName(_ locales: [Locale]) -> [Locale] {
        var seen = Set<String>()
        let unique = locales.filter { seen.insert($0.identifier).inserted }
        return unique.sorted {
            let a = displayName(for: $0), b = displayName(for: $1)
            let order = a.localizedCaseInsensitiveCompare(b)
            return order == .orderedSame ? $0.identifier < $1.identifier : order == .orderedAscending
        }
    }

    // MARK: - Detection

    /// Dominant language of script text via NLLanguageRecognizer, as a Locale
    /// (e.g. "de"). Nil when undetermined, too short, or not confident.
    static func detect(fromScript text: String) -> Locale? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A handful of characters cannot be classified reliably.
        guard trimmed.count >= 12 else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(trimmed.prefix(20_000)))
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        let confidence = recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0
        guard confidence >= 0.5 else { return nil }
        return Locale(identifier: language.rawValue)
    }

    // MARK: - Persisted choice

    /// The user's explicit choice (UserDefaults "PVMSpeechLocale" identifier);
    /// nil / "" means Automatic.
    static var preferredLocale: Locale? {
        get {
            guard let id = UserDefaults.standard.string(forKey: defaultsKey), !id.isEmpty else { return nil }
            return Locale(identifier: id)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.identifier, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }
    }

    /// The locale to request: the preferred one if set; else detected from
    /// `scriptText` when provided; else nil (the recognizer's own default:
    /// system language, then en_US).
    static func resolve(scriptText: String?) -> Locale? {
        if let preferred = preferredLocale { return preferred }
        if let scriptText { return detect(fromScript: scriptText) }
        return nil
    }

    // MARK: - Matching

    /// Picks the supported locale that best fits `requested`: an exact
    /// identifier match, else the same language and region, else the same
    /// language (preferring the system region when the system language is the
    /// same, then the language's most likely region, then alphabetical order).
    /// Lets a bare detected code such as "de" resolve to e.g. de_DE.
    static func bestMatch(for requested: Locale, in supported: [Locale]) -> Locale? {
        func norm(_ id: String) -> String { id.replacingOccurrences(of: "_", with: "-").lowercased() }
        let wanted = norm(requested.identifier)
        if let exact = supported.first(where: { norm($0.identifier) == wanted }) { return exact }

        guard let lang = requested.language.languageCode?.identifier else { return nil }
        let sameLanguage = supported
            .filter { $0.language.languageCode?.identifier == lang }
            .sorted { $0.identifier < $1.identifier }
        guard !sameLanguage.isEmpty else { return nil }

        if let region = requested.region?.identifier,
           let match = sameLanguage.first(where: { $0.region?.identifier == region }) {
            return match
        }
        // The system region only counts when the system language is this one
        // (a de_CH user reading German gets de_CH, an en_US user gets de_DE).
        if Locale.current.language.languageCode?.identifier == lang,
           let systemRegion = Locale.current.region?.identifier,
           let match = sameLanguage.first(where: { $0.region?.identifier == systemRegion }) {
            return match
        }
        let likelyID = Locale.Language(identifier: lang).maximalIdentifier
        if let likelyRegion = Locale(identifier: likelyID).region?.identifier,
           let match = sameLanguage.first(where: { $0.region?.identifier == likelyRegion }) {
            return match
        }
        return sameLanguage.first
    }
}
