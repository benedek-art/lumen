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
// CLONE copies the source patch: `out = I(p + d)`.
//
// HEAL is the gradient-domain (Poisson) blend of Pérez et al. 2003, and it is solved in
// CLOSED FORM rather than iterated, which is what lets the GPU match it exactly. The
// Poisson problem "take the source's gradients, meet the destination at the boundary"
// has the solution `f = I(p + d) + M(p)`, where `M` is the HARMONIC function on the disc
// whose boundary values are the difference `I_dst − I_src` around the rim. On a disc the
// harmonic interpolant of a boundary function is the Poisson integral, and discretized
// at N equally spaced rim samples it is a weighted mean with weights
//
//     w_k = (1 − ρ²) / |q − u_k|²     (q = (p − c)/R, u_k the k-th rim direction)
//
// The (1 − ρ²) factor is common to every k and cancels in the normalization, so each
// pixel's membrane is `Σ b_k / |q − u_k|²  ÷  Σ 1 / |q − u_k|²`. No solver, no
// iteration count, no convergence tolerance: one boundary pass of N samples and one
// per-pixel pass, the same arithmetic on both sides. Near the rim the weight
// concentrates on the nearest samples, so the patch meets the destination; at the
// centre it is the mean boundary difference, which is the patch re-lit to the
// surroundings' level. That re-lighting — illumination and colour from the
// destination, texture from the source — is the whole difference between Heal and
// Clone.
//
// Each rim sample is the mean of `boundarySubsamples` points along its own arc, so a
// sample is not one noisy pixel and a large spot's rim is covered rather than sparsely
// pointed at.
//
// THE EDGE. `alpha = opacity · (1 − smoothstep(rin, 1, ρ))`, with `rin = 1 − feather`
// guarded to one pixel — `MaskRaster.radialPlane`'s rule, so a spot's soft edge and a
// radial mask's are the same shape. Pixels at or beyond the radius are not touched at
// all, which is what makes a recipe's untouched regions — and a recipe with no spots —
// byte-identical to the input.
//
// COORDINATES are `ImageBuffer`'s: top-down, pixel centres at +0.5. Positions are
// fractions of width and height; the radius is a fraction of the LONG edge, so the same
// spot covers the same content at every render size.

import Foundation

public enum SpotRetouch {

    /// Rim samples in the Poisson integral. Shared with the GPU kernels, which loop over
    /// exactly this many.
    public static let boundarySamples = 64
    /// Points averaged along each rim sample's arc.
    public static let boundarySubsamples = 4

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
        let radius = Swift.max(
            Num.clamp(spot.radius, HealSpot.radiusRange.lowerBound,
                      HealSpot.radiusRange.upperBound) * edge, 0.5)
        let feather = Num.clamp(spot.feather, 0, 100) / 100
        let pixelGuard = Num.saturate(1.0 / Swift.max(radius, 1))
        let rin = Num.clamp(Swift.max(1 - feather, pixelGuard), 0, 1 - 1e-6)

        let cx = spot.x * w, cy = spot.y * h
        let minX = Swift.max(Int(floor(cx - radius)), 0)
        let minY = Swift.max(Int(floor(cy - radius)), 0)
        let maxX = Swift.min(Int(ceil(cx + radius)), width)
        let maxY = Swift.min(Int(ceil(cy + radius)), height)
        let resolved = SpotGeometry(cx: cx, cy: cy, sx: spot.sourceX * w, sy: spot.sourceY * h,
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

    /// The angle of sub-sample `j` of rim sample `k`: evenly spread across the arc the
    /// sample stands for, centred on `rimAngle(k)`.
    @inlinable
    public static func subsampleAngle(_ k: Int, _ j: Int) -> Double {
        let arc = 2 * Double.pi / Double(boundarySamples)
        let offset = (Double(j) + 0.5) / Double(boundarySubsamples) - 0.5
        return arc * (Double(k) + offset)
    }

    /// `I_dst − I_src` around the rim — the boundary condition of the membrane.
    public static func boundaryDifferences(_ image: ImageBuffer,
                                           _ spot: SpotGeometry) -> [RGB] {
        (0..<boundarySamples).map { k in
            var acc = RGB.zero
            for j in 0..<boundarySubsamples {
                let theta = subsampleAngle(k, j)
                let ux = cos(theta) * spot.radius, uy = sin(theta) * spot.radius
                acc = acc + image.bilinear(spot.cx + ux, spot.cy + uy)
                    - image.bilinear(spot.sx + ux, spot.sy + uy)
            }
            return acc / Double(boundarySubsamples)
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
                    fill = fill + membrane(qx: qx, qy: qy, boundary: boundary)
                }
                out[x, y] = input[x, y].mix(fill, a)
            }
        }
        return out
    }
}
