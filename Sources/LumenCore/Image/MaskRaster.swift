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
    /// Guided-filter regularization on the [0,1]-normalized guide. Not user-exposed —
    /// docs/08's explicit criticism of darktable is that it exposes this raw.
    private static let guidedEpsilon: Double = 1e-4
    /// Similarity Gaussian widths at selectivity 0, and the log-scale decade span.
    private static let sigmaChroma0: Double = 0.30
    private static let sigmaLuma0: Double = 0.50
    private static let selectivityDecades: Double = 1.2

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
    /// THE ONE RESOLVER. The loupe, the export, the overlay and the CPU reference all
    /// reach a mask's alpha through this function — `ReferenceRenderer` calls it, and
    /// `PipelineRenderer` calls it for every mask `MaskGPU` declines — so a reference
    /// cannot mean one thing on screen and another in the delivered file. `alpha` below
    /// is its body; this signature is what the callers hold.
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
        // "Nothing to lend" reaches a caller as an empty selection, which is what this
        // function has always returned and what every caller but `referenced` wants.
        alpha(mask: mask, size: size, source: source, strokeSets: strokeSets,
              aiMattes: aiMattes, brushPlanes: brushPlanes, masks: masks,
              resolving: resolving)
            ?? Plane(width: Swift.max(size.width, 1), height: Swift.max(size.height, 1))
    }

    /// `combine`'s answer, carrying the ONE distinction a reference has to be able to
    /// make: nil is "this mask has no selection to lend", a plane is "this is what it
    /// selects, and it may legitimately be nothing anywhere".
    ///
    /// Nobody outside this file needs that distinction — `combine` flattens it to an
    /// empty plane — but `referenced` does, because it is the whole difference between a
    /// dependency that is ABSENT and one that selects nothing, and the two fold into a
    /// stack differently.
    static func alpha(mask: Mask,
                      size: (width: Int, height: Int),
                      source: ImageBuffer?,
                      strokeSets: [String: BrushStrokeSet],
                      aiMattes: [String: Plane],
                      brushPlanes: [String: Plane],
                      masks: [Mask],
                      resolving: Set<String>) -> Plane? {
        if size.width < 1 || size.height < 1 { return nil }
        // THE FOLD RUNS ON THE SHARED FINE GRID (Astra M04 / S-10). A brush stamp
        // sampled at pixel centres is only the stroke the photographer drew while its
        // radius spans a few pixels; below that, the fit view and the export disagree
        // about what a thin stroke selects — and an Intersect or Subtract of two such
        // strokes, folded pixel by pixel on the coarse grid, disagrees further, because
        // max/min/× of two area averages is not the area average of max/min/×. So the
        // whole stack is rasterized and folded at `supersample`× the requested size
        // and box-reduced once, before the refinement chain. `supersample` is 1 — and
        // this function is exactly what it was — for every mask with no brush stroke
        // under `brushFineRadiusPx`.
        let factor = brushSupersample(mask: mask, strokeSets: strokeSets,
                                      size: (width: size.width, height: size.height))
        let w = size.width * factor
        let h = size.height * factor
        var acc = Plane(width: w, height: h)

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
        // So the question every guard here asks is whether the component CONTRIBUTED —
        // `isEvaluable` for the kinds that read an input, and `referenced` returning a
        // plane rather than nil for the one kind that reads another mask. The flag is
        // read after the fold rather than before it, because the reference's answer is
        // not knowable until it has been resolved, and resolving it twice would mean two
        // answers to keep in step.
        let n = w * h
        var contributed = false

        // Accumulator seeds at 0, so a stack that opens with subtract/intersect stays
        // empty — same as LR, and the property maskalgebra.json pins.
        for c in mask.components {
            // AND THE SAME RULE PER COMPONENT, which is the half that was missing.
            //
            // A whole-mask guard only fires when EVERY component is incomplete. The loop
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
            //
            // AND THE SAME RULE THROUGH A REFERENCE (audit F5-01's neighbour). This is
            // the door the two paragraphs above left open, because `isEvaluable` cannot
            // answer for `.maskRef` — what it needs is another mask, and only `referenced`
            // holds the list. So a reference to a mask that has been DELETED, or one that
            // closes a cycle, or one whose target has no evaluable component of its own,
            // used to arrive here as a zero plane and fold in as a selection of nothing:
            // under `.intersect` it emptied the mask that pointed at it, and under a
            // whole-mask `invert` it lifted the entire photograph. `referenced` now says
            // ABSENT with nil, and absent is skipped like any other unfinished component:
            // deleting the Sky mask leaves "Sky ∩ Person" selecting the Person, which is
            // the only reading under which a delete is not also a silent edit to every
            // mask that ever named it.
            let raw: Plane
            if c.kind == .maskRef {
                guard let lent = referenced(c, size: (width: w, height: h), source: source,
                                            strokeSets: strokeSets, aiMattes: aiMattes,
                                            brushPlanes: brushPlanes, masks: masks,
                                            resolving: resolving.union([mask.id]))
                else { continue }
                raw = lent
            } else {
                guard MaskRaster.isEvaluable(c, strokeSets: strokeSets, aiMattes: aiMattes,
                                             brushPlanes: brushPlanes) else { continue }
                let set: BrushStrokeSet? = c.kind == .brush ? strokeSets[c.strokesRef ?? ""] : nil
                let held: Plane? = c.kind == .brush ? brushPlanes[c.strokesRef ?? ""] : nil
                raw = rasterize(component: c, size: (width: w, height: h),
                                source: source, strokes: set, aiMattes: aiMattes,
                                brushPlane: held)
            }
            // A plane of the wrong size is not a contribution either — it is an input
            // this fold cannot read, which is the absent case again rather than a zero.
            if raw.width != w || raw.height != h { continue }
            contributed = true
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

        guard contributed else { return nil }
        if factor > 1 { acc = boxReduced(acc, by: factor) }
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
    /// `.maskRef` is not asked here, and the reason is not that a reference cannot be
    /// absent — it can, and that was the hole this function's own argument left open.
    /// It is that the answer is only knowable by evaluating another mask, which needs
    /// the list and the cycle guard. `referenced` asks it, once, and returns nil for
    /// exactly what `false` means here.
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
    /// NIL IS "ABSENT", NEVER "SELECTS NOTHING". Four ways a reference has nothing to
    /// lend, and each of them used to arrive at the fold as a zero plane:
    ///
    ///   · the component names no mask at all (`validationError` already says so);
    ///   · it names a mask that is NOT IN THE RECIPE — deleted, or arriving from another
    ///     photograph through Paste Settings, which copies ids verbatim;
    ///   · it closes a CYCLE, which `resolving` catches: `resolving` carries every id on
    ///     the current chain, so a mask that names itself, or A → B → A, stops rather
    ///     than recursing, because a cyclic definition has no fixed point to be right
    ///     about. `referenceDepthLimit` is the belt to that brace — a chain longer than
    ///     any photograph could justify stops rather than growing a stack;
    ///   · the target resolves to nothing itself, which is `alpha` returning nil one
    ///     level down: a Subject mask whose matte was never generated has no selection
    ///     to lend, and saying it selects nothing would be a claim about the picture
    ///     that nothing measured.
    ///
    /// A zero plane is a CLAIM — this mask selects no pixel — and under `.intersect` it
    /// empties whatever pointed at it, while under a whole-mask `invert` it selects the
    /// entire photograph. Neither is an answer a deleted mask is entitled to give.
    static func referenced(_ c: MaskComponent,
                           size: (width: Int, height: Int),
                           source: ImageBuffer?,
                           strokeSets: [String: BrushStrokeSet],
                           aiMattes: [String: Plane],
                           brushPlanes: [String: Plane],
                           masks: [Mask],
                           resolving: Set<String>) -> Plane? {
        guard let id = c.maskRef, !id.isEmpty,
              !resolving.contains(id),
              resolving.count <= referenceDepthLimit,
              let target = masks.first(where: { $0.id == id })
        else { return nil }
        // A disabled mask still SELECTS. `enabled` says whether its adjustments reach
        // the picture, and a reference wants its selection — otherwise turning off the
        // Sky mask to look at something would silently empty every mask built on it.
        //
        // Which is a promise about this function, and `MaskDependency.contributing` is
        // what makes it keepable: the disabled mask's INPUTS — its Vision matte, its
        // brush blob — have to be fetched too, and every roster that decides what to
        // fetch used to stop at `where mask.enabled` (audit F5-01).
        return alpha(mask: target, size: size, source: source,
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

        // 1. Guided-filter refine — edge-aware snap against the stage input's structure,
        // in colour: brightness and OKLab chroma together (`colourGuidedFilter`).
        let r = refineRadius(feather: refine.feather, longEdge: longEdge)
        if r >= 1, let src = source {
            let guide = colourGuide(source: src, width: a.width, height: a.height)
            a = colourGuidedFilter(a, guide: guide, radius: r, epsilon: guidedEpsilon)
            a = a.map { Num.saturate($0.isFinite ? $0 : 0) }
        }

        // 2. Edge shift — flat dilate/erode by a disc, ±50 ≈ ±1% long edge.
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
        //
        // Two order statistics and the extremes are all this reads, so it selects them
        // rather than sorting the plane: O(n) against O(n log n), on a plane that is
        // 11 M px at a settle and 33 M at export, every refined bake. The k-th smallest
        // of a multiset is one value however it is found, and every g here is finite
        // (safeLog2 floors at −16, never NaN, never −0), so lo/hi are bit-identical to
        // what `sorted[loIndex]` / `sorted[hiIndex]` gave.
        let n = g.values.count
        guard n > 0 else { return g }
        var first = g.values[0], last = g.values[0]
        for v in g.values {
            if v < first { first = v }
            if v > last { last = v }
        }
        let loIndex = Swift.min(n - 1, Swift.max(0, Int(Double(n) * 0.02)))
        let hiIndex = Swift.min(n - 1, Swift.max(0, Int(Double(n) * 0.98)))
        var scratch = g.values
        let loValue = kthSmallest(&scratch, loIndex, in: 0..<n)
        // The first select leaves everything above loIndex ≥ loValue, so the hi
        // statistic lives in that tail and the second select need not revisit the rest.
        let hiValue = hiIndex == loIndex
            ? loValue : kthSmallest(&scratch, hiIndex, in: (loIndex + 1)..<n)
        var lo = Double(loValue)
        var hi = Double(hiValue)
        if !(hi > lo) { lo = Double(first); hi = Double(last) }
        let span = Swift.max(hi - lo, 1e-6)
        return g.map { Num.saturate(($0 - lo) / span) }
    }

    /// How much the two OKLab chroma axes weigh in the refine guide against the
    /// normalized log-luminance. OKLab a/b span about ±0.3 on real colours, so ×2 puts a
    /// saturated hue change on the same footing as a full-range brightness edge. [D]
    static let chromaGuideScale: Double = 2

    /// Follow's guide: `guidePlane`'s normalized log-luminance, plus OKLab a and b.
    ///
    /// A brightness-only guide cannot tell a red watering can from the green twigs seen
    /// through its handle when the two are equally bright, so a guided filter on it
    /// pulled those twigs into the selection at Follow 50 and up (measured on 8559:
    /// docs/quality/lanes/WS-50/REPORT.md). Chroma is exactly what separates them, and
    /// it is what every colour-aware matting refinement guides on.
    static func colourGuide(source: ImageBuffer, width: Int, height: Int) -> [Plane] {
        let luma = guidePlane(source: source, width: width, height: height)
        var ca = Plane(width: width, height: height)
        var cb = Plane(width: width, height: height)
        let lab = OKLabTransform.working
        ca.values.withUnsafeMutableBufferPointer { pa in
            cb.values.withUnsafeMutableBufferPointer { pb in
                let oa = pa.baseAddress!, ob = pb.baseAddress!
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    for x in 0..<width {
                        let c = srcColor(source, x, y, width, height)
                        let o = lab.toLab(RGB(Swift.max(c.r, 0), Swift.max(c.g, 0),
                                              Swift.max(c.b, 0)))
                        oa[y * width + x] = Float(o.a.isFinite ? o.a * chromaGuideScale : 0)
                        ob[y * width + x] = Float(o.b.isFinite ? o.b * chromaGuideScale : 0)
                    }
                }
            }
        }
        return [luma, ca, cb]
    }

    /// He, Sun & Tang's guided filter with a three-channel guide: per window, the
    /// alpha is modelled as an affine function of the guide colour, `q = aᵀI + b`, with
    /// `a = (Σ + εU)⁻¹ cov(I, p)`. With one channel this is exactly
    /// `SpatialOps.guidedFilter`; the extra two are what let the model see a hue edge.
    static func colourGuidedFilter(_ p: Plane, guide: [Plane], radius: Int,
                                   epsilon: Double) -> Plane {
        let w = p.width, h = p.height
        guard radius > 0, guide.count == 3,
              guide.allSatisfy({ $0.width == w && $0.height == h }) else { return p }
        let i0 = guide[0], i1 = guide[1], i2 = guide[2]
        let n = w * h
        // The thirteen window means are independent of one another, so they run
        // concurrently; each is the same `boxBlur` the one-channel filter uses.
        let sources: [() -> Plane] = [
            { i0 }, { i1 }, { i2 }, { p },
            { i0.zip(i0) { $0 * $1 } }, { i0.zip(i1) { $0 * $1 } }, { i0.zip(i2) { $0 * $1 } },
            { i1.zip(i1) { $0 * $1 } }, { i1.zip(i2) { $0 * $1 } }, { i2.zip(i2) { $0 * $1 } },
            { i0.zip(p) { $0 * $1 } }, { i1.zip(p) { $0 * $1 } }, { i2.zip(p) { $0 * $1 } },
        ]
        let means = concurrentBoxBlurs(sources, radius: radius)
        let m0 = means[0].values, m1 = means[1].values, m2 = means[2].values
        let mp = means[3].values
        let s00 = means[4].values, s01 = means[5].values, s02 = means[6].values
        let s11 = means[7].values, s12 = means[8].values, s22 = means[9].values
        let c0 = means[10].values, c1 = means[11].values, c2 = means[12].values
        let eps = Swift.max(epsilon, 1e-12)

        var a0 = Plane(width: w, height: h), a1 = a0, a2 = a0, b = a0
        a0.values.withUnsafeMutableBufferPointer { pa0 in
        a1.values.withUnsafeMutableBufferPointer { pa1 in
        a2.values.withUnsafeMutableBufferPointer { pa2 in
        b.values.withUnsafeMutableBufferPointer { pb in
            let o0 = pa0.baseAddress!, o1 = pa1.baseAddress!, o2 = pa2.baseAddress!
            let ob = pb.baseAddress!
            DispatchQueue.concurrentPerform(iterations: h) { y in
                for i in (y * w)..<(y * w + w) {
                    let u0 = Double(m0[i]), u1 = Double(m1[i]), u2 = Double(m2[i])
                    let up = Double(mp[i])
                    // Covariance of the guide (regularized) and its covariance with
                    // the alpha.
                    let v00 = Double(s00[i]) - u0 * u0 + eps
                    let v01 = Double(s01[i]) - u0 * u1
                    let v02 = Double(s02[i]) - u0 * u2
                    let v11 = Double(s11[i]) - u1 * u1 + eps
                    let v12 = Double(s12[i]) - u1 * u2
                    let v22 = Double(s22[i]) - u2 * u2 + eps
                    let k0 = Double(c0[i]) - u0 * up
                    let k1 = Double(c1[i]) - u1 * up
                    let k2 = Double(c2[i]) - u2 * up
                    // Symmetric 3×3 solve by cofactors. ε on the diagonal keeps it
                    // positive definite; a non-finite answer (only reachable from a
                    // poisoned input) degrades to the box mean, which is the
                    // one-channel filter's flat answer.
                    let d00 = v11 * v22 - v12 * v12
                    let d01 = v02 * v12 - v01 * v22
                    let d02 = v01 * v12 - v02 * v11
                    let det = v00 * d00 + v01 * d01 + v02 * d02
                    var x0 = 0.0, x1 = 0.0, x2 = 0.0
                    if det.isFinite, abs(det) > 1e-30 {
                        let d11 = v00 * v22 - v02 * v02
                        let d12 = v01 * v02 - v00 * v12
                        let d22 = v00 * v11 - v01 * v01
                        x0 = (d00 * k0 + d01 * k1 + d02 * k2) / det
                        x1 = (d01 * k0 + d11 * k1 + d12 * k2) / det
                        x2 = (d02 * k0 + d12 * k1 + d22 * k2) / det
                        if !(x0.isFinite && x1.isFinite && x2.isFinite) { x0 = 0; x1 = 0; x2 = 0 }
                    }
                    o0[i] = Float(x0)
                    o1[i] = Float(x1)
                    o2[i] = Float(x2)
                    ob[i] = Float(up - x0 * u0 - x1 * u1 - x2 * u2)
                }
            }
        }}}}
        let coefficients = concurrentBoxBlurs([{ a0 }, { a1 }, { a2 }, { b }], radius: radius)
        let ma0 = coefficients[0].values, ma1 = coefficients[1].values
        let ma2 = coefficients[2].values, mb = coefficients[3].values
        let g0 = i0.values, g1 = i1.values, g2 = i2.values
        var out = Plane(width: w, height: h)
        for i in 0..<n {
            out.values[i] = ma0[i] * g0[i] + ma1[i] * g1[i] + ma2[i] * g2[i] + mb[i]
        }
        return out
    }

    /// `SpatialOps.boxBlur` of each plane, run concurrently. The planes are built
    /// inside the worker so a product plane exists only while its blur needs it.
    private static func concurrentBoxBlurs(_ sources: [() -> Plane], radius: Int) -> [Plane] {
        var out = [Plane](repeating: Plane(width: 1, height: 1), count: sources.count)
        out.withUnsafeMutableBufferPointer { o in
            let base = o.baseAddress!
            DispatchQueue.concurrentPerform(iterations: sources.count) { k in
                base[k] = SpatialOps.boxBlur(sources[k](), radius: radius)
            }
        }
        return out
    }

    /// The value `a.sorted()[k]` would hold, found by introselect over `range` (k is an
    /// absolute index into `a`). On return `a[range]` is partitioned about index k:
    /// every element below it is ≤ the result and every element above it ≥, which is
    /// what lets `guidePlane` run its second select on the tail alone.
    ///
    /// Precondition: no NaN in `a[range]` — `<` must be a total order on it.
    ///
    /// The partition is THREE-WAY on purpose. A guide off a black frame or an astro sky
    /// is mostly the −16 EV floor, and a constant plane is all one value; a two-way
    /// quickselect walks those one element per round and goes quadratic, which at
    /// 33 M px is a hang. Equal elements land in the middle band and end the search in
    /// one pass. Rounds are capped at ~2·log₂ n regardless; past that, or once the
    /// range is small, the rest is sorted in place, which is exact and no worse than
    /// the full sort this replaced.
    static func kthSmallest(_ a: inout [Float], _ k: Int, in range: Range<Int>) -> Float {
        precondition(range.contains(k), "kthSmallest: k outside range")
        return a.withUnsafeMutableBufferPointer { p -> Float in
            @inline(__always) func median3(_ x: Float, _ y: Float, _ z: Float) -> Float {
                Swift.max(Swift.min(x, y), Swift.min(Swift.max(x, y), z))
            }
            var lo = range.lowerBound
            var hi = range.upperBound
            var rounds = 2 * (Int.bitWidth - range.count.leadingZeroBitCount)
            while true {
                let count = hi - lo
                if count <= 32 || rounds <= 0 {
                    p[lo..<hi].sort()
                    return p[k]
                }
                rounds -= 1
                let mid = lo + count / 2
                let pivot: Float
                if count >= 1024 {
                    // Tukey's ninther: a median of three medians, for long ranges.
                    let s = count / 8
                    pivot = median3(median3(p[lo], p[lo + s], p[lo + 2 * s]),
                                    median3(p[mid - s], p[mid], p[mid + s]),
                                    median3(p[hi - 1 - 2 * s], p[hi - 1 - s], p[hi - 1]))
                } else {
                    pivot = median3(p[lo], p[mid], p[hi - 1])
                }
                // [lo, lt) < pivot, [lt, i) == pivot, [gt, hi) > pivot.
                var lt = lo, i = lo, gt = hi
                while i < gt {
                    let v = p[i]
                    if v < pivot {
                        p.swapAt(lt, i); lt += 1; i += 1
                    } else if v > pivot {
                        gt -= 1; p.swapAt(i, gt)
                    } else {
                        i += 1
                    }
                }
                if k < lt { hi = lt } else if k >= gt { lo = gt } else { return p[k] }
            }
        }
    }

    /// Expand / Contract: a flat greyscale dilation (Edge > 0) or erosion (Edge < 0) by
    /// a disc whose radius is the shift. ±50 ≈ ±1 % of the long edge.
    ///
    /// WHY MORPHOLOGY, after two rounds of distance-field arithmetic. A flat dilation by
    /// a disc of radius s moves EVERY level set of the alpha outward by s, so it does
    /// the one thing the label promises and nothing else, on any mask:
    ///
    ///   · it is monotone per pixel by construction — a bigger disc contains a smaller
    ///     one, so raising Edge can never lower a pixel and lowering it can never raise
    ///     one;
    ///   · it keeps the profile the mask already has: hard stays hard, a smoothstep
    ///     radial stays a smoothstep, a 0.6 plateau stays 0.6 and moves as a plateau;
    ///   · it cannot make speckle: dilation only closes holes and erosion only removes
    ///     islands, so a noisy range mask gets cleaner as the slider moves, not dirtier.
    ///
    /// What it replaced was a reconstruction from the α = 0.5 set's signed distance and
    /// one global ramp width, with an "advection" fallback for masks that had more than
    /// one width. The reconstruction swapped every profile for a linear ramp (so the
    /// first pixel of travel re-shaped a smooth radial), and the advection sampled the
    /// alpha a shift's distance along the distance field's normal — which lands OFF any
    /// feature thinner than the shift. On a colour-range mask, a texture made of exactly
    /// such features, that measured 2–13 % of pixels moving the wrong way at every step
    /// (up to a full 1 → 0), five times the speckle at Edge +50, and visible rings,
    /// bubbles and torn stripes (docs/quality/lanes/WS-50/REPORT.md).
    ///
    /// THE DISC IS EXACT UP TO 8 PX AND A REGULAR OCTAGON BEYOND. An exact disc costs
    /// one row pass per row of the disc, which is cheap while the disc is small — and
    /// small is where an octagon is a poor disc (radius 1 is a 3 × 3 square, 41 % too
    /// big on the diagonals). Past 8 px the octagon, the Minkowski sum of a horizontal,
    /// a vertical and two diagonal segments, costs four passes whatever the radius, and
    /// scaled by `octagonScale` its radius runs 0.96…1.04× by direction: ±1 px at full
    /// travel on a 2400-px frame, against an exact disc that would cost O(n·r).
    ///
    /// Sub-pixel shifts blend the two integer radii either side, `mix(D⌊s⌋, D⌈s⌉, frac)`.
    /// Every structuring element in the family contains the one before it (checked by
    /// brute force to radius 120; `octagonMorphology` says why), so that blend is still
    /// monotone in s and continuous through every integer, and Edge 1 on a loupe-sized
    /// raster is a half-pixel move rather than a dead step.
    static func edgeShifted(_ a: Plane, edge: Double, longEdge: Int) -> Plane {
        guard edge.isFinite else { return a }
        let e = Num.clamp(edge, -50, 50)
        let shift = (e / 50) * 0.01 * Double(longEdge)
        guard shift != 0, a.width > 0, a.height > 0 else { return a }
        let grow = shift > 0
        // The radius in structuring-element steps: pixels while the disc is exact, and
        // past that the octagon's apothem, which is 0.96 of the radius it averages to.
        // Continuous at the switch and increasing, so the family stays nested in s.
        let limit = Double(exactDiscRadius)
        let s = abs(shift) <= limit ? abs(shift) : limit + (abs(shift) - limit) * octagonScale
        var clean = a
        for i in 0..<clean.values.count where !clean.values[i].isFinite { clean.values[i] = 0 }

        let k = Int(s.rounded(.down))
        let frac = Float(s - Double(k))
        let inner = k > 0 ? flatMorphology(clean, radius: k, dilate: grow) : clean
        guard frac > 0 else { return inner }
        let outer = flatMorphology(clean, radius: k + 1, dilate: grow)
        var out = inner
        for i in 0..<out.values.count {
            let lo = inner.values[i]
            // `lo + (hi − lo)·f`, not `lo·(1 − f) + hi·f`: where the two agree — every
            // plateau, every pixel the boundary is nowhere near — this returns `lo`
            // exactly, so a flat region stays bit-identical.
            out.values[i] = lo + (outer.values[i] - lo) * frac
        }
        return out
    }

    /// Up to this radius the structuring element is an exact lattice disc.
    static let exactDiscRadius = 8

    /// The octagon's apothem per pixel of radius: 2 / (1 + sec 22.5°), which puts its
    /// flats at 0.96 and its vertices at 1.04 of the radius asked for.
    static let octagonScale: Double = 2 / (1 + 1 / cos(Double.pi / 8))

    /// Flat dilation (or erosion) by a disc of `radius` px: exact up to
    /// `exactDiscRadius`, a regular octagon beyond.
    static func flatMorphology(_ a: Plane, radius r: Int, dilate: Bool) -> Plane {
        guard r > 0 else { return a }
        return r <= exactDiscRadius
            ? discMorphology(a, radius: r, dilate: dilate)
            : octagonMorphology(a, radius: r, dilate: dilate)
    }

    /// The lattice disc x² + y² ≤ r², as its rows: row dy is a horizontal segment of
    /// half-width ⌊√(r² − dy²)⌋, so the dilation is the extreme, over dy, of the
    /// horizontally filtered plane read dy rows away. Reading past the frame clamps to
    /// the edge row, which the row's own window already covers, so it equals clipping.
    static func discMorphology(_ a: Plane, radius r: Int, dilate: Bool) -> Plane {
        let w = a.width, h = a.height
        var halfWidth = [Int](repeating: 0, count: 2 * r + 1)
        for dy in -r...r {
            var x = 0
            while (x + 1) * (x + 1) + dy * dy <= r * r { x += 1 }
            halfWidth[dy + r] = x
        }
        var filtered: [Int: Plane] = [:]
        for half in Set(halfWidth) {
            var p = a
            slidingExtreme(&p, dx: 1, dy: 0, half: half, max: dilate)
            filtered[half] = p
        }
        var out = a
        out.values.withUnsafeMutableBufferPointer { o in
            for dy in -r...r {
                guard let rows = filtered[halfWidth[dy + r]] else { continue }
                rows.values.withUnsafeBufferPointer { v in
                    for y in 0..<h {
                        let src = Swift.min(Swift.max(y + dy, 0), h - 1) * w
                        let dst = y * w
                        if dilate {
                            for x in 0..<w where v[src + x] > o[dst + x] { o[dst + x] = v[src + x] }
                        } else {
                            for x in 0..<w where v[src + x] < o[dst + x] { o[dst + x] = v[src + x] }
                        }
                    }
                }
            }
        }
        return out
    }

    /// Flat dilation (or erosion) by a regular octagon of apothem `radius` px.
    ///
    /// A horizontal and a vertical segment of half-length `ax` make a square; the two
    /// diagonals of half-length `d` make a diamond of half-width 2d; their sum has
    /// support `ax + 2d` along the axes and `√2(ax + d)` along the diagonals, equal when
    /// ax = √2·d — the regular octagon. `d` is that ratio rounded and `ax = r − 2d`,
    /// which keeps the axis support exactly r.
    ///
    /// `ax` IS NEVER ZERO. Two lattice diagonals reach only the pixels whose x + y is
    /// even — a checkerboard — and it is the horizontal and vertical segments that fill
    /// it in. At r = 2 the plain rounding gives ax = 0, a structuring element with holes
    /// that does not contain the r = 1 one, and Edge stopped being monotone there. With
    /// ax ≥ 1 every element in the family contains the one before it, which a brute-force
    /// check of the lattice sets confirms to r = 120.
    static func octagonMorphology(_ a: Plane, radius r: Int, dilate: Bool) -> Plane {
        guard r > 0 else { return a }
        let d = Swift.min(Int((Double(r) / (2 + 2.0.squareRoot())).rounded()), (r - 1) / 2)
        let ax = r - 2 * d
        // PADDED BY r, REPLICATING THE BORDER, then cropped. Four chained passes that
        // each clip at the frame lose every path that leaves it: a pixel two steps from
        // the edge can be reached by the octagon only through a point outside, so near
        // the border the octagon of radius 9 did not contain the disc of radius 8 and
        // Edge flickered there (0.31 → 0.14 → 0.03 → 0.20 over Edge 17…19 on 983). On a
        // replicated border every pass sees what the disc branch's clamped rows see.
        let w = a.width, h = a.height
        let pw = w + 2 * r, ph = h + 2 * r
        var p = Plane(width: pw, height: ph)
        for y in 0..<ph {
            let sy = Swift.min(Swift.max(y - r, 0), h - 1) * w
            for x in 0..<pw {
                p.values[y * pw + x] = a.values[sy + Swift.min(Swift.max(x - r, 0), w - 1)]
            }
        }
        slidingExtreme(&p, dx: 1, dy: 0, half: ax, max: dilate)
        slidingExtreme(&p, dx: 0, dy: 1, half: ax, max: dilate)
        slidingExtreme(&p, dx: 1, dy: 1, half: d, max: dilate)
        slidingExtreme(&p, dx: 1, dy: -1, half: d, max: dilate)
        var out = a
        for y in 0..<h {
            for x in 0..<w { out.values[y * w + x] = p.values[(y + r) * pw + x + r] }
        }
        return out
    }

    /// In place: every pixel becomes the max (or min) of the pixels within `half` steps
    /// of it along direction (dx, dy), the window clipped at the frame — which is the
    /// same answer a replicated border gives, because the replicated value is already
    /// in the window.
    ///
    /// van Herk / Gil-Werman: the padded line is cut into blocks of the window's length,
    /// a running extreme is taken forward and backward inside each block, and every
    /// window is exactly one backward tail plus one forward head — three comparisons
    /// per pixel whatever the radius. Lines are independent, so they run concurrently;
    /// each writes only its own pixels, so the result does not depend on the schedule.
    static func slidingExtreme(_ p: inout Plane, dx: Int, dy: Int, half: Int, max useMax: Bool) {
        guard half > 0 else { return }
        let w = p.width, h = p.height
        guard w > 0, h > 0 else { return }
        // Each line starts on the frame's first row or column (last row for an
        // up-going diagonal) and runs until it leaves the frame.
        var starts: [(Int, Int)] = []
        if dy == 0 {
            for y in 0..<h { starts.append((0, y)) }
        } else if dx == 0 {
            for x in 0..<w { starts.append((x, 0)) }
        } else {
            let y0 = dy > 0 ? 0 : h - 1
            for x in 0..<w { starts.append((x, y0)) }
            for y in 0..<h where y != y0 { starts.append((0, y)) }
        }
        let window = 2 * half + 1
        let pad: Float = useMax ? -.infinity : .infinity
        let step = dy * w + dx
        let chunks = Swift.min(starts.count, 64)
        p.values.withUnsafeMutableBufferPointer { v in
            let base = v.baseAddress!
            starts.withUnsafeBufferPointer { lines in
                DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                    let longest = Swift.max(w, h)
                    let padded = longest + 2 * half
                    let blocks = (padded + window - 1) / window * window
                    var line = [Float](repeating: pad, count: blocks)
                    var fwd = [Float](repeating: pad, count: blocks)
                    var bwd = [Float](repeating: pad, count: blocks)
                    var li = chunk
                    while li < lines.count {
                        defer { li += chunks }
                        let (sx, sy) = lines[li]
                        // Pixels on this line: until x or y leaves the frame.
                        var n = Int.max
                        if dx > 0 { n = Swift.min(n, w - sx) }
                        if dy > 0 { n = Swift.min(n, h - sy) }
                        if dy < 0 { n = Swift.min(n, sy + 1) }
                        guard n > 1 else { continue }
                        let first = sy * w + sx
                        let m = (n + 2 * half + window - 1) / window * window
                        for j in 0..<half { line[j] = pad }
                        for j in 0..<n { line[half + j] = base[first + j * step] }
                        for j in (half + n)..<m { line[j] = pad }
                        var j = 0
                        while j < m {
                            var f = line[j]
                            fwd[j] = f
                            for t in (j + 1)..<(j + window) {
                                let x = line[t]
                                f = useMax ? Swift.max(f, x) : Swift.min(f, x)
                                fwd[t] = f
                            }
                            var g = line[j + window - 1]
                            bwd[j + window - 1] = g
                            var t = j + window - 2
                            while t >= j {
                                let x = line[t]
                                g = useMax ? Swift.max(g, x) : Swift.min(g, x)
                                bwd[t] = g
                                t -= 1
                            }
                            j += window
                        }
                        // Output pixel i covers padded [i, i + 2·half].
                        for i in 0..<n {
                            let lo = bwd[i], hi = fwd[i + 2 * half]
                            base[first + i * step] = useMax ? Swift.max(lo, hi) : Swift.min(lo, hi)
                        }
                    }
                }
            }
        }
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
        var x0 = line[0] * sx
        var y0 = line[1] * sy
        let x1 = line[2] * sx, y1 = line[3] * sy
        var dx = x1 - x0, dy = y1 - y0
        var dd = dx * dx + dy * dy
        guard dd.isFinite, dd > 1e-12 else { return p }
        // NEVER SHORTER THAN `antialiasPixels`. Two lines dragged together read as a hard edge,
        // and a ramp narrower than a pixel is not a hard edge, it is a staircase: every
        // pixel lands at 0 or 1 and the line aliases. Widened about its midpoint, so the
        // edge stays exactly where the centre line is drawn. `maskLinearSource` does the
        // same in the shader.
        let span = antialiasPixels / long
        if dd < span * span {
            let k = span / dd.squareRoot()
            x0 = (x0 + x1) / 2 - dx * k / 2
            y0 = (y0 + y1) / 2 - dy * k / 2
            dx *= k
            dy *= k
            dd = span * span
        }

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

    /// The radius, as a fraction of the rim, inside which a radial is fully on: the
    /// one number Feather sets. Public because `MaskGPU` hands it to the shader: one
    /// copy of the policy, so the two renderers cannot disagree about where the core is.
    /// At Feather 100 the core is at least one pixel (on the shorter axis), so it does
    /// not collapse to a point. The Feather 0 end is `radialRampStart`'s job, per pixel.
    public static func radialCore(radii: (Double, Double), feather: Double?,
                                  width w: Int, height h: Int) -> Double {
        let f = Num.clamp(feather ?? 50, 0, 100) / 100
        let rxPx = Swift.max(abs(radii.0) * Double(w), 1e-6)
        let ryPx = Swift.max(abs(radii.1) * Double(h), 1e-6)
        let pixel = Num.saturate(1.0 / Swift.max(Swift.min(rxPx, ryPx), 1))
        return Num.clamp(Swift.max(1 - f, pixel), 0, 1 - 1e-6)
    }

    /// Where the falloff starts AT THIS PIXEL: the core, pulled in just far enough that
    /// the ramp to the rim is `antialiasPixels` wide in this direction.
    ///
    /// Feather 0 used to put the ramp at 1e-6 of the radius — on a 400 px radius,
    /// 0.0004 px — so every pixel landed at exactly 0 or 1 and the rim was a staircase.
    /// The floor is PER PIXEL, from the local gradient of the normalized radius, because
    /// one number for the whole ellipse is wrong on an elongated one: set on the short
    /// axis, a 1000 × 20 px ellipse got a 75 px soft ramp at the ends of its long axis.
    /// `gradient` is |∇r| per pixel; the shader computes the same expression.
    @inline(__always)
    static func radialRampStart(core: Double, gradient: Double) -> Double {
        Swift.max(0, Swift.min(core, 1 - antialiasPixels * gradient))
    }

    /// The narrowest ramp a gradient renders, in pixels: 1.5, because a smoothstep's
    /// steepest slope is 1.5 / width, so 1.5 px of it is as steep as a one-pixel box
    /// filter — the coverage an anti-aliased edge is supposed to have. One pixel of
    /// smoothstep looked half-aliased at 12×: most rim pixels still landed at 0 or 1.
    public static let antialiasPixels: Double = 1.5

    static func radialPlane(_ c: MaskComponent, _ w: Int, _ h: Int) -> Plane {
        var p = Plane(width: w, height: h)
        guard let center = c.center, center.count == 2,
              let radii = c.radii, radii.count == 2 else { return p }
        let cx = center[0], cy = center[1]
        let rx = abs(radii[0]), ry = abs(radii[1])
        guard cx.isFinite, cy.isFinite, rx > 1e-9, ry > 1e-9 else { return p }

        let theta = -(c.rotation ?? 0) * Double.pi / 180
        let ct = cos(theta), st = sin(theta)
        let rin = radialCore(radii: (rx, ry), feather: c.feather, width: w, height: h)

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
                if r >= 1 {
                    p[x, y] = 0
                    continue
                }
                // |∇r| in pixels: ∇(r²)/2r, with r² = (qx/rx)² + (qy/ry)² in long-edge
                // units, so its length is |(nx/rx, ny/ry)| / r, and one pixel is 1/long.
                let gx = nx / rxL, gy = ny / ryL
                let g = (gx * gx + gy * gy).squareRoot() / Swift.max(r, 1e-12) / long
                let start = radialRampStart(core: rin, gradient: g)
                if r <= start {
                    p[x, y] = 1
                } else {
                    // `1 - smoothstep(rin, 1, r)`, NOT `smoothstep(1, rin, r)`.
                    // `Num.smoothstep` guards a degenerate edge pair with
                    // `if e1 <= e0 { return x < e0 ? 0 : 1 }`, and `rin` is always
                    // below 1 — so the reversed form took that branch on every call
                    // and returned 0 for the entire falloff. The mask was hard-edged:
                    // 1 inside `rin`, 0 outside it, and Feather did nothing but shrink
                    // the core. Both endpoints still meet the branches above exactly.
                    p[x, y] = 1 - smoothstep(start, 1, r)
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

    /// docs/08 §8.2: a band over the scene-referred log luminance of the stage input, so
    /// the handles are EV-denominated and the band is stable under display-transform
    /// changes. `lo`/`hi` are normalized on the fixed −10…+4 EV axis.
    ///
    /// THE HANDLES ARE THE EDGE. Each shoulder is centred on its handle, so a pixel
    /// exactly at From or To is half selected at every Smooth, and Smooth softens the
    /// edge without moving it. The shoulders used to sit entirely outside the handles,
    /// so raising Smooth grew the selection: at the default 50 a band set at −3.2 EV
    /// selected sky a full stop darker than the handle the photographer had put above
    /// it (983: precision 0.46). A handle at an end of the axis is open: To at +4 takes
    /// everything brighter as well.
    ///
    /// THE MEASUREMENT IS DENOISED before it is thresholded (`rangeMeasured`). Read per
    /// pixel, a band edge that falls inside a noisy tone flickers pixel by pixel: on the
    /// ISO 3200 jacket in 2348 a band ending at −4.6 EV was 7,900 specks per megapixel.
    static func lumaRangePlane(_ c: MaskComponent, _ w: Int, _ h: Int,
                               _ source: ImageBuffer?) -> Plane {
        var p = Plane(width: w, height: h)
        guard let src = source, let lo = c.lo, let hi = c.hi, lo.isFinite, hi.isFinite else { return p }
        let lo01 = Num.saturate(lo)
        let hi01 = Num.saturate(Swift.max(hi, lo))
        let smooth = c.smooth.map { $0.isFinite ? $0 : 50 } ?? 50
        let weights = RGBColorSpace.rec2020.luminanceWeights
        // Absent means luma, which is what every band written before the field means.
        let channel = c.channel ?? .luma

        var ev = Plane(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                let measured = channel.value(srcColor(src, x, y, w, h), weights: weights)
                ev[x, y] = Num.safeLog2(measured.isFinite ? measured : 0, floorEV: -16)
            }
        }
        ev = rangeMeasured([ev], level: ev)[0]
        for i in 0..<p.values.count {
            let nEV = Num.saturate((Double(ev.values[i]) - evMin) / (evMax - evMin))
            p.values[i] = Float(lumaRangeValue(nEV, lo: lo01, hi: hi01, smooth: smooth))
        }
        return p
    }

    /// The band's arithmetic on one normalized EV, separated like `luminosityValue` so the
    /// panel's luminance-map strip draws the curve that renders and a test can state it.
    ///
    /// Smooth 0 is a step at each handle; Smooth 100 ramps across `lumaShoulderEV` (2 EV)
    /// centred on each, so nothing more than 1 EV outside the band is ever touched. A
    /// band narrower than its shoulder gets shoulders as wide as the band, which still
    /// reach 1 at its middle, so Smooth never empties a band the handles left open.
    public static func lumaRangeValue(_ nEV: Double, lo: Double, hi: Double,
                                      smooth: Double) -> Double {
        guard nEV.isFinite, lo.isFinite, hi.isFinite else { return 0 }
        let lo01 = Num.saturate(lo)
        let hi01 = Num.saturate(Swift.max(hi, lo))
        let x = Num.saturate(nEV)
        let s = smooth.isFinite ? Num.clamp(smooth, 0, 100) / 100 : 0.5
        let half = Swift.min(s * lumaShoulderEV / evSpan, hi01 - lo01) / 2
        // Open ends: a handle parked at the end of the axis means "and beyond".
        let rise = lo01 <= 0 ? 1 : (half > 1e-9
            ? smoothstep(lo01 - half, lo01 + half, x) : (x >= lo01 ? 1 : 0))
        let fall = hi01 >= 1 ? 1 : (half > 1e-9
            ? 1 - smoothstep(hi01 - half, hi01 + half, x) : (x <= hi01 ? 1 : 0))
        return Num.saturate(rise * fall)
    }

    // MARK: - Range-mask measurement (WS-47/48)

    /// Box mean with the border repeated — `SpatialOps.boxBlur`'s convention — but
    /// row-major in both passes (the vertical pass slides a row of column sums down the
    /// frame), because the range masks run eight of these per plane per bake and the
    /// column-at-a-time walk was most of their cost. Inputs here are always finite.
    static func rangeBox(_ v: [Float], _ w: Int, _ h: Int, _ radius: Int) -> [Float] {
        let r = Swift.min(radius, Swift.max(w, h))
        guard r > 0, w > 0, h > 0 else { return v }
        let inv = 1 / Double(2 * r + 1)
        var tmp = [Float](repeating: 0, count: w * h)
        v.withUnsafeBufferPointer { src in
            tmp.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    let row = y * w
                    var sum = 0.0
                    for k in -r...r { sum += Double(src[row + Swift.min(Swift.max(k, 0), w - 1)]) }
                    dst[row] = Float(sum * inv)
                    if w > 1 {
                        for x in 1..<w {
                            sum += Double(src[row + Swift.min(x + r, w - 1)])
                            sum -= Double(src[row + Swift.max(x - r - 1, 0)])
                            dst[row + x] = Float(sum * inv)
                        }
                    }
                }
            }
        }
        var out = [Float](repeating: 0, count: w * h)
        var column = [Double](repeating: 0, count: w)
        tmp.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                column.withUnsafeMutableBufferPointer { col in
                    for k in -r...r {
                        let row = Swift.min(Swift.max(k, 0), h - 1) * w
                        for x in 0..<w { col[x] += Double(src[row + x]) }
                    }
                    for x in 0..<w { dst[x] = Float(col[x] * inv) }
                    if h > 1 {
                        for y in 1..<h {
                            let add = Swift.min(y + r, h - 1) * w
                            let sub = Swift.max(y - r - 1, 0) * w
                            let row = y * w
                            for x in 0..<w {
                                col[x] += Double(src[add + x]) - Double(src[sub + x])
                                dst[row + x] = Float(col[x] * inv)
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    /// Box radius of the measurement denoise: 1/800 of the long edge, so the same mask
    /// reads the same part of the frame on screen and in the export (3 px at 2400, 1 px
    /// at the 1024 px proxy). Below 400 px it rounds to 0 and the filter is off, because
    /// there a 5 × 5 high-pass mistakes fine texture for noise (ScaleHonestyTests'
    /// 48-cycle modulation is a 6 px period at 300 px) and the preview's selection would
    /// stop matching the export's. The cost is real: an ISO 3200 band edge at 390 px
    /// speckles again (2348: 4,470 specks/MP against 459 at 410 px). Only thumbnails
    /// rasterize that small.
    public static func rangeMeasurementRadius(longEdge: Int) -> Int {
        Int((Double(longEdge) / 800).rounded())
    }

    /// How far past the noise variance a local variance must be before the smoothing
    /// treats it as structure (ε = 9σ²), and how many times the filter runs. One pass at
    /// 4σ² left 4,700 specks per MP on 2348's jacket; two at 9σ² leave under 300 and
    /// still keep 983's 1.2 EV snow/sky step to the pixel.
    public static let rangeNoiseFactor: Double = 9
    public static let rangeMeasurementPasses = 2

    /// The noise table's bins: half a stop wide from −16 EV, 46 of them, so the last one
    /// ends at +7 EV. `MaskGPU`'s noise-table pass reads the same three numbers.
    public static let rangeNoiseBinLo: Double = -16
    public static let rangeNoiseBinWidth: Double = 0.5
    public static let rangeNoiseBins = 46

    /// The bin of one level value (EV), clamped into the table.
    @inline(__always)
    static func rangeNoiseBin(_ v: Float) -> Int {
        let b = Int(((Double(v) - rangeNoiseBinLo) / rangeNoiseBinWidth).rounded(.down))
        return Swift.min(Swift.max(b, 0), rangeNoiseBins - 1)
    }

    /// One plane's noise variance per bin of `levelBins`: the robust MAD of a 5 × 5
    /// high-pass on every second pixel, away from the border (`rangeMeasured` has the
    /// reasoning).
    static func rangeNoiseTable(_ p: Plane, levelBins: [Int]) -> [Double] {
        let w = p.width, h = p.height
        let local = rangeBox(p.values, w, h, 2)
        var residuals = [[Float]](repeating: [], count: rangeNoiseBins)
        for y in stride(from: 2, to: h - 2, by: 2) {
            for x in stride(from: 2, to: w - 2, by: 2) {
                let i = y * w + x
                let r = p.values[i] - local[i]
                if r.isFinite { residuals[levelBins[i]].append(Swift.abs(r)) }
            }
        }
        return rangeNoiseVariance(&residuals)
    }

    /// Per-bin |residual| samples → per-bin noise variance. A bin with fewer than 64
    /// samples borrows from the nearest bin that has a value, walking up from the
    /// darkest, so a thin bin can borrow a value an earlier thin bin borrowed. Public
    /// because `MaskGPU`'s noise-table kernel falls back to it when it has no Metal
    /// device, and its Metal twin reproduces this walk step for step.
    public static func rangeNoiseVariance(_ residuals: inout [[Float]]) -> [Double] {
        let bins = residuals.count
        // MAD → σ; the 5 × 5 high-pass keeps 24/25 of white noise's variance.
        var sigma2 = [Double](repeating: -1, count: bins)
        for b in 0..<bins where residuals[b].count >= 64 {
            let k = residuals[b].count / 2
            let mad = Double(kthSmallest(&residuals[b], k, in: 0..<residuals[b].count))
            let s = 1.4826 * mad / (24.0 / 25.0).squareRoot()
            sigma2[b] = s * s
        }
        // Thin bins borrow from the nearest measured one.
        for b in 0..<bins where sigma2[b] < 0 {
            var best = -1.0, distance = Int.max
            for o in 0..<bins where sigma2[o] >= 0 && Swift.abs(o - b) < distance {
                best = sigma2[o]; distance = Swift.abs(o - b)
            }
            sigma2[b] = Swift.max(best, 0)
        }
        return sigma2
    }

    /// The planes a range mask thresholds, smoothed where the picture is flat and left
    /// alone where it has edges: a self-guided filter whose ε is the frame's OWN noise
    /// variance at that brightness.
    ///
    /// WHY NOISE-AWARE. A fixed ε that quiets ISO 6400 darks (σ ≈ 0.48 EV per pixel on
    /// 2348's jacket) also flattens the 1.2 EV snow/sky step in 983, and one that keeps
    /// that step leaves the jacket speckling. The noise is a function of brightness, so
    /// it is estimated per half-stop bin of `level` (a robust MAD of a 5 × 5 high-pass,
    /// on every second pixel; demosaicked noise is correlated over a pixel or two, and
    /// a 3 × 3 high-pass sees too little of it) and each pixel gets the ε of its bin. A clean frame
    /// estimates a tiny σ and the filter is close to identity; texture inflates the
    /// estimate a little, which costs a selection detail finer than a few pixels.
    ///
    /// All planes share `level`'s bins but keep their own σ, because chroma noise and
    /// lightness noise are different sizes.
    static func rangeMeasured(_ planes: [Plane], level: Plane) -> [Plane] {
        guard let first = planes.first else { return planes }
        let w = first.width, h = first.height
        let radius = rangeMeasurementRadius(longEdge: Swift.max(w, h))
        guard radius > 0 else { return planes }
        let levelBins = level.values.map(rangeNoiseBin)
        return planes.map { p in
            let sigma2 = rangeNoiseTable(p, levelBins: levelBins)
            let eps = levelBins.map { Float(rangeNoiseFactor * sigma2[$0] + 1e-10) }
            var out = p.values
            let n = out.count
            var a = [Float](repeating: 0, count: n)
            var b = [Float](repeating: 0, count: n)
            for _ in 0..<rangeMeasurementPasses {
                let mean = rangeBox(out, w, h, radius)
                var square = out
                for i in 0..<n { square[i] *= square[i] }
                let meanSq = rangeBox(square, w, h, radius)
                for i in 0..<n {
                    let m = mean[i]
                    let v = Swift.max(meanSq[i] - m * m, 0)
                    let gain = v / (v + eps[i])
                    a[i] = gain
                    b[i] = m * (1 - gain)
                }
                let meanA = rangeBox(a, w, h, radius)
                let meanB = rangeBox(b, w, h, radius)
                for i in 0..<n {
                    let q = meanA[i] * out[i] + meanB[i]
                    if q.isFinite { out[i] = q }
                }
            }
            return Plane(width: w, height: h, values: out)
        }
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

    /// docs/08 §8.2: everything this colour, wherever it is, in OKLab. Multiple samples
    /// union (the best match wins). Refine (`rangeAmount`, 0…100, default 50) widens
    /// every tolerance together.
    ///
    /// THE DISTANCE, and why it is not hue/chroma/lightness trapezoids any more.
    ///
    /// · Shading is not a different colour. Scaling linear RGB by k scales OKLab's L, a
    ///   and b all by ∛k, so a pixel's chromaticity is compared AT THE SAMPLE'S
    ///   LIGHTNESS — (a, b)·L₀/L — and its lightness only through a wide, separate EV
    ///   gate. The old gate allowed ±0.15 in L at Refine 50, about ±1.3 EV, and the
    ///   shaded underside of 8559's red can fell out of a mask sampled on its side
    ///   (recall 0.84), behind a contour where the falloff ended.
    /// · A near-neutral is not "any hue". The old hue test faded out as EITHER chroma
    ///   fell, so a saturated red sample let grey bench wood through at Refine 75
    ///   (precision 0.55). Now chromaticity is one distance, split along the sample's
    ///   hue: across it (a hue error) at the tolerance, toward neutral at no more
    ///   than 90 % of the sample's own chroma, so grey is never a saturated sample's colour; a grey
    ///   SAMPLE selects greys, because then every direction is across.
    /// · Every edge of the falloff is a smoothstep, never a corner, and the inputs are
    ///   denoised first (`rangeMeasured`): ISO 6400 chroma noise read per pixel was
    ///   9,900 specks per megapixel on 2062's poppies.
    static func colorRangePlane(_ c: MaskComponent, _ w: Int, _ h: Int,
                                _ source: ImageBuffer?) -> Plane {
        var p = Plane(width: w, height: h)
        guard let src = source, let samples = c.samples, !samples.isEmpty else { return p }
        let context = OKLabTransform.working
        // §8.2 caps the picker at 8 samples; extras are ignored, not an error.
        var refs: [OKLab] = []
        for s in samples.prefix(8) where s.count >= 3 {
            if s[0].isFinite && s[1].isFinite && s[2].isFinite {
                let lab = context.toLab(RGB(s[0], s[1], s[2]))
                if lab.L.isFinite && lab.a.isFinite && lab.b.isFinite { refs.append(lab) }
            }
        }
        if refs.isEmpty { return p }
        let tol = colorRangeTolerances(refine: c.rangeAmount ?? 50)

        // The three planes, measured, then denoised against the frame's own noise.
        var planes = [Plane](repeating: Plane(width: w, height: h), count: 3)
        var level = Plane(width: w, height: h)
        let weights = RGBColorSpace.rec2020.luminanceWeights
        for y in 0..<h {
            for x in 0..<w {
                let rgb = srcColor(src, x, y, w, h)
                let lab = context.toLab(rgb)
                let i = y * w + x
                planes[0].values[i] = Float(lab.L.isFinite ? lab.L : 0)
                planes[1].values[i] = Float(lab.a.isFinite ? lab.a : 0)
                planes[2].values[i] = Float(lab.b.isFinite ? lab.b : 0)
                let luminance = weights.r * rgb.r + weights.g * rgb.g + weights.b * rgb.b
                level.values[i] = Float(Num.safeLog2(luminance.isFinite ? luminance : 0,
                                                     floorEV: -16))
            }
        }
        planes = rangeMeasured(planes, level: level)

        for i in 0..<p.values.count {
            let lab = OKLab(L: Double(planes[0].values[i]), a: Double(planes[1].values[i]),
                            b: Double(planes[2].values[i]))
            var best = 0.0
            for ref in refs {
                let v = colorRangeValue(lab, ref: ref, tolerances: tol)
                if v > best { best = v }
            }
            p.values[i] = Float(best)
        }
        return p
    }

    /// Refine → tolerances. Geometric in Refine so each step of the slider is the same
    /// proportional widening: hue (chromaticity across the sample's hue) 0.0144 → 0.046 →
    /// 0.144 in OKLab (0 / 50 / 100),
    /// lightness ±1.5 → ±3 → ±6 EV to the zero point.
    public static func colorRangeTolerances(refine: Double) -> (chroma: Double, ev: Double) {
        let r = refine.isFinite ? Num.clamp(refine, 0, 100) / 100 : 0.5
        return (chroma: 0.0144 * pow(10, r), ev: 1.5 * pow(4, r))
    }

    /// Where the falloff starts, as a fraction of each tolerance: inside it a pixel is
    /// fully selected, between it and the tolerance it fades on a smoothstep.
    public static let colorRangeCore: Double = 0.35
    /// Lightness keeps a wider flat core: shading is the common case, not the edge one.
    public static let colorRangeEVCore: Double = 0.5
    /// OKLab L below which chromaticity is not rescaled any further — black has no colour
    /// worth dividing by.
    public static let colorRangeLFloor: Double = 0.08
    /// Saturation tolerance as a multiple of the hue tolerance.
    /// 2.5, not 2: at 2 with a hue tolerance 25 % wider, 8559's terracotta pot (34° of
    /// hue from the red can) took a third of a Refine 50 edit.
    public static let colorRangeSaturationReach: Double = 2.5
    /// How far toward grey any sample may always reach, in OKLab chroma.
    public static let colorRangeNeutralReach: Double = 0.035

    /// One pixel against one sample. Public so a test can state the geometry directly.
    public static func colorRangeValue(_ lab: OKLab, ref: OKLab,
                                       tolerances tol: (chroma: Double, ev: Double)) -> Double {
        guard lab.L.isFinite, lab.a.isFinite, lab.b.isFinite else { return 0 }
        let refL = Swift.max(ref.L, colorRangeLFloor)
        let L = Swift.max(lab.L, colorRangeLFloor)
        // Chromaticity at the sample's lightness.
        let k = refL / L
        let a = lab.a * k, b = lab.b * k
        let refC = (ref.a * ref.a + ref.b * ref.b).squareRoot()
        var across: Double
        var along: Double
        if refC > 1e-6 {
            let ua = ref.a / refC, ub = ref.b / refC
            along = a * ua + b * ub - refC
            across = -a * ub + b * ua
        } else {
            along = 0
            across = (a * a + b * b).squareRoot()
        }
        // Saturation (along the sample's hue) gets 2.5 × the room hue does: sheen and
        // skylight desaturate a surface without changing what colour it is (the top of
        // 8559's can). Toward neutral that room is capped at 90 % of the sample's chroma,
        // so a saturated sample never reaches grey; a sample within ~1.5 JND of grey
        // (0.035) is not capped below that, because its greys ARE its colour.
        let saturation = colorRangeSaturationReach * tol.chroma
        let alongTol = along < 0
            ? Swift.min(saturation, Swift.max(0.9 * refC, colorRangeNeutralReach))
            : saturation
        across /= tol.chroma
        along /= alongTol
        let d = (across * across + along * along).squareRoot()
        let chroma = 1 - smoothstep(colorRangeCore, 1, d)
        if chroma <= 0 { return 0 }
        // Lightness as EV: L ∝ ∛Y along a shading line, so 3·log₂(L/L₀) is stops.
        let ev = 3 * Num.safeLog2(L / refL, floorEV: -40)
        let light = 1 - smoothstep(colorRangeEVCore, 1, Swift.abs(ev) / tol.ev)
        return Num.saturate(chroma * light)
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
    /// resolution. The caller supplies the matte — already refined against the picture
    /// at `PipelineRenderer.matteLongEdge` (`VisionMattes`, WS-49) — and this only fits
    /// it to the target extent.
    ///
    /// Shrinking by 2× or more area-averages first. The refined matte is 2048 px and a
    /// draft raster is 1024: a bilinear resize at 2:1 samples between every other pair
    /// of pixels, so a one-pixel strand of hair the refinement recovered survives on
    /// alternate rows and vanishes on the rest. The box keeps its coverage.
    static func mattePlane(_ kind: MaskKind, _ w: Int, _ h: Int,
                           _ aiMattes: [String: Plane]) -> Plane {
        guard let matte = aiMattes[kind.rawValue] else { return Plane(width: w, height: h) }
        let factor = Swift.min(matte.width / Swift.max(w, 1), matte.height / Swift.max(h, 1))
        var source = matte
        if factor >= 2 {
            source = Plane(width: (matte.width + factor - 1) / factor,
                           height: (matte.height + factor - 1) / factor,
                           values: MatteRefine.boxDown(matte.values, matte.width,
                                                       matte.height, factor))
        }
        return fitted(source, w, h).map { Num.saturate($0.isFinite ? $0 : 0) }
    }

    // MARK: - Brush fine grid

    /// The smallest brush stamp radius, in raster pixels, a mask fold is evaluated at.
    /// Below it the fold runs on a finer grid and is box-reduced (see `alpha`). Chosen
    /// by measurement, not taste: docs/audit-2026-10/streams/P15-brush.md.
    static let brushFineRadiusPx: Double = 3
    /// The most the fine grid may multiply each side by.
    static let brushSupersampleLimit = 4

    /// How many times finer than `size`, per side, a mask's fold must run so its
    /// thinnest brush stroke is drawn with a radius of at least `brushFineRadiusPx`.
    ///
    /// Bounded twice: by `brushSupersampleLimit`, and so the fine grid's long edge
    /// never passes `DraftLadder.interactiveLongEdgeCeiling` (or the requested long
    /// edge, when that is already larger — an export at sensor size gets no fine grid
    /// at all, and needs none: its thinnest legal stroke, Size 0.002, is a 6 px radius
    /// at 6000 px). The ceiling is the same line `BrushPlaneCache` draws for what it
    /// will hold, so a fine plane on an interactive surface is always one it can resume.
    ///
    /// Public because the pipeline paints its held brush planes at the fine size; a
    /// plane of any other size is refused by `rasterize` and repainted.
    public static func brushSupersample(mask: Mask,
                                        strokeSets: [String: BrushStrokeSet],
                                        size: (width: Int, height: Int)) -> Int {
        let long = Swift.max(size.width, size.height)
        guard long > 0 else { return 1 }
        var thinnest = Double.infinity
        for c in mask.components where c.kind == .brush {
            guard let ref = c.strokesRef, let set = strokeSets[ref] else { continue }
            for stroke in set.strokes
            where stroke.size.isFinite && stroke.size > 0 && stroke.flow > 0 {
                thinnest = Swift.min(thinnest, stroke.size / 2 * Double(long))
            }
        }
        guard thinnest.isFinite, thinnest < brushFineRadiusPx else { return 1 }
        let wanted = (brushFineRadiusPx / thinnest).rounded(.up)
        let room = Swift.max(1, Swift.max(DraftLadder.interactiveLongEdgeCeiling, long) / long)
        return Swift.max(1, Swift.min(Int(Swift.min(wanted, 64)),
                                      brushSupersampleLimit, room))
    }

    /// The fine size `alpha` folds `mask` at for a request of `size`.
    public static func brushFoldSize(mask: Mask,
                                     strokeSets: [String: BrushStrokeSet],
                                     size: (width: Int, height: Int))
        -> (width: Int, height: Int) {
        let f = brushSupersample(mask: mask, strokeSets: strokeSets, size: size)
        return (width: size.width * f, height: size.height * f)
    }

    /// Box average of `factor`×`factor` blocks. `p`'s sides are exact multiples.
    static func boxReduced(_ p: Plane, by factor: Int) -> Plane {
        let w = p.width / factor
        let h = p.height / factor
        var out = Plane(width: w, height: h)
        let inv = 1 / Double(factor * factor)
        var row = [Double](repeating: 0, count: w)
        for y in 0..<h {
            for x in 0..<w { row[x] = 0 }
            for fy in 0..<factor {
                let base = (y * factor + fy) * p.width
                for x in 0..<w {
                    var sum = 0.0
                    let start = base + x * factor
                    for fx in 0..<factor { sum += Double(p.values[start + fx]) }
                    row[x] += sum
                }
            }
            for x in 0..<w { out.values[y * w + x] = Float(row[x] * inv) }
        }
        return out
    }

    // MARK: - Brush stroke

    /// One stroke into the accumulation buffer: the swept dab (`BrushStrokeRaster`),
    /// composited once. Paint is asymptotic to Density and never exceeds it regardless
    /// of passes; erase multiplies toward zero by the stroke's own coverage.
    static func paint(stroke: BrushStroke, into p: inout Plane,
                      width w: Int, height h: Int, longEdge long: Double,
                      source: ImageBuffer?) {
        guard stroke.size.isFinite, stroke.size > 0, !stroke.points.isEmpty else { return }
        let radiusPx = (stroke.size / 2) * long
        guard radiusPx.isFinite, radiusPx >= 0.5 else { return }
        // Only the stroke's own bounds are held: a short stroke on a 45 MP export plane
        // must not allocate a second 45 MP plane.
        let window = BrushStrokeRaster.bounds(of: stroke, width: w, height: h,
                                              radius: radiusPx)
        guard !window.isEmpty else { return }
        var raster = BrushStrokeRaster(stroke: stroke, width: w, height: h, longEdge: long,
                                       source: source, window: window)
        guard raster.paints else { return }
        for point in stroke.points { raster.append(point) }
        raster.finish()
        raster.composite(into: &p)
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

    // MARK: - Small helpers

    /// Smoothstep that also runs backwards (`e0 > e1`), which every inward falloff in
    /// this file needs. `Num.smoothstep` deliberately treats an inverted pair as a step.
    static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let d = e1 - e0
        if !d.isFinite || abs(d) < 1e-12 { return x < e0 ? 0 : 1 }
        let u = Num.saturate((x - e0) / d)
        return u * u * (3 - 2 * u)
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
