// Generates the app icon PNG (1024x1024): dark rounded square with
// prompter-style text bars and the orange read marker.
// Usage: swift Scripts/make_icon.swift /path/to/AppIcon_1024.png
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon_1024.png"
let S: CGFloat = 1024

let ctx = CGContext(
    data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

// Background: rounded dark square with subtle vertical gradient.
let corner: CGFloat = 232
let rect = CGRect(x: 0, y: 0, width: S, height: S).insetBy(dx: 36, dy: 36)
let path = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
ctx.addPath(path)
ctx.clip()
let colors = [CGColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1),
              CGColor(srgbRed: 0.02, green: 0.02, blue: 0.03, alpha: 1)] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])

// Text bars (prompter lines), alternating white/green, varying widths.
let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.96)
let green = CGColor(srgbRed: 0.28, green: 0.87, blue: 0.34, alpha: 0.96)
let barH: CGFloat = 64
let gap: CGFloat = 56
let leftX: CGFloat = 260
let widths: [CGFloat] = [520, 430, 560, 380, 500, 300]
let colorsSeq = [white, white, green, white, green, white]
let totalH = CGFloat(widths.count) * barH + CGFloat(widths.count - 1) * gap
var y = (S + totalH) / 2 - barH
for (i, w) in widths.enumerated() {
    ctx.setFillColor(colorsSeq[i])
    let r = CGRect(x: leftX, y: y, width: w, height: barH)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: barH / 2, cornerHeight: barH / 2, transform: nil))
    ctx.fillPath()
    y -= barH + gap
}

// Orange marker triangle pointing right at the 3rd bar from top.
let markerColor = CGColor(srgbRed: 0.91, green: 0.32, blue: 0.18, alpha: 1)
let markerCenterY = (S + totalH) / 2 - barH / 2 - 2 * (barH + gap)
ctx.setFillColor(markerColor)
ctx.beginPath()
ctx.move(to: CGPoint(x: 118, y: markerCenterY + 62))
ctx.addLine(to: CGPoint(x: 118, y: markerCenterY - 62))
ctx.addLine(to: CGPoint(x: 224, y: markerCenterY))
ctx.closePath()
ctx.fillPath()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
