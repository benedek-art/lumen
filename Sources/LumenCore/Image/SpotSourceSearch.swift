// SpotSourceSearch.swift
// Where a new spot borrows from, when the photographer has not said (docs/09: "Auto
// source selection searches an expanding ring around the target, scoring candidates by
// texture similarity and penalizing sources that cross strong edges").
//
// THE SCORE. The destination's interior is the blemish, so it is the one thing a
// search must not compare. What is clean is the RING just outside the spot — the
// context the patch has to sit in — and a good source is one whose own ring matches it:
//
//   · Ring match: the sum of squared differences between the destination's ring and the
//     candidate's, sampled at the same offsets. For Heal the two rings are compared with
//     their means removed, because Heal re-lights the patch to the destination's level
//     (`SpotRetouch`'s membrane) — a source in shade with the right texture is a good
//     Heal source and a bad Clone source, and the score says so.
//   · Interior penalty: the candidate's OWN interior must not carry much more structure than
//     the surroundings do. A source whose rim matches but whose middle holds an edge, a
//     second blemish or a highlight would paste that in; its interior variance beyond the
//     destination ring's is charged.
//   · A small preference for nearer sources, so equally good candidates resolve to the
//     one in the most similar light, and the answer is deterministic.
//
// Everything is measured in the shaper's log domain (`LumenLog.encode`) rather than in
// scene-linear, so a difference means the same thing in shadow and in highlight.
//
// THE SEARCH is an expanding ring of candidates — five distances by 32 directions,
// none closer than just over one diameter, so a source can never overlap the blemish it
// is replacing — followed by a pattern search that halves its step down to an eighth of a
// pixel. That last stage is what lands a periodic texture in phase. Deterministic: no
// random draws, so the same click on the same picture always proposes the same source.
//
// WINDOWED. The app cannot afford to hand this a 45 MP frame per click, and does not
// need to: `window(for:)` names the region of the source frame a search can reach and
// the scale that brings the spot to a working size, and `autoSource(for:in:window:)`
// maps the answer back to source-normalized coordinates.

import Foundation

public enum SpotSourceSearch {

    /// Candidate distances from the destination, in radii. The smallest is just over a
    /// diameter, so the source disc never overlaps the destination disc.
    public static let candidateDistances: [Double] = [2.1, 2.6, 3.2, 4.0, 5.0]
    public static let candidateDirections = 32
    /// Radii, in units of the spot radius, at which the context ring is sampled.
    public static let ringRadii: [Double] = [1.15, 1.35, 1.6]
    public static let ringDirections = 24
    /// How far a search reaches from the centre, in radii: the farthest candidate plus
    /// its ring, plus the refinement's first step.
    public static let reach: Double = 5.0 + 1.6 + 0.6
    /// The spot radius a search works at, in pixels of the buffer it is handed. Larger
    /// spots are searched on a proportionally downscaled window: texture similarity at
    /// 24 px of radius is plenty, and it bounds a click's cost on any frame.
    public static let workingRadius: Double = 24

    // MARK: Windowing

    /// The region of the source frame a search needs, in source pixels (top-down), and
    /// the scale the caller should render it at.
    public struct Window: Sendable, Equatable {
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int
        /// Buffer pixels per source pixel; ≤ 1.
        public let scale: Double

        /// The buffer size the caller should render the window to.
        public var bufferWidth: Int { Swift.max(Int((Double(width) * scale).rounded()), 1) }
        public var bufferHeight: Int {
            Swift.max(Int((Double(height) * scale).rounded()), 1)
        }
    }

    public static func window(for spot: HealSpot, sourceWidth: Int,
                              sourceHeight: Int) -> Window {
        let w = Double(sourceWidth), h = Double(sourceHeight)
        let radius = Swift.max(
            Num.clamp(spot.radius, HealSpot.radiusRange.lowerBound,
                      HealSpot.radiusRange.upperBound) * Swift.max(w, h), 0.5)
        let extent = radius * reach
        let cx = spot.x * w, cy = spot.y * h
        let x0 = Swift.max(Int(floor(cx - extent)), 0)
        let y0 = Swift.max(Int(floor(cy - extent)), 0)
        let x1 = Swift.min(Int(ceil(cx + extent)), sourceWidth)
        let y1 = Swift.min(Int(ceil(cy + extent)), sourceHeight)
        let scale = Swift.min(1, workingRadius / radius)
        return Window(x: x0, y: y0, width: Swift.max(x1 - x0, 1),
                      height: Swift.max(y1 - y0, 1), scale: scale)
    }

    /// The best source for `spot`, searched in `buffer` — the `window` of the source
    /// frame rendered at whatever size the caller produced (the mapping reads the
    /// buffer's real dimensions, so a rounded size cannot shift the answer). Returns
    /// source-normalized coordinates, or nil when no candidate fits.
    public static func autoSource(for spot: HealSpot, in buffer: ImageBuffer,
                                  window: Window, sourceWidth: Int,
                                  sourceHeight: Int) -> (x: Double, y: Double)? {
        let w = Double(sourceWidth), h = Double(sourceHeight)
        let toBufferX = Double(buffer.width) / Double(window.width)
        let toBufferY = Double(buffer.height) / Double(window.height)
        let radius = Swift.max(
            Num.clamp(spot.radius, HealSpot.radiusRange.lowerBound,
                      HealSpot.radiusRange.upperBound) * Swift.max(w, h), 0.5)
        let cx = (spot.x * w - Double(window.x)) * toBufferX
        let cy = (spot.y * h - Double(window.y)) * toBufferY
        guard let best = bestSource(in: buffer, centerX: cx, centerY: cy,
                                    radius: radius * Swift.min(toBufferX, toBufferY),
                                    mode: spot.mode)
        else { return nil }
        return ((best.x / toBufferX + Double(window.x)) / w,
                (best.y / toBufferY + Double(window.y)) / h)
    }

    /// The whole-frame convenience: `image` IS the source frame.
    public static func autoSource(for spot: HealSpot,
                                  in image: ImageBuffer) -> (x: Double, y: Double)? {
        let window = Window(x: 0, y: 0, width: image.width, height: image.height, scale: 1)
        return autoSource(for: spot, in: image, window: window,
                          sourceWidth: image.width, sourceHeight: image.height)
    }

    // MARK: The search, in buffer pixels

    /// The best source centre for a spot at (`centerX`, `centerY`) of `radius`, all in
    /// `image`'s own pixels, or nil when no candidate lies wholly inside the frame.
    public static func bestSource(in image: ImageBuffer, centerX: Double, centerY: Double,
                                  radius: Double,
                                  mode: HealMode) -> (x: Double, y: Double)? {
        guard radius.isFinite, centerX.isFinite, centerY.isFinite, radius > 0 else {
            return nil
        }
        let encoded = image.map { LumenLog.encode($0) }
        let scorer = Scorer(image: encoded, cx: centerX, cy: centerY, radius: radius,
                            heal: mode == .heal)

        var best: (dx: Double, dy: Double, score: Double)?
        for distance in candidateDistances {
            for k in 0..<candidateDirections {
                let theta = 2 * Double.pi * Double(k) / Double(candidateDirections)
                let dx = cos(theta) * distance * radius
                let dy = sin(theta) * distance * radius
                guard let score = scorer.score(dx: dx, dy: dy) else { continue }
                if best == nil || score < best!.score { best = (dx, dy, score) }
            }
        }
        guard var current = best else { return nil }

        // Pattern search: try the eight neighbours at `step`, move to the best that
        // improves, halve the step when none does. Bounded, deterministic.
        var step = radius * 0.5
        var iterations = 0
        while step >= 0.125 && iterations < 400 {
            iterations += 1
            var improved = false
            for (ox, oy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0),
                             (1.0, 1.0), (1.0, -1.0), (-1.0, 1.0), (-1.0, -1.0)] {
                let dx = current.dx + ox * step, dy = current.dy + oy * step
                guard let score = scorer.score(dx: dx, dy: dy),
                      score < current.score else { continue }
                current = (dx, dy, score)
                improved = true
            }
            if !improved { step *= 0.5 }
        }
        return (centerX + current.dx, centerY + current.dy)
    }

    /// The scoring, with the destination's side measured once.
    struct Scorer {
        let image: ImageBuffer
        let cx: Double
        let cy: Double
        let radius: Double
        let heal: Bool
        let ringOffsets: [(Double, Double)]
        let interiorOffsets: [(Double, Double)]
        let destinationRing: [RGB]
        let destinationRingMean: RGB
        let destinationRingVariance: Double

        init(image: ImageBuffer, cx: Double, cy: Double, radius: Double, heal: Bool) {
            self.image = image
            self.cx = cx
            self.cy = cy
            self.radius = radius
            self.heal = heal
            var ring: [(Double, Double)] = []
            for (index, r) in SpotSourceSearch.ringRadii.enumerated() {
                for k in 0..<SpotSourceSearch.ringDirections {
                    // Each ring is rotated half a step from the last, so the three
                    // together sample the annulus rather than three spokes of it.
                    let theta = 2 * Double.pi * (Double(k) + 0.5 * Double(index))
                        / Double(SpotSourceSearch.ringDirections)
                    ring.append((cos(theta) * r * radius, sin(theta) * r * radius))
                }
            }
            self.ringOffsets = ring
            var interior: [(Double, Double)] = [(0, 0)]
            for (r, n) in [(0.35, 8), (0.65, 12), (0.9, 16)] {
                for k in 0..<n {
                    let theta = 2 * Double.pi * Double(k) / Double(n)
                    interior.append((cos(theta) * r * radius, sin(theta) * r * radius))
                }
            }
            self.interiorOffsets = interior
            let samples = ring.map { image.bilinear(cx + $0.0, cy + $0.1) }
            self.destinationRing = samples
            let mean = Self.mean(samples)
            self.destinationRingMean = mean
            self.destinationRingVariance = Self.variance(samples, mean: mean)
        }

        /// Lower is better; nil when the candidate's disc and ring are not wholly inside
        /// the frame or it would overlap the destination.
        func score(dx: Double, dy: Double) -> Double? {
            let sx = cx + dx, sy = cy + dy
            let margin = radius * (SpotSourceSearch.ringRadii.last ?? 1)
            guard sx - margin >= 0, sy - margin >= 0,
                  sx + margin <= Double(image.width), sy + margin <= Double(image.height)
            else { return nil }
            let distance = (dx * dx + dy * dy).squareRoot()
            guard distance >= 2 * radius else { return nil }

            let ring = ringOffsets.map { image.bilinear(sx + $0.0, sy + $0.1) }
            let ringMean = Self.mean(ring)
            var ssd = 0.0
            for i in 0..<ring.count {
                var d = ring[i] - destinationRing[i]
                if heal { d = d - (ringMean - destinationRingMean) }
                ssd += d.r * d.r + d.g * d.g + d.b * d.b
            }
            ssd /= Double(ring.count)

            let interior = interiorOffsets.map { image.bilinear(sx + $0.0, sy + $0.1) }
            let interiorVariance = Self.variance(interior, mean: Self.mean(interior))
            // Only structure WELL BEYOND the surroundings' own is charged — twice the
            // destination ring's variance, plus a floor. An interior and a ring are
            // different sample sets, so even a perfectly matched texture's two
            // variances differ by a little, and a penalty on that little would tug the
            // answer off phase by a fraction of a pixel. A blemish or an edge is not a
            // little. (A Clone's LEVEL needs no separate term: the raw ring SSD it is
            // scored on already demands it.)
            let penalty = Swift.max(
                interiorVariance - 2 * destinationRingVariance - Self.varianceFloor, 0)
            return ssd + 2 * penalty + 1e-6 * distance / radius
        }

        /// Variance (log-encoded, summed over channels) below which an interior counts as
        /// flat: about half a percent of the shaper's range as a standard deviation.
        static let varianceFloor: Double = 3e-5

        static func mean(_ values: [RGB]) -> RGB {
            guard !values.isEmpty else { return .zero }
            var acc = RGB.zero
            for v in values { acc = acc + v }
            return acc / Double(values.count)
        }

        /// Summed over the three channels.
        static func variance(_ values: [RGB], mean: RGB) -> Double {
            guard !values.isEmpty else { return 0 }
            var acc = 0.0
            for v in values {
                let d = v - mean
                acc += d.r * d.r + d.g * d.g + d.b * d.b
            }
            return acc / Double(values.count)
        }
    }
}
