// The zoomed draw ratio's contract (the MAC-07 mechanism, found in the owner's second
// session): while zoomed, every proxy the render path delivers — ladder-capped draft,
// instant embedded preview, or the settle itself — must occupy the SAME on-screen
// extent, so a slider drag changes sharpness and never size.
#if os(macOS)

import XCTest
@testable import LumenApp

final class ZoomedRatioTests: XCTestCase {

    func testTheSettleDrawsAtTheBareZoomLevel() {
        XCTAssertEqual(LoupeGeometry.zoomedRatio(zoomLevel: 1.0, fullLongEdge: 4600,
                                                 renderedLongEdge: 4600),
                       1.0, "full-resolution pixels at 1:1 are the definition of 1:1")
        XCTAssertEqual(LoupeGeometry.zoomedRatio(zoomLevel: 0.5, fullLongEdge: 4600,
                                                 renderedLongEdge: 4600),
                       0.5)
    }

    func testADraftOccupiesTheSettlesExtentExactly() {
        // The shipped defect: a 1024px draft of a 4600px photograph drew at 1024
        // points-ish while the settle drew at 4600 — a 4.5x size flip on every slider
        // event. Normalized, the two drawn widths must agree to the point.
        let zoom = 1.0
        let scale: CGFloat = 2
        let settleDrawn = LoupeGeometry.drawnSize(
            imageWidth: 4600, imageHeight: 3067,
            ratio: LoupeGeometry.zoomedRatio(zoomLevel: zoom, fullLongEdge: 4600,
                                             renderedLongEdge: 4600),
            displayScale: scale)
        let draftDrawn = LoupeGeometry.drawnSize(
            imageWidth: 1024, imageHeight: 683,
            ratio: LoupeGeometry.zoomedRatio(zoomLevel: zoom, fullLongEdge: 4600,
                                             renderedLongEdge: 1024),
            displayScale: scale)
        XCTAssertEqual(Double(draftDrawn.width), Double(settleDrawn.width),
                       accuracy: 0.001,
                       "the long edge normalizes exactly — this is the whole contract")
        // The short edge inherits the proxy's integer rounding; a pixel of drift is
        // the resampler's, not the geometry's.
        XCTAssertEqual(Double(draftDrawn.height), Double(settleDrawn.height),
                       accuracy: 2.0)
    }

    func testTheInstantPreviewNormalizesToo() {
        // The embedded preview can be tiny (512-class); it stands in for the settle
        // the same way a draft does.
        let drawn = LoupeGeometry.drawnSize(
            imageWidth: 512, imageHeight: 341,
            ratio: LoupeGeometry.zoomedRatio(zoomLevel: 2.0, fullLongEdge: 4096,
                                             renderedLongEdge: 512),
            displayScale: 2)
        XCTAssertEqual(Double(drawn.width), 4096.0, accuracy: 0.001,
                       "512 x (2.0 x 4096/512) / scale 2 = 4096 points")
    }

    func testUnknownFullSizeFallsBackToTheBareLevelInsteadOfHiding() {
        // Before the first request is even recorded there is nothing to normalize by;
        // the bare level is the shipped (wrong-at-draft) behaviour, but it is finite,
        // visible and self-corrects on the next apply — a 1-frame window, not a state.
        XCTAssertEqual(LoupeGeometry.zoomedRatio(zoomLevel: 1.0, fullLongEdge: 0,
                                                 renderedLongEdge: 1024),
                       1.0)
        XCTAssertEqual(LoupeGeometry.zoomedRatio(zoomLevel: 1.0, fullLongEdge: 4600,
                                                 renderedLongEdge: 0),
                       1.0)
    }
}

#endif
