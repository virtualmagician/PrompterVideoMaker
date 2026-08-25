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
            // Each segment's first line sits exactly on the marker at its start time.
            for (i, segment) in script.segments.enumerated() {
                points.append((segment.start, extents[i].firstLineCenterY - markerY))
            }
            // The last line reaches the marker at the last cue's end; holds during lead-out.
            points.append((script.lastEnd, lastExtent.lastLineCenterY - markerY))
        } else {
            points.append((0, 0))
        }
        self.scrollCurve = ScrollCurve(points: points)
    }

    /// Renders a full frame at `scale` (1.0 -> 1920x1080; 0.5 -> 960x540).
    /// Ribbon scroll offset at a video time (for wheel scrubbing).
    func scrollOffset(atVideoTime t: Double) -> CGFloat {
        CGFloat(scrollCurve.offset(at: t - style.leadIn))
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
