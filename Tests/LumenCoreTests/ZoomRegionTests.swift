// The zoomed region ask (docs/32 fifth round): the visible rectangle plus a margin,
// snapped OUTWARD to a grid so a drifting pan mints a new render key only when it
// leaves the margin — and nil whenever the whole frame is (nearly) on screen, where
// whole-frame rendering and its ladder cost model are the right tool.
import XCTest
@testable import LumenCore

final class ZoomRegionTests: XCTestCase {

    private let container = CGSize(width: 1000, height: 800)

    /// A frame drawn smaller than the container — every fit render — is not a region.
    func testWholeFrameVisibleIsNil() {
        XCTAssertNil(ZoomRegion.requestUnit(container: container,
                                            drawnFull: CGSize(width: 900, height: 600),
                                            pan: .zero),
                     "a frame entirely on screen must render whole, on the ladder")
    }

    /// A frame drawn exactly at the container still answers nil: the margin would
    /// reach past every edge, so the region would BE the whole frame at higher cost.
    func testExactlyFillingFrameIsNil() {
        XCTAssertNil(ZoomRegion.requestUnit(container: container,
                                            drawnFull: container, pan: .zero))
    }

    /// Deep zoom, centred: the region contains the visible viewport plus the margin,
    /// stays inside the unit square, and lands on the snap grid.
    func testCentredZoomContainsViewportAndMargin() throws {
        let drawn = CGSize(width: 10_000, height: 8_000)
        let region = try XCTUnwrap(ZoomRegion.requestUnit(container: container,
                                                          drawnFull: drawn, pan: .zero))
        // The visible rectangle in unit space is [0.45, 0.55] on both axes; the
        // margin pushes each edge out by a quarter viewport (0.025 here).
        XCTAssertLessThanOrEqual(region.minX, 0.45 - 0.025 + 1e-9)
        XCTAssertGreaterThanOrEqual(region.maxX, 0.55 + 0.025 - 1e-9)
        XCTAssertLessThanOrEqual(region.minY, 0.45 - 0.025 + 1e-9)
        XCTAssertGreaterThanOrEqual(region.maxY, 0.55 + 0.025 - 1e-9)
        XCTAssertGreaterThanOrEqual(region.minX, 0)
        XCTAssertGreaterThanOrEqual(region.minY, 0)
        XCTAssertLessThanOrEqual(region.maxX, 1)
        XCTAssertLessThanOrEqual(region.maxY, 1)
        for edge in [region.minX, region.minY, region.maxX, region.maxY] {
            let cells = Double(edge) / ZoomRegion.grid
            XCTAssertEqual(cells, cells.rounded(), accuracy: 1e-9,
                           "edges snap to the grid so a drifting pan re-keys rarely")
        }
        // And it is a small fraction of the frame — the whole point of the ask.
        XCTAssertLessThan(Double(region.width), 0.3)
        XCTAssertLessThan(Double(region.height), 0.3)
    }

    /// A pan small next to the grid cell answers the SAME rectangle — the render key
    /// must not move per pan point.
    func testSmallPanIsQuantizedAway() throws {
        let drawn = CGSize(width: 10_000, height: 8_000)
        let a = try XCTUnwrap(ZoomRegion.requestUnit(container: container,
                                                     drawnFull: drawn, pan: .zero))
        let b = try XCTUnwrap(ZoomRegion.requestUnit(
            container: container, drawnFull: drawn,
            pan: CGSize(width: 40, height: -30)))
        XCTAssertEqual(a, b, "a 40 pt drift is inside the margin and the grid cell")
    }

    /// Panned hard against the left edge: the region is clamped at 0 there and does
    /// not reach the far side of the frame.
    func testEdgePanClampsWithoutCrossing() throws {
        let drawn = CGSize(width: 10_000, height: 8_000)
        // The clamp the viewer applies: the image's left edge at the container's.
        let pan = CGSize(width: (drawn.width - container.width) / 2, height: 0)
        let region = try XCTUnwrap(ZoomRegion.requestUnit(container: container,
                                                          drawnFull: drawn, pan: pan))
        XCTAssertEqual(Double(region.minX), 0, accuracy: 1e-9)
        XCTAssertLessThan(Double(region.maxX), 0.5,
                          "the far half of the frame is off screen and unpaid for")
    }

    /// One axis fully visible, the other zoomed: still a region — the visible axis
    /// simply spans the whole unit range.
    func testOneVisibleAxisSpansUnit() throws {
        let drawn = CGSize(width: 10_000, height: 600)
        let region = try XCTUnwrap(ZoomRegion.requestUnit(container: container,
                                                          drawnFull: drawn, pan: .zero))
        XCTAssertEqual(Double(region.minY), 0, accuracy: 1e-9)
        XCTAssertEqual(Double(region.maxY), 1, accuracy: 1e-9)
        XCTAssertLessThan(Double(region.width), 0.5)
    }

    /// Degenerate and hostile inputs answer nil or a safe rectangle, never a crash
    /// or an empty rect.
    func testDegenerateInputsAreSafe() {
        XCTAssertNil(ZoomRegion.requestUnit(container: .zero,
                                            drawnFull: CGSize(width: 100, height: 100),
                                            pan: .zero))
        XCTAssertNil(ZoomRegion.requestUnit(container: container,
                                            drawnFull: .zero, pan: .zero))
        XCTAssertNil(ZoomRegion.requestUnit(
            container: container,
            drawnFull: CGSize(width: CGFloat.nan, height: 100), pan: .zero))
        // A NaN pan is treated as no pan, not poison.
        let region = ZoomRegion.requestUnit(
            container: container,
            drawnFull: CGSize(width: 10_000, height: 8_000),
            pan: CGSize(width: CGFloat.nan, height: .nan))
        XCTAssertNotNil(region)
        if let region {
            XCTAssertGreaterThan(Double(region.width), 0)
            XCTAssertGreaterThan(Double(region.height), 0)
        }
    }

    /// The margin arithmetic the affordability claim rests on: a quarter viewport per
    /// side is 2.25× the visible pixels, so a region render costs the viewport class,
    /// not the sensor class.
    func testMarginCostFactor() {
        let factor = (1 + 2 * ZoomRegion.marginFraction)
            * (1 + 2 * ZoomRegion.marginFraction)
        XCTAssertEqual(factor, 2.25, accuracy: 1e-12)
    }
}
