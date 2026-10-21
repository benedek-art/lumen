// CropGuides.swift
// What the crop rectangle draws inside itself, as line segments in the rectangle's own
// units — so the triangle's right angles and the spiral's convergence can be tested
// here, and the overlay only strokes what this hands it.
//
// Lightroom's O cycle is Thirds, Grid, Diagonal, Triangle, Golden Ratio, Golden Spiral
// (and Aspect Ratios); ⇧O turns the two shapes that have a handedness. The order below
// puts the two most used first and None last, so one press from the default is a
// different guide and the cycle ends somewhere clean.

import Foundation

public enum CropGuides {

    public enum Style: String, CaseIterable, Identifiable, Sendable {
        /// Spelled `off` rather than `none`: a case called `none` on a non-optional
        /// value reads as `Optional.none` to every human who glances at a comparison.
        case off
        case thirds
        case golden
        case grid
        case diagonals
        case triangle
        case spiral

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .off: return "None"
            case .thirds: return "Thirds"
            case .golden: return "Golden Ratio"
            case .grid: return "Grid"
            case .diagonals: return "Diagonals"
            case .triangle: return "Golden Triangle"
            case .spiral: return "Golden Spiral"
            }
        }

        /// What O moves to next.
        public var next: Style {
            switch self {
            case .thirds: return .golden
            case .golden: return .grid
            case .grid: return .diagonals
            case .diagonals: return .triangle
            case .triangle: return .spiral
            case .spiral: return .off
            case .off: return .thirds
            }
        }

        /// How many distinct ways ⇧O can turn this guide; 1 for the symmetric ones.
        public var orientations: Int {
            switch self {
            case .triangle: return 2
            case .spiral: return 4
            default: return 1
            }
        }

        /// The fractions of each edge the straight divisions sit at, or nil.
        public var divisions: [Double]? {
            switch self {
            case .thirds: return [1.0 / 3, 2.0 / 3]
            case .grid: return [0.25, 0.5, 0.75]
            // 1 − 1/φ and 1/φ: the 0.382 and 0.618 photographers know.
            case .golden: return [1 - 1 / phi, 1 / phi]
            default: return nil
            }
        }
    }

    public static let phi = (1 + 5.0.squareRoot()) / 2

    /// One straight piece of a guide, in the rectangle's own units, origin top-left,
    /// y downward.
    public struct Segment: Equatable, Sendable {
        public var x0, y0, x1, y1: Double
        public init(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) {
            self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1
        }
    }

    /// Divisions of the fine grid drawn while the angle is changing — denser than the
    /// Grid guide, because what it is for is judging lines against it, not composing.
    public static let rotationGridDivisions = 8

    /// The segments of `style` in a `width × height` rectangle. `orientation` is taken
    /// modulo the style's count. Curves come back as short chords.
    public static func segments(_ style: Style, width: Double, height: Double,
                                orientation: Int = 0) -> [Segment] {
        guard width > 0, height > 0, width.isFinite, height.isFinite else { return [] }
        if let divisions = style.divisions { return lines(at: divisions, width, height) }
        let turn = ((orientation % style.orientations) + style.orientations)
            % style.orientations
        switch style {
        case .diagonals:
            return [Segment(0, 0, width, height), Segment(width, 0, 0, height)]
        case .triangle:
            return triangle(width, height, mirrored: turn == 1)
        case .spiral:
            return spiral(width, height, flipX: turn == 1 || turn == 2,
                          flipY: turn == 2 || turn == 3)
        default:
            return []
        }
    }

    /// The fine grid shown while rotating.
    public static func rotationGrid(width: Double, height: Double) -> [Segment] {
        let n = rotationGridDivisions
        return lines(at: (1..<n).map { Double($0) / Double(n) }, width, height)
    }

    // MARK: Internals

    private static func lines(at fractions: [Double], _ w: Double, _ h: Double) -> [Segment] {
        fractions.flatMap { f in
            [Segment(w * f, 0, w * f, h), Segment(0, h * f, w, h * f)]
        }
    }

    /// One diagonal, and from each of the other two corners the perpendicular to it.
    /// Perpendicular in the rectangle's REAL units, which is why this takes a width and
    /// height rather than working in a unit square: stretch a unit-square construction
    /// and the right angles stop being right.
    private static func triangle(_ w: Double, _ h: Double, mirrored: Bool) -> [Segment] {
        let a = mirrored ? (w, 0.0) : (0.0, 0.0)
        let b = mirrored ? (0.0, h) : (w, h)
        let others = mirrored ? [(0.0, 0.0), (w, h)] : [(w, 0.0), (0.0, h)]
        var out = [Segment(a.0, a.1, b.0, b.1)]
        let dx = b.0 - a.0, dy = b.1 - a.1
        let len2 = dx * dx + dy * dy
        for p in others {
            let t = ((p.0 - a.0) * dx + (p.1 - a.1) * dy) / len2
            out.append(Segment(p.0, p.1, a.0 + t * dx, a.1 + t * dy))
        }
        return out
    }

    /// The golden spiral as quarter arcs through successively cut squares, built in a
    /// φ:1 rectangle and stretched to this one — Lightroom stretches it the same way,
    /// because a spiral that only fit golden crops would be no guide for a 4:5. A
    /// portrait rectangle gets the construction transposed.
    private static func spiral(_ w: Double, _ h: Double, flipX: Bool,
                               flipY: Bool) -> [Segment] {
        let portrait = h > w
        // Unit construction: a φ × 1 rectangle, landscape.
        var rx = 0.0, ry = 0.0, rw = phi, rh = 1.0
        var points: [(Double, Double)] = []
        let chordsPerQuarter = 12
        for step in 0..<10 {
            let centre: (Double, Double)
            let from: (Double, Double)
            let to: (Double, Double)
            switch step % 4 {
            case 0:     // square off the left
                let s = rh
                centre = (rx + s, ry + s); from = (rx, ry + s); to = (rx + s, ry)
                rx += s; rw -= s
            case 1:     // off the top
                let s = rw
                centre = (rx, ry + s); from = (rx, ry); to = (rx + s, ry + s)
                ry += s; rh -= s
            case 2:     // off the right
                let s = rh
                centre = (rx + rw - s, ry); from = (rx + rw, ry); to = (rx + rw - s, ry + s)
                rw -= s
            default:    // off the bottom
                let s = rw
                centre = (rx + s, ry + rh - s); from = (rx + s, ry + rh)
                to = (rx, ry + rh - s)
                rh -= s
            }
            let a0 = atan2(from.1 - centre.1, from.0 - centre.0)
            var sweep = atan2(to.1 - centre.1, to.0 - centre.0) - a0
            if sweep > .pi { sweep -= 2 * .pi }
            if sweep < -.pi { sweep += 2 * .pi }
            let r = ((from.0 - centre.0) * (from.0 - centre.0)
                     + (from.1 - centre.1) * (from.1 - centre.1)).squareRoot()
            let first = points.isEmpty ? 0 : 1
            for i in first...chordsPerQuarter {
                let a = a0 + sweep * Double(i) / Double(chordsPerQuarter)
                points.append((centre.0 + r * cos(a), centre.1 + r * sin(a)))
            }
        }
        // Map the φ × 1 construction onto the rectangle.
        let mapped = points.map { p -> (Double, Double) in
            var u = p.0 / phi, v = p.1
            if portrait { swap(&u, &v) }
            if flipX { u = 1 - u }
            if flipY { v = 1 - v }
            return (Swift.min(Swift.max(u, 0), 1) * w, Swift.min(Swift.max(v, 0), 1) * h)
        }
        return zip(mapped, mapped.dropFirst()).map { Segment($0.0, $0.1, $1.0, $1.1) }
    }
}
