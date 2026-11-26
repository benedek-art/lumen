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

    func testTheZoomedAskIsOnePixelPerDevicePixel() {
        // At and above 1:1 the full ask.
        XCTAssertEqual(ContinuousZoom.zoomedAskLongEdge(fullLongEdge: 6000, zoom: 1), 6000)
        XCTAssertEqual(ContinuousZoom.zoomedAskLongEdge(fullLongEdge: 6000, zoom: 4), 6000)
        // Below it, what the panel draws, bucketed up.
        XCTAssertEqual(ContinuousZoom.zoomedAskLongEdge(fullLongEdge: 6000, zoom: 0.25), 1536)
        XCTAssertEqual(ContinuousZoom.zoomedAskLongEdge(fullLongEdge: 6000, zoom: 0.26), 1792)
        XCTAssertEqual(ContinuousZoom.zoomedAskLongEdge(fullLongEdge: 6000, zoom: 0.99), 6000)
        for zoom in stride(from: 0.05, to: 1.0, by: 0.01) {
            let ask = ContinuousZoom.zoomedAskLongEdge(fullLongEdge: 7008, zoom: zoom)
            XCTAssertGreaterThanOrEqual(Double(ask), zoom * 7008)
            XCTAssertLessThanOrEqual(ask, 7008)
        }
        // Nonsense zooms leave the full ask alone.
        XCTAssertEqual(ContinuousZoom.zoomedAskLongEdge(fullLongEdge: 6000, zoom: 0), 6000)
        XCTAssertEqual(ContinuousZoom.zoomedAskLongEdge(fullLongEdge: 6000, zoom: .nan), 6000)
    }

    /// Wide enough to catch a release a hair above fit, narrow enough that the
    /// correction at release is not a visible change of size.
    func testTheEndOfGestureSnapIsSmall() {
        XCTAssertGreaterThan(ContinuousZoom.fitSnapSlack, 1)
        XCTAssertLessThanOrEqual(ContinuousZoom.fitSnapSlack, 1.03)
    }
}
