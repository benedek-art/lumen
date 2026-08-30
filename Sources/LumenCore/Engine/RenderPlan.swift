// RenderPlan.swift
// The bake: a recipe compiled into the small set of objects a render actually needs.
//
// Nearly every colour-bearing stage in Lumen is a pure RGB→RGB function — printer
// lights, the colour tools, the grade, the film chain, the display transform, the tone
// curve. Rather than reimplement each one in a shader and hope the two stay in step,
// the engine evaluates the composed function here, in the reference implementation,
// and bakes it into lookup tables the GPU fetches. One implementation, one set of
// goldens, and the shader surface shrinks to a handful of trivial kernels.
//
// The plan is split exactly where the pipeline's spatial stages sit (docs/14 §2), so
// the documented stage order survives the optimization:
//
//   S6 linear matrix  →  S7 tone gain (needs the guided mask: spatial)
//                     →  colourGrade LUT   (S9 + S10, log → log)
//                     →  S8/S11/S12/S13    (presence, local, sharpen, vignette: spatial)
//                     →  finish LUT        (S14 + S15, log → display-linear)
//
// Building a plan is a few milliseconds; it happens once per parameter change, never
// per pixel and never per tile.

import Foundation

public struct RenderPlan: Sendable {

    public let recipe: Recipe

    /// Renderer-measured chroma-weighted mean hue per mixer band — Uniformity's
    /// convergence target when present (docs/05; docs/23 audit queue item 12). Stored
    /// so `exactColor`'s engine is built from exactly what the table's engine was.
    public let bandMeanHues: [Double]?

    // MARK: Stage S6 — the fused linear matrix
    public let linear: LinearStage

    // MARK: Stage S7 — tone
    public let tone: ToneEngine
    /// Gain (a linear multiplier) as a function of the log-encoded guided mask value.
    public let toneGainLUT: LUT1D
    public let toneIsIdentity: Bool

    // MARK: Stages S9–S10 — colour and grade, log → log
    public let colorGradeLUT: LUT3D
    public let colorGradeIsIdentity: Bool

    // MARK: Stages S14–S15 — picture formation and the curve, log → display-linear
    ///
    /// Stored NORMALIZED into [0,1] and paired with `finishScale`. A colour-cube
    /// filter's domain is the unit cube, and an HDR rendition legitimately reaches
    /// several times display white; keeping the table normalized and multiplying by a
    /// scalar afterwards means no highlight can be silently clipped by the table.
    ///
    /// THE TWO ARE ONE VALUE. `finishScale` is the white the table beside it was baked
    /// under — NOT necessarily this event's white, because a draft frame may be served
    /// a stale table (see `PlanTableCache.pairedTableAllowingStale`). Reading either
    /// alone, or recomputing the scalar while accepting a cached table, produces a
    /// picture that belongs to no setting. Use `displayWhite` when what is wanted is
    /// this recipe's white; that one is always current.
    public let finishLUT: LUT3D
    public let finishScale: Double

    /// The soft proof, when the viewer has one on (docs/11: "the proof state is a
    /// viewing mode, not an edit", which is why it arrives as a plan argument and not
    /// through the recipe).
    ///
    /// The proof's picture half is composed onto the END of `finishLUT` rather than run
    /// as a stage of its own, and that is why it reaches pixels with no new kernel: the
    /// finish table is the one object the GPU graph and `ReferenceRenderer` both apply,
    /// so the simulation cannot be present on one path and missing from the other.
    public let softProof: SoftProofTransform?

    /// The finish table WITHOUT the proof, kept only when the gamut warning is on.
    ///
    /// The flag is a discontinuity and a trilinear table cannot hold one — measured, the
    /// baked flag's edge sat a mean of 0.017 OKLCh chroma off the true boundary. So the
    /// renderers compute it per pixel instead, and to ask "is this colour outside the
    /// destination" they need the value from before the proof clipped it. This is that
    /// value's table. Nil when there is no warning to draw, so nothing pays for it.
    public let finishLUTBeforeProof: LUT3D?

    // MARK: Display
    public let displayWhite: Double
    public let displayTransform: DisplayTransform
    public let filmChain: FilmChain?

    // MARK: Spatial parameters carried through for the image stages
    public let detail: Detail
    public let denoise: Denoise
    public let vignetteEV: Double
    /// `Look.vignetteFeather`, 0…100 — how gradually the burn arrives. Carried beside
    /// the EV so both renderers read one resolved pair;
    /// `DetailEngine.vignetteInnerRadius(feather:)` turns it into geometry.
    public let vignetteFeather: Double
    public let masks: [Mask]

    // MARK: Stage S3 — profiled classical noise reduction
    ///
    /// The Tier-1 engine, resolved through `ISODefaults.classic(for:)` so the mode
    /// switch means what the panel says: Off zeroes every row including Hot Pixels,
    /// Classic runs the recipe's own block, and AI drops the ISO-adaptive rows to zero
    /// because the noise they compensate for is meant to be gone by then — **unless the
    /// photographer set them by hand**, which the recipe now records.
    ///
    /// That exception used to be two parameters defaulting to `false`, and this call
    /// site passed neither, so it never fired: switching to AI zeroed a hand-set
    /// Luminance on every render. A default argument is a silent answer to a question
    /// the caller was never asked, and the specification's word was "unless".
    public let classicalDenoise: ClassicalDenoise
    /// True when S3 cannot move a pixel, so the graph skips forty nodes.
    public let denoiseIsIdentity: Bool

    /// `captureISO` is what the file says it was shot at; it selects the noise profile
    /// every threshold in S3 is denominated in. A file with no ISO recorded falls back
    /// to the base-ISO profile, which is the gentlest of the seed curve — under-denoising
    /// an unknown body is recoverable, over-denoising it is not.
    /// `allowStaleTables` routes the two cached bakes through
    /// `PlanTableCache.tableAllowingStale`: a plan built for a DRAFT frame may carry
    /// the previous event's table while the exact one bakes off the render path —
    /// one mouse event of slider travel stale, gone the moment the hand pauses.
    /// Settle and export plans must leave it false; their tables are exact by
    /// construction, which is what makes the staleness bounded instead of sticky.
    /// `bandMeanHues` is the renderer-measured chroma-weighted mean hue per mixer
    /// band (`ColorEngine.measureBandMeanHues`) — the convergence target docs/05
    /// specifies for Uniformity. The plan cannot measure it itself: a plan owns no
    /// image. nil is honest and self-consistent — Uniformity then converges on each
    /// band's own core-arc midpoint, the user-writable fallback.
    public init(recipe: Recipe,
                asShotKelvin: Double = 5500,
                asShotTint: Double = 0,
                displayWhiteTarget: Double? = nil,
                lutSize: Int = LUT3D.interactiveSize,
                captureISO: Double? = nil,
                space: RGBColorSpace = .rec2020,
                softProof: SoftProof? = nil,
                allowStaleTables: Bool = false,
                bandMeanHues: [Double]? = nil) {
        self.recipe = recipe
        self.bandMeanHues = bandMeanHues
        let develop = recipe.develop
        let look = recipe.look

        // ---- S6 -------------------------------------------------------------
        let wb = WhiteBalanceEngine(asShotKelvin: asShotKelvin, asShotTint: asShotTint,
                                    targetKelvin: develop.raw.temp,
                                    targetTint: develop.raw.tint, space: space)
        let toneEngine = ToneEngine(tone: develop.tone, zones: develop.zones)
        let grade = GradeEngine(wheels: look.wheels, printerLights: look.printerLights,
                                whiteAnchorEV: toneEngine.whiteAnchorEV,
                                blackAnchorEV: toneEngine.blackAnchorEV)
        self.linear = LinearStage(whiteBalance: wb,
                                  exposureGain: toneEngine.exposureGain,
                                  printerLightGains: grade.printerLightGains)

        // ---- S7 -------------------------------------------------------------
        self.tone = toneEngine
        self.toneIsIdentity = toneEngine.isIdentity
        self.toneGainLUT = toneEngine.isIdentity
            ? LUT1D(size: 2) { _ in 1 }
            : toneEngine.bakeGainLUT()

        // ---- S9 + S10 --------------------------------------------------------
        let color = ColorEngine(mixer: develop.mixer, pointColors: develop.pointColors,
                                color: develop.color, primaries: look.primaries,
                                bw: look.bw, bandMeanHues: bandMeanHues)
        let colorIdentity = color.isIdentity && grade.isIdentity
        self.colorGradeIsIdentity = colorIdentity
        if colorIdentity {
            self.colorGradeLUT = LUT3D.identity(size: 2)
        } else {
            // Everything `color` and `grade` were built from, plus the anchors the
            // grade reads. Miss anything here and the cache returns a table for a
            // recipe the photographer is no longer editing.
            let bake = {
                LUT3D(size: lutSize) { encoded in
                    let scene = LumenLog.decode(encoded)
                    let out = grade.apply(color.apply(scene))
                    return LumenLog.encode(out)
                }
            }
            // The measured hues are a table input like any other: two photos with
            // different skies bake different Uniformity fields, and a key without
            // this part would hand photo B the table converged on photo A's blues —
            // the Paste-Settings poisoning class, one cache over.
            let huesPart = bandMeanHues.map {
                $0.map(CanonicalJSON.canonicalNumber).joined(separator: ",")
            } ?? "-"
            let key = PlanTableCache.key(
                ["cg", "\(lutSize)", "\(space)", huesPart,
                 CanonicalJSON.canonicalNumber(toneEngine.whiteAnchorEV),
                 CanonicalJSON.canonicalNumber(toneEngine.blackAnchorEV)],
                [develop.mixer, develop.pointColors, develop.color,
                 look.primaries, look.bw, look.wheels, look.printerLights])
            self.colorGradeLUT = key.map {
                allowStaleTables
                    ? PlanTableCache.tableAllowingStale(.colorGrade, key: $0,
                                                        size: lutSize, build: bake)
                    : PlanTableCache.table(.colorGrade, key: $0, size: lutSize,
                                           build: bake)
            } ?? bake()
        }

        // ---- S14 + S15 -------------------------------------------------------
        let transform = DisplayTransform.forRecipe(recipe,
                                                   displayWhiteTarget: displayWhiteTarget,
                                                   space: space)
        self.displayTransform = transform
        self.displayWhite = transform.white

        let chain: FilmChain?
        if let film = look.filmLab, film.amount > 0, FilmStock.named(film.stock) != nil {
            // `FilmChain(_:displayWhite:)` is the convenience initializer, and it
            // delegates with `filmExposure: 0`. Using it here pinned Film Exposure to
            // zero on every render in the app: the engine honours the value, clamps it
            // to −2…+3 and threads it through the whole chain, and nothing outside a
            // test ever passed one.
            //
            // `base: transform` is docs/31 round two §2. Without it the chain rebuilt
            // a Neutral transform, copied only `whiteTarget`, and blended the film
            // against THAT — so with the gate above being `amount > 0`, Strength 0
            // rendered through the user's transform and Strength 1 rendered 99%
            // Neutral: a 51-code discontinuity on the "Linear" preset, and Black
            // target dropped outright. The blend base is the recipe's solved
            // transform, the same object the `else` branch of `display` below applies,
            // so Strength walks between the two renderings with no jump at either end.
            chain = FilmChain(film, filmExposure: film.exposure,
                              displayWhite: transform.white, base: transform)
        } else {
            chain = nil
        }
        self.filmChain = chain

        let curve = CurveStack(develop.curve)
        let boundary = RenderPlan.sharedGamutBoundary
        let white = transform.white
        let scale = Swift.max(white, 1e-6)
        // `finishScale` is NOT assigned here, deliberately: it has to be the scalar of
        // whichever table is actually served below, and on a draft frame that may be a
        // stale one baked under a different white. Assigning this event's value here is
        // precisely the defect — see `pairedTableAllowingStale`.
        let proof = softProof?.transform(working: space)
        self.softProof = proof
        // One closure, used for both tables, so the proofed and unproofed versions
        // cannot drift into being different pictures with one difference.
        let display: @Sendable (RGB) -> RGB = { encoded in
            let scene = LumenLog.decode(encoded)
            let formed: RGB
            if let chain {
                formed = chain.apply(scene)
            } else {
                formed = transform.apply(scene, gamut: boundary)
            }
            // The division by `scale` comes BEFORE the proof deliberately: the proof's
            // domain is display-linear relative to display white, so 1.0 has to mean
            // white for the destination gamut to mean anything. Proofing the unscaled
            // value would put an HDR rendition's 4.0 through a table whose whole
            // question is "does this fit in the file", and every highlight would answer
            // no for the wrong reason.
            return curve.apply(formed, white: white, space: space) / scale
        }

        // The single most expensive thing a plan does, and the one least likely to have
        // changed since the last frame. `transform` comes from the render preset, the
        // display white target and the tone ANCHORS — and the anchors move only with
        // Whites and Blacks — so Exposure, Contrast, Highlights, Shadows, the zones, all
        // of presence and denoise and sharpening, every mask and the vignette leave this
        // table bit-identical while the user drags them.
        //
        // `boundary` is `Gamut.sharedBoundary`, one object for the whole process, so it
        // is a constant rather than a key component. The PROOF is not in this key and
        // must not be: `display` does not read it, and the proofed table is derived from
        // this one below under a key of its own.
        //
        // `FilmLab` has no default value to stand in for "no film", and substituting a
        // literal marker for an unencodable one would let a real stock collide with the
        // absence of one. Absent keys as "-", present-but-unencodable fails the key.
        let filmPart: String?
        if let film = look.filmLab {
            filmPart = (try? CanonicalJSON.tree(of: film)).map(CanonicalJSON.serialize)
        } else {
            filmPart = "-"
        }
        let baseKey = filmPart.flatMap { film in
            PlanTableCache.key(
                ["fin", "\(lutSize)", "\(space)", film,
                 CanonicalJSON.canonicalNumber(white),
                 CanonicalJSON.canonicalNumber(toneEngine.whiteAnchorEV),
                 CanonicalJSON.canonicalNumber(toneEngine.blackAnchorEV),
                 displayWhiteTarget.map(CanonicalJSON.canonicalNumber) ?? "-"],
                [look.render, develop.curve])
        }
        let bakePlain = { LUT3D(size: lutSize, transform: display) }
        // The proofed variant below stays on the blocking path either way: it is a
        // cheap map over `plain`, and mapping a stale `plain` keeps the two consistent.
        //
        // SERVED AS A PAIR. `bakePlain` normalizes by `scale` (the division at the end
        // of `display`) and `RenderGraph` multiplies `finishScale` back, so the table
        // and the scalar are two halves of one picture — and the stale path hands back
        // a table baked under a DIFFERENT key. Taking this event's `scale` for a
        // previous event's table yields `oldPicture × newWhite / oldWhite`: not a stale
        // picture but one that existed at no setting. That is the tone cube's flicker
        // exactly (see the `toneKey` comment below), one table over, and it survived
        // that fix because the fix was made where the bug was FOUND rather than where
        // the shape was.
        //
        // Latent as the app ships, and precisely so: `transform.white` is
        // `max(whiteTarget, 1) / 100` and `applyAnchors` writes only the anchor EVs, so
        // Whites and Blacks change this key without changing this scale — a stale serve
        // there is correctly one event behind. It takes a control over
        // `look.render.whiteTarget`, which has no UI yet, to make the two disagree. The
        // fix is structural anyway: the cache returns the scalar it baked with, so
        // `finishScale` is whatever pairs with the table actually served, and no future
        // caller has to know any of the above.
        let served: (table: LUT3D, pairedValue: Double)
        if let baseKey {
            served = allowStaleTables
                ? PlanTableCache.pairedTableAllowingStale(.finish, key: baseKey,
                                                          size: lutSize,
                                                          pairedWith: scale,
                                                          build: bakePlain)
                : (PlanTableCache.table(.finish, key: baseKey, size: lutSize,
                                        pairedWith: scale, build: bakePlain), scale)
        } else {
            served = (bakePlain(), scale)
        }
        let plain = served.table
        self.finishScale = served.pairedValue

        // Baked ONCE and then mapped, not baked twice.
        //
        // The proofed table's samples are the plain table's samples put through the
        // proof, by construction — so the second table is a matrix, a clamp and a matrix
        // over 35 937 samples rather than another 35 937 evaluations of the display
        // transform, the film chain and the curve. That distinction is the difference
        // between proofing costing nothing per frame and costing another 17.7 ms of the
        // budget `CurveStack`'s header measures.
        //
        // The map is cached too, under the base key PLUS the proof settings. Without the
        // settings in the key, toggling the destination or the intent would keep showing
        // the previous proof — the exact stale-picture failure `PlanTableCacheTests`
        // exists to catch, arriving through a door that test did not know about.
        if let proof {
            let mapProof = {
                var mapped = plain.data
                var i = 0
                while i < mapped.count {
                    let out = proof.mapped(RGB(Double(mapped[i]), Double(mapped[i + 1]),
                                               Double(mapped[i + 2])))
                    mapped[i] = Float(out.r)
                    mapped[i + 1] = Float(out.g)
                    mapped[i + 2] = Float(out.b)
                    i += 4
                }
                return LUT3D(size: lutSize, data: mapped)
            }
            let proofKey = baseKey.flatMap { base in
                PlanTableCache.key([base, "proof"], [proof.settings])
            }
            // A draft plan may be holding a STALE `plain` (that is what
            // `tableAllowingStale` is for) — and `mapProof` closes over it. Storing
            // that map under the exact `proofKey` poisoned the slot: the settle
            // rebuilt the plan with the exact `plain`, hit the poisoned entry, and
            // the soft-proofed picture at rest stayed one mouse event behind
            // forever, with the gamut flag (computed from the exact before-proof
            // table) disagreeing with the proofed pixels under it. On the draft
            // path the map is built fresh and NOT cached — a few milliseconds of
            // matrix-and-clamp per drag plan — and only the blocking path, whose
            // `plain` is exact by construction, may populate the cache.
            if allowStaleTables {
                self.finishLUT = mapProof()
            } else {
                self.finishLUT = proofKey.map {
                    PlanTableCache.table(.finishProofed, key: $0, size: lutSize,
                                         pairedWith: served.pairedValue,
                                         build: mapProof)
                } ?? mapProof()
            }
            // Kept only when there is a flag to draw; the flag needs the value from
            // before the map and nothing else does.
            self.finishLUTBeforeProof = proof.settings.showGamutWarning ? plain : nil
        } else {
            self.finishLUT = plain
            self.finishLUTBeforeProof = nil
        }
        // ---- S3 ---------------------------------------------------------------
        let noiseProfile = NoiseProfile.forISO(captureISO ?? 100)
        let engine = ClassicalDenoise(ISODefaults.classic(for: develop.denoise),
                                      profile: noiseProfile)
        self.classicalDenoise = engine
        self.denoiseIsIdentity = engine.isIdentity

        // ---- carried through --------------------------------------------------
        self.detail = develop.detail
        self.denoise = develop.denoise
        self.vignetteEV = look.vignette
        self.vignetteFeather = look.vignetteFeather
        self.masks = recipe.masks.filter { $0.enabled }

        // Baked once, here, and only when the tone stage will actually read it. At
        // the plan's own fidelity: an export plan (lutSize == exportSize) gets the
        // export-grade cube, because MEASURED (AccuracyProbeTests) the 32-knot cube
        // parks up to 0.080 EV of error on Whites +100 at scene +0.8 EV — sky tones,
        // in the delivered file. 65 knots halves the spacing and trilinear error
        // falls with its square; the bake is once per export, not per frame.
        if toneEngine.isIdentity {
            self.toneGainCubeBaked = nil
        } else {
            // The SAME floor as `toneGainScale`, because the graph multiplies the
            // two back together and they are meaningless except as a pair. This
            // floored at 1e-9 while the scale floored at 1.0 — so a tone curve whose
            // gain is everywhere below 1 (global zones at −1 EV: every sample 0.5)
            // baked a cube of 1.0s, the scale returned 1.0, and the GPU applied no
            // gain while the reference darkened a stop.
            // `testBakedToneCubeTimesScaleEqualsTheGainTable` holds the pair.
            var peak = 1.0
            for v in self.toneGainLUT.samples { peak = Swift.max(peak, v) }
            let lut = self.toneGainLUT
            let cubeSize = lutSize >= LUT3D.exportSize ? LUT3D.exportSize : 32
            let bakeCube = {
                LUT3D(size: cubeSize) { encoded in
                    RGB(gray: lut.evaluate(encoded.r) / peak)
                }
            }
            // Through the cache, like every other expensive table. This was the one
            // that was not: 32 768 samples rebuilt at plan init — during a drag, on
            // every mouse event — and invalidated by exactly the six tone sliders and
            // the zones, which is to say by the controls that are dragged most. The
            // key is complete because `toneEngine` is built from these two subtrees
            // alone, and `peak` is derived from the table they produce.
            let toneKey = PlanTableCache.key(["tonecube", "\(cubeSize)"],
                                             [develop.tone, develop.zones])
            // CACHED, BUT NEVER SERVED STALE — unlike every other table here, and for
            // a reason the comment above already states without following through:
            // the cube and `toneGainScale` "are meaningless except as a pair".
            //
            // The cube stores `gain / peak` and the graph multiplies `toneGainScale`
            // back. `toneGainScale` is not cached; it is recomputed from THIS event's
            // `toneGainLUT`. `tableAllowingStale` returns, by design, the newest table
            // in the slot when this event's key misses — a cube normalized by a
            // PREVIOUS event's peak. So every draft frame of a tone drag computed
            //
            //     oldGain(v) / oldPeak × newPeak
            //
            // instead of `newGain(v)`: the whole picture wrong by `newPeak / oldPeak`,
            // snapping back the moment a background bake landed. Measured on a Blacks
            // drag, the shadows were applying a gain of 0.94 where the table said 1.48.
            // That is the flicker the owner reported once the notching was gone, and it
            // is worst on Contrast and Blacks because those move the peak gain most.
            //
            // Made exact rather than paired-and-cached because it is the cheapest table
            // here by a wide margin — 32³ samples of a 1-D lookup, at or below the
            // noise floor of `PlanCostProbeTests` in a release build, against 15–18 ms
            // for the 33³ finish and colour-grade tables. It still goes through the
            // cache, so dragging a control that is NOT tone hits and pays nothing; only
            // a tone drag pays the bake, and it is a fraction of a millisecond.
            //
            // `testTheToneCubeAndItsScaleStayAPairOnTheDRAFTPath` holds this. Its
            // sibling did not: it built its plan with the default
            // `allowStaleTables: false`, so it only ever exercised the path a drag does
            // not take — the same shape of blind spot as the draft ladder's.
            self.toneGainCubeBaked = toneKey.map {
                PlanTableCache.table(.toneGain, key: $0, size: cubeSize,
                                     build: bakeCube)
            } ?? bakeCube()
        }
    }

    /// One gamut boundary for the whole process — the same object every other stage
    /// uses, so nothing can disagree about where the display gamut is.
    public static var sharedGamutBoundary: Gamut.Boundary { Gamut.sharedBoundary }

    // MARK: - Per-pixel reference

    /// The composed per-pixel colour function, for stages that have no spatial
    /// component. This is what the LUTs approximate — goldens compare the two.
    ///
    /// `space` must be the space the plan was built with, exactly as it must for
    /// `exactColor` — the two are twins and take the parameter the same way. This one
    /// hardcoded rec2020 for the tone stage's luminance while its twin used the
    /// parameter, so on any plan built for another working space the two disagreed
    /// about how bright a saturated colour is before either table was sampled — a
    /// disagreement charged to "interpolation error" in every golden that compares
    /// them.
    public func referenceColor(_ sceneLinear: RGB,
                               space: RGBColorSpace = .rec2020) -> RGB {
        var c = linear.apply(sceneLinear)
        if !toneIsIdentity {
            let lum = Swift.max(space.luminance(c), 0)
            c = c * tone.gain(at: Num.safeLog2(lum / 0.18))
        }
        if !colorGradeIsIdentity {
            c = LumenLog.decode(colorGradeLUT.sample(LumenLog.encode(c)))
        }
        // The finish table already ENDS in display-linear — encode going in, nothing
        // coming out. Decoding here would exponentiate the table's own interpolation
        // error, which is exactly what it did until a golden caught it.
        let encoded = LumenLog.encode(c)
        return finishedColor(encoded: encoded)
    }

    /// The finish table plus the exact gamut flag, which is how both render paths
    /// compose the last stage. Factored out so the reference renderer, the GPU graph's
    /// twin and `referenceColor` all say it once.
    public func finishedColor(encoded: RGB) -> RGB {
        let proofed = finishLUT.sample(encoded) * finishScale
        guard let softProof, softProof.settings.showGamutWarning,
              let plain = finishLUTBeforeProof else { return proofed }
        // The flag is asked of the value BEFORE the proof mapped it, which is the whole
        // reason that table is kept: after the map nothing is out of gamut.
        guard softProof.isOutOfGamut(plain.sample(encoded)) else { return proofed }
        // Denominated relative to display white, like every other display-linear value
        // here, so it scales with the rendition instead of sitting at an absolute level
        // that would be a different grey on an HDR target.
        return SoftProof.warningColor * finishScale
    }

    /// The same function with the LUT stages evaluated exactly rather than sampled —
    /// the f32 reference the LUT's interpolation error is measured against.
    public func exactColor(_ sceneLinear: RGB, space: RGBColorSpace = .rec2020) -> RGB {
        let develop = recipe.develop
        let look = recipe.look
        var c = linear.apply(sceneLinear)
        if !toneIsIdentity {
            let lum = Swift.max(space.luminance(c), 0)
            c = c * tone.gain(at: Num.safeLog2(lum / 0.18))
        }
        let color = ColorEngine(mixer: develop.mixer, pointColors: develop.pointColors,
                                color: develop.color, primaries: look.primaries,
                                bw: look.bw, bandMeanHues: bandMeanHues)
        let grade = GradeEngine(wheels: look.wheels, printerLights: look.printerLights,
                                whiteAnchorEV: tone.whiteAnchorEV,
                                blackAnchorEV: tone.blackAnchorEV)
        c = grade.apply(color.apply(c))
        let formed: RGB
        if let filmChain {
            formed = filmChain.apply(c)
        } else {
            formed = displayTransform.apply(c, gamut: RenderPlan.sharedGamutBoundary)
        }
        let finished = CurveStack(develop.curve).apply(formed, white: displayWhite,
                                                       space: space)
        // The proof belongs here too, in the same place and the same domain the table
        // puts it — this function is the f32 twin the table's interpolation error is
        // measured against, and a twin that skips a stage measures the stage instead of
        // the error.
        guard let softProof else { return finished }
        return softProof.apply(finished / finishScale) * finishScale
    }

    /// The largest gain the tone stage produces, so its cube can be stored normalized.
    public var toneGainScale: Double {
        var peak = 1.0
        for v in toneGainLUT.samples { peak = Swift.max(peak, v) }
        return peak
    }

    /// The tone gain as a cube the stock colour-cube filter can apply against the
    /// log-encoded mask — no custom kernel at all. Normalized by `toneGainScale` for
    /// the same reason the finish table is: a +2 EV shadow lift is a gain of 4, and a
    /// unit-domain table would quietly clip it to 1.
    ///
    /// Built once per plan, not per frame: the cube is a quarter of a million samples
    /// expressing a one-dimensional function, and rebaking it on every render was pure
    /// waste.
    /// A STORED cube, not a `lazy var`.
    ///
    /// It was lazy, which on a struct means a mutating getter — and every consumer
    /// holds the plan as a `let`, so none of them could call it. `RenderGraph.applyTone`
    /// therefore called `toneGainCube()` and rebaked all 32 768 samples on every single
    /// frame, which is exactly the waste the property was added to prevent. Nothing was
    /// wrong with the reasoning; it just could not be reached from where it was needed.
    ///
    /// Built only when the tone stage is live, because that is the only time anything
    /// reads it and an identity plan should not pay for a quarter of a million samples.
    /// 32 knots on an interactive plan, `LUT3D.exportSize` on an export one — the
    /// name stopped carrying the number the day the number started depending on what
    /// the plan is for.
    public let toneGainCubeBaked: LUT3D?

    public func toneGainCube(size: Int = 32) -> LUT3D {
        let scale = toneGainScale
        return LUT3D(size: size) { encoded in
            RGB(gray: toneGainLUT.evaluate(encoded.r) / scale)
        }
    }

    /// True when the whole colour path is a no-op and the renderer can hand the
    /// decoded image straight to the display transform.
    public var isColorIdentity: Bool {
        toneIsIdentity && colorGradeIsIdentity && linear.isIdentity
    }
}
