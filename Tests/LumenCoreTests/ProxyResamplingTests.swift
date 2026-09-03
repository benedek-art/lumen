// How a proxy is resampled when it is drawn — the rule that decided every draft frame
// at fit was a pixel-level inspection. See `ProxyResampling` for the argument.
import XCTest
@testable import LumenCore

final class ProxyResamplingTests: XCTestCase {

    /// A 16-inch MacBook Pro's centre pane: 1180 pt beside a 230 pt sidebar and a
    /// 320 pt develop column, at 2×. Every number below is what that viewport actually
    /// asks for.
    private let paneDevicePixels = 2360

    private func fitRatio(proxy: Int) -> Double { Double(paneDevicePixels) / Double(proxy) }

    /// THE DEFECT, at the sizes it actually occurred at. A draft is smaller than the
    /// viewport, so its drawn ratio is above 1 — exactly like a 1:1 inspection — and the
    /// old rule read that as "show the pixels that exist". They are the PROXY's pixels,
    /// and magnifying them unsmoothed is aliasing, not honesty.
    func testEveryDraftAtFitIsResampledRatherThanBlockUpscaled() {
        // proxy long edge → the magnification it suffers in this pane
        for proxy in [1728, 1280, 1024, 768, 576] {
            let ratio = fitRatio(proxy: proxy)
            XCTAssertGreaterThan(ratio, 1,
                                 "the fixture must be a magnification — that is the "
                                     + "case the old rule got wrong")
            let mode = ProxyResampling.mode(zoomRatio: 0, drawnRatio: ratio,
                                            renderedLongEdge: proxy,
                                            fullLongEdge: 2560)
            XCTAssertEqual(mode, .linear,
                           "a \(proxy) px draft magnified \(String(format: "%.2f", ratio))× "
                               + "at fit must be smoothed; unsmoothed it is a blocky "
                               + "picture whose edges shimmer from frame to frame")
        }
    }

    /// The case the old rule was written for, and which must still work: the user has
    /// zoomed to 1:1 and the settled full-resolution frame is up. These ARE the pixels
    /// that exist, and smoothing them would be a guess.
    func testAOneToOneInspectionOfASettledFrameShowsItsPixels() {
        XCTAssertEqual(ProxyResampling.mode(zoomRatio: 1.0, drawnRatio: 1.0,
                                            renderedLongEdge: 4096, fullLongEdge: 4096),
                       ProxyResampling.none)
        XCTAssertEqual(ProxyResampling.mode(zoomRatio: 2.0, drawnRatio: 2.0,
                                            renderedLongEdge: 4096, fullLongEdge: 4096),
                       ProxyResampling.none)
    }

    /// And the case that distinguishes the new rule from the old one: zoomed to 1:1
    /// with a DRAFT still on screen. The ratio says magnify; the frame is not the
    /// photograph's pixels, so it is smoothed until the settle brings the real ones.
    func testAOneToOneInspectionOfADraftIsStillResampled() {
        XCTAssertEqual(ProxyResampling.mode(zoomRatio: 1.0, drawnRatio: 2.0,
                                            renderedLongEdge: 2048, fullLongEdge: 4096),
                       .linear,
                       "a draft magnified to 1:1 has no source pixels to show; drawing "
                           + "its own unsmoothed claims a sharpness the file does not "
                           + "have here yet")
    }

    /// Minification is filtered, which the old rule already got right.
    func testMinificationIsFiltered() {
        XCTAssertEqual(ProxyResampling.mode(zoomRatio: 0, drawnRatio: 0.92,
                                            renderedLongEdge: 2560, fullLongEdge: 2560),
                       .filtered,
                       "nearest-neighbour minification is aliasing")
    }

    /// Not knowing the settle's size must fail SAFE. It is nil before the first render
    /// of a photograph, and assuming "this is full resolution" there would draw the
    /// very first frame of every photo blocky.
    func testAnUnknownFullResolutionIsTreatedAsAProxy() {
        XCTAssertEqual(ProxyResampling.mode(zoomRatio: 2.0, drawnRatio: 2.0,
                                            renderedLongEdge: 4096, fullLongEdge: nil),
                       .linear)
    }

    /// Fit is never a pixel inspection, whatever the proxy's size — including the
    /// degenerate case of a frame larger than the viewport.
    func testFitIsNeverAPixelInspection() {
        for zoom in [0.0] {
            for (rendered, ratio) in [(2560, 0.92), (1280, 1.84), (576, 4.10)] {
                XCTAssertNotEqual(
                    ProxyResampling.mode(zoomRatio: zoom, drawnRatio: ratio,
                                         renderedLongEdge: rendered, fullLongEdge: 2560),
                    ProxyResampling.none,
                    "at fit the frame is whatever proxy the render path could afford, "
                        + "which is never a statement about the sensor's pixels")
            }
        }
    }
}
