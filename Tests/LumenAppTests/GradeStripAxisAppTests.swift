// The Colour Grading strip and its handle drag, on the axis the engine grades on
// (B2-05). The arithmetic is pinned in LumenCore (`GradeStripAxisTests`); what this file
// checks is that the PANEL calls it: `LookPanel.stripWindows` is what `ZoneWeightStrip`
// draws, and `LookPanel.pivotsAfterDrag` is what `movePivot` stores. Both used the
// factory −9 … +5 EV axis, so at Whites +100 the strip drew crossfades 10.7 % narrower
// than the rendered ones and a Balance-shifted handle landed 0.21 EV off its release.
#if os(macOS)

import XCTest
@testable import LumenApp
@testable import LumenCore

final class GradeStripAxisAppTests: XCTestCase {

    private func rendered(_ recipe: Recipe) -> ZoneWindows {
        let tone = ToneEngine(tone: recipe.develop.tone, zones: recipe.develop.zones)
        return GradeEngine(wheels: recipe.look.wheels,
                           printerLights: recipe.look.printerLights,
                           whiteAnchorEV: tone.whiteAnchorEV,
                           blackAnchorEV: tone.blackAnchorEV).windows
    }

    func testTheGradeStripDrawsTheEnginesWindowsWhenWhitesMove() {
        var recipe = Recipe()
        recipe.develop.tone.whites = 100
        recipe.look.wheels.balance = 60
        let drawn = LookPanel.stripWindows(recipe)
        let engine = rendered(recipe)
        XCTAssertEqual(drawn.spanEV, engine.spanEV, accuracy: 1e-12)
        XCTAssertEqual(drawn.highlightPivotEV, engine.highlightPivotEV, accuracy: 1e-9)
        XCTAssertEqual(drawn.shadowHalfWidth, engine.shadowHalfWidth, accuracy: 1e-12)
    }

    func testADraggedHandleRendersWhereItWasReleasedWhenWhitesMove() {
        for balance in [-100.0, 100] {
            var recipe = Recipe()
            recipe.develop.tone.whites = 100
            recipe.look.wheels.balance = balance
            // 0.8, not 0.55: Balance moves the pivots by up to 0.3 of display level
            // since lane K1, so at Balance −100 the shadow handle sits at 0.63 and a
            // highlight handle dropped at 0.55 would be (correctly) held above it.
            recipe.look.wheels.pivots = LookPanel.pivotsAfterDrag(1, to: 0.8, in: recipe)
            XCTAssertEqual(rendered(recipe).highlightPivot, 0.8, accuracy: 1e-12,
                           "Balance \(balance)")
        }
    }
}

#endif
