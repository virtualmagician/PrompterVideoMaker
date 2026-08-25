import Foundation
import CoreText
import CoreGraphics
import AppKit

/// Lays out the whole script once as one tall text ribbon (CoreText),
/// 1920-wide space, wrapped at `style.textWidth`, fixed line height
/// `style.lineHeight`. Per-chunk color runs come from `Chunker`
/// (`style.alternatingColors`, `style.maxChunkWords`, primary/secondary
/// text colors). All lines are spaced uniformly (no extra gap between
/// segments); insert an empty-text segment for a deliberate visual break.
///
/// Coordinate note: `lines` and `segmentExtents` live in "ribbon space":
/// Y = 0 is the top of the ribbon, +Y grows downward, matching the order
/// segments appear in the script. `draw(into:scrollOffset:style:)` converts
/// ribbon space into the CGContext's native (bottom-left origin, +Y up)
/// space by arithmetic (never by flipping the CTM), so CoreText draws
/// glyphs upright without any extra text-matrix flip.
final class RibbonLayout {
    struct Line {
        let ctLine: CTLine
        /// Baseline Y in ribbon coordinates (0 = ribbon top, +Y down).
        let baselineY: CGFloat
        /// Vertical center of the line's box (ribbon coordinates).
        let centerY: CGFloat
        let segmentIndex: Int
    }

    struct SegmentExtent {
        let firstLineCenterY: CGFloat
        let lastLineCenterY: CGFloat
    }

    let lines: [Line]
    let segmentExtents: [SegmentExtent]
    let totalHeight: CGFloat

    private static let foregroundColorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)

    init(script: Script, style: StyleSettings) {
        let font = style.resolvedFont()
        let primaryColor = style.primaryTextColor.cgColor
        let secondaryColor = style.secondaryTextColor.cgColor
        let lineHeight = style.lineHeight
        let textWidth = max(1, style.textWidth)

        let chunkGroups = Chunker.chunks(
            for: script.segments,
            maxWords: style.maxChunkWords,
            alternate: style.alternatingColors
        )

        var builtLines: [Line] = []
        var extents: [SegmentExtent] = []
        var cursorTop: CGFloat = 0

        for (segIndex, segment) in script.segments.enumerated() {
            let chunks = segIndex < chunkGroups.count ? chunkGroups[segIndex] : []
            let attrString = Self.buildAttributedString(
                chunks: chunks,
                font: font,
                primary: primaryColor,
                secondary: secondaryColor,
                fallbackText: segment.text
            )
            let ctLines = Self.wrapLines(attrString: attrString, maxWidth: textWidth)

            var firstCenter: CGFloat?
            var lastCenter: CGFloat = cursorTop + lineHeight / 2

            if ctLines.isEmpty {
                // Reserve a blank line so extents stay meaningful even for empty cues.
                let centerY = cursorTop + lineHeight / 2
                let baselineY = Self.baseline(forCenterY: centerY, lineHeight: lineHeight, font: font)
                let empty = CTLineCreateWithAttributedString(NSAttributedString(string: "", attributes: [.font: font]))
                builtLines.append(Line(ctLine: empty, baselineY: baselineY, centerY: centerY, segmentIndex: segIndex))
                firstCenter = centerY
                lastCenter = centerY
                cursorTop += lineHeight
            } else {
                for ctLine in ctLines {
                    let centerY = cursorTop + lineHeight / 2
                    let baselineY = Self.baseline(forCenterY: centerY, lineHeight: lineHeight, font: font)
                    builtLines.append(Line(ctLine: ctLine, baselineY: baselineY, centerY: centerY, segmentIndex: segIndex))
                    if firstCenter == nil { firstCenter = centerY }
                    lastCenter = centerY
                    cursorTop += lineHeight
                }
            }

            extents.append(SegmentExtent(
                firstLineCenterY: firstCenter ?? (cursorTop + lineHeight / 2),
                lastLineCenterY: lastCenter
            ))
        }

        self.lines = builtLines
        self.segmentExtents = extents
        self.totalHeight = cursorTop
    }

    /// Centers the font's ascent/descent span within a `lineHeight`-tall box
    /// and returns the baseline Y (ribbon coords, top-down) for that box.
    private static func baseline(forCenterY centerY: CGFloat, lineHeight: CGFloat, font: NSFont) -> CGFloat {
        let ascent = font.ascender
        let descent = -font.descender // NSFont.descender is negative
        let glyphSpan = ascent + descent
        let boxTop = centerY - lineHeight / 2
        let glyphBoxTop = boxTop + (lineHeight - glyphSpan) / 2
        return glyphBoxTop + ascent
    }

    private static func buildAttributedString(
        chunks: [TextChunk],
        font: NSFont,
        primary: CGColor,
        secondary: CGColor,
        fallbackText: String
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        guard !chunks.isEmpty else {
            if !fallbackText.isEmpty {
                result.append(NSAttributedString(
                    string: fallbackText,
                    attributes: [.font: font, foregroundColorKey: primary]
                ))
            }
            return result
        }
        for (i, chunk) in chunks.enumerated() {
            let color = chunk.colorIndex == 0 ? primary : secondary
            if i > 0 {
                result.append(NSAttributedString(string: " ", attributes: [.font: font, foregroundColorKey: color]))
            }
            result.append(NSAttributedString(string: chunk.text, attributes: [.font: font, foregroundColorKey: color]))
        }
        return result
    }

    /// Manual CoreText line-breaking so we control line height ourselves
    /// (rather than relying on CTFramesetter's natural leading).
    private static func wrapLines(attrString: NSAttributedString, maxWidth: CGFloat) -> [CTLine] {
        guard attrString.length > 0 else { return [] }
        let typesetter = CTTypesetterCreateWithAttributedString(attrString as CFAttributedString)
        var result: [CTLine] = []
        var start = 0
        let length = attrString.length
        while start < length {
            let suggested = CTTypesetterSuggestLineBreak(typesetter, start, Double(maxWidth))
            let count = max(suggested, 1) // guarantee forward progress even if a glyph can't fit
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
            result.append(line)
            start += count
        }
        return result
    }

    /// Draws only the lines whose box intersects the visible canvas for the
    /// given `scrollOffset`. `scrollOffset` o means ribbon Y maps to
    /// canvas-top-down Y = ribbonY - o (ribbon coordinate at the canvas TOP
    /// edge). We convert that top-down canvas Y into the CGContext's native
    /// bottom-left-origin Y via `canvasHeight - canvasTopDownY` — pure
    /// arithmetic, no CTM flip — so glyphs remain upright.
    func draw(into ctx: CGContext, scrollOffset: CGFloat, style: StyleSettings) {
        guard !lines.isEmpty else { return }

        let canvasHeight = StyleSettings.canvasHeight
        let padding = style.lineHeight / 2 + 8
        let visibleRibbonTop = scrollOffset - padding
        let visibleRibbonBottom = scrollOffset + canvasHeight + padding

        // Binary search the first line whose center could be visible.
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].centerY < visibleRibbonTop { lo = mid + 1 } else { hi = mid }
        }

        let leftMargin = style.horizontalMargin
        let textWidth = style.textWidth

        ctx.saveGState()
        ctx.textMatrix = .identity

        var idx = lo
        while idx < lines.count, lines[idx].centerY <= visibleRibbonBottom {
            let line = lines[idx]
            defer { idx += 1 }

            let canvasTopDownY = line.baselineY - scrollOffset
            let cgY = canvasHeight - canvasTopDownY

            var x = leftMargin
            if style.alignment == .center {
                let lineWidth = CGFloat(CTLineGetTypographicBounds(line.ctLine, nil, nil, nil))
                x = leftMargin + max(0, (textWidth - lineWidth) / 2)
            }

            ctx.textPosition = CGPoint(x: x, y: cgY)
            CTLineDraw(line.ctLine, ctx)
        }

        ctx.restoreGState()
    }
}
