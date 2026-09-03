// ViewingConditionsTests.swift
// The surround is part of the instrument, so its rules are pinned like the engine's.

import XCTest
@testable import LumenCore

final class ViewingConditionsTests: XCTestCase {

    private let normal = 0.165   // Lumen.surroundCanvas

    // MARK: - Lights out

    /// Three presses of `L` return where they started, which is what makes it a cycle
    /// rather than a switch with a hidden third state.
    func testTheCycleReturns() {
        XCTAssertEqual(LightsOut.normal.next, .dim)
        XCTAssertEqual(LightsOut.dim.next, .out)
        XCTAssertEqual(LightsOut.out.next, .normal)
        XCTAssertEqual(LightsOut.normal.next.next.next, .normal)
    }

    /// The middle rung has to stay usable — the point of it is to quiet the panels
    /// while still editing. A rung nobody can read is not dim, it is off, and then the
    /// cycle has two offs and no dim.
    func testTheDimRungIsStillLegibleAndTheOutRungIsGone() {
        XCTAssertGreaterThan(LightsOut.dim.chromeOpacity, 0.2)
        XCTAssertLessThan(LightsOut.dim.chromeOpacity, 1)
        XCTAssertEqual(LightsOut.out.chromeOpacity, 0)
        XCTAssertTrue(LightsOut.out.hidesChrome)
        XCTAssertFalse(LightsOut.dim.hidesChrome,
                       "dim must keep the chrome in the layout — it is still clickable")
    }

    // MARK: - Assessment

    /// ISO 12646 asks for the photograph's own mid-tone as the field. Not a taste
    /// value: it is `LumenLog.midGrey` through the display's transfer function, so it
    /// follows the engine's anchor rather than being written down twice.
    func testTheAssessmentSurroundIsTheEnginesOwnMidGrey() {
        let expected = TransferFunction.srgb.encode(LumenLog.midGrey)
        XCTAssertEqual(ViewingConditions.assessmentSurround(), expected, accuracy: 1e-12)
        // 0.4614, not the 0.4626 that gets quoted everywhere: that figure is 0.18
        // through a pure 2.2 gamma, and sRGB's actual curve is piecewise with a 1/2.4
        // exponent and a linear toe. Written out because the two are a code value apart
        // and the wrong one looks right.
        XCTAssertEqual(ViewingConditions.assessmentSurround(), 0.46136, accuracy: 5e-5,
                       "0.18 scene-linear should encode to 0.4614 in sRGB — if this "
                       + "moved, the engine's mid-grey anchor moved with it")
    }

    /// THE DISAGREEMENT WITH LIGHTROOM, pinned. docs/12 §12.7: "LR's Lights Out dims to
    /// black, which is the *wrong* surround for judging tone." So a mode whose only
    /// purpose is judging tone must not be overridden by one whose purpose is getting
    /// out of the way.
    func testAssessmentBeatsLightsOutForTheSurround() {
        let both = ViewingConditions.surround(lights: .out, assessment: true,
                                              normalSurround: normal)
        XCTAssertEqual(both, ViewingConditions.assessmentSurround(), accuracy: 1e-12,
                       "lights-out's black took the field away from assessment mode, "
                       + "which is the one thing assessment mode is for")
        // And it still takes the chrome away, which is the half it is entitled to.
        XCTAssertEqual(ViewingConditions.chromeOpacity(lights: .out, assessment: true), 0)
    }

    func testTheWhiteAnchorBelongsToAssessmentAlone() {
        XCTAssertTrue(ViewingConditions.showsWhiteAnchor(assessment: true))
        XCTAssertFalse(ViewingConditions.showsWhiteAnchor(assessment: false),
                       "a white line around the photograph in ordinary use is a border, "
                       + "and this app draws no borders")
    }

    // MARK: - What must NOT change

    /// Ordinary use is untouched by either control being off.
    func testNeitherControlChangesAnythingWhenBothAreOff() {
        XCTAssertEqual(ViewingConditions.surround(lights: .normal, assessment: false,
                                                  normalSurround: normal), normal)
        XCTAssertEqual(ViewingConditions.chromeOpacity(lights: .normal,
                                                       assessment: false), 1)
        XCTAssertFalse(ViewingConditions.showsWhiteAnchor(assessment: false))
    }

    /// Dim quiets the chrome and leaves the field alone — it is a chrome control, and
    /// the photograph is untouched (docs/12 §12.7: "image untouched").
    func testDimDoesNotMoveTheField() {
        XCTAssertEqual(ViewingConditions.surround(lights: .dim, assessment: false,
                                                  normalSurround: normal), normal)
        XCTAssertLessThan(ViewingConditions.chromeOpacity(lights: .dim,
                                                          assessment: false), 1)
    }

    /// The quieter of the two wins the chrome, so neither control can make the
    /// interface LOUDER than the other left it.
    func testTheQuieterControlWinsTheChrome() {
        for lights in LightsOut.allCases {
            for assessment in [true, false] {
                let out = ViewingConditions.chromeOpacity(lights: lights,
                                                          assessment: assessment)
                XCTAssertLessThanOrEqual(out, lights.chromeOpacity)
                if assessment { XCTAssertLessThanOrEqual(out, 0.35) }
            }
        }
    }
}
