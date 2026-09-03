// The measured band hues are read from exactly one place, under one condition — and
// producing them costs a whole RAW decode, which on an external drive is seconds
// (docs/34). This pins the predicate that lets the renderer skip it.
import XCTest
@testable import LumenCore

final class BandHueNeedTests: XCTestCase {

    func testADefaultRecipeDoesNotNeedTheMeasurement() {
        XCTAssertFalse(ColorEngine.needsMeasuredBandHues(Recipe().develop.mixer),
                       "a photograph nobody has touched must not pay for a second "
                           + "decode of the file before its first frame")
    }

    func testUniformityIsWhatNeedsIt() {
        var mixer = Mixer()
        mixer.uniformity = 40
        XCTAssertTrue(ColorEngine.needsMeasuredBandHues(mixer))
        mixer.uniformity = -40
        XCTAssertTrue(ColorEngine.needsMeasuredBandHues(mixer),
                      "the consumer tests q != 0, so both signs read the target")
        mixer.uniformity = 0
        XCTAssertFalse(ColorEngine.needsMeasuredBandHues(mixer))
    }

    /// Moving the per-band controls does NOT need it — only convergence does. If that
    /// ever changes, the renderer's skip becomes wrong, and this test is the tripwire.
    func testBandMovesAloneDoNotNeedIt() {
        var mixer = Mixer()
        mixer.bands[0].hue = 80
        mixer.bands[3].sat = -60
        mixer.bands[7].lum = 25
        XCTAssertFalse(ColorEngine.needsMeasuredBandHues(mixer))
    }

    /// And Uniformity still resolves without a measurement: `bandTargetHue` falls back
    /// to each band's own core midpoint, so a plan built with none is usable rather
    /// than degenerate.
    func testUniformityStillResolvesWithoutAMeasurement() {
        var recipe = Recipe()
        recipe.develop.mixer.uniformity = 100
        XCTAssertNil(RenderPlan(recipe: recipe).bandMeanHues,
                     "no measurement supplied — the engine uses the band's core "
                         + "midpoint, which is what makes skipping it safe")
    }
}
