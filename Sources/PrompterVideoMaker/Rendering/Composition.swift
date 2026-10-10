import Foundation
import CoreGraphics

/// Ties script + style together: builds the `RibbonLayout` and `ScrollCurve`
/// once, then renders full frames (background, text, marker) at any video
/// time.
final class PrompterComposition {
    let script: Script
    let style: StyleSettings
    /// style.leadIn + script.lastEnd + style.leadOut
    let videoDuration: Double

    let layout: RibbonLayout
    private let scrollCurve: ScrollCurve

    init(script: Script, style: StyleSettings) {
        self.script = script
        self.style = style
        self.layout = RibbonLayout(script: script, style: style)
        self.videoDuration = style.leadIn + script.lastEnd + style.leadOut

        let markerY = style.markerY
        let canvasHeight = StyleSettings.canvasHeight
        let extents = layout.segmentExtents

        var points: [(time: Double, offset: Double)] = []
        if !script.segments.isEmpty, let firstExtent = extents.first, let lastExtent = extents.last {
            // At video start, the first line waits just below the bottom
            // edge and rolls in during lead-in.
            points.append((
                script.firstStart - style.leadIn,
                firstExtent.firstLineCenterY - markerY - (canvasHeight - markerY)
            ))
            // Each segment's first line sits exactly on the marker at its
            // start time; with valid word timings every later line also gets
            // an anchor at the time its first word is spoken.
            points.append(contentsOf: Self.scrollAnchors(script: script, layout: layout, markerY: markerY))
            // The last line reaches the marker at the last cue's end; holds during lead-out.
            points.append((script.lastEnd, lastExtent.lastLineCenterY - markerY))
        } else {
            points.append((0, 0))
        }
        self.scrollCurve = ScrollCurve(points: points)
    }

    // MARK: - Scroll anchors

    /// Anchors closer than this (seconds) to the previous kept anchor are
    /// dropped: noisy word times would otherwise create near-vertical spline
    /// sections.
    static let minAnchorGap: Double = 0.25

    private struct Anchor {
        var time: Double
        var offset: Double
        /// A segment's first-line anchor (cue start); never dropped.
        var isSegmentFirst: Bool
    }

    /// Returns `timings` sorted by location when they still describe `plain`
    /// exactly (every range in bounds and `plain[range] == word`); nil when
    /// absent or when the text was edited since they were captured.
    private static func validWordTimings(_ timings: [WordTiming]?, plain: String) -> [WordTiming]? {
        guard let timings, !timings.isEmpty else { return nil }
        let ns = plain as NSString
        for t in timings {
            guard t.location >= 0, t.length > 0, t.length <= ns.length - t.location,
                  t.start.isFinite, t.end.isFinite else { return nil }
            guard ns.substring(with: NSRange(location: t.location, length: t.length)) == t.word else { return nil }
        }
        return timings.sorted { $0.location < $1.location }
    }

    /// Scroll control points (script time, ribbon offset) for all segments.
    ///
    /// Rule: every segment contributes (segment.start, firstLineCenterY -
    /// markerY). If its word timings are valid for the current text, every
    /// later layout line L (non-empty range) also contributes (start of the
    /// first word timing intersecting L.range, clamped to
    /// [segment.start, segment.end]; L.centerY - markerY); lines no word
    /// touches are skipped. Finally any later-line anchor less than
    /// `minAnchorGap` after the previous kept anchor is dropped; a
    /// segment's first-line anchor is never dropped (conflicting later-line
    /// anchors before it are removed instead).
    static func scrollAnchors(script: Script, layout: RibbonLayout, markerY: CGFloat) -> [(time: Double, offset: Double)] {
        let segmentCount = script.segments.count
        var linesBySegment = [[RibbonLayout.Line]](repeating: [], count: segmentCount)
        for line in layout.lines where line.segmentIndex >= 0 && line.segmentIndex < segmentCount {
            linesBySegment[line.segmentIndex].append(line)
        }

        var kept: [Anchor] = []
        func add(_ a: Anchor) {
            if a.isSegmentFirst {
                // Mandatory: evict later-line anchors that crowd (or follow) it.
                while let last = kept.last, !last.isSegmentFirst, a.time - last.time < minAnchorGap {
                    kept.removeLast()
                }
            } else if let last = kept.last, a.time - last.time < minAnchorGap {
                return
            }
            kept.append(a)
        }

        for (i, segment) in script.segments.enumerated() {
            add(Anchor(
                time: segment.start,
                offset: layout.segmentExtents[i].firstLineCenterY - markerY,
                isSegmentFirst: true
            ))

            guard i < layout.segmentPlainTexts.count,
                  let timings = validWordTimings(segment.wordTimings, plain: layout.segmentPlainTexts[i])
            else { continue }

            var p = 0
            for line in linesBySegment[i].dropFirst() where line.range.length > 0 {
                let lineStart = line.range.location
                let lineEnd = lineStart + line.range.length
                // First timing that ends after this line begins; it
                // intersects the line only if it also begins before it ends.
                while p < timings.count, timings[p].location + timings[p].length <= lineStart { p += 1 }
                guard p < timings.count, timings[p].location < lineEnd else { continue }
                let time = min(max(timings[p].start, segment.start), max(segment.end, segment.start))
                add(Anchor(time: time, offset: line.centerY - markerY, isSegmentFirst: false))
            }
        }
        return kept.map { ($0.time, $0.offset) }
    }

    /// Renders a full frame at `scale` (1.0 -> 1920x1080; 0.5 -> 960x540).
    /// Ribbon scroll offset at a video time (for wheel scrubbing).
    func scrollOffset(atVideoTime t: Double) -> CGFloat {
        CGFloat(scrollCurve.offset(at: t - style.leadIn))
    }

    /// Word under a canvas point (top-down 1920x1080 coords, as displayed —
    /// mirroring is unapplied here) at the given video time.
    func hitTestWord(canvasPoint: CGPoint, atVideoTime t: Double) -> (segmentIndex: Int, plainRange: Range<Int>)? {
        let p = style.mirrored
            ? CGPoint(x: StyleSettings.canvasWidth - canvasPoint.x, y: canvasPoint.y)
            : canvasPoint
        return layout.wordHit(canvasPoint: p, scrollOffset: scrollOffset(atVideoTime: t), style: style)
    }

    /// Canvas-space (top-down, as displayed) highlight boxes for a plain-text
    /// range of one segment at the given video time.
    func highlightRects(segmentIndex: Int, plainRange: Range<Int>, atVideoTime t: Double) -> [CGRect] {
        let off = scrollOffset(atVideoTime: t)
        return layout.rects(forSegment: segmentIndex, plainRange: plainRange, style: style).map { r in
            var rect = r.offsetBy(dx: 0, dy: -off)
            if style.mirrored {
                rect.origin.x = StyleSettings.canvasWidth - rect.maxX
            }
            return rect
        }
    }

    /// Inverse of `scrollOffset(atVideoTime:)` by bisection — the curve is
    /// monotone, so this finds the video time whose ribbon position matches
    /// `target`, clamped to [0, videoDuration].
    func videoTime(forScrollOffset target: CGFloat) -> Double {
        var lo = 0.0
        var hi = videoDuration
        if scrollOffset(atVideoTime: lo) >= target { return lo }
        if scrollOffset(atVideoTime: hi) <= target { return hi }
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if scrollOffset(atVideoTime: mid) < target { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    func image(atVideoTime t: Double, scale: CGFloat) -> CGImage? {
        let width = max(2, Int((StyleSettings.canvasWidth * scale).rounded()))
        let height = max(2, Int((StyleSettings.canvasHeight * scale).rounded()))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        draw(atVideoTime: t, into: ctx, size: CGSize(width: width, height: height))
        return ctx.makeImage()
    }

    /// Draws background, scrolled text, and the marker arrow into `ctx`
    /// (which is assumed to use CoreGraphics' native bottom-left origin,
    /// +Y-up coordinate system — no external CTM flip). videoTime 0 = start
    /// of video; scriptTime = videoTime - leadIn. Applies `style.mirrored`
    /// to the whole frame (a horizontal flip, for beam-splitter prompter
    /// glass).
    func draw(atVideoTime t: Double, into ctx: CGContext, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }

        let scriptTime = t - style.leadIn
        let offset = scrollCurve.offset(at: scriptTime)

        ctx.saveGState()

        ctx.setFillColor(style.backgroundColor.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))

        let scaleX = size.width / StyleSettings.canvasWidth
        let scaleY = size.height / StyleSettings.canvasHeight
        ctx.scaleBy(x: scaleX, y: scaleY)

        if style.mirrored {
            ctx.translateBy(x: StyleSettings.canvasWidth, y: 0)
            ctx.scaleBy(x: -1, y: 1)
        }

        layout.draw(into: ctx, scrollOffset: offset, style: style)

        if style.markerEnabled {
            drawMarker(into: ctx)
        }

        ctx.restoreGState()
    }

    /// A solid triangle from x=24 to x=64, vertically centered on
    /// style.markerY, pointing right toward the text (like a playhead ▶).
    private func drawMarker(into ctx: CGContext) {
        let canvasHeight = StyleSettings.canvasHeight
        let centerCGY = canvasHeight - style.markerY // top-down -> bottom-up
        let halfHeight: CGFloat = 22
        let xBase: CGFloat = 24
        let xTip: CGFloat = 64

        ctx.saveGState()
        ctx.setFillColor(style.markerColor.cgColor)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: xBase, y: centerCGY + halfHeight))
        ctx.addLine(to: CGPoint(x: xBase, y: centerCGY - halfHeight))
        ctx.addLine(to: CGPoint(x: xTip, y: centerCGY))
        ctx.closePath()
        ctx.fillPath()
        ctx.restoreGState()
    }
}
