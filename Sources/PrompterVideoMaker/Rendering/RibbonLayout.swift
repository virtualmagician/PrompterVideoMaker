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
        let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let primaryColor = style.primaryTextColor.cgColor
        let secondaryColor = style.secondaryTextColor.cgColor
        let accentColor = style.resolvedEmphasisColor.cgColor
        let lineHeight = style.lineHeight
        let textWidth = max(1, style.textWidth)

        // Emphasis markup (**bold** __underline__ ==accent==) is parsed out
        // first; chunking and layout run on the plain text.
        let parsed = script.segments.map { EmphasisMarkup.parse($0.text) }
        var plainSegments = script.segments
        for i in plainSegments.indices { plainSegments[i].text = parsed[i].plain }

        let chunkGroups = Chunker.chunks(
            for: plainSegments,
            maxWords: style.maxChunkWords,
            alternate: style.alternatingColors
        )

        var builtLines: [Line] = []
        var extents: [SegmentExtent] = []
        var cursorTop: CGFloat = 0

        for (segIndex, _) in script.segments.enumerated() {
            let chunks = segIndex < chunkGroups.count ? chunkGroups[segIndex] : []
            let attrString = Self.buildAttributedString(
                chunks: chunks,
                runs: parsed[segIndex].runs,
                font: font,
                boldFont: boldFont,
                primary: primaryColor,
                secondary: secondaryColor,
                accent: accentColor,
                fallbackText: parsed[segIndex].plain
            )
            let ctLines = Self.wrapLines(attrString: attrString, maxWidth: textWidth)

            var firstCenter: CGFloat?
            var lastCenter: CGFloat = cursorTop + lineHeight / 2

            if ctLines.isEmpty {
                // Reserve a blank (spacer) line; its height is adjustable via
                // style.blankLineHeightMultiple.
                let blankHeight = lineHeight * max(0.1, style.resolvedBlankLineHeight)
                let centerY = cursorTop + blankHeight / 2
                let baselineY = Self.baseline(forCenterY: centerY, lineHeight: blankHeight, font: font)
                let empty = CTLineCreateWithAttributedString(NSAttributedString(string: "", attributes: [.font: font]))
                builtLines.append(Line(ctLine: empty, baselineY: baselineY, centerY: centerY, segmentIndex: segIndex))
                firstCenter = centerY
                lastCenter = centerY
                cursorTop += blankHeight
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

    private static let underlineKey = NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)

    private static func buildAttributedString(
        chunks: [TextChunk],
        runs: [EmphasisMarkup.Run],
        font: NSFont,
        boldFont: NSFont,
        primary: CGColor,
        secondary: CGColor,
        accent: CGColor,
        fallbackText: String
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        if chunks.isEmpty {
            if !fallbackText.isEmpty {
                result.append(NSAttributedString(
                    string: fallbackText,
                    attributes: [.font: font, foregroundColorKey: primary]
                ))
            }
        } else {
            for (i, chunk) in chunks.enumerated() {
                let color = chunk.colorIndex == 0 ? primary : secondary
                if i > 0 {
                    result.append(NSAttributedString(string: " ", attributes: [.font: font, foregroundColorKey: color]))
                }
                result.append(NSAttributedString(string: chunk.text, attributes: [.font: font, foregroundColorKey: color]))
            }
        }

        // Overlay emphasis runs; their UTF-16 ranges refer to the plain text,
        // which is exactly the chunk texts joined by single spaces.
        let totalLen = result.length
        for run in runs {
            let lo = max(0, min(run.range.lowerBound, totalLen))
            let hi = max(lo, min(run.range.upperBound, totalLen))
            guard hi > lo else { continue }
            let r = NSRange(location: lo, length: hi - lo)
            if run.bold { result.addAttribute(.font, value: boldFont, range: r) }
            if run.underline {
                result.addAttribute(Self.underlineKey, value: CTUnderlineStyle.single.rawValue as NSNumber, range: r)
            }
            if run.accent { result.addAttribute(foregroundColorKey, value: accent, range: r) }
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
