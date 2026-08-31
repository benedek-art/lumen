// MaskAlgebra.swift
// The reference semantics for combining mask components (docs/08, v1 docs/05):
//   add        →  acc = max(acc, v)          (union)
//   subtract   →  acc = min(acc, 1 − v)
//   intersect  →  acc = acc · v
// applied in component order over per-pixel alphas in [0,1]. Component `invert`
// flips its alpha first; component `amount` (0…100) scales its alpha.
//
// Mask-level `amount` (0…200) does NOT touch the raster — it multiplies the mask's
// adjustment values at apply time (docs/08 §Amount). Keeping raster and strength
// orthogonal is what makes the pin-scrub gesture cheap.
//
// The GPU rasterizer must match this fold exactly; goldens live in
// Tests/LumenCoreTests/Fixtures/maskalgebra.json.

import Foundation

public enum MaskAlgebra {

    /// A mask's adjusted pixel, combined with the one underneath through its blend mode
    /// — BEFORE the alpha composite, which is unchanged.
    ///
    /// The whole of S11 for one pixel is:
    ///
    ///     adjusted = localAdjust(base)
    ///     blended  = blended(base:adjusted:blend:space:)
    ///     out      = mix(base, blended, alpha)
    ///
    /// so a mask in Normal mode is bit-identical to what shipped before blend modes
    /// existed — `blended` returns `adjusted` untouched — and every other mode composites
    /// through the same alpha it always did.
    ///
    /// Both modes are luminance-ratio rescales, which is why they are the two that are
    /// well defined on the scene-referred values this stage carries. Neither clamps and
    /// neither assumes a white point.
    ///
    /// **Luminosity** takes the adjusted pixel's brightness and the ORIGINAL's colour:
    /// scale the base until its luminance matches. Burning a face gets darker without
    /// getting more orange, which is what happens when Exposure moves a warm pixel.
    ///
    /// **Colour** is the mirror: the adjusted pixel's chromaticity at the ORIGINAL's
    /// brightness. Warming a sky stops lifting it.
    ///
    /// The degenerate cases are both real photographs rather than hypotheticals — a
    /// clipped black is luminance zero, and there is no colour in it to preserve — so
    /// each falls back to the mode that has something to say rather than to a division.
    public static func blended(base: RGB, adjusted: RGB, blend: MaskBlend,
                               space: RGBColorSpace) -> RGB {
        switch blend {
        case .normal:
            return adjusted
        case .luminosity:
            let from = space.luminance(base)
            let to = space.luminance(adjusted)
            guard from > luminanceFloor, to.isFinite else { return adjusted }
            let scale = to / from
            guard scale.isFinite else { return adjusted }
            return base * scale
        case .color:
            let from = space.luminance(adjusted)
            let to = space.luminance(base)
            guard from > luminanceFloor, to.isFinite else { return base }
            let scale = to / from
            guard scale.isFinite else { return base }
            return adjusted * scale
        }
    }

    /// Below this luminance a pixel has no ratio worth taking. Scene-linear, and two
    /// decades under the darkest value a 14-bit raw can hold above its own noise floor,
    /// so it excludes only pixels that are numerically black.
    public static let luminanceFloor: Double = 1e-7

    /// One component's contribution: raw alpha → invert → amount scale.
    public static func componentAlpha(raw: Double, invert: Bool, amount: Double) -> Double {
        let clamped = min(max(raw, 0), 1)
        let flipped = invert ? 1 - clamped : clamped
        return flipped * min(max(amount, 0), 100) / 100
    }

    /// Fold a component stack over per-pixel raw alphas. `stack` pairs each component's
    /// (op, invert, amount) with its raw alpha at this pixel. Accumulator starts at 0,
    /// so a stack that begins with subtract/intersect stays empty — same as LR.
    public static func combined(
        _ stack: [(op: MaskOp, invert: Bool, amount: Double, alpha: Double)]
    ) -> Double {
        var acc = 0.0
        for c in stack {
            let v = componentAlpha(raw: c.alpha, invert: c.invert, amount: c.amount)
            switch c.op {
            case .add: acc = max(acc, v)
            case .subtract: acc = min(acc, 1 - v)
            case .intersect: acc *= v
            }
        }
        return acc
    }
}
