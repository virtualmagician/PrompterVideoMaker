import Foundation

enum OllamaError: LocalizedError {
    case notRunning
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Ollama isn't reachable at localhost:11434. Start the Ollama app (or `ollama serve`) and try again."
        case .badResponse(let detail):
            return "Unexpected response from Ollama: \(detail)"
        }
    }
}

/// Minimal client for a local Ollama server.
struct OllamaClient {
    var baseURL = URL(string: "http://localhost:11434")!

    private var session: URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 600
        cfg.timeoutIntervalForResource = 3600
        return URLSession(configuration: cfg)
    }

    /// Names of locally installed generative models (embedding models excluded).
    func installedModels() async throws -> [String] {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        req.timeoutInterval = 5
        let data: Data
        do {
            (data, _) = try await session.data(for: req)
        } catch {
            if Self.isCancellation(error) { throw CancellationError() }
            throw OllamaError.notRunning
        }
        struct Tags: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }
        let tags = try JSONDecoder().decode(Tags.self, from: data)
        return tags.models.map(\.name).filter { !$0.lowercased().contains("embed") }
    }

    func chat(model: String, system: String, user: String) async throws -> String {
        struct Message: Codable { let role: String; let content: String }
        struct Request: Codable {
            let model: String
            let messages: [Message]
            let stream: Bool
            let options: [String: Double]
        }
        struct Response: Decodable {
            struct Msg: Decodable { let content: String }
            let message: Msg
        }
        var req = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Request(
            model: model,
            messages: [Message(role: "system", content: system), Message(role: "user", content: user)],
            stream: false,
            options: ["temperature": 0.2]
        ))
        let data: Data
        do {
            (data, _) = try await session.data(for: req)
        } catch {
            if Self.isCancellation(error) { throw CancellationError() }
            throw OllamaError.notRunning
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data).message.content
        } catch {
            throw OllamaError.badResponse(String(data: data.prefix(300), encoding: .utf8) ?? "non-UTF8")
        }
    }

    /// URLSession reports Swift Task cancellation as URLError(.cancelled);
    /// preserve its identity so callers' CancellationError handling works.
    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}

/// Asks a local Ollama model to add spoken-delivery emphasis markup to the
/// script. The model can ONLY insert markers: every suggested line is
/// validated to be word-for-word identical to the original after stripping
/// markup, otherwise the original line is kept.
enum EmphasisSuggester {
    static let systemPrompt = """
    You choose which words of a teleprompter script deserve vocal stress.
    You are given numbered script lines. For each line that needs stress,
    pick the single word or short phrase (1-3 consecutive words, copied
    EXACTLY from that line) carrying the meaning of the sentence.
    Output ONLY lines of the form:
    N: exact words
    one per stressed line, nothing else. Skip lines that need no stress —
    most lines should be skipped. Never output words that are not in the line.
    """

    static func suggest(
        segments: [Segment],
        model: String,
        client: OllamaClient = OllamaClient(),
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [Segment] {
        var result = segments
        // Indices of lines worth sending (skip empty spacer segments).
        let candidates = segments.indices.filter {
            !segments[$0].text.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard !candidates.isEmpty else { return segments }

        let batchSize = 12
        let batches = stride(from: 0, to: candidates.count, by: batchSize).map {
            Array(candidates[$0..<min($0 + batchSize, candidates.count)])
        }

        // Run up to 3 batches concurrently; the model only echoes back the
        // lines it marks, which keeps generation short.
        let updates = try await withThrowingTaskGroup(
            of: [(Int, String)].self, returning: [(Int, String)].self
        ) { group in
            var all: [(Int, String)] = []
            var completed = 0
            var next = 0
            func launch(_ batch: [Int]) {
                group.addTask {
                    try Task.checkCancellation()
                    let numbered = batch.enumerated()
                        .map { pair in "\(pair.offset + 1)| \(EmphasisMarkup.strip(segments[pair.element].text))" }
                        .joined(separator: "\n")
                    let reply = try await client.chat(model: model, system: systemPrompt, user: numbered)
                    var updates: [(Int, String)] = []
                    for line in reply.split(separator: "\n") {
                        let parts = line.split(separator: ":", maxSplits: 1)
                        guard parts.count == 2,
                              let n = Int(String(parts[0]).trimmingCharacters(in: .whitespaces)),
                              n >= 1, n <= batch.count else { continue }
                        let segIndex = batch[n - 1]
                        let phrase = String(parts[1]).trimmingCharacters(in: .whitespaces)
                        // The model only NAMES the words; the app inserts the
                        // markers itself, so the text cannot be altered.
                        if let marked = Self.applyBold(phrase: phrase, to: segments[segIndex].text) {
                            updates.append((segIndex, marked))
                        }
                    }
                    return updates
                }
            }
            let concurrency = min(3, batches.count)
            while next < concurrency { launch(batches[next]); next += 1 }
            while let updates = try await group.next() {
                all.append(contentsOf: updates)
                completed += 1
                progress(Double(completed) / Double(batches.count))
                if next < batches.count { launch(batches[next]); next += 1 }
            }
            return all
        }
        for (segIndex, text) in updates {
            result[segIndex].text = text
        }
        return result
    }

    /// Bolds the first occurrence of `phrase` (case-insensitive, must match
    /// whole words) in the marked text's plain form; nil when the phrase
    /// isn't found. Existing markup is preserved.
    static func applyBold(phrase rawPhrase: String, to markedText: String) -> String? {
        let phrase = EmphasisMarkup.strip(rawPhrase)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”‘’*_="))
        guard !phrase.isEmpty,
              phrase.split(whereSeparator: { $0.isWhitespace }).count <= 4 else { return nil }
        let (plain, runs) = EmphasisMarkup.parse(markedText)
        let ns = plain as NSString
        var search = NSRange(location: 0, length: ns.length)
        while search.length > 0 {
            let found = ns.range(of: phrase, options: [.caseInsensitive], range: search)
            guard found.location != NSNotFound else { return nil }
            // Whole-word check on both edges.
            let beforeOK = found.location == 0
                || !isWordChar(ns.character(at: found.location - 1))
            let after = found.location + found.length
            let afterOK = after >= ns.length || !isWordChar(ns.character(at: after))
            if beforeOK && afterOK {
                var masks = EmphasisMarkup.characterAttributes(runs: runs, length: ns.length)
                for i in found.location..<after { masks[i].insert(.bold) }
                return EmphasisMarkup.serialize(plain: plain, characterAttributes: masks)
            }
            let nextLoc = found.location + 1
            search = NSRange(location: nextLoc, length: ns.length - nextLoc)
        }
        return nil
    }

    private static func isWordChar(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    /// Removes every emphasis marker from the script.
    static func clear(segments: [Segment]) -> [Segment] {
        var result = segments
        for i in result.indices {
            result[i].text = EmphasisMarkup.strip(result[i].text)
        }
        return result
    }
}
