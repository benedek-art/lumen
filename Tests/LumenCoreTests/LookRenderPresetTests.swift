// LookRenderPresetTests.swift
// The one field in the Look layer that describes the PHOTOGRAPH rather than the look,
// and the boundary it must never be carried across.
//
// `look.render.preset` holds five names. Four of them ("Neutral", "Soft", "Punchy",
// "Film Base") pick a tone curve, and picking a curve is exactly the kind of intent a
// look exists to carry. The fifth, "Linear", is not a curve: docs/04 §6.1 put it there
// as the escape hatch for a file that has already been tone-mapped once, and
// `AppState.startingRecipe` writes it onto every JPEG, HEIC and TIFF at ingest for that
// reason and no other. On a rendered file the preset is a fact about the file, of the
// same kind as its white balance — and per docs/00 §4 facts about a file stay with the
// file.
//
// So a look that replaced the preset whole moved its target between two registers.
// `testTheTwoRegistersAreNotACosmeticDifference` measures what that costs in code
// values, through the shipping curve, so the rest of this file is asserting about
// something with a known price rather than about a string. The short version: a
// RAW-born look landing on a JPEG plugs its shadows (32 → 13) and greys its white
// (255 → 222); a JPEG-born look landing on a RAW clips every highlight above +2.47 EV.
//
// The Looks header's Reset had the same defect and it was fixed (audit K-027,
// `DevelopColumn.swift:596`, which re-applies the photograph's own starting render per
// target). What was left was the same mechanism arriving through the two doors the
// feature actually exists for — Apply Look and Paste Look — which is why these tests
// are about `LookSubset.applied(to:)` and `applied(toAll:)` rather than about a button.
//
// The load-bearing test in the file is arguably `testApplyingALookBetweenTwoFilesOf
// TheSameKindIsUnchangedInEveryByte`. Both frames agreeing about what they are is
// nearly every application of nearly every look, it is why this went unnoticed for as
// long as it did, and a fix that quietly changed it would be a worse defect than the
// one it repaired. That test carries a copy of the old function and demands the whole
// `Recipe` still match it.

import Foundation
import XCTest
@testable import LumenCore

final class LookRenderPresetTests: XCTestCase {

    // MARK: - Fixtures

    /// A look with real grading in it, saved off a frame sitting on `preset`.
    ///
    /// The grade is here so the assertions below can tell "the preset was held back"
    /// apart from "nothing arrived at all" — a fix that made `applied(to:)` a no-op
    /// would pass a preset assertion and fail every photographer.
    private static func gradedLook(preset: String) -> Look {
        Look(
            wheels: GradingWheels(global: Wheel(hue: 210, sat: 0.12, lum: 0.03),
                                  shadows: Wheel(hue: 18, sat: 0.06, lum: -0.04)),
            printerLights: PrinterLights(master: 3, r: -1, g: 2, b: 4),
            primaries: Primaries(rHue: 4, rPurity: -6),
            bw: BlackAndWhite(bands: [10, -20, 30, -40, 5, 15, -25, 35], enabled: false),
            vignette: -0.8,
            vignetteFeather: 72,
            grain: CreativeGrain(amount: 38, size: 64, roughness: 22),
            render: RenderParams(preset: preset, contrast: 1.4, skew: -0.2,
                                 huePreservation: 65, blackTarget: 2.5, whiteTarget: 90))
    }

    /// What `AppState.startingRecipe` hands an unedited RAW: the type's own defaults,
    /// which put `render.preset` on "Neutral".
    private static func rawRecipe() -> Recipe {
        var recipe = Recipe()
        recipe.develop.tone.exposure = -0.75
        recipe.develop.raw.temp = 3200
        return recipe
    }

    /// What `AppState.startingRecipe` hands an unedited JPEG, HEIC or TIFF. The one
    /// line it writes is this one — `recipe.look.render.preset = "Linear"` — and the
    /// whole of this file is about what happens to it afterwards.
    private static func renderedFileRecipe() -> Recipe {
        var recipe = Recipe()
        recipe.look.render.preset = "Linear"
        recipe.develop.tone.exposure = 0.4
        return recipe
    }

    /// `LookSubset.applied(to:)` EXACTLY as it stood before the register rule: the Look
    /// layer replaced whole, `preset` and all.
    ///
    /// Carried here rather than described in a comment because
    /// `testApplyingALookBetweenTwoFilesOfTheSameKindIsUnchangedInEveryByte` asserts
    /// whole-`Recipe` equality against it. "Unchanged for the common case" is a claim
    /// about two functions, so the test needs both of them.
    private static func previousBehaviour(_ subset: LookSubset, on recipe: Recipe) -> Recipe {
        var copy = recipe
        copy.look = subset.look
        copy.pipelineVersion = max(recipe.pipelineVersion, subset.pipelineVersion)
        return copy
    }

    // MARK: - The boundary, both ways

    /// The owner's case: "Portra warm" is built on a RAW, and the shoot it is applied
    /// to contains the client's delivered JPEGs.
    func testALookSavedOffARAWDoesNotLayASecondToneMapOnAJPEG() {
        let fromRaw = LookSubset.extracted(
            from: Recipe(look: LookRenderPresetTests.gradedLook(preset: "Neutral")))

        let result = fromRaw.applied(to: LookRenderPresetTests.renderedFileRecipe())

        XCTAssertEqual(result.look.render.preset, "Linear",
                       "a look took a rendered file off the Linear escape hatch and put "
                       + "the default sigmoid on top of the camera's own curve — a "
                       + "SECOND tone map, persisted into the recipe. Measured cost: "
                       + "code value 32 → 13, 48 → 27, 255 → 222")
        XCTAssertEqual(result.look.vignette, -0.8,
                       "the look itself did not arrive, so this is passing for the "
                       + "wrong reason")
    }

    /// The reverse, which the audit calls the harder one to diagnose: one look built on
    /// a delivered JPEG, applied across a RAW shoot.
    func testALookSavedOffAJPEGDoesNotThrowAwayARAWsHighlights() {
        let fromJpeg = LookSubset.extracted(
            from: Recipe(look: LookRenderPresetTests.gradedLook(preset: "Linear")))

        let result = fromJpeg.applied(to: LookRenderPresetTests.rawRecipe())

        XCTAssertEqual(result.look.render.preset, "Neutral",
                       "a scene-referred RAW was handed the escape hatch, which clips "
                       + "at display white: every highlight above +2.47 EV is now paper "
                       + "white, and the shadows are washed (−4 EV: 9 → 27)")
        XCTAssertEqual(result.look.printerLights, PrinterLights(master: 3, r: -1, g: 2, b: 4),
                       "the look itself did not arrive, so this is passing for the "
                       + "wrong reason")
    }

    /// A RAW the photographer parked on Linear on purpose — the "show me the data"
    /// control — is not pulled off it by a look either.
    ///
    /// This is the one case where reading the target RECIPE differs from reading the
    /// target photograph's format, and it is asserted rather than left to fall out,
    /// because it is a decision: the rule is symmetric, no look moves a frame across
    /// the boundary in either direction, and the preset picker stays the way to change
    /// registers deliberately.
    func testALookDoesNotPullAFrameOffLinearEither() {
        let fromRaw = LookSubset.extracted(
            from: Recipe(look: LookRenderPresetTests.gradedLook(preset: "Punchy")))

        var parkedOnLinear = Recipe()
        parkedOnLinear.look.render.preset = "Linear"

        let result = fromRaw.applied(to: parkedOnLinear)
        XCTAssertEqual(result.look.render.preset, "Linear",
                       "applying a look silently cancelled the honesty control the "
                       + "photograph was deliberately being inspected under")
    }

    /// A preset name from a later build is a CURVE, not a second escape hatch, so it
    /// travels.
    ///
    /// That matches how the engine reads it — `DisplayTransformParams.preset(named:)`
    /// resolves an unrecognised name to Neutral — and it is the conservative reading of
    /// the two: mistaking a curve for a curve costs a different grade, mistaking an
    /// escape hatch for a curve costs a second tone map on every rendered file.
    func testAPresetNameFromALaterBuildIsTreatedAsACurveAndTravels() {
        XCTAssertEqual(LookSubset.carriedRenderPreset("Portra Print", onto: "Neutral"),
                       "Portra Print")
        XCTAssertEqual(LookSubset.carriedRenderPreset("Portra Print", onto: "Linear"),
                       "Linear",
                       "an unknown name was let across the boundary onto a rendered file")
    }

    // MARK: - What still travels

    /// The creative half of the display transform is not collateral damage.
    ///
    /// All five overrides travel unconditionally. Each is a number dialled on top of
    /// whatever curve is in force; none of them answers "what kind of file is this".
    /// A fix that threw the whole of `render` away would pass every assertion above and
    /// silently drop half a look.
    func testTheCreativeHalfOfTheDisplayTransformStillTravels() {
        let fromRaw = LookSubset.extracted(
            from: Recipe(look: LookRenderPresetTests.gradedLook(preset: "Neutral")))

        let onJpeg = fromRaw.applied(to: LookRenderPresetTests.renderedFileRecipe())

        XCTAssertEqual(onJpeg.look.render.contrast, 1.4, "contrast did not travel")
        XCTAssertEqual(onJpeg.look.render.skew, -0.2, "skew did not travel")
        XCTAssertEqual(onJpeg.look.render.huePreservation, 65,
                       "huePreservation did not travel")
        XCTAssertEqual(onJpeg.look.render.blackTarget, 2.5, "blackTarget did not travel")
        XCTAssertEqual(onJpeg.look.render.whiteTarget, 90, "whiteTarget did not travel")

        // And the rest of the Look layer, whole — the preset is the ONLY exception.
        var expected = LookRenderPresetTests.gradedLook(preset: "Neutral")
        expected.render.preset = "Linear"
        XCTAssertEqual(onJpeg.look, expected,
                       "something other than render.preset was held back")
    }

    // MARK: - The common path, byte for byte

    /// Two files of the same kind: nothing changes, at all, in any field.
    ///
    /// This is the case that made the defect invisible — a RAW look on a RAW, a JPEG
    /// look on a JPEG — and it is therefore the case a fix is most likely to break
    /// without anyone noticing for another release. Asserted as whole-`Recipe` equality
    /// against a copy of the OLD function rather than field by field, so a change
    /// anywhere in the result fails here.
    func testApplyingALookBetweenTwoFilesOfTheSameKindIsUnchangedInEveryByte() {
        let rawLook = LookSubset.extracted(
            from: Recipe(look: LookRenderPresetTests.gradedLook(preset: "Neutral")))
        let jpegLook = LookSubset.extracted(
            from: Recipe(look: LookRenderPresetTests.gradedLook(preset: "Linear")))
        // A deliberate curve choice, saved off a RAW and applied to a RAW: still the
        // same register, so it must still travel and still produce the same document.
        let punchyLook = LookSubset.extracted(
            from: Recipe(look: LookRenderPresetTests.gradedLook(preset: "Punchy")))

        let sameKindPairs: [(String, LookSubset, Recipe)] = [
            ("RAW look onto a RAW", rawLook, LookRenderPresetTests.rawRecipe()),
            ("Punchy RAW look onto a RAW", punchyLook, LookRenderPresetTests.rawRecipe()),
            ("JPEG look onto a JPEG", jpegLook,
             LookRenderPresetTests.renderedFileRecipe()),
        ]

        for (name, look, target) in sameKindPairs {
            XCTAssertEqual(look.applied(to: target),
                           LookRenderPresetTests.previousBehaviour(look, on: target),
                           "\(name): the register rule changed the common path, where "
                           + "the two frames already agree about what they are and "
                           + "nothing was ever wrong")
        }

        // The same statement one level up: the preset itself is not merely preserved,
        // it is the source's, because the source is entitled to it here.
        XCTAssertEqual(punchyLook.applied(to: LookRenderPresetTests.rawRecipe())
                        .look.render.preset,
                       "Punchy",
                       "a deliberate curve choice stopped travelling between two frames "
                       + "in the same register — the fix over-reached")
    }

    // MARK: - The selection, which is what makes this an S1

    /// A selection is not one kind of file. It is a shoot folder: the RAWs, plus the
    /// delivered JPEGs, plus the phone frames, plus the client's re-sends.
    ///
    /// `applied(toAll:)` takes the decision against each target recipe, so this is the
    /// same rule per frame rather than a second one — and asserting it here is what
    /// keeps a future `applied(toAll:)` that stops going through `applied(to:)` from
    /// reintroducing the defect for exactly the gesture the feature exists for.
    func testOneLookAcrossAMixedSelectionLeavesEveryFrameInItsOwnRegister() {
        let fromRaw = LookSubset.extracted(
            from: Recipe(look: LookRenderPresetTests.gradedLook(preset: "Neutral")))

        // Eight frames, alternating: RAW, JPEG, RAW, JPEG…
        let frames: [Recipe] = (0..<8).map { index in
            var recipe = index.isMultiple(of: 2)
                ? LookRenderPresetTests.rawRecipe()
                : LookRenderPresetTests.renderedFileRecipe()
            recipe.develop.tone.exposure = Double(index) * 0.25 - 1.0
            return recipe
        }

        let graded = fromRaw.applied(toAll: frames)

        XCTAssertEqual(graded.count, frames.count)
        for (index, after) in graded.enumerated() {
            let before = frames[index]
            XCTAssertEqual(after.look.render.preset, before.look.render.preset,
                           "frame \(index) changed tone-mapping register when a look "
                           + "was applied to the selection it was in")
            XCTAssertEqual(after.develop, before.develop,
                           "frame \(index) lost its own normalization")
            XCTAssertEqual(after.look.vignette, -0.8,
                           "frame \(index) did not get the look at all")
            XCTAssertEqual(after.look.render.contrast, 1.4,
                           "frame \(index) did not get the look's display-transform "
                           + "overrides")
        }
        XCTAssertEqual(Set(graded.map { $0.look.render.preset }), ["Neutral", "Linear"],
                       "the selection was flattened onto one register — which is the "
                       + "whole defect, and it is worst here because the RAWs and the "
                       + "JPEGs are damaged in opposite directions in one gesture")
    }

    // MARK: - Why it matters, in code values

    /// The register difference is not cosmetic and not a preference. This measures both
    /// directions through the shipping curve, so every assertion above is anchored to a
    /// number rather than to a string comparison.
    ///
    /// `DisplayTransform` builds all four of its stated invariants by construction, so
    /// these are the values the app renders, not an approximation of them: mid-grey
    /// lands on 0.18, the −9 EV anchor on the black target, the +5 EV anchor on the
    /// white target, and the log-log slope at mid-grey equals `contrast`. The tolerance
    /// is half a code value — loose enough that a retune of the curve's internals does
    /// not fail this test spuriously, tight enough that it could not pass if the two
    /// presets were interchangeable.
    func testTheTwoRegistersAreNotACosmeticDifference() {
        func codeValue(_ input8: Double, preset: String) -> Double {
            let transform = DisplayTransform(RenderParams(preset: preset).resolved())
            let scene = TransferFunction.srgb.decode(input8 / 255)
            return TransferFunction.srgb.encode(transform.tone(scene)) * 255
        }

        // A JPEG's own pixels, under its own preset: it comes out as it went in. That
        // is what "already tone-mapped" means and why Linear is the honest setting.
        for cv in [8.0, 32.0, 48.0, 128.0, 255.0] {
            XCTAssertEqual(codeValue(cv, preset: "Linear"), cv, accuracy: 0.5,
                           "Linear is supposed to be a pass-through")
        }

        // The same pixels under a RAW look's Neutral: a second tone map.
        XCTAssertEqual(codeValue(32, preset: "Neutral"), 12.6, accuracy: 0.5,
                       "shadows plug")
        XCTAssertEqual(codeValue(48, preset: "Neutral"), 26.7, accuracy: 0.5)
        XCTAssertEqual(codeValue(255, preset: "Neutral"), 221.7, accuracy: 0.5,
                       "paper white is no longer white")

        // And the other direction, in scene EV above mid-grey: Linear clips where the
        // display transform was still holding detail.
        let neutral = DisplayTransform(RenderParams(preset: "Neutral").resolved())
        let linear = DisplayTransform(RenderParams(preset: "Linear").resolved())
        let clipEV = log2(1 / DisplayTransform.midGrey)   // +2.4739…
        XCTAssertEqual(clipEV, 2.474, accuracy: 0.001)
        for ev in [2.5, 3.0, 4.0, 4.9] {
            let scene = DisplayTransform.midGrey * pow(2, ev)
            XCTAssertEqual(linear.tone(scene), 1.0, accuracy: 1e-9,
                           "+\(ev) EV is clipped to display white under Linear")
            XCTAssertLessThan(neutral.tone(scene), 1.0,
                              "+\(ev) EV still carries detail under Neutral, which is "
                              + "what a look carrying Linear onto a RAW throws away")
        }
        // The loss is highlight SEPARATION, not brightness: Neutral puts the +5 EV
        // white anchor on display white too, by construction. Everything between +2.47
        // and +5 EV is the range Linear flattens onto that one value.
        XCTAssertEqual(neutral.tone(DisplayTransform.midGrey * pow(2, 5.0)), 1.0,
                       accuracy: 1e-9)
    }
}

/// The rule has FOUR doors, and `applied(to:)` is only one of them.
///
/// `LookSubset.carriedRenderPreset`'s own header says so: "`applied(to:)` is not the
/// only door a look comes through — `AppState.pasteLook` assigns `recipe.look`
/// directly — and a second copy of this decision written at the other call site is how
/// the two drift apart." The tests above prove the rule and prove ONE door. This proves
/// the other three, which are in `LumenApp` and so are reachable here only as text.
///
/// The three are Paste Settings, Paste Settings Without Masks, and Paste Look. Each
/// assigns `recipe.look` whole, and each therefore has to put the preset back. Two of
/// them are Paste SETTINGS rather than Paste Look, which is the part worth writing
/// down: a photographer pasting *settings* across a mixed selection is not thinking
/// about the display transform at all, so the register change would arrive with no
/// affordance anywhere near it.
///
/// There is a second, subtler thing this pins. Every one of the three must read the
/// target's own preset BEFORE overwriting `recipe.look` — after the assignment,
/// `recipe.look.render.preset` is already the source's, and passing it as `onto:`
/// makes the guard a no-op that still compiles, still reads correctly at a glance, and
/// silently restores the defect. That is exactly the mistake made while wiring these
/// three, caught by reading the diff rather than by a test, which is why there is now
/// a test.
final class LookRenderPresetDoorTests: XCTestCase {

    private static func appStateSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/LumenApp")
        return stripComments(try String(contentsOf:
            root.appendingPathComponent("AppState.swift"), encoding: .utf8))
    }

    func testEveryDoorThatAssignsALookWholeRestoresTheTargetsRegister() throws {
        let source = try Self.appStateSource()

        // Every `.look = <something>` in the app is a door. Count them, and count the
        // guards. A new door added without a guard moves the counts apart.
        let doors = source.components(separatedBy: ".look = ").count - 1
        let guards = source.components(separatedBy: "carriedRenderPreset(").count - 1

        XCTAssertGreaterThan(doors, 0,
                             "the assignment pattern stopped matching; this test would "
                             + "otherwise pass by checking nothing")
        XCTAssertEqual(guards, doors,
                       "\(doors) places assign a look whole and \(guards) restore the "
                       + "target's render preset. An unguarded one lays a second tone "
                       + "map on a rendered file, or clips 2.47 EV off a RAW.")
    }

    /// The read-after-write trap, pinned by shape: the value handed to `onto:` must be
    /// a local read taken before the assignment, never `recipe.look.render.preset`.
    func testNoDoorReadsTheTargetsPresetAfterOverwritingIt() throws {
        let source = try Self.appStateSource()
        XCTAssertFalse(
            source.contains("onto: recipe.look.render.preset"),
            "reading the target's preset AFTER `recipe.look` was overwritten yields the "
            + "SOURCE's preset, which makes the guard a no-op that still compiles and "
            + "still reads correctly. Capture it in a local before the assignment.")
    }

    /// Comment stripping, for the same reason every other text-scanning test in this
    /// repository has it: this file's own prose contains `carriedRenderPreset` and
    /// `onto: recipe.look.render.preset`, so an unstripped scan of a file that quoted
    /// either would pass with the code gone. Two tests in this project have already
    /// passed their own substitution proof that way.
    private static func stripComments(_ source: String) -> String {
        var out = ""
        var i = source.startIndex
        var inBlock = false
        while i < source.endIndex {
            let rest = source[i...]
            if inBlock {
                if rest.hasPrefix("*/") { inBlock = false; i = source.index(i, offsetBy: 2) }
                else { i = source.index(after: i) }
                continue
            }
            if rest.hasPrefix("/*") { inBlock = true; i = source.index(i, offsetBy: 2); continue }
            if rest.hasPrefix("//") {
                while i < source.endIndex, source[i] != "\n" { i = source.index(after: i) }
                continue
            }
            out.append(source[i])
            i = source.index(after: i)
        }
        return out
    }
}
