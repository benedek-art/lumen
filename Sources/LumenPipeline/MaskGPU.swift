// MaskGPU.swift
// The parametric fast path: a mask made only of gradients never touches the CPU.
//
// THE DEFECT THIS ENDS. A linear gradient is a smoothstep along an axis and a radial is
// a signed distance to an ellipse — the two cheapest closed forms in the pipeline — and
// both were rasterized into a `Plane` on the CPU like a hair matte. So dragging one
// rewrote its geometry on every mouse event, changed the raster cache's key, missed, and
// was served THE PREVIOUS RASTER while the exact one baked on a background queue. The
// bright region trailed the handle by a gesture. That is the tail, and it is not a
// cache-tuning problem: the fix is for the geometry never to be rasterized at all
// (docs/35 §5.1).
//
// WHAT IS ELIGIBLE, and the rule is deliberately narrow. Every component must be a
// linear or radial gradient with valid geometry, and the refinement chain must be
// identity. The chain is a guided filter, a distance transform and a Gaussian; those are
// the parts that legitimately need the picture and a neighbourhood, and a mask that uses
// them takes the CPU path exactly as before. A mask that does not — which is every
// gradient a photographer drags — is a closed form the GPU evaluates for free at the
// resolution the frame is being rendered at anyway.
//
// COORDINATES. `MaskRaster` measures in LONG-EDGE units, because pixels are square and
// normalized coordinates are not: applying a rotation to (fraction of width, fraction of
// height) mixes two units and renders a 45° ellipse at 33.7°. The kernels take `w`, `h`
// and the extent origin and do the same arithmetic on `destCoord()`, whose y runs the
// same direction as a `Plane`'s rows through `PipelineRenderer.image(from:)` — that
// bridge scales and translates and never flips, which is why no flip appears here.
//
// The `rin` guard, the smoothstep, the fold order and the clamp points are all
// `MaskRaster`'s, computed on this side where they can be shared rather than written
// twice into shader text. `MaskGPUParityTests` compares the two at three resolutions,
// including a non-power-of-two, and fails on a worst-pixel difference past 1e-4.

#if os(macOS)

import CoreImage
import Foundation
import LumenCore

enum MaskGPU {

    /// Worst per-pixel difference the parity test allows between this path and
    /// `MaskRaster`. Float32 on the GPU against f64 on the CPU, through a smoothstep and
    /// a square root; 1e-4 is two orders inside what an 8-bit edge could show.
    static let parityTolerance: Double = 1e-4

    /// True when this mask is a closed form: only gradients, and no refinement.
    ///
    /// `mask.invert` is allowed — it is one more kernel. `mask.amount` is not consulted
    /// because it never touches the raster; it scales the adjustments at apply time.
    static func isParametric(_ mask: Mask) -> Bool {
        guard KernelLibrary.parametricMasksAvailable else { return false }
        guard mask.refine == MaskRefine() else { return false }
        guard !mask.components.isEmpty else { return false }
        for c in mask.components {
            guard c.validationError() == nil else { return false }
            switch c.kind {
            case .linear:
                guard let line = c.line, line.count == 4,
                      line.allSatisfy({ $0.isFinite }) else { return false }
            case .radial:
                guard let centre = c.center, centre.count == 2,
                      let radii = c.radii, radii.count == 2,
                      centre.allSatisfy({ $0.isFinite }),
                      radii.allSatisfy({ $0.isFinite }),
                      abs(radii[0]) > 1e-9, abs(radii[1]) > 1e-9 else { return false }
            default:
                return false
            }
        }
        return true
    }

    /// This mask's alpha as a CIImage, or nil when it is not eligible.
    ///
    /// Nil is a fall-back signal, never an error: the caller runs `MaskRaster` and gets
    /// the same picture more slowly. Every guard in here returns nil rather than
    /// producing a partial mask, because a mask that is half right is worse than one
    /// that is late.
    static func alpha(for mask: Mask, extent: CGRect) -> CIImage? {
        guard isParametric(mask), extent.width >= 1, extent.height >= 1 else { return nil }
        let w = Float(extent.width)
        let h = Float(extent.height)
        let ox = Float(extent.origin.x)
        let oy = Float(extent.origin.y)

        // The accumulator seeds at ZERO, so a stack opening with subtract or intersect
        // stays empty — the property `maskalgebra.json` pins for the CPU fold, and the
        // one a caller would notice first if this path disagreed.
        guard var accumulator = KernelLibrary.applyGenerator(
            KernelLibrary.maskLinear, extent: extent,
            // A degenerate line: `dd < 1e-12` makes the kernel return zero everywhere,
            // which is the cheapest correct way to ask for an empty plane.
            [Float(0), Float(0), Float(0), Float(0), w, h, ox, oy])
        else { return nil }

        for c in mask.components {
            guard let raw = rawAlpha(c, extent: extent, w: w, h: h, ox: ox, oy: oy)
            else { return nil }
            guard let folded = KernelLibrary.apply(
                KernelLibrary.maskFold, extent: extent,
                [accumulator, raw, Float(ordinal(c.op)),
                 Float(c.invert ? 1 : 0), Float(Num.clamp(c.amount, 0, 100))])
            else { return nil }
            accumulator = folded
        }

        guard mask.invert else { return accumulator }
        return KernelLibrary.apply(KernelLibrary.maskInvert, extent: extent, [accumulator])
    }

    // MARK: - One component

    private static func rawAlpha(_ c: MaskComponent, extent: CGRect,
                                 w: Float, h: Float, ox: Float, oy: Float) -> CIImage? {
        switch c.kind {
        case .linear:
            guard let line = c.line, line.count == 4 else { return nil }
            return KernelLibrary.applyGenerator(
                KernelLibrary.maskLinear, extent: extent,
                [Float(line[0]), Float(line[1]), Float(line[2]), Float(line[3]),
                 w, h, ox, oy])
        case .radial:
            guard let centre = c.center, centre.count == 2,
                  let radii = c.radii, radii.count == 2 else { return nil }
            let rx = abs(radii[0]), ry = abs(radii[1])
            // `MaskRaster.radialPlane`'s numbers, computed here rather than in shader
            // text so there is one copy of the policy and the shader carries none.
            let theta = -(c.rotation ?? 0) * Double.pi / 180
            let f = Num.clamp(c.feather ?? 50, 0, 100) / 100
            let rxPx = Swift.max(rx * Double(w), 1e-6)
            let ryPx = Swift.max(ry * Double(h), 1e-6)
            let pixelGuard = Num.saturate(1.0 / Swift.max(Swift.min(rxPx, ryPx), 1))
            let rin = Num.clamp(Swift.max(1 - f, pixelGuard), 0, 1 - 1e-6)
            return KernelLibrary.applyGenerator(
                KernelLibrary.maskRadial, extent: extent,
                [Float(centre[0]), Float(centre[1]), Float(rx), Float(ry),
                 Float(cos(theta)), Float(sin(theta)), Float(rin), w, h, ox, oy])
        default:
            return nil
        }
    }

    /// `MaskOp`'s ordinal, as the fold kernel reads it. Written as a switch rather than
    /// taken off a `CaseIterable` index, so adding an operation is a compile error here
    /// instead of a silently renumbered shader.
    private static func ordinal(_ op: MaskOp) -> Int {
        switch op {
        case .add: return 0
        case .subtract: return 1
        case .intersect: return 2
        }
    }
}

#endif
