import Foundation

/// Lightweight inline emphasis markup for prompter text:
///   **bold**   *italic*   __underline__   ==accent color==
/// Markers must hug their content (`**word**`, not `** word **`); unmatched
/// markers are treated as literal text. Different markers may nest
/// (`**bold __both__**`).
enum EmphasisMarkup {

    enum Attribute: CaseIterable {
        case bold, italic, underline, accent

        var marker: String {
            switch self {
            case .bold: return "**"
            case .italic: return "*"
            case .underline: return "__"
            case .accent: return "=="
            }
        }
    }

    struct Run: Equatable {
        /// UTF-16 offsets into the plain (marker-free) text.
        var range: Range<Int>
        var bold: Bool = false
        var italic: Bool = false
        var underline: Bool = false
        var accent: Bool = false

        var attributes: Set<Attribute> {
            var s = Set<Attribute>()
            if bold { s.insert(.bold) }
            if italic { s.insert(.italic) }
            if underline { s.insert(.underline) }
            if accent { s.insert(.accent) }
            return s
        }
    }

    private static let pattern: NSRegularExpression = {
        // (marker)(?=\S)(content, lazily)(?<=\S)\1 — longer markers listed
        // first so "***" (bold+italic) beats "**" beats "*".
        try! NSRegularExpression(pattern: "(\\*\\*\\*|\\*\\*|__|==|\\*)(?=\\S)(.+?)(?<=\\S)\\1")
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
            case "***": run.bold = true; run.italic = true
            case "**": run.bold = true
            case "*": run.italic = true
            case "__": run.underline = true
            default: run.accent = true
            }
            runs.append(run)
            cursor = m.range.location + m.range.length
        }
        return (plain, runs)
    }

    // MARK: - Character attribute masks

    /// Per-UTF-16-character attribute sets for the plain text described by
    /// `runs` (text length `length`).
    static func characterAttributes(runs: [Run], length: Int) -> [Set<Attribute>] {
        var masks = [Set<Attribute>](repeating: [], count: max(0, length))
        for run in runs {
            let lo = max(0, run.range.lowerBound)
            let hi = min(length, run.range.upperBound)
            guard hi > lo else { continue }
            for i in lo..<hi {
                masks[i].formUnion(run.attributes)
            }
        }
        return masks
    }

    // MARK: - Serialization (plain + attributes → marked-up text)

    /// Rebuilds canonical markup from plain text and per-character attributes.
    /// Whitespace between two characters carrying the same set is wrapped with
    /// them; markers always hug non-whitespace (leading/trailing whitespace of
    /// a run is emitted outside the markers).
    static func serialize(plain: String, characterAttributes masksIn: [Set<Attribute>]) -> String {
        let ns = plain as NSString
        let n = ns.length
        guard n > 0 else { return plain }
        var masks = masksIn
        if masks.count < n { masks += Array(repeating: Set<Attribute>(), count: n - masks.count) }

        // Give whitespace the intersection of its non-space neighbors so runs
        // merge across single spaces.
        func isSpace(_ i: Int) -> Bool {
            let c = ns.character(at: i)
            return c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
        }
        var effective = masks
        for i in 0..<n where isSpace(i) {
            var left = i - 1
            while left >= 0, isSpace(left) { left -= 1 }
            var right = i + 1
            while right < n, isSpace(right) { right += 1 }
            if left >= 0, right < n {
                effective[i] = masks[left].intersection(masks[right])
            } else {
                effective[i] = []
            }
        }

        // Canonical nesting order (outermost first).
        let order: [Attribute] = [.bold, .italic, .underline, .accent]
        var out = ""
        var i = 0
        while i < n {
            if effective[i].isEmpty {
                out += ns.substring(with: NSRange(location: i, length: 1))
                i += 1
                continue
            }
            // Maximal run of identical attribute sets.
            let set = effective[i]
            var j = i
            while j < n, effective[j] == set { j += 1 }
            // Trim whitespace off the wrapped edges.
            var a = i, b = j
            while a < b, isSpace(a) { a += 1 }
            while b > a, isSpace(b - 1) { b -= 1 }
            if a > i { out += ns.substring(with: NSRange(location: i, length: a - i)) }
            if b > a {
                let open = order.filter { set.contains($0) }
                for attr in open { out += attr.marker }
                out += ns.substring(with: NSRange(location: a, length: b - a))
                for attr in open.reversed() { out += attr.marker }
            }
            if j > b { out += ns.substring(with: NSRange(location: b, length: j - b)) }
            i = j
        }
        return out
    }

    // MARK: - Toggling (for the in-preview formatting UI)

    /// Toggles `attribute` over `plainRange` (UTF-16 offsets into the PLAIN
    /// text of `markedText`): if every non-whitespace character in the range
    /// already has it, it is removed; otherwise it is applied to the whole
    /// range. Returns the re-serialized marked-up text.
    static func toggle(_ attribute: Attribute, in markedText: String, plainRange: Range<Int>) -> String {
        let (plain, runs) = parse(markedText)
        let ns = plain as NSString
        let n = ns.length
        let lo = max(0, min(plainRange.lowerBound, n))
        let hi = max(lo, min(plainRange.upperBound, n))
        guard hi > lo else { return markedText }

        var masks = characterAttributes(runs: runs, length: n)
        func isSpace(_ i: Int) -> Bool {
            let c = ns.character(at: i)
            return c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
        }
        let targetIndices = (lo..<hi).filter { !isSpace($0) }
        guard !targetIndices.isEmpty else { return markedText }
        let allHave = targetIndices.allSatisfy { masks[$0].contains(attribute) }
        for i in targetIndices {
            if allHave {
                masks[i].remove(attribute)
            } else {
                masks[i].insert(attribute)
            }
        }
        return serialize(plain: plain, characterAttributes: masks)
    }

    /// Keeps only the given attributes, dropping all other markers.
    static func filtered(_ markedText: String, keeping kept: Set<Attribute>) -> String {
        let (plain, runs) = parse(markedText)
        let masks = characterAttributes(runs: runs, length: (plain as NSString).length)
            .map { $0.intersection(kept) }
        return serialize(plain: plain, characterAttributes: masks)
    }

    /// Expands a plain-text UTF-16 index to the whitespace-delimited word
    /// containing it (or nil on whitespace / out of range).
    static func wordRange(inPlain plain: String, at index: Int) -> Range<Int>? {
        let ns = plain as NSString
        let n = ns.length
        guard n > 0 else { return nil }
        let i = max(0, min(index, n - 1))
        func isSpace(_ k: Int) -> Bool {
            let c = ns.character(at: k)
            return c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
        }
        guard !isSpace(i) else { return nil }
        var a = i
        while a > 0, !isSpace(a - 1) { a -= 1 }
        var b = i + 1
        while b < n, !isSpace(b) { b += 1 }
        return a..<b
    }
}
