import Testing
import Foundation
@testable import PrompterVideoMaker

@Suite struct ScrollCurveTests {
    @Test func hitsControlPointsExactly() {
        let pts: [(time: Double, offset: Double)] = [(0, 0), (2, 300), (5, 900), (9, 1000)]
        let curve = ScrollCurve(points: pts)
        for p in pts {
            #expect(abs(curve.offset(at: p.time) - p.offset) < 1e-9)
        }
    }

    @Test func isMonotone() {
        let pts: [(time: Double, offset: Double)] = [(0, 0), (1, 500), (1.5, 510), (4, 512), (6, 2000), (7, 2001)]
        let curve = ScrollCurve(points: pts)
        var prev = -Double.infinity
        for i in 0...1000 {
            let t = Double(i) * 7.0 / 1000.0
            let v = curve.offset(at: t)
            #expect(v >= prev - 1e-9, "curve went backward at t=\(t)")
            prev = v
        }
    }

    @Test func clampsOutsideRange() {
        let curve = ScrollCurve(points: [(1, 100), (2, 200)])
        #expect(curve.offset(at: -5) == 100)
        #expect(curve.offset(at: 99) == 200)
    }

    @Test func sanitizesUnsortedAndDuplicateInput() {
        let curve = ScrollCurve(points: [(2, 200), (0, 0), (2, 180), (3, 150)])
        // Duplicate time 2 collapses; offset at 3 clamps up to >= offset at 2.
        #expect(curve.offset(at: 3) >= curve.offset(at: 2))
        var prev = -Double.infinity
        for i in 0...300 {
            let t = Double(i) / 100.0 * 3.0
            let v = curve.offset(at: t)
            #expect(v >= prev - 1e-9)
            prev = v
        }
    }
}
