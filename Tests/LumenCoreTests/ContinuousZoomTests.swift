// The two numbers the continuous zoom gestures share. The gestures' own contract —
// anchoring, the fit floor, the first pinch — is `ViewerViewportTests`.
import XCTest
@testable import LumenCore

final class ContinuousZoomTests: XCTestCase {

    func testTheZoomedAskIsTheCapOrTheFramesOwnPixels() {
        // Larger than the cap: the cap is what a zoomed render delivers.
        XCTAssertEqual(ContinuousZoom.zoomedFullLongEdge(nativeLongEdge: 7008,
                                                         renderCap: 4096), 4096)
        // A small frame delivers all of itself and no more.
        XCTAssertEqual(ContinuousZoom.zoomedFullLongEdge(nativeLongEdge: 3000,
                                                         renderCap: 4096), 3000)
        // Not yet known, or nonsense: assume the cap.
        XCTAssertEqual(ContinuousZoom.zoomedFullLongEdge(nativeLongEdge: nil,
                                                         renderCap: 4096), 4096)
        XCTAssertEqual(ContinuousZoom.zoomedFullLongEdge(nativeLongEdge: 0,
                                                         renderCap: 4096), 4096)
    }

    /// Wide enough to catch a release a hair above fit, narrow enough that the
    /// correction at release is not a visible change of size.
    func testTheEndOfGestureSnapIsSmall() {
        XCTAssertGreaterThan(ContinuousZoom.fitSnapSlack, 1)
        XCTAssertLessThanOrEqual(ContinuousZoom.fitSnapSlack, 1.03)
    }
}
