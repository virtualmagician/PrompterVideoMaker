import Foundation
import Combine
import AVFoundation

enum AudioRecorderError: LocalizedError {
    case engineStartFailed(underlying: Error)
    case fileCreateFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .engineStartFailed:
            return "Could not start the microphone. Check System Settings > Privacy & Security > Microphone and make sure PrompterVideoMaker is allowed to record audio."
        case .fileCreateFailed(let underlying):
            return "Could not create the recording file: \(underlying.localizedDescription)"
        }
    }
}

/// Records the default input device to a WAV file while publishing a live
/// elapsed time and input-level meter for the record-and-align UI.
@MainActor
final class AudioRecorder: ObservableObject {
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0

    private let engine = AVAudioEngine()
    private var outputFile: AVAudioFile?
    private var recordingURL: URL?
    private var startDate: Date?
    private var elapsedTimer: Timer?

    /// ~/Library/Application Support/PrompterVideoMaker/Recordings, created
    /// on demand.
    private static func recordingsDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport
            .appendingPathComponent("PrompterVideoMaker", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func newRecordingURL() throws -> URL {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMdd-HHmmss"
        let name = "rec-\(df.string(from: Date())).wav"
        return try recordingsDirectory().appendingPathComponent(name)
    }

    /// Starts recording the default input device. The system microphone
    /// permission prompt is triggered automatically by `engine.start()`; if
    /// permission was previously denied, the engine fails to start and this
    /// throws a descriptive error.
    func start() throws {
        guard !isRecording else { return }

        let url: URL
        do {
            url = try Self.newRecordingURL()
        } catch {
            throw AudioRecorderError.fileCreateFailed(underlying: error)
        }

        let input = engine.inputNode
        // Use the input's own (native) format for both the tap and the file
        // so no sample-rate/channel conversion happens on the audio thread.
        let format = input.outputFormat(forBus: 0)

        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forWriting: url,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
        } catch {
            throw AudioRecorderError.fileCreateFailed(underlying: error)
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            try? file.write(from: buffer)
            let rms = Self.rms(of: buffer)
            Task { @MainActor in
                self?.level = (self?.level ?? 0) * 0.7 + min(1, max(0, rms * 6)) * 0.3
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioRecorderError.engineStartFailed(underlying: error)
        }

        outputFile = file
        recordingURL = url
        isRecording = true
        elapsed = 0
        level = 0
        startDate = Date()

        elapsedTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startDate else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    /// Stops the engine, closes the file, and returns its URL (nil if a
    /// recording wasn't in progress).
    @discardableResult
    func stop() -> URL? {
        guard isRecording else { return nil }
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        outputFile = nil
        let url = recordingURL
        recordingURL = nil
        startDate = nil
        isRecording = false
        level = 0
        return url
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0, channelCount > 0 else { return 0 }
        var sum: Float = 0
        for ch in 0..<channelCount {
            let samples = data[ch]
            for i in 0..<frameLength {
                let s = samples[i]
                sum += s * s
            }
        }
        return sqrt(sum / Float(frameLength * channelCount))
    }
}
