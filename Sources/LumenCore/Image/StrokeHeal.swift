// StrokeHeal.swift
// S5 RETOUCH, the brushed half (docs/09 §Heal / Clone): a painted stroke healed or
// cloned along its whole length from one auto-picked offset. The f32 reference; the GPU
// graph (`RenderGraph.applyHealStrokes`) reads every constant and every formula here.
//
// WHERE A STROKE LIVES. In the brush stroke blob, exactly as a mask brush does — a
// `BrushStrokeSet` addressed by `Heal.strokesRef`, `Heal.count` its stroke count — with
// each stroke's `retouch` naming the mode and the source offset. Size is the stroke's
// diameter as a fraction of the long edge, feather its soft edge, density its opacity.
//
// THE SHAPE is a TUBE: every pixel within one radius of the stroke's centreline, with
// the spot's edge rule applied to the distance — `alpha = opacity · (1 − smoothstep(rin,
// 1, d / R))`. The centreline is the recorded polyline, resampled to evenly spaced
// vertices half a radius apart (fewer if the stroke would need more than
// `maxVertices`). Spacing in radii, not pixels, is what keeps the vertex list the same
// at every render size.
//
// CLONE is `I(p + d)`, as for a spot.
//
// HEAL is the spot's closed form carried to the tube: `I(p + d) + M(p)`, where `M`
// interpolates the boundary difference `I_dst − I_src` measured at RIM SAMPLES — one on
// each side of every vertex at one radius out, and `capSamples` round each end — with
// weights `1 / |p − b_k|²` (in radii). On a disc those samples and that weight ARE the
// spot's Poisson integral; across a straight tube the inverse-square weights summed
// along each side give each side `π / distance`, which is linear interpolation from one
// wall to the other — the exact harmonic solution for a strip. So a stroke inherits the
// light on both sides of it, and meets the picture at its ends, with no solver and no
// iteration, and the GPU does the same sums.
//
// A rim sample that falls inside the tube — the inside of a bend, a stroke crossing
// itself — is dropped: it would measure the blemish rather than its surroundings. Each
// remaining sample is the mean of `subsamples` points along the rim, like a spot's.
//
// COORDINATES are `ImageBuffer`'s: top-down, pixel centres at +0.5.

import Foundation

public enum StrokeHeal {

    /// The most centreline vertices one stroke resolves to. Shared with the GPU kernels,
    /// which loop over at most `maxBoundarySamples` rim samples.
    public static let maxVertices = 256
    /// Rim samples round each end of the stroke, between its two side samples.
    public static let capSamples = 7
    public static var maxBoundarySamples: Int { 2 * maxVertices + 2 * capSamples }
    /// Points averaged along the rim for each rim sample (odd: centred on the sample).
    public static let subsamples = 3

    public struct Point: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public init(_ x: Double, _ y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// One stroke resolved against a frame's pixel grid. Both renderers work from this.
    public struct StrokeGeometry: Sendable, Equatable {
        /// Centreline vertices, pixels.
        public let vertices: [Point]
        /// Rim sample positions, pixels, and each one's step between sub-samples.
        public let rim: [Point]
        public let rimSteps: [Point]
        /// The source offset, pixels.
        public let dx: Double
        public let dy: Double
        public let radius: Double
        public let rin: Double
        public let opacity: Double
        public let heal: Bool
        /// Pixels that can change: x in `minX..<maxX`, y in `minY..<maxY`.
        public let minX: Int
        public let minY: Int
        public let maxX: Int
        public let maxY: Int

        public var isEmpty: Bool { minX >= maxX || minY >= maxY }
        public var width: Int { maxX - minX }
        public var height: Int { maxY - minY }
    }

    /// The heal strokes of a recipe, resolved through its stroke set: every stroke in
    /// the blob that carries a `retouch`, in draw order. Empty when the recipe names no
    /// blob or the blob is not to hand — a missing blob heals nothing rather than
    /// something else.
    public static func strokes(for heal: Heal,
                               strokeSets: [String: BrushStrokeSet]) -> [BrushStroke] {
        guard let ref = heal.strokesRef, let set = strokeSets[ref] else { return [] }
        return set.strokes.filter { $0.retouch != nil }
    }

    // MARK: Resolution

    public static func resolve(_ stroke: BrushStroke, width: Int,
                               height: Int) -> StrokeGeometry? {
        guard width > 0, height > 0, let retouch = stroke.retouch,
              !stroke.points.isEmpty else { return nil }
        let scalars = [stroke.size, stroke.feather, stroke.density, retouch.dx, retouch.dy]
        guard scalars.allSatisfy({ $0.isFinite }),
              stroke.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let opacity = Num.clamp(stroke.density, 0, 100) / 100
        guard opacity > 0 else { return nil }

        let w = Double(width), h = Double(height)
        let radius = Swift.max(
            Num.clamp(stroke.size / 2, HealSpot.radiusRange.lowerBound,
                      HealSpot.radiusRange.upperBound) * Swift.max(w, h), 0.5)
        let feather = Num.clamp(stroke.feather, 0, 100) / 100
        let pixelGuard = Num.saturate(1.0 / Swift.max(radius, 1))
        let rin = Num.clamp(Swift.max(1 - feather, pixelGuard), 0, 1 - 1e-6)

        let vertices = resample(stroke.points.map { Point($0.x * w, $0.y * h) },
                                spacing: radius * 0.5)
        let (rim, steps) = rimSamples(vertices, radius: radius)

        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        for v in vertices {
            minX = Swift.min(minX, v.x); minY = Swift.min(minY, v.y)
            maxX = Swift.max(maxX, v.x); maxY = Swift.max(maxY, v.y)
        }
        let geometry = StrokeGeometry(
            vertices: vertices, rim: rim, rimSteps: steps,
            dx: retouch.dx * w, dy: retouch.dy * h,
            radius: radius, rin: rin, opacity: opacity, heal: retouch.mode == .heal,
            minX: Swift.max(Int(floor(minX - radius)), 0),
            minY: Swift.max(Int(floor(minY - radius)), 0),
            maxX: Swift.min(Int(ceil(maxX + radius)), width),
            maxY: Swift.min(Int(ceil(maxY + radius)), height))
        return geometry.isEmpty ? nil : geometry
    }

    /// Evenly spaced vertices along the polyline, at most `maxVertices`, the first and
    /// last on the stroke's own ends. A stroke with no length is one vertex.
    static func resample(_ points: [Point], spacing: Double) -> [Point] {
        var lengths: [Double] = [0]
        for i in 1..<Swift.max(points.count, 1) {
            lengths.append(lengths[i - 1]
                           + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y))
        }
        let total = lengths.last ?? 0
        guard points.count > 1, total > 1e-9 else { return [points[0]] }
        let segments = Swift.min(Swift.max(Int(ceil(total / Swift.max(spacing, 1e-9))), 1),
                                 maxVertices - 1)
        var out: [Point] = []
        out.reserveCapacity(segments + 1)
        var j = 1
        for k in 0...segments {
            let s = total * Double(k) / Double(segments)
            while j < points.count - 1 && lengths[j] < s { j += 1 }
            let span = lengths[j] - lengths[j - 1]
            let t = span > 0 ? Num.clamp((s - lengths[j - 1]) / span, 0, 1) : 0
            out.append(Point(points[j - 1].x + (points[j].x - points[j - 1].x) * t,
                             points[j - 1].y + (points[j].y - points[j - 1].y) * t))
        }
        return out
    }

    /// The rim: two side samples per vertex and `capSamples` round each end, minus any
    /// that land inside the tube.
    static func rimSamples(_ vertices: [Point], radius: Double) -> ([Point], [Point]) {
        let n = vertices.count
        func tangent(_ i: Int) -> Point {
            guard n > 1 else { return Point(1, 0) }
            let a = vertices[Swift.max(i - 1, 0)], b = vertices[Swift.min(i + 1, n - 1)]
            let len = hypot(b.x - a.x, b.y - a.y)
            return len > 1e-12 ? Point((b.x - a.x) / len, (b.y - a.y) / len) : Point(1, 0)
        }
        let spacing = n > 1
            ? hypot(vertices[1].x - vertices[0].x, vertices[1].y - vertices[0].y)
            : radius * Double.pi / Double(capSamples + 1)
        var rim: [Point] = [], steps: [Point] = []
        func add(_ p: Point, _ step: Point) {
            guard distance(p, to: vertices) >= radius * (1 - 1e-6) else { return }
            rim.append(p)
            steps.append(step)
        }
        // End caps first, the start's, then the sides, then the end's: an order fixed
        // here so the GPU's rim image is indexed identically.
        func cap(_ v: Point, back: Point) {
            let normal = Point(-back.y, back.x)
            let arc = radius * Double.pi / Double(capSamples + 1)
            for m in 1...capSamples {
                let phi = -Double.pi / 2 + Double(m) * Double.pi / Double(capSamples + 1)
                let dir = Point(cos(phi) * back.x + sin(phi) * normal.x,
                                cos(phi) * back.y + sin(phi) * normal.y)
                let along = Point(-sin(phi) * back.x + cos(phi) * normal.x,
                                  -sin(phi) * back.y + cos(phi) * normal.y)
                add(Point(v.x + radius * dir.x, v.y + radius * dir.y),
                    Point(along.x * arc / Double(subsamples), along.y * arc / Double(subsamples)))
            }
        }
        let t0 = tangent(0)
        cap(vertices[0], back: Point(-t0.x, -t0.y))
        for i in 0..<n {
            let t = tangent(i)
            let normal = Point(-t.y, t.x)
            let step = Point(t.x * spacing / Double(subsamples), t.y * spacing / Double(subsamples))
            add(Point(vertices[i].x + radius * normal.x, vertices[i].y + radius * normal.y), step)
            add(Point(vertices[i].x - radius * normal.x, vertices[i].y - radius * normal.y), step)
        }
        cap(vertices[n - 1], back: tangent(n - 1))
        return (rim, steps)
    }

    /// Distance from `p` to the polyline through `vertices` (a point when there is one).
    public static func distance(_ p: Point, to vertices: [Point]) -> Double {
        guard vertices.count > 1 else {
            return hypot(p.x - vertices[0].x, p.y - vertices[0].y)
        }
        var best = Double.infinity
        for i in 1..<vertices.count {
            best = Swift.min(best, segmentDistance(p, vertices[i - 1], vertices[i]))
        }
        return best
    }

    @inlinable
    static func segmentDistance(_ p: Point, _ a: Point, _ b: Point) -> Double {
        let ex = b.x - a.x, ey = b.y - a.y
        let len2 = ex * ex + ey * ey
        let t = len2 > 0 ? Num.clamp(((p.x - a.x) * ex + (p.y - a.y) * ey) / len2, 0, 1) : 0
        return hypot(p.x - (a.x + t * ex), p.y - (a.y + t * ey))
    }

    // MARK: The alpha

    /// The tube's alpha over the stroke's box, row-major from (`minX`, `minY`), top-down.
    /// Geometry only — no picture — which is why the GPU path is handed this plane
    /// rather than recomputing a polyline distance per pixel: one definition of the
    /// stroke's shape, rasterized once.
    ///
    /// Each segment visits only its own box, so the cost is the tube's area, not the
    /// bounding box's times the vertex count.
    public static func alphaPlane(_ g: StrokeGeometry) -> [Float] {
        let bw = g.width, bh = g.height
        var nearest = [Double](repeating: .infinity, count: bw * bh)
        func visit(_ a: Point, _ b: Point) {
            let x0 = Swift.max(Int(floor(Swift.min(a.x, b.x) - g.radius)), g.minX)
            let x1 = Swift.min(Int(ceil(Swift.max(a.x, b.x) + g.radius)), g.maxX)
            let y0 = Swift.max(Int(floor(Swift.min(a.y, b.y) - g.radius)), g.minY)
            let y1 = Swift.min(Int(ceil(Swift.max(a.y, b.y) + g.radius)), g.maxY)
            guard x0 < x1, y0 < y1 else { return }
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let d = segmentDistance(Point(Double(x) + 0.5, Double(y) + 0.5), a, b)
                    let i = (y - g.minY) * bw + (x - g.minX)
                    if d < nearest[i] { nearest[i] = d }
                }
            }
        }
        if g.vertices.count == 1 {
            visit(g.vertices[0], g.vertices[0])
        } else {
            for i in 1..<g.vertices.count { visit(g.vertices[i - 1], g.vertices[i]) }
        }
        return nearest.map {
            Float(SpotRetouch.alpha(rho: $0 / g.radius, rin: g.rin, opacity: g.opacity))
        }
    }

    // MARK: The membrane

    /// `I_dst − I_src` at every rim sample, each the mean of `subsamples` points along
    /// the rim.
    public static func boundaryDifferences(_ image: ImageBuffer,
                                           _ g: StrokeGeometry) -> [RGB] {
        let half = (subsamples - 1) / 2
        return (0..<g.rim.count).map { k in
            var acc = RGB.zero
            for j in -half...half {
                let px = g.rim[k].x + Double(j) * g.rimSteps[k].x
                let py = g.rim[k].y + Double(j) * g.rimSteps[k].y
                acc = acc + image.bilinear(px, py) - image.bilinear(px + g.dx, py + g.dy)
            }
            return acc / Double(subsamples)
        }
    }

    /// The membrane at pixel `(px, py)`: inverse-square (in radii) weighted mean of the
    /// rim differences, with `SpotRetouch.membrane`'s 1e-6 floor.
    public static func membrane(px: Double, py: Double, _ g: StrokeGeometry,
                                boundary: [RGB]) -> RGB {
        var acc = RGB.zero
        var total = 0.0
        let scale = 1 / (g.radius * g.radius)
        for k in 0..<boundary.count {
            let dx = px - g.rim[k].x, dy = py - g.rim[k].y
            let weight = 1 / Swift.max((dx * dx + dy * dy) * scale, 1e-6)
            acc = acc + boundary[k] * weight
            total += weight
        }
        return total > 0 ? acc / total : .zero
    }

    // MARK: Applying

    /// Every heal stroke, in draw order, each reading what the previous left. No strokes,
    /// no work and no copy.
    public static func apply(_ image: ImageBuffer, strokes: [BrushStroke]) -> ImageBuffer {
        var current = image
        for stroke in strokes {
            guard let g = resolve(stroke, width: image.width, height: image.height)
            else { continue }
            current = apply(current, g)
        }
        return current
    }

    public static func apply(_ input: ImageBuffer, _ g: StrokeGeometry) -> ImageBuffer {
        let alpha = alphaPlane(g)
        let boundary = g.heal ? boundaryDifferences(input, g) : []
        var out = input
        for y in g.minY..<g.maxY {
            let py = Double(y) + 0.5
            for x in g.minX..<g.maxX {
                let a = Double(alpha[(y - g.minY) * g.width + (x - g.minX)])
                guard a > 0 else { continue }
                let px = Double(x) + 0.5
                var fill = input.bilinear(px + g.dx, py + g.dy)
                if g.heal { fill = fill + membrane(px: px, py: py, g, boundary: boundary) }
                out[x, y] = input[x, y].mix(fill, a)
            }
        }
        return out
    }
}
