import Foundation
import CoreGraphics
import CoreText
import AppKit

/// What the export slate shows.
struct TitleCardInfo {
    var projectName: String
    var exportDate: Date
    var videoDuration: Double
}

/// Draws the one-frame title card (slate) at the start of exported videos:
/// project name, export date, duration — in the project's own colors.
enum TitleCardRenderer {

    static func draw(info: TitleCardInfo, style: StyleSettings, into ctx: CGContext, size: CGSize) {
        ctx.saveGState()
        ctx.setFillColor(style.backgroundColor.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))

        let scaleX = size.width / StyleSettings.canvasWidth
        let scaleY = size.height / StyleSettings.canvasHeight
        ctx.scaleBy(x: scaleX, y: scaleY)

        let canvasW = StyleSettings.canvasWidth
        let canvasH = StyleSettings.canvasHeight
        let primary = style.primaryTextColor.cgColor
        let secondary = style.secondaryTextColor.cgColor

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        let total = Int(info.videoDuration.rounded())
        let durationText = String(format: "%d:%02d", total / 60, total % 60)
        let detailText = "\(dateFormatter.string(from: info.exportDate))   ·   \(durationText)"

        let titleFont = NSFont(name: style.fontName, size: 110)
            ?? NSFont.systemFont(ofSize: 110, weight: .semibold)
        let detailFont = NSFont(name: style.fontName, size: 44)
            ?? NSFont.systemFont(ofSize: 44, weight: .regular)

        let fgKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let titleLine = CTLineCreateWithAttributedString(NSAttributedString(
            string: info.projectName,
            attributes: [.font: titleFont, fgKey: primary]))
        let detailLine = CTLineCreateWithAttributedString(NSAttributedString(
            string: detailText,
            attributes: [.font: detailFont, fgKey: secondary]))

        ctx.textMatrix = .identity

        func centeredX(_ line: CTLine) -> CGFloat {
            let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            return max(style.horizontalMargin, (canvasW - w) / 2)
        }

        // Title slightly above center; details below; a thin accent rule between.
        let titleBaselineCG = canvasH * 0.52
        ctx.textPosition = CGPoint(x: centeredX(titleLine), y: titleBaselineCG)
        CTLineDraw(titleLine, ctx)

        let ruleY = titleBaselineCG - 64
        ctx.setFillColor(style.resolvedEmphasisColor.cgColor)
        ctx.fill(CGRect(x: (canvasW - 220) / 2, y: ruleY, width: 220, height: 6))

        ctx.textPosition = CGPoint(x: centeredX(detailLine), y: ruleY - 96)
        CTLineDraw(detailLine, ctx)

        ctx.restoreGState()
    }
}
