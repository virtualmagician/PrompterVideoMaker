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
        /// This line's UTF-16 range within its segment's plain text.
        let range: NSRange
    }

    struct SegmentExtent {
        let firstLineCenterY: CGFloat
        let lastLineCenterY: CGFloat
    }

    let lines: [Line]
    let segmentExtents: [SegmentExtent]
    let totalHeight: CGFloat
    /// Marker-free text per segment (parallel to the script's segments).
    let segmentPlainTexts: [String]

    private static let foregroundColorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)

    init(script: Script, style: StyleSettings) {
        let font = style.resolvedFont()
        let fm = NSFontManager.shared
        let boldFont = fm.convert(font, toHaveTrait: .boldFontMask)
        let italicFont = fm.convert(font, toHaveTrait: .italicFontMask)
        let boldItalicFont = fm.convert(boldFont, toHaveTrait: .italicFontMask)
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
                italicFont: italicFont,
                boldItalicFont: boldItalicFont,
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
                builtLines.append(Line(ctLine: empty, baselineY: baselineY, centerY: centerY, segmentIndex: segIndex, range: NSRange(location: 0, length: 0)))
                firstCenter = centerY
                lastCenter = centerY
                cursorTop += blankHeight
            } else {
                for (ctLine, lineRange) in ctLines {
                    let centerY = cursorTop + lineHeight / 2
                    let baselineY = Self.baseline(forCenterY: centerY, lineHeight: lineHeight, font: font)
                    builtLines.append(Line(ctLine: ctLine, baselineY: baselineY, centerY: centerY, segmentIndex: segIndex, range: lineRange))
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
        self.segmentPlainTexts = parsed.map { $0.plain }
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
        italicFont: NSFont,
        boldItalicFont: NSFont,
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

        // Overlay emphasis; ranges refer to the plain text, which is exactly
        // the chunk texts joined by single spaces. Bold/italic can overlap,
        // so fonts are applied from per-character masks.
        let totalLen = result.length
        let masks = EmphasisMarkup.characterAttributes(runs: runs, length: totalLen)
        var i = 0
        while i < totalLen {
            let bold = masks[i].contains(.bold)
            let italic = masks[i].contains(.italic)
            var j = i
            while j < totalLen,
                  masks[j].contains(.bold) == bold,
                  masks[j].contains(.italic) == italic { j += 1 }
            if bold || italic {
                let f = bold && italic ? boldItalicFont : (bold ? boldFont : italicFont)
                result.addAttribute(.font, value: f, range: NSRange(location: i, length: j - i))
            }
            i = j
        }
        for run in runs {
            let lo = max(0, min(run.range.lowerBound, totalLen))
            let hi = max(lo, min(run.range.upperBound, totalLen))
            guard hi > lo else { continue }
            let r = NSRange(location: lo, length: hi - lo)
            if run.underline {
                result.addAttribute(Self.underlineKey, value: CTUnderlineStyle.single.rawValue as NSNumber, range: r)
            }
            if run.accent { result.addAttribute(foregroundColorKey, value: accent, range: r) }
        }
        return result
    }

    // MARK: - Hit-testing & highlight geometry (for in-preview formatting)

    /// The X where a line's glyphs start on the canvas (honors alignment).
    func xOrigin(of line: Line, style: StyleSettings) -> CGFloat {
        var x = style.horizontalMargin
        if style.alignment == .center {
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line.ctLine, nil, nil, nil))
            x += max(0, (style.textWidth - lineWidth) / 2)
        }
        return x
    }

    /// Maps a canvas point (top-down, 1920x1080) at the given scroll offset to
    /// the whitespace-delimited word under it, as (segmentIndex, UTF-16 range
    /// in that segment's plain text).
    func wordHit(canvasPoint: CGPoint, scrollOffset: CGFloat, style: StyleSettings) -> (segmentIndex: Int, plainRange: Range<Int>)? {
        guard !lines.isEmpty else { return nil }
        let ribbonY = canvasPoint.y + scrollOffset
        var best: Line?
        var bestDist = CGFloat.greatestFiniteMagnitude
        // Spacer (empty) lines can be shorter than lineHeight and must never
        // shadow an adjacent text line, so only selectable lines compete.
        for line in lines where line.range.length > 0 {
            let d = abs(line.centerY - ribbonY)
            if d < bestDist { bestDist = d; best = line }
        }
        guard let line = best, bestDist <= style.lineHeight / 2 else { return nil }
        let x0 = xOrigin(of: line, style: style)
        let relX = canvasPoint.x - x0
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line.ctLine, nil, nil, nil))
        guard relX >= -10, relX <= lineWidth + 10 else { return nil }
        var idx = CTLineGetStringIndexForPosition(line.ctLine, CGPoint(x: relX, y: 0))
        guard idx != kCFNotFound else { return nil }
        let lineEnd = line.range.location + line.range.length
        if idx >= lineEnd { idx = lineEnd - 1 }
        guard line.segmentIndex < segmentPlainTexts.count else { return nil }
        let plain = segmentPlainTexts[line.segmentIndex]
        guard let word = EmphasisMarkup.wordRange(inPlain: plain, at: idx) else { return nil }
        return (line.segmentIndex, word)
    }

    /// Bounding boxes (ribbon coords, top-down) for a plain-text range within
    /// one segment — one rect per wrapped line the range touches.
    func rects(forSegment segIndex: Int, plainRange: Range<Int>, style: StyleSettings) -> [CGRect] {
        var out: [CGRect] = []
        for line in lines where line.segmentIndex == segIndex && line.range.length > 0 {
            let lineLo = line.range.location
            let lineHi = lineLo + line.range.length
            let lo = max(plainRange.lowerBound, lineLo)
            let hi = min(plainRange.upperBound, lineHi)
            guard hi > lo else { continue }
            let x0 = xOrigin(of: line, style: style)
            let xa = CGFloat(CTLineGetOffsetForStringIndex(line.ctLine, lo, nil))
            let xb = CGFloat(CTLineGetOffsetForStringIndex(line.ctLine, hi, nil))
            out.append(CGRect(
                x: x0 + min(xa, xb),
                y: line.centerY - style.lineHeight / 2,
                width: abs(xb - xa),
                height: style.lineHeight
            ))
        }
        return out
    }

    /// Manual CoreText line-breaking so we control line height ourselves
    /// (rather than relying on CTFramesetter's natural leading).
    private static func wrapLines(attrString: NSAttributedString, maxWidth: CGFloat) -> [(line: CTLine, range: NSRange)] {
        guard attrString.length > 0 else { return [] }
        let typesetter = CTTypesetterCreateWithAttributedString(attrString as CFAttributedString)
        var result: [(CTLine, NSRange)] = []
        var start = 0
        let length = attrString.length
        while start < length {
            let suggested = CTTypesetterSuggestLineBreak(typesetter, start, Double(maxWidth))
            let count = max(suggested, 1) // guarantee forward progress even if a glyph can't fit
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
            result.append((line, NSRange(location: start, length: count)))
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
