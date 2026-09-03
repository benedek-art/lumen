// LookSubset.swift
// What a look IS, as a value — and the two operations that take one off a photograph
// and put it onto another.
//
// docs/00 §4 states the rule the whole product is cut along: "Develop makes the file
// true … Look makes the set yours", and then the sentence this file exists to make
// mechanical — "Presets respect the boundary, so a film look never smuggles in
// someone's white balance."
//
// The boundary was already structural in the format (docs/15 §15.4 doctrine 3: "Stage
// tags are structural … per-frame normalization is never dragged along by accident"),
// but nothing had ever expressed it as code that can be wrong. `AppState.copyLook`
// copied `recipe.look` inside a SwiftUI observable object in a target with no tests, so
// the partition was a fact about one line of an untestable file. Here it is a pure
// function over two values, with the partition itself written down as data so a new
// top-level recipe key cannot slip past the decision.
//
// THE PARTITION, and why each side is where it is:
//
//   look        TRAVELS. Grading wheels, printer lights, the Film Lab, primaries, the
//               B&W treatment, vignette, creative grain, the display transform's five
//               overrides, and the (inert) LUT slot. Every one of them is an expression
//               of intent about a set of frames, and each reads a develop-normalized,
//               scene-referred image (docs/14 §3), so it computes the same thing on
//               every frame it lands on.
//
//   look.render.preset
//               TRAVELS ONLY WITHIN A REGISTER — the one field on the travelling side
//               that the paragraph above is not true of. The exception is written out
//               here rather than left inside `applied(to:)` because the sentence it
//               breaks is this file's entire justification, and a reader who believes
//               that sentence will not go looking for a counterexample.
//
//               Four of the five preset names — "Neutral", "Soft", "Punchy", "Film
//               Base" — are curve choices, and those really are intents about a set of
//               frames. The fifth, "Linear", is not a curve at all. docs/04 §6.1 put it
//               there as the escape hatch for a file that has ALREADY been tone-mapped,
//               and `AppState.startingRecipe` writes it onto every JPEG, HEIC and TIFF
//               at ingest for exactly that reason: "a JPEG … is clipped at display
//               white and carries a manufacturer's S-curve. Handing it the default
//               sigmoid applies a SECOND." `RenderedImageSource` says the same thing
//               about the pixels and `WorkspaceSection.nonDefault` a third time. So on
//               a rendered file the preset is not an expression of intent about a set
//               of frames at all; it is a fact about THIS one, of the same kind as its
//               white balance — and a rendered file is the one input to this pipeline
//               that is not scene-referred, which is precisely the property the
//               travelling side is justified by.
//
//               Carrying it whole therefore moves the target between two registers, and
//               the cost is not subtle. Measured through the shipping curve
//               (`DisplayTransform.tone`, neutral preset, white target 100, black
//               0.0152, anchors −9/+5 EV): a RAW-born look landing on a JPEG takes sRGB
//               code value 32 → 13, 48 → 27, 255 → 222 — plugged shadows, and a white
//               that is no longer white. The reverse, a JPEG-born look landing on a
//               RAW, clips everything above +2.47 EV to paper white: two and a half
//               stops of highlight the display transform was holding, gone. It is the
//               same defect the Looks header's Reset had (audit K-027, fixed at
//               `DevelopColumn.swift:596` by re-applying the photograph's own starting
//               render per target), arriving instead through the two doors the feature
//               exists for — Apply Look and Paste Look.
//
//               So the rule is a boundary rather than a ban: the preset travels unless
//               it would carry the frame across the line between tone-mapped and not,
//               and in that case the target keeps its own. "Punchy" still travels RAW
//               to RAW and JPEG to JPEG — every case where the two frames agree about
//               what they are, which is nearly every case, and which is why this went
//               unnoticed. `carriedRenderPreset` is the rule; `applied(to:)` applies it.
//
//   develop     STAYS. White balance is derived from THIS camera's as-shot neutral;
//               exposure and tone are THIS frame's light; geometry is THIS frame's
//               crop; denoise is THIS frame's ISO; the mixer, point colours and the
//               curve are corrective, per docs/14 §3's register table. A look that
//               carried any of them would be the copy-paste-then-fix ritual docs/00
//               names as Lightroom's failure, with the wrong exposure baked in.
//
//   masks       STAY, today, and the reason is not the same as develop's. docs/14 §3
//               and docs/15 §15.4 both say masks declare their own register and that
//               look-tagged ones travel — and `Mask` carries no register field, so
//               there is no such thing as a look-tagged mask to carry (audit FILM-17).
//               Until one exists, "carry the masks" would mean carrying ALL of them,
//               and a mask's geometry is per-frame by construction: a brush component
//               is a stroke blob recorded over one photograph, a radial is a centre in
//               that frame's source coordinates, a linear is a line across it. Moving
//               those to another frame is the same defect as moving a crop.
//
//   pipelineVersion
//               NEITHER. It is carried IN the stored look, because docs/14 §3 defines a
//               named look as "the look-slice of a recipe plus its pipelineVersion" and
//               a reader has to know which vocabulary the slice is written in. It is
//               not applied ONTO the target as-is: see `applied(to:)`.
//
// ONE THING THE DOCUMENTS DISAGREE ABOUT, left alone rather than decided here.
// docs/14 §3's register list puts "printer lights" on the DEVELOP side; docs/15 §15.4's
// recipe format puts `printerLights` inside `look`, which is where `Look` puts it, which
// is where the Look panel draws it, and which is therefore what travels today. Three
// sources against one, so this file follows them — but the odd one out is arguable
// rather than obviously a typo (a printer-light master IS an exposure, and exposure is
// the develop side's own example of what must not travel), and unilaterally editing the
// pipeline document to match the code is how a real design question gets closed by
// whoever touched the file last. It is written down here instead.
//
// Nothing in the Look subtree is conditional here — a look carries the whole struct,
// `lut` included. That is deliberate on two counts. `Recipe.renderIdentity` strips
// `look.lut` because no stage reads it, and that projection is about which recipes
// render the same picture; which fields a photographer's saved look remembers is a
// different question with a different answer. And a LUT is the most look-shaped thing
// there is, so the day a LUT stage lands, looks carry it with no change here and no
// second dead-field decision to unwind.
//
// HOW MUCH OF IT LANDS — `amount`, and why it is a property of the LOOK rather than of
// the photograph.
//
// Every competitor ships one: Lightroom's profile/preset Amount, DxO's intensity,
// darktable's per-module opacity. It is how a film emulation goes from the 100% the
// stock was measured at to the 40% a wedding set can actually take, and Lumen had looks
// with no way to dial one back at all. `SpeedEdit.Parameter.lookAmount` has named the
// control since docs/12 §12.4 was written; this is the field it names.
//
// It is on the SUBSET, not on `Look`, and that is a real limitation rather than a
// preference — see the note on `applied(to:)`. The amount is baked into the parameters
// as the look lands, so no stage reads it and no render path had to learn a new word:
// every engine downstream sees a legitimate, whole Look, which is exactly what
// Lightroom's preset Amount does and the reason it composes with the film chain, the
// grade, the transform and the grain for free.
//
// The rule is one sentence, and it is Lightroom's: MAGNITUDES INTERPOLATE, CATEGORICALS
// LAND WHOLE. A grading wheel's saturation, a printer light, a vignette, a film stock's
// Strength, a band of a B&W mix — all of those are quantities, and 40% of one is a
// meaningful thing to ask for. A stock's NAME is not a quantity; neither is "this frame
// is black and white", nor which display-transform curve is in force. Nothing in the
// Look layer can express half a monochrome conversion or a crossfade between two
// emulsions, so an amount that pretended to would be inventing a rendering the pipeline
// cannot produce. `blended(from:toward:amount:)` is the rule and every field's side of
// it is argued at the line that implements it.

import Foundation

/// `look.kind` — the three registers docs/15 §15.3 declares for the table. Only `look`
/// has a writer today; the other two are named so the column's values are a closed set
/// rather than free text, and so a listing can ask for one register.
public enum LookKind: String, Codable, Sendable, CaseIterable {
    /// The portable creative layer. What "Save Look" writes.
    case look
    /// A develop-side starting point (per-camera defaults, a denoise baseline). No
    /// writer: `LookSubset` carries no develop fields, by the partition above.
    case developPreset = "develop-preset"
    /// Applied automatically at ingest. No writer.
    case importDefault = "import-default"
}

/// The portable slice of a recipe: the Look layer plus the vocabulary version it was
/// written in. Stored as canonical sparse JSON in `look.subset`.
public struct LookSubset: Codable, Equatable, Sendable {
    /// The pipeline version of the recipe this slice was taken from.
    public var pipelineVersion: Int
    public var look: Look
    /// How much of this look lands, 0…100. See the header, and `applied(to:)`.
    ///
    /// The DEFAULT IS FULL, and that is the whole of the migration story: a look saved
    /// before this field existed was saved at full strength, so an absent key has to
    /// read as 100. Reading it as 0 — which is what a `Double` gains by default, and
    /// what every "add a field, forget the decoder" bug in this format would have
    /// produced — would silently un-apply every look in every catalog on first open,
    /// and would do it quietly, because a look that lands as nothing looks exactly like
    /// a look that was never applied.
    public var amount: Double

    public init(pipelineVersion: Int = currentPipelineVersion, look: Look = Look(),
                amount: Double = LookSubset.fullAmount) {
        self.pipelineVersion = pipelineVersion
        self.look = look
        self.amount = amount
    }

    // MARK: - The partition, as data

    /// Top-level recipe keys a look TAKES from the photograph it is saved off.
    ///
    /// TOP-LEVEL is the whole claim. One leaf inside `look` is qualified —
    /// `look.render.preset` travels only within its register, see the header and
    /// `carriedRenderPreset` — and that is not expressible here, because this set
    /// answers "which subtrees" and the preset question is "which of two frames does
    /// this field describe". Written down at both ends rather than at one, so the set
    /// is not read as a promise it does not make.
    public static let carriedRecipeKeys: Set<String> = ["look"]

    /// Top-level recipe keys a look leaves behind. `pipelineVersion` is here because it
    /// is not content: it is copied into the stored look as a stamp, and never written
    /// over the target's own (see `applied(to:)`).
    /// `maskGroups` is here because `masks` is, and for the same reason rather than by
    /// association: a folder is a name for a set of masks, and a look that carried the
    /// folders without the masks would arrive as a column of empty headers. The
    /// partition test is what forced this decision to be made rather than defaulted —
    /// adding the field to `Recipe` and not to one of these two sets fails it by name.
    public static let uncarriedRecipeKeys: Set<String> = [
        "pipelineVersion", "develop", "masks", "maskGroups",
    ]

    // MARK: - Taking a look off a photograph

    /// The look this recipe expresses.
    public static func extracted(from recipe: Recipe) -> LookSubset {
        LookSubset(pipelineVersion: recipe.pipelineVersion, look: recipe.look)
    }

    // MARK: - How much of it lands

    /// The whole look. The default, the value every look saved before `amount` existed
    /// is read at, and the one value at which `applied(to:)` does not blend at all.
    public static let fullAmount: Double = 100

    /// What the slider and the speed edit may ask for. Named here rather than spelled
    /// as a literal at each of the three sites that need it (`LookPanel`'s row,
    /// `SpeedEdit.Parameter.lookAmount.range`, and this file's own clamp), because a
    /// control whose bounds are stated in three places is a control that will one day
    /// be draggable past what the model accepts.
    public static let amountRange: ClosedRange<Double> = 0...100

    /// An amount from anywhere — a slider, a decoder, a hand-edited sidecar — reduced to
    /// one this file will act on.
    ///
    /// A non-finite amount reads as FULL rather than as zero, on the same grounds as the
    /// absent key: every unreadable answer to "how much of this look" has to fail toward
    /// the look being there. `NaN` compares false against every bound, so without this
    /// guard it would slip past a bare `clamp` and then poison every `Num.mix` below it,
    /// turning a whole look into NaN — which renders as black rather than as nothing.
    public static func clampedAmount(_ raw: Double) -> Double {
        guard raw.isFinite else { return LookSubset.fullAmount }
        return Num.clamp(raw, LookSubset.amountRange.lowerBound,
                         LookSubset.amountRange.upperBound)
    }

    /// One look, `amount` percent of the way from another.
    ///
    /// PUBLIC AND SEPARATE FROM `applied(to:)` for the reason `carriedRenderPreset` is:
    /// it is the rule, it is the part that can be wrong in a way no crash reports, and
    /// it has to be assertable on its own. `applied(to:)` is plumbing around it.
    ///
    /// The two ends are EXACT, by early-out and not by arithmetic. 0 returns `own`
    /// untouched and 100 returns `carried` untouched — the same objects, not values that
    /// happen to compare equal — so a look applied at full strength produces the byte
    /// sequence it produced before this field existed and every pinned render in
    /// docs/proof stays pinned. The interior does trigonometry (see `blendedWheel`), and
    /// trigonometry does not round-trip exactly; putting the ends outside it is what
    /// keeps that from costing a fingerprint.
    public static func blended(from own: Look, toward carried: Look,
                               amount raw: Double) -> Look {
        let t = LookSubset.clampedAmount(raw) / LookSubset.fullAmount
        guard t > 0 else { return own }
        guard t < 1 else { return carried }

        // Starting from `carried` rather than from `own` is the categorical half of the
        // rule, applied by construction: anything not touched below — `render.preset`,
        // `lut`, a film stock's name, the B&W treatment's switch — is the look's own,
        // whole, at any amount above zero.
        var out = carried
        out.wheels = LookSubset.blendedWheels(from: own.wheels, toward: carried.wheels, t: t)
        // Printer lights are INTEGER stops on a printer's dial and there is no half
        // stop: the panel steps them, the engine indexes gains by them. Rounded rather
        // than truncated so a light walks toward the look's value from both directions.
        out.printerLights = PrinterLights(
            master: LookSubset.blendedStop(own.printerLights.master,
                                           carried.printerLights.master, t),
            r: LookSubset.blendedStop(own.printerLights.r, carried.printerLights.r, t),
            g: LookSubset.blendedStop(own.printerLights.g, carried.printerLights.g, t),
            b: LookSubset.blendedStop(own.printerLights.b, carried.printerLights.b, t))
        out.primaries = LookSubset.blendedPrimaries(from: own.primaries,
                                                    toward: carried.primaries, t: t)
        out.vignette = Num.mix(own.vignette, carried.vignette, t)
        out.vignetteFeather = Num.mix(own.vignetteFeather, carried.vignetteFeather, t)
        out.filmLab = LookSubset.blendedFilm(from: own.filmLab, toward: carried.filmLab, t: t)
        out.bw = LookSubset.blendedTreatment(from: own.bw, toward: carried.bw, t: t)
        // Through `normalized` for the reason `CreativeGrain` states at length: nil has
        // to be the only spelling of "no creative grain", or a look landing at 1% would
        // write a present-but-default grain block whose picture is identical and whose
        // `recipe_fp` is not — throwing away every preview keyed on the old one.
        out.grain = CreativeGrain.normalized(
            LookSubset.blendedGrain(from: own.grain, toward: carried.grain, t: t))
        out.render = LookSubset.blendedRender(from: own.render, toward: carried.render, t: t)
        return out
    }

    /// A grade, part of the way to another grade.
    ///
    /// Zone geometry — pivots, blending, balance — INTERPOLATES here, where
    /// `GradingWheels.scalingShift` deliberately leaves it alone, and the difference is
    /// not an inconsistency. `scalingShift` scales a delta toward zero, and "where the
    /// zones sit" has no zero to scale toward. This is a walk between two complete
    /// grades, both of which state a geometry, so the only rule that arrives at the
    /// look's own answer at 100 is one that moves every field.
    private static func blendedWheels(from own: GradingWheels, toward carried: GradingWheels,
                                      t: Double) -> GradingWheels {
        var out = carried
        out.global = LookSubset.blendedWheel(from: own.global, toward: carried.global, t: t)
        out.shadows = LookSubset.blendedWheel(from: own.shadows, toward: carried.shadows, t: t)
        out.mid = LookSubset.blendedWheel(from: own.mid, toward: carried.mid, t: t)
        out.high = LookSubset.blendedWheel(from: own.high, toward: carried.high, t: t)
        out.blending = Num.mix(own.blending, carried.blending, t)
        out.balance = Num.mix(own.balance, carried.balance, t)
        // Indexed against the look's own list rather than zipped, so the result always
        // has the shape the look declared even if a hand-edited sidecar handed the
        // target a pivot list of a different length (`RecipeWire.fixedLength` makes that
        // unreachable through the decoder; nothing makes it unreachable through the API).
        out.pivots = carried.pivots.enumerated().map { index, pivot in
            index < own.pivots.count ? Num.mix(own.pivots[index], pivot, t) : pivot
        }
        out.colorBalance = LookSubset.blendedGrid(from: own.colorBalance,
                                                  toward: carried.colorBalance, t: t)
        return out
    }

    /// One wheel, part of the way to another — INTERPOLATED AS A PUCK ON THE DISC, which
    /// is the only reading of a grading wheel that does not change the colour as the
    /// amount comes down.
    ///
    /// `GradingWheels.scalingShift` records the finding this is built on: "scaling
    /// [hue] would rotate the grade toward red as the mask weakened rather than weaken
    /// it, so a mask at 50% would be a different colour rather than half as much of the
    /// same one." Interpolating the hue ANGLE toward the target's reproduces that defect
    /// exactly — a warm shadow at hue 18° landing on an ungraded frame at 40% would come
    /// out at 7.2°, a different tint rather than a weaker one — and it is the obvious
    /// implementation, which is why it is argued against here rather than left for
    /// somebody to discover in a print.
    ///
    /// So the pair (hue, sat) is treated as what the control actually is: a position on
    /// a disc, in polar coordinates. A puck slides in a straight line from where the
    /// frame's grade sits to where the look puts it. Through the origin — the case that
    /// matters, an ungraded target — that line holds the hue exactly and scales the
    /// radius, which is `scalingShift`'s answer arrived at rather than special-cased.
    /// `lum` is a signed magnitude on its own axis and simply interpolates.
    private static func blendedWheel(from own: Wheel, toward carried: Wheel,
                                     t: Double) -> Wheel {
        let ownRadians = own.hue * .pi / 180
        let carriedRadians = carried.hue * .pi / 180
        let x = Num.mix(own.sat * cos(ownRadians), carried.sat * cos(carriedRadians), t)
        let y = Num.mix(own.sat * sin(ownRadians), carried.sat * sin(carriedRadians), t)
        let sat = (x * x + y * y).squareRoot()
        // A puck at the centre has no direction, and `isNeutral` reads sat and lum
        // only, so the angle is free. It keeps the look's rather than falling to zero,
        // which would silently rewrite a stored hue to red on the way through.
        let hue = sat > 0 ? LookSubset.wrappedHue(atan2(y, x) * 180 / .pi) : carried.hue
        return Wheel(hue: hue, sat: sat, lum: Num.mix(own.lum, carried.lum, t))
    }

    /// `Num.wrapHue` with its top end actually closed.
    ///
    /// `wrapHue` is `remainder`-then-`+360`, so ANY input in the last few ulps below
    /// zero comes back as exactly 360: `-5.7e-14 + 360` has no representable neighbour
    /// short of 360 and rounds to it. That input is not hypothetical here, it is the
    /// commonest interesting case — two grades on opposite sides of red, 350° and 10°,
    /// meet at a puck whose `atan2` is zero to within a rounding error, and the sign of
    /// that error is not something the caller gets to choose. Half of the time the walk
    /// between two neighbouring tints reports 360°.
    ///
    /// Which is the SAME COLOUR, and that is exactly why it is worth folding rather than
    /// leaving: nothing renders differently, so nothing would ever surface it, while
    /// `Wheel(hue: 360)` and `Wheel(hue: 0)` serialize to different canonical text and
    /// therefore to different `recipe_fp` values. Two applications of one look at one
    /// amount would key two cache entries and pin two proof records, decided by a
    /// floating-point sign. It also puts a number outside the picker's own 0..<360 into
    /// the recipe, which no wheel control can produce or display.
    ///
    /// Folded here rather than in `Num.wrapHue` because that function has twenty other
    /// callers across the colour engine and its boundary is their business to change,
    /// not this file's — see this pass's report.
    private static func wrappedHue(_ degrees: Double) -> Double {
        let wrapped = Num.wrapHue(degrees)
        return wrapped >= 360 ? 0 : wrapped
    }

    /// The advanced grid, interpolated field by field — `hueShift` included.
    ///
    /// That hue moves where a wheel's does not, for the reason `ColorBalanceParams
    /// .scaled` gives: this one IS the magnitude ("rotating by 0° is the identity"),
    /// where a wheel's hue is the direction of a magnitude called `sat`.
    private static func blendedGrid(from own: ColorBalanceParams,
                                    toward carried: ColorBalanceParams,
                                    t: Double) -> ColorBalanceParams {
        func axis(_ o: ColorBalanceAxis, _ c: ColorBalanceAxis) -> ColorBalanceAxis {
            ColorBalanceAxis(global: Num.mix(o.global, c.global, t),
                             shadows: Num.mix(o.shadows, c.shadows, t),
                             mid: Num.mix(o.mid, c.mid, t),
                             high: Num.mix(o.high, c.high, t))
        }
        return ColorBalanceParams(hueShift: Num.mix(own.hueShift, carried.hueShift, t),
                                  vibrance: Num.mix(own.vibrance, carried.vibrance, t),
                                  chroma: axis(own.chroma, carried.chroma),
                                  saturation: axis(own.saturation, carried.saturation),
                                  brilliance: axis(own.brilliance, carried.brilliance))
    }

    /// The primary remap — eight numbers, every one of them a magnitude at zero when it
    /// is doing nothing, so every one of them interpolates.
    private static func blendedPrimaries(from own: Primaries, toward carried: Primaries,
                                         t: Double) -> Primaries {
        Primaries(rHue: Num.mix(own.rHue, carried.rHue, t),
                  rPurity: Num.mix(own.rPurity, carried.rPurity, t),
                  gHue: Num.mix(own.gHue, carried.gHue, t),
                  gPurity: Num.mix(own.gPurity, carried.gPurity, t),
                  bHue: Num.mix(own.bHue, carried.bHue, t),
                  bPurity: Num.mix(own.bPurity, carried.bPurity, t),
                  tintHue: Num.mix(own.tintHue, carried.tintHue, t),
                  tintPurity: Num.mix(own.tintPurity, carried.tintPurity, t))
    }

    /// A printer light, which is a whole stop or it is nothing.
    private static func blendedStop(_ own: Int, _ carried: Int, _ t: Double) -> Int {
        Int(Num.mix(Double(own), Double(carried), t).rounded())
    }

    /// The film chain, part of the way.
    ///
    /// THE STOCK IS THE CATEGORICAL and Strength is the magnitude, which is what makes
    /// this the easy case rather than the hard one: `FilmLab.amount` is already "0…100
    /// blend with the neutral rendering", so a look carrying Portra at Strength 84,
    /// landing at 40%, is Portra at Strength 33.6 — a picture the chain has always been
    /// able to render, on a control the photographer can see move.
    ///
    /// TWO DIFFERENT EMULSIONS DO NOT CROSSFADE. There is one film stage and it loads
    /// one stock; a target already wearing Tri-X, handed a Portra look at 40%, gets
    /// Portra at Strength 40% of the look's — not a chemistry that does not exist. The
    /// jump is real and it is stated rather than smoothed, because the alternative is a
    /// picture no combination of controls in the app could reproduce.
    ///
    /// `halationSize`, `halationRedness` and `printSize` follow the look whole. All
    /// three are optional, and nil there means "the emulsion's own measured value" —
    /// which is not a number this file can name (it lives on `FilmStock`), so
    /// interpolating through it would mean inventing one and then PINNING it into the
    /// recipe, exactly the wire-format cost `FilmLab` argues against at each of them.
    private static func blendedFilm(from own: FilmLab?, toward carried: FilmLab?,
                                    t: Double) -> FilmLab? {
        guard var out = carried else {
            // The look says no film. Fade the frame's own out by Strength rather than
            // dropping it at the first percent, so the picture walks: at 100 the
            // early-out in `blended` has already returned the look's nil.
            guard var fading = own else { return nil }
            fading.amount = Num.mix(fading.amount, 0, t)
            return fading
        }
        // Only the SAME stock's numbers are a baseline to walk from; a different one's
        // Strength describes a different chemistry, and its exposure and push are in
        // that stock's latitude, not this one's.
        let base = own?.stock == out.stock ? own : nil
        out.amount = Num.mix(base?.amount ?? 0, out.amount, t)
        out.exposure = Num.mix(base?.exposure ?? 0, out.exposure, t)
        out.pushPull = Num.mix(base?.pushPull ?? 0, out.pushPull, t)
        out.halation = Num.mix(base?.halation ?? 0, out.halation, t)
        // Grain SIZE is a pitch, not a strength — it says how big the crystals are, and
        // there is no "less big", which is the same split `GrainPlan` makes between the
        // two fields. It walks only between two statements of it, and a frame with no
        // stock of its own makes no such statement, so there the look's size stands and
        // Amount alone does the fading.
        let baseSize = base?.grain.size ?? out.grain.size
        out.grain = FilmGrain(size: Num.mix(baseSize, out.grain.size, t),
                              amount: Num.mix(base?.grain.amount ?? 0, out.grain.amount, t))
        return out
    }

    /// The black-and-white treatment, part of the way — and THE ONE PART OF A LOOK THIS
    /// AMOUNT CANNOT DIAL.
    ///
    /// `BlackAndWhite` is an eight-band mix plus a switch. The mix is a set of
    /// magnitudes and interpolates; the switch is the question "is this frame
    /// monochrome", and nothing in the Look layer can answer it halfway — there is no
    /// partial-conversion control, and `develop.color.saturation`, which could fake one,
    /// is on the side of the partition that does not travel. So the look's treatment
    /// lands whole at any amount above zero and its MIX comes up from the frame's own
    /// (or from flat, where the frame has none). A look that says colour makes the frame
    /// colour, for the same reason and in the same direction.
    ///
    /// This is Lightroom's behaviour for Treatment under a preset Amount, arrived at for
    /// the same reason rather than copied: a boolean has no 40%.
    private static func blendedTreatment(from own: BlackAndWhite?, toward carried: BlackAndWhite?,
                                         t: Double) -> BlackAndWhite? {
        guard var out = carried else { return nil }
        let base = own?.bands ?? []
        let landing = out.bands
        out.bands = landing.enumerated().map { index, band in
            Num.mix(index < base.count ? base[index] : 0, band, t)
        }
        return out
    }

    /// Creative grain, part of the way.
    ///
    /// The baseline for a frame that has never been grained is `CreativeGrain()` —
    /// amount 0, size 50, roughness 50 — and that is exactly right rather than
    /// convenient: its own decoder argues that the middle of the two texture axes is
    /// what "no opinion" means, so a look's grain fades in at its own size and roughness
    /// walking out of the middle, rather than out of the finest possible grain with the
    /// smoothest possible plate.
    private static func blendedGrain(from own: CreativeGrain?, toward carried: CreativeGrain?,
                                     t: Double) -> CreativeGrain? {
        guard let carried else {
            guard var fading = own else { return nil }
            fading.amount = Num.mix(fading.amount, 0, t)
            return fading
        }
        let base = own ?? CreativeGrain()
        return CreativeGrain(amount: Num.mix(base.amount, carried.amount, t),
                             size: Num.mix(base.size, carried.size, t),
                             roughness: Num.mix(base.roughness, carried.roughness, t))
    }

    /// The display transform, part of the way — which is mostly "not at all", and the
    /// reason is the same argument `applied(to:)` already makes about this struct.
    ///
    /// `preset` names a KIND OF RENDERING, not a quantity, and it is additionally the
    /// one field in the whole look with a register rule of its own; it lands whole and
    /// `applied(to:)` then puts it through `carriedRenderPreset` exactly as it does at
    /// full strength. The five overrides interpolate ONLY where both sides state one.
    /// Where either side is nil the look's answer is taken whole, because nil is not a
    /// number — it means "follow whatever the preset says", a value that lives in
    /// `DisplayTransformParams.preset(named:)` and changes if a preset is ever retuned.
    /// Resolving it here to interpolate through would write all five overrides into the
    /// recipe and pin this build's tuning of the preset forever, which is precisely what
    /// `RenderParams` keeps them optional to avoid.
    private static func blendedRender(from own: RenderParams, toward carried: RenderParams,
                                      t: Double) -> RenderParams {
        func override(_ mine: Double?, _ theirs: Double?) -> Double? {
            guard let mine, let theirs else { return theirs }
            return Num.mix(mine, theirs, t)
        }
        var out = carried
        out.contrast = override(own.contrast, carried.contrast)
        out.skew = override(own.skew, carried.skew)
        out.huePreservation = override(own.huePreservation, carried.huePreservation)
        out.blackTarget = override(own.blackTarget, carried.blackTarget)
        out.whiteTarget = override(own.whiteTarget, carried.whiteTarget)
        return out
    }

    // MARK: - Putting it onto another

    /// The preset name that means "this frame has already been tone-mapped once",
    /// spelled once here because three modules have to agree about the string and two
    /// of them (`AppState.startingRecipe`, `DisplayTransformParams.preset(named:)`) are
    /// not visible from this one.
    ///
    /// Anything that is NOT this name is treated as a tone-mapping preset, which is the
    /// same reading `DisplayTransformParams.preset(named:)` gives — its `default:` case
    /// resolves an unrecognised name to Neutral. So a preset written by a later build
    /// is a curve, not a second escape hatch, and it travels. That is the conservative
    /// answer for an unknown name: mistaking a curve for a curve costs a different
    /// grade, mistaking an escape hatch for a curve costs a second tone map.
    public static let linearPresetName = "Linear"

    /// Which preset a frame ends up on when a look carrying `carried` lands on a frame
    /// currently sitting on `own`. The header explains why the answer is not simply
    /// `carried`.
    ///
    /// It reads the TARGET RECIPE's preset rather than the target photograph's format,
    /// because a `Recipe` records no format and this is a pure function over two values
    /// — which is the property that makes the rule testable at all, and the reason it
    /// is here rather than in the view layer where it started. The recipe's preset is
    /// the format's own statement in the first place: `AppState.startingRecipe` writes
    /// "Linear" onto every rendered file at ingest, and nothing else writes it unless
    /// the photographer picks it.
    ///
    /// The two readings differ in exactly one case — a RAW the photographer deliberately
    /// parked on Linear to inspect the data — and there this rule is the conservative
    /// one: that frame keeps Linear, and a look cannot pull it off. A look that silently
    /// took a frame off the honesty control would be the same class of surprise in the
    /// other direction, and the preset picker is the affordance for changing registers
    /// on purpose. No look moves a frame across the boundary, either way.
    ///
    /// Public and named because it is a RULE, not an implementation detail: `applied(to:)`
    /// is not the only door a look comes through — `AppState.pasteLook` assigns
    /// `recipe.look` directly — and a second copy of this decision written at the other
    /// call site is how the two drift apart.
    public static func carriedRenderPreset(_ carried: String, onto own: String) -> String {
        let carriedIsRendered = carried == LookSubset.linearPresetName
        let ownIsRendered = own == LookSubset.linearPresetName
        return carriedIsRendered == ownIsRendered ? carried : own
    }

    /// This look applied to one recipe: the Look layer replaced whole — save for the one
    /// leaf in it that describes the target rather than the look — with develop and
    /// masks untouched.
    ///
    /// The version is raised, never lowered, and never simply overwritten. Lowering it
    /// would stamp a v1 vocabulary onto a recipe whose develop layer is written in v2 —
    /// a claim about the whole document made by a slice that only speaks for part of
    /// it. Leaving it alone is wrong in the other direction: a v2 look can express
    /// "black and white, off, mix kept" (`look.bw.enabled == false`), which a v1 reader
    /// renders as black and white, so a recipe that has just been handed one has to say
    /// v2 or it lies about what it holds. `max` is the only rule that is right at both
    /// ends, and it is safe because no version-1 recipe renders differently under
    /// version 2 (see `currentPipelineVersion`).
    ///
    /// `render`'s five OVERRIDES — contrast, skew, huePreservation, blackTarget,
    /// whiteTarget — travel unconditionally and are deliberately NOT part of the preset
    /// exception. Each is a number the photographer dialled on top of whatever curve is
    /// in force, each means the same thing under every preset, and none of them names a
    /// register: `blackTarget` and `whiteTarget` are display targets in % of SDR white,
    /// true of the screen rather than of the file, and `contrast`, `skew` and
    /// `huePreservation` shape a curve that a rendered frame simply does not run. A look
    /// that dropped them would apply a different picture than it saved, which is the
    /// same argument `vignetteFeather` and `grain` are carried under. Only `preset`
    /// answers "what kind of file is this", so only `preset` is guarded.
    ///
    /// `applied(toAll:)` needs no rule of its own for any of this. The decision is taken
    /// against each target recipe, so a selection mixing RAWs with delivered JPEGs — a
    /// real job, and the case that makes this worth guarding rather than a curiosity —
    /// gets the right answer per frame for free.
    ///
    /// `amount` DECIDES HOW MUCH OF IT ARRIVES, and it is spent here rather than read
    /// by a stage. The look is interpolated onto the target's own before it is written,
    /// so what lands in `recipe.look` is a whole, ordinary Look that every engine
    /// downstream already knows how to render. Nothing in `RenderPlan`, `RenderGraph`,
    /// `DisplayTransform` or `PipelineRenderer` learns a new word, no plan cache key
    /// grows a term it could forget, and `Recipe.renderIdentity` keeps meaning exactly
    /// what it meant.
    ///
    /// The two ends are exact and deliberately so. 100 takes the same three lines this
    /// function has always been, so a look applied at full strength writes the bytes it
    /// wrote before the field existed — no fingerprint moves and no pinned render in
    /// docs/proof is re-baked. 0 returns the target UNTOUCHED, version included: a look
    /// that lands as nothing has put nothing into the recipe, so there is no v2
    /// vocabulary in it to declare, and "apply at 0" reads as the no-op a photographer
    /// dragging a slider to the bottom expects rather than as a history step that
    /// silently restamps the document.
    ///
    /// WHAT THIS SHAPE COSTS, said out loud because it is the feature's real boundary:
    /// the amount is spent at the moment of applying and is not kept on the photograph,
    /// so it cannot be dialled afterwards the way Film Lab Strength can. Re-applying the
    /// same look at a second amount COMPOUNDS — 40% onto a frame already at 40% is 64%
    /// of the way, not 40% — because the second apply walks from where the first left
    /// the frame. Undo then re-apply is the honest gesture, and it is the same one
    /// Lightroom's preset Amount needs once the preset row loses focus. A live,
    /// re-draggable amount is a field on `Look` read by the engine, which is a different
    /// and much larger change: `SpeedEdit.Parameter.lookAmount` is waiting on it.
    public func applied(to recipe: Recipe) -> Recipe {
        let strength = LookSubset.clampedAmount(amount)
        guard strength > 0 else { return recipe }
        var copy = recipe
        copy.look = strength >= LookSubset.fullAmount
            ? look
            : LookSubset.blended(from: recipe.look, toward: look, amount: strength)
        copy.look.render.preset = LookSubset.carriedRenderPreset(look.render.preset,
                                                                 onto: recipe.look.render.preset)
        copy.pipelineVersion = max(recipe.pipelineVersion, pipelineVersion)
        return copy
    }

    /// This look applied across a selection.
    ///
    /// Spelled out rather than left to the call site's `map`, because "apply to the
    /// selection" is the gesture the split exists for — one look across 800 frames —
    /// and the property worth pinning is about the whole set: every frame ends up
    /// expressing the same look while keeping its own normalization. A `map` in a view
    /// cannot be asserted; this can.
    ///
    /// "The same look" is exact for a selection of one kind of file and has one stated
    /// exception for a mixed one: a rendered frame keeps its own `render.preset`, per
    /// `applied(to:)`. That is not a weaker promise, it is the promise — a selection
    /// dropped on a shoot folder holds the RAWs and the delivered JPEGs together, and
    /// "the same look" cannot mean "the same tone-mapping register" for files that
    /// arrive in different ones.
    public func applied(toAll recipes: [Recipe]) -> [Recipe] {
        recipes.map(applied(to:))
    }

    // MARK: - Names

    /// The name a look is stored under, or nil if the string is not a name.
    ///
    /// Trimmed, because " Portra warm " and "Portra warm" are the same look to the
    /// person typing and two rows to SQLite; collapsed internally so tab-pasted names
    /// do not sort strangely; length-capped so a paste accident cannot put a paragraph
    /// in the browser. Empty is nil rather than an error string, so the save button has
    /// something to disable itself on.
    public static func normalizedName(_ raw: String) -> String? {
        let collapsed = raw
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        if collapsed.isEmpty { return nil }
        if collapsed.count <= LookSubset.maximumNameLength { return collapsed }
        return String(collapsed.prefix(LookSubset.maximumNameLength))
    }

    public static let maximumNameLength = 120

    private enum CodingKeys: String, CodingKey {
        case pipelineVersion, look, amount
    }

    /// Tolerant of a recipe written before any of these keys existed: each falls
    /// back to the default in the memberwise initializer above. See RecipeDecoding.swift.
    ///
    /// `amount`'s fallback is `fullAmount`, and it is the one in this decoder that would
    /// destroy work if it were wrong. Every look in every catalog predates the key, so
    /// the absent case is not an edge — it is all of them — and a fallback of zero would
    /// read each of them as a look that lands as nothing. It is clamped on the way in as
    /// well: this is the door a hand-edited sidecar comes through, and `blended` runs
    /// `Num.mix` over forty fields with whatever arrives here.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.pipelineVersion = try c.decodeIfPresent(Int.self, forKey: .pipelineVersion)
            ?? currentPipelineVersion
        self.look = try c.decodeIfPresent(Look.self, forKey: .look) ?? Look()
        self.amount = LookSubset.clampedAmount(
            try c.decodeIfPresent(Double.self, forKey: .amount) ?? LookSubset.fullAmount)
    }
}
