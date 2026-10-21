// GradeBalanceDirectionTests.swift
// The colour-grading Balance slider runs the way Lightroom Classic's does: positive
// Balance hands more of the tonal range to the HIGHLIGHTS wheel, negative to the
// SHADOWS wheel (docs/05-spec-color.md §D15, "LrC semantics").
//
// It ran the other way. `ZoneWindows` added the Balance shift to both pivots, so
// +Balance slid them UP the tonal axis — and a pivot moving up is a Highlights zone
// getting SHORTER. Measured at the default pivots on the −9…+5 EV axis:
//
//   Balance     highlight weight at +1 EV     shadow weight at −2 EV
//      0              0.802                         0.000
//   +100              0.004                         0.306     ← Shadows grew
//   −100              (mid-grey became 100 % Highlights)
//
// Adobe's split-toning Balance and its Color Grading successor both say the opposite:
// positive values boost the Highlight wheel's influence, and at the far right nearly
// everything counts as a highlight. Nothing in the docs recorded the reversal as a
// choice, and nothing pinned the sign — the fixture rows pinned numbers, not intent —
// so it is pinned here as the direction a user reads off the slider.

import XCTest
@testable import LumenCore

final class GradeBalanceDirectionTests: XCTestCase {

    func testPositiveBalanceExtendsTheHighlightsZoneLikeLightroom() {
        let neutral = ZoneWindows()
        let positive = ZoneWindows(balance: 100)
        let atPlusOne = 1.0
        XCTAssertGreaterThan(
            positive.weights(at: atPlusOne).high, neutral.weights(at: atPlusOne).high + 0.1,
            "+100 Balance must give the Highlights wheel MORE of a +1 EV tone "
                + "(Lightroom: positive favours Highlights); got "
                + "\(positive.weights(at: atPlusOne).high) against "
                + "\(neutral.weights(at: atPlusOne).high) at Balance 0")
        XCTAssertLessThan(positive.highlightPivotEV, neutral.highlightPivotEV,
                          "+Balance must move the highlight pivot DOWN the tonal axis")
        XCTAssertLessThan(positive.shadowPivotEV, neutral.shadowPivotEV,
                          "+Balance must move the shadow pivot DOWN the tonal axis")
    }

    func testNegativeBalanceExtendsTheShadowsZoneLikeLightroom() {
        let neutral = ZoneWindows()
        let negative = ZoneWindows(balance: -100)
        // −1 EV renders at about a third of display level, on the default shadow
        // pivot, so it has room to gain shadow weight (−2 EV is already ~0.9 shadow).
        let atMinusOne = -1.0
        XCTAssertGreaterThan(
            negative.weights(at: atMinusOne).shadows,
            neutral.weights(at: atMinusOne).shadows + 0.1,
            "−100 Balance must give the Shadows wheel MORE of a −1 EV tone; got "
                + "\(negative.weights(at: atMinusOne).shadows) against "
                + "\(neutral.weights(at: atMinusOne).shadows) at Balance 0")
        // Mid-grey must not become a pure highlight when the user asked for shadows.
        XCTAssertLessThan(negative.weights(at: 0).high, neutral.weights(at: 0).high + 1e-12,
                          "−Balance must not grow the Highlights zone")
    }

    /// The panel's pivot strip and its drag handler both read the post-Balance pivot
    /// through `pivotShift`, so the handle a user drags and the pivot the engine
    /// renders can only disagree if this does.
    func testThePivotShiftIsTheOneTheWindowsApply() {
        for balance in [-100.0, -37, 0, 52, 100] {
            let windows = ZoneWindows(balance: balance)
            let shift = ZoneWindows.pivotShift(balance: balance)
            XCTAssertEqual(windows.shadowPivot, GradingWheels.defaultPivots[0] + shift,
                           accuracy: 1e-15, "shadow pivot at Balance \(balance)")
            XCTAssertEqual(windows.highlightPivot, GradingWheels.defaultPivots[1] + shift,
                           accuracy: 1e-15, "highlight pivot at Balance \(balance)")
            XCTAssertEqual(shift, -(balance / 100) * ZoneWindows.balanceRange,
                           accuracy: 1e-15)
        }
    }
}
