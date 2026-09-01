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
    /// The fixed axis every channel-reading selection is denominated on. Internal
    /// rather than private because the luminosity series' tests assert the rasterizer
    /// against the closed form, and a test that had to re-derive these two numbers
    /// would be asserting its own arithmetic rather than the renderer's.
    static let evMin: Double = -10
    static let evMax: Double = 4
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
    ///   - brushPlane: an already-painted plane for THIS component's stroke set, when
    ///     the caller holds one (`accumulatedBrushPlane`). Used verbatim if it is the
    ///     right size; ignored otherwise, so a stale or mis-sized cache degrades to a
    ///     repaint rather than to a wrong mask.
    public static func rasterize(component: MaskComponent,
                                 size: (width: Int, height: Int),
                                 source: ImageBuffer? = nil,
                                 strokes: BrushStrokeSet? = nil,
                                 aiMattes: [String: Plane] = [:],
                                 brushPlane held: Plane? = nil) -> Plane {
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
            if let held, held.width == w, held.height == h { return held }
            return brushPlane(component, w, h, source, strokes)
        case .lumaRange:
            return lumaRangePlane(component, w, h, source)
        case .luminosity:
            return luminosityPlane(component, w, h, source)
        case .polygon:
            return polygonPlane(component, w, h)
        case .colorRange:
            return colorRangePlane(component, w, h, source)
        case .similarity, .similarityLine:
            return similarityPlane(component, w, h, source)
        case .depthRange:
            return depthRangePlane(component, w, h, aiMattes)
        case .aiSubject, .aiSky, .aiBackground, .aiObject, .aiPerson, .aiLandscape:
            return mattePlane(component.kind, w, h, aiMattes)
        case .maskRef:
            // Resolved by `combine`, which is the only function that holds the list of
            // masks a reference could name. Rasterizing ONE component cannot answer
            // "what does mask X select", so this returns empty rather than pretending.
            return Plane(width: w, height: h)
        }
    }

    /// Rasterize every component, fold the stack with `MaskAlgebra`'s semantics, apply
    /// the whole-mask invert, then run the refinement chain in `MaskRefine` order:
    /// guided-filter refine (`feather`) → edge shift (`edge`) → Gaussian softness
    /// (`blur`) → levels remap (`levelsLo`/`levelsHi`/`levelsGamma`).
    ///
    /// `mask.amount` deliberately never touches the raster (MaskAlgebra.swift's header,
    /// resolved in the brief §5.8): it scales the adjustment deltas at apply time.
    /// `mask.enabled` is likewise the caller's business — the S11 evaluator skips
    /// disabled masks; this stays a pure raster function.
    ///
    /// - Parameter strokeSets: brush blobs keyed by the component's `strokesRef` string.
    /// - Parameter brushPlanes: already-painted brush planes, keyed by the same
    ///   `strokesRef`. This is how an incremental painter reaches the fold: the caller
    ///   accumulates with `accumulatedBrushPlane` and hands the result in, so appending
    ///   a stroke costs one stroke instead of the whole set (docs/36 §1.2). A plane of
    ///   the wrong size is ignored, not trusted.
    /// - Parameter masks: every mask on this photograph, so a `maskRef` component can be
    ///   resolved. Defaults to empty, which makes a reference select nothing — the same
    ///   posture the rest of this file takes toward an input it was not given.
    /// - Parameter resolving: the ids currently being evaluated, so a reference cycle
    ///   terminates. Callers pass nothing; the recursion carries it.
    public static func combine(mask: Mask,
                               size: (width: Int, height: Int),
                               source: ImageBuffer? = nil,
                               strokeSets: [String: BrushStrokeSet] = [:],
                               aiMattes: [String: Plane] = [:],
                               brushPlanes: [String: Plane] = [:],
                               masks: [Mask] = [],
                               resolving: Set<String> = []) -> Plane {
        let w = Swift.max(size.width, 1)
        let h = Swift.max(size.height, 1)
        var acc = Plane(width: w, height: h)
        if size.width < 1 || size.height < 1 { return acc }

        // A MASK NOBODY HAS FINISHED MAKING SELECTS NOTHING, INVERT OR NOT.
        //
        // `invert` flips the folded alpha, so an empty stack inverted is the WHOLE
        // FRAME — which is right for a stack whose components deliberately select
        // nothing, and catastrophic for one that has not been drawn yet. The picker
        // stopped seeding geometry this round (a radial arriving as a circle was the
        // owner's complaint, and it also blocked the draw gesture), so there is now a
        // window of seconds between choosing a kind and drawing it. Ticking Invert in
        // that window used to hand a two-stop lift to the entire photograph.
        //
        // The distinction the fold needs is the same one the panel's badge already
        // makes: a component that reads INCOMPLETE is not a selection of nothing, it is
        // the absence of a selection, and there is nothing there to invert. A mask with
        // no components at all is the same statement — which is what the stack summary
        // has always said in words: "nothing selected yet".
        //
        // AND "FINISHED" MEANS ITS INPUT IS THERE, not merely that its fields parse.
        // `validationError()` is a check on the RECIPE — a brush passes it the moment it
        // has a `strokesRef` — and a reference is only a promise that bytes exist
        // somewhere. When the promise is unkept (a catalog restored without its blob
        // directory, a sidecar that dropped its payload, a matte not yet generated) the
        // component rasterizes to a zero plane, which reads as "selects nothing", which
        // an invert turns back into the whole photograph. That is the same catastrophe
        // the paragraph above is about, arriving through the one door it did not close:
        // structurally valid, semantically absent.
        //
        // So the question both guards ask is `isEvaluable`, which adds to
        // `validationError()` the one thing the recipe cannot know: whether the data
        // this rasterization needs was actually handed to it.
        let usable = mask.components.contains {
            MaskRaster.isEvaluable($0, strokeSets: strokeSets, aiMattes: aiMattes,
                                   brushPlanes: brushPlanes)
        }
        guard usable else { return acc }

        // Accumulator seeds at 0, so a stack that opens with subtract/intersect stays
        // empty — same as LR, and the property maskalgebra.json pins.
        let n = w * h
        for c in mask.components {
            // AND THE SAME RULE PER COMPONENT, which is the half that was missing.
            //
            // The guard above only fires when EVERY component is incomplete. The loop
            // then rasterized the unfinished ones anyway — `rasterize` hands back a zero
            // plane — and folded them in. For `.add` that is invisible, because max(a, 0)
            // is a; for `.subtract` it is also invisible, because min(a, 1) is a. For
            // `.intersect` it is `a × 0`, and THE WHOLE MASK GOES TO ZERO.
            //
            // Reachable in two clicks: a mask with a working Radial, add a component —
            // `makeComponent` seeds no geometry by design — and set its op to Intersect
            // with the segmented control that is always on screen. Every pixel the mask
            // selected disappears until the second component is drawn, and a recipe saved
            // in that state renders empty forever, in the loupe and in the delivered
            // file, with the panel flagging only the one component as INCOMPLETE.
            //
            // "The absence of a selection" is the argument the guard above already makes.
            // A component that cannot be evaluated has nothing to contribute to the fold
            // — not zero, nothing — and skipping it is what that sentence means applied
            // one level down.
            guard MaskRaster.isEvaluable(c, strokeSets: strokeSets, aiMattes: aiMattes,
                                         brushPlanes: brushPlanes) else { continue }
            let set: BrushStrokeSet? = c.kind == .brush ? strokeSets[c.strokesRef ?? ""] : nil
            let held: Plane? = c.kind == .brush ? brushPlanes[c.strokesRef ?? ""] : nil
            let raw: Plane
            if c.kind == .maskRef {
                raw = referenced(c, size: (width: w, height: h), source: source,
                                 strokeSets: strokeSets, aiMattes: aiMattes,
                                 brushPlanes: brushPlanes, masks: masks,
                                 resolving: resolving.union([mask.id]))
            } else {
                raw = rasterize(component: c, size: (width: w, height: h),
                                source: source, strokes: set, aiMattes: aiMattes,
                                brushPlane: held)
            }
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

        return refined(acc, refine: mask.refine, source: source, invert: mask.invert)
    }

    /// Whether this component can actually be rasterized into a selection.
    ///
    /// Two questions, and the second is the one that was missing. Does the recipe
    /// describe it fully (`validationError()`)? And is the DATA it reads present — a
    /// brush's stroke set or its held plane, an AI kind's matte?
    ///
    /// A component that fails either is not a selection of nothing; it is the absence of
    /// a selection, and there is nothing there to inflate, subtract or invert. The
    /// distinction matters exactly once and then it matters enormously: `invert` turns
    /// "selects nothing" into "selects everything", so a brush mask whose blob did not
    /// come back from a restore stops being a dodge on one shoulder and becomes a
    /// two-stop lift on the whole photograph — in the loupe, in the overlay, and in the
    /// thumbnails, which read the memory cache rather than the export path's guard.
    ///
    /// `.maskRef` is deliberately not consulted here: what it needs is another mask,
    /// which `referenced` resolves with its own cycle guard, and asking twice would
    /// mean two answers to keep in step.
    static func isEvaluable(_ c: MaskComponent,
                            strokeSets: [String: BrushStrokeSet],
                            aiMattes: [String: Plane],
                            brushPlanes: [String: Plane]) -> Bool {
        guard c.validationError() == nil else { return false }
        switch c.kind {
        case .brush:
            // Either source is enough: `brushPlanes` is the painted plane held across
            // frames, `strokeSets` the strokes themselves. A stroke set that exists but
            // is EMPTY is a real answer — a stroke that was undone back to nothing —
            // so presence is the test, not point count.
            guard let ref = c.strokesRef else { return false }
            return strokeSets[ref] != nil || brushPlanes[ref] != nil
        default:
            // Every kind whose selection comes from a model: no matte, no selection.
            guard c.kind.needsMatte else { return true }
            return aiMattes[c.kind.rawValue] != nil
        }
    }

    /// One `maskRef` component's alpha: the FINISHED alpha of the mask it names.
    ///
    /// Finished, not raw — the referenced mask's own fold, its whole-mask invert and its
    /// whole refinement chain — because "Sky ∩ Person" means the two selections a
    /// photographer can see, not two half-built ones. It is a live reference: soften the
    /// Sky mask's edge and every intersection with it softens too, which is the property
    /// Capture One's Combine Masks does not have, since that merges sources into one
    /// layer and forgets where they came from.
    ///
    /// What it does NOT take is the referenced mask's Amount, which scales that mask's
    /// ADJUSTMENTS and never its raster (`MaskAlgebra`'s header). A reference is about
    /// the selection; the strength of the other mask's edit is none of its business.
    ///
    /// Cycles terminate. `resolving` carries every id on the current chain, so a mask
    /// that names itself, or A → B → A, selects nothing rather than recursing — and
    /// "nothing" is the right answer because a cyclic definition has no fixed point to
    /// be right about. `referenceDepthLimit` is the belt to that brace: a chain longer
    /// than any photograph could justify stops rather than growing a stack.
    static func referenced(_ c: MaskComponent,
                           size: (width: Int, height: Int),
                           source: ImageBuffer?,
                           strokeSets: [String: BrushStrokeSet],
                           aiMattes: [String: Plane],
                           brushPlanes: [String: Plane],
                           masks: [Mask],
                           resolving: Set<String>) -> Plane {
        let empty = Plane(width: Swift.max(size.width, 1), height: Swift.max(size.height, 1))
        guard let id = c.maskRef, !id.isEmpty,
              !resolving.contains(id),
              resolving.count <= referenceDepthLimit,
              let target = masks.first(where: { $0.id == id })
        else { return empty }
        // A disabled mask still SELECTS. `enabled` says whether its adjustments reach
        // the picture, and a reference wants its selection — otherwise turning off the
        // Sky mask to look at something would silently empty every mask built on it.
        return combine(mask: target, size: size, source: source,
                       strokeSets: strokeSets, aiMattes: aiMattes,
                       brushPlanes: brushPlanes, masks: masks, resolving: resolving)
    }

    /// How long a chain of references may be. Eight is past any composition a
    /// photograph justifies and far short of a stack that matters.
    static let referenceDepthLimit = 8

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
    /// `lo`/`hi` are the wire values (`MaskRefine.levelsLo`/`levelsHi`), which the
    /// format defines as 0…100 and the panel ships as a 0…100 slider with step 1.
    /// `hi ≤ lo` collapses to a hard step rather than silently inverting — inversion
    /// belongs to the invert toggles.
    ///
    /// PERCENT ALWAYS. This used to sniff the units — `percent = lo > 1 || hi > 1` —
    /// as a convenience so that `hi: 1` and `hi: 100` both meant "full range". But 1 is
    /// a value the slider can actually take, and it means one percent, so dragging Hi
    /// down through it produced: at 2 the mask is fully opaque, at 1 it snaps back to
    /// un-remapped, at 0 fully opaque again. And `lo: 1, hi: 1` read as `lo01 = 1`,
    /// which emptied the mask completely. Taking the units from the contract instead of
    /// guessing them from the values removes the hole.
    public static func levels(_ v: Double, lo: Double, hi: Double, gamma: Double) -> Double {
        guard v.isFinite else { return 0 }
        let loIn = lo.isFinite ? lo : 0
        let hiIn = hi.isFinite ? hi : 100
        let lo01 = Num.saturate(loIn / 100)
        let hi01 = Num.saturate(hiIn / 100)
        let span = Swift.max(hi01 - lo01, 1e-4)
        let t = Num.saturate((v - lo01) / span)
        let g = gamma.isFinite ? Num.clamp(gamma, 0.2, 5.0) : 1
        if g == 1 { return t }
        if t <= 0 { return 0 }
        return Num.saturate(pow(t, 1 / g))
    }

    // MARK: - Refinement chain (docs/08 §8.5)

    /// Fixed order, applied to the folded alpha. Whole-mask invert (docs/08 §8.1,
    /// brief §5.7) sits AHEAD of this chain: the four refinements are shaping the
    /// selection the user can see, so inverting first is what makes Edge Shift grow
    /// the region that is now selected rather than the one that no longer is.
    static func refined(_ alpha: Plane, refine: MaskRefine, source: ImageBuffer?,
                        invert: Bool = false) -> Plane {
        var a = alpha
        let longEdge = Swift.max(a.width, a.height)

        // 0. Whole-mask invert, before the chain.
        if invert { a = a.map { 1 - Num.saturate($0.isFinite ? $0 : 0) } }

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
    /// Where a point on a rotated ellipse actually lands, in source-normalized
    /// coordinates — the on-image handles' half of `radialPlane`'s geometry.
    ///
    /// **This exists because the two drifted, and the drift shipped.** `radialPlane`
    /// used to rotate in per-axis normalized space; that was fixed to rotate in
    /// long-edge units, for the reason the comment below gives — pixels are square and
    /// normalized coordinates are not, so on a 3:2 frame a 45° ellipse rendered at 33.7°
    /// with the wrong eccentricity. `MaskCanvas` kept the old convention, and its own
    /// comment went on asserting "the rotation convention is the rasterizer's" for
    /// months after it had stopped being true.
    ///
    /// What that cost: on a 6000×4000 frame with a radial turned to 45°, the drawn rim,
    /// all four resize dots, the feather ring and the rotate stalk sat 0.07 of the frame
    /// height away from the mask that was actually rendering — about 283 source pixels,
    /// roughly 85 screen points, against an 11 pt grab radius. The outline did not match
    /// the effect, pressing the drawn rim could miss the real one and be read as "draw a
    /// new ellipse here", and resize dragged by the wrong amount.
    ///
    /// `offset` is in the wire format's own units: a displacement in per-axis normalized
    /// coordinates, so `(radii[0], 0)` is the major-axis end. The return is the same.
    /// At rotation 0, and on a square frame, this is the identity on `offset` — which is
    /// why the drift was invisible until someone turned an ellipse on a 3:2 photograph.
    public static func radialOffset(_ offset: (x: Double, y: Double),
                                    rotation: Double,
                                    width: Int, height: Int) -> (x: Double, y: Double) {
        let long = Double(Swift.max(width, height))
        guard long > 0 else { return offset }
        let sx = Double(width) / long, sy = Double(height) / long
        guard sx > 0, sy > 0 else { return offset }
        // Into long-edge units, where a rotation is a rotation.
        let ox = offset.x * sx, oy = offset.y * sy
        let a = rotation * Double.pi / 180
        let c = cos(a), s = sin(a)
        // `radialPlane` rotates a sample by −rotation to reach the ellipse's own frame,
        // so travelling the other way — from the ellipse's frame out to the picture —
        // is a rotation by +rotation. Inverting the wrong direction is the other way to
        // get this wrong, and it looks identical at 0° and at 180°.
        let rx = ox * c - oy * s
        let ry = ox * s + oy * c
        return (rx / sx, ry / sy)
    }

    /// The inverse of `radialOffset`: a source-normalized displacement from the centre,
    /// expressed in the ellipse's own frame. What a resize or feather drag needs.
    public static func radialLocal(_ delta: (x: Double, y: Double),
                                   rotation: Double,
                                   width: Int, height: Int) -> (x: Double, y: Double) {
        let long = Double(Swift.max(width, height))
        guard long > 0 else { return delta }
        let sx = Double(width) / long, sy = Double(height) / long
        guard sx > 0, sy > 0 else { return delta }
        let dx = delta.x * sx, dy = delta.y * sy
        let a = -rotation * Double.pi / 180
        let c = cos(a), s = sin(a)
        return ((dx * c - dy * s) / sx, (dx * s + dy * c) / sy)
    }

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
        guard let set = set else { return Plane(width: w, height: h) }
        return accumulatedBrushPlane(strokes: set, size: (width: w, height: h),
                                     source: source, resuming: nil)
    }

    /// A brush component's plane, optionally **resumed** from a previously computed one.
    ///
    /// This is the shape docs/08 §8.2 specifies and the shape the shipping path did not
    /// have: *"brush strokes render into the cached component buffer incrementally
    /// rather than re-folding the whole stack per stamp."* What stood here painted
    /// every stroke of the set on every rasterization, so a sixty-stroke mask paid
    /// sixty strokes on every settle, every export and every draft cache miss — and the
    /// sixty-first stroke made all sixty-one more expensive. The cost of painting grew
    /// with how much you had already painted, which is the worst possible shape for the
    /// one tool a photographer uses continuously (docs/36 §1.2).
    ///
    /// `resuming` is `(plane, strokes)`: a plane that already holds the first `strokes`
    /// strokes of this same set, at this same size, against this same stage input. When
    /// it is supplied and usable, only `strokes...` are painted. It is REFUSED — and the
    /// whole set repainted — whenever it cannot be shown to be a prefix of this one:
    ///
    ///   · a size mismatch (a different raster resolution is a different plane),
    ///   · a count past the end of the set (strokes were removed or undone),
    ///   · a count that is negative.
    ///
    /// Correctness rests on one property of the fold: strokes composite in draw order
    /// and each one reads only the accumulator, never the strokes before it. Paint
    /// deposits `a + flow·s·max(density − a, 0)` and an eraser multiplies toward zero;
    /// both are functions of the accumulator alone. So painting `[0..<k)` then `[k...]`
    /// is exactly painting `[0...]`, which is what
    /// `testResumingAStrokeSetIsTheSameAsPaintingItWhole` pins.
    ///
    /// The caller owns the cache and therefore owns the key. `PipelineRenderer` keys on
    /// the stroke reference, the raster size and the stage-input fingerprint — the last
    /// because Automask samples the picture, so the same strokes over a different
    /// exposure are a different plane.
    public static func accumulatedBrushPlane(strokes set: BrushStrokeSet,
                                             size: (width: Int, height: Int),
                                             source: ImageBuffer? = nil,
                                             resuming: (plane: Plane, strokes: Int)?
                                                 = nil) -> Plane {
        let w = Swift.max(size.width, 1)
        let h = Swift.max(size.height, 1)
        if size.width < 1 || size.height < 1 { return Plane(width: w, height: h) }

        var p: Plane
        var first: Int
        if let resuming, resuming.plane.width == w, resuming.plane.height == h,
           resuming.strokes >= 0, resuming.strokes <= set.strokes.count {
            p = resuming.plane
            first = resuming.strokes
        } else {
            p = Plane(width: w, height: h)
            first = 0
        }
        guard first < set.strokes.count else { return p }

        let long = Double(Swift.max(w, h))
        for index in first..<set.strokes.count {
            paint(stroke: set.strokes[index], into: &p,
                  width: w, height: h, longEdge: long, source: source)
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
        // Absent means luma, which is what every band written before the field means.
        let channel = c.channel ?? .luma

        for y in 0..<h {
            for x in 0..<w {
                let rgb = srcColor(src, x, y, w, h)
                let measured = channel.value(rgb, weights: weights)
                let ev = Num.safeLog2(measured.isFinite ? measured : 0, floorEV: -16)
                let nEV = Num.saturate((ev - evMin) / (evMax - evMin))
                let rise = smoothstep(lo01 - shoulder, lo01, nEV)
                let fall = 1 - smoothstep(hi01, hi01 + shoulder, nEV)
                p[x, y] = Num.saturate(rise * fall)
            }
        }
        return p
    }

    /// A closed outline, filled — the polygon and the lasso, which are one thing.
    ///
    /// ONE MECHANISM DOES BOTH JOBS. The value at a pixel is a smoothstep over the
    /// SIGNED DISTANCE to the outline, so the same arithmetic that feathers the edge
    /// also antialiases it: at Feather 0 the ramp is exactly one pixel wide, which is a
    /// clean edge rather than a staircase, and every higher setting simply widens it.
    /// A fill that computed coverage and then blurred would need two passes, would
    /// round the corners at Feather 0, and would put the boundary in a different place
    /// than the handles the photographer is dragging.
    ///
    /// Distances are in LONG-EDGE units, for the reason `linearPlane` states: pixels are
    /// square and normalized coordinates are not, so a feather measured in normalized
    /// space would be wider across a 3:2 frame than down it.
    ///
    /// Winding is EVEN-ODD. A lasso that crosses itself — which is most of them, drawn
    /// quickly — produces a hole under the nonzero rule and does not under even-odd, and
    /// a hole where the photographer's hand wobbled is never what they meant.
    static func polygonPlane(_ c: MaskComponent, _ w: Int, _ h: Int) -> Plane {
        var p = Plane(width: w, height: h)
        guard let raw = c.path, raw.count >= 3 else { return p }
        let long = Double(Swift.max(w, h))
        let sx = Double(w) / long, sy = Double(h) / long
        var xs = [Double](), ys = [Double]()
        xs.reserveCapacity(raw.count)
        ys.reserveCapacity(raw.count)
        for point in raw {
            guard point.count == 2, point[0].isFinite, point[1].isFinite else { return p }
            xs.append(point[0] * sx)
            ys.append(point[1] * sy)
        }
        let n = xs.count

        // Feather 0 is ONE PIXEL, not zero: a zero-width ramp is a staircase, and the
        // one place a mask must never look cheap is the edge the photographer drew by
        // hand. Above that it is a fraction of the long edge, matching the radial's
        // travel closely enough that the two controls feel like one control.
        let pixel = 1.0 / long
        let f = Num.clamp(c.feather ?? 0, 0, 100) / 100
        let band = Swift.max(f * polygonFeatherSpan, pixel)

        // The outline's own bounding box, grown by the feather: outside it the answer
        // is zero, and a lasso around one window in a 45 MP frame would otherwise pay
        // for a per-edge distance at every pixel in the photograph.
        let minX = (xs.min() ?? 0) - band, maxX = (xs.max() ?? 0) + band
        let minY = (ys.min() ?? 0) - band, maxY = (ys.max() ?? 0) + band

        for y in 0..<h {
            let py = (Double(y) + 0.5) / long
            if py < minY || py > maxY { continue }
            for x in 0..<w {
                let px = (Double(x) + 0.5) / long
                if px < minX || px > maxX { continue }
                let d = signedDistanceToOutline(px, py, xs, ys, n)
                // `d` is positive inside. The ramp is centred ON the outline, so the
                // boundary the photographer placed is the half-selected line rather
                // than the outer or inner limit of the falloff — which is what makes a
                // feathered shape stay the size it was drawn.
                p[x, y] = Num.saturate(smoothstep(-band / 2, band / 2, d))
            }
        }
        return p
    }

    /// Distance from a point to the outline, positive inside.
    ///
    /// The unsigned distance is the minimum over every edge, treated as a segment; the
    /// sign comes from an even-odd crossing count, computed in the same loop because
    /// both walk the same edge list and a second pass would double the cost of the
    /// hottest arithmetic in the rasterizer.
    static func signedDistanceToOutline(_ px: Double, _ py: Double,
                                        _ xs: [Double], _ ys: [Double],
                                        _ n: Int) -> Double {
        var best = Double.greatestFiniteMagnitude
        var inside = false
        var j = n - 1
        for i in 0..<n {
            let ax = xs[j], ay = ys[j], bx = xs[i], by = ys[i]
            let ex = bx - ax, ey = by - ay
            let wx = px - ax, wy = py - ay
            let ee = ex * ex + ey * ey
            let t = ee > 1e-24 ? Num.saturate((wx * ex + wy * ey) / ee) : 0
            let dx = wx - ex * t, dy = wy - ey * t
            best = Swift.min(best, dx * dx + dy * dy)
            // The standard crossing test, with the half-open rule on y so a vertex
            // exactly level with the scanline is counted once rather than twice.
            if (ay > py) != (by > py) {
                let cross = ax + (py - ay) / (by - ay) * ex
                if px < cross { inside.toggle() }
            }
            j = i
        }
        let distance = best.squareRoot()
        return inside ? distance : -distance
    }

    /// What Feather 100 means for an outline, as a fraction of the long edge. The
    /// radial's falloff at Feather 100 runs the whole way from centre to rim, which has
    /// no analogue on an arbitrary shape; 6% is close to what that looks like on a
    /// typical drawn region and is the widest a hand-drawn edge stays placeable at.
    static let polygonFeatherSpan: Double = 0.06

    /// Kuyper's luminosity series, evaluated as a continuous function of the channel.
    ///
    /// THE FAMILY, written out because this is where it is defined and nowhere else:
    ///
    ///     L         = the channel on the same fixed −10…+4 EV axis Brightness Range
    ///                 uses, saturated to 0…1
    ///     Lights n  = L^n
    ///     Darks n   = (1 − L)^n
    ///     Midtones n = 1 − L^(n+1) − (1 − L)^(n+1),  renormalized to peak at 1
    ///
    /// Every one of them is smooth in L with no boundary anywhere, at any level, which
    /// is the property the tradition calls SELF-FEATHERING and the reason the family is
    /// worth having rather than a band with soft shoulders. A band has a plateau and two
    /// edges; feathering it moves the edges. There is nothing here to move.
    ///
    /// TWO DELIBERATE DEPARTURES from the Photoshop original, both of which make it a
    /// better control rather than a different one:
    ///
    ///   `n` is CONTINUOUS. Photoshop's series is five pre-baked channels because
    ///   channel arithmetic can only intersect a mask with itself a whole number of
    ///   times. `pow` has no such limit, and a level of 2.4 is exactly as self-feathering
    ///   as a level of 2. So the "series generator" that Lumenzia exists to be is one
    ///   slider here, and the mask list stays the length the photographer made it.
    ///
    ///   Midtones are RENORMALIZED. The raw formula peaks at `1 − 2^-n` — 0.5 at level
    ///   1 — so a Photoshop midtone mask at full opacity performs half an edit, and
    ///   everyone who uses them knows to compensate. Lumen already has one control that
    ///   means "less of this", and it is called Amount. A second, invisible, level-
    ///   dependent one hiding inside the selection would make Amount a lie. The shape is
    ///   unchanged; only the scale is, and `testMidtonesPeakAtOneSoAmountMeansWhatItSays`
    ///   is the reason it may not drift back.
    static func luminosityPlane(_ c: MaskComponent, _ w: Int, _ h: Int,
                                _ source: ImageBuffer?) -> Plane {
        var p = Plane(width: w, height: h)
        guard let src = source else { return p }
        let series = c.series ?? .lights
        let raw = c.level ?? 1
        let n = raw.isFinite
            ? Num.clamp(raw, luminosityMinLevel, luminosityMaxLevel)
            : luminosityMinLevel
        let weights = RGBColorSpace.rec2020.luminanceWeights
        let channel = c.channel ?? .luma
        // Level 1 midtones peak at 0.5; level 5 at 0.969. Computed once rather than per
        // pixel, and guarded because `n` can be small enough that the peak is tiny.
        let midtonePeak = Swift.max(1 - pow(2, -n), 1e-6)

        for y in 0..<h {
            for x in 0..<w {
                let rgb = srcColor(src, x, y, w, h)
                let measured = channel.value(rgb, weights: weights)
                let ev = Num.safeLog2(measured.isFinite ? measured : 0, floorEV: -16)
                let l = Num.saturate((ev - evMin) / (evMax - evMin))
                p[x, y] = Num.saturate(luminosityValue(l, series: series, level: n,
                                                       midtonePeak: midtonePeak))
            }
        }
        return p
    }

    /// The family's arithmetic, on one already-normalized luminance. Separated from the
    /// loop above so a test can state the curve directly rather than through a fixture
    /// picture, and so the panel's own preview curve cannot drift from what renders.
    public static func luminosityValue(_ l: Double, series: LuminositySeries,
                                       level: Double, midtonePeak: Double? = nil)
        -> Double {
        // `Num.clamp` compares, and every comparison against NaN is false, so a
        // poisoned level would pass straight through into `pow` and poison the plane.
        // Level 1 is the plain channel — the honest answer to "this number is not a
        // number" is the one that still selects something sensible.
        let n = level.isFinite
            ? Num.clamp(level, luminosityMinLevel, luminosityMaxLevel)
            : luminosityMinLevel
        let x = l.isFinite ? Num.saturate(l) : 0
        switch series {
        case .lights:
            return pow(x, n)
        case .darks:
            return pow(1 - x, n)
        case .midtones:
            let peak = midtonePeak ?? Swift.max(1 - pow(2, -n), 1e-6)
            let raw = 1 - pow(x, n + 1) - pow(1 - x, n + 1)
            return Num.saturate(raw / peak)
        }
    }

    /// Level 1 is the plain channel; below it the family stops being a series. Five is
    /// where Photoshop's stops and where `L^n` has narrowed to the top ~1.5 EV, past
    /// which the selection is too small to place by eye.
    public static let luminosityMinLevel: Double = 1
    public static let luminosityMaxLevel: Double = 5

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
    /// THE SPATIAL HALF, which used to be missing. `MaskComponent.points` pairs one
    /// `[x, y, radius, sign]` with each sample by index, so a Colour Pick is "pixels
    /// like this one, NEAR HERE" — the U-Point mechanic it is named after — rather than
    /// "pixels like this one, anywhere", which is a colour range wearing another tool's
    /// name (docs/35 §2.4).
    ///
    /// With no points the gate evaluates over the whole frame, exactly as before, so
    /// every recipe written before the field renders identically after it.
    ///
    /// With points, positive ones union and negative ones subtract:
    ///
    ///     alpha = saturate( max(positive: spatial·g) − max(negative: spatial·g) )
    ///
    /// A negative point at 40 removes 40% of what it covers rather than all of it,
    /// because `spatial` is a falloff and not a mask — which is what makes a negative
    /// point a *dodge* of the selection rather than a hole in it.
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

        // The points, paired with `refs` by index. Parsed once, out of the loop, and
        // measured in the same units the brush uses so a point keeps its reach through
        // a crop: radius is a fraction of the LONG edge.
        let long = Double(Swift.max(w, h))
        let spatial = points(c, refs.count, w: w, h: h, longEdge: long)

        for y in 0..<h {
            let py = Double(y) + 0.5
            for x in 0..<w {
                let lab = context.toLab(srcColor(src, x, y, w, h))
                let px = Double(x) + 0.5
                var positive = 0.0
                var negative = 0.0
                for (index, ref) in refs.enumerated() {
                    let da = lab.a - ref.a
                    let db = lab.b - ref.b
                    let dC2 = da * da + db * db
                    let dL = lab.L - ref.L
                    var g = exp(-dC2 / twoSigmaC2) * exp(-(dL * dL) / twoSigmaL2)
                    guard g.isFinite else { continue }
                    guard let spatial else {
                        // No geometry at all: the gate covers the whole frame, which is
                        // what this component meant before points existed.
                        if g > positive { positive = g }
                        continue
                    }
                    // A malformed entry selects nothing rather than everything — an
                    // unparseable point must not silently become a global gate.
                    guard let point = spatial[index] else { continue }
                    let dx = px - point.cx
                    let dy = py - point.cy
                    let d = (dx * dx + dy * dy).squareRoot()
                    g *= stampProfile(d / point.radius, hardness: similarityPointCore)
                    if g <= 0 { continue }
                    if point.negative {
                        if g > negative { negative = g }
                    } else if g > positive {
                        positive = g
                    }
                }
                p[x, y] = Num.saturate((positive - negative) * ramp[x, y])
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

    /// A similarity point's parsed geometry, in PIXELS at the requested extent.
    struct SimilarityPoint {
        var cx: Double
        var cy: Double
        var radius: Double
        var negative: Bool
    }

    /// Fraction of a similarity point's radius that deposits at full strength before
    /// the shoulder starts. 0.35 is a soft point — closer to DxO's control point, whose
    /// influence is felt well before its drawn circle — and it is the one number here
    /// that is taste rather than derivation, so it is named.
    static let similarityPointCore: Double = 0.35

    /// The points of a similarity component, aligned with its samples by index.
    ///
    /// Returns nil when the component carries no points at all, which is the signal to
    /// the caller that the gate is global — distinct from an array of nils, which means
    /// "there are points, and this one is malformed".
    static func points(_ c: MaskComponent, _ count: Int, w: Int, h: Int,
                       longEdge long: Double) -> [SimilarityPoint?]? {
        guard let raw = c.points, !raw.isEmpty else { return nil }
        var out: [SimilarityPoint?] = Array(repeating: nil, count: count)
        for (index, entry) in raw.prefix(count).enumerated() {
            guard entry.count >= 3,
                  entry[0].isFinite, entry[1].isFinite, entry[2].isFinite else { continue }
            let radius = entry[2] * long
            guard radius >= 0.5 else { continue }
            let sign = entry.count >= 4 && entry[3].isFinite ? entry[3] : 1
            out[index] = SimilarityPoint(cx: entry[0] * Double(w),
                                         cy: entry[1] * Double(h),
                                         radius: radius,
                                         negative: sign < 0)
        }
        return out
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

// MARK: - Overlays

/// How a mask is DRAWN over the picture (docs/08 §8.6): six modes and four overlay
/// colours, with LR's keyboard grammar — `O` shows it, `⇧O` cycles the colour, `⌥O`
/// cycles the mode.
///
/// The compositing rule lives here, in the engine, for the same reason
/// `ClippingOverlay`'s does: it is a statement about what the user is being shown, it
/// has to be identical wherever it is drawn, and a rule that lives in a SwiftUI view
/// cannot be tested. The view's whole job is to run `composite` over the sampled
/// picture and the mask's alpha.
public enum MaskOverlay {

    /// How big to composite the overlay layer, given the alpha it will be built from.
    ///
    /// The overlay is drawn by resampling a mask alpha over the picture, one output
    /// pixel at a time in Swift, so this number squared is the cost of every frame the
    /// photographer sees while dragging a gradient around. Two bounds decide it and
    /// both are ceilings, never floors:
    ///
    ///   · `cap` is the pane bound. Above it the extra pixels are thrown away by the
    ///     downscale on the way to the screen.
    ///   · The ALPHA's own size is the information bound, and it is the one that makes
    ///     dragging feel live. `AppState.refreshMaskOverlay` rasterizes a half-size
    ///     alpha while a gesture is running; compositing that into a full-size layer
    ///     spends four times the pixels to interpolate detail the input does not have.
    ///
    /// Twice the alpha rather than exactly it, because five of the six modes read the
    /// PICTURE too and the picture is sharp at any size — so the layer stays a little
    /// ahead of the mask it carries, and the mask edge is the only thing that softens.
    ///
    /// The 512 floor keeps a degenerate alpha — a 96-px thumbnail plane arriving here
    /// by accident, or an 8-px raster from a collapsed crop — from compositing the
    /// overlay at a size that reads as broken rather than as soft.
    ///
    /// Pure arithmetic, in Core rather than in the view, so the rule can be tested on
    /// the platform CI runs tests on. It decides how the app performs during the one
    /// interaction masking is judged by; a rule that lived only in a macOS-gated view
    /// could only ever be checked by looking at it.
    public static func compositeLongEdge(alphaLongEdge: Int, cap: Int) -> Int {
        let wanted = Swift.max(512, alphaLongEdge * 2)
        return Swift.max(1, Swift.min(cap, wanted))
    }

    /// The six modes, in the order `⌥O` cycles them — LR's order, because fifteen
    /// years of tutorials describe it.
    public enum Mode: String, Codable, Sendable, CaseIterable {
        case colorOverlay
        case colorOnBW
        case imageOnBW
        case imageOnBlack
        case imageOnWhite
        case matte

        public var label: String {
            switch self {
            case .colorOverlay: return "Colour Overlay"
            case .colorOnBW: return "Colour on B&W"
            case .imageOnBW: return "Image on B&W"
            case .imageOnBlack: return "Image on Black"
            case .imageOnWhite: return "Image on White"
            case .matte: return "Matte"
            }
        }

        /// True when the mode needs the picture underneath. `matte` does not — it is
        /// the ground-truth view, and it must look the same over any photograph.
        public var readsPicture: Bool { self != .matte }

        public var next: Mode {
            let all = Mode.allCases
            guard let i = all.firstIndex(of: self) else { return .colorOverlay }
            return all[(i + 1) % all.count]
        }
    }

    /// The four overlay colours `⇧O` cycles, in LR's order.
    public enum Tint: String, Codable, Sendable, CaseIterable {
        case red, green, white, black

        public var label: String { rawValue.capitalized }

        /// Display-referred, because that is the domain the overlay is drawn in.
        public var colour: RGB {
            switch self {
            case .red: return RGB(0.90, 0.16, 0.16)
            case .green: return RGB(0.16, 0.85, 0.30)
            case .white: return RGB.one
            case .black: return RGB.zero
            }
        }

        public var next: Tint {
            let all = Tint.allCases
            guard let i = all.firstIndex(of: self) else { return .red }
            return all[(i + 1) % all.count]
        }
    }

    /// Default strength of the tinted modes (docs/08 §8.6 shows a translucent wash).
    public static let defaultStrength: Double = 0.45

    /// One overlay pixel, fully opaque, ready to draw over the image.
    ///
    /// - Parameters:
    ///   - picture: the displayed pixel, sRGB-encoded 0…1 — the same numbers the
    ///     viewer is showing, so what the overlay draws is what the eye compares
    ///     against.
    ///   - alpha: the mask's refined alpha at that pixel.
    ///   - strength: how far the two tinted modes push toward the overlay colour.
    ///     Only they use it; the other four are unambiguous by construction and a
    ///     half-strength Matte would be a lie about the mask's density.
    public static func composite(picture: RGB, alpha: Double, mode: Mode, tint: Tint,
                                 strength: Double = defaultStrength) -> RGB {
        let a = Num.saturate(alpha.isFinite ? alpha : 0)
        let s = Num.saturate(strength.isFinite ? strength : defaultStrength)
        let c = picture.isFinite ? picture : RGB.zero
        // Rec.709 luma on the ENCODED picture: this is a desaturation for the eye, not
        // a colour-science operation, and the encoded axis is where the viewer is.
        let grey = RGB(gray: Num.saturate(0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b))
        switch mode {
        case .colorOverlay: return c.mix(tint.colour, a * s)
        case .colorOnBW: return grey.mix(tint.colour, a * s)
        case .imageOnBW: return grey.mix(c, a)
        case .imageOnBlack: return RGB.zero.mix(c, a)
        case .imageOnWhite: return RGB.one.mix(c, a)
        case .matte: return RGB(gray: a)
        }
    }
}
