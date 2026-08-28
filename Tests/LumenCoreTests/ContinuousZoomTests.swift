// The continuous zoom gestures' contract: pinch and scrub both start from what is on
// screen (fit starts from the fit ratio), track the gesture exponentially, snap to
// fit instead of hovering above it or shrinking below it, and treat garbage input as
// "stay where you are".
import XCTest
@testable import LumenCore

final class ContinuousZoomTests: XCTestCase {

    // MARK: Pinch

    func testAPinchFromFitZoomsInFromTheFitRatio() {
        XCTAssertEqual(ContinuousZoom.pinched(startZoom: 0, fitRatio: 0.4,
                                              magnification: 2.0),
                       0.8, accuracy: 1e-12)
    }

    func testAPinchFromAZoomedRatioMultipliesThatRatio() {
        XCTAssertEqual(ContinuousZoom.pinched(startZoom: 1.0, fitRatio: 0.4,
                                              magnification: 1.5),
                       1.5, accuracy: 1e-12)
    }

    func testPinchingOutSnapsToFitInsteadOfHoveringAboveIt() {
        // 1.0 × 0.405 = 0.405 ≤ 0.4 × 1.02: inside the slack, so fit — not a frame
        // imperceptibly larger than fit that can never be reached exactly.
        XCTAssertEqual(ContinuousZoom.pinched(startZoom: 1.0, fitRatio: 0.4,
                                              magnification: 0.405),
                       ZoomLadder.fit)
        // And never below fit: the picture cannot be pinched smaller than the window.
        XCTAssertEqual(ContinuousZoom.pinched(startZoom: 0, fitRatio: 0.4,
                                              magnification: 0.5),
                       ZoomLadder.fit)
    }

    func testARunawayPinchIsCappedByTheLadder() {
        XCTAssertEqual(ContinuousZoom.pinched(startZoom: 1.0, fitRatio: 0.4,
                                              magnification: 1e9),
                       ZoomLadder.maximum)
    }

    func testAGarbageMagnificationChangesNothing() {
        XCTAssertEqual(ContinuousZoom.pinched(startZoom: 1.5, fitRatio: 0.4,
                                              magnification: .nan), 1.5)
        XCTAssertEqual(ContinuousZoom.pinched(startZoom: 1.5, fitRatio: 0.4,
                                              magnification: 0), 1.5)
    }

    // MARK: Scrub

    func testOneDoublingDistanceRightDoublesFromFit() {
        XCTAssertEqual(ContinuousZoom.scrubbed(
                           startZoom: 0, fitRatio: 0.4,
                           horizontalTravel: ContinuousZoom.scrubPointsPerDoubling),
                       0.8, accuracy: 1e-12)
    }

    func testAStationaryOrLeftwardScrubFromFitStaysAtFit() {
        // The jitter of a press must not zoom — this is what replaces the old
        // click-detection threshold.
        XCTAssertEqual(ContinuousZoom.scrubbed(startZoom: 0, fitRatio: 0.4,
                                               horizontalTravel: 0), ZoomLadder.fit)
        XCTAssertEqual(ContinuousZoom.scrubbed(startZoom: 0, fitRatio: 0.4,
                                               horizontalTravel: 2), ZoomLadder.fit)
        XCTAssertEqual(ContinuousZoom.scrubbed(startZoom: 0, fitRatio: 0.4,
                                               horizontalTravel: -300), ZoomLadder.fit)
    }

    func testScrubTravelIsExponentialSoEqualTravelMeansEqualSteps() {
        let one = ContinuousZoom.scrubbed(startZoom: 0, fitRatio: 0.4,
                                          horizontalTravel: 150)
        let two = ContinuousZoom.scrubbed(startZoom: 0, fitRatio: 0.4,
                                          horizontalTravel: 300)
        XCTAssertEqual(two / one, 2.0, accuracy: 1e-9)
    }

    func testAGarbageTravelChangesNothing() {
        XCTAssertEqual(ContinuousZoom.scrubbed(startZoom: 1.5, fitRatio: 0.4,
                                               horizontalTravel: .infinity), 1.5)
    }

    // MARK: The shared start rule

    func testFitWithNoUsableFitRatioStartsFromOneToOne() {
        // No image yet: 1:1 rather than a zero that no multiplication escapes.
        XCTAssertEqual(ContinuousZoom.pinched(startZoom: 0, fitRatio: 0,
                                              magnification: 2.0),
                       2.0, accuracy: 1e-12)
    }
}
