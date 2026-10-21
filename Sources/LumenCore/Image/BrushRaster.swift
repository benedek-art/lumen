// BrushRaster.swift
// One brush stroke, rasterized as the swept dab rather than as a row of stamps.
//
// WHAT STOOD HERE BEFORE, AND WHY IT COULD NOT BE TUNED INTO SHAPE. `MaskRaster.paint`
// laid a stamp every tenth of a radius and composited EACH STAMP into the accumulator:
// `a + flow·s·(density − a)`. A pixel beside the centreline sits under about twenty
// stamps, so it received twenty deposits, `1 − (1 − flow·s)^20`. Measured on base
// 84bcd7c (WS-44 brushlab, 41 px radius):
//
//   · Flow did nothing within a stroke: Flow 50 painted 1.00, not 0.50. Two crossing
//     Flow 50 strokes painted 1.00, not 0.75. The eraser at Flow 50 erased everything.
//   · Feather collapsed: any s above ~0.15 was driven to 1, so a Feather 100 stroke
//     reached 50 % at 0.79 radius where its own dab (and the cursor) put it at 0.48, and
//     its 10–90 % edge was a quarter of a radius wide. A soft brush painted a hard bar.
//   · Pressure did nothing, for the same reason as Flow: it scaled a deposit that
//     saturated anyway (0.1 pressure painted 0.84 one radius in, 1.0 thereafter).
//
// WHAT THIS DOES. A stroke's coverage at a pixel is the dab profile at the pixel's
// distance from the centreline: `c = flow · pressure · profile(d / r)`, the MAXIMUM
// over the centreline, not a sum. That is exactly the cross-section the cursor rings
// promise, it has no stamps and therefore no spacing, beading or speed dependence, and
// the stroke then composites onto the accumulator ONCE:
//
//     paint:  a ← a + c · max(density − a, 0)      erase:  a ← a · (1 − c)
//
// so Flow 50 is 50 % per pass and 75 % after two, Density is a ceiling, and the
// eraser's Flow is how much it takes away. One stroke going back over itself does not
// build up (Lightroom's eraser and Photoshop's opacity behave the same way; it is the
// predictable choice, and a second pass is a second stroke).
//
// The centreline is the same uniform Catmull-Rom through the recorded points that
// `stampCenters` walked, flattened into segments short enough that the chord never
// leaves the curve by more than a fifth of a pixel. Because the profile is monotonic,
// max-of-profiles is profile-of-the-distance-to-the-polyline, and that distance is
// drawn region by region: the slab beside each segment, the wedge outside each joint,
// the two end caps (see "Drawing"). Nothing depends on how the events were spaced: six
// events across the frame paint the same continuous band as six hundred, and the cost
// is the stroke's own area rather than a disc per recorded point.
//
// AUTO MASK. The old gate compared every pixel with the colour under EACH stamp's
// centre in plain OKLab, so the moment the centre crossed an edge the brush painted the
// other side, shading split one object into two, and every dark colour matched every
// other. It also converted every pixel to OKLab once per stamp, twenty times over.
// Measured on 4694/8559 (tools/automask.py) the old brush leaked 14–42 % of its paint
// off the object. Now:
//
//   · pixels are compared in shading-invariant features (chromaticity a/L, b/L, and
//     log lightness at a fifth of the weight; `labAt`), computed once per pixel per
//     stroke and cached;
//   · the stroke accepts the colour where it STARTED, and grows that into a small set
//     only from centre samples that sit on one colour and lie within τ of a colour
//     already accepted — so it follows one object's colour range and never jumps to
//     another (`updateReferences`);
//   · the deposit spreads only through pixels connected to what this stroke has
//     already painted, so a same-coloured island past an edge stays clean.
//
// INCREMENTAL. `append` draws the first point's dab at once and then each Catmull-Rom
// segment as soon as its far tangent is known; `finish` draws the last one and the end
// cap. So a stroke built point by point (the live canvas, `BrushLivePreview`) is
// bit-identical to the same stroke painted whole (`MaskRaster.paint`).

import Foundation

public struct BrushStrokeRaster {

    /// A rectangle in pixels of the full extent, half-open.
    public struct Rect: Equatable, Sendable {
        public var x0: Int
        public var y0: Int
        public var x1: Int
        public var y1: Int
        public var isEmpty: Bool { x1 <= x0 || y1 <= y0 }
        public func union(_ o: Rect) -> Rect {
            if isEmpty { return o }
            if o.isEmpty { return self }
            return Rect(x0: Swift.min(x0, o.x0), y0: Swift.min(y0, o.y0),
                        x1: Swift.max(x1, o.x1), y1: Swift.max(y1, o.y1))
        }
        public func intersection(_ o: Rect) -> Rect {
            Rect(x0: Swift.max(x0, o.x0), y0: Swift.max(y0, o.y0),
                 x1: Swift.min(x1, o.x1), y1: Swift.min(y1, o.y1))
        }
        public static let empty = Rect(x0: 0, y0: 0, x1: 0, y1: 0)
    }

    struct Pt {
        var x: Double
        var y: Double
        var p: Double
    }

    /// OKLab ΔE at which the Auto Mask gate starts to close; shut at 2τ. The value the
    /// per-stamp gate used (`MaskRaster.automaskTau`).
    static let automaskTau: Double = 0.06
    /// Auto Mask features (`labAt`): weight on log lightness, and the lightness below
    /// which chromaticity stops being divided further (noise in the shadows).
    static let lightnessWeight: Double = 0.2
    static let maxReferences = 24
    static let lightnessFloor: Double = 0.1
    private static let toLMS = OKLabTransform.working.rgbToLMS
    private static let toLab = OKLabTransform.lmsToLab
    /// Largest chord deviation from the Catmull-Rom curve, in pixels.
    static let flatness: Double = 0.2
    /// Work guard: a pathological stroke must not become an unbounded loop.
    static let maxSegments: Int = 400_000

    public let width: Int
    public let height: Int
    /// The part of the extent this raster holds. The whole extent for a live stroke; the
    /// stroke's own bounds when the whole stroke is known (`MaskRaster.paint`).
    public let window: Rect
    /// Coverage over `window`, row-major: `flow · pressure · profile · gate`, 0…1.
    public private(set) var coverage: [Float]
    /// Everything any segment has written, in extent pixels.
    public private(set) var touched: Rect = .empty
    /// What changed since the last `takeDirty()`.
    private var dirty: Rect = .empty

    public let radius: Double
    let hardness: Double
    let flow: Double
    public let density: Double
    public let erase: Bool
    /// False when the stroke cannot paint (radius under half a pixel, Flow 0, or Density 0
    /// on a paint stroke). Such a raster accepts points and draws nothing.
    public let paints: Bool

    private let source: ImageBuffer?
    /// Auto Mask's per-pixel working memory (features cache, flood state). See
    /// `AutoMaskScratch` for why it is not five Swift arrays.
    private var scratch: AutoMaskScratch?
    /// The colours this stroke accepts as "the object" (Auto Mask features, see `labAt`):
    /// the colour where it started, plus every colour the centre has since reached that
    /// lay within `automaskTau` of one already accepted. At most `maxReferences`.
    private var references: [(Double, Double, Double)] = []

    private var points: [Pt] = []
    private var segmentsDrawn = 0
    private var finished = false
    private var segmentBudget = BrushStrokeRaster.maxSegments
    /// The last polyline vertex drawn, and the direction of the last segment of
    /// nonzero length into it: a joint needs both.
    private var head: Pt?
    private var headDirection: (Double, Double)?

    // Auto Mask scratch over the window, reused across primitives: a generation stamp
    // per pixel (2g+1 = passable in primitive g, 2g+2 = reached), the gated value, and
    // the flood queue. Stamps instead of clearing, so a primitive costs its own area.
    private var generation: UInt32 = 0
    /// Whether any Auto Mask primitive has deposited yet (see the seeds in `fill`).
    private var painted = false

    /// - Parameters:
    ///   - stroke: the brush parameters; its points are NOT drawn (use `append` or
    ///     `MaskRaster.paint`).
    ///   - width, height: the raster extent.
    ///   - longEdge: what `stroke.size` is a fraction of — the extent's long edge.
    ///   - source: the picture Auto Mask reads, at any size (sampled through normalized
    ///     coordinates). Ignored unless `stroke.automask`.
    ///   - window: the region to hold; defaults to the whole extent.
    public init(stroke: BrushStroke, width: Int, height: Int, longEdge: Double? = nil,
                source: ImageBuffer? = nil, window: Rect? = nil) {
        let w = Swift.max(width, 1), h = Swift.max(height, 1)
        self.width = w
        self.height = h
        let full = Rect(x0: 0, y0: 0, x1: w, y1: h)
        let win = (window ?? full).intersection(full)
        self.window = win.isEmpty ? Rect(x0: 0, y0: 0, x1: 1, y1: 1) : win
        let long = longEdge ?? Double(Swift.max(w, h))
        let size = stroke.size.isFinite ? stroke.size : 0
        let r = Swift.max(size, 0) / 2 * long
        self.radius = r.isFinite ? r : 0
        self.flow = Num.clamp(stroke.flow.isFinite ? stroke.flow : 0, 0, 100) / 100
        self.density = Num.clamp(stroke.density.isFinite ? stroke.density : 0, 0, 100) / 100
        self.erase = stroke.erase
        // Hardness, with a ≥1 px antialiasing guard at Feather 0 — the dab's own rule.
        let feather = stroke.feather.isFinite ? stroke.feather : 50
        let hard = Num.saturate(1 - Num.clamp(feather, 0, 100) / 100)
        self.hardness = Swift.min(hard, Swift.max(0, 1 - 1 / Swift.max(self.radius, 1)))
        self.paints = self.radius >= 0.5 && self.flow > 0 && (stroke.erase || self.density > 0)
        self.source = stroke.automask ? source : nil
        let count = self.window.width * self.window.height
        self.coverage = [Float](repeating: 0, count: self.paints ? count : 0)
        if self.paints, self.source != nil {
            scratch = AutoMaskScratch(count: count)
        }
    }

    // MARK: Building

    /// Add one centreline point (source-normalized, as `BrushPoint` stores it) and draw
    /// what it completes: the first point's dab at once, after that the Catmull-Rom
    /// segment that now has both its tangents. Non-finite points are dropped.
    public mutating func append(_ point: BrushPoint) {
        guard !finished, point.x.isFinite, point.y.isFinite else { return }
        let pressure = point.pressure.isFinite ? Num.saturate(point.pressure) : 1
        let q = Pt(x: point.x * Double(width), y: point.y * Double(height), p: pressure)
        points.append(q)
        if points.count == 1 {
            guard paints else { return }
            startReference(at: q)
            disc(q, box: nil)
            head = q
            return
        }
        // Segment i runs points[i] → points[i+1] and needs points[i+2] for its tangent.
        while segmentsDrawn + 2 < points.count {
            drawSegment(segmentsDrawn)
            segmentsDrawn += 1
        }
    }

    /// Draw what the last point left pending: the final segment (its far tangent clamped
    /// to the endpoint) and the end cap.
    public mutating func finish() {
        guard !finished else { return }
        finished = true
        while segmentsDrawn + 1 < points.count {
            drawSegment(segmentsDrawn)
            segmentsDrawn += 1
        }
        if paints, points.count > 1, let head { disc(head, box: nil) }
    }

    /// The end of what has been drawn, while the stroke is still being built. The live
    /// canvas draws the not-yet-final stretch from here to the pointer itself.
    public var drawnHead: (x: Double, y: Double, pressure: Double)? {
        head.map { (x: $0.x, y: $0.y, pressure: $0.p) }
    }

    /// The deposit of a plain dab (no Auto Mask) at distance `d` pixels, at `pressure`.
    public func dabValue(distance d: Double, pressure: Double) -> Float {
        guard paints, d < radius else { return 0 }
        return Float(profile(d / radius) * flow * pressure)
    }

    public var automasked: Bool { source != nil }

    /// The region changed since the last call, and resets it.
    public mutating func takeDirty() -> Rect {
        let d = dirty
        dirty = .empty
        return d
    }

    /// Coverage at an extent pixel (0 outside the window).
    public func value(_ x: Int, _ y: Int) -> Float {
        guard paints, x >= window.x0, x < window.x1, y >= window.y0, y < window.y1 else { return 0 }
        return coverage[(y - window.y0) * window.width + (x - window.x0)]
    }

    /// Fold this stroke into an accumulator plane of the full extent.
    public func composite(into p: inout Plane) {
        guard paints, p.width == width, p.height == height else { return }
        let r = touched.intersection(window)
        guard !r.isEmpty else { return }
        let ww = window.width
        let density = Float(self.density)
        let erase = self.erase
        coverage.withUnsafeBufferPointer { cov in
            p.values.withUnsafeMutableBufferPointer { out in
                for y in r.y0..<r.y1 {
                    let crow = (y - window.y0) * ww - window.x0
                    let orow = y * width
                    for x in r.x0..<r.x1 {
                        let c = cov[crow + x]
                        if c <= 0 { continue }
                        let a = out[orow + x]
                        let next = erase ? a * (1 - c) : a + c * Swift.max(density - a, 0)
                        out[orow + x] = Swift.min(Swift.max(next, 0), 1)
                    }
                }
            }
        }
    }

    // MARK: Geometry

    /// The extent pixels a whole stroke can touch: its flattened centreline padded by the
    /// radius. Used to size the window of a stroke painted whole.
    static func bounds(of stroke: BrushStroke, width: Int, height: Int,
                       radius: Double) -> Rect {
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        var pts: [Pt] = []
        for q in stroke.points where q.x.isFinite && q.y.isFinite {
            pts.append(Pt(x: q.x * Double(width), y: q.y * Double(height), p: 1))
        }
        guard !pts.isEmpty else { return .empty }
        func include(_ q: Pt) {
            minX = Swift.min(minX, q.x); maxX = Swift.max(maxX, q.x)
            minY = Swift.min(minY, q.y); maxY = Swift.max(maxY, q.y)
        }
        include(pts[0])
        var budget = maxSegments
        if pts.count > 1 {
            for i in 0..<(pts.count - 1) {
                for q in flattened(pts, i, radius: radius, budget: &budget) { include(q) }
            }
        }
        let pad = radius + 1
        func clampI(_ v: Double, _ hi: Int) -> Int { Int(Num.clamp(v, 0, Double(hi))) }
        return Rect(x0: clampI((minX - pad).rounded(.down), width),
                    y0: clampI((minY - pad).rounded(.down), height),
                    x1: clampI((maxX + pad).rounded(.up) + 1, width),
                    y1: clampI((maxY + pad).rounded(.up) + 1, height))
    }

    /// Catmull-Rom segment `i` of `pts` (uniform, τ = 0.5, end tangents clamped), as the
    /// polyline vertices after its start: short enough to keep the chord within
    /// `flatness` of the curve, and never longer than one radius so a capsule's box
    /// wastes little.
    static func flattened(_ pts: [Pt], _ i: Int, radius: Double,
                          budget: inout Int) -> [Pt] {
        let p0 = pts[Swift.max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1]
        let p3 = pts[Swift.min(i + 2, pts.count - 1)]
        func at(_ t: Double) -> Pt {
            Pt(x: catmullRom(p0.x, p1.x, p2.x, p3.x, t),
               y: catmullRom(p0.y, p1.y, p2.y, p3.y, t),
               p: Num.mix(p1.p, p2.p, t))
        }
        let cx = p2.x - p1.x, cy = p2.y - p1.y
        let chord = (cx * cx + cy * cy).squareRoot()
        guard chord.isFinite else { return [] }
        if chord <= 0 { return [p2] }
        // Subdivide until every sub-chord stays within `flatness` of the curve at its
        // quarter points, doubling n. Measured, not estimated: a sagitta estimate from
        // the whole segment under-counts where the curvature sits at the segment's ends
        // (the verifier found 1.06 px on a zig-zag and 1.26 px on a sharp turn with it).
        func deviation(_ n: Int) -> Double {
            var worst = 0.0
            var a = p1
            for j in 1...n {
                let b = at(Double(j) / Double(n))
                for f in [0.25, 0.5, 0.75] {
                    let q = at((Double(j - 1) + f) / Double(n))
                    let dx = q.x - (a.x + (b.x - a.x) * f), dy = q.y - (a.y + (b.y - a.y) * f)
                    worst = Swift.max(worst, (dx * dx + dy * dy).squareRoot())
                }
                a = b
            }
            return worst
        }
        var n = Int(Num.clamp((chord / Swift.max(radius, 1)).rounded(.up), 1, 256))
        while n < 256 && deviation(n) > flatness { n = Swift.min(n * 2, 256) }
        guard budget > 0 else { return [] }
        let take = Swift.min(n, budget)
        budget -= take
        var out: [Pt] = []
        out.reserveCapacity(take)
        for j in 1...take { out.append(at(Double(j) / Double(n))) }
        return out
    }

    static func catmullRom(_ p0: Double, _ p1: Double, _ p2: Double,
                           _ p3: Double, _ t: Double) -> Double {
        let t2 = t * t
        let t3 = t2 * t
        return 0.5 * ((2 * p1)
                      + (-p0 + p2) * t
                      + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
                      + (-p0 + 3 * p1 - 3 * p2 + p3) * t3)
    }

    // MARK: Drawing
    //
    // The coverage is `flow · pressure · profile(distance to the centreline / r)`. The
    // centreline is a polyline, and the set of pixels nearest to each part of it splits
    // into: the slab beside each segment (projection inside the segment), the wedge on
    // the outside of each joint (nearest point is the vertex), and the two end caps.
    // Drawing exactly those — rather than a capsule per segment — makes the cost the
    // stroke's own area: recorded points are often a few pixels apart under a brush
    // hundreds of pixels wide, and a capsule per segment re-covered a whole disc for each.

    @inline(__always)
    private func profile(_ rho: Double) -> Double {
        if rho <= hardness { return 1 }
        if rho >= 1 { return 0 }
        let u = (rho - hardness) / (1 - hardness)
        return 1 - u * u * (3 - 2 * u)
    }

    private mutating func drawSegment(_ i: Int) {
        guard paints else { return }
        var budget = segmentBudget
        let vertices = Self.flattened(points, i, radius: radius, budget: &budget)
        segmentBudget = budget
        for b in vertices { advance(to: b) }
    }

    private mutating func advance(to b: Pt) {
        guard let a = head, b.x.isFinite, b.y.isFinite else { return }
        let ex = b.x - a.x, ey = b.y - a.y
        let length = (ex * ex + ey * ey).squareRoot()
        guard length > 1e-9 else {
            // No travel: the vertex moves nowhere, but its pressure may have changed.
            if b.p > a.p { disc(b, box: nil) }
            head = b
            return
        }
        let u = (ex / length, ey / length)
        if let d = headDirection { joint(a, from: d, to: u) }
        slab(a, b, u, length)
        headDirection = u
        head = b
    }

    /// The outside of the turn at `v`: the pixels beyond the end of the incoming segment
    /// AND before the start of the outgoing one, `(P − v)·d1 > 0` and `(P − v)·d2 < 0`,
    /// which neither slab reaches and whose nearest centreline point is `v` itself.
    /// That is a sector of the turn's angle; its rows are spanned exactly, because its
    /// bounding box is not small — a thin sliver on a diagonal stroke has a square box,
    /// and boxes at every vertex measured as most of the stroke's cost.
    private mutating func joint(_ v: Pt, from d1: (Double, Double), to d2: (Double, Double)) {
        let cross = d1.0 * d2.1 - d1.1 * d2.0
        let dot = d1.0 * d2.0 + d1.1 * d2.1
        if abs(cross) < 1e-12 && dot > 0 { return }          // straight on: no wedge
        guard v.x.isFinite, v.y.isFinite else { return }
        let r = radius
        let area = Rect(x0: Int(Num.clamp((v.x - r).rounded(.down), -1, Double(width + 1))),
                        y0: Int(Num.clamp((v.y - r).rounded(.down), -1, Double(height + 1))),
                        x1: Int(Num.clamp((v.x + r).rounded(.up) + 1, -1, Double(width + 1))),
                        y1: Int(Num.clamp((v.y + r).rounded(.up) + 1, -1, Double(height + 1))))
            .intersection(window)
        guard !area.isEmpty else { return }
        fill(Primitive(kind: .joint, ax: v.x, ay: v.y, ux: d1.0, uy: d1.1, length: 0,
                       pa: v.p, dp: 0, vx: d2.0, vy: d2.1), rows: area)
    }

    /// A disc of radius r at `c`: a dab, or an end cap.
    private mutating func disc(_ c: Pt, box: Rect?) {
        guard c.x.isFinite, c.y.isFinite else { return }
        let r = radius
        let full = Rect(x0: Int(Num.clamp((c.x - r).rounded(.down), -1, Double(width + 1))),
                        y0: Int(Num.clamp((c.y - r).rounded(.down), -1, Double(height + 1))),
                        x1: Int(Num.clamp((c.x + r).rounded(.up) + 1, -1, Double(width + 1))),
                        y1: Int(Num.clamp((c.y + r).rounded(.up) + 1, -1, Double(height + 1))))
        var area = full.intersection(window)
        if let box { area = area.intersection(box) }
        guard !area.isEmpty else { return }
        fill(Primitive(kind: .disc, ax: c.x, ay: c.y, ux: 0, uy: 0, length: 0,
                       pa: c.p, dp: 0, vx: 0, vy: 0), rows: area)
    }

    /// The pixels whose projection falls inside segment a → b, within r of it.
    private mutating func slab(_ a: Pt, _ b: Pt, _ u: (Double, Double), _ length: Double) {
        let r = radius
        let minX = Swift.min(a.x, b.x) - r, maxX = Swift.max(a.x, b.x) + r
        let minY = Swift.min(a.y, b.y) - r, maxY = Swift.max(a.y, b.y) + r
        guard maxX.isFinite, maxY.isFinite, minX.isFinite, minY.isFinite else { return }
        let area = Rect(x0: Int(Num.clamp(minX.rounded(.down), -1, Double(width + 1))),
                        y0: Int(Num.clamp(minY.rounded(.down), -1, Double(height + 1))),
                        x1: Int(Num.clamp(maxX.rounded(.up) + 1, -1, Double(width + 1))),
                        y1: Int(Num.clamp(maxY.rounded(.up) + 1, -1, Double(height + 1))))
            .intersection(window)
        guard !area.isEmpty else { return }
        fill(Primitive(kind: .slab, ax: a.x, ay: a.y, ux: u.0, uy: u.1, length: length,
                       pa: a.p, dp: b.p - a.p, vx: 0, vy: 0), rows: area)
    }

    private struct Primitive {
        enum Kind { case slab, disc, joint }
        var kind: Kind
        // Slab start, or disc/joint centre.
        var ax: Double
        var ay: Double
        // Slab direction, or a joint's incoming one (unit).
        var ux: Double
        var uy: Double
        var length: Double
        // Pressure at the start, and its change along.
        var pa: Double
        var dp: Double
        // A joint's outgoing direction (unit).
        var vx: Double
        var vy: Double
        var isSlab: Bool { kind == .slab }
    }

    /// The columns of row `yc` (pixel-centre ordinate) a primitive can touch, as a
    /// half-open integer range inside `area`.
    @inline(__always)
    private static func span(_ q: Primitive, _ yc: Double, _ area: Rect,
                             radius r: Double, width: Int) -> (Int, Int) {
        var lo = -Double.infinity, hi = Double.infinity
        if q.isSlab {
            // |(P − A)·n| ≤ r  and  0 ≤ (P − A)·u ≤ L, each linear in x.
            let ry = yc - q.ay
            func clipSpan(_ coef: Double, _ c0: Double, _ low: Double, _ high: Double) {
                if abs(coef) < 1e-12 {
                    if c0 < low || c0 > high { lo = .infinity; hi = -.infinity }
                    return
                }
                let x1 = (low - c0) / coef + q.ax, x2 = (high - c0) / coef + q.ax
                lo = Swift.max(lo, Swift.min(x1, x2))
                hi = Swift.min(hi, Swift.max(x1, x2))
            }
            clipSpan(-q.uy, ry * q.ux, -r, r)                     // n = (−uy, ux)
            clipSpan(q.ux, ry * q.uy, -1e-9, q.length + 1e-9)
        } else {
            let dy = yc - q.ay
            let h2 = r * r - dy * dy
            if h2 <= 0 { return (0, 0) }
            let half = h2.squareRoot()
            lo = q.ax - half; hi = q.ax + half
            if q.kind == .joint {
                // (P − v)·d1 ≥ −ε and (P − v)·d2 ≤ ε. Half a pixel of overlap with the
                // slabs either side: max-combine makes overlap free and a seam is not.
                let eps = 0.5
                func clipSpan(_ coef: Double, _ c0: Double, _ low: Double, _ high: Double) {
                    if abs(coef) < 1e-12 {
                        if c0 < low || c0 > high { lo = .infinity; hi = -.infinity }
                        return
                    }
                    let x1 = (low - c0) / coef + q.ax, x2 = (high - c0) / coef + q.ax
                    lo = Swift.max(lo, Swift.min(x1, x2))
                    hi = Swift.min(hi, Swift.max(x1, x2))
                }
                clipSpan(q.ux, dy * q.uy, -eps, .greatestFiniteMagnitude)
                clipSpan(q.vx, dy * q.vy, -.greatestFiniteMagnitude, eps)
            }
        }
        guard lo <= hi, lo.isFinite || hi.isFinite else { return (0, 0) }
        let xs = Swift.max(area.x0, Int(Num.clamp((lo - 0.5).rounded(.up), -1, Double(width + 1))))
        let xe = Swift.min(area.x1, Int(Num.clamp((hi - 0.5).rounded(.down), -2, Double(width))) + 1)
        return (xs, xe)
    }

    private mutating func fill(_ q: Primitive, rows area: Rect) {
        let r = radius
        let invR = 1 / r
        let h = hardness
        let invShoulder = h < 1 ? 1 / (1 - h) : 0
        let f = flow
        let ww = window.width
        let invLength = q.length > 0 ? 1 / q.length : 0
        let nx = -q.uy, ny = q.ux
        var touchedRows = Rect.empty

        if source == nil {
            coverage.withUnsafeMutableBufferPointer { cov in
                for y in area.y0..<area.y1 {
                    let yc = Double(y) + 0.5
                    let (xs, xe) = Self.span(q, yc, area, radius: r, width: width)
                    if xs >= xe { continue }
                    touchedRows = touchedRows.union(Rect(x0: xs, y0: y, x1: xe, y1: y + 1))
                    let row = (y - window.y0) * ww - window.x0
                    let ry = yc - q.ay
                    for x in xs..<xe {
                        let rx = Double(x) + 0.5 - q.ax
                        let d: Double, t: Double
                        if q.isSlab {
                            d = abs(rx * nx + ry * ny)
                            t = Swift.min(Swift.max((rx * q.ux + ry * q.uy) * invLength, 0), 1)
                        } else {
                            d = (rx * rx + ry * ry).squareRoot()
                            t = 0
                        }
                        if d >= r { continue }
                        let rho = d * invR
                        var s = 1.0
                        if rho > h {
                            let u = (rho - h) * invShoulder
                            s = 1 - u * u * (3 - 2 * u)
                        }
                        let v = Float(s * f * (q.pa + q.dp * t))
                        if v > cov[row + x] { cov[row + x] = v }
                    }
                }
            }
            mark(touchedRows)
            return
        }

        // AUTO MASK: gate every pixel against the stroke's reference, then keep only
        // what is connected to the brush core through pixels that pass.
        updateReferences(near: q)
        guard let scratch, let src = source else { return }
        let stamp = scratch.stamp, gated = scratch.gated, queue = scratch.queue
        let refs = references
        let tau = Self.automaskTau
        generation &+= 1
        let passable = generation &* 2 &+ 1, reached = generation &* 2 &+ 2
        let win = window, wdt = width, hgt = height
        let wasPainted = painted
        var head = 0, tail = 0
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        // On the raw buffer: through `self`, every read and write of `coverage` paid a
        // uniqueness check, which measured as the largest single cost of the stroke.
        coverage.withUnsafeMutableBufferPointer { cov in
            for y in area.y0..<area.y1 {
                let yc = Double(y) + 0.5
                let (xs, xe) = Self.span(q, yc, area, radius: r, width: wdt)
                if xs >= xe { continue }
                let row = (y - win.y0) * ww - win.x0
                let ry = yc - q.ay
                for x in xs..<xe {
                    let rx = Double(x) + 0.5 - q.ax
                    let d: Double, t: Double
                    if q.isSlab {
                        d = abs(rx * nx + ry * ny)
                        t = Swift.min(Swift.max((rx * q.ux + ry * q.uy) * invLength, 0), 1)
                    } else {
                        d = (rx * rx + ry * ry).squareRoot()
                        t = 0
                    }
                    if d >= r { continue }
                    let rho = d * invR
                    var s = 1.0
                    if rho > h {
                        let u = (rho - h) * invShoulder
                        s = 1 - u * u * (3 - 2 * u)
                    }
                    let c = Self.features(scratch, src, win, wdt, hgt, x, y)
                    var best = Double.infinity
                    for m in refs {
                        let dL = c.0 - m.0, da = c.1 - m.1, db = c.2 - m.2
                        best = Swift.min(best, dL * dL + da * da + db * db)
                    }
                    let g = 1 - MaskRaster.smoothstep(tau, 2 * tau, best.squareRoot())
                    if g <= 0.02 { continue }
                    let k = row + x
                    gated[k] = Float(s * f * (q.pa + q.dp * t) * g)
                    // SEEDS. Until the stroke has painted anything: the brush core on the
                    // reference colour. After that: only pixels touching what THIS stroke
                    // already painted, so the paint spreads through the object it started
                    // on and nowhere else — a same-coloured island the centre wanders onto
                    // past an edge is not connected to it, and stays clean.
                    let seed: Bool
                    if wasPainted {
                        seed = cov[k] > 0
                            || (x > win.x0 && cov[k - 1] > 0)
                            || (x + 1 < win.x1 && cov[k + 1] > 0)
                            || (y > win.y0 && cov[k - ww] > 0)
                            || (y + 1 < win.y1 && cov[k + ww] > 0)
                    } else {
                        seed = rho <= 0.5 && g >= 0.5
                    }
                    if seed {
                        stamp[k] = reached
                        queue[tail] = Int32(k); tail += 1
                    } else {
                        stamp[k] = passable
                    }
                }
            }
            let wh = win.height
            while head < tail {
                let k = Int(queue[head]); head += 1
                let x = k % ww, y = k / ww
                if x > 0, stamp[k - 1] == passable { stamp[k - 1] = reached; queue[tail] = Int32(k - 1); tail += 1 }
                if x + 1 < ww, stamp[k + 1] == passable { stamp[k + 1] = reached; queue[tail] = Int32(k + 1); tail += 1 }
                if y > 0, stamp[k - ww] == passable { stamp[k - ww] = reached; queue[tail] = Int32(k - ww); tail += 1 }
                if y + 1 < wh, stamp[k + ww] == passable {
                    stamp[k + ww] = reached; queue[tail] = Int32(k + ww); tail += 1
                }
            }
            for i in 0..<tail {
                let k = Int(queue[i])
                if gated[k] > cov[k] { cov[k] = gated[k] }
                let x = k % ww, y = k / ww
                minX = Swift.min(minX, x); maxX = Swift.max(maxX, x)
                minY = Swift.min(minY, y); maxY = Swift.max(maxY, y)
            }
        }
        guard tail > 0 else { return }
        painted = true
        mark(Rect(x0: minX + win.x0, y0: minY + win.y0, x1: maxX + win.x0 + 1, y1: maxY + win.y0 + 1))
    }

    private mutating func mark(_ box: Rect) {
        guard !box.isEmpty else { return }
        touched = touched.union(box)
        dirty = dirty.union(box)
    }

    // MARK: Auto Mask

    /// Auto Mask features of the source under an extent pixel (see below), cached for
    /// the life of the stroke.
    private func labAt(_ x: Int, _ y: Int) -> (Double, Double, Double) {
        guard let scratch, let source else { return (0, 0, 0) }
        return Self.features(scratch, source, window, width, height, x, y)
    }

    @inline(__always)
    private static func features(_ scratch: AutoMaskScratch, _ src: ImageBuffer, _ window: Rect,
                                 _ width: Int, _ height: Int,
                                 _ x: Int, _ y: Int) -> (Double, Double, Double) {
        let cx = Swift.min(Swift.max(x, window.x0), window.x1 - 1)
        let cy = Swift.min(Swift.max(y, window.y0), window.y1 - 1)
        let i = (cy - window.y0) * window.width + (cx - window.x0)
        let lab = scratch.lab
        if scratch.labReady[i] != 0 {
            return (Double(lab[i * 3]), Double(lab[i * 3 + 1]), Double(lab[i * 3 + 2]))
        }
        let rgb = MaskRaster.srcColor(src, cx, cy, width, height)
        var L = 0.0, A = 0.0, B = 0.0
        if rgb.isFinite {
            // `OKLabTransform.working.toLab`, with `cbrt` for its `pow(x, 1/3)`: the
            // same number to the last few bits and a third of the cost, on the one
            // conversion this stroke does per pixel.
            let lms = Self.toLMS.apply(rgb)
            let c = Self.toLab.apply(RGB(cbrt(lms.r), cbrt(lms.g), cbrt(lms.b)))
            // SHADING-INVARIANT FEATURES, not OKLab itself. Light falling off across
            // one object scales its linear RGB, and OKLab's cube root turns that into
            // the SAME factor on L, a and b — so plain ΔE called the lit and shaded
            // halves of one lemon different objects (a vertical cut through a dab on a
            // side-lit lemon) while every dark colour collapsed onto every other one (the
            // lemon's shaded rim matched the black table). Chromaticity a/L, b/L does not
            // move under shading; lightness still counts, as a log ratio at a fifth of
            // the weight, so 1 EV of shading costs ~0.05 and black against white is shut.
            let l = Swift.max(c.r, Self.lightnessFloor)
            L = Self.lightnessWeight * log(Swift.max(c.r, 0.02))
            A = c.g / l
            B = c.b / l
        }
        lab[i * 3] = Float(L); lab[i * 3 + 1] = Float(A); lab[i * 3 + 2] = Float(B)
        scratch.labReady[i] = 1
        return (L, A, B)
    }

    /// Mean Auto Mask features over a 5×5 grid spanning ±0.1 radius (at least ±2 px)
    /// around a point — one pixel of texture or noise must not decide what the stroke is
    /// painting — and the largest distance of any of the 25 from that mean, which says
    /// whether the point sits on one colour or across an edge.
    private mutating func sample(at q: Pt) -> (Double, Double, Double) {
        sampleWithSpread(at: q).mean
    }

    private mutating func sampleWithSpread(at q: Pt)
        -> (mean: (Double, Double, Double), spread: Double) {
        let step = Swift.max(1, 0.05 * radius)
        var values: [(Double, Double, Double)] = []
        values.reserveCapacity(25)
        var sL = 0.0, sA = 0.0, sB = 0.0
        for j in -2...2 {
            for i in -2...2 {
                let x = Int(Num.clamp((q.x + Double(i) * step).rounded(.down), 0, Double(width - 1)))
                let y = Int(Num.clamp((q.y + Double(j) * step).rounded(.down), 0, Double(height - 1)))
                let c = labAt(x, y)
                values.append(c)
                sL += c.0; sA += c.1; sB += c.2
            }
        }
        let mean = (sL / 25, sA / 25, sB / 25)
        var spread = 0.0
        for c in values {
            let dL = c.0 - mean.0, da = c.1 - mean.1, db = c.2 - mean.2
            spread = Swift.max(spread, (dL * dL + da * da + db * db).squareRoot())
        }
        return (mean, spread)
    }

    private mutating func startReference(at q: Pt) {
        guard source != nil, references.isEmpty else { return }
        references = [sample(at: q)]
    }

    /// Grow the accepted colours from where the centre has got to: a slab samples its
    /// far end. A sample joins only if it is within τ of a colour already accepted (and
    /// not a near-duplicate of one), so the set walks across one object's colour range —
    /// the lemon's limb, its lit side, its tip — but never jumps to a different object:
    /// a centre that has crossed onto the bowl samples the bowl, which matches nothing
    /// accepted, and is ignored.
    ///
    /// Not a single reference that follows the centre: that was tried and measured.
    /// Tracing the lemon's outline half a radius inside pulled a drifting reference
    /// toward the darker limb, and the stroke then leaked onto the potato beside it.
    /// And not a single fixed reference either: started on the limb, it rejected the
    /// lemon's own tip and the stroke stopped painting halfway round.
    private mutating func updateReferences(near q: Primitive) {
        if references.isEmpty {
            references = [sample(at: Pt(x: q.ax, y: q.ay, p: q.pa))]
        }
        guard q.isSlab, references.count < Self.maxReferences else { return }
        let b = Pt(x: q.ax + q.ux * q.length, y: q.ay + q.uy * q.length, p: q.pa + q.dp)
        let (c, spread) = sampleWithSpread(at: b)
        // A centre on an edge samples a mixture of both sides, and a mixture is within τ
        // of the side it came from — accept it and the next one is within τ of IT, and
        // the set walks off the object one blend at a time. So a colour joins only from
        // a centre that sits on one colour.
        guard spread < Self.automaskTau else { return }
        var best = Double.infinity
        for m in references {
            let dL = c.0 - m.0, da = c.1 - m.1, db = c.2 - m.2
            best = Swift.min(best, (dL * dL + da * da + db * db).squareRoot())
        }
        if best < Self.automaskTau && best > Self.automaskTau / 4 {
            references.append(c)
        }
    }
}

/// Auto Mask's per-pixel working memory over a raster's window: the feature cache and
/// its ready flags, and the flood's generation stamps, gated values and queue.
///
/// `calloc`, not five `Array(repeating:)`s. The window of a stroke painted whole is its
/// bounding box — 2300 × 700 pixels for a stroke across a 2400 px frame — and five
/// zero-filled arrays over it are ~40 MB written before a pixel is painted, which
/// measured as most of a thin Auto Mask stroke's cost. `calloc` hands back zero pages
/// the kernel maps on first touch, so a stroke pays for the pixels it reaches.
///
/// A class so the memory is freed with the raster; a copied raster shares it, which is
/// harmless for the cache (same pixels, same features) and the flood (scratch per call).
final class AutoMaskScratch {
    let lab: UnsafeMutablePointer<Float>
    let labReady: UnsafeMutablePointer<UInt8>
    let stamp: UnsafeMutablePointer<UInt32>
    let gated: UnsafeMutablePointer<Float>
    let queue: UnsafeMutablePointer<Int32>

    init?(count: Int) {
        let n = Swift.max(count, 1)
        guard let lab = calloc(n * 3, MemoryLayout<Float>.stride),
              let ready = calloc(n, 1),
              let stamp = calloc(n, MemoryLayout<UInt32>.stride),
              let gated = calloc(n, MemoryLayout<Float>.stride),
              let queue = calloc(n, MemoryLayout<Int32>.stride) else { return nil }
        self.lab = lab.bindMemory(to: Float.self, capacity: n * 3)
        self.labReady = ready.bindMemory(to: UInt8.self, capacity: n)
        self.stamp = stamp.bindMemory(to: UInt32.self, capacity: n)
        self.gated = gated.bindMemory(to: Float.self, capacity: n)
        self.queue = queue.bindMemory(to: Int32.self, capacity: n)
    }

    deinit {
        free(lab); free(labReady); free(stamp); free(gated); free(queue)
    }
}

extension BrushStrokeRaster.Rect {
    public var width: Int { Swift.max(x1 - x0, 0) }
    public var height: Int { Swift.max(y1 - y0, 0) }
}
