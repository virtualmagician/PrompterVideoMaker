import Foundation

/// Errors raised while parsing malformed SRT input.
enum SRTParseError: Error, Equatable {
    case malformed(line: Int, reason: String)
}

/// Imports/exports the SubRip (.srt) subtitle format.
enum SRTParser {

    private static let timestampRegex: NSRegularExpression = {
        // "H:MM:SS,mmm --> H:MM:SS,mmm" tolerating '.' as the millisecond
        // separator and 1-3 digit hour/millisecond fields; trailing content
        // (e.g. WebVTT-style position cues) is ignored.
        let pattern = #"^(\d+):(\d{2}):(\d{2})[.,](\d{1,3})\s*-->\s*(\d+):(\d{2}):(\d{2})[.,](\d{1,3})"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    /// Parses SRT text. Tolerates: BOM, CRLF/LF, blank-line variations,
    /// `,` or `.` millisecond separator, missing/non-sequential indices,
    /// multi-line cue text (joined with a single space).
    /// If stripSpeakerPrefixes, removes leading "Name:" / "Speaker 1:" style
    /// prefixes (a short label, max ~24 chars, before the first colon) from cue text.
    static func parse(_ text: String, stripSpeakerPrefixes: Bool) throws -> [Segment] {
        var content = text
        if let scalar = content.unicodeScalars.first, scalar.value == 0xFEFF {
            content.removeFirst()
        }
        content = content.replacingOccurrences(of: "\r\n", with: "\n")
        content = content.replacingOccurrences(of: "\r", with: "\n")

        let rawLines = content.components(separatedBy: "\n")
        let n = rawLines.count
        var segments: [Segment] = []
        var i = 0

        func isBlank(_ s: String) -> Bool {
            s.trimmingCharacters(in: .whitespaces).isEmpty
        }

        while i < n {
            // Skip blank lines (tolerates 0+ blank lines between cues, extra
            // trailing blank lines, and no trailing blank line at EOF).
            while i < n, isBlank(rawLines[i]) { i += 1 }
            guard i < n else { break }

            var lineNo = i + 1
            var line = rawLines[i]

            if parseTimestampLine(line) == nil {
                // Not a timestamp: treat as a cue index line. The index value
                // itself is never inspected, so missing/non-numeric/
                // non-sequential indices are all tolerated equally.
                i += 1
                while i < n, isBlank(rawLines[i]) { i += 1 }
                guard i < n else {
                    throw SRTParseError.malformed(line: lineNo, reason: "expected a timestamp line after cue index")
                }
                lineNo = i + 1
                line = rawLines[i]
            }

            guard let (start, end) = parseTimestampLine(line) else {
                throw SRTParseError.malformed(line: lineNo, reason: "invalid timestamp line: \"\(line)\"")
            }
            i += 1

            var textLines: [String] = []
            while i < n, !isBlank(rawLines[i]) {
                textLines.append(rawLines[i].trimmingCharacters(in: .whitespaces))
                i += 1
            }

            var cueText = textLines.joined(separator: " ")
            if stripSpeakerPrefixes {
                cueText = strippingSpeakerPrefix(cueText)
            }

            segments.append(Segment(text: cueText, start: start, end: end))
        }

        return segments
    }

    /// Standard SRT output: index from 1, HH:MM:SS,mmm --> HH:MM:SS,mmm.
    static func serialize(_ segments: [Segment]) -> String {
        var lines: [String] = []
        lines.reserveCapacity(segments.count * 4)
        for (offset, segment) in segments.enumerated() {
            lines.append(String(offset + 1))
            lines.append("\(formatTimestamp(segment.start)) --> \(formatTimestamp(segment.end))")
            lines.append(segment.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Timestamps

    private static func parseTimestampLine(_ line: String) -> (TimeInterval, TimeInterval)? {
        let s = line.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let match = timestampRegex.firstMatch(in: s, range: range) else { return nil }

        func group(_ idx: Int) -> String {
            guard let r = Range(match.range(at: idx), in: s) else { return "" }
            return String(s[r])
        }

        guard let h1 = Int(group(1)), let m1 = Int(group(2)), let sec1 = Int(group(3)),
              let h2 = Int(group(5)), let m2 = Int(group(6)), let sec2 = Int(group(7)) else {
            return nil
        }
        let ms1 = paddedMilliseconds(group(4))
        let ms2 = paddedMilliseconds(group(8))

        let start = TimeInterval(h1) * 3600 + TimeInterval(m1) * 60 + TimeInterval(sec1) + TimeInterval(ms1) / 1000
        let end = TimeInterval(h2) * 3600 + TimeInterval(m2) * 60 + TimeInterval(sec2) + TimeInterval(ms2) / 1000
        return (start, end)
    }

    /// Normalizes a 1-3 digit millisecond field to a 3-digit value, e.g. "5" -> 500.
    private static func paddedMilliseconds(_ digits: String) -> Int {
        var s = digits
        while s.count < 3 { s.append("0") }
        if s.count > 3 { s = String(s.prefix(3)) }
        return Int(s) ?? 0
    }

    private static func formatTimestamp(_ t: TimeInterval) -> String {
        let clamped = max(0, t)
        let totalMillis = Int((clamped * 1000).rounded())
        let ms = totalMillis % 1000
        let totalSeconds = totalMillis / 1000
        let s = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let m = totalMinutes % 60
        let h = totalMinutes / 60
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    // MARK: - Speaker prefix stripping

    /// Strips a leading "Label:" prefix from cue text, provided the label
    /// (the text before the first colon) is short (<= 24 chars) and does not
    /// itself contain sentence-ending punctuation (i.e. it reads like a
    /// speaker name/tag, not the start of an ordinary sentence that happens
    /// to contain a colon).
    private static func strippingSpeakerPrefix(_ text: String) -> String {
        guard let colonRange = text.range(of: ":") else { return text }
        let label = text[text.startIndex..<colonRange.lowerBound].trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, label.count <= 24 else { return text }
        guard !label.contains(where: { $0 == "." || $0 == "!" || $0 == "?" }) else { return text }
        let rest = text[colonRange.upperBound...]
        return rest.trimmingCharacters(in: .whitespaces)
    }
}
