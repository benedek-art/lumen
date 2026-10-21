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
//   · Context terms (`Scorer.contextCost`, WS-56): texture ENERGY (a flat source on a
//     textured picture used to win the raw SSD), CONSISTENCY (the source's middle must
//     look like its own ring), LEVEL for Heal (re-lighting a different structure makes
//     holes), and OUTLIERS (one pit or sky gap in the source is a new defect).
//   · A small preference for nearer sources, so equally good candidates resolve to the
//     one in the most similar light, and the answer is deterministic.
//
// The radius every distance is measured in is the spot's REACH, its feather included
// (`SpotRetouch.reach`): the context ring lies beyond everything the spot writes, and a
// source may come no nearer than the reach plus the circle, so no written pixel ever
// borrows from inside the circle.
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

    /// Candidate distances from the destination, in units of half the clearance (the
    /// spot's reach plus its circle — a diameter when there is no feather). The
    /// smallest is just over it, so no written pixel borrows from inside the circle.
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
        let radius = SpotRetouch.reach(of: spot, edge: Swift.max(w, h))
        let extent = radius * reach
        let cx = spot.x * w, cy = spot.y * h
        let x0 = StrokeHeal.boundedIndex(floor(cx - extent), lower: 0, upper: sourceWidth - 1)
        let y0 = StrokeHeal.boundedIndex(floor(cy - extent), lower: 0, upper: sourceHeight - 1)
        let x1 = StrokeHeal.boundedIndex(ceil(cx + extent), lower: 0, upper: sourceWidth)
        let y1 = StrokeHeal.boundedIndex(ceil(cy + extent), lower: 0, upper: sourceHeight)
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
        let radius = SpotRetouch.reach(of: spot, edge: Swift.max(w, h))
        let cx = (spot.x * w - Double(window.x)) * toBufferX
        let cy = (spot.y * h - Double(window.y)) * toBufferY
        guard let best = bestSource(in: buffer, centerX: cx, centerY: cy,
                                    radius: radius * Swift.min(toBufferX, toBufferY),
                                    core: SpotRetouch.core(of: spot), mode: spot.mode)
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
                                  radius: Double, core: Double = 1,
                                  mode: HealMode) -> (x: Double, y: Double)? {
        guard radius.isFinite, centerX.isFinite, centerY.isFinite, radius > 0 else {
            return nil
        }
        let encoded = image.map { LumenLog.encode($0) }
        let scorer = Scorer(image: encoded, cx: centerX, cy: centerY, radius: radius,
                            heal: mode == .heal, core: core)

        var best: (dx: Double, dy: Double, score: Double)?
        for distance in candidateDistances {
            for k in 0..<candidateDirections {
                let theta = 2 * Double.pi * Double(k) / Double(candidateDirections)
                let dx = cos(theta) * distance * scorer.clearance / 2
                let dy = sin(theta) * distance * scorer.clearance / 2
                guard let score = scorer.score(dx: dx, dy: dy) else { continue }
                if best == nil || score < best!.score { best = (dx, dy, score) }
            }
        }
        guard let start = best else { return nil }
        let current = refine(start, scorer: scorer, radius: radius)
        return (centerX + current.dx, centerY + current.dy)
    }

    /// Pattern search: try the eight neighbours at `step`, move to the best that
    /// improves, halve the step when none does. Bounded, deterministic.
    static func refine(_ start: (dx: Double, dy: Double, score: Double), scorer: Scorer,
                       radius: Double) -> (dx: Double, dy: Double, score: Double) {
        refine(start, radius: radius) { scorer.score(dx: $0, dy: $1) }
    }

    /// The same search over any score — `StrokeHeal`'s tube scorer uses it.
    static func refine(_ start: (dx: Double, dy: Double, score: Double), radius: Double,
                       score scoreAt: (Double, Double) -> Double?)
        -> (dx: Double, dy: Double, score: Double) {
        var current = start
        var step = radius * 0.5
        var iterations = 0
        while step >= 0.125 && iterations < 400 {
            iterations += 1
            var improved = false
            for (ox, oy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0),
                             (1.0, 1.0), (1.0, -1.0), (-1.0, 1.0), (-1.0, -1.0)] {
                let dx = current.dx + ox * step, dy = current.dy + oy * step
                guard let score = scoreAt(dx, dy),
                      score < current.score else { continue }
                current = (dx, dy, score)
                improved = true
            }
            if !improved { step *= 0.5 }
        }
        return current
    }

    // MARK: Re-picking — `/` (docs/09 §Heal / Clone, LR's binding)

    /// How many distinct sources `/` cycles through before it comes back to the first.
    public static let alternativeCount = 6

    /// The best `limit` DISTINCT sources, best first, in `image`'s own pixels.
    ///
    /// The first is exactly `bestSource`'s answer: the candidates are ranked by the same
    /// score (ties to the earlier candidate, as `bestSource`'s strict `<` resolves them)
    /// and each is refined by the same pattern search. Later entries are the next-best
    /// candidates whose refined position is at least one radius from every entry before
    /// them — two candidates that refine into the same texture are one choice, and a
    /// re-pick that moved the source by a pixel would look like a key that did nothing.
    public static func rankedSources(in image: ImageBuffer, centerX: Double, centerY: Double,
                                     radius: Double, core: Double = 1, mode: HealMode,
                                     limit: Int = alternativeCount) -> [(x: Double, y: Double)] {
        guard limit > 0, radius.isFinite, centerX.isFinite, centerY.isFinite, radius > 0 else {
            return []
        }
        let encoded = image.map { LumenLog.encode($0) }
        let scorer = Scorer(image: encoded, cx: centerX, cy: centerY, radius: radius,
                            heal: mode == .heal, core: core)
        var candidates: [(index: Int, dx: Double, dy: Double, score: Double)] = []
        for distance in candidateDistances {
            for k in 0..<candidateDirections {
                let theta = 2 * Double.pi * Double(k) / Double(candidateDirections)
                let dx = cos(theta) * distance * scorer.clearance / 2
                let dy = sin(theta) * distance * scorer.clearance / 2
                guard let score = scorer.score(dx: dx, dy: dy) else { continue }
                candidates.append((candidates.count, dx, dy, score))
            }
        }
        candidates.sort { $0.score < $1.score || ($0.score == $1.score && $0.index < $1.index) }

        var picked: [(dx: Double, dy: Double, score: Double)] = []
        func isDistinct(_ dx: Double, _ dy: Double) -> Bool {
            picked.allSatisfy { hypot($0.dx - dx, $0.dy - dy) >= radius }
        }
        for candidate in candidates {
            guard picked.count < limit else { break }
            // A candidate that already sits on a pick would refine into it.
            guard isDistinct(candidate.dx, candidate.dy) else { continue }
            let refined = refine((candidate.dx, candidate.dy, candidate.score),
                                 scorer: scorer, radius: radius)
            guard isDistinct(refined.dx, refined.dy) else { continue }
            picked.append(refined)
        }
        return picked.map { (centerX + $0.dx, centerY + $0.dy) }
    }

    /// `rankedSources` for a spot, searched in a window of the source frame (see
    /// `autoSource(for:in:window:sourceWidth:sourceHeight:)`), in source-normalized
    /// coordinates.
    public static func rankedSources(for spot: HealSpot, in buffer: ImageBuffer,
                                     window: Window, sourceWidth: Int, sourceHeight: Int,
                                     limit: Int = alternativeCount) -> [(x: Double, y: Double)] {
        let w = Double(sourceWidth), h = Double(sourceHeight)
        let toBufferX = Double(buffer.width) / Double(window.width)
        let toBufferY = Double(buffer.height) / Double(window.height)
        let radius = SpotRetouch.reach(of: spot, edge: Swift.max(w, h))
        let cx = (spot.x * w - Double(window.x)) * toBufferX
        let cy = (spot.y * h - Double(window.y)) * toBufferY
        return rankedSources(in: buffer, centerX: cx, centerY: cy,
                             radius: radius * Swift.min(toBufferX, toBufferY),
                             core: SpotRetouch.core(of: spot), mode: spot.mode,
                             limit: limit).map {
            (($0.x / toBufferX + Double(window.x)) / w,
             ($0.y / toBufferY + Double(window.y)) / h)
        }
    }

    /// What `/` moves `spot`'s source to: the candidate AFTER the one it sits on now,
    /// wrapping to the best — so pressing it repeatedly walks every alternative and comes
    /// back. A source the photographer dragged somewhere that is none of the candidates
    /// goes to the best one, which is what "re-pick" means when nothing was picked.
    ///
    /// Stateless on purpose: which alternative a spot is on is read off the spot itself
    /// (within half a radius, in source pixels), so the cycle survives undo, a relaunch
    /// and a second window with nothing remembered anywhere. Nil when there are no
    /// candidates at all.
    public static func nextSource(for spot: HealSpot, candidates: [(x: Double, y: Double)],
                                  sourceWidth: Int,
                                  sourceHeight: Int) -> (x: Double, y: Double)? {
        guard !candidates.isEmpty else { return nil }
        let w = Double(sourceWidth), h = Double(sourceHeight)
        let radius = SpotRetouch.reach(of: spot, edge: Swift.max(w, h))
        let tolerance = 0.5 * radius
        let current = candidates.firstIndex { candidate in
            hypot((candidate.x - spot.sourceX) * w, (candidate.y - spot.sourceY) * h)
                <= tolerance
        }
        guard let current else { return candidates[0] }
        return candidates[(current + 1) % candidates.count]
    }

    /// The scoring, with the destination's side measured once.
    struct Scorer {
        let image: ImageBuffer
        let cx: Double
        let cy: Double
        let radius: Double
        let heal: Bool
        /// The nearest a source centre may be: the spot's reach plus its circle, so no
        /// pixel the spot writes borrows from inside the circle — the blemish. (The
        /// feather bands may overlap; they hold clean picture.)
        let clearance: Double
        let ringOffsets: [(Double, Double)]
        let interiorOffsets: [(Double, Double)]
        let destinationRing: [RGB]
        let destinationRingMean: RGB
        let destinationRingVariance: Double

        init(image: ImageBuffer, cx: Double, cy: Double, radius: Double, heal: Bool,
             core: Double = 1) {
            self.image = image
            self.clearance = radius * (1 + Num.clamp(core, 0, 1))
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
            // A grid a sixteenth of the radius apart (1.5 px at the working size) over
            // the disc: dense enough that a pit or a speck two pixels across lands on a
            // sample, because the outlier term below can only charge what it sees.
            var interior: [(Double, Double)] = []
            let n = Self.interiorGrid
            for j in -n...n {
                for i in -n...n {
                    let u = Double(i) / Double(n), v = Double(j) / Double(n)
                    guard u * u + v * v < 0.95 * 0.95 else { continue }
                    interior.append((u * radius, v * radius))
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
            guard distance >= clearance else { return nil }

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
            let context = Self.contextCost(
                heal: heal, ring: (ringMean, Self.variance(ring, mean: ringMean)),
                interior: (Self.mean(interior), interiorVariance,
                           Self.peakDeviation(interior, from: ringMean)),
                destination: (destinationRingMean, destinationRingVariance))
            return ssd + 2 * penalty + context + 1e-6 * distance / radius
        }

        /// What a ring SSD cannot see, shared by the spot and the stroke scorers (means
        /// and variances log-encoded, variances summed over channels).
        ///
        /// TEXTURE ENERGY. A raw SSD prefers a FLAT candidate on a textured picture:
        /// against a ring of variance σ², a flat ring scores σ² and an equally textured
        /// but uncorrelated one 2σ², so on foliage the search picked a patch of shadow
        /// and the heal pasted a smooth disc (1840's canopy: texture ratio 0.30).
        /// Charging the difference in texture amplitude — the ring's, and an interior
        /// flatter than the context — makes the flat patch cost 3σ².
        ///
        /// CONSISTENCY. The candidate's middle must look like its own surroundings: a
        /// source whose ring matches but whose centre holds a cluster of sky gaps, a
        /// second blemish or a highlight pastes that in, and Heal's re-lighting only
        /// moves its level. Charged on the interior mean against the candidate ring's.
        ///
        /// LEVEL, for Heal. The re-lighting makes a source in other light usable, but on
        /// texture a "level" difference is usually a structure difference — a thinner
        /// canopy with more sky through it reads brighter — and re-lighting that turns
        /// its sky gaps into dark holes. So Heal still prefers a source in the
        /// destination's own light; Clone's raw SSD already demands it in full.
        ///
        /// OUTLIERS. A source can be right on average and still hold one dark pit or one
        /// bright sky hole in its middle, which the heal then pastes in as a NEW spot —
        /// the means and variances of the interior barely move for it. The interior's
        /// worst sample beyond 2.5σ of the candidate's own ring (and a floor) is charged
        /// directly.
        static func contextCost(heal: Bool, ring: (mean: RGB, variance: Double),
                                interior: (mean: RGB, variance: Double, peak: Double),
                                destination: (mean: RGB, variance: Double)) -> Double {
            func norm2(_ c: RGB) -> Double { c.r * c.r + c.g * c.g + c.b * c.b }
            let sigmaD = destination.variance.squareRoot()
            let ringSigma = ring.variance.squareRoot()
            // Against the candidate's OWN surroundings: a pit is an outlier because the
            // wall around it is smooth, whatever the destination's ring holds (6929's
            // wall spot has a brick edge in its ring that hid the pit at max(σ, σD)).
            let outlier = Swift.max(interior.peak - 2.5 * ringSigma - outlierFloor, 0)
            let flatness = Swift.max(0.7 * sigmaD - interior.variance.squareRoot(), 0)
            var cost = 2 * (ringSigma - sigmaD) * (ringSigma - sigmaD)
                + 4 * flatness * flatness
                + 4 * norm2(interior.mean - ring.mean)
            cost += Self.outlierWeight * outlier * outlier
            if heal { cost += healLevelWeight * norm2(ring.mean - destination.mean) }
            return cost
        }

        /// Log-encoded distance below which no single sample counts as an outlier: about
        /// a sixth of a stop.
        static let outlierFloor: Double = 0.007
        /// Decisive on purpose: a pasted second defect is the worst thing a heal does.
        static let outlierWeight: Double = 40

        /// The largest distance (log-encoded, Euclidean over channels) of any sample
        /// from `mean`.
        static func peakDeviation(_ values: [RGB], from mean: RGB) -> Double {
            var peak = 0.0
            for v in values {
                let d = v - mean
                peak = Swift.max(peak, (d.r * d.r + d.g * d.g + d.b * d.b).squareRoot())
            }
            return peak
        }

        /// Variance (log-encoded, summed over channels) below which an interior counts as
        /// flat: about half a percent of the shaper's range as a standard deviation.
        static let varianceFloor: Double = 3e-5
        /// Interior grid half-width in steps: 16 steps to the radius.
        static let interiorGrid = 16
        /// How much of the level difference a Heal source is still charged, against
        /// Clone's whole. 0.5 measured: the canopy case (1840) went from ΔE 7.1 to 1.0 with
        /// no sky case above 0.05.
        static let healLevelWeight: Double = 0.5

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
