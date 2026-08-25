import Foundation
import CoreGraphics

/// Maps time (seconds, script timeline) to a vertical scroll offset in ribbon
/// pixels. Monotone cubic Hermite interpolation (Fritsch–Carlson), so the
/// scroll passes through every control point exactly (exact cue timings),
/// speed changes are smooth, and the text never scrolls backward.
struct ScrollCurve {
    private let times: [Double]
    private let values: [Double]
    private let tangents: [Double]

    /// Control points must have strictly increasing times and non-decreasing
    /// offsets. Violations are sanitized (sorted, deduplicated, clamped).
    init(points rawPoints: [(time: Double, offset: Double)]) {
        var pts = rawPoints.sorted { $0.time < $1.time }
        // Deduplicate near-equal times, keeping the later offset.
        var cleaned: [(Double, Double)] = []
        for p in pts {
            if let last = cleaned.last, p.time - last.0 < 1e-6 {
                cleaned[cleaned.count - 1].1 = max(last.1, p.offset)
            } else {
                cleaned.append((p.time, p.offset))
            }
        }
        // Enforce monotone non-decreasing offsets.
        for i in 1..<max(cleaned.count, 1) where i < cleaned.count {
            cleaned[i].1 = max(cleaned[i].1, cleaned[i - 1].1)
        }
        if cleaned.isEmpty { cleaned = [(0, 0)] }
        pts = cleaned

        let n = pts.count
        let t = pts.map { $0.0 }
        let y = pts.map { $0.1 }
        var m = [Double](repeating: 0, count: n)

        if n > 1 {
            // Secant slopes.
            var d = [Double](repeating: 0, count: n - 1)
            for i in 0..<(n - 1) {
                let dt = t[i + 1] - t[i]
                d[i] = dt > 0 ? (y[i + 1] - y[i]) / dt : 0
            }
            // Initial tangents.
            m[0] = d[0]
            m[n - 1] = d[n - 2]
            for i in 1..<(n - 1) {
                m[i] = (d[i - 1] + d[i]) / 2
            }
            // Fritsch–Carlson monotonicity filter.
            for i in 0..<(n - 1) {
                if d[i] == 0 {
                    m[i] = 0
                    m[i + 1] = 0
                } else {
                    let a = m[i] / d[i]
                    let b = m[i + 1] / d[i]
                    let s = a * a + b * b
                    if s > 9 {
                        let tau = 3 / s.squareRoot()
                        m[i] = tau * a * d[i]
                        m[i + 1] = tau * b * d[i]
                    }
                }
            }
        }

        self.times = t
        self.values = y
        self.tangents = m
    }

    var startTime: Double { times.first ?? 0 }
    var endTime: Double { times.last ?? 0 }
    var endOffset: Double { values.last ?? 0 }

    func offset(at time: Double) -> Double {
        guard times.count > 1 else { return values.first ?? 0 }
        if time <= times[0] { return values[0] }
        if time >= times[times.count - 1] { return values[values.count - 1] }
        // Binary search for the interval containing `time`.
        var lo = 0, hi = times.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if times[mid] <= time { lo = mid } else { hi = mid }
        }
        let h = times[hi] - times[lo]
        guard h > 0 else { return values[lo] }
        let s = (time - times[lo]) / h
        let s2 = s * s
        let s3 = s2 * s
        let h00 = 2 * s3 - 3 * s2 + 1
        let h10 = s3 - 2 * s2 + s
        let h01 = -2 * s3 + 3 * s2
        let h11 = s3 - s2
        return h00 * values[lo] + h10 * h * tangents[lo]
             + h01 * values[hi] + h11 * h * tangents[hi]
    }
}
