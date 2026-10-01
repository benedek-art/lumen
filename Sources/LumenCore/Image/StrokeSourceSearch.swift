// StrokeSourceSearch.swift
// Where a painted heal stroke borrows from: ONE offset for the whole stroke, picked the
// way `SpotSourceSearch` picks a spot's source and scored by the same rules, carried
// from a disc to the stroke's tube.
//
//   · The context is the band just outside the tube — samples at the spot's ring radii
//     (1.15, 1.35, 1.6 R) off both sides of every vertex and round both ends — and a good
//     offset is one whose band matches it (means removed for Heal, as for a spot).
//   · The interior penalty is charged on the candidate tube's centreline and the
//     half-radius lines either side of it.
//   · No offset may make the source tube overlap the stroke itself: every shifted
//     vertex stays two radii from the centreline, the spot's "just over a diameter".
//   · Candidates are the spot's expanding ring of offsets, then the same pattern
//     search (`SpotSourceSearch.refine`). Deterministic.
//
// Windowed like a spot: `window(for:)` names the region a search reaches and the scale
// that brings the radius to `SpotSourceSearch.workingRadius`.

import Foundation

public enum StrokeSourceSearch {

    public static func window(for stroke: BrushStroke, sourceWidth: Int,
                              sourceHeight: Int) -> SpotSourceSearch.Window {
        let w = Double(sourceWidth), h = Double(sourceHeight)
        let radius = Swift.max(
            Num.clamp(stroke.size / 2, HealSpot.radiusRange.lowerBound,
                      HealSpot.radiusRange.upperBound) * Swift.max(w, h), 0.5)
        let extent = radius * SpotSourceSearch.reach
        let xs = stroke.points.map { $0.x * w }, ys = stroke.points.map { $0.y * h }
        let x0 = Swift.max(Int(floor((xs.min() ?? 0) - extent)), 0)
        let y0 = Swift.max(Int(floor((ys.min() ?? 0) - extent)), 0)
        let x1 = Swift.min(Int(ceil((xs.max() ?? 0) + extent)), sourceWidth)
        let y1 = Swift.min(Int(ceil((ys.max() ?? 0) + extent)), sourceHeight)
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
        guard !stroke.points.isEmpty else { return nil }
        let w = Double(sourceWidth), h = Double(sourceHeight)
        let toX = Double(buffer.width) / Double(window.width)
        let toY = Double(buffer.height) / Double(window.height)
        let radius = Swift.max(
            Num.clamp(stroke.size / 2, HealSpot.radiusRange.lowerBound,
                      HealSpot.radiusRange.upperBound) * Swift.max(w, h), 0.5)
            * Swift.min(toX, toY)
        let points = stroke.points.map {
            StrokeHeal.Point(($0.x * w - Double(window.x)) * toX,
                             ($0.y * h - Double(window.y)) * toY)
        }
        guard let best = bestOffset(in: buffer, points: points, radius: radius,
                                    mode: stroke.retouch?.mode ?? .heal) else { return nil }
        return (best.dx / toX / w, best.dy / toY / h)
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
    /// along the polyline through `points`.
    public static func bestOffset(in image: ImageBuffer, points: [StrokeHeal.Point],
                                  radius: Double,
                                  mode: HealMode) -> (dx: Double, dy: Double)? {
        guard radius.isFinite, radius > 0, !points.isEmpty,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let vertices = StrokeHeal.resample(points, spacing: radius * 0.5)
        let scorer = TubeScorer(image: image.map { LumenLog.encode($0) },
                                vertices: vertices, radius: radius, heal: mode == .heal)
        var best: (dx: Double, dy: Double, score: Double)?
        for distance in SpotSourceSearch.candidateDistances {
            for k in 0..<SpotSourceSearch.candidateDirections {
                let theta = 2 * Double.pi * Double(k)
                    / Double(SpotSourceSearch.candidateDirections)
                let dx = cos(theta) * distance * radius
                let dy = sin(theta) * distance * radius
                guard let score = scorer.score(dx: dx, dy: dy) else { continue }
                if best == nil || score < best!.score { best = (dx, dy, score) }
            }
        }
        guard let start = best else { return nil }
        let refined = SpotSourceSearch.refine(start, radius: radius) {
            scorer.score(dx: $0, dy: $1)
        }
        return (refined.dx, refined.dy)
    }

    struct TubeScorer {
        let image: ImageBuffer
        let vertices: [StrokeHeal.Point]
        let radius: Double
        let heal: Bool
        let ring: [StrokeHeal.Point]
        let interior: [StrokeHeal.Point]
        let destinationRing: [RGB]
        let destinationRingMean: RGB
        let destinationRingVariance: Double

        init(image: ImageBuffer, vertices: [StrokeHeal.Point], radius: Double, heal: Bool) {
            self.image = image
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
                interior.append(v)
                interior.append(StrokeHeal.Point(v.x + 0.5 * radius * nx, v.y + 0.5 * radius * ny))
                interior.append(StrokeHeal.Point(v.x - 0.5 * radius * nx, v.y - 0.5 * radius * ny))
            }
            self.interior = interior
            let samples = ring.map { image.bilinear($0.x, $0.y) }
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
                                          to: vertices) >= 2 * radius else { return nil }
            }
            let shifted = ring.map { image.bilinear($0.x + dx, $0.y + dy) }
            let shiftedMean = SpotSourceSearch.Scorer.mean(shifted)
            var ssd = 0.0
            for i in 0..<shifted.count {
                var d = shifted[i] - destinationRing[i]
                if heal { d = d - (shiftedMean - destinationRingMean) }
                ssd += d.r * d.r + d.g * d.g + d.b * d.b
            }
            ssd /= Double(Swift.max(shifted.count, 1))
            let inside = interior.map { image.bilinear($0.x + dx, $0.y + dy) }
            let insideVariance = SpotSourceSearch.Scorer.variance(
                inside, mean: SpotSourceSearch.Scorer.mean(inside))
            let penalty = Swift.max(insideVariance - 2 * destinationRingVariance
                                        - SpotSourceSearch.Scorer.varianceFloor, 0)
            return ssd + 2 * penalty + 1e-6 * (dx * dx + dy * dy).squareRoot() / radius
        }
    }
}
