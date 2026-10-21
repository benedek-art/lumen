// SpotRetouch.swift
// S5 RETOUCH (docs/14): circular Heal and Clone spots, the f32 reference.
//
// WHERE IT RUNS. After S3 denoise and before the S6 linear matrix, on the scene-linear
// decode. Retouch early, so a healed patch inherits every downstream stage — white
// balance, tone, grade, grain — and cannot reveal itself the moment a look is applied
// (docs/14 §2.1 rule 3). `ReferenceRenderer.render` opens with it (its input has been
// through S3 upstream of the call) and `RenderGraph.colorStageInput` runs it straight
// after `applyDenoise`; both read every constant and every formula from this file.
//
// CLONE copies the source patch: `out = I(p + d)`. The offset `d` is rounded to whole
// pixels at resolve, so every borrowed pixel is a real pixel: a bilinear read at a
// fractional offset averages four, which smoothed the grain to half its amplitude and
// left a soft disc in a noisy sky (WS-56: texture ratio 0.49–0.81 → 0.94–1.07).
//
// HEAL is the gradient-domain (Poisson) blend of Pérez et al. 2003, solved in CLOSED
// FORM rather than iterated, which is what lets the GPU match it exactly — and solved
// in the LOG domain (`LumenLog`), because light is multiplicative. The Poisson problem
// "take the source's gradients, meet the destination at the boundary" has the solution
// `f = I(p + d) · e^M(p)` there, i.e. `encode(f) = encode(I(p + d)) + M(p)`, where `M`
// is the HARMONIC function on the disc whose boundary values are the log ratio
// `encode(I_dst) − encode(I_src)` around the rim. An additive membrane in linear light
// keeps the source's ABSOLUTE texture: a source half as bright came back with half the
// destination's contrast, a flat milky disc on foliage, and a dark pixel could go
// negative. On a disc the harmonic interpolant of a boundary function is the Poisson
// integral, and discretized at N equally spaced rim samples it is a weighted mean with
// weights
//
//     w_k = (1 − ρ²) / |q − u_k|²     (q = (p − c)/R_rim, u_k the k-th rim direction)
//
// The (1 − ρ²) factor is common to every k and cancels in the normalization, so each
// pixel's membrane is `Σ b_k / |q − u_k|²  ÷  Σ 1 / |q − u_k|²`. No solver, no
// iteration count, no convergence tolerance: one boundary pass of N samples and one
// per-pixel pass, the same arithmetic on both sides. At the centre it is the mean
// boundary ratio, which is the patch re-lit to the surroundings' level. That
// re-lighting — illumination and colour from the destination, texture from the source
// — is the whole difference between Heal and Clone.
//
// THE RIM is sampled `rimMargin` (one pixel) outside the spot's reach, so a defect
// that runs right to a hard-edged circle is not its own boundary condition, and it is
// LOW-PASSED: each rim sample is the Hann-weighted mean of `boundarySubsamples` points
// across `boundaryArc` rim spacings, destination and source averaged BEFORE the log, so
// one bright leaf or sky gap on the rim is not a boundary value the membrane carries
// into the middle of the patch.
//
// THE EDGE. The feather lies OUTSIDE the circle the photographer drew: everything inside
// it is replaced at full opacity, and the soft edge reaches `featherReach` radii further
// at Feather 100. With the feather inside (as before WS-56), Feather 50 blended half of
// the defect's own pixels back in at ρ = 0.75, and a speck left a visible ring. The
// resolved geometry's `radius` is that REACH, and `rin = circle ÷ reach`;
// `alpha = opacity · (1 − smoothstep(rin, 1, ρ))`, `MaskRaster.radialPlane`'s shape.
// Pixels at or beyond the reach are not touched at all, which is what makes a recipe's
// untouched regions — and a recipe with no spots — byte-identical to the input.
//
// COORDINATES are `ImageBuffer`'s: top-down, pixel centres at +0.5. Positions are
// fractions of width and height; the radius is a fraction of the LONG edge, so the same
// spot covers the same content at every render size.

import Foundation

public enum SpotRetouch {

    /// Rim samples in the Poisson integral. Shared with the GPU kernels, which loop over
    /// exactly this many.
    public static let boundarySamples = 64
    /// Points averaged along each rim sample's arc, Hann-weighted.
    public static let boundarySubsamples = 16
    /// The arc each rim sample averages, in rim spacings: four, so the rim is smoothed
    /// over about 22° and adjacent samples share most of their points.
    public static let boundaryArc: Double = 4
    /// How far the soft edge reaches beyond the circle at Feather 100, in radii.
    public static let featherReach = 1.0
    /// The rim is sampled this many pixels OUTSIDE the reach, so at Feather 0 a defect
    /// that runs right to the circle is not part of its own boundary condition (it left
    /// 0.21 stops of a speck behind when the rim sat on the circle).
    public static let rimMargin = 1.0

    /// A spot resolved against one frame's pixel grid. Both renderers derive their
    /// numbers from this, so they cannot disagree about where a spot is.
    public struct SpotGeometry: Sendable, Equatable {
        /// Destination centre, pixels.
        public let cx: Double
        public let cy: Double
        /// Source centre, pixels.
        public let sx: Double
        public let sy: Double
        /// Radius, pixels.
        public let radius: Double
        /// Flat core as a fraction of the radius.
        public let rin: Double
        /// 0…1.
        public let opacity: Double
        public let heal: Bool
        /// Pixels that can change: x in `minX..<maxX`, y in `minY..<maxY`, top-down.
        public let minX: Int
        public let minY: Int
        public let maxX: Int
        public let maxY: Int

        public var isEmpty: Bool { minX >= maxX || minY >= maxY }
    }

    /// The radius a spot reaches, feather included, in pixels of a frame whose long edge
    /// is `edge` — what the source search must keep clear of the destination and match
    /// the context beyond.
    public static func reach(of spot: HealSpot, edge: Double) -> Double {
        let circle = Swift.max(
            Num.clamp(spot.radius.isFinite ? spot.radius : HealSpot.defaultRadius,
                      HealSpot.radiusRange.lowerBound, HealSpot.radiusRange.upperBound)
                * edge, 0.5)
        let feather = Num.clamp(spot.feather.isFinite ? spot.feather : 0, 0, 100) / 100
        return circle * (1 + featherReach * feather)
    }

    /// The circle as a fraction of the reach: 1 without feather.
    public static func core(of spot: HealSpot) -> Double {
        let feather = Num.clamp(spot.feather.isFinite ? spot.feather : 0, 0, 100) / 100
        return 1 / (1 + featherReach * feather)
    }

    /// Resolve a spot on a `width`×`height` frame, or nil when it cannot change a pixel
    /// (non-finite geometry, zero opacity, entirely off the frame).
    public static func resolve(_ spot: HealSpot, width: Int, height: Int) -> SpotGeometry? {
        guard width > 0, height > 0 else { return nil }
        let values = [spot.x, spot.y, spot.sourceX, spot.sourceY, spot.radius,
                      spot.feather, spot.opacity]
        guard values.allSatisfy({ $0.isFinite }) else { return nil }
        let opacity = Num.clamp(spot.opacity, 0, 100) / 100
        guard opacity > 0 else { return nil }

        let w = Double(width), h = Double(height)
        let edge = Swift.max(w, h)
        let circle = Swift.max(
            Num.clamp(spot.radius, HealSpot.radiusRange.lowerBound,
                      HealSpot.radiusRange.upperBound) * edge, 0.5)
        let feather = Num.clamp(spot.feather, 0, 100) / 100
        // The feather lies OUTSIDE the circle: everything the photographer ringed is
        // replaced at full opacity, and the soft edge blends into clean picture.
        let radius = circle * (1 + featherReach * feather)
        let rin = Num.clamp(circle / radius, 0, 1 - 1e-6)

        let cx = spot.x * w, cy = spot.y * h
        // The borrowed patch is a whole number of pixels away, so every pixel it copies
        // is a real pixel rather than a bilinear mean of four, which would smooth the
        // grain and leave a soft disc in a noisy sky. Half a pixel, at most, of shift.
        let sx = cx + (spot.sourceX * w - cx).rounded()
        let sy = cy + (spot.sourceY * h - cy).rounded()
        // Intersect with the frame in floating point BEFORE converting: a finite position
        // from a decoded recipe (x = 1e20) does not fit in Int and would trap.
        let minX = StrokeHeal.boundedIndex(floor(cx - radius), lower: 0, upper: width)
        let minY = StrokeHeal.boundedIndex(floor(cy - radius), lower: 0, upper: height)
        let maxX = StrokeHeal.boundedIndex(ceil(cx + radius), lower: 0, upper: width)
        let maxY = StrokeHeal.boundedIndex(ceil(cy + radius), lower: 0, upper: height)
        let resolved = SpotGeometry(cx: cx, cy: cy, sx: sx, sy: sy,
                                radius: radius, rin: rin, opacity: opacity,
                                heal: spot.mode == .heal,
                                minX: minX, minY: minY, maxX: maxX, maxY: maxY)
        return resolved.isEmpty ? nil : resolved
    }

    /// The spot's alpha at normalized distance `rho` from its centre.
    @inlinable
    public static func alpha(rho: Double, rin: Double, opacity: Double) -> Double {
        if rho >= 1 { return 0 }
        if rho <= rin { return opacity }
        let t = Num.clamp((rho - rin) / Swift.max(1 - rin, 1e-12), 0, 1)
        return opacity * (1 - t * t * (3 - 2 * t))
    }

    /// The direction of rim sample `k`.
    @inlinable
    public static func rimAngle(_ k: Int) -> Double {
        2 * Double.pi * Double(k) / Double(boundarySamples)
    }

    /// The angle of sub-sample `j` of rim sample `k`: spread across `boundaryArc` rim
    /// spacings, centred on `rimAngle(k)`.
    @inlinable
    public static func subsampleAngle(_ k: Int, _ j: Int) -> Double {
        let arc = 2 * Double.pi / Double(boundarySamples)
        let offset = boundaryArc * ((Double(j) + 0.5) / Double(boundarySubsamples) - 0.5)
        return arc * (Double(k) + offset)
    }

    /// Sub-sample `j`'s Hann weight, `sin²(π (j + ½) / J)`: neighbouring rim samples
    /// overlap and the rim is LOW-PASSED, so one bright leaf or sky gap on the rim is not
    /// a boundary value the membrane then carries into the middle of the patch.
    @inlinable
    public static func subsampleWeight(_ j: Int) -> Double {
        let t = sin(Double.pi * (Double(j) + 0.5) / Double(boundarySubsamples))
        return t * t
    }

    /// The boundary condition of the membrane: around the rim, the destination's and the
    /// source's weighted means, each through `LumenLog.encode`, and their difference — a
    /// log ratio, so the patch is re-lit by multiplying. Light is multiplicative: an
    /// additive re-light of a source half as bright keeps its absolute texture and
    /// reads as a flat, milky disc on foliage (texture ratio 0.72 → 0.94 measured), and
    /// can drive a dark pixel negative. The shaper's linear toe keeps zero and negatives
    /// finite.
    public static func boundaryDifferences(_ image: ImageBuffer,
                                           _ spot: SpotGeometry) -> [RGB] {
        (0..<boundarySamples).map { k in
            var d = RGB.zero, s = RGB.zero, total = 0.0
            for j in 0..<boundarySubsamples {
                let theta = subsampleAngle(k, j)
                let weight = subsampleWeight(j)
                let r = spot.radius + rimMargin
                let ux = cos(theta) * r, uy = sin(theta) * r
                d = d + image.bilinear(spot.cx + ux, spot.cy + uy) * weight
                s = s + image.bilinear(spot.sx + ux, spot.sy + uy) * weight
                total += weight
            }
            return LumenLog.encode(d / total) - LumenLog.encode(s / total)
        }
    }

    /// The membrane at normalized offset `(qx, qy)` from the centre: the discrete
    /// Poisson integral of the rim differences.
    public static func membrane(qx: Double, qy: Double, boundary: [RGB]) -> RGB {
        var acc = RGB.zero
        var total = 0.0
        for k in 0..<boundary.count {
            let theta = rimAngle(k)
            let dx = qx - cos(theta), dy = qy - sin(theta)
            let weight = 1 / Swift.max(dx * dx + dy * dy, 1e-6)
            acc = acc + boundary[k] * weight
            total += weight
        }
        return total > 0 ? acc / total : .zero
    }

    /// Apply every spot, in order, each reading what the previous ones left.
    ///
    /// No spots, no work and no copy: the input is returned as it came in, which is the
    /// byte-identity a recipe without spots is owed.
    public static func apply(_ image: ImageBuffer, spots: [HealSpot]) -> ImageBuffer {
        var current = image
        for spot in spots {
            guard let resolved = resolve(spot, width: image.width, height: image.height)
            else { continue }
            current = apply(current, resolved)
        }
        return current
    }

    /// One spot.
    public static func apply(_ input: ImageBuffer, _ spot: SpotGeometry) -> ImageBuffer {
        let boundary = spot.heal ? boundaryDifferences(input, spot) : []
        var out = input
        let dx = spot.sx - spot.cx, dy = spot.sy - spot.cy
        for y in spot.minY..<spot.maxY {
            let py = Double(y) + 0.5
            for x in spot.minX..<spot.maxX {
                let px = Double(x) + 0.5
                let qx = (px - spot.cx) / spot.radius
                let qy = (py - spot.cy) / spot.radius
                let rho = (qx * qx + qy * qy).squareRoot()
                let a = alpha(rho: rho, rin: spot.rin, opacity: spot.opacity)
                guard a > 0 else { continue }
                var fill = input.bilinear(px + dx, py + dy)
                if spot.heal {
                    // On the circle the rim was sampled on.
                    let rim = spot.radius + rimMargin
                    let m = membrane(qx: (px - spot.cx) / rim, qy: (py - spot.cy) / rim,
                                     boundary: boundary)
                    fill = LumenLog.decode(LumenLog.encode(fill) + m)
                }
                out[x, y] = input[x, y].mix(fill, a)
            }
        }
        return out
    }
}
