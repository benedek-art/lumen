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
