// MaskRaster.swift
// The reference mask rasterizer (docs/08 §8.2–8.5, docs/14 §5.6 S11): one component's
// raw alpha, the stack fold, and the refinement chain. This is the f64 CPU definition
// the GPU rasterizer is measured against (docs/14 §1.4) — the fold here must match
// Model/MaskAlgebra.swift bit-for-bit, because that file is the algebra's authority
// and Tests/.../maskalgebra.json is its golden.
//
// Coordinate contract (docs/08 §8.1, docs/14 §5.8): every vector component is stored
// in SOURCE-NORMALIZED coordinates and rasterized at the requested extent, so a crop
// or a rotation re-rasterizes a mask instead of orphaning it. Nothing here reads pixel
// coordinates out of a recipe.
//
// Robustness posture (docs/08 §8.7, docs/15 §15.7): a malformed component is an empty
// mask, never a trap. `validationError() != nil` → zero plane; a missing stroke blob,
// a missing AI matte, or a nil stage input → zero plane. Masks are user work in flight;
// the read path degrades and badges, it does not crash.
//
// The [D] constants below (stamp profile, EV axis, selectivity σ mapping, tolerance
// ramps, guided-filter ε) are the phase-4 brief's derived closed forms: the spec fixes
// the behavior, these fix the numbers. Each is a golden-test item.
//
// Spatial kernels come from Image/SpatialOps.swift: the guided filter, the Gaussian,
// and the box blur are shared with the tone and detail stages.

import Foundation

public enum MaskRaster {

    // MARK: - Derived constants (the [D] choices)

    /// Fixed EV axis for the luminance band. Never per-image auto-ranging — EV
    /// denomination exists so the same band means the same thing on every photo.
    private static let evMin: Double = -10
    private static let evMax: Double = 4
    private static let evSpan: Double = 14
    /// Luminance-band shoulder half-width at Smoothness 100, in EV (so 50 → 1.0 EV).
    private static let lumaShoulderEV: Double = 2.0
    /// Depth-band shoulder half-width at Smoothness 100, in normalized depth.
    private static let depthShoulder: Double = 0.15
    /// Automask OKLab ΔE tolerance; the gate fades out over [τ, 2τ].
    private static let automaskTau: Double = 0.06
    /// Trapezoid shoulder fraction for the colour-range per-axis falloff.
    private static let trapezoidShoulder: Double = 0.5
    /// Guided-filter regularization on the [0,1]-normalized guide. Not user-exposed —
    /// docs/08's explicit criticism of darktable is that it exposes this raw.
    private static let guidedEpsilon: Double = 1e-4
    /// Similarity Gaussian widths at selectivity 0, and the log-scale decade span.
    private static let sigmaChroma0: Double = 0.30
    private static let sigmaLuma0: Double = 0.50
    private static let selectivityDecades: Double = 1.2
    /// Arc-length stamp spacing as a fraction of the stamp radius (floor: 1 px).
    private static let stampSpacingFraction: Double = 0.10
    /// Work guards. A pathological stroke must not turn into an unbounded loop.
    private static let maxDenseSamples: Int = 400_000
    private static let maxStamps: Int = 200_000

    // MARK: - Public API

    /// One component's RAW alpha, before `invert` and `amount` (those belong to the
    /// fold — see `MaskAlgebra.componentAlpha`). Returns a zero plane rather than
    /// trapping for every malformed or unsatisfiable input.
    ///
    /// - Parameters:
    ///   - source: the S11 stage input a range-type component samples (luma / colour /
    ///     similarity / brush automask). `nil` ⇒ those kinds return zero.
    ///   - strokes: the decoded blob behind a brush component's `strokesRef`.
    ///   - aiMattes: precomputed mattes keyed by `MaskKind.rawValue`; `depthRange`
    ///     reads its depth map from the same dictionary (key `"depthRange"`, or
    ///     `"depth"`). A missing key ⇒ zero.
    public static func rasterize(component: MaskComponent,
                                 size: (width: Int, height: Int),
                                 source: ImageBuffer? = nil,
                                 strokes: BrushStrokeSet? = nil,
                                 aiMattes: [String: Plane] = [:]) -> Plane {
        let w = Swift.max(size.width, 1)
        let h = Swift.max(size.height, 1)
        if size.width < 1 || size.height < 1 { return Plane(width: w, height: h) }
        if component.validationError() != nil { return Plane(width: w, height: h) }

        switch component.kind {
        case .linear:
            return linearPlane(component, w, h)
        case .radial:
            return radialPlane(component, w, h)
        case .brush:
            return brushPlane(component, w, h, source, strokes)
        case .lumaRange:
            return lumaRangePlane(component, w, h, source)
        case .colorRange:
            return colorRangePlane(component, w, h, source)
        case .similarity, .similarityLine:
            return similarityPlane(component, w, h, source)
        case .depthRange:
            return depthRangePlane(component, w, h, aiMattes)
        case .aiSubject, .aiSky, .aiBackground, .aiObject, .aiPerson, .aiLandscape:
            return mattePlane(component.kind, w, h, aiMattes)
        }
    }

    /// Rasterize every component, fold the stack with `MaskAlgebra`'s semantics, then
    /// run the refinement chain in `MaskRefine` order:
    /// guided-filter refine (`feather`) → edge shift (`edge`) → Gaussian softness
    /// (`blur`) → levels remap (`levelsLo`/`levelsHi`/`levelsGamma`).
    ///
    /// `mask.amount` deliberately never touches the raster (MaskAlgebra.swift's header,
    /// resolved in the brief §5.8): it scales the adjustment deltas at apply time.
    /// `mask.enabled` is likewise the caller's business — the S11 evaluator skips
    /// disabled masks; this stays a pure raster function.
    ///
    /// - Parameter strokeSets: brush blobs keyed by the component's `strokesRef` string.
    public static func combine(mask: Mask,
                               size: (width: Int, height: Int),
                               source: ImageBuffer? = nil,
                               strokeSets: [String: BrushStrokeSet] = [:],
                               aiMattes: [String: Plane] = [:]) -> Plane {
        let w = Swift.max(size.width, 1)
        let h = Swift.max(size.height, 1)
        var acc = Plane(width: w, height: h)
        if size.width < 1 || size.height < 1 { return acc }

        // Accumulator seeds at 0, so a stack that opens with subtract/intersect stays
        // empty — same as LR, and the property maskalgebra.json pins.
        let n = w * h
        for c in mask.components {
            let set: BrushStrokeSet? = c.kind == .brush ? strokeSets[c.strokesRef ?? ""] : nil
            let raw = rasterize(component: c, size: (width: w, height: h),
                                source: source, strokes: set, aiMattes: aiMattes)
            if raw.width != w || raw.height != h { continue }
            for i in 0..<n {
                let v = MaskAlgebra.componentAlpha(raw: Double(raw.values[i]),
                                                   invert: c.invert, amount: c.amount)
                let a = Double(acc.values[i])
                switch c.op {
                case .add: acc.values[i] = Float(Swift.max(a, v))
                case .subtract: acc.values[i] = Float(Swift.min(a, 1 - v))
                case .intersect: acc.values[i] = Float(a * v)
                }
            }
        }

        return refined(acc, refine: mask.refine, source: source)
    }

    /// docs/08 §8.5: "radius ≈ Refine × 2% long edge". At 61 MP (9504 px long edge),
    /// Refine 10 → 19 px, Refine 100 → 190 px.
    public static func refineRadius(feather: Double, longEdge: Int) -> Int {
        guard feather.isFinite, longEdge > 0 else { return 0 }
        let f = Num.clamp(feather, 0, 100) / 100
        let r = (f * 0.02 * Double(longEdge)).rounded()
        guard r.isFinite, r >= 1 else { return 0 }
        return Int(Swift.min(r, 1e7))
    }

    /// The levels density remap: `t = clamp((α − lo)/(hi − lo), 0, 1)`, `α' = t^(1/γ)`,
    /// so γ > 1 raises density and γ = 1 is identity.
    ///
    /// `lo`/`hi` are the wire values (`MaskRefine.levelsLo`/`levelsHi`, 0…100). Values
    /// that are already normalized (both ≤ 1) are accepted as such, so `lo: 0, hi: 1`
    /// and `lo: 0, hi: 100` both mean "full range". `hi ≤ lo` collapses to a hard step
    /// rather than silently inverting — inversion belongs to the invert toggles.
    public static func levels(_ v: Double, lo: Double, hi: Double, gamma: Double) -> Double {
        guard v.isFinite else { return 0 }
        let loIn = lo.isFinite ? lo : 0
        let hiIn = hi.isFinite ? hi : 100
        let percent = loIn > 1 || hiIn > 1
        let lo01 = Num.saturate(percent ? loIn / 100 : loIn)
        let hi01 = Num.saturate(percent ? hiIn / 100 : hiIn)
        let span = Swift.max(hi01 - lo01, 1e-4)
        let t = Num.saturate((v - lo01) / span)
        let g = gamma.isFinite ? Num.clamp(gamma, 0.2, 5.0) : 1
        if g == 1 { return t }
        if t <= 0 { return 0 }
        return Num.saturate(pow(t, 1 / g))
    }

    // MARK: - Refinement chain (docs/08 §8.5)

    /// Fixed order, applied to the folded alpha. Whole-mask invert would sit ahead of
    /// this chain (brief §5.7) but `Mask` ships no invert field, so there is nothing
    /// to apply here.
    static func refined(_ alpha: Plane, refine: MaskRefine, source: ImageBuffer?) -> Plane {
        var a = alpha
        let longEdge = Swift.max(a.width, a.height)

        // 1. Guided-filter refine — edge-aware snap against the stage input's structure.
        let r = refineRadius(feather: refine.feather, longEdge: longEdge)
        if r >= 1, let src = source {
            let guide = guidePlane(source: src, width: a.width, height: a.height)
            a = SpatialOps.guidedFilter(input: a, guide: guide, radius: r, epsilon: guidedEpsilon)
            a = a.map { Num.saturate($0.isFinite ? $0 : 0) }
        }

        // 2. Edge shift — signed-distance dilate/erode, ±50 ≈ ±1% long edge.
        a = edgeShifted(a, edge: refine.edge, longEdge: longEdge)

        // 3. Gaussian feather — σ ≈ Feather × 1% long edge.
        if refine.blur.isFinite {
            let sigma = (Num.clamp(refine.blur, 0, 100) / 100) * 0.01 * Double(longEdge)
            if sigma > 0.05 {
                a = SpatialOps.gaussianBlur(a, sigma: sigma)
                a = a.map { Num.saturate($0.isFinite ? $0 : 0) }
            }
        }

        // 4. Levels density remap.
        return a.map {
            levels($0, lo: refine.levelsLo, hi: refine.levelsHi, gamma: refine.levelsGamma)
        }
    }

    /// Guide for the refine step: log-luminance of the stage input, percentile-normalized
    /// to [0,1]. Plain GF, not S7's exposure-independent variant — a mask already samples
    /// a fully corrected scene, and eigf's exposure invariance buys nothing here.
    static func guidePlane(source: ImageBuffer, width: Int, height: Int) -> Plane {
        var g = Plane(width: width, height: height)
        let weights = RGBColorSpace.rec2020.luminanceWeights
        for y in 0..<height {
            for x in 0..<width {
                let c = srcColor(source, x, y, width, height)
                let luminance = weights.r * c.r + weights.g * c.g + weights.b * c.b
                let ev = Num.safeLog2(luminance.isFinite ? luminance : 0, floorEV: -16)
                g[x, y] = ev
            }
        }
        // Robust 2nd/98th percentile normalization keeps the guide's contrast stable
        // across frames instead of chasing a single specular pixel.
        var sorted = g.values
        sorted.sort()
        guard let first = sorted.first, let last = sorted.last else { return g }
        let loIndex = Swift.min(sorted.count - 1, Swift.max(0, Int(Double(sorted.count) * 0.02)))
        let hiIndex = Swift.min(sorted.count - 1, Swift.max(0, Int(Double(sorted.count) * 0.98)))
        var lo = Double(sorted[loIndex])
        var hi = Double(sorted[hiIndex])
        if !(hi > lo) { lo = Double(first); hi = Double(last) }
        let span = Swift.max(hi - lo, 1e-6)
        return g.map { Num.saturate(($0 - lo) / span) }
    }

    /// Signed-distance dilate/erode. The α ≥ 0.5 set's exact Euclidean distance
    /// transform (Felzenszwalb–Huttenlocher, two separable O(n) passes) gives the
    /// signed distance φ; the boundary moves by `shift` and the measured ramp width
    /// is preserved. Level-set advection cannot do this — for a near-binary AI matte
    /// ‖∇α‖ saturates and a 20 px shift would move the edge by one pixel.
    static func edgeShifted(_ a: Plane, edge: Double, longEdge: Int) -> Plane {
        guard edge.isFinite else { return a }
        let e = Num.clamp(edge, -50, 50)
        let shift = (e / 50) * 0.01 * Double(longEdge)
        // Blend the reconstruction in over the first pixel of shift rather than
        // switching it on. On a 2560-px frame a shift of half a pixel is Edge ≈ 0.98,
        // so the old threshold made Edge 0 → 1 a visible jump: the reconstruction does
        // not shift the existing alpha, it rebuilds one from the signed distance and a
        // single global ramp width, which only reproduces a mask that was already a
        // uniform linear ramp. For a Gaussian-blurred edge the profile differs by
        // ~0.1 alpha across the transition band, and that arrived all at once.
        let engagement = Num.saturate(abs(shift))
        guard engagement > 0 else { return a }

        let w = a.width, h = a.height
        let n = w * h

        // Ramp width from the mean gradient over the transition band: a ramp of width
        // W px has |∇α| = 1/W, and a hard edge lands at ~1 px.
        var gradSum = 0.0
        var gradCount = 0
        for y in 0..<h {
            for x in 0..<w {
                let v = a[x, y]
                if v > 0.02 && v < 0.98 {
                    let gx = (a.clampedSample(x + 1, y) - a.clampedSample(x - 1, y)) * 0.5
                    let gy = (a.clampedSample(x, y + 1) - a.clampedSample(x, y - 1)) * 0.5
                    let m = (gx * gx + gy * gy).squareRoot()
                    if m.isFinite { gradSum += m; gradCount += 1 }
                }
            }
        }
        let meanGrad = gradCount > 0 ? gradSum / Double(gradCount) : 1.0
        let rampWidth = Num.clamp(meanGrad > 1e-6 ? 1.0 / meanGrad : 1.0, 1.0, Double(Swift.max(longEdge, 2)))

        // A finite sentinel, not infinity: the transform adds squared distances, and
        // inf − inf is NaN. 1e12 dominates any real squared distance while leaving
        // ulp ≪ 1 px, so the arithmetic stays exact.
        let big: Double = 1e12
        var fInside = [Double](repeating: 0, count: n)
        var fOutside = [Double](repeating: 0, count: n)
        var anyInside = false
        var anyOutside = false
        for i in 0..<n {
            let inside = Double(a.values[i]) >= 0.5
            fInside[i] = inside ? 0 : big
            fOutside[i] = inside ? big : 0
            if inside { anyInside = true } else { anyOutside = true }
        }
        // A wholly empty or wholly full mask has no boundary to move.
        if !anyInside || !anyOutside { return a }

        let dToInside = edt2D(fInside, w, h)
        let dToOutside = edt2D(fOutside, w, h)

        var out = a
        for i in 0..<n {
            let inside = Double(a.values[i]) >= 0.5
            let phi = inside
                ? -(dToOutside[i].squareRoot() - 0.5)
                : (dToInside[i].squareRoot() - 0.5)
            let rebuilt = Num.saturate(0.5 + (shift - phi) / rampWidth)
            out.values[i] = Float(Num.mix(Double(a.values[i]), rebuilt, engagement))
        }
        return out
    }

    // MARK: - Component rasterizers

    /// docs/08 §8.2: alpha = smoothstep along the gradient axis, two endpoints in
    /// source coordinates, zero raster storage. The span between the two lines IS the
    /// feather — there is no separate control. Mirror (§8.2) has no shipped field, so
    /// only the one-sided ramp is available.
    static func linearPlane(_ c: MaskComponent, _ w: Int, _ h: Int) -> Plane {
        var p = Plane(width: w, height: h)
        guard let line = c.line, line.count == 4 else { return p }
        // Work in long-edge units so the axis direction is isotropic (pixels are
        // square; normalized coordinates are not).
        let long = Double(Swift.max(w, h))
        let sx = Double(w) / long
        let sy = Double(h) / long
        let x0 = line[0] * sx, y0 = line[1] * sy
        let x1 = line[2] * sx, y1 = line[3] * sy
        let dx = x1 - x0, dy = y1 - y0
        let dd = dx * dx + dy * dy
        guard dd.isFinite, dd > 1e-12 else { return p }

        for y in 0..<h {
            let py = (Double(y) + 0.5) / long
            for x in 0..<w {
                let px = (Double(x) + 0.5) / long
                let t = Num.saturate(((px - x0) * dx + (py - y0) * dy) / dd)
                p[x, y] = smoothstep(0, 1, t)
            }
        }
        return p
    }

    /// docs/08 §8.2: signed distance to the ellipse through a smooth falloff, stored as
    /// center/axes/rotation. The falloff runs INWARD from the ellipse edge (LR's
    /// convention, which the Feather 50 default matches). Center and radii are
    /// source-normalized against width and height respectively, per docs/15's example.
    static func radialPlane(_ c: MaskComponent, _ w: Int, _ h: Int) -> Plane {
        var p = Plane(width: w, height: h)
        guard let center = c.center, center.count == 2,
              let radii = c.radii, radii.count == 2 else { return p }
        let cx = center[0], cy = center[1]
        let rx = abs(radii[0]), ry = abs(radii[1])
        guard cx.isFinite, cy.isFinite, rx > 1e-9, ry > 1e-9 else { return p }

        let theta = -(c.rotation ?? 0) * Double.pi / 180
        let ct = cos(theta), st = sin(theta)
        let f = Num.clamp(c.feather ?? 50, 0, 100) / 100
        // ≥1 px inner guard: at Feather 100 the core must not collapse to a point.
        let rxPx = Swift.max(rx * Double(w), 1e-6)
        let ryPx = Swift.max(ry * Double(h), 1e-6)
        let pixelGuard = Num.saturate(1.0 / Swift.max(Swift.min(rxPx, ryPx), 1))
        let rin = Num.clamp(Swift.max(1 - f, pixelGuard), 0, 1 - 1e-6)

        // Rotate in long-edge units, for the reason `linearPlane` gives above: pixels
        // are square and normalized coordinates are not, so a rotation matrix applied
        // to (fraction of width, fraction of height) mixes two different units. On a
        // 3:2 frame a 45° ellipse rendered at 33.7°, with the wrong eccentricity too.
        // Centre and radii are normalized per-axis by the wire format, so they convert
        // the same way — and at rotation 0 this is arithmetically identical to what it
        // replaces.
        let long = Double(Swift.max(w, h))
        let sx = Double(w) / long, sy = Double(h) / long
        let cxL = cx * sx, cyL = cy * sy
        let rxL = Swift.max(rx * sx, 1e-12), ryL = Swift.max(ry * sy, 1e-12)

        for y in 0..<h {
            let dv = (Double(y) + 0.5) / long - cyL
            for x in 0..<w {
                let du = (Double(x) + 0.5) / long - cxL
                let qx = du * ct - dv * st
                let qy = du * st + dv * ct
                let nx = qx / rxL, ny = qy / ryL
                let r = (nx * nx + ny * ny).squareRoot()
                if r <= rin {
                    p[x, y] = 1
                } else if r >= 1 {
                    p[x, y] = 0
                } else {
                    // `1 - smoothstep(rin, 1, r)`, NOT `smoothstep(1, rin, r)`.
                    // `Num.smoothstep` guards a degenerate edge pair with
                    // `if e1 <= e0 { return x < e0 ? 0 : 1 }`, and `rin` is always
                    // below 1 — so the reversed form took that branch on every call
                    // and returned 0 for the entire falloff. The mask was hard-edged:
                    // 1 inside `rin`, 0 outside it, and Feather did nothing but shrink
                    // the core. Both endpoints still meet the branches above exactly.
                    p[x, y] = 1 - smoothstep(rin, 1, r)
                }
            }
        }
        return p
    }

    /// docs/08 §8.2: Catmull-Rom centerline, stamped radial-falloff discs, per-pass
    /// accumulation that never exceeds Density. The stamp profile is the same closed
    /// form as the radial gradient — one shader serves both.
    static func brushPlane(_ c: MaskComponent, _ w: Int, _ h: Int,
                           _ source: ImageBuffer?, _ set: BrushStrokeSet?) -> Plane {
        var p = Plane(width: w, height: h)
        guard let set = set, !set.strokes.isEmpty else { return p }
        let long = Double(Swift.max(w, h))
        for stroke in set.strokes {
            paint(stroke: stroke, into: &p, width: w, height: h, longEdge: long, source: source)
        }
        return p
    }

    /// docs/08 §8.2: per-pixel trapezoid over the scene-referred log luminance of the
    /// stage input, so the handles are EV-denominated and the band is stable under
    /// display-transform changes. `lo`/`hi` are normalized on the fixed −10…+4 EV axis.
    static func lumaRangePlane(_ c: MaskComponent, _ w: Int, _ h: Int,
                               _ source: ImageBuffer?) -> Plane {
        var p = Plane(width: w, height: h)
        guard let src = source, let lo = c.lo, let hi = c.hi, lo.isFinite, hi.isFinite else { return p }
        let lo01 = Num.saturate(lo)
        let hi01 = Num.saturate(Swift.max(hi, lo))
        let s = Num.clamp(c.smooth ?? 50, 0, 100) / 100
        // Smoothness 50 → 1.0 EV shoulders. The floor keeps a hard step from becoming
        // a zero-width smoothstep.
        let shoulder = Swift.max(s * lumaShoulderEV / evSpan, 1e-4)
        let weights = RGBColorSpace.rec2020.luminanceWeights

        for y in 0..<h {
            for x in 0..<w {
                let rgb = srcColor(src, x, y, w, h)
                let luminance = weights.r * rgb.r + weights.g * rgb.g + weights.b * rgb.b
                let ev = Num.safeLog2(luminance.isFinite ? luminance : 0, floorEV: -16)
                let nEV = Num.saturate((ev - evMin) / (evMax - evMin))
                let rise = smoothstep(lo01 - shoulder, lo01, nEV)
                let fall = 1 - smoothstep(hi01, hi01 + shoulder, nEV)
                p[x, y] = Num.saturate(rise * fall)
            }
        }
        return p
    }

    /// docs/08 §8.2: similarity in OKLab hue/chroma/lightness with a trapezoid falloff
    /// per axis; multiple samples union before falloff. Per-axis tolerance fields are
    /// not on the shipped struct, so Refine (`rangeAmount`) always drives all three —
    /// the doc's "linked" mode.
    static func colorRangePlane(_ c: MaskComponent, _ w: Int, _ h: Int,
                                _ source: ImageBuffer?) -> Plane {
        var p = Plane(width: w, height: h)
        guard let src = source, let samples = c.samples, !samples.isEmpty else { return p }
        let context = OKLabTransform.working
        // §8.2 caps the picker at 8 samples; extras are ignored, not an error.
        var refs: [OKLCh] = []
        for s in samples.prefix(8) where s.count >= 3 {
            if s[0].isFinite && s[1].isFinite && s[2].isFinite {
                refs.append(context.toLCh(RGB(s[0], s[1], s[2])))
            }
        }
        if refs.isEmpty { return p }

        let refine = Num.clamp(c.rangeAmount ?? 50, 0, 100)
        let tolHue = 6.0 + 0.54 * refine        // 33° at Refine 50
        let tolChroma = 0.02 + 0.0016 * refine  // 0.10 at Refine 50
        let tolLuma = 0.03 + 0.0024 * refine    // 0.15 at Refine 50

        for y in 0..<h {
            for x in 0..<w {
                let lch = context.toLCh(srcColor(src, x, y, w, h))
                var best = 0.0
                for ref in refs {
                    let dh = abs(Num.hueDelta(ref.h, lch.h))
                    let dc = abs(lch.C - ref.C)
                    let dl = abs(lch.L - ref.L)
                    // Hue is meaningless as chroma → 0; fade the hue test out there
                    // rather than letting near-neutrals pick a random hue.
                    let chromaWeight = smoothstep(0.01, 0.04, Swift.min(lch.C, ref.C))
                    let hueTerm = Num.mix(1, trapezoid(dh, tolHue), chromaWeight)
                    let a = hueTerm * trapezoid(dc, tolChroma) * trapezoid(dl, tolLuma)
                    if a > best { best = a }
                }
                p[x, y] = Num.saturate(best)
            }
        }
        return p
    }

    /// docs/08 §8.2: alpha = spatial falloff × Gaussian similarity in OKLab chroma and
    /// lightness, widths set by the two selectivity sliders (log-scale so the slider is
    /// perceptually even).
    ///
    /// DEGRADED: `MaskComponent` stores sampled colours but no point geometry, radius,
    /// or ± sign for `.similarity` (brief §1.5 #8), and no detachable eyedropper
    /// position for `.similarityLine` (#9). So the spatial falloff term is omitted —
    /// `.similarity` evaluates the gate over the whole frame, `.similarityLine`
    /// multiplies it by its stored ramp, and all samples count as positive. Adding the
    /// geometry fields restores the spec's form without changing anything here but the
    /// falloff multiplier.
    static func similarityPlane(_ c: MaskComponent, _ w: Int, _ h: Int,
                                _ source: ImageBuffer?) -> Plane {
        var p = Plane(width: w, height: h)
        guard let src = source, let samples = c.samples, !samples.isEmpty else { return p }
        let context = OKLabTransform.working
        // Capped like `colorRangePlane`: the picker offers 8, but `samples` arrives
        // from a sidecar and the loop below is O(W·H·N) with two `exp` per sample. Ten
        // thousand samples against a 45 MP frame is not slow, it is a hang.
        var refs: [OKLab] = []
        for s in samples.prefix(8) where s.count >= 3 {
            if s[0].isFinite && s[1].isFinite && s[2].isFinite {
                refs.append(context.toLab(RGB(s[0], s[1], s[2])))
            }
        }
        if refs.isEmpty { return p }

        let chromaSel = Num.clamp(c.chromaSel ?? 50, 0, 100)
        let lumaSel = Num.clamp(c.lumaSel ?? 50, 0, 100)
        let sigmaC = Swift.max(sigmaChroma0 * pow(10, -selectivityDecades * chromaSel / 100), 1e-6)
        let sigmaL = Swift.max(sigmaLuma0 * pow(10, -selectivityDecades * lumaSel / 100), 1e-6)
        let twoSigmaC2 = 2 * sigmaC * sigmaC
        let twoSigmaL2 = 2 * sigmaL * sigmaL

        // The line ramp, when this is a Similarity Line; an all-ones plane otherwise,
        // so the inner loop has no branch and no optional to unwrap per pixel.
        let ramp: Plane = c.kind == .similarityLine
            ? linearPlane(c, w, h)
            : Plane(width: w, height: h, fill: 1)

        for y in 0..<h {
            for x in 0..<w {
                let lab = context.toLab(srcColor(src, x, y, w, h))
                var best = 0.0
                for ref in refs {
                    let da = lab.a - ref.a
                    let db = lab.b - ref.b
                    let dC2 = da * da + db * db
                    let dL = lab.L - ref.L
                    let g = exp(-dC2 / twoSigmaC2) * exp(-(dL * dL) / twoSigmaL2)
                    if g.isFinite && g > best { best = g }
                }
                p[x, y] = Num.saturate(best * ramp[x, y])
            }
        }
        return p
    }

    /// docs/08 §8.3: the same trapezoid machinery as the luminance band, over normalized
    /// relative/ordinal depth (near = 0). The depth map itself is a cached artifact and
    /// arrives through `aiMattes`. `depthSmooth` is not a shipped field, so the shared
    /// `smooth` key drives the shoulders (default 50).
    static func depthRangePlane(_ c: MaskComponent, _ w: Int, _ h: Int,
                                _ aiMattes: [String: Plane]) -> Plane {
        var p = Plane(width: w, height: h)
        let stored = aiMattes[MaskKind.depthRange.rawValue] ?? aiMattes["depth"]
        guard let depthMap = stored,
              let lo = c.depthLo, let hi = c.depthHi,
              lo.isFinite, hi.isFinite else { return p }
        let depth = fitted(depthMap, w, h)
        let lo01 = Num.saturate(lo)
        let hi01 = Num.saturate(Swift.max(hi, lo))
        let s = Num.clamp(c.smooth ?? 50, 0, 100) / 100
        let shoulder = Swift.max(s * depthShoulder, 1e-4)

        for y in 0..<h {
            for x in 0..<w {
                let d = Num.saturate(depth[x, y])
                let rise = smoothstep(lo01 - shoulder, lo01, d)
                let fall = 1 - smoothstep(hi01, hi01 + shoulder, d)
                p[x, y] = Num.saturate(rise * fall)
            }
        }
        return p
    }

    /// docs/08 §8.3/§8.5: AI components rasterize to a cached buffer at generation
    /// resolution (1024–2048 px); everything above that is the refine step's job. Here
    /// the caller supplies the matte and this only fits it to the target extent.
    static func mattePlane(_ kind: MaskKind, _ w: Int, _ h: Int,
                           _ aiMattes: [String: Plane]) -> Plane {
        guard let matte = aiMattes[kind.rawValue] else { return Plane(width: w, height: h) }
        return fitted(matte, w, h).map { Num.saturate($0.isFinite ? $0 : 0) }
    }

    // MARK: - Brush stamping

    private struct StampPoint {
        var x: Double        // pixel coordinates at the rasterization extent
        var y: Double
        var pressure: Double
    }

    /// One stroke into the accumulation buffer. Paint is asymptotic to Density and can
    /// never exceed it regardless of passes; erase is asymptotic to zero.
    static func paint(stroke: BrushStroke, into p: inout Plane,
                      width w: Int, height h: Int, longEdge long: Double,
                      source: ImageBuffer?) {
        guard stroke.size.isFinite, stroke.size > 0 else { return }
        let radiusPx = (stroke.size / 2) * long
        guard radiusPx.isFinite, radiusPx >= 0.5 else { return }

        let flow = Num.clamp(stroke.flow, 0, 100) / 100
        let density = Num.clamp(stroke.density, 0, 100) / 100
        guard flow > 0 else { return }
        if !stroke.erase && density <= 0 { return }

        // Hardness, with a ≥1 px antialiasing guard at Feather 0.
        let hardness = Num.saturate(1 - Num.clamp(stroke.feather, 0, 100) / 100)
        let hardnessUsed = Swift.min(hardness, Swift.max(0, 1 - 1 / Swift.max(radiusPx, 1)))

        let spacing = Swift.max(1, stampSpacingFraction * radiusPx)
        let centers = stampCenters(stroke.points, width: w, height: h, spacingPx: spacing)
        if centers.isEmpty { return }

        let context = OKLabTransform.working
        let useAutomask = stroke.automask && source != nil

        for centre in centers {
            guard centre.x.isFinite, centre.y.isFinite else { continue }
            // The automask reference is one sample per stamp, not per pixel (docs/08:
            // "per-stamp color-similarity gate against the stamp-center sample"),
            // taken from the denoised stage input rather than the raw signal.
            var reference: OKLab? = nil
            if useAutomask, let src = source {
                let u = centre.x / Double(w)
                let v = centre.y / Double(h)
                let rgb = src.bilinear(u * Double(src.width), v * Double(src.height))
                if rgb.isFinite { reference = context.toLab(rgb) }
            }

            // Clamp in Double before converting: an Int() conversion of an out-of-range
            // or non-finite Double traps, and a stroke point is user data.
            let minX = (centre.x - radiusPx).rounded(.down)
            let maxX = (centre.x + radiusPx).rounded(.up)
            let minY = (centre.y - radiusPx).rounded(.down)
            let maxY = (centre.y + radiusPx).rounded(.up)
            if maxX < 0 || maxY < 0 || minX > Double(w - 1) || minY > Double(h - 1) { continue }
            let x0 = Int(Num.clamp(minX, 0, Double(w - 1)))
            let x1 = Int(Num.clamp(maxX, 0, Double(w - 1)))
            let y0 = Int(Num.clamp(minY, 0, Double(h - 1)))
            let y1 = Int(Num.clamp(maxY, 0, Double(h - 1)))
            if x1 < x0 || y1 < y0 { continue }

            let flowPressure = flow * Num.saturate(centre.pressure)
            if flowPressure <= 0 { continue }

            for y in y0...y1 {
                let dy = Double(y) + 0.5 - centre.y
                for x in x0...x1 {
                    let dx = Double(x) + 0.5 - centre.x
                    let d = (dx * dx + dy * dy).squareRoot()
                    var s = stampProfile(d / radiusPx, hardness: hardnessUsed)
                    if s <= 0 { continue }

                    if let reference = reference, let src = source {
                        let lab = context.toLab(srcColor(src, x, y, w, h))
                        let dL = lab.L - reference.L
                        let da = lab.a - reference.a
                        let db = lab.b - reference.b
                        let deltaE = (dL * dL + da * da + db * db).squareRoot()
                        s *= 1 - smoothstep(automaskTau, 2 * automaskTau, deltaE)
                        if s <= 0 { continue }
                    }

                    let i = y * w + x
                    let a = Double(p.values[i])
                    let next: Double
                    if stroke.erase {
                        next = a * (1 - flowPressure * s)
                    } else {
                        next = a + flowPressure * s * Swift.max(density - a, 0)
                    }
                    p.values[i] = Float(Num.saturate(next))
                }
            }
        }
    }

    /// Stamp profile, shared with the radial gradient: flat core out to the hardness
    /// radius, smoothstep shoulder to the rim, zero beyond.
    static func stampProfile(_ rho: Double, hardness: Double) -> Double {
        guard rho.isFinite else { return 0 }
        if rho <= hardness { return 1 }
        if rho >= 1 { return 0 }
        // Same reversed-argument bug as `radialPlane`, and the same fix. This one made
        // every brush stamp a hard-edged disc, so a soft brush painted aliased edges
        // that the mask's own Feather control could not recover — it only moved the
        // hard edge inward. See the note there.
        return 1 - smoothstep(hardness, 1, rho)
    }

    /// Catmull-Rom (uniform, τ = 0.5) through the recorded points, resampled at
    /// arc-length spacing so stamp density is independent of input sampling rate.
    private static func stampCenters(_ points: [BrushPoint],
                                     width w: Int, height h: Int,
                                     spacingPx spacing: Double) -> [StampPoint] {
        var pts: [StampPoint] = []
        pts.reserveCapacity(points.count)
        for q in points where q.x.isFinite && q.y.isFinite {
            pts.append(StampPoint(x: q.x * Double(w),
                                  y: q.y * Double(h),
                                  pressure: q.pressure.isFinite ? Num.saturate(q.pressure) : 1))
        }
        if pts.isEmpty { return [] }
        if pts.count == 1 { return pts }

        // Dense spline samples first, arc-length walk second — two cheap passes beat
        // one Newton solve, and the result is deterministic.
        var dense: [StampPoint] = [pts[0]]
        dense.reserveCapacity(pts.count * 4)
        let step = Swift.max(spacing * 0.5, 0.5)
        for i in 0..<(pts.count - 1) {
            let p0 = pts[Swift.max(i - 1, 0)]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = pts[Swift.min(i + 2, pts.count - 1)]
            let chordX = p2.x - p1.x, chordY = p2.y - p1.y
            let chord = (chordX * chordX + chordY * chordY).squareRoot()
            var steps = 1
            if chord.isFinite && chord > 0 {
                // Clamp in Double first — Int() traps on an out-of-range conversion,
                // and the chord length comes from recorded coordinates.
                steps = Int(Num.clamp((chord / step).rounded(.up), 1, 64))
            }
            for j in 1...steps {
                let t = Double(j) / Double(steps)
                dense.append(StampPoint(x: catmullRom(p0.x, p1.x, p2.x, p3.x, t),
                                        y: catmullRom(p0.y, p1.y, p2.y, p3.y, t),
                                        pressure: Num.mix(p1.pressure, p2.pressure, t)))
            }
            if dense.count > maxDenseSamples { break }
        }

        var out: [StampPoint] = [dense[0]]
        var carried = 0.0
        for i in 1..<dense.count {
            let a = dense[i - 1]
            let b = dense[i]
            let dx = b.x - a.x, dy = b.y - a.y
            let segment = (dx * dx + dy * dy).squareRoot()
            if !segment.isFinite || segment <= 0 { continue }
            var walked = 0.0
            while carried + (segment - walked) >= spacing && out.count < maxStamps {
                walked += spacing - carried
                let t = Num.saturate(walked / segment)
                out.append(StampPoint(x: Num.mix(a.x, b.x, t),
                                      y: Num.mix(a.y, b.y, t),
                                      pressure: Num.mix(a.pressure, b.pressure, t)))
                carried = 0
            }
            carried += segment - walked
            if out.count >= maxStamps { break }
        }
        return out
    }

    private static func catmullRom(_ p0: Double, _ p1: Double, _ p2: Double,
                                   _ p3: Double, _ t: Double) -> Double {
        let t2 = t * t
        let t3 = t2 * t
        return 0.5 * ((2 * p1)
                      + (-p0 + p2) * t
                      + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
                      + (-p0 + 3 * p1 - 3 * p2 + p3) * t3)
    }

    // MARK: - Small helpers

    /// Smoothstep that also runs backwards (`e0 > e1`), which every inward falloff in
    /// this file needs. `Num.smoothstep` deliberately treats an inverted pair as a step.
    static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let d = e1 - e0
        if !d.isFinite || abs(d) < 1e-12 { return x < e0 ? 0 : 1 }
        let u = Num.saturate((x - e0) / d)
        return u * u * (3 - 2 * u)
    }

    /// Per-axis trapezoid: flat core, smoothstep shoulder, zero past the tolerance.
    static func trapezoid(_ delta: Double, _ tolerance: Double) -> Double {
        guard delta.isFinite else { return 0 }
        let tol = Swift.max(tolerance, 1e-9)
        let d = abs(delta)
        let core = (1 - trapezoidShoulder) * tol
        if d <= core { return 1 }
        if d >= tol { return 0 }
        return smoothstep(tol, core, d)
    }

    /// Sample the stage input at a mask pixel. Fast path when the extents already match;
    /// otherwise bilinear through source-normalized coordinates, which is the whole
    /// point of storing masks normalized.
    static func srcColor(_ src: ImageBuffer, _ x: Int, _ y: Int, _ w: Int, _ h: Int) -> RGB {
        if src.width == w && src.height == h { return src[x, y] }
        let u = (Double(x) + 0.5) / Double(w)
        let v = (Double(y) + 0.5) / Double(h)
        return src.bilinear(u * Double(src.width), v * Double(src.height))
    }

    static func fitted(_ plane: Plane, _ w: Int, _ h: Int) -> Plane {
        if plane.width == w && plane.height == h { return plane }
        return plane.resized(width: w, height: h)
    }

    // MARK: - Exact Euclidean distance transform (Felzenszwalb–Huttenlocher)

    /// Squared distance transform of a sampled function, two separable O(n) passes.
    static func edt2D(_ f: [Double], _ w: Int, _ h: Int) -> [Double] {
        var d = f
        if w <= 0 || h <= 0 || d.count != w * h { return d }

        var column = [Double](repeating: 0, count: h)
        for x in 0..<w {
            for y in 0..<h { column[y] = d[y * w + x] }
            let t = edt1D(column)
            for y in 0..<h { d[y * w + x] = t[y] }
        }
        var row = [Double](repeating: 0, count: w)
        for y in 0..<h {
            for x in 0..<w { row[x] = d[y * w + x] }
            let t = edt1D(row)
            for x in 0..<w { d[y * w + x] = t[x] }
        }
        return d
    }

    /// The 1-D lower envelope of parabolas rooted at each sample.
    static func edt1D(_ f: [Double]) -> [Double] {
        let n = f.count
        if n <= 1 { return f }
        var v = [Int](repeating: 0, count: n)
        var z = [Double](repeating: 0, count: n + 1)
        var k = 0
        v[0] = 0
        z[0] = -Double.infinity
        z[1] = Double.infinity

        for q in 1..<n {
            var s = parabolaIntersection(f, q, v[k])
            while k > 0 && s <= z[k] {
                k -= 1
                s = parabolaIntersection(f, q, v[k])
            }
            k += 1
            v[k] = q
            z[k] = s
            z[k + 1] = Double.infinity
        }

        var d = [Double](repeating: 0, count: n)
        k = 0
        for q in 0..<n {
            while k < n - 1 && z[k + 1] < Double(q) { k += 1 }
            let dq = Double(q - v[k])
            d[q] = dq * dq + f[v[k]]
        }
        return d
    }

    private static func parabolaIntersection(_ f: [Double], _ q: Int, _ vk: Int) -> Double {
        let den = Double(2 * q - 2 * vk)
        if den == 0 { return Double.infinity }
        let num = (f[q] + Double(q * q)) - (f[vk] + Double(vk * vk))
        let s = num / den
        return s.isFinite ? s : Double.infinity
    }
}
