import Testing
import Foundation
import AVFoundation
@testable import PrompterVideoMaker

@Suite struct AudioWaveformTests {
    @Test func computesEnvelopeOfSyntheticTone() throws {
        // 2 s file: 1 s of 440 Hz sine at 0.8 amplitude, then 1 s of silence.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wave-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let sr = 48_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        // Scope the writer so it flushes/closes before the reader opens.
        try {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let frames = AVAudioFrameCount(sr * 2)
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buf.frameLength = frames
            let data = buf.floatChannelData![0]
            for i in 0..<Int(frames) {
                let t = Double(i) / sr
                data[i] = t < 1.0 ? Float(0.8 * sin(2 * .pi * 440 * t)) : 0
            }
            try file.write(from: buf)
        }()

        let wave = try AudioWaveform.compute(url: url, bucketsPerSecond: 50)
        #expect(abs(wave.duration - 2.0) < 0.1)
        #expect(wave.peak(from: 0.2, to: 0.8) > 0.7)
        #expect(wave.peak(from: 1.2, to: 1.8) < 0.01)
    }
}
