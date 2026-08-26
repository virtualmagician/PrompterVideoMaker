import Foundation
import AVFoundation

/// Downsampled peak envelope of an audio file, for drawing a waveform track.
/// Bucket k covers time [k, k+1) / bucketsPerSecond, aligned with the script
/// timeline (audio t = script t).
struct AudioWaveform: Equatable {
    let buckets: [Float]
    let bucketsPerSecond: Int

    var duration: Double { Double(buckets.count) / Double(bucketsPerSecond) }

    /// Peak-abs downsampling, reading the file in chunks so memory stays flat
    /// for long recordings.
    static func compute(url: URL, bucketsPerSecond: Int = 50) throws -> AudioWaveform {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate > 0, file.length > 0 else {
            return AudioWaveform(buckets: [], bucketsPerSecond: bucketsPerSecond)
        }
        let framesPerBucket = max(1, Int(sampleRate) / bucketsPerSecond)
        let totalBuckets = Int(file.length) / framesPerBucket + 1
        var buckets = [Float](repeating: 0, count: totalBuckets)

        let chunkFrames: AVAudioFrameCount = 262_144
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            return AudioWaveform(buckets: [], bucketsPerSecond: bucketsPerSecond)
        }

        var frameOffset = 0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunkFrames)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            let channels = Int(format.channelCount)
            if let data = buffer.floatChannelData {
                for ch in 0..<channels {
                    let samples = data[ch]
                    for i in 0..<n {
                        let bucket = (frameOffset + i) / framesPerBucket
                        if bucket < totalBuckets {
                            let v = abs(samples[i])
                            if v > buckets[bucket] { buckets[bucket] = v }
                        }
                    }
                }
            }
            frameOffset += n
        }

        // Trim trailing silence-only zero buckets past the data.
        while let last = buckets.last, last == 0, buckets.count > frameOffset / framesPerBucket + 1 {
            buckets.removeLast()
        }
        return AudioWaveform(buckets: buckets, bucketsPerSecond: bucketsPerSecond)
    }

    /// Peak for a script-time range (for drawing one pixel column).
    func peak(from t0: Double, to t1: Double) -> Float {
        guard !buckets.isEmpty, t1 > t0 else { return 0 }
        let lo = max(0, Int(t0 * Double(bucketsPerSecond)))
        let hi = min(buckets.count, max(lo + 1, Int(t1 * Double(bucketsPerSecond)) + 1))
        guard lo < hi else { return 0 }
        var m: Float = 0
        for i in lo..<hi where buckets[i] > m { m = buckets[i] }
        return m
    }
}
