// A slider tick re-spells only the plan keys whose recipe subtrees moved, and the
// spelling it reuses is byte-for-byte the one it would have made.
//
// The round-trip count is the measurement, not a timing: `CanonicalJSON.treeBuilds`
// counts every encoder round trip, so "a Texture tick encodes nothing" is an integer
// the shared runner cannot make noisy. Before `PlanKeyMemo` that tick encoded eleven
// subtrees (seven for the colour+grade key, two for the finish key, two for the tone
// cube's) to spell three keys that had not changed.
import XCTest
@testable import LumenCore

final class PlanKeyMemoTests: XCTestCase {

    override func setUp() {
        super.setUp()
        PlanTableCache.setRenderIdentity("plan-key-memo")
    }

    override func tearDown() {
        PlanTableCache.setRenderIdentity("")
        super.tearDown()
    }

    /// Live tone, colour, grade, curve and film, so every key is actually spelled —
    /// an identity colour stage skips its key entirely and would make the count lie.
    private func edited() -> Recipe {
        var r = Recipe()
        r.develop.tone.exposure = 0.4
        r.develop.tone.contrast = 20
        r.develop.tone.whites = 10
        r.develop.color.saturation = 12
        r.develop.curve.parametric.lights = 15
        r.look.wheels.high.sat = 20
        r.look.wheels.high.hue = 40
        return r
    }

    private func encodes(_ body: () -> Void) -> Int {
        let before = CanonicalJSON.treeBuilds.value
        body()
        return CanonicalJSON.treeBuilds.value - before
    }

    func testAnUntabledControlTickEncodesNoKeySubtree() {
        let recipe = edited()
        _ = RenderPlan(recipe: recipe)          // primes the memo
        var texture = recipe
        texture.develop.detail.texture = 37
        XCTAssertEqual(encodes { _ = RenderPlan(recipe: texture) }, 0,
                       "Texture moves no keyed subtree; spelling its keys again is the "
                           + "0.67 ms the memo exists to remove")

        // Exposure is a tone input: the tone cube's key must be re-spelled (tone and
        // zones, two round trips) and nothing else.
        var exposure = texture
        exposure.develop.tone.exposure = 0.9
        XCTAssertEqual(encodes { _ = RenderPlan(recipe: exposure) }, 2)

        // Saturation moved out of every table when the colour stage became exact:
        // it re-spells nothing now.
        var saturation = exposure
        saturation.develop.color.saturation = -20
        XCTAssertEqual(encodes { _ = RenderPlan(recipe: saturation) }, 0)

        // A grading wheel is the grade table's input: its two subtrees and nothing else.
        var wheel = saturation
        wheel.look.wheels.high.sat = 35
        XCTAssertEqual(encodes { _ = RenderPlan(recipe: wheel) }, 2)
    }

    /// The reuse is only worth having if it is invisible: every key a memo hands back
    /// must equal the key `PlanTableCache.key` spells from scratch, across changes that
    /// do and do not move the inputs, and across the one value where `==` is looser
    /// than the bits.
    func testAMemoisedKeyIsByteIdenticalToAFreshSpelling() {
        let memo = PlanKeyMemo<RenderPlan.ToneKeyInputs>()
        var tone = Tone()
        var cases: [Tone] = []
        tone.exposure = 0.5; cases.append(tone)
        cases.append(tone)                               // a repeat: the memo's hit
        tone.contrast = -30; cases.append(tone)
        tone.contrast = -0.0; cases.append(tone)         // -0 == 0, prints "0"
        tone.contrast = 0; cases.append(tone)
        tone.highlights = 1e-7; cases.append(tone)
        for t in cases {
            let zones = Zones()
            let memoised = memo.key(["tonecube", "32"],
                                    inputs: .init(tone: t, zones: zones)) { [t, zones] }
            let fresh = PlanTableCache.key(["tonecube", "32"], [t, zones])
            XCTAssertEqual(memoised, fresh)
            XCTAssertNotNil(memoised)
        }
    }

    /// The tables a plan carries are the tables a cold plan would carry, so the memo
    /// moves no pixel even after it has been primed by a different recipe.
    func testAPlanBuiltThroughAPrimedMemoMatchesAColdOne() {
        var a = edited()
        a.look.filmLab = FilmLab(stock: FilmStock.all[0].id, amount: 60)
        var b = a
        b.develop.tone.blacks = -25
        b.develop.color.vibrance = 30
        b.develop.curve.parametric.darks = -10
        b.look.filmLab?.amount = 85
        _ = RenderPlan(recipe: a)
        let primed = RenderPlan(recipe: b)
        PlanTableCache.clear()
        let cold = RenderPlan(recipe: b)
        XCTAssertTrue(primed.finishLUT == cold.finishLUT)
        XCTAssertTrue(primed.gradeLUT == cold.gradeLUT)
        XCTAssertTrue(primed.toneGainCubeBaked == cold.toneGainCubeBaked)
        XCTAssertEqual(primed.finishScale, cold.finishScale)
    }
}
