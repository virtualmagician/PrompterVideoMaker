import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Handles CLI invocations for scripted exports and self-testing, bridging
/// async work onto the calling thread with a semaphore (no NSApplication
/// needed).
enum HeadlessRunner {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.count > 1 else { return false }

        if args.contains("--export") {
            runExport(args: args)
            return true
        }
        if args.contains("--render-frame") {
            runRenderFrame(args: args)
            return true
        }
        if args.contains("--transcribe") {
            runTranscribe(args: args)
            return true
        }
        if args.contains("--align") {
            runAlign(args: args)
            return true
        }
        if args.contains("--emphasize") {
            runEmphasize(args: args)
            return true
        }
        return false
    }

    // MARK: - --emphasize

    /// --emphasize --srt <in.srt> --out <out.srt> [--model <ollama model>]
    /// Adds AI-suggested **bold**/__underline__ emphasis markup via a local
    /// Ollama model.
    private static func runEmphasize(args: [String]) {
        guard let srtPath = value(for: "--srt", in: args) else { fail("--emphasize requires --srt <path>") }
        guard let outPath = value(for: "--out", in: args) else { fail("--emphasize requires --out <path.srt>") }
        let modelFlag = value(for: "--model", in: args)

        do {
            let segments = try loadSegments(srtPath: srtPath)
            let semaphore = DispatchSemaphore(value: 0)
            var result: Result<[Segment], Error>?
            Task {
                do {
                    let client = OllamaClient()
                    let model: String
                    if let modelFlag {
                        model = modelFlag
                    } else {
                        let models = try await client.installedModels()
                        guard let first = models.first(where: { $0.hasPrefix("gemma") }) ?? models.first else {
                            throw OllamaError.badResponse("no generative models installed")
                        }
                        model = first
                    }
                    print("model: \(model)")
                    let suggested = try await EmphasisSuggester.suggest(segments: segments, model: model) { p in
                        print("progress: \(Int((p * 100).rounded()))%")
                        fflush(stdout)
                    }
                    result = .success(suggested)
                } catch {
                    result = .failure(error)
                }
                semaphore.signal()
            }
            semaphore.wait()

            switch result {
            case .success(let suggested):
                try SRTParser.serialize(suggested).write(toFile: outPath, atomically: true, encoding: .utf8)
                let changed = zip(segments, suggested).filter { $0.text != $1.text }.count
                print("emphasized \(changed) of \(segments.count) cues")
                print("Emphasized SRT written: \(outPath)")
            case .failure(let error):
                fail("Emphasis failed: \(error.localizedDescription)")
            case nil:
                fail("Emphasis did not complete")
            }
        } catch {
            fail("Emphasis failed: \(error.localizedDescription)")
        }
    }

    // MARK: - --align

    /// --align --script <plain-text path> --audio <recording> --out <path.srt>
    ///         [--granularity sentences|lines|paragraphs]
    /// Builds a script from pasted-style text, recognizes the recording, and
    /// aligns the known text against it to produce timed cues.
    private static func runAlign(args: [String]) {
        guard let scriptPath = value(for: "--script", in: args) else { fail("--align requires --script <path>") }
        guard let audioPath = value(for: "--audio", in: args) else { fail("--align requires --audio <path>") }
        guard let outPath = value(for: "--out", in: args) else { fail("--align requires --out <path.srt>") }
        let granularity = value(for: "--granularity", in: args)
            .flatMap { ScriptGranularity(rawValue: $0.capitalized) } ?? .sentences

        do {
            let text = try String(contentsOfFile: scriptPath, encoding: .utf8)
            let script = ScriptImporter.script(fromPastedText: text, granularity: granularity)
            guard !script.isEmpty else { fail("Script text produced no segments") }

            let semaphore = DispatchSemaphore(value: 0)
            var result: Result<[Transcriber.TimedWord], Error>?
            Task {
                do {
                    let words = try await Transcriber.timedWords(audioURL: URL(fileURLWithPath: audioPath)) { p in
                        print("progress: \(Int((p * 100).rounded()))%")
                        fflush(stdout)
                    }
                    result = .success(words)
                } catch {
                    result = .failure(error)
                }
                semaphore.signal()
            }
            semaphore.wait()

            switch result {
            case .success(let words):
                let aligned = Aligner.align(script: script, words: words)
                let srt = SRTParser.serialize(aligned.segments)
                try srt.write(toFile: outPath, atomically: true, encoding: .utf8)
                print(String(format: "match rate: %.1f%%", aligned.matchRate * 100))
                print("Aligned SRT written: \(outPath)")
            case .failure(let error):
                fail("Alignment failed: \(error.localizedDescription)")
            case nil:
                fail("Alignment did not complete")
            }
        } catch {
            fail("Alignment failed: \(error.localizedDescription)")
        }
    }

    // MARK: - --export

    private static func runExport(args: [String]) {
        guard let srtPath = value(for: "--srt", in: args) else { fail("--export requires --srt <path>") }
        guard let outPath = value(for: "--out", in: args) else { fail("--export requires --out <path.mp4>") }
        let audioPath = value(for: "--audio", in: args)

        do {
            let segments = try loadSegments(srtPath: srtPath)
            var script = Script(segments: segments)
            script.normalize()

            var style = StyleSettings()
            applyStyleFlags(&style, args: args)

            let audioURL = audioPath.map { URL(fileURLWithPath: $0) }
            let outputURL = URL(fileURLWithPath: outPath)
            let composition = PrompterComposition(script: script, style: style)
            let titleName = value(for: "--title", in: args)
                ?? URL(fileURLWithPath: srtPath).deletingPathExtension().lastPathComponent
            let titleCard = TitleCardInfo(
                projectName: titleName,
                exportDate: Date(),
                videoDuration: composition.videoDuration
            )
            let exporter = VideoExporter(
                composition: composition, audioURL: audioURL,
                outputURL: outputURL, titleCard: titleCard)

            let semaphore = DispatchSemaphore(value: 0)
            var exportError: Error?
            Task {
                do {
                    try await exporter.export { p in
                        print("progress: \(Int((p * 100).rounded()))%")
                        fflush(stdout)
                    }
                } catch {
                    exportError = error
                }
                semaphore.signal()
            }
            semaphore.wait()

            if let exportError {
                fail("Export failed: \(exportError.localizedDescription)")
            }
            print("Export complete: \(outPath)")
        } catch {
            fail("Export failed: \(error.localizedDescription)")
        }
    }

    // MARK: - --render-frame

    private static func runRenderFrame(args: [String]) {
        guard let srtPath = value(for: "--srt", in: args) else { fail("--render-frame requires --srt <path>") }
        guard let timeStr = value(for: "--time", in: args), let time = Double(timeStr) else {
            fail("--render-frame requires --time <seconds>")
        }
        guard let outPath = value(for: "--out", in: args) else { fail("--render-frame requires --out <path.png>") }

        do {
            let segments = try loadSegments(srtPath: srtPath)
            var script = Script(segments: segments)
            script.normalize()

            var style = StyleSettings()
            applyStyleFlags(&style, args: args)

            let composition = PrompterComposition(script: script, style: style)
            guard let image = composition.image(atVideoTime: time, scale: 1.0) else {
                fail("Failed to render frame at t=\(time)")
            }
            try writePNG(image: image, to: URL(fileURLWithPath: outPath))
            print("Frame written: \(outPath)")
        } catch {
            fail("Render failed: \(error.localizedDescription)")
        }
    }

    // MARK: - --transcribe

    private static func runTranscribe(args: [String]) {
        guard let audioPath = value(for: "--audio", in: args) else { fail("--transcribe requires --audio <path>") }
        guard let outPath = value(for: "--out", in: args) else { fail("--transcribe requires --out <path.srt>") }
        let audioURL = URL(fileURLWithPath: audioPath)

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<[Segment], Error>?
        Task {
            do {
                let segments = try await Transcriber.transcribe(audioURL: audioURL) { p in
                    print("progress: \(Int((p * 100).rounded()))%")
                    fflush(stdout)
                }
                result = .success(segments)
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()

        switch result {
        case .success(let segments):
            do {
                let srt = SRTParser.serialize(segments)
                try srt.write(toFile: outPath, atomically: true, encoding: .utf8)
                print("Transcription written: \(outPath)")
            } catch {
                fail("Failed to write SRT: \(error.localizedDescription)")
            }
        case .failure(let error):
            fail("Transcription failed: \(error.localizedDescription)")
        case nil:
            fail("Transcription failed: unknown error")
        }
    }

    // MARK: - Shared helpers

    private static func loadSegments(srtPath: String) throws -> [Segment] {
        let text = try String(contentsOfFile: srtPath, encoding: .utf8)
        return try SRTParser.parse(text, stripSpeakerPrefixes: true)
    }

    private static func applyStyleFlags(_ style: inout StyleSettings, args: [String]) {
        if let v = value(for: "--fps", in: args) {
            guard let n = Int(v), (1...240).contains(n) else {
                fail("--fps must be an integer between 1 and 240")
            }
            style.fps = n
        }
        if let v = value(for: "--font", in: args) { style.fontName = v }
        if let v = value(for: "--font-size", in: args), let n = Double(v) { style.fontSize = CGFloat(n) }
        if let v = value(for: "--line-height", in: args), let n = Double(v) { style.lineHeightMultiple = CGFloat(n) }
        if let v = value(for: "--bg", in: args), let c = RGBAColor(hex: v) { style.backgroundColor = c }
        if let v = value(for: "--color1", in: args), let c = RGBAColor(hex: v) { style.primaryTextColor = c }
        if let v = value(for: "--color2", in: args), let c = RGBAColor(hex: v) { style.secondaryTextColor = c }
        if hasFlag("--no-alternate", in: args) { style.alternatingColors = false }
        if let v = value(for: "--chunk-words", in: args), let n = Int(v) { style.maxChunkWords = min(max(1, n), 1000) }
        if let v = value(for: "--lead-in", in: args), let n = Double(v) { style.leadIn = n }
        if let v = value(for: "--lead-out", in: args), let n = Double(v) { style.leadOut = n }
        if let v = value(for: "--codec", in: args) {
            guard let c = VideoCodecSetting(rawValue: v.lowercased()) else { fail("--codec must be h264 or hevc") }
            style.videoCodec = c
        }
        if let v = value(for: "--quality", in: args) {
            guard let q = QualityPresetSetting(rawValue: v.lowercased()) else { fail("--quality must be draft, standard, high or maximum") }
            style.qualityPreset = q
        }
        if hasFlag("--mirror", in: args) { style.mirrored = true }
        if hasFlag("--no-audio", in: args) { style.includeAudio = false }
        if hasFlag("--no-title-card", in: args) { style.titleCardEnabled = false }
    }

    private static func value(for flag: String, in args: [String]) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    private static func hasFlag(_ flag: String, in args: [String]) -> Bool {
        args.contains(flag)
    }

    private static func writePNG(image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw HeadlessRunnerError.cannotCreateImageDestination
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw HeadlessRunnerError.cannotWriteImage
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
        exit(1)
    }
}

private enum HeadlessRunnerError: LocalizedError {
    case cannotCreateImageDestination
    case cannotWriteImage

    var errorDescription: String? {
        switch self {
        case .cannotCreateImageDestination: return "Could not create a PNG destination."
        case .cannotWriteImage: return "Could not write the PNG file."
        }
    }
}
