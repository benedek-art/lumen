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

    /// The audit's own case: Whites +100 at Blending 50 renders a 0.1200 half-width,
    /// and the factory axis would have drawn 0.1071.
    func testAtWhitesPlusOneHundredTheStripDrawsTheWiderRenderedCrossfade() {
        let r = recipe(whites: 100, blacks: 0)
        let drawn = ZoneWindows(gradeOf: r)
        XCTAssertEqual(drawn.spanEV, 12.5, accuracy: 1e-12)
        XCTAssertEqual(drawn.shadowHalfWidth, 1.5 / 12.5, accuracy: 1e-9,
                       "the strip must draw the crossfade the engine renders at span 12.5, "
                       + "not the factory axis's 1.5 / 14")
        XCTAssertEqual(drawn.shadowHalfWidth, renderedWindows(r).shadowHalfWidth,
                       accuracy: 1e-12)
    }

    /// Dropping a handle stores `handle − Balance shift`; the shift has to be converted
    /// on the rendered span, or the pivot the engine solves is not where the handle was
    /// released. Converted on 14 EV at Whites +100 and Balance ±100 it missed by 0.214 EV.
    func testABalanceShiftedHandleRendersWhereItWasReleasedWhenWhitesMove() {
        for balance in [-100.0, 100] {
            let r = recipe(whites: 100, blacks: 0, balance: balance)
            let windows = ZoneWindows(gradeOf: r)
            let released = 0.55
            let stored = released - ZoneWindows.pivotShift(balance: balance,
                                                           spanEV: windows.spanEV)
            var dropped = r
            dropped.look.wheels.pivots = [r.look.wheels.pivots[0], stored]
            let rendered = renderedWindows(dropped)
            XCTAssertEqual(rendered.highlightPivot, released, accuracy: 1e-12,
                           "Balance \(balance): the rendered pivot must sit under the handle")
            // And the factory span is measurably the wrong inverse here.
            let factory = released - ZoneWindows.pivotShift(balance: balance, spanEV: 14)
            XCTAssertEqual(abs(factory - stored) * windows.spanEV, 0.214, accuracy: 1e-3)
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
