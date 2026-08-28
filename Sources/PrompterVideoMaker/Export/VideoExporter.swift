import Foundation
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo

enum VideoExportError: LocalizedError {
    case cannotStartWriting(Error?)
    case pixelBufferPoolUnavailable
    case pixelBufferCreationFailed(CVReturn)
    case contextCreationFailed
    case sampleBufferTimingFailed
    case writerFailed(Error?)
    case audioTrackMissing

    var errorDescription: String? {
        switch self {
        case .cannotStartWriting(let err): return "Could not start writing the video file: \(err?.localizedDescription ?? "unknown error")."
        case .pixelBufferPoolUnavailable: return "The video writer's pixel buffer pool was unavailable."
        case .pixelBufferCreationFailed(let status): return "Could not create a pixel buffer (CVReturn \(status))."
        case .contextCreationFailed: return "Could not create a CoreGraphics context for a video frame."
        case .sampleBufferTimingFailed: return "Could not retime an audio sample buffer."
        case .writerFailed(let err): return "Video writing failed: \(err?.localizedDescription ?? "unknown error")."
        case .audioTrackMissing: return "The audio file has no audio track."
        }
    }
}

/// Renders `composition` to an H.264 .mp4 (1920x1080, BT.709) using
/// AVAssetWriter, optionally muxing in AAC audio decoded from `audioURL`.
final class VideoExporter {
    private let composition: PrompterComposition
    private let audioURL: URL?
    private let outputURL: URL
    private let titleCard: TitleCardInfo?

    init(composition: PrompterComposition, audioURL: URL?, outputURL: URL, titleCard: TitleCardInfo? = nil) {
        self.composition = composition
        self.audioURL = audioURL
        self.outputURL = outputURL
        self.titleCard = titleCard
    }

    /// 1 when the slate frame is prepended; the whole timeline (audio
    /// included) shifts by this many frames so cue timings stay exact.
    private var slateFrames: Int {
        titleCard != nil && composition.style.resolvedTitleCardEnabled ? 1 : 0
    }

    private var slateSeconds: Double {
        Double(slateFrames) / Double(max(1, composition.style.fps))
    }

    /// H.264 .mp4, 1920x1080, composition.style.fps (30 or 60), ~12 Mbps,
    /// BT.709. Video length = composition.videoDuration. If an audio URL is
    /// provided and style.includeAudio, decodes it via AVAssetReader and
    /// encodes AAC 48kHz stereo, placed so audio t=0 aligns with video
    /// t=leadIn. Renders frames via composition.draw into pixel buffers
    /// drawn from the pixel buffer adaptor's pool, wrapping each frame in
    /// autoreleasepool and pacing generation to the writer's readiness so
    /// memory stays bounded on very long exports.
    func export(progress: @escaping @Sendable (Double) -> Void) async throws {
        let style = composition.style
        let fps = max(1, style.fps)
        let width = Int(StyleSettings.canvasWidth)
        let height = Int(StyleSettings.canvasHeight)

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        // NOTE: AVVideoColorPropertiesKey must be a TOP-LEVEL key of the output
        // settings dictionary (a sibling of AVVideoCompressionPropertiesKey),
        // not nested inside it — nesting it throws
        // "Compression property AVVideoColorPropertiesKey is not supported
        // for video codec type avc1" at AVAssetWriterInput init time.
        var compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: composition.style.videoBitrate
        ]
        if composition.style.resolvedCodec == .h264 {
            compressionProperties[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        let colorProperties: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: composition.style.resolvedCodec == .hevc
                ? AVVideoCodecType.hevc
                : AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compressionProperties,
            AVVideoColorPropertiesKey: colorProperties
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )
        guard writer.canAdd(videoInput) else { throw VideoExportError.cannotStartWriting(writer.error) }
        writer.add(videoInput)

        // Optional audio.
        var audioInput: AVAssetWriterInput?
        var assetReader: AVAssetReader?
        var readerOutput: AVAssetReaderTrackOutput?
        var audioDurationSeconds: Double = 0
        if let audioURL, style.includeAudio {
            let asset = AVURLAsset(url: audioURL)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let track = tracks.first else { throw VideoExportError.audioTrackMissing }
            audioDurationSeconds = try await asset.load(.duration).seconds

            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM
            ])
            output.alwaysCopiesSampleData = false
            reader.add(output)

            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: StyleSettings.audioBitrate
            ])
            aInput.expectsMediaDataInRealTime = false
            if writer.canAdd(aInput) {
                writer.add(aInput)
                audioInput = aInput
                assetReader = reader
                readerOutput = output
            }
        }

        guard writer.startWriting() else {
            throw VideoExportError.cannotStartWriting(writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        let frameCount = slateFrames + max(1, Int((composition.videoDuration * Double(fps)).rounded()))
        let videoQueue = DispatchQueue(label: "PrompterVideoMaker.videoExport")
        let hasAudio = audioInput != nil
        let videoWeight = hasAudio ? 0.85 : 1.0
        let combiner = ProgressCombiner(videoWeight: videoWeight, onUpdate: progress)

        // IMPORTANT: when the writer has multiple inputs (video + audio) and
        // both use expectsMediaDataInRealTime = false, AVAssetWriter
        // interleaves samples by timestamp internally. Driving one input to
        // full completion before ever touching the other can make the first
        // input's isReadyForMoreMediaData go permanently false while it
        // waits for the other (not-yet-started) track to catch up —
        // deadlocking the export. Both inputs must be pumped concurrently.
        if let audioInput, let reader = assetReader, let output = readerOutput {
            guard reader.startReading() else {
                throw VideoExportError.writerFailed(reader.error)
            }
            let audioQueue = DispatchQueue(label: "PrompterVideoMaker.audioExport")
            let leadInTime = CMTime(seconds: style.leadIn + slateSeconds, preferredTimescale: 600)

            async let videoTask: Void = Self.driveVideo(
                writer: writer,
                input: videoInput,
                adaptor: adaptor,
                composition: composition,
                fps: fps,
                frameCount: frameCount,
                slate: slateFrames,
                titleCard: titleCard,
                width: width,
                height: height,
                queue: videoQueue,
                progress: { p in combiner.updateVideo(p) }
            )
            async let audioTask: Void = Self.driveAudio(
                writer: writer,
                input: audioInput,
                reader: reader,
                output: output,
                shiftBy: leadInTime,
                totalDuration: audioDurationSeconds,
                maxOutputSeconds: composition.videoDuration + slateSeconds,
                queue: audioQueue,
                progress: { p in combiner.updateAudio(p) }
            )
            _ = try await (videoTask, audioTask)
        } else {
            try await Self.driveVideo(
                writer: writer,
                input: videoInput,
                adaptor: adaptor,
                composition: composition,
                fps: fps,
                frameCount: frameCount,
                slate: slateFrames,
                titleCard: titleCard,
                width: width,
                height: height,
                queue: videoQueue,
                progress: { p in combiner.updateVideo(p) }
            )
        }

        writer.endSession(atSourceTime: CMTime(seconds: composition.videoDuration + slateSeconds, preferredTimescale: 600))

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }

        guard writer.status == .completed else {
            throw VideoExportError.writerFailed(writer.error)
        }
        progress(1.0)
    }

    // MARK: - Video frame generation

    private static func driveVideo(
        writer: AVAssetWriter,
        input: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        composition: PrompterComposition,
        fps: Int,
        frameCount: Int,
        slate: Int,
        titleCard: TitleCardInfo?,
        width: Int,
        height: Int,
        queue: DispatchQueue,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw VideoExportError.contextCreationFailed
        }
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let frameIndex = Locked(0)
            let finished = Locked(false)

            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    if finished.value { return }
                    let i = frameIndex.value
                    if i >= frameCount {
                        finished.value = true
                        input.markAsFinished()
                        cont.resume()
                        return
                    }

                    var frameError: Error?
                    autoreleasepool {
                        guard let pool = adaptor.pixelBufferPool else {
                            frameError = VideoExportError.pixelBufferPoolUnavailable
                            return
                        }
                        var pixelBufferOut: CVPixelBuffer?
                        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)
                        guard status == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else {
                            frameError = VideoExportError.pixelBufferCreationFailed(status)
                            return
                        }

                        CVPixelBufferLockBaseAddress(pixelBuffer, [])
                        if let ctx = CGContext(
                            data: CVPixelBufferGetBaseAddress(pixelBuffer),
                            width: CVPixelBufferGetWidth(pixelBuffer),
                            height: CVPixelBufferGetHeight(pixelBuffer),
                            bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                            space: colorSpace,
                            bitmapInfo: bitmapInfo
                        ) {
                            if i < slate, let card = titleCard {
                                TitleCardRenderer.draw(
                                    info: card,
                                    style: composition.style,
                                    into: ctx,
                                    size: CGSize(width: width, height: height)
                                )
                            } else {
                                let videoTime = Double(i - slate) / Double(fps)
                                composition.draw(
                                    atVideoTime: videoTime,
                                    into: ctx,
                                    size: CGSize(width: width, height: height)
                                )
                            }
                        } else {
                            frameError = VideoExportError.contextCreationFailed
                        }
                        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

                        if frameError == nil {
                            let pts = CMTime(value: Int64(i), timescale: Int32(fps))
                            if !adaptor.append(pixelBuffer, withPresentationTime: pts) {
                                frameError = VideoExportError.writerFailed(writer.error)
                            }
                        }
                    }

                    if let frameError {
                        finished.value = true
                        input.markAsFinished()
                        cont.resume(throwing: frameError)
                        return
                    }

                    frameIndex.value = i + 1
                    progress(Double(i + 1) / Double(frameCount))
                }
            }
        }
    }

    // MARK: - Audio muxing

    private static func driveAudio(
        writer: AVAssetWriter,
        input: AVAssetWriterInput,
        reader: AVAssetReader,
        output: AVAssetReaderTrackOutput,
        shiftBy delta: CMTime,
        totalDuration: Double,
        maxOutputSeconds: Double,
        queue: DispatchQueue,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let totalDuration = max(0.001, totalDuration)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let finished = Locked(false)

            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    if finished.value { return }

                    guard let sampleBuffer = output.copyNextSampleBuffer() else {
                        finished.value = true
                        input.markAsFinished()
                        if reader.status == .failed {
                            cont.resume(throwing: VideoExportError.writerFailed(reader.error))
                        } else {
                            cont.resume()
                        }
                        return
                    }

                    do {
                        let shifted = try Self.retimedSampleBuffer(sampleBuffer, by: delta)

                        // endSession(atSourceTime:) only stops FUTURE appends —
                        // it doesn't retroactively trim samples we already
                        // wrote. So we must stop feeding audio ourselves once
                        // its shifted timestamp reaches the video's length,
                        // or the audio track (and the whole container) would
                        // run longer than composition.videoDuration.
                        let shiftedSeconds = CMSampleBufferGetPresentationTimeStamp(shifted).seconds
                        guard shiftedSeconds < maxOutputSeconds else {
                            finished.value = true
                            input.markAsFinished()
                            reader.cancelReading()
                            progress(1.0)
                            cont.resume()
                            return
                        }

                        if !input.append(shifted) {
                            finished.value = true
                            input.markAsFinished()
                            cont.resume(throwing: VideoExportError.writerFailed(writer.error))
                            return
                        }
                        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
                        progress(min(0.99, pts / totalDuration))
                    } catch {
                        finished.value = true
                        input.markAsFinished()
                        cont.resume(throwing: error)
                        return
                    }
                }
            }
        }
    }

    private static func retimedSampleBuffer(_ sampleBuffer: CMSampleBuffer, by delta: CMTime) throws -> CMSampleBuffer {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return sampleBuffer }

        var timingInfo = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        let status = CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer, entryCount: count, arrayToFill: &timingInfo, entriesNeededOut: nil
        )
        guard status == noErr else { throw VideoExportError.sampleBufferTimingFailed }

        for i in timingInfo.indices {
            timingInfo[i].presentationTimeStamp = CMTimeAdd(timingInfo[i].presentationTimeStamp, delta)
            if timingInfo[i].decodeTimeStamp.isValid {
                timingInfo[i].decodeTimeStamp = CMTimeAdd(timingInfo[i].decodeTimeStamp, delta)
            }
        }

        var newBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &newBuffer
        )
        guard createStatus == noErr, let result = newBuffer else {
            throw VideoExportError.sampleBufferTimingFailed
        }
        return result
    }
}

/// Small lock-protected box used to share mutable counters between the
/// `requestMediaDataWhenReady` callback (which can re-invoke synchronously
/// and from a background queue) and the surrounding continuation closures.
private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { self._value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

/// Combines independently-reported 0...1 progress fractions from the
/// (possibly concurrent) video and audio drivers into one weighted,
/// monotonically non-decreasing overall progress value.
private final class ProgressCombiner: @unchecked Sendable {
    private let lock = NSLock()
    private var videoFraction: Double = 0
    private var audioFraction: Double = 0
    private let videoWeight: Double
    private let onUpdate: @Sendable (Double) -> Void

    init(videoWeight: Double, onUpdate: @escaping @Sendable (Double) -> Void) {
        self.videoWeight = videoWeight
        self.onUpdate = onUpdate
    }

    private var lastReported: Double = 0

    // Delivering inside the lock keeps reports serialized and monotonic;
    // neither consumer re-enters the combiner, so this cannot deadlock.
    func updateVideo(_ fraction: Double) {
        lock.lock()
        videoFraction = fraction
        let combined = max(lastReported, videoWeight * videoFraction + (1 - videoWeight) * audioFraction)
        lastReported = combined
        onUpdate(combined)
        lock.unlock()
    }

    func updateAudio(_ fraction: Double) {
        lock.lock()
        audioFraction = fraction
        let combined = max(lastReported, videoWeight * videoFraction + (1 - videoWeight) * audioFraction)
        lastReported = combined
        onUpdate(combined)
        lock.unlock()
    }
}
