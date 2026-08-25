# PrompterVideoMaker — Module Contracts (for implementation agents)

Native macOS teleprompter-video app. SwiftPM executable, macOS 15 deployment
target, Swift language mode 5, canvas always 1920x1080. Read these files first —
they already exist and compile:

- `Sources/PrompterVideoMaker/Models/Script.swift` — `Segment`, `Script`, `PrompterProject`
- `Sources/PrompterVideoMaker/Models/StyleSettings.swift` — `StyleSettings`, `RGBAColor`, canvas constants
- `Sources/PrompterVideoMaker/Rendering/ScrollCurve.swift` — `ScrollCurve` (time → ribbon offset, monotone cubic)
- `Sources/PrompterVideoMaker/main.swift` — entry: calls `HeadlessRunner.runIfRequested()`, else `PrompterApp.main()`

Rules for every agent:
- Write ONLY the files assigned to you. Never edit shared/model files or another module's files.
- Tests use `import Testing` (Swift Testing, `@Test`/`#expect`). XCTest is NOT available.
- To compile/iterate: copy the whole package to your assigned scratch directory,
  add stubs there for the other modules you depend on (see Stubs below), and run
  `swift build` / `swift test` in the COPY. Never run swift build in the real
  project directory. When done, copy ONLY your assigned files back.
- Fonts/colors: use `style.resolvedFont()`, `RGBAColor.cgColor/.nsColor`.

## Module A — SRT import + chunking
Files: `Sources/PrompterVideoMaker/Importers/SRTParser.swift`,
`Sources/PrompterVideoMaker/Models/Chunker.swift`,
`Tests/ParserChunkerTests.swift`

```swift
enum SRTParseError: Error { case malformed(line: Int, reason: String) }

enum SRTParser {
    /// Parses SRT text. Tolerates: BOM, CRLF/LF, blank-line variations,
    /// `,` or `.` millisecond separator, missing/non-sequential indices,
    /// multi-line cue text (joined with a single space).
    /// If stripSpeakerPrefixes, removes leading "Name:" / "Speaker 1:" style
    /// prefixes (a short label, max ~24 chars, before the first colon) from cue text.
    static func parse(_ text: String, stripSpeakerPrefixes: Bool) throws -> [Segment]
    /// Standard SRT output: index from 1, HH:MM:SS,mmm --> HH:MM:SS,mmm.
    static func serialize(_ segments: [Segment]) -> String
}

struct TextChunk: Equatable {
    let text: String
    /// 0 = primary color, 1 = secondary color.
    let colorIndex: Int
}

enum Chunker {
    /// Splits each segment's text into short "sense" chunks of at most
    /// maxWords words, breaking preferentially at sentence enders (. ! ?),
    /// then at , ; : — then hard word-count splits. Color alternation is
    /// GLOBAL: it continues across segments (chunk N+1 anywhere in the script
    /// has the other color of chunk N). If alternate == false every chunk has
    /// colorIndex 0. Chunk texts of one segment joined by " " must equal the
    /// segment text (no characters lost).
    static func chunks(for segments: [Segment], maxWords: Int, alternate: Bool) -> [[TextChunk]]
}
```
Tests: round-trip parse→serialize→parse on a synthetic SRT; speaker-prefix stripping
("Speaker 1: Hello" → "Hello", but "Warning: do not" with long text before colon stays if
prefix > 24 chars or contains sentence punctuation); dot-vs-comma millis; chunker: no
text loss, maxWords respected (except single words longer than the limit), global alternation.

## Module B — Layout, rendering, export, headless
Files: `Sources/PrompterVideoMaker/Rendering/RibbonLayout.swift`,
`Sources/PrompterVideoMaker/Rendering/Composition.swift`,
`Sources/PrompterVideoMaker/Export/VideoExporter.swift`,
`Sources/PrompterVideoMaker/HeadlessRunner.swift`

```swift
/// Lays out the whole script once as one tall text ribbon (CoreText),
/// 1920-wide space, wrapped at style.textWidth, line height style.lineHeight.
/// Uses Chunker for per-chunk color runs (style.alternatingColors,
/// style.maxChunkWords, primary/secondaryTextColor). Segments are separated
/// by exactly one empty line gap (0.35 * lineHeight vertical gap).
final class RibbonLayout {
    struct Line {
        let ctLine: CTLine
        /// Baseline Y in ribbon coordinates (0 = ribbon top, +Y down).
        let baselineY: CGFloat
        /// Vertical center of the line's box.
        let centerY: CGFloat
        let segmentIndex: Int
    }
    struct SegmentExtent { let firstLineCenterY: CGFloat; let lastLineCenterY: CGFloat }

    init(script: Script, style: StyleSettings)
    var lines: [Line] { get }
    var segmentExtents: [SegmentExtent] { get }   // parallel to script.segments
    var totalHeight: CGFloat { get }
    /// Draw visible lines into ctx (canvas coords, 1920x1080, CoreGraphics
    /// bottom-left origin is fine internally — the public contract is only that
    /// Composition output is upright). scrollOffset o means ribbon Y maps to
    /// canvas Y = ribbonY - o (ribbon coordinate at the canvas TOP edge).
    func draw(into ctx: CGContext, scrollOffset: CGFloat, style: StyleSettings)
}

/// Ties script+style together: builds RibbonLayout + ScrollCurve, renders frames.
final class PrompterComposition {
    let script: Script
    let style: StyleSettings
    let videoDuration: Double     // style.leadIn + script.lastEnd + style.leadOut
    init(script: Script, style: StyleSettings)
    /// Full frame: background, text at correct scroll position, marker arrow.
    /// videoTime 0 = start of video (scriptTime = videoTime - leadIn).
    /// scale 1.0 → 1920x1080; 0.5 → 960x540. Applies style.mirrored.
    func image(atVideoTime t: Double, scale: CGFloat) -> CGImage?
    func draw(atVideoTime t: Double, into ctx: CGContext, size: CGSize)
}
```

ScrollCurve control points (build inside PrompterComposition, script-time space):
- `(firstStart - leadIn, extent0.firstLineCenterY - markerY - (canvasHeight - markerY))`
  → at video start the first line waits just below the bottom edge, rolls in during lead-in.
- For each segment i: `(start_i, extents[i].firstLineCenterY - markerY)` → the first line of
  a segment sits EXACTLY on the marker at its start time.
- Final: `(lastEnd, extents[last].lastLineCenterY - markerY)` → last line reaches the marker
  at the last cue's end; hold during leadOut.
Marker: left-pointing... — a solid triangle at x from ~24px to ~64px, vertically centered
on style.markerY, pointing RIGHT toward the text (like a playhead ▶), color style.markerColor,
drawn only if style.markerEnabled. Text left margin must clear it (margin already 100px).

```swift
final class VideoExporter {
    init(composition: PrompterComposition, audioURL: URL?, outputURL: URL)
    /// H.264 .mp4, 1920x1080, composition.style.fps (30 or 60), ~12 Mbps,
    /// BT.709. If audioURL != nil and style.includeAudio: decode with
    /// AVAssetReader, encode AAC 48kHz stereo via AVAssetWriterInput, audio
    /// placed so audio t=0 aligns with video t=leadIn. Video length =
    /// composition.videoDuration. Uses AVAssetWriterInputPixelBufferAdaptor
    /// with a pixel buffer pool; renders frames via composition.draw.
    func export(progress: @escaping @Sendable (Double) -> Void) async throws
}

enum HeadlessRunner {
    /// Handles CLI invocations, returns true if handled (process exits after):
    /// --export --srt <path> [--audio <path>] --out <path.mp4>
    ///          [--fps 30|60] [--font <name>] [--font-size N] [--line-height X]
    ///          [--bg HEX] [--color1 HEX] [--color2 HEX] [--no-alternate]
    ///          [--chunk-words N] [--lead-in S] [--lead-out S] [--mirror] [--no-audio]
    /// --render-frame --srt <path> --time T --out <path.png>  (single frame, for testing)
    /// --transcribe --audio <path> --out <path.srt>   → calls
    ///          Transcriber.transcribe(audioURL:progress:) and writes SRTParser.serialize
    /// Prints progress to stdout, errors to stderr, exit(1) on failure.
    /// Bridge async work with a semaphore; no NSApplication needed.
    static func runIfRequested() -> Bool
}
```

## Module C — SwiftUI app
Files: `Sources/PrompterVideoMaker/UI/PrompterApp.swift` (NO @main attribute —
`main.swift` calls `PrompterApp.main()`), `AppState.swift`, `ContentView.swift`,
`SegmentListView.swift`, `PreviewView.swift`, `InspectorView.swift`, `TransportBar.swift`
(all under `Sources/PrompterVideoMaker/UI/`).

`PrompterApp: App` — WindowGroup with ContentView, 1280x800 min; Commands: Open
(SRT/audio/project), Save Project, Export Video…

`AppState: ObservableObject` (@MainActor):
- `@Published var project: PrompterProject`, `selectedSegmentID: UUID?`,
  `playheadVideoTime: Double`, `isPlaying: Bool`, export/transcribe progress state.
- `composition: PrompterComposition?` — rebuilt (debounced ~0.25s) whenever
  script/style change.
- Import: SRT via `SRTParser.parse` (strip speaker prefixes: user toggle in the
  open flow, default ON); audio via `Transcriber.transcribe(audioURL:progress:)`
  (async, progress sheet, sets project.audioPath so preview/export use it).
- Playback: preview clock driven by the view; audio sync via AVAudioPlayer when
  audioPath set (audio currentTime = playheadVideoTime - leadIn, only while playing).
- Export: NSSavePanel → VideoExporter in Task, progress bar, reveal in Finder on done.

Layout (ContentView): HSplitView — left: SegmentListView (250-350w); center:
PreviewView + TransportBar; right: InspectorView (~300w, scrollable Form).
- SegmentListView: List of segments (index, start→end mm:ss.s, editable TextField
  text). Selection follows playback (auto-scroll). Context menu / buttons:
  split at cursor is NOT needed — provide "Split in Half", "Merge with Next",
  "Delete". Steppers for start/end nudge (±0.1s) on the selected row.
- PreviewView: 16:9 area, black letterbox, draws
  `composition.image(atVideoTime:scale:)` at fitting scale via TimelineView
  (.animation when playing) + Canvas. Click = pause/play toggle.
- TransportBar: play/pause (space), jump to start/end, prev/next segment,
  scrubber Slider over videoDuration, time label "m:ss.t / m:ss.t".
- InspectorView sections: Colors (background, primary, secondary,
  ColorPicker), Alternating colors toggle + max words/chunk slider (3...14),
  Text (font picker via NSFontManager family names menu, size slider 48...160,
  line height 1.1...2.2, margin 40...300, alignment picker, "≈ N lines visible"
  readout), Marker (toggle, color, vertical position 0.15...0.6), Mirror toggle,
  Export (fps picker 30/60, lead-in/out steppers 0...10s, include audio toggle),
  Timing (global offset ±, buttons -0.5s/+0.5s applying `script.offsetAll`).
Style: modern macOS — .formStyle(.grouped), SF Symbols, dark-friendly.

## Stubs for cross-module compilation (in your scratch copy only)
Module B may stub: `enum Transcriber { static func transcribe(audioURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [Segment] { [] } }`
and Module A's `Chunker`/`TextChunk`/`SRTParser` if not yet present.
Module C may stub: `PrompterComposition`, `VideoExporter`, `Transcriber`, `Chunker`, `HeadlessRunner`.
Module A needs no stubs (depends only on Models).
Delete/do-not-copy stubs when copying your files back.
