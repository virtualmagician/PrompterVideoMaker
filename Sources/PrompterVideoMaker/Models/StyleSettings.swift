import Foundation
import AppKit

/// Codable RGBA color used throughout the app.
struct RGBAColor: Codable, Equatable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1.0) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(nsColor: NSColor) {
        let c = nsColor.usingColorSpace(.sRGB) ?? .white
        self.init(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
    }

    /// "#RRGGBB" or "#RRGGBBAA"; returns nil for malformed input.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255)
        } else {
            self.init(r: Double((v >> 24) & 0xFF) / 255, g: Double((v >> 16) & 0xFF) / 255,
                      b: Double((v >> 8) & 0xFF) / 255, a: Double(v & 0xFF) / 255)
        }
    }

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var cgColor: CGColor { nsColor.cgColor }

    static let black = RGBAColor(r: 0, g: 0, b: 0)
    static let white = RGBAColor(r: 1, g: 1, b: 1)
    /// Accent used by ==emphasis== markup (warm yellow).
    static let emphasisYellow = RGBAColor(r: 1.0, g: 0.84, b: 0.04)
    /// Prompter green (like the reference still).
    static let promptGreen = RGBAColor(r: 0.28, g: 0.87, b: 0.34)
    /// Marker red-orange.
    static let markerOrange = RGBAColor(r: 0.91, g: 0.32, b: 0.18)
}

enum TextAlignmentSetting: String, Codable, CaseIterable {
    case leading, center
}

/// Everything that controls how the prompter looks and exports.
/// Canvas is always 1920x1080.
struct StyleSettings: Codable, Equatable {
    static let canvasWidth: CGFloat = 1920
    static let canvasHeight: CGFloat = 1080

    var backgroundColor: RGBAColor = .black
    var primaryTextColor: RGBAColor = .white
    var secondaryTextColor: RGBAColor = .promptGreen
    /// Alternate chunk colors to make long text easier to track.
    var alternatingColors: Bool = true
    /// Color for ==emphasis== markup; overrides the alternating colors.
    /// Optional so projects/defaults saved by older versions still decode.
    var emphasisColor: RGBAColor?
    var resolvedEmphasisColor: RGBAColor { emphasisColor ?? .emphasisYellow }
    /// Maximum words per alternating color chunk.
    var maxChunkWords: Int = 8

    /// Height of an empty-line (spacer) segment as a multiple of the line
    /// height. Optional so older saved projects/defaults still decode.
    var blankLineHeightMultiple: CGFloat?
    var resolvedBlankLineHeight: CGFloat { blankLineHeightMultiple ?? 1.0 }

    /// PostScript name; resolved with `resolvedFont()`.
    var fontName: String = "HelveticaNeue"
    /// In canvas pixels (1920x1080 space).
    var fontSize: CGFloat = 96
    /// Line height = fontSize * lineHeightMultiple.
    var lineHeightMultiple: CGFloat = 1.6
    var horizontalMargin: CGFloat = 100
    var alignment: TextAlignmentSetting = .leading

    var markerEnabled: Bool = true
    var markerColor: RGBAColor = .markerOrange
    /// Marker vertical position as fraction of canvas height from the top.
    var markerYFraction: CGFloat = 0.38
    /// Horizontal mirror for beam-splitter prompter glass.
    var mirrored: Bool = false

    // Export settings
    var fps: Int = 60
    /// Seconds of roll-in before the first cue.
    var leadIn: Double = 2.0
    /// Seconds of hold after the last cue.
    var leadOut: Double = 2.0
    var includeAudio: Bool = true

    init() {}

    func resolvedFont() -> NSFont {
        NSFont(name: fontName, size: fontSize)
            ?? NSFont.systemFont(ofSize: fontSize, weight: .regular)
    }

    var lineHeight: CGFloat { fontSize * lineHeightMultiple }
    var visibleLines: Double { Double(Self.canvasHeight / lineHeight) }
    var markerY: CGFloat { Self.canvasHeight * markerYFraction }
    var textWidth: CGFloat { Self.canvasWidth - horizontalMargin * 2 }
}
