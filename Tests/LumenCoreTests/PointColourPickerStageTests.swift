// PointColourPickerStageTests.swift
// AI-02: the Point Colour picker has to store the value its swatch will compare.
//
// `ColorEngine.apply` runs the primaries, then the Mixer, then the swatches in creation
// order, and each swatch measures its distance to the pixel AS IT ARRIVES. The picker
// stored the colour stage's INPUT. With any primaries or Mixer edit those are different
// colours, so the swatch was centred somewhere the clicked pixel no longer was.
//
// The finding's trigger, reproduced on the engine: Red Mixer Hue +100, pick that red,
// Point Saturation −100. Picked at the stage input, the colour kept 0.1198 of its 0.12
// chroma at Range 0 and 0.0427 at Range 50. Picked where the swatch reads, it greys.
//
// The renderer's tap (`PipelineRenderer.sampleColorStageInput`) samples the stage input
// and maps it through `ColorEngine.selectionInput`, which is what these tests drive.

import XCTest
@testable import LumenCore

final class PointColourPickerStageTests: XCTestCase {

    private let context = OKLabTransform.working
    /// A red sitting on the Red band's centre, at an ordinary lightness and chroma.
    private lazy var red = context.toRGB(OKLCh(L: 0.6, C: 0.12,
                                               h: ColorEngine.bandHueCentres[0]))

    private func engine(_ r: Recipe) -> ColorEngine {
        ColorEngine(mixer: r.develop.mixer, pointColors: r.develop.pointColors,
                    color: r.develop.color, primaries: r.look.primaries, bw: r.look.bw)
    }

    /// Pick `colour` the way the app does for the next swatch, then pull that swatch's
    /// Saturation to −100, and return the chroma the clicked pixel is left with.
    private func chromaAfterDesaturatingThePick(_ base: Recipe, colour: RGB,
                                                range: Double) -> Double {
        let picked = engine(base).selectionInput(
            colour, for: .pointColor(index: base.develop.pointColors.count))
        var edited = base
        edited.develop.pointColors.append(PointColor(
            sample: [picked.r, picked.g, picked.b], range: range,
            shift: HSLShift(h: 0, s: -100, l: 0)))
        return context.toLCh(engine(edited).apply(colour)).C
    }

    func testAPickAfterAMixerHueMoveSelectsTheClickedPixel() {
        var recipe = Recipe()
        recipe.develop.mixer.bands[0].hue = 100
        for range in [0.0, 50] {
            let left = chromaAfterDesaturatingThePick(recipe, colour: red, range: range)
            XCTAssertLessThan(left, 0.002,
                              "Range \(range): the swatch picked off this red left "
                                  + "\(left) of its 0.12 chroma — it is centred on a "
                                  + "colour the Mixer has already moved away")
        }
    }

    func testAPickAfterAPrimariesMoveSelectsTheClickedPixel() {
        var recipe = Recipe()
        recipe.look.primaries.rHue = 100
        recipe.look.primaries.rPurity = -60
        recipe.look.primaries.tintHue = 80
        let shadowRed = context.toRGB(OKLCh(L: 0.25, C: 0.08, h: 30))
        for colour in [red, shadowRed] {
            for range in [0.0, 50] {
                XCTAssertLessThan(
                    chromaAfterDesaturatingThePick(recipe, colour: colour, range: range),
                    0.002, "Range \(range), \(colour)")
            }
        }
    }

    /// A swatch reads the pixel AFTER every earlier swatch, so re-picking swatch 1 has
    /// to carry the sample through swatch 0, and only swatch 0.
    func testASwatchIsPickedAfterTheSwatchesBeforeItAndNoneAfter() {
        var recipe = Recipe()
        recipe.develop.mixer.bands[4].lum = -40
        let first = PointColor(sample: [red.r, red.g, red.b], range: 60,
                               shift: HSLShift(h: 40, s: 0, l: 0))
        let later = PointColor(sample: [0.1, 0.2, 0.7], range: 60,
                               shift: HSLShift(h: -30, s: 50, l: 0))
        recipe.develop.pointColors = [first, PointColor(sample: [0, 0, 0]), later]
        let e = engine(recipe)
        let atOne = e.selectionInput(red, for: .pointColor(index: 1))
        // Swatch 0 rotated the red by about 40°; swatch 2 is not applied yet.
        let hue = context.toLCh(atOne).h
        XCTAssertGreaterThan(Num.hueDelta(context.toLCh(red).h, hue), 30)
        // Swatch 1 (a black, no-shift dead swatch) and swatch 2 come after: the value
        // for index 1 and index 2 differ only by swatch 1, which is dead.
        XCTAssertEqual(e.selectionInput(red, for: .pointColor(index: 2)), atOne)

        // And re-picking swatch 1 at that value then desaturating it greys the red.
        var edited = recipe
        edited.develop.pointColors[1] = PointColor(sample: [atOne.r, atOne.g, atOne.b],
                                                   range: 0,
                                                   shift: HSLShift(h: 0, s: -100, l: 0))
        let leftAfterSwatchOne = context.toLCh(engine(edited).apply(red)).C
        XCTAssertLessThan(leftAfterSwatchOne, 0.002)
    }

    /// The Mixer's band picker reads after the primaries, which is where band
    /// membership is decided. A primaries rotation moves a colour across a band seam;
    /// the picked band must be the one the Mixer will actually grade it with.
    func testTheMixerBandPickReadsAfterThePrimaries() {
        var recipe = Recipe()
        recipe.look.primaries.rHue = -100
        recipe.look.primaries.gHue = 100
        let e = engine(recipe)
        var moved = 0
        for hue in stride(from: 0.0, to: 360.0, by: 5) {
            let colour = context.toRGB(OKLCh(L: 0.6, C: 0.12, h: hue))
            let raw = ColorEngine.dominantBand(for: colour, arcs: e.arcs)
            let picked = ColorEngine.dominantBand(for: e.selectionInput(colour, for: .mixerBand),
                                                  arcs: e.arcs)
            if raw != picked { moved += 1 }
            // The band the Mixer actually weights most for this pixel: pull each band
            // in turn and see which one darkens it most.
            var strongest = -1
            var deepest = 0.0
            for band in 0..<ColorEngine.bandCount {
                var pulled = recipe
                pulled.develop.mixer.bands[band].lum = -100
                let drop = context.toLCh(engine(recipe).apply(colour)).L
                    - context.toLCh(engine(pulled).apply(colour)).L
                if drop > deepest { deepest = drop; strongest = band }
            }
            XCTAssertEqual(picked, strongest, "hue \(hue)")
        }
        XCTAssertGreaterThan(moved, 0, "the primaries edit moved no colour across a "
                             + "band seam, so this test cannot tell the two taps apart")
    }
}
