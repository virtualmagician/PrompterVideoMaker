import Foundation

enum ScriptGranularity: String, CaseIterable, Identifiable {
    case sentences = "Sentences"
    case lines = "Lines"
    case paragraphs = "Paragraphs"
    var id: String { rawValue }
}

/// Builds a Script from pasted plain text. Segments get estimated timings
/// (~150 words per minute plus punctuation pauses) so preview and export work
/// immediately; the record-and-align flow then replaces them with real ones.
enum ScriptImporter {
    static let defaultWordsPerMinute: Double = 150

    static func script(
        fromPastedText text: String,
        granularity: ScriptGranularity,
        wordsPerMinute: Double = defaultWordsPerMinute
    ) -> Script {
        let pieces = split(text: text, granularity: granularity)
        let wps = max(0.5, wordsPerMinute) / 60.0

        var segments: [Segment] = []
        var t = 0.0
        for piece in pieces {
            let words = piece.split(whereSeparator: { $0.isWhitespace }).count
            var duration = Double(words) / wps
            if piece.hasSuffix(".") || piece.hasSuffix("!") || piece.hasSuffix("?") {
                duration += 0.3
            }
            duration = max(1.0, duration)
            segments.append(Segment(text: piece, start: t, end: t + duration))
            t += duration + 0.2
        }
        var script = Script(segments: segments)
        script.normalize()
        return script
    }

    /// Splits pasted text into cue-sized pieces.
    static func split(text: String, granularity: ScriptGranularity) -> [String] {
        let cleaned = text.replacingOccurrences(of: "\r\n", with: "\n")

        switch granularity {
        case .lines:
            return cleaned
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

        case .paragraphs:
            return cleaned
                .components(separatedBy: "\n\n")
                .map {
                    $0.components(separatedBy: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                }
                .filter { !$0.isEmpty }

        case .sentences:
            // Newlines become soft breaks; split the flowed text at sentence
            // enders, keeping the punctuation with the sentence.
            let flowed = cleaned
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            var sentences: [String] = []
            var current = ""
            var i = flowed.startIndex
            while i < flowed.endIndex {
                let ch = flowed[i]
                current.append(ch)
                if ch == "." || ch == "!" || ch == "?" {
                    // Consume trailing quotes/brackets, then break unless this
                    // looks like a mid-sentence abbreviation/number dot.
                    var j = flowed.index(after: i)
                    while j < flowed.endIndex, "\"')]”’".contains(flowed[j]) {
                        current.append(flowed[j])
                        j = flowed.index(after: j)
                    }
                    let nextIsSpace = j == flowed.endIndex || flowed[j] == " "
                    let isDecimalDot = ch == "." && j < flowed.endIndex && flowed[j].isNumber
                    if nextIsSpace && !isDecimalDot {
                        let s = current.trimmingCharacters(in: .whitespaces)
                        if !s.isEmpty { sentences.append(s) }
                        current = ""
                    }
                    i = j
                    continue
                }
                i = flowed.index(after: i)
            }
            let rest = current.trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { sentences.append(rest) }
            return sentences
        }
    }
}
