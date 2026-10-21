// StrokeSourceSearch.swift
// Where a painted heal stroke borrows from: ONE offset for the whole stroke, picked the
// way `SpotSourceSearch` picks a spot's source and scored by the same rules, carried
// from a disc to the stroke's tube.
//
//   · The context is the band just outside the tube — samples at the spot's ring radii
//     (1.15, 1.35, 1.6 R) off both sides of every vertex and round both ends — and a good
//     offset is one whose band matches it (means removed for Heal, as for a spot).
//   · The interior penalty, and the spot's texture, consistency, level and outlier
//     terms (`SpotSourceSearch.Scorer.contextCost`), are charged on lines across the
//     candidate tube every eighth of a radius.
//   · No written pixel may borrow from the painted tube itself: every shifted vertex
//     stays the reach plus the tube from the centreline — two radii without feather.
//   · Candidates are the spot's expanding ring of offsets, then the same pattern
//     search (`SpotSourceSearch.refine`). Deterministic. `rankedOffsets` lists the
//     distinct alternatives `/` cycles through.
//
// Windowed like a spot: `window(for:)` names the region a search reaches and the scale
// that brings the radius to `SpotSourceSearch.workingRadius`.

import Foundation

public enum StrokeSourceSearch {

    public static func window(for stroke: BrushStroke, sourceWidth: Int,
                              sourceHeight: Int) -> SpotSourceSearch.Window {
        // The API returns a window, so malformed input gets a harmless one-pixel
        // sentinel. autoOffset independently rejects it before any image search.
        let refused = SpotSourceSearch.Window(x: 0, y: 0, width: 1, height: 1, scale: 1)
        guard sourceWidth > 0, sourceHeight > 0, stroke.size.isFinite,
              !stroke.points.isEmpty else { return refused }
        let w = Double(sourceWidth), h = Double(sourceHeight)
        let points = stroke.points.map { StrokeHeal.Point($0.x * w, $0.y * h) }
        guard points.allSatisfy(StrokeHeal.usable) else { return refused }
        let radius = StrokeHeal.reach(of: stroke, edge: Swift.max(w, h))
        let extent = radius * SpotSourceSearch.reach
        let xs = points.map { $0.x }, ys = points.map { $0.y }
        let x0 = StrokeHeal.boundedIndex(floor((xs.min() ?? 0) - extent), lower: 0, upper: sourceWidth - 1)
        let y0 = StrokeHeal.boundedIndex(floor((ys.min() ?? 0) - extent), lower: 0, upper: sourceHeight - 1)
        let x1 = StrokeHeal.boundedIndex(ceil((xs.max() ?? 0) + extent), lower: 0, upper: sourceWidth)
        let y1 = StrokeHeal.boundedIndex(ceil((ys.max() ?? 0) + extent), lower: 0, upper: sourceHeight)
        return SpotSourceSearch.Window(
            x: x0, y: y0, width: Swift.max(x1 - x0, 1), height: Swift.max(y1 - y0, 1),
            scale: Swift.min(1, SpotSourceSearch.workingRadius / radius))
    }

    /// The source offset for `stroke` (its `retouch.mode` decides Heal or Clone
    /// scoring; a stroke without one is scored as Heal), searched in `buffer` — the
    /// `window` of the source frame at whatever size the caller rendered it. Returns the
    /// offset as `StrokeRetouch` states it (fractions of the source width and height),
    /// or nil when no offset fits.
    public static func autoOffset(for stroke: BrushStroke, in buffer: ImageBuffer,
                                  window: SpotSourceSearch.Window, sourceWidth: Int,
                                  sourceHeight: Int) -> (dx: Double, dy: Double)? {
        guard let frame = searchFrame(for: stroke, in: buffer, window: window,
                                      sourceWidth: sourceWidth, sourceHeight: sourceHeight),
              let best = bestOffset(in: buffer, points: frame.points, radius: frame.radius,
                                    core: StrokeHeal.core(of: stroke),
                                    mode: stroke.retouch?.mode ?? .heal) else { return nil }
        return (best.dx / frame.toX / Double(sourceWidth),
                best.dy / frame.toY / Double(sourceHeight))
    }

    /// The whole-frame convenience: `image` IS the source frame.
    public static func autoOffset(for stroke: BrushStroke,
                                  in image: ImageBuffer) -> (dx: Double, dy: Double)? {
        autoOffset(for: stroke, in: image,
                   window: .init(x: 0, y: 0, width: image.width, height: image.height,
                                 scale: 1),
                   sourceWidth: image.width, sourceHeight: image.height)
    }

    /// The search, in `image`'s own pixels: the best offset for a tube of `radius`
    /// along the polyline through `points`. `core` is the painted tube as a fraction of
    /// `radius` (the rest is feather), which sets how near the source may come.
    public static func bestOffset(in image: ImageBuffer, points: [StrokeHeal.Point],
                                  radius: Double, core: Double = 1,
                                  mode: HealMode) -> (dx: Double, dy: Double)? {
        rankedOffsets(in: image, points: points, radius: radius, core: core, mode: mode,
                      limit: 1).first
    }

    /// The best `limit` DISTINCT offsets, best first — `SpotSourceSearch.rankedSources`
    /// for a tube: candidates ranked by the same score (ties to the earlier one), each
    /// refined by the same pattern search, and later entries at least one radius from
    /// every entry before them. The first is `bestOffset`'s answer.
    public static func rankedOffsets(in image: ImageBuffer, points: [StrokeHeal.Point],
                                     radius: Double, core: Double = 1, mode: HealMode,
                                     limit: Int = SpotSourceSearch.alternativeCount)
        -> [(dx: Double, dy: Double)] {
        guard limit > 0, image.width > 0, image.height > 0,
              radius.isFinite, radius > 0, !points.isEmpty,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return [] }
        guard radius <= StrokeHeal.coordinateLimit else { return [] }
        let vertices = StrokeHeal.resample(points, spacing: radius * 0.5)
        guard !vertices.isEmpty else { return [] }
        let scorer = TubeScorer(image: image.map { LumenLog.encode($0) },
                                vertices: vertices, radius: radius, heal: mode == .heal,
                                core: core)
        var candidates: [(index: Int, dx: Double, dy: Double, score: Double)] = []
        for distance in SpotSourceSearch.candidateDistances {
            for k in 0..<SpotSourceSearch.candidateDirections {
                let theta = 2 * Double.pi * Double(k)
                    / Double(SpotSourceSearch.candidateDirections)
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
            guard isDistinct(candidate.dx, candidate.dy) else { continue }
            let refined = SpotSourceSearch.refine((candidate.dx, candidate.dy, candidate.score),
                                                  radius: radius) {
                scorer.score(dx: $0, dy: $1)
            }
            guard isDistinct(refined.dx, refined.dy) else { continue }
            picked.append(refined)
        }
        return picked.map { ($0.dx, $0.dy) }
    }

    /// `rankedOffsets` for a stroke, searched in a window of the source frame (see
    /// `autoOffset(for:in:window:sourceWidth:sourceHeight:)`), as `StrokeRetouch` states
    /// an offset.
    public static func rankedOffsets(for stroke: BrushStroke, in buffer: ImageBuffer,
                                     window: SpotSourceSearch.Window, sourceWidth: Int,
                                     sourceHeight: Int,
                                     limit: Int = SpotSourceSearch.alternativeCount)
        -> [(dx: Double, dy: Double)] {
        guard let frame = searchFrame(for: stroke, in: buffer, window: window,
                                      sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        else { return [] }
        return rankedOffsets(in: buffer, points: frame.points, radius: frame.radius,
                             core: StrokeHeal.core(of: stroke),
                             mode: stroke.retouch?.mode ?? .heal, limit: limit).map {
            ($0.dx / frame.toX / Double(sourceWidth), $0.dy / frame.toY / Double(sourceHeight))
        }
    }

    /// What `/` moves a stroke's offset to: the candidate AFTER the one it is on now,
    /// wrapping to the best — `SpotSourceSearch.nextSource`'s rule, stateless the same
    /// way (which alternative a stroke is on is read off its own offset, within half a
    /// radius). Nil when there are no candidates or the stroke has no retouch.
    public static func nextOffset(for stroke: BrushStroke,
                                  candidates: [(dx: Double, dy: Double)],
                                  sourceWidth: Int, sourceHeight: Int) -> (dx: Double, dy: Double)? {
        guard !candidates.isEmpty, let retouch = stroke.retouch else { return nil }
        let w = Double(sourceWidth), h = Double(sourceHeight)
        let tolerance = 0.5 * StrokeHeal.reach(of: stroke, edge: Swift.max(w, h))
        let current = candidates.firstIndex {
            hypot(($0.dx - retouch.dx) * w, ($0.dy - retouch.dy) * h) <= tolerance
        }
        guard let current else { return candidates[0] }
        return candidates[(current + 1) % candidates.count]
    }

    /// The stroke's points and radius in a search buffer's pixels.
    static func searchFrame(for stroke: BrushStroke, in buffer: ImageBuffer,
                            window: SpotSourceSearch.Window, sourceWidth: Int,
                            sourceHeight: Int)
        -> (points: [StrokeHeal.Point], radius: Double, toX: Double, toY: Double)? {
        guard !stroke.points.isEmpty, stroke.size.isFinite,
              sourceWidth > 0, sourceHeight > 0,
              window.width > 0, window.height > 0,
              stroke.points.allSatisfy({
                  StrokeHeal.usable(.init($0.x * Double(sourceWidth),
                                         $0.y * Double(sourceHeight)))
              }) else { return nil }
        let w = Double(sourceWidth), h = Double(sourceHeight)
        let toX = Double(buffer.width) / Double(window.width)
        let toY = Double(buffer.height) / Double(window.height)
        let radius = StrokeHeal.reach(of: stroke, edge: Swift.max(w, h)) * Swift.min(toX, toY)
        let points = stroke.points.map {
            StrokeHeal.Point(($0.x * w - Double(window.x)) * toX,
                             ($0.y * h - Double(window.y)) * toY)
        }
        return (points, radius, toX, toY)
    }

    struct TubeScorer {
        let image: ImageBuffer
        let vertices: [StrokeHeal.Point]
        let radius: Double
        let heal: Bool
        /// How far every shifted vertex must stay from the centreline: the reach plus
        /// the painted tube (`SpotSourceSearch.Scorer.clearance`'s rule).
        let clearance: Double
        let ring: [StrokeHeal.Point]
        let interior: [StrokeHeal.Point]
        let destinationRing: [RGB]
        let destinationRingMean: RGB
        let destinationRingVariance: Double

        init(image: ImageBuffer, vertices: [StrokeHeal.Point], radius: Double, heal: Bool,
             core: Double = 1) {
            self.image = image
            self.clearance = radius * (1 + Num.clamp(core, 0, 1))
            self.vertices = vertices
            self.radius = radius
            self.heal = heal
            var ring: [StrokeHeal.Point] = []
            for r in SpotSourceSearch.ringRadii {
                let (samples, _) = StrokeHeal.rimSamples(vertices, radius: radius * r)
                ring += samples.filter {
                    StrokeHeal.distance($0, to: vertices) >= radius * r * (1 - 1e-6)
                }
            }
            self.ring = ring
            var interior: [StrokeHeal.Point] = []
            let n = vertices.count
            for i in 0..<n {
                let a = vertices[Swift.max(i - 1, 0)], b = vertices[Swift.min(i + 1, n - 1)]
                let len = hypot(b.x - a.x, b.y - a.y)
                let nx = len > 1e-12 ? -(b.y - a.y) / len : 0
                let ny = len > 1e-12 ? (b.x - a.x) / len : 1
                let v = vertices[i]
                // Across the tube every eighth of a radius, and half a vertex spacing
                // along it too, so a two-pixel pit in a source is seen (the outlier term
                // in `SpotSourceSearch.Scorer.contextCost`).
                let ta = StrokeHeal.Point(ny, -nx)
                for along in [0.0, 0.25] {
                    for step in -7...7 {
                        let c = Double(step) / 8 * radius
                        interior.append(StrokeHeal.Point(v.x + c * nx + along * radius * ta.x,
                                                         v.y + c * ny + along * radius * ta.y))
                    }
                }
            }
            self.interior = interior
            let samples = ring.map { StrokeHeal.sample(image, $0.x, $0.y) }
            self.destinationRing = samples
            let mean = SpotSourceSearch.Scorer.mean(samples)
            self.destinationRingMean = mean
            self.destinationRingVariance = SpotSourceSearch.Scorer.variance(samples, mean: mean)
        }

        /// Lower is better; nil when the shifted band leaves the frame or the shifted
        /// tube overlaps the stroke.
        func score(dx: Double, dy: Double) -> Double? {
            let width = Double(image.width), height = Double(image.height)
            for p in ring {
                let x = p.x + dx, y = p.y + dy
                guard x >= 0, y >= 0, x <= width, y <= height else { return nil }
            }
            for v in vertices {
                guard StrokeHeal.distance(StrokeHeal.Point(v.x + dx, v.y + dy),
                                          to: vertices) >= clearance else { return nil }
            }
            let shifted = ring.map { StrokeHeal.sample(image, $0.x + dx, $0.y + dy) }
            let shiftedMean = SpotSourceSearch.Scorer.mean(shifted)
            var ssd = 0.0
            for i in 0..<shifted.count {
                var d = shifted[i] - destinationRing[i]
                if heal { d = d - (shiftedMean - destinationRingMean) }
                ssd += d.r * d.r + d.g * d.g + d.b * d.b
            }
            ssd /= Double(Swift.max(shifted.count, 1))
            let inside = interior.map { StrokeHeal.sample(image, $0.x + dx, $0.y + dy) }
            let insideVariance = SpotSourceSearch.Scorer.variance(
                inside, mean: SpotSourceSearch.Scorer.mean(inside))
            let penalty = Swift.max(insideVariance - 2 * destinationRingVariance
                                        - SpotSourceSearch.Scorer.varianceFloor, 0)
            let context = SpotSourceSearch.Scorer.contextCost(
                heal: heal,
                ring: (shiftedMean, SpotSourceSearch.Scorer.variance(shifted, mean: shiftedMean)),
                interior: (SpotSourceSearch.Scorer.mean(inside), insideVariance,
                           SpotSourceSearch.Scorer.peakDeviation(inside, from: shiftedMean)),
                destination: (destinationRingMean, destinationRingVariance))
            return ssd + 2 * penalty + context
                + 1e-6 * (dx * dx + dy * dy).squareRoot() / radius
        }
    }
}
