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
            throw OllamaError.notRunning
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data).message.content
        } catch {
            throw OllamaError.badResponse(String(data: data.prefix(300), encoding: .utf8) ?? "non-UTF8")
        }
    }
}

/// Asks a local Ollama model to add spoken-delivery emphasis markup to the
/// script. The model can ONLY insert markers: every suggested line is
/// validated to be word-for-word identical to the original after stripping
/// markup, otherwise the original line is kept.
enum EmphasisSuggester {
    static let systemPrompt = """
    You mark up teleprompter scripts to help a speaker deliver them well.
    You are given numbered script lines. Return the SAME numbered lines, adding:
    - **double asterisks** around 1-3 words that deserve vocal stress (the words carrying the meaning of the sentence), and
    - __double underscores__ around words that need careful enunciation (names, numbers, technical terms, foreign words).
    Rules:
    - NEVER change, add, remove, or reorder any words or punctuation. Only insert ** or __ markers.
    - Markers must directly touch the words: **like this**, never ** like this **.
    - Be sparing. Many lines need no markers at all; a line should never have more than 3 marked spans.
    - Output ONLY the numbered lines, one per line, in the same "N| text" format. No commentary.
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

        let batchSize = 20
        let batches = stride(from: 0, to: candidates.count, by: batchSize).map {
            Array(candidates[$0..<min($0 + batchSize, candidates.count)])
        }

        var done = 0
        for batch in batches {
            try Task.checkCancellation()
            let numbered = batch.enumerated()
                .map { pair in "\(pair.offset + 1)| \(EmphasisMarkup.strip(segments[pair.element].text))" }
                .joined(separator: "\n")
            let reply = try await client.chat(model: model, system: systemPrompt, user: numbered)

            // Parse "N| text" lines from the reply.
            var suggestions: [Int: String] = [:]
            for line in reply.split(separator: "\n") {
                let parts = line.split(separator: "|", maxSplits: 1)
                guard parts.count == 2,
                      let n = Int(String(parts[0]).trimmingCharacters(in: .whitespaces)),
                      n >= 1, n <= batch.count else { continue }
                suggestions[n - 1] = String(parts[1]).trimmingCharacters(in: .whitespaces)
            }

            for (offset, segIndex) in batch.enumerated() {
                guard let suggested = suggestions[offset] else { continue }
                let original = segments[segIndex].text
                // Safety gate: markup must be the only difference.
                if EmphasisMarkup.plainEquivalent(suggested, original),
                   suggested != EmphasisMarkup.strip(suggested) {
                    result[segIndex].text = suggested
                }
            }

            done += batch.count
            progress(Double(done) / Double(candidates.count))
        }
        return result
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
