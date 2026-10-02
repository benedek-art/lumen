// MaskPointColourPickerStageTests.swift
// AI-02's gap inside a mask: the mask's Point Colour picker has to store the value the
// mask's swatch will compare.
//
// `ReferenceRenderer.applyLocalAdjust` (and its GPU twin `LocalPlan`) runs the mask's
// exposure, local tone and local white balance BEFORE the mask's colour stage, and inside
// that stage each swatch measures the pixel after every earlier swatch. The mask picker
// stored the mask stage's INPUT (`sampleMaskStageInput`), so in a mask carrying a Temp,
// Tint or Exposure move the swatch was centred on a colour the clicked pixel no longer
// was. `PipelineRenderer.sampleMaskStageInput(…, pointColorSwatch:)` maps its window
// mean through `ReferenceRenderer.localSelectionInput`, which is what these tests drive,
// end to end through the render's own `applyLocalAdjust`.

import XCTest
@testable import LumenCore

final class MaskPointColourPickerStageTests: XCTestCase {

    private let context = OKLabTransform.working
    /// A red on the Red band's centre, at an ordinary lightness and chroma.
    private lazy var red = context.toRGB(OKLCh(L: 0.6, C: 0.12,
                                               h: ColorEngine.bandHueCentres[0]))
    /// A muted colour, which a white-balance move swings much further in hue.
    private lazy var muted = context.toRGB(OKLCh(L: 0.6, C: 0.04,
                                                 h: ColorEngine.bandHueCentres[4]))

    /// Pick `colour` in mask 0 the way the app does for its next swatch, pull that
    /// swatch to Saturation −100, render the mask's adjustment over a one-pixel
    /// picture of `colour`, and return the chroma that pixel is left with.
    private func chromaAfterDesaturatingTheMaskPick(_ base: Recipe, colour: RGB,
                                                    range: Double) -> Double {
        let plan = RenderPlan(recipe: base)
        let mask = base.masks[0]
        let picked = ReferenceRenderer.localSelectionInput(
            colour, mask: mask, plan: plan, swatchIndex: mask.adjust.pointColors.count)
        var edited = base
        edited.masks[0].adjust.pointColors.append(PointColor(
            sample: [picked.r, picked.g, picked.b], range: range,
            shift: HSLShift(h: 0, s: -100, l: 0)))
        let editedPlan = RenderPlan(recipe: edited)
        let image = ImageBuffer(width: 1, height: 1) { _, _ in colour }
        let out = ReferenceRenderer.applyLocalAdjust(image, mask: edited.masks[0],
                                                     plan: editedPlan, space: .rec2020)
        return context.toLCh(out[0, 0]).C
    }

    private func recipe(with adjust: LocalAdjust) -> Recipe {
        var r = Recipe()
        r.masks = [Mask(name: "m", adjust: adjust)]
        return r
    }

    func testAMaskPickAfterTheMasksOwnWhiteBalanceSelectsTheClickedPixel() {
        let r = recipe(with: LocalAdjust(temp: 100, tint: 100))
        for range in [0.0, 50] {
            let left = chromaAfterDesaturatingTheMaskPick(r, colour: muted, range: range)
            XCTAssertLessThan(left, 0.001,
                              "Range \(range): the mask swatch picked off this colour left "
                                  + "\(left) of its chroma — it is centred on a colour "
                                  + "the mask's own white balance has already moved")
        }
    }

    func testAMaskPickAfterTheMasksOwnExposureAndToneSelectsTheClickedPixel() {
        let r = recipe(with: LocalAdjust(exposure: 1.5, contrast: 40, shadows: 50))
        for range in [0.0, 50] {
            let left = chromaAfterDesaturatingTheMaskPick(r, colour: red, range: range)
            XCTAssertLessThan(left, 0.002,
                              "Range \(range): \(left) chroma left — the swatch sits "
                                  + "at the pre-exposure lightness of the clicked pixel")
        }
    }

    /// The second swatch reads the pixel after the first: a hue swing on swatch 0
    /// moves the red before swatch 1 ever sees it.
    func testASecondMaskSwatchIsPickedAfterTheFirst() {
        let first = PointColor(sample: [red.r, red.g, red.b], range: 50,
                               shift: HSLShift(h: 60, s: 0, l: 0))
        let r = recipe(with: LocalAdjust(pointColors: [first]))
        for range in [0.0, 50] {
            let left = chromaAfterDesaturatingTheMaskPick(r, colour: red, range: range)
            XCTAssertLessThan(left, 0.002,
                              "Range \(range): \(left) chroma left — swatch 1 was "
                                  + "picked before swatch 0 had moved the pixel")
        }
    }

    /// Nothing in the mask before the swatch: the pick is the input, unchanged — the
    /// fix cannot move a pick that was already right.
    func testAnUneditedMaskPicksTheStageInput() {
        let r = recipe(with: LocalAdjust(sat: -30))
        let picked = ReferenceRenderer.localSelectionInput(
            red, mask: r.masks[0], plan: RenderPlan(recipe: r), swatchIndex: 0)
        XCTAssertEqual(picked.r, red.r, accuracy: 1e-12)
        XCTAssertEqual(picked.g, red.g, accuracy: 1e-12)
        XCTAssertEqual(picked.b, red.b, accuracy: 1e-12)
    }
}
