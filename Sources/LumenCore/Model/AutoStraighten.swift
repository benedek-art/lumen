// AutoStraighten.swift
// Lightroom's Auto straighten: find the tilt of the picture's dominant straight lines —
// a horizon, a roofline, the verticals of a building — and return the angle that
// levels them. It SETS the Angle field and hides behind nothing, the way the ruler does
// (docs/09: "auto sets sliders, never hides behind them").
//
// THE METHOD, and why not a gradient-orientation histogram. A 3×3 gradient measures a
// direction per pixel to a few degrees at best, and the pixel grid biases every
// textured region toward exactly 0° and 45° — so the histogram's peak is pulled toward
// "already level", which is the one wrong answer Auto must not give. What defines a
// tilted horizon is not the local direction of its pixels but that they are COLLINEAR.
// So: take the strong edge pixels, split them into a near-horizontal and a
// near-vertical family by their local direction, and for each candidate tilt t project
// each family onto the normal of its lines at t. At the true tilt every long line
// collapses into one bin of that projection and the profile turns spiky; its energy
// (the sum of squared bin weights) peaks there. A camera roll turns horizontals and
// verticals by the same angle, so the two families' energies add.
//
// THE SIGN is `Straighten`'s derivation: a source direction s appears on the frame at
// `angle + s` (mirrored: `−(angle + s)`), so levelling a line seen at s on the
// UNTURNED frame needs `angle = −s`. Measured on a mirrored plate the line is seen at
// −s and the answer is +s. Both are independent of the angle the recipe holds now,
// because the plate this reads is drawn with the angle left off.

import Foundation

public enum AutoStraighten {

    /// The widest tilt Auto searches, either way. Beyond this a "dominant line" is
    /// more often a diagonal in the composition than a horizon that drifted.
    public static let searchDegrees: Double = 20

    /// How many times the best tilt's energy must exceed the median over the search
    /// before Auto believes it anywhere in the search. Pure texture and noise sit near
    /// 1; a horizon or a building scores 1.5–4.4 on the corpus (REPORT.md).
    ///
    /// Deliberately one bar, not two. A weaker tier for small corrections was tried
    /// and measured: frames scoring 1.15–1.35 (a gate behind foliage, a soft field
    /// horizon) were off by a median 0.43° and up to 4.1° on turned copies, against
    /// 0.06° median and 0.69° worst above this bar (REPORT.md). A wrong Auto is worse
    /// than an honest "nothing to level".
    public static let minimumConfidence: Double = 1.35

    public struct Estimate: Equatable, Sendable {
        /// The angle `geometry.angle` should hold to level the lines, clamped to the
        /// straighten range.
        public var angle: Double
        /// The tilt the lines were found at on the plate, y downward, degrees.
        public var observedTilt: Double
        /// Best energy ÷ median energy over the search.
        public var confidence: Double
    }

    /// Estimate the levelling angle from a luma plane (row-major, y downward, any
    /// scale — only edges matter). Nil when nothing in the frame is straight enough to
    /// trust, in which case the caller changes nothing.
    ///
    /// `plateIsFlipped` says whether the plate was drawn mirrored (the crop canvas
    /// draws it with the flip applied). Size it to ~800 px on the long edge: finer
    /// costs time for no accuracy, coarser loses short lines.
    public static func estimate(luma: [Float], width: Int, height: Int,
                                plateIsFlipped: Bool = false) -> Estimate? {
        guard width >= 16, height >= 16, luma.count == width * height else { return nil }

        // 1. Sobel, and the strong edge points with their local line direction.
        struct EdgePoint { var x: Double; var y: Double; var w: Double }
        var horizontal: [EdgePoint] = []
        var vertical: [EdgePoint] = []
        var magnitudes: [Float] = []
        magnitudes.reserveCapacity(width * height / 4)
        var raw: [(Int, Int, Float, Float)] = []
        raw.reserveCapacity(width * height / 4)
        @inline(__always) func at(_ x: Int, _ y: Int) -> Float { luma[y * width + x] }
        let margin = 2
        for y in margin..<(height - margin) {
            for x in margin..<(width - margin) {
                let gx = (at(x + 1, y - 1) + 2 * at(x + 1, y) + at(x + 1, y + 1))
                    - (at(x - 1, y - 1) + 2 * at(x - 1, y) + at(x - 1, y + 1))
                let gy = (at(x - 1, y + 1) + 2 * at(x, y + 1) + at(x + 1, y + 1))
                    - (at(x - 1, y - 1) + 2 * at(x, y - 1) + at(x + 1, y - 1))
                let m = (gx * gx + gy * gy).squareRoot()
                guard m.isFinite, m > 0 else { continue }
                magnitudes.append(m)
                raw.append((x, y, gx, gy))
            }
        }
        guard !magnitudes.isEmpty else { return nil }
        // Strong edges only: the top 12 %, and never anything a flat frame's rounding
        // could produce. Sobel on a [0, 1] plane answers ~4× the step height.
        let sorted = magnitudes.sorted()
        let percentile = sorted[Swift.min(sorted.count - 1, Int(Double(sorted.count) * 0.88))]
        let floor = Swift.max(percentile, 0.08)
        // Edges somewhat past the search vote too. They mostly feed the median the
        // confidence is measured against; narrowing this to +1° was tried and let
        // foliage frames through (REPORT.md). The rim guard below handles diagonals.
        let band = searchDegrees + 8
        for (x, y, gx, gy) in raw {
            let m = (gx * gx + gy * gy).squareRoot()
            guard m >= floor else { continue }
            // The line runs perpendicular to the gradient.
            let line = atan2(Double(gy), Double(gx)) * 180 / .pi + 90
            let dev = Straighten.wrapToAxis(line)
            // Which axis it is near: the wrap says how far, the raw angle says which.
            var folded = line.truncatingRemainder(dividingBy: 180)
            if folded < 0 { folded += 180 }
            let nearVertical = abs(folded - 90) < 45
            guard abs(dev) <= band else { continue }
            let p = EdgePoint(x: Double(x), y: Double(y), w: Double(m))
            if nearVertical { vertical.append(p) } else { horizontal.append(p) }
        }
        guard horizontal.count + vertical.count >= 40 else { return nil }

        // 2. Projection-profile energy per candidate tilt.
        let diagonal = Double(width + height)
        let bins = Int(diagonal * 2) + 8
        var profile = [Double](repeating: 0, count: bins)
        func energy(_ tilt: Double) -> Double {
            let r = tilt * .pi / 180
            let c = cos(r), s = sin(r)
            var total = 0.0
            for (family, isVertical) in [(horizontal, false), (vertical, true)] where !family.isEmpty {
                for i in profile.indices { profile[i] = 0 }
                for p in family {
                    // Horizontal lines at tilt t run along (cos t, sin t); their normal
                    // coordinate is −x·sin t + y·cos t. Verticals run along
                    // (−sin t, cos t); theirs is x·cos t + y·sin t.
                    let rho = isVertical ? p.x * c + p.y * s : -p.x * s + p.y * c
                    let index = Int((rho + diagonal).rounded())
                    if index >= 0 && index < bins { profile[index] += p.w }
                }
                var e = 0.0
                for v in profile where v > 0 { e += v * v }
                total += e
            }
            return total
        }

        var samples: [(Double, Double)] = []
        var t = -searchDegrees
        while t <= searchDegrees + 1e-9 {
            samples.append((t, energy(t)))
            t += 0.25
        }
        guard let coarse = samples.max(by: { $0.1 < $1.1 }) else { return nil }
        let energies = samples.map(\.1).sorted()
        let median = energies[energies.count / 2]
        guard median > 0 else { return nil }
        let confidence = coarse.1 / median
        guard confidence >= minimumConfidence else { return nil }
        // A best AT the rim is a peak outside the search, cut off — a diagonal in the
        // composition, not a horizon. "Levelling" it to ±20° is the worst answer Auto
        // could give, so it gives none.
        guard abs(coarse.0) < searchDegrees - 0.5 else { return nil }

        // 3. Refine around the coarse peak.
        var best = coarse
        var f = Swift.max(coarse.0 - 0.3, -searchDegrees)
        while f <= Swift.min(coarse.0 + 0.3, searchDegrees) + 1e-9 {
            let e = energy(f)
            if e > best.1 { best = (f, e) }
            f += 0.02
        }

        let observed = best.0
        let angle = plateIsFlipped ? observed : -observed
        return Estimate(angle: Num.clamp(angle, -Straighten.limitDegrees, Straighten.limitDegrees),
                        observedTilt: observed, confidence: confidence)
    }
}
