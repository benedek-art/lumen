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
    ///
    /// This two-argument form is the closed-form path alone: no picture, so only a mask
    /// `isParametric` accepts. `alpha(for:extent:source:)` is the wider one.
    static func alpha(for mask: Mask, extent: CGRect) -> CIImage? {
        guard isParametric(mask) else { return nil }
        return alpha(for: mask, extent: extent, source: nil)
    }

    // MARK: - The range path (lane M9)
    //
    // THE DEFECT THIS ENDS. Luminance range, luminosity and colour range are pointwise
    // functions of the stage input, and they took the CPU raster path like a hair matte:
    // a global Exposure drag with a sky band active re-keyed the raster on every event,
    // the drag wore the previous one (the band's edge a gesture behind the tones, snapping
    // at the pause), and every settle rasterized it again on one core at up to 4096 px —
    // 100–600 ms of a frame on the measuring container (docs/quality/lanes/M9/REPORT.md).
    // Evaluated here they cost the stage input as a second GPU graph (`gpuMaskStage`) plus
    // one pass per component (one per sample for a colour range), at the frame's own
    // resolution, and nothing is cached or can be stale.
    //
    // WHAT IS ELIGIBLE: every component one of linear, radial, lumaRange, luminosity,
    // colorRange, valid and with finite parameters; and a refinement chain that is
    // pointwise at this resolution — no guided refine (`refineRadius` < 1), no Edge, no
    // Blur. Whole-mask invert and Levels are pointwise and run here. Everything else
    // keeps the CPU path exactly as before.

    /// Whether the range kinds (luminance range, luminosity, colour range) take the
    /// kernels below. It was OFF from the integration of lane M4 (84698be) until lane M9b:
    /// M4 made luminance and colour range SPATIAL (`MaskRaster.rangeMeasured` denoises the
    /// measurement with a noise-adaptive guided pass at 1 px per 800 of long edge),
    /// centred the luminance shoulders on From/To and made the colour range ignore
    /// shading, and M9's kernels were the pointwise twin of the definition before that.
    /// They are M4's definition again — `MaskRangeMeasure` runs the measurement denoise
    /// on the GPU — and `MaskRangeGPUParityTests` holds them to it. Kept as a switch so a
    /// future definition change has one place to send range masks back to the CPU.
    static let rangeKindsOnGPU = true

    /// True when this mask has a GPU form at a render whose long edge is `longEdge`.
    static func isGPUEvaluable(_ mask: Mask, longEdge: Int) -> Bool {
        if isParametric(mask) { return true }
        guard rangeKindsOnGPU, KernelLibrary.rangeMasksAvailable else { return false }
        guard !mask.components.isEmpty else { return false }
        let r = mask.refine
        guard MaskRaster.refineRadius(feather: r.feather, longEdge: longEdge) < 1 else {
            return false
        }
        // `edgeShifted` engages on any finite non-zero Edge; `refined` blurs above σ 0.05.
        if r.edge.isFinite, r.edge != 0 { return false }
        if r.blur.isFinite,
           (Num.clamp(r.blur, 0, 100) / 100) * 0.01 * Double(longEdge) > 0.05 {
            return false
        }
        // The measurement denoise has a longest box (`KernelLibrary.rangeMaxRadius`).
        if mask.components.contains(where: { $0.kind == .lumaRange || $0.kind == .colorRange }),
           MaskRangeMeasure.radius(longEdge: longEdge) == nil {
            return false
        }
        for c in mask.components {
            guard c.validationError() == nil, c.amount.isFinite else { return false }
            switch c.kind {
            case .linear, .radial:
                guard isParametric(Mask(id: mask.id, components: [c])) else { return false }
            case .lumaRange:
                guard (c.smooth ?? 50).isFinite else { return false }
            case .luminosity:
                break
            case .colorRange:
                guard (c.rangeAmount ?? 50).isFinite else { return false }
            default:
                return false
            }
        }
        return true
    }

    /// Whether any component of an eligible mask samples the stage input.
    static func readsPicture(_ mask: Mask) -> Bool {
        mask.components.contains { $0.kind.readsSourceImage }
    }

    /// This mask's alpha over `extent`, sampling `source` — the stage input
    /// (`RenderGraph.localStageInput` with `maskSource`) over the same extent — for the
    /// components that read the picture. Nil when the mask is not `isGPUEvaluable`, or
    /// needs a picture and was given none.
    static func alpha(for mask: Mask, extent: CGRect, source: CIImage?) -> CIImage? {
        guard extent.width >= 1, extent.height >= 1 else { return nil }
        let longEdge = Int(Swift.max(extent.width, extent.height))
        guard isGPUEvaluable(mask, longEdge: longEdge) else { return nil }
        if source == nil, readsPicture(mask) { return nil }
        let w = Float(extent.width)
        let h = Float(extent.height)
        let ox = Float(extent.origin.x)
        let oy = Float(extent.origin.y)

        // The accumulator seeds at ZERO, so a stack opening with subtract or intersect
        // stays empty — the property `maskalgebra.json` pins for the CPU fold, and the
        // one a caller would notice first if this path disagreed.
        guard var accumulator = zero(extent: extent, w: w, h: h, ox: ox, oy: oy)
        else { return nil }

        // One measurement denoise per distinct measurement, not per component: two bands
        // on the same channel, or two colour ranges, read the same corrected plane.
        var corrections: [MaskRangeMeasure.Spec: CIImage] = [:]
        for c in mask.components {
            guard let raw = rawAlpha(c, extent: extent, source: source,
                                     w: w, h: h, ox: ox, oy: oy,
                                     corrections: &corrections)
            else { return nil }
            guard let folded = KernelLibrary.apply(
                KernelLibrary.maskFold, extent: extent,
                [accumulator, raw, Float(ordinal(c.op)),
                 Float(c.invert ? 1 : 0), Float(Num.clamp(c.amount, 0, 100))])
            else { return nil }
            accumulator = folded
        }

        // `MaskRaster.refined`, the pointwise steps: invert ahead of the chain, then Levels.
        if mask.invert {
            guard let inverted = KernelLibrary.apply(KernelLibrary.maskInvert,
                                                     extent: extent, [accumulator])
            else { return nil }
            accumulator = inverted
        }
        guard let levels = levelsArguments(mask.refine) else { return accumulator }
        return KernelLibrary.apply(KernelLibrary.maskLevels, extent: extent,
                                   [accumulator as Any] + levels)
    }

    /// An empty plane. A degenerate line: `dd < 1e-12` makes the linear kernel return
    /// zero everywhere, which is the cheapest correct way to ask for one.
    private static func zero(extent: CGRect, w: Float, h: Float,
                             ox: Float, oy: Float) -> CIImage? {
        KernelLibrary.applyGenerator(KernelLibrary.maskLinear, extent: extent,
                                     [Float(0), Float(0), Float(0), Float(0), w, h, ox, oy])
    }

    // MARK: - The reference's numbers
    //
    // `MaskRaster`'s constants, restated on this side so the shaders carry none. They are
    // private there; `MaskRangeGPUParityTests` is what keeps the two copies one.

    /// The fixed EV axis every channel-reading selection is denominated on.
    static let evMin: Double = -10
    static let evMax: Double = 4
    /// Luminance-band shoulder half-width at Smoothness 100, in EV.
    static let lumaShoulderEV: Double = 2.0

    /// `MaskChannel`'s ordinal as the kernels read it. A switch, so a new channel is a
    /// compile error here rather than a silently wrong band.
    static func ordinal(_ channel: MaskChannel) -> Int {
        switch channel {
        case .luma: return 0
        case .red: return 1
        case .green: return 2
        case .blue: return 3
        case .max: return 4
        case .min: return 5
        }
    }

    static func ordinal(_ series: LuminositySeries) -> Int {
        switch series {
        case .lights: return 0
        case .darks: return 1
        case .midtones: return 2
        }
    }

    private static var weightsVector: CIVector {
        let wts = RGBColorSpace.rec2020.luminanceWeights
        return CIVector(x: CGFloat(wts.r), y: CGFloat(wts.g), z: CGFloat(wts.b))
    }

    private static func rows(_ m: Mat3) -> [CIVector] {
        m.m.map { CIVector(x: CGFloat($0[0]), y: CGFloat($0[1]), z: CGFloat($0[2])) }
    }

    /// `MaskRaster.lumaRangePlane`'s band (`lumaRangeValue`'s centred shoulders), or nil
    /// for a band it rasterizes as empty. Follows the channel and weights arguments of
    /// `KernelLibrary.maskLumaRange`, after its two images.
    static func lumaRangeArguments(_ c: MaskComponent) -> [Any]? {
        guard let lo = c.lo, let hi = c.hi, lo.isFinite, hi.isFinite else { return nil }
        let lo01 = Num.saturate(lo)
        let hi01 = Num.saturate(Swift.max(hi, lo))
        let smooth = c.smooth.map { $0.isFinite ? $0 : 50 } ?? 50
        let s = Num.clamp(smooth, 0, 100) / 100
        let half = Swift.min(s * lumaShoulderEV / (evMax - evMin), hi01 - lo01) / 2
        return [Float(ordinal(c.channel ?? .luma)), weightsVector,
                Float(evMin), Float(evMax), Float(lo01), Float(hi01),
                Float(half), Float(half > 1e-9 ? 1 : 0)]
    }

    /// `MaskRaster.luminosityPlane`'s series.
    static func luminosityArguments(_ c: MaskComponent) -> [Any] {
        let raw = c.level ?? 1
        let n = raw.isFinite
            ? Num.clamp(raw, MaskRaster.luminosityMinLevel, MaskRaster.luminosityMaxLevel)
            : MaskRaster.luminosityMinLevel
        let peak = Swift.max(1 - pow(2, -n), 1e-6)
        return [Float(ordinal(c.channel ?? .luma)), weightsVector,
                Float(evMin), Float(evMax),
                Float(ordinal(c.series ?? .lights)), Float(n), Float(peak)]
    }

    /// `MaskRaster.colorRangePlane`'s references (at most eight, finite only), each as
    /// the arguments `KernelLibrary.maskColorRef` takes after its matrices, or nil when no
    /// reference survives — the reference's empty plane. `colorRangeValue`'s per-sample
    /// numbers are computed here: the floored lightness, the chroma and unit hue, and the
    /// toward-grey tolerance that caps at 90 % of the sample's own chroma.
    static func colorRangeArguments(_ c: MaskComponent)
        -> (references: [[Any]], matrices: [CIVector])? {
        guard let samples = c.samples, !samples.isEmpty else { return nil }
        let context = OKLabTransform.working
        let tol = MaskRaster.colorRangeTolerances(refine: c.rangeAmount ?? 50)
        let saturation = MaskRaster.colorRangeSaturationReach * tol.chroma
        var refs: [[Any]] = []
        for s in samples.prefix(8) where s.count >= 3 {
            guard s[0].isFinite, s[1].isFinite, s[2].isFinite else { continue }
            let lab = context.toLab(RGB(s[0], s[1], s[2]))
            guard lab.L.isFinite, lab.a.isFinite, lab.b.isFinite else { continue }
            let refL = Swift.max(lab.L, MaskRaster.colorRangeLFloor)
            let refC = (lab.a * lab.a + lab.b * lab.b).squareRoot()
            let hasHue = refC > 1e-6
            let toward = Swift.min(saturation,
                                   Swift.max(0.9 * refC, MaskRaster.colorRangeNeutralReach))
            refs.append([
                CIVector(x: CGFloat(refL), y: CGFloat(refC), z: hasHue ? 1 : 0),
                CIVector(x: hasHue ? CGFloat(lab.a / refC) : 0,
                         y: hasHue ? CGFloat(lab.b / refC) : 0),
                CIVector(x: CGFloat(tol.chroma), y: CGFloat(toward), z: CGFloat(saturation)),
                CIVector(x: CGFloat(MaskRaster.colorRangeCore),
                         y: CGFloat(MaskRaster.colorRangeEVCore),
                         z: CGFloat(MaskRaster.colorRangeLFloor)),
                Float(tol.ev),
            ])
        }
        if refs.isEmpty { return nil }
        return (refs, rows(context.rgbToLMS) + rows(OKLabTransform.lmsToLab))
    }

    /// `MaskRaster.levels`, or nil when it is the identity on an alpha already in [0, 1].
    static func levelsArguments(_ r: MaskRefine) -> [Any]? {
        let loIn = r.levelsLo.isFinite ? r.levelsLo : 0
        let hiIn = r.levelsHi.isFinite ? r.levelsHi : 100
        let lo01 = Num.saturate(loIn / 100)
        let hi01 = Num.saturate(hiIn / 100)
        let span = Swift.max(hi01 - lo01, 1e-4)
        let g = r.levelsGamma.isFinite ? Num.clamp(r.levelsGamma, 0.2, 5.0) : 1
        if lo01 == 0, hi01 == 1, g == 1 { return nil }
        return [Float(lo01), Float(span), Float(1 / g), Float(g == 1 ? 0 : 1)]
    }

    // MARK: - One component

    private static func rawAlpha(_ c: MaskComponent, extent: CGRect, source: CIImage?,
                                 w: Float, h: Float, ox: Float, oy: Float,
                                 corrections: inout [MaskRangeMeasure.Spec: CIImage])
        -> CIImage? {
        // The measurement denoise's correction for one spec, built once per mask.
        func correction(_ spec: MaskRangeMeasure.Spec, _ source: CIImage) -> CIImage? {
            if let held = corrections[spec] { return held }
            let made = MaskRangeMeasure.correction(spec, source: source, extent: extent)
            if let made { corrections[spec] = made }
            return made
        }
        switch c.kind {
        case .lumaRange:
            guard let source else { return nil }
            guard let arguments = lumaRangeArguments(c) else {
                return zero(extent: extent, w: w, h: h, ox: ox, oy: oy)
            }
            let spec = MaskRangeMeasure.Spec(colour: false,
                                             channel: ordinal(c.channel ?? .luma))
            guard let delta = correction(spec, source) else { return nil }
            return KernelLibrary.apply(KernelLibrary.maskLumaRange, extent: extent,
                                       [source as Any, delta] + arguments)
        case .luminosity:
            guard let source else { return nil }
            return KernelLibrary.apply(KernelLibrary.maskLuminosity, extent: extent,
                                       [source as Any] + luminosityArguments(c))
        case .colorRange:
            guard let source else { return nil }
            guard var best = zero(extent: extent, w: w, h: h, ox: ox, oy: oy) else {
                return nil
            }
            guard let parts = colorRangeArguments(c) else { return best }
            guard let delta = correction(MaskRangeMeasure.Spec(colour: true, channel: 0),
                                         source)
            else { return nil }
            for reference in parts.references {
                var arguments: [Any] = [source, delta, best]
                arguments.append(contentsOf: parts.matrices as [Any])
                arguments.append(contentsOf: reference)
                guard let next = KernelLibrary.apply(KernelLibrary.maskColorRef,
                                                     extent: extent, arguments)
                else { return nil }
                best = next
            }
            return best
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
            let rin = MaskRaster.radialCore(radii: (rx, ry), feather: c.feather,
                                            width: Int(w), height: Int(h))
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
