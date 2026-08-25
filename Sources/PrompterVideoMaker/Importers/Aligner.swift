import Foundation

/// Aligns a known script against the words recognized in a recording of the
/// user reading it, and derives per-segment timings from the match.
///
/// Because the target text is known, this is far more robust than free
/// transcription: recognition errors, stumbles, and skipped or repeated words
/// only weaken individual matches instead of corrupting the text.
enum Aligner {

    struct Result {
        /// Same segments (ids/texts preserved) with timings from the recording.
        let segments: [Segment]
        /// Fraction of script words that found a match in the recognition.
        let matchRate: Double
    }

    // MARK: - Tokenization

    private struct Token {
        let normalized: String
        let segmentIndex: Int
    }

    private static func normalize(_ word: some StringProtocol) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func fuzzyEqual(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        // Allow one edit for words of 4+ chars (ASR variance: plurals, endings).
        guard a.count >= 4, b.count >= 4, abs(a.count - b.count) <= 1 else { return false }
        return editDistanceAtMostOne(a, b)
    }

    private static func editDistanceAtMostOne(_ a: String, _ b: String) -> Bool {
        let ac = Array(a), bc = Array(b)
        if ac.count == bc.count {
            var diffs = 0
            for i in 0..<ac.count where ac[i] != bc[i] {
                diffs += 1
                if diffs > 1 { return false }
            }
            return true
        }
        // Lengths differ by 1: check single insertion.
        let (short, long) = ac.count < bc.count ? (ac, bc) : (bc, ac)
        var i = 0, j = 0, used = false
        while i < short.count && j < long.count {
            if short[i] == long[j] {
                i += 1; j += 1
            } else {
                if used { return false }
                used = true
                j += 1
            }
        }
        return true
    }

    // MARK: - Alignment

    /// Needleman–Wunsch global alignment of script tokens vs recognized
    /// tokens, then segment timings from the matched words.
    static func align(script: Script, words: [Transcriber.TimedWord]) -> Result {
        // Script tokens tagged with their segment.
        var tokens: [Token] = []
        for (si, seg) in script.segments.enumerated() {
            for w in seg.text.split(whereSeparator: { $0.isWhitespace }) {
                let n = normalize(w)
                if !n.isEmpty { tokens.append(Token(normalized: n, segmentIndex: si)) }
            }
        }
        let rec: [(norm: String, start: Double, end: Double)] = words.compactMap {
            let n = normalize($0.text)
            return n.isEmpty ? nil : (n, $0.start, $0.end)
        }

        guard !tokens.isEmpty, !rec.isEmpty else {
            return Result(segments: script.segments, matchRate: 0)
        }

        let n = tokens.count, m = rec.count
        let gap = -1, mismatch = -1, matchExact = 2, matchFuzzy = 1

        // DP score + backtrack direction (0 diag, 1 up/script-gap, 2 left/rec-gap).
        var score = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        var back = [[UInt8]](repeating: [UInt8](repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n { score[i][0] = i * gap; back[i][0] = 1 }
        for j in 1...m { score[0][j] = j * gap; back[0][j] = 2 }
        for i in 1...n {
            for j in 1...m {
                let exact = tokens[i - 1].normalized == rec[j - 1].norm
                let fuzzy = exact || fuzzyEqual(tokens[i - 1].normalized, rec[j - 1].norm)
                let diagScore = score[i - 1][j - 1] + (exact ? matchExact : (fuzzy ? matchFuzzy : mismatch))
                let upScore = score[i - 1][j] + gap
                let leftScore = score[i][j - 1] + gap
                if diagScore >= upScore && diagScore >= leftScore {
                    score[i][j] = diagScore; back[i][j] = 0
                } else if upScore >= leftScore {
                    score[i][j] = upScore; back[i][j] = 1
                } else {
                    score[i][j] = leftScore; back[i][j] = 2
                }
            }
        }

        // Backtrack, keeping only genuinely matching diagonal steps.
        var matched: [(tokenIdx: Int, recIdx: Int)] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            switch back[i][j] {
            case 0:
                let ok = tokens[i - 1].normalized == rec[j - 1].norm
                    || fuzzyEqual(tokens[i - 1].normalized, rec[j - 1].norm)
                if ok { matched.append((i - 1, j - 1)) }
                i -= 1; j -= 1
            case 1: i -= 1
            default: j -= 1
            }
        }
        matched.reverse()

        // Per-segment: first/last matched recognized word give start/end.
        var starts = [Double?](repeating: nil, count: script.segments.count)
        var ends = [Double?](repeating: nil, count: script.segments.count)
        for (ti, ri) in matched {
            let si = tokens[ti].segmentIndex
            if starts[si] == nil { starts[si] = rec[ri].start }
            ends[si] = rec[ri].end
        }

        // Interpolate any unmatched segments between their timed neighbors.
        var segments = script.segments
        let total = segments.count
        for si in 0..<total where starts[si] == nil {
            let prevEnd: Double = {
                for k in stride(from: si - 1, through: 0, by: -1) {
                    if let e = ends[k] { return e }
                }
                return rec.first?.start ?? 0
            }()
            let nextStart: Double = {
                for k in (si + 1)..<total {
                    if let s = starts[k] { return s }
                }
                return rec.last?.end ?? prevEnd + 2
            }()
            // Share the hole among consecutive unmatched segments by word count.
            var holeIndices: [Int] = [si]
            var k = si + 1
            while k < total, starts[k] == nil { holeIndices.append(k); k += 1 }
            let wordCounts = holeIndices.map {
                max(1, segments[$0].text.split(whereSeparator: { $0.isWhitespace }).count)
            }
            let totalWords = Double(wordCounts.reduce(0, +))
            let span = max(0.5, nextStart - prevEnd)
            // ASR end timestamps can overrun the next word's start; starting
            // the hole later than nextStart would let normalize()'s sort
            // reorder segments. Clamp so script order is always preserved.
            var cursor = min(prevEnd, nextStart)
            for (idx, h) in holeIndices.enumerated() {
                let share = span * Double(wordCounts[idx]) / totalWords
                starts[h] = cursor
                ends[h] = cursor + share
                cursor += share
            }
        }

        for si in 0..<total {
            segments[si].start = starts[si] ?? 0
            segments[si].end = max(ends[si] ?? segments[si].start, segments[si].start)
        }

        var result = Script(segments: segments)
        result.normalize()
        let matchRate = Double(Set(matched.map { $0.tokenIdx }).count) / Double(tokens.count)
        return Result(segments: result.segments, matchRate: matchRate)
    }
}
