// LookAmountTests.swift
// Look Amount: the control that dials a saved look back from the 100% a film stock was
// measured at to the 40% a set can actually take.
//
// Every competitor has one — Lightroom's preset/profile Amount, DxO's intensity,
// darktable's per-module opacity — and Lumen had looks that could only be applied or not
// applied. `SpeedEdit.Parameter.lookAmount` had named the control, given it a title, a
// range and the `K` key since docs/12 §12.4 was transcribed, against a field that did not
// exist anywhere in the model.
//
// FOUR THINGS CAN GO WRONG HERE and three of them are silent:
//
//   1. THE DEFAULT DOES NOT ROUND-TRIP. A new `Double` on a `Codable` struct decodes to
//      zero unless somebody says otherwise, and every saved look in every catalog
//      predates this key — so the absent case is not an edge, it is all of them. A
//      fallback of zero reads each of them as a look that lands as nothing, and a look
//      that lands as nothing is indistinguishable on screen from a look that was never
//      applied. `testALookSavedBeforeTheAmountExistedIsStillFullyApplied` is the pin.
//
//   2. FULL STRENGTH STOPS BEING WHAT IT WAS. If applying at 100 goes through the
//      interpolator rather than around it, every pinned render in docs/proof and every
//      `recipe_fp` in every catalog moves — for a feature nobody used yet. The
//      interpolator does trigonometry (see `LookSubset.blendedWheel`) and trigonometry
//      does not round-trip exactly, so this is not theoretical: it is why both ends of
//      `blended` are early-outs rather than arithmetic.
//
//   3. THE AMOUNT ROTATES THE GRADE INSTEAD OF WEAKENING IT. `GradingWheels
//      .scalingShift` already records this finding for a mask's Amount — "a mask at 50%
//      would be a different colour rather than half as much of the same one" — and the
//      obvious implementation of a look Amount reproduces it exactly, one struct up.
//
//   4. A CATEGORICAL GETS INTERPOLATED. There is one film stage and it loads one stock;
//      `BlackAndWhite` is a mix and a switch. Half a monochrome conversion and a
//      crossfade between two emulsions are both pictures this pipeline cannot produce,
//      so an Amount that appeared to offer them would be describing a rendering that
//      does not exist.
//
// The fifth thing, which is not a defect but a boundary, is pinned too: the amount is
// spent AS the look lands, so it is not a control on the photograph and re-applying
// compounds. That is asserted rather than left in a doc comment, because the day someone
// makes it live the assertion is what tells them the old promise changed.

import XCTest
@testable import LumenCore

final class LookAmountTests: XCTestCase {

    // MARK: - Fixtures

    /// A photograph that has already been worked on: its own grade, its own film stock,
    /// its own transform. The interesting target, because a blend onto a DEFAULT look is
    /// the easy half — it reduces to scaling — and the half that hides sign errors.
    private static func gradedTarget() -> Recipe {
        var recipe = Recipe(develop: SavedLookTests.loadedDevelop())
        recipe.look.wheels.shadows = Wheel(hue: 200, sat: 0.20, lum: 0.10)
        recipe.look.wheels.blending = 20
        recipe.look.printerLights = PrinterLights(master: -2, r: 4, g: 0, b: -6)
        recipe.look.primaries = Primaries(rHue: -10, rPurity: 20)
        recipe.look.vignette = 1.0
        recipe.look.vignetteFeather = 20
        recipe.look.filmLab = FilmLab(stock: "lumen/trix400", amount: 60)
        recipe.look.grain = CreativeGrain(amount: 10, size: 20, roughness: 80)
        recipe.look.render = RenderParams(preset: "Soft", contrast: 0.5)
        return recipe
    }

    private static func subset(_ look: Look, amount: Double) -> LookSubset {
        LookSubset(pipelineVersion: currentPipelineVersion, look: look, amount: amount)
    }

    // MARK: - 1. The default round-trips

    /// THE TRAP THIS WHOLE FILE EXISTS FOR. Every look in every catalog was written
    /// before `amount` did, so the absent key is the ONLY case that exists today. It has
    /// to read as the full look.
    ///
    /// Both doors are checked. `CanonicalJSON.decodeLookSubset` merges a defaults tree
    /// under the sparse text and would paper over a decoder that read the key wrongly;
    /// a bare `JSONDecoder` reaches `LookSubset.init(from:)` directly. A fix that only
    /// held on one of them would hold for the catalog and fail for anything that decoded
    /// a look the plain way.
    func testALookSavedBeforeTheAmountExistedIsStillFullyApplied() throws {
        let stored = """
        {"pipelineVersion":2,"look":{"vignette":-0.6,"printerLights":{"master":3}}}
        """
        let merged = try CanonicalJSON.decodeLookSubset(from: Data(stored.utf8))
        XCTAssertEqual(merged.amount, LookSubset.fullAmount,
                       "a look stored before Amount existed decoded as landing "
                       + "\(merged.amount)% of itself — every saved look in every "
                       + "catalog is this case, so the whole library would come back "
                       + "applying nothing")

        let direct = try JSONDecoder().decode(LookSubset.self, from: Data(stored.utf8))
        XCTAssertEqual(direct.amount, LookSubset.fullAmount,
                       "the sparse decoder's defaults tree is hiding a decoder that "
                       + "reads an absent amount as zero")

        // And it is not merely the number: the look really does arrive whole.
        let landed = merged.applied(to: Recipe())
        XCTAssertEqual(landed.look.vignette, -0.6)
        XCTAssertEqual(landed.look.printerLights.master, 3)
    }

    /// A default `LookSubset` says full, so the memberwise initializer and the decoder
    /// agree — which is what `CanonicalJSON.sparse` diffs against, and therefore what
    /// keeps the key off the wire entirely.
    func testTheDefaultAmountIsFullAndCostsTheWireNothing() throws {
        XCTAssertEqual(LookSubset().amount, LookSubset.fullAmount)
        XCTAssertEqual(LookSubset.extracted(from: Recipe(look: SavedLookTests.loadedLook()))
                        .amount, LookSubset.fullAmount,
                       "a look taken off a photograph is that photograph's look, whole; "
                       + "saving one at less than full strength would store a look "
                       + "nobody could ever get the rest of")

        let full = LookSubset.extracted(from: Recipe(look: SavedLookTests.loadedLook()))
        let text = try CanonicalJSON.canonicalLookJSON(full)
        XCTAssertFalse(text.contains("\"amount\":100"),
                       "a full-strength look now writes an amount key it did not write "
                       + "before, so every look in every catalog re-serializes and the "
                       + "text a look is compared and keyed by changes for no reason")

        var dialled = full
        dialled.amount = 40
        let dialledText = try CanonicalJSON.canonicalLookJSON(dialled)
        XCTAssertTrue(dialledText.contains("\"amount\":40"),
                      "a look stored at 40% did not record it, so it comes back at 100")
        XCTAssertEqual(try CanonicalJSON.decodeLookSubset(from: Data(dialledText.utf8))
                        .amount, 40)
    }

    // MARK: - 2. Full strength is bit-identical to having no amount at all

    /// The rule `applied(to:)` has always been, written out here so the assertion is
    /// against the SHIPPED behaviour rather than against the new code's own answer.
    private static func appliedTheOldWay(_ subset: LookSubset, to recipe: Recipe) -> Recipe {
        var copy = recipe
        copy.look = subset.look
        copy.look.render.preset =
            LookSubset.carriedRenderPreset(subset.look.render.preset,
                                           onto: recipe.look.render.preset)
        copy.pipelineVersion = max(recipe.pipelineVersion, subset.pipelineVersion)
        return copy
    }

    /// Compared as CANONICAL TEXT, not just as values. The text is what gets
    /// fingerprinted into `edit.recipe` and what every preview and artifact in the
    /// catalog is keyed by, so equality of the strings is the actual claim: no stored
    /// render moves, no proof record is re-baked, nothing in docs/proof needs re-pinning.
    func testApplyingAtFullStrengthIsExactlyTheRuleThatShippedWithoutAnAmount() throws {
        let fixture = SavedLookTests.loadedLook()
        for target in [Recipe(), Self.gradedTarget(),
                       Recipe(pipelineVersion: 1)] {
            let subset = Self.subset(fixture, amount: LookSubset.fullAmount)
            let now = subset.applied(to: target)
            let before = Self.appliedTheOldWay(subset, to: target)
            XCTAssertEqual(try CanonicalJSON.canonicalRecipeJSON(now),
                           try CanonicalJSON.canonicalRecipeJSON(before),
                           "a look applied at full strength no longer writes the bytes "
                           + "it wrote before Amount existed: every recipe fingerprint "
                           + "in every catalog moves, every cached preview is thrown "
                           + "away, and every pinned render in docs/proof has to be "
                           + "re-baked — for a control nobody has touched")
            XCTAssertEqual(now, before)
        }
    }

    /// The other end, and the reason it is an early-out rather than `mix(x, y, 0)`:
    /// nothing of the look landed, so there is no newer vocabulary in the document to
    /// declare either. A version bump on an untouched recipe is a claim about a slice
    /// that never arrived.
    func testApplyingAtZeroLeavesTheRecipeCompletelyUntouched() {
        let target = Self.gradedTarget()
        let subset = LookSubset(pipelineVersion: 99,
                                look: SavedLookTests.loadedLook(), amount: 0)
        XCTAssertEqual(subset.applied(to: target), target,
                       "a look applied at 0% changed the photograph")
        XCTAssertEqual(subset.applied(to: target).pipelineVersion, target.pipelineVersion,
                       "a look that landed as nothing restamped the document's version")
    }

    // MARK: - 3. Magnitudes interpolate

    func testEveryMagnitudeInALookLandsAtTheFractionAsked() throws {
        let fixture = SavedLookTests.loadedLook()
        let landed = Self.subset(fixture, amount: 40).applied(to: Recipe())
        let look = landed.look
        let base = Look()

        XCTAssertEqual(look.vignette, base.vignette + (fixture.vignette - base.vignette) * 0.4,
                       accuracy: 1e-12, "the vignette did not scale")
        XCTAssertEqual(look.vignetteFeather,
                       base.vignetteFeather
                        + (fixture.vignetteFeather - base.vignetteFeather) * 0.4,
                       accuracy: 1e-12)
        XCTAssertEqual(look.wheels.shadows.sat, fixture.wheels.shadows.sat * 0.4,
                       accuracy: 1e-12, "a grading wheel did not weaken")
        XCTAssertEqual(look.wheels.shadows.lum, fixture.wheels.shadows.lum * 0.4,
                       accuracy: 1e-12)
        XCTAssertEqual(look.wheels.colorBalance.brilliance.shadows,
                       fixture.wheels.colorBalance.brilliance.shadows * 0.4,
                       accuracy: 1e-12, "the advanced grid did not weaken")
        XCTAssertEqual(look.wheels.colorBalance.hueShift,
                       fixture.wheels.colorBalance.hueShift * 0.4, accuracy: 1e-12,
                       "the grid's master rotation IS the magnitude there — see "
                       + "ColorBalanceParams.scaled — so half a look is half the turn")
        XCTAssertEqual(look.primaries.rHue, fixture.primaries.rHue * 0.4, accuracy: 1e-12)
        XCTAssertEqual(look.printerLights.b,
                       Int((Double(fixture.printerLights.b) * 0.4).rounded()),
                       "a printer light is a whole stop and did not round to one")
        XCTAssertEqual(try XCTUnwrap(look.filmLab?.amount),
                       try XCTUnwrap(fixture.filmLab?.amount) * 0.4, accuracy: 1e-12,
                       "Film Lab Strength is the stock's own magnitude and is exactly "
                       + "where a look's Amount belongs")
        XCTAssertEqual(try XCTUnwrap(look.grain?.amount),
                       try XCTUnwrap(fixture.grain?.amount) * 0.4, accuracy: 1e-12)
    }

    /// The B&W mix is eight magnitudes and comes up from flat; the treatment itself is
    /// not (see the categorical test below).
    func testTheBlackAndWhiteMixComesUpFromFlatRatherThanLandingWhole() throws {
        let mix = BlackAndWhite(bands: [10, -20, 30, -40, 5, 15, -25, 35], enabled: true)
        let landed = Self.subset(Look(bw: mix), amount: 25).applied(to: Recipe())
        let bands = try XCTUnwrap(landed.look.bw?.bands)
        XCTAssertEqual(bands, mix.bands.map { $0 * 0.25 },
                       "the mix landed at full strength, so Amount does nothing to a "
                       + "black-and-white look but flip it monochrome")
    }

    /// Continuity, over the whole travel and over a target that is not at its defaults.
    /// A blend that is right at the ends and wrong in the middle is the failure that a
    /// two-point test cannot see.
    func testTheAmountWalksMonotonicallyFromTheFrameToTheLook() {
        let target = Self.gradedTarget()
        let look = SavedLookTests.loadedLook()
        var previous = target.look.vignette
        // The fixture's vignette is below the target's, so the walk is downward.
        XCTAssertLessThan(look.vignette, target.look.vignette)
        for step in stride(from: 0.0, through: 100.0, by: 5) {
            let landed = Self.subset(look, amount: step).applied(to: target)
            XCTAssertLessThanOrEqual(landed.look.vignette, previous + 1e-12,
                                     "the vignette went back up between \(step - 5)% "
                                     + "and \(step)%: the blend is not a walk")
            previous = landed.look.vignette
        }
        XCTAssertEqual(previous, look.vignette, accuracy: 1e-12,
                       "the walk did not arrive at the look")
    }

    // MARK: - 4. A weakened grade is the same colour

    /// `GradingWheels.scalingShift`'s finding, one struct up: interpolating the hue
    /// ANGLE toward the look's rotates the grade as it weakens instead of weakening it,
    /// so a warm shadow at 18° landing at 40% would come out at 7.2° — a different tint,
    /// not less of the same one. The wheel is a puck on a disc and is interpolated as
    /// one, which through the origin holds the angle exactly.
    func testWeakeningAGradeDoesNotRotateIt() {
        let look = Look(wheels: GradingWheels(shadows: Wheel(hue: 18, sat: 0.5, lum: 0.2)))
        for amount in [5.0, 25, 40, 60, 99] {
            let landed = Self.subset(look, amount: amount).applied(to: Recipe())
            XCTAssertEqual(landed.look.wheels.shadows.hue, 18, accuracy: 1e-9,
                           "at \(amount)% the shadow grade has rotated to "
                           + "\(landed.look.wheels.shadows.hue)°, which is a different "
                           + "colour rather than less of the one that was asked for")
            XCTAssertEqual(landed.look.wheels.shadows.sat, 0.5 * amount / 100,
                           accuracy: 1e-12)
        }
    }

    /// The same property where both ends are real colours: the puck slides across the
    /// disc, so the midpoint is the midpoint of the two TINTS. Interpolating the angles
    /// instead sends a blend of two opposite hues the long way round the wheel through a
    /// colour neither look contains.
    func testTwoGradesMeetThroughTheDiscRatherThanAroundIt() {
        var target = Recipe()
        target.look.wheels.global = Wheel(hue: 350, sat: 0.4)
        let look = Look(wheels: GradingWheels(global: Wheel(hue: 10, sat: 0.4)))
        let landed = Self.subset(look, amount: 50).applied(to: target)
        XCTAssertEqual(landed.look.wheels.global.hue, 0, accuracy: 1e-9,
                       "halfway between 350° and 10° is 0°, not 180°")
        XCTAssertLessThan(landed.look.wheels.global.sat, 0.4,
                          "two tints 20° apart met at full saturation, so the puck is "
                          + "travelling round the rim rather than across the disc")
    }

    // MARK: - 5. Categoricals land whole

    /// A stock name is not a quantity, "this frame is monochrome" is not a quantity, and
    /// neither is which display-transform curve is in force. Each lands whole at any
    /// amount above zero and it is the STRENGTH beside it that dials.
    func testTheChoicesInALookArriveWholeAndOnlyTheirStrengthsDial() throws {
        let target = Self.gradedTarget()   // Tri-X at 60, "Soft", colour
        let look = Look(filmLab: FilmLab(stock: "lumen/portra400", amount: 100),
                        bw: BlackAndWhite(bands: Array(repeating: 20, count: 8),
                                          enabled: true),
                        render: RenderParams(preset: "Punchy"))
        let landed = Self.subset(look, amount: 10).applied(to: target)

        XCTAssertEqual(landed.look.filmLab?.stock, "lumen/portra400",
                       "at 10% the frame is wearing some other emulsion than the one "
                       + "the look names — there is one film stage and it loads one "
                       + "stock, so a crossfade is a picture the pipeline cannot make")
        XCTAssertEqual(try XCTUnwrap(landed.look.filmLab?.amount), 10, accuracy: 1e-12,
                       "the stock arrived at full Strength, so Amount did nothing")
        XCTAssertTrue(landed.look.blackAndWhiteIsOn,
                      "the treatment is a switch and there is no partial monochrome "
                      + "control anywhere in the Look layer to fake one with")
        XCTAssertEqual(landed.look.render.preset, "Punchy",
                       "the transform preset names a kind of rendering, not an amount")
    }

    /// The register rule still runs at a partial amount. A look born on a RAW must not
    /// pull a delivered JPEG off "Linear" at 40% any more than it may at 100 — the
    /// two-and-a-half stops of highlight `LookSubset`'s header measures are lost just as
    /// completely either way.
    func testAPartialAmountStillCannotMoveAFrameAcrossTheToneMappedBoundary() {
        var jpeg = Recipe()
        jpeg.look.render.preset = LookSubset.linearPresetName
        let raw = Look(render: RenderParams(preset: "Film Base"))
        let landed = Self.subset(raw, amount: 40).applied(to: jpeg)
        XCTAssertEqual(landed.look.render.preset, LookSubset.linearPresetName,
                       "a look at 40% took an already tone-mapped frame off the escape "
                       + "hatch and handed it a second S-curve")
    }

    /// A look with no film says "no film", and the frame's own fades out by Strength
    /// rather than vanishing at the first percent — the picture walks even though the
    /// slot is categorical.
    func testALookWithNoFilmFadesTheFramesOwnStockOutByStrength() throws {
        let target = Self.gradedTarget()   // Tri-X at Strength 60
        let landed = Self.subset(Look(), amount: 25).applied(to: target)
        XCTAssertEqual(landed.look.filmLab?.stock, "lumen/trix400")
        XCTAssertEqual(try XCTUnwrap(landed.look.filmLab?.amount), 45, accuracy: 1e-12,
                       "60 → 45 is a quarter of the way to gone; a stock that jumped "
                       + "straight to nil would make the first percent of the slider a "
                       + "cliff")
        XCTAssertNil(Self.subset(Look(), amount: 100).applied(to: target)
                        .look.filmLab,
                     "at full strength the look's own answer — no film — has to arrive")
    }

    // MARK: - 6. What a hand-edited sidecar cannot do

    /// This is the door a foreign or hand-edited look comes through, and `blended` runs
    /// `Num.mix` over forty fields with whatever arrives. A NaN would take the whole
    /// look with it and render black, which is worse than any misreading of the number.
    func testAnUnreadableAmountFailsTowardTheLookBeingThere() throws {
        XCTAssertEqual(LookSubset.clampedAmount(.nan), LookSubset.fullAmount)
        XCTAssertEqual(LookSubset.clampedAmount(.infinity), LookSubset.fullAmount)
        XCTAssertEqual(LookSubset.clampedAmount(400), LookSubset.fullAmount)
        XCTAssertEqual(LookSubset.clampedAmount(-20), 0)

        let overdriven = """
        {"pipelineVersion":2,"look":{"vignette":-0.6},"amount":400}
        """
        let decoded = try CanonicalJSON.decodeLookSubset(from: Data(overdriven.utf8))
        XCTAssertEqual(decoded.amount, LookSubset.fullAmount,
                       "an amount past the top of the control survived the decoder")

        var poisoned = Self.subset(SavedLookTests.loadedLook(), amount: .nan)
        let landed = poisoned.applied(to: Recipe())
        XCTAssertTrue(landed.look.vignette.isFinite,
                      "a NaN amount poisoned the look on the way through")
        poisoned.amount = -5
        XCTAssertEqual(poisoned.applied(to: Recipe()), Recipe(),
                       "a negative amount did something other than nothing")
    }

    // MARK: - 7. The boundary this shape has, pinned rather than described

    /// The amount is spent AS the look lands — it is baked into the parameters, which is
    /// what lets `RenderPlan`, `RenderGraph`, `DisplayTransform` and `PipelineRenderer`
    /// stay ignorant of it and what keeps every plan cache key correct. The price is
    /// that it is not a control on the photograph: re-applying at a second amount walks
    /// from where the first one left the frame instead of from where it started.
    ///
    /// Asserted rather than left in a doc comment, because the day somebody makes the
    /// amount live this test is what tells them which promise they are changing.
    func testReapplyingAtAPartialAmountCompoundsRatherThanReplacing() {
        let look = SavedLookTests.loadedLook()
        let subset = Self.subset(look, amount: 40)
        let once = subset.applied(to: Recipe())
        let twice = subset.applied(to: once)
        XCTAssertNotEqual(twice, once,
                          "a second apply at the same amount changed nothing, so the "
                          + "amount has quietly become a property of the photograph — "
                          + "if that is now true, this file's whole shape is out of date")
        // 40% then 40% again is 64% of the way, not 40%.
        XCTAssertEqual(twice.look.vignette, look.vignette * 0.64, accuracy: 1e-12)
    }

    /// At full strength the old promise is untouched: applying a look twice is applying
    /// it once. `SavedLookTests` asserts this too; it is repeated here because the
    /// property is exactly what the compounding above puts at risk.
    func testAtFullStrengthApplyingTwiceIsStillApplyingOnce() {
        let subset = LookSubset.extracted(from: Recipe(look: SavedLookTests.loadedLook()))
        let once = subset.applied(to: Self.gradedTarget())
        XCTAssertEqual(subset.applied(to: once), once)
    }

    // MARK: - 8. The controls that spend it

    /// A speed edit clamps to `Parameter.range`, so a range short of the panel
    /// control's does not scale the drag — it amputates the control, silently, at a
    /// number that is not the end of anything on screen.
    ///
    /// `maskAmount` was 0…100 against a slider that has always been 0…200 (`MaskPanel`'s
    /// row, `Mask.amount`'s own "0…200 multiplier over the whole adjust set",
    /// `ReferenceRenderer.applyLocalAdjust`'s clamp). The whole over-100 half — which is
    /// what the D29 multiplier exists for — was unreachable by hold-and-drag.
    func testTheSpeedEditRangesAreTheirPanelControls() {
        XCTAssertEqual(SpeedEdit.Parameter.lookAmount.range, LookSubset.amountRange,
                       "holding K would drag a look's Amount past what the model "
                       + "accepts, or stop short of the top of the slider")
        XCTAssertEqual(SpeedEdit.Parameter.maskAmount.range, 0...200,
                       "holding M cannot reach a mask Amount above 100, so the entire "
                       + "over-strength half of the control — the reason it is a "
                       + "multiplier and not an opacity — is unreachable by drag")

        // The clamp is what makes a wrong range destructive rather than cosmetic.
        let full = SpeedEdit.value(from: 100, dragPoints: 900, across: 900,
                                   parameter: .maskAmount, fine: false)
        XCTAssertEqual(full, 200, "a full-window drag stops before the slider does")
    }

    /// The panel's end of it, as a text scan, because `LookPanel` is in LumenApp — macOS
    /// only, no test target here — and the defect it guards against is exactly the one
    /// `SpeedEdit` already had: a control named everywhere and wired to nothing.
    ///
    /// COMMENTS ARE STRIPPED FIRST. This file's subject is a symbol that appears in
    /// several paragraphs of prose in that panel, so an unstripped scan would be
    /// satisfied by the comment explaining the line it is meant to find missing —
    /// `LookBrowserVerbTests` and `DeliveryNameTests` both record a first draft passing
    /// its own substitution proof that way.
    func testTheLookPanelDrawsAnAmountAndSpendsItOnTheApply() throws {
        let panel = Self.strippingComments(try Self.appSource("LookPanel.swift"))
        XCTAssertTrue(panel.contains("title: \"Amount\""),
                      "the look browser draws no Amount control, so a film emulation "
                      + "can only be applied at the strength it was saved at")
        XCTAssertTrue(panel.contains("value: $applyAmount"),
                      "the Amount row is drawn against something other than the "
                      + "panel's own amount")
        // Deliberately loose about HOW the amount reaches the apply, and tight about
        // THAT it is HANDED ON. The panel holds a second copy of `AppState.applyLook`'s
        // plumbing today only because that verb takes a `LookRow` and nothing else;
        // when it grows an `amount:` the two collapse and this body becomes one call.
        // `amount = applyAmount` is today's shape and `amount: applyAmount` is that
        // one, so either satisfies this and neither is the defect being guarded — a
        // control that is drawn, bound, and then never spent, exactly what
        // `SpeedEdit.Parameter.lookAmount` was.
        //
        // A BARE `apply.contains("applyAmount")` IS NOT ENOUGH and this assertion's
        // first draft was exactly that: it survives deleting the one line that spends
        // the amount, because the zero guard above it and the status sentence below it
        // both READ `applyAmount` and neither applies anything. A test satisfied by the
        // two lines that only talk about a value is the same class of defect as the
        // unstripped-comment scan warned about two paragraphs up — it passes on a panel
        // that draws the slider, refuses to apply at 0%, prints "at 40%" in the status
        // bar, and then lands the look whole.
        let apply = try Self.body(after: "private func apply(_ look: LookRow)", in: panel)
        XCTAssertTrue(apply.contains("amount = applyAmount")
                        || apply.contains("amount: applyAmount"),
                      "the panel applies the look without ever handing on the Amount "
                      + "the photographer set, so the slider moves and nothing else "
                      + "does — which is the defect this whole feature started as")
        XCTAssertFalse(panel.contains("LookSubset.blended("),
                       "the view is doing the interpolating. What a look does to a "
                       + "recipe is decided in LumenCore, where it is tested; a second "
                       + "copy in a target with no tests is how the two paths that "
                       + "apply a look came to disagree about the render preset")
    }

    // MARK: - helpers

    private static func appSource(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/LumenApp")
        return try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    /// The braces of the declaration `anchor` opens, so an assertion about one function
    /// cannot be satisfied by a line somewhere else in a 1700-line file.
    ///
    /// Copied from `LookBrowserVerbTests` rather than shared, for the reason
    /// `CaptureSharpenScopeTests` gives: a helper shared between two files that assert
    /// unrelated things is a third thing to keep true.
    private static func body(after anchor: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: anchor),
                                  "\(anchor) is gone from the panel")
        var index = start.upperBound
        while index < source.endIndex, source[index] != "{" {
            index = source.index(after: index)
        }
        guard index < source.endIndex else { return "" }
        var depth = 0
        let open = index
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { return String(source[open...index]) }
            }
            index = source.index(after: index)
        }
        return String(source[open...])
    }

    private static func strippingComments(_ source: String) -> String {
        var out = ""
        var index = source.startIndex
        var inBlock = false
        while index < source.endIndex {
            let rest = source[index...]
            if inBlock {
                if rest.hasPrefix("*/") { inBlock = false; index = source.index(index, offsetBy: 2) }
                else { index = source.index(after: index) }
                continue
            }
            if rest.hasPrefix("/*") { inBlock = true; index = source.index(index, offsetBy: 2); continue }
            if rest.hasPrefix("//") {
                while index < source.endIndex, source[index] != "\n" { index = source.index(after: index) }
                continue
            }
            out.append(source[index])
            index = source.index(after: index)
        }
        return out
    }
}
