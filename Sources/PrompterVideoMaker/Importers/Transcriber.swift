import Foundation
import AVFoundation
import Speech
import CoreMedia

enum TranscriberError: LocalizedError {
    case localeUnsupported
    case notAuthorized
    case recognizerUnavailable
    case noSpeechFound

    var errorDescription: String? {
        switch self {
        case .localeUnsupported: return "No supported transcription language found on this Mac."
        case .notAuthorized: return "Speech recognition permission was not granted."
        case .recognizerUnavailable: return "The speech recognizer is not available on this Mac."
        case .noSpeechFound: return "No speech was detected in the audio file."
        }
    }
}

/// On-device audio → timed script segments.
/// macOS 26+: the new SpeechAnalyzer/SpeechTranscriber API (word-level timings).
/// macOS 15: SFSpeechRecognizer with on-device recognition.
enum Transcriber {

    /// A recognized word with its audio time range.
    struct TimedWord {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    /// Raw recognized words with timestamps (used directly by the
    /// script/recording aligner).
    static func timedWords(audioURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedWord] {
        if #available(macOS 26.0, *) {
            return try await transcribeModern(audioURL: audioURL, progress: progress)
        } else {
            return try await transcribeLegacy(audioURL: audioURL, progress: progress)
        }
    }

    static func transcribe(audioURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [Segment] {
        let words = try await timedWords(audioURL: audioURL, progress: progress)
        guard !words.isEmpty else { throw TranscriberError.noSpeechFound }
        return group(words: words)
    }

    // MARK: - macOS 26 SpeechAnalyzer path

    @available(macOS 26.0, *)
    private static func transcribeModern(audioURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedWord] {
        var resolvedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
        if resolvedLocale == nil {
            resolvedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US"))
        }
        guard let locale = resolvedLocale else {
            throw TranscriberError.localeUnsupported
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        // Download the on-device model if it isn't installed yet.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            progress(0.02)
            try await request.downloadAndInstall()
        }

        let audioFile = try AVAudioFile(forReading: audioURL)
        let audioDuration = Double(audioFile.length) / audioFile.processingFormat.sampleRate

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let collector = Task<[TimedWord], Error> {
            var words: [TimedWord] = []
            for try await result in transcriber.results {
                let attr = result.text
                for run in attr.runs {
                    guard let timeRange = run.audioTimeRange else { continue }
                    let text = String(attr[run.range].characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let start = timeRange.start.seconds
                    let end = timeRange.end.seconds
                    words.append(TimedWord(text: text, start: start, end: end))
                    if audioDuration > 0 {
                        progress(min(0.98, 0.05 + 0.93 * (end / audioDuration)))
                    }
                }
            }
            return words
        }

        do {
            if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            }
        } catch {
            collector.cancel()
            throw error
        }

        let words = try await collector.value
        progress(1.0)
        return words.sorted { $0.start < $1.start }
    }

    // MARK: - macOS 15 SFSpeechRecognizer fallback

    private static func transcribeLegacy(audioURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedWord] {
        let auth = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard auth == .authorized else { throw TranscriberError.notAuthorized }

        guard let recognizer = SFSpeechRecognizer(locale: Locale.current)
                ?? SFSpeechRecognizer(locale: Locale(identifier: "en_US")),
              recognizer.isAvailable else {
            throw TranscriberError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        request.addsPunctuation = true

        let asset = AVURLAsset(url: audioURL)
        let audioDuration = (try? await asset.load(.duration).seconds) ?? 0

        return try await withCheckedThrowingContinuation { cont in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                if finished { return }
                if let error {
                    finished = true
                    cont.resume(throwing: error)
                    return
                }
                guard let result else { return }
                if audioDuration > 0, let last = result.bestTranscription.segments.last {
                    progress(min(0.98, (last.timestamp + last.duration) / audioDuration))
                }
                if result.isFinal {
                    finished = true
                    let words = result.bestTranscription.segments.map {
                        TimedWord(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration)
                    }
                    progress(1.0)
                    cont.resume(returning: words)
                }
            }
        }
    }

    // MARK: - Grouping words into prompter cues

    /// Groups timed words into readable cues: break on sentence-ending
    /// punctuation, on silence gaps > 0.7 s, or when a cue reaches 14 words.
    private static func group(words: [TimedWord]) -> [Segment] {
        var segments: [Segment] = []
        var current: [TimedWord] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined(separator: " ")
                .replacingOccurrences(of: " ,", with: ",")
                .replacingOccurrences(of: " .", with: ".")
                .replacingOccurrences(of: " ?", with: "?")
                .replacingOccurrences(of: " !", with: "!")
            segments.append(Segment(text: text, start: first.start, end: last.end))
            current = []
        }

        for (i, word) in words.enumerated() {
            current.append(word)
            let endsSentence = word.text.hasSuffix(".") || word.text.hasSuffix("!") || word.text.hasSuffix("?")
            let bigGap: Bool = {
                guard i + 1 < words.count else { return false }
                return words[i + 1].start - word.end > 0.7
            }()
            if endsSentence || bigGap || current.count >= 14 {
                flush()
            }
        }
        flush()
        return segments
    }
}
