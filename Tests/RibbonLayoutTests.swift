import Testing
import Foundation
@testable import PrompterVideoMaker

@Suite struct RibbonLayoutTests {
    private func makeScript(_ texts: [String]) -> Script {
        var t = 0.0
        var segs: [Segment] = []
        for text in texts {
            segs.append(Segment(text: text, start: t, end: t + 2))
            t += 3
        }
        return Script(segments: segs)
    }

    @Test func linesAreUniformlySpacedAcrossSegments() {
        let script = makeScript([
            "Thank you Peter and good evening everyone here tonight",
            "My name is Marco Tempest.",
            "I lead Creative Technology and Innovation at ETH Zurich Space.",
        ])
        let style = StyleSettings()
        let layout = RibbonLayout(script: script, style: style)
        #expect(layout.lines.count >= 3)
        for i in 1..<layout.lines.count {
            let delta = layout.lines[i].centerY - layout.lines[i - 1].centerY
            #expect(abs(delta - style.lineHeight) < 0.001,
                    "non-uniform spacing between lines \(i - 1) and \(i): \(delta)")
        }
        #expect(abs(layout.totalHeight - CGFloat(layout.lines.count) * style.lineHeight) < 0.001)
    }

    @Test func emptySegmentOccupiesExactlyOneBlankLine() {
        let script = makeScript(["First cue text.", "", "Third cue text."])
        let style = StyleSettings()
        let layout = RibbonLayout(script: script, style: style)

        let blankLines = layout.lines.filter { $0.segmentIndex == 1 }
        #expect(blankLines.count == 1)
        #expect(layout.segmentExtents.count == 3)
        // The blank line sits exactly one line height below the previous line
        // and one above the next — uniform spacing preserved.
        for i in 1..<layout.lines.count {
            let delta = layout.lines[i].centerY - layout.lines[i - 1].centerY
            #expect(abs(delta - style.lineHeight) < 0.001)
        }
        // Extents for the blank segment are that single line's center.
        let ext = layout.segmentExtents[1]
        #expect(ext.firstLineCenterY == ext.lastLineCenterY)
        #expect(ext.firstLineCenterY == blankLines[0].centerY)
    }
}
