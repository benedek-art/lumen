// GradeStripAxisTests.swift
// The Colour Grading strip draws the zone windows the engine grades through, on the
// axis the engine grades on (B2-05).
//
// The pivots are stored on a normalized axis, black anchor → white anchor, and the
// engine hangs that axis off the TONE stage's live anchors: `RenderPlan` hands
// `toneEngine.whiteAnchorEV` / `blackAnchorEV` to `GradeEngine`, and Whites and Blacks
// move each anchor by up to 1.5 EV. Two things in `ZoneWindows` are denominated in EV
// and divided by that span — the Balance shift and the crossfade half-width — so the
// span is not a detail of the drawing; it is part of the shape.
//
// The strip built `ZoneWindows(pivots:blending:balance:)`, the factory −9 … +5 EV, and
// the handle drag converted Balance with a hard-coded 14 EV. Measured at Whites +100
// (span 12.5):
//
//                                  drawn     rendered
//   crossfade half-width          0.1071      0.1200    ← 10.7 % narrower on screen
//   handle drop, Balance ±100     0.214 EV off the release
//
// At Whites and Blacks zero the two agree exactly, which is why nothing caught it. Each
// test below builds the strip's windows through `ZoneWindows(gradeOf:)` — the one the
// panel calls — and compares against the windows `GradeEngine` is built with the way
// `RenderPlan` builds it. If the zone axis is ever re-denominated (A1-03 / D-5), the
// strip has to move with it, and this is where that shows.

import XCTest
@testable import LumenCore

final class GradeStripAxisTests: XCTestCase {

    /// The windows the renderer grades through, built exactly as `RenderPlan` builds
    /// them: a full tone engine, its live anchors handed to the grade engine.
    private func renderedWindows(_ recipe: Recipe) -> ZoneWindows {
        let tone = ToneEngine(tone: recipe.develop.tone, zones: recipe.develop.zones)
        return GradeEngine(wheels: recipe.look.wheels,
                           printerLights: recipe.look.printerLights,
                           whiteAnchorEV: tone.whiteAnchorEV,
                           blackAnchorEV: tone.blackAnchorEV).windows
    }

    private func recipe(whites: Double, blacks: Double, blending: Double = 50,
                        balance: Double = 0,
                        pivots: [Double] = GradingWheels.defaultPivots) -> Recipe {
        var r = Recipe()
        r.develop.tone.whites = whites
        r.develop.tone.blacks = blacks
        r.look.wheels.blending = blending
        r.look.wheels.balance = balance
        r.look.wheels.pivots = pivots
        return r
    }

    func testTheGradeStripDrawsTheWindowsTheEngineGradesThrough() {
        for whites in [-100.0, -40, 0, 60, 100] {
            for blacks in [-100.0, 0, 100] {
                for blending in [0.0, 50, 100] {
                    for balance in [-100.0, 0, 100] {
                        let r = recipe(whites: whites, blacks: blacks,
                                       blending: blending, balance: balance,
                                       pivots: [0.25, 0.7])
                        let drawn = ZoneWindows(gradeOf: r)
                        let rendered = renderedWindows(r)
                        let label = "Whites \(whites) Blacks \(blacks) "
                            + "Blending \(blending) Balance \(balance)"
                        XCTAssertEqual(drawn.spanEV, rendered.spanEV, accuracy: 1e-12,
                                       "axis span, \(label)")
                        XCTAssertEqual(drawn.shadowPivot, rendered.shadowPivot,
                                       accuracy: 1e-12, "shadow pivot, \(label)")
                        XCTAssertEqual(drawn.highlightPivot, rendered.highlightPivot,
                                       accuracy: 1e-12, "highlight pivot, \(label)")
                        XCTAssertEqual(drawn.shadowHalfWidth, rendered.shadowHalfWidth,
                                       accuracy: 1e-12, "shadow crossfade, \(label)")
                        XCTAssertEqual(drawn.highlightHalfWidth,
                                       rendered.highlightHalfWidth,
                                       accuracy: 1e-12, "highlight crossfade, \(label)")
                    }
                }
            }
        }
    }

    /// Blacks +100 moves the display curve's black anchor, so it moves the scene EV each
    /// pivot sits at, and the strip and the engine must agree on where. (The crossfade
    /// width itself is display level since lane K1 and no longer depends on the span.)
    /// WS-05: this was driven by Whites +100, but Whites no longer moves an anchor (its
    /// white point is gain, so the transform's hue blend does not shift under it); the
    /// anchor that still moves is Blacks'.
    func testAtBlacksPlusOneHundredTheStripDrawsTheRenderedPivotsInStops() {
        let r = recipe(whites: 0, blacks: 100)
        let drawn = ZoneWindows(gradeOf: r)
        XCTAssertEqual(drawn.spanEV, 15.5, accuracy: 1e-12)
        XCTAssertEqual(drawn.shadowPivotEV, renderedWindows(r).shadowPivotEV,
                       accuracy: 1e-12)
        XCTAssertLessThan(drawn.shadowPivotEV, ZoneWindows().shadowPivotEV,
                          "Blacks +100 lowers the black anchor, so the 1/3 level sits "
                              + "at a lower scene EV")
        // And Whites, which no longer moves an anchor, leaves the axis alone.
        XCTAssertEqual(ZoneWindows(gradeOf: recipe(whites: 100, blacks: 0)).spanEV, 14,
                       accuracy: 1e-12)
    }

    /// Dropping a handle stores `handle − Balance shift`, so the pivot the engine solves
    /// is where the handle was released, at every Blacks setting.
    func testABalanceShiftedHandleRendersWhereItWasReleasedWhenBlacksMove() {
        for balance in [-100.0, 100] {
            let r = recipe(whites: 0, blacks: 100, balance: balance)
            // Above the shadow handle at both Balance extremes (it sits at 0.63 at −100).
            let released = 0.8
            let stored = released - ZoneWindows.pivotShift(balance: balance)
            var dropped = r
            dropped.look.wheels.pivots = [r.look.wheels.pivots[0], stored]
            let rendered = renderedWindows(dropped)
            XCTAssertEqual(rendered.highlightPivot, released, accuracy: 1e-12,
                           "Balance \(balance): the rendered pivot must sit under the handle")
        }
    }

    /// `ToneEngine.anchors(for:)` is the arithmetic the engine itself runs, not a copy.
    func testTheCheapAnchorsAreTheToneEnginesAnchors() {
        for whites in [-100.0, -25, 0, 70, 100, 250] {
            for blacks in [-180.0, -100, 0, 33, 100] {
                var tone = Tone()
                tone.whites = whites
                tone.blacks = blacks
                let cheap = ToneEngine.anchors(for: tone)
                let engine = ToneEngine(tone: tone, zones: Zones())
                XCTAssertEqual(cheap.white, engine.whiteAnchorEV)
                XCTAssertEqual(cheap.black, engine.blackAnchorEV)
                let based = ToneEngine.anchors(for: tone, baseWhiteAnchorEV: 3.5,
                                               baseBlackAnchorEV: -10)
                let maskEngine = ToneEngine(tone: tone, zones: Zones(),
                                            baseWhiteAnchorEV: 3.5, baseBlackAnchorEV: -10)
                XCTAssertEqual(based.white, maskEngine.whiteAnchorEV)
                XCTAssertEqual(based.black, maskEngine.blackAnchorEV)
            }
        }
    }
}
