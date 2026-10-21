import XCTest
@testable import LumenCore

/// The eyedropper's zoom-aware sample window (docs/quality/lanes/WS-02/SPEC.md B1, H3):
/// Lightroom's 5x5 screen-pixel rule, written as a radius.
final class PickSampleTests: XCTestCase {

    /// Above 100% zoom (one source pixel spans one or more device pixels) the window is
    /// 5x5 IMAGE pixels, the floor.
    func testAbove100PercentIsFiveImagePixels() {
        for s in [0.125, 0.5, 1.0] {
            XCTAssertEqual(PickSample.radius(sourcePixelsPerDevicePixel: s), 2, "s = \(s)")
        }
    }

    /// A 6024 px frame at Fit in the 1686-device-pixel viewer of a 1512 pt window.
    func testFitOnA24MPFrameIsNineteenPixels() {
        XCTAssertEqual(PickSample.radius(sourcePixelsPerDevicePixel: 6024.0 / 1686), 9)
    }

    /// The G9's 5184 px frame: a smaller window, by Lightroom's own rule.
    func testFitOnTheG9IsSeventeenPixels() {
        XCTAssertEqual(PickSample.radius(sourcePixelsPerDevicePixel: 5184.0 / 1686), 8)
    }

    func testTheCapIs63Pixels() {
        XCTAssertEqual(PickSample.radius(sourcePixelsPerDevicePixel: 100), 31)
        XCTAssertEqual(PickSample.radius(sourcePixelsPerDevicePixel: 1e300), 31)
    }

    func testRadiusNeverDecreasesWithZoomOut() {
        var previous = PickSample.radius(sourcePixelsPerDevicePixel: 0.05)
        var step = 0
        while true {
            let s = 0.05 + Double(step) * 0.01
            guard s <= 60 + 1e-9 else { break }
            let r = PickSample.radius(sourcePixelsPerDevicePixel: s)
            XCTAssertGreaterThanOrEqual(r, previous, "radius fell at s = \(s)")
            XCTAssertTrue((2...31).contains(r), "radius \(r) out of range at s = \(s)")
            previous = r
            step += 1
        }
    }

    func testGarbageInputFallsBackToTwo() {
        for s in [Double.nan, .infinity, -.infinity, 0, -1] {
            XCTAssertEqual(PickSample.radius(sourcePixelsPerDevicePixel: s), 2, "s = \(s)")
        }
    }

    /// The square drawn under the pointer covers exactly the sampled window on screen.
    func testIndicatorSideMatchesTheSampleWindow() {
        XCTAssertEqual(PickSample.indicatorSidePoints(radius: 9, sourcePixelsPerDevicePixel: 3.57,
                                                      backingScale: 2),
                       2.661, accuracy: 0.001)
        for s in [0.125, 0.5, 1.0] {
            let r = PickSample.radius(sourcePixelsPerDevicePixel: s)
            for backing in [1.0, 2.0] {
                XCTAssertEqual(PickSample.indicatorSidePoints(radius: r,
                                                              sourcePixelsPerDevicePixel: s,
                                                              backingScale: backing),
                               5 / s / backing, accuracy: 1e-12, "s = \(s), backing \(backing)")
            }
        }
    }
}
