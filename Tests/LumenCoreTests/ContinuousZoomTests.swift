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

    // MARK: The fit zoom's denomination (the first-pinch jump)

    /// The viewer draws `zoomLevel × fullLongEdge` device pixels, so the fit zoom is
    /// the level whose product is the fitted extent. This is the arithmetic the whole
    /// continuity of the first gesture rests on.
    func testTheFitZoomDrawsExactlyTheFittedExtent() {
        // A 1920-device-pixel viewport showing a proxy rendered to fill it, against a
        // 4096 zoomed render cap.
        let fit = ContinuousZoom.fitZoom(proxyFitRatio: 1.0, proxyLongEdge: 1920,
                                         zoomedFullLongEdge: 4096)
        XCTAssertEqual(fit * 4096, 1920, accuracy: 1e-9)
    }

    /// THE REGRESSION (owner, session C): "a lot of times it jumps, especially the
    /// first zoom in. Anything after that is fine, except for the first big jump."
    ///
    /// The viewer asks for the VIEWPORT's pixels at fit and the CAP's when zoomed, so
    /// the denominator changes the instant a gesture leaves fit. Computing the start
    /// against the fit-mode denominator — 1920/1920, i.e. 1.0 — and then multiplying
    /// it under the zoomed one drew 4096 device pixels for a 1920 viewport: a 2.13×
    /// jump on the first pinch, and every pinch after it continuous, because by then
    /// both sides were already the cap. Expressed as the thing that must stay true:
    /// one unit of magnification must leave the picture the size it already was.
    func testTheFirstPinchDoesNotJump() {
        let viewport = 1920.0
        let cap = 4096
        let fit = ContinuousZoom.fitZoom(proxyFitRatio: 1.0, proxyLongEdge: 1920,
                                         zoomedFullLongEdge: cap)
        let barelyMoved = ContinuousZoom.pinched(startZoom: ZoomLadder.fit,
                                                 fitRatio: fit,
                                                 magnification: 1.05)
        let drawnDevicePixels = barelyMoved * Double(cap)
        XCTAssertEqual(drawnDevicePixels / viewport, 1.05, accuracy: 0.001,
                       "a 5% pinch must grow the picture by 5%, not by the ratio "
                           + "between the two render request sizes")
    }

    func testTheZoomedBasisIsTheCapOrTheFramesOwnPixels() {
        // Any modern camera is larger than the cap: the cap is what a zoomed render
        // delivers.
        XCTAssertEqual(ContinuousZoom.zoomedFullLongEdge(nativeLongEdge: 7008,
                                                         renderCap: 4096), 4096)
        // A small frame delivers all of itself and no more.
        XCTAssertEqual(ContinuousZoom.zoomedFullLongEdge(nativeLongEdge: 3000,
                                                         renderCap: 4096), 3000)
        // Not yet known, or nonsense: assume the cap, which the first settle corrects.
        XCTAssertEqual(ContinuousZoom.zoomedFullLongEdge(nativeLongEdge: nil,
                                                         renderCap: 4096), 4096)
        XCTAssertEqual(ContinuousZoom.zoomedFullLongEdge(nativeLongEdge: 0,
                                                         renderCap: 4096), 4096)
    }

    func testAFitZoomWithNothingUsableFallsBackToTheProxyRatio() {
        XCTAssertEqual(ContinuousZoom.fitZoom(proxyFitRatio: 0.5, proxyLongEdge: 0,
                                              zoomedFullLongEdge: 4096), 0.5)
        XCTAssertEqual(ContinuousZoom.fitZoom(proxyFitRatio: 0.5, proxyLongEdge: 1920,
                                              zoomedFullLongEdge: 0), 0.5)
    }

    // MARK: The scroll zoom

    /// A scroll COMPOUNDS where a pinch multiplies its start — the difference between
    /// an instrument that reports increments and one that reports a total.
    func testScrollCompoundsWhereAPinchDoesNot() {
        let fit = 0.2
        var zoom = ContinuousZoom.scrolled(currentZoom: 1, fitRatio: fit, factor: 1.2)
        zoom = ContinuousZoom.scrolled(currentZoom: zoom, fitRatio: fit, factor: 1.2)
        XCTAssertEqual(zoom, 1.44, accuracy: 1e-9,
                       "two scroll events of 1.2 are worth 1.44, not 1.2")
        // The pinch, given the same two events, reports 1.2 total both times and must
        // land on 1.2 — which is why it takes a START rather than the current level.
        XCTAssertEqual(ContinuousZoom.pinched(startZoom: 1, fitRatio: fit,
                                              magnification: 1.2), 1.2, accuracy: 1e-9)
    }

    /// A scroll out lands ON fit rather than a hair above it, through the same snap
    /// both gestures use — otherwise the only way back is a different verb.
    func testScrollingOutSnapsToFit() {
        let fit = 0.25
        XCTAssertEqual(ContinuousZoom.scrolled(currentZoom: 0.26, fitRatio: fit,
                                               factor: 0.9),
                       ZoomLadder.fit)
        // And a scroll IN from fit starts at the fit ratio rather than at zero, which
        // no multiplication could leave.
        XCTAssertEqual(ContinuousZoom.scrolled(currentZoom: ZoomLadder.fit,
                                               fitRatio: fit, factor: 2),
                       0.5, accuracy: 1e-9)
    }

    func testScrollIsClampedAndRefusesNonsense() {
        XCTAssertEqual(ContinuousZoom.scrolled(currentZoom: 8, fitRatio: 0.2,
                                               factor: 100),
                       ZoomLadder.maximum,
                       "a runaway flick is clamped by the same ladder as everything else")
        XCTAssertEqual(ContinuousZoom.scrolled(currentZoom: 2, fitRatio: 0.2,
                                               factor: .nan), 2)
        XCTAssertEqual(ContinuousZoom.scrolled(currentZoom: 2, fitRatio: 0.2,
                                               factor: 0), 2)
    }
}
