import Foundation

/// One short "sense" chunk of prompter text with its alternating color slot.
struct TextChunk: Equatable {
    let text: String
    /// 0 = primary color, 1 = secondary color.
    let colorIndex: Int
}

/// Splits segment text into short chunks for alternating-color prompter display.
enum Chunker {

    /// Splits each segment's text into short "sense" chunks of at most
    /// maxWords words, breaking preferentially at sentence enders (. ! ?),
    /// then at , ; : — then hard word-count splits. Color alternation is
    /// GLOBAL: it continues across segments (chunk N+1 anywhere in the script
    /// has the other color of chunk N). If alternate == false every chunk has
    /// colorIndex 0. Chunk texts of one segment joined by " " must equal the
    /// segment text (no characters lost).
    static func chunks(for segments: [Segment], maxWords: Int, alternate: Bool) -> [[TextChunk]] {
        let limit = max(1, maxWords)
        var globalIndex = 0
        var result: [[TextChunk]] = []
        result.reserveCapacity(segments.count)

        for segment in segments {
            let words = segment.text.isEmpty
                ? []
                : segment.text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            let wordGroups = splitIntoWordGroups(words, maxWords: limit)

            var segmentChunks: [TextChunk] = []
            segmentChunks.reserveCapacity(wordGroups.count)
            for group in wordGroups {
                let colorIndex = alternate ? (globalIndex % 2) : 0
                segmentChunks.append(TextChunk(text: group.joined(separator: " "), colorIndex: colorIndex))
                globalIndex += 1
            }
            result.append(segmentChunks)
        }

        return result
    }

    // MARK: - Word grouping

    /// Groups words into chunks of at most `maxWords` words each. Within the
    /// window of up to `maxWords` words available for the next chunk, the
    /// break point is chosen by priority: the last word ending a sentence
    /// (. ! ?), else the last word ending a clause (, ; :), else a hard cut
    /// at the window boundary.
    private static func splitIntoWordGroups(_ words: [String], maxWords: Int) -> [[String]] {
        guard !words.isEmpty else { return [] }
        var groups: [[String]] = []
        var start = 0
        let n = words.count

        while start < n {
            // Overflow-safe form of min(start + maxWords, n).
            let windowEnd = maxWords >= n - start ? n : start + maxWords // exclusive

            var breakAt: Int? = nil
            for i in stride(from: windowEnd - 1, through: start, by: -1) {
                if endsSentence(words[i]) { breakAt = i + 1; break }
            }
            if breakAt == nil {
                for i in stride(from: windowEnd - 1, through: start, by: -1) {
                    if endsClause(words[i]) { breakAt = i + 1; break }
                }
            }
            let cut = breakAt ?? windowEnd
            groups.append(Array(words[start..<cut]))
            start = cut
        }

        return groups
    }

    private static func endsSentence(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return last == "." || last == "!" || last == "?"
    }

    private static func endsClause(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return last == "," || last == ";" || last == ":"
    }
}
