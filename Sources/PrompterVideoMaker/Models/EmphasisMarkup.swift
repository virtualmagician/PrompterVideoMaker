import Foundation

/// Lightweight inline emphasis markup for prompter text:
///   **bold**   __underline__   ==accent color==
/// Markers must hug their content (`**word**`, not `** word **`); unmatched
/// markers are treated as literal text. Different markers may nest
/// (`**bold __both__**`).
enum EmphasisMarkup {

    struct Run: Equatable {
        /// UTF-16 offsets into the plain (marker-free) text.
        var range: Range<Int>
        var bold: Bool = false
        var underline: Bool = false
        var accent: Bool = false
    }

    private static let pattern: NSRegularExpression = {
        // (marker)(?=\S)(content, lazily)(?<=\S)\1
        try! NSRegularExpression(pattern: "(\\*\\*|__|==)(?=\\S)(.+?)(?<=\\S)\\1")
    }()

    /// Parses markup into plain text plus attribute runs.
    static func parse(_ text: String) -> (plain: String, runs: [Run]) {
        parseInner(text)
    }

    /// Plain text with all markers removed.
    static func strip(_ text: String) -> String {
        parseInner(text).plain
    }

    /// True when the two texts are identical after removing markup and
    /// collapsing whitespace — i.e. markup is the ONLY difference.
    static func plainEquivalent(_ a: String, _ b: String) -> Bool {
        normalizePlain(strip(a)) == normalizePlain(strip(b))
    }

    private static func normalizePlain(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func parseInner(_ text: String) -> (plain: String, runs: [Run]) {
        let ns = text as NSString
        var plain = ""
        var plainLen = 0 // UTF-16 length of `plain`
        var runs: [Run] = []
        var cursor = 0

        while cursor < ns.length {
            let searchRange = NSRange(location: cursor, length: ns.length - cursor)
            guard let m = pattern.firstMatch(in: text, options: [], range: searchRange) else {
                let rest = ns.substring(with: searchRange)
                plain += rest
                plainLen += (rest as NSString).length
                break
            }
            // Literal text before the match.
            if m.range.location > cursor {
                let literal = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                plain += literal
                plainLen += (literal as NSString).length
            }
            let marker = ns.substring(with: m.range(at: 1))
            let inner = ns.substring(with: m.range(at: 2))
            // Recursively parse the inner content (different markers may nest).
            let sub = parseInner(inner)
            let start = plainLen
            for var r in sub.runs {
                r.range = (r.range.lowerBound + start)..<(r.range.upperBound + start)
                runs.append(r)
            }
            plain += sub.plain
            plainLen += (sub.plain as NSString).length
            var run = Run(range: start..<plainLen)
            switch marker {
            case "**": run.bold = true
            case "__": run.underline = true
            default: run.accent = true
            }
            runs.append(run)
            cursor = m.range.location + m.range.length
        }
        return (plain, runs)
    }
}
