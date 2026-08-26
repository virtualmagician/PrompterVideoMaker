import Foundation
import Combine
import AVFoundation
import CoreAudio
import AudioToolbox
import os.log

private let audioRecorderLog = Logger(subsystem: "com.marcotempest.PrompterVideoMaker", category: "audio")

/// The live meter values, isolated from AudioRecorder's slow state.
@MainActor
final class AudioMeter: ObservableObject {
    @Published fileprivate(set) var level: Float = 0
    @Published fileprivate(set) var levelHistory: [Float] = []
    @Published fileprivate(set) var elapsed: TimeInterval = 0
}

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

/// One CoreAudio input-capable device, as offered to the user in the
/// microphone picker.
struct AudioInputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let uid: String
}

/// A tiny lock-protected box holding the `AVAudioFile` currently being
/// written to (if any). The record tap runs on a real-time audio thread, not
/// the main actor, so the file reference it writes through can't be a plain
/// `@MainActor`-isolated stored property — reads/writes here are protected by
/// an `NSLock` instead, independent of Swift's actor-isolation checking.
private final class AudioFileBox: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?

    var current: AVAudioFile? {
        lock.lock()
        defer { lock.unlock() }
        return file
    }

    func set(_ newFile: AVAudioFile?) {
        lock.lock()
        file = newFile
        lock.unlock()
    }
}

/// Monitors the selected input device continuously (from the moment the
/// Record Timing pane opens) and optionally writes that same tap to a WAV
/// file while recording. Publishes a live elapsed time, level meter, and
/// level history for the record-and-align UI.
@MainActor
final class AudioRecorder: ObservableObject {
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var isMonitoring: Bool = false
    /// High-frequency meter values live on their own ObservableObject so
    /// only the small meter views re-render 20x/sec — re-rendering the whole
    /// Record pane at that rate destabilizes open menus (observed SEGV in
    /// SwiftUI's MenuItemCallback when the pane thrashes under an open menu).
    let meter = AudioMeter()
    /// Ring buffer of recent smoothed levels, oldest first, capped at
    /// UID of the CoreAudio input device to use, or nil for the system
    /// default. Change via `setDevice(uid:)`, not directly.
    @Published private(set) var selectedDeviceUID: String?
    /// Last monitoring failure (engine start, device switch, device loss);
    /// nil while the meter is healthy.
    @Published private(set) var monitorError: String?
    /// Set when a device configuration change killed an in-progress take.
    @Published private(set) var recordingInterrupted = false

    private let engine = AVAudioEngine()
    private nonisolated let fileBox = AudioFileBox()
    private var recordingURL: URL?
    private var startDate: Date?
    private var elapsedTimer: Timer?

    private static let levelHistoryCap = 240
    private static let deviceUIDDefaultsKey = "PVMInputDeviceUID"

    private var configObserver: (any NSObjectProtocol)?

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.deviceUIDDefaultsKey)
        selectedDeviceUID = (stored?.isEmpty ?? true) ? nil : stored
        // A device unplug/replug stops the engine and posts this
        // notification; rebuild the graph so the meter (and any take) never
        // dies silently.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleConfigurationChange() }
        }
    }

    deinit {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
    }

    private func handleConfigurationChange() {
        guard isMonitoring else { return }
        let wasRecording = isRecording
        stopMonitoring()
        do {
            try startMonitoring()
            if wasRecording {
                monitorError = "The audio device changed — the take was interrupted."
            }
        } catch {
            monitorError = error.localizedDescription
        }
        if wasRecording {
            recordingInterrupted = true
        }
    }

    // MARK: - Device enumeration

    /// Enumerates CoreAudio devices that expose at least one input stream.
    /// Any device that fails a property lookup along the way is skipped
    /// rather than aborting the whole listing.
    static func availableInputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        )
        guard status == noErr, dataSize > 0 else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard deviceCount > 0 else { return [] }
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        )
        guard status == noErr else { return [] }

        var result: [AudioInputDevice] = []
        for deviceID in deviceIDs {
            guard hasInputStreams(deviceID) else { continue }
            guard let name = stringProperty(deviceID, selector: kAudioObjectPropertyName) else { continue }
            guard let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID) else { continue }
            result.append(AudioInputDevice(id: deviceID, name: name, uid: uid))
        }
        return result
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard status == noErr else { return false }
        return dataSize / UInt32(MemoryLayout<AudioStreamID>.size) > 0
    }

    private static func stringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, ptr)
        }
        guard status == noErr else { return nil }
        return value as String
    }

    /// Points the given input node's audio unit at the device matching
    /// `uid`. Silently does nothing if the device is no longer present
    /// (e.g. unplugged since it was selected) so monitoring/recording falls
    /// back to whatever the input node already has. Throws only if the
    /// device IS found but CoreAudio refuses to select it.
    private static func applyInputDevice(uid: String, to node: AVAudioInputNode) throws {
        guard let match = availableInputDevices().first(where: { $0.uid == uid }) else { return }
        guard let audioUnit = node.audioUnit else { return }
        var deviceID = match.id
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Could not select the chosen microphone (OSStatus \(status))."]
            )
        }
    }

    // MARK: - Device selection

    /// Stores and persists the chosen input device (nil = system default).
    /// Ignored while actively recording — switching devices mid-take would
    /// desync the file's format from the tap. If currently monitoring
    /// (but not recording), monitoring is restarted on the new device.
    func setDevice(uid: String?) {
        let normalized = (uid?.isEmpty ?? true) ? nil : uid
        guard normalized != selectedDeviceUID else { return }
        guard !isRecording else { return }

        selectedDeviceUID = normalized
        if let normalized {
            UserDefaults.standard.set(normalized, forKey: Self.deviceUIDDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.deviceUIDDefaultsKey)
        }

        // Restart whenever the pane wants a live meter — including after a
        // previous failure, so picking a working device revives it.
        guard isMonitoring || monitorError != nil else { return }
        stopMonitoring()
        do {
            try startMonitoring()
        } catch {
            monitorError = error.localizedDescription
            audioRecorderLog.error("Failed to restart monitoring after device change: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Monitoring (live meter, no file)

    /// Starts the engine and installs the level/waveform tap without
    /// creating a file. Safe to call repeatedly (no-ops if already
    /// monitoring). The system microphone permission prompt is triggered
    /// automatically by `engine.start()`.
    func startMonitoring() throws {
        guard !isMonitoring else { return }

        let input = engine.inputNode

        if let uid = selectedDeviceUID {
            do {
                try Self.applyInputDevice(uid: uid, to: input)
            } catch {
                throw AudioRecorderError.engineStartFailed(underlying: error)
            }
        }

        // Read the tap format AFTER the device has been applied above, since
        // a different device can have a different native sample rate/channel
        // count.
        let format = input.outputFormat(forBus: 0)

        input.removeTap(onBus: 0)
        let box = fileBox
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            if let file = box.current {
                try? file.write(from: buffer)
            }
            let rms = Self.rms(of: buffer)
            Task { @MainActor in
                guard let self else { return }
                let smoothed = self.meter.level * 0.7 + min(1, max(0, rms * 6)) * 0.3
                self.meter.level = smoothed
                self.meter.levelHistory.append(smoothed)
                if self.meter.levelHistory.count > Self.levelHistoryCap {
                    self.meter.levelHistory.removeFirst(self.meter.levelHistory.count - Self.levelHistoryCap)
                }
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioRecorderError.engineStartFailed(underlying: error)
        }

        isMonitoring = true
        monitorError = nil
    }

    /// Full teardown: removes the tap, stops the engine, clears the meter.
    /// If a recording happened to still be in progress, it's stopped (and
    /// its file closed) first.
    func stopMonitoring() {
        if isRecording {
            _ = stop()
        }
        guard isMonitoring else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isMonitoring = false
        meter.level = 0
        meter.levelHistory.removeAll()
    }

    // MARK: - Recording (adds a file on top of monitoring)

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

    /// Starts recording. Ensures monitoring (and therefore the engine/tap)
    /// is already running first, then opens a WAV file on the input node's
    /// current (native) format so no sample-rate/channel conversion happens
    /// on the audio thread. `elapsed` is measured from the start of
    /// recording, not from when monitoring began.
    func start() throws {
        guard !isRecording else { return }

        if !isMonitoring {
            try startMonitoring()
        }

        let url: URL
        do {
            url = try Self.newRecordingURL()
        } catch {
            throw AudioRecorderError.fileCreateFailed(underlying: error)
        }

        let format = engine.inputNode.outputFormat(forBus: 0)
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

        fileBox.set(file)
        recordingURL = url
        recordingInterrupted = false
        isRecording = true
        meter.elapsed = 0
        startDate = Date()

        elapsedTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startDate else { return }
                self.meter.elapsed = Date().timeIntervalSince(start)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    /// Stops WRITING and closes the file, but leaves monitoring (the engine
    /// and tap) running so the pane keeps showing a live meter. Returns the
    /// recorded file's URL (nil if a recording wasn't in progress).
    @discardableResult
    func stop() -> URL? {
        guard isRecording else { return nil }
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        fileBox.set(nil)
        let url = recordingURL
        recordingURL = nil
        startDate = nil
        isRecording = false
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
