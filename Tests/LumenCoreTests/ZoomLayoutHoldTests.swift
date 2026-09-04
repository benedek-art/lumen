// The scale a held canvas wears. Every degenerate input must answer 1 — a
// `scaleEffect` given 0, NaN or infinity draws no photograph at all, which is the one
// outcome worse than the slowness this hold exists to fix.
import XCTest
@testable import LumenCore

final class ZoomLayoutHoldTests: XCTestCase {

    /// Not held: the two extents are the same measurement, and the identity comes back
    /// exactly rather than as 0.9999999999999999.
    func testUnheldIsExactlyOne() {
        XCTAssertEqual(ZoomLayoutHold.stretch(base: 1234.5678, live: 1234.5678), 1)
        XCTAssertEqual(ZoomLayoutHold.stretch(base: 1, live: 1), 1)
    }

    /// Held: the ratio of the two drawn extents, which is the magnification the
    /// gesture has travelled since the hold began.
    func testStretchIsTheRatioOfDrawnExtents() {
        XCTAssertEqual(ZoomLayoutHold.stretch(base: 1000, live: 2000), 2, accuracy: 1e-12)
        XCTAssertEqual(ZoomLayoutHold.stretch(base: 2000, live: 1000), 0.5, accuracy: 1e-12)
        XCTAssertEqual(ZoomLayoutHold.stretch(base: 1440, live: 1800), 1.25, accuracy: 1e-12)
    }

    /// A pinch out of fit and back is the round trip the snap-to-fit rule makes
    /// common; it must land back on the frame it started from.
    func testRoundTripReturnsToOne() {
        let base = 1633.0
        let out = ZoomLayoutHold.stretch(base: base, live: base * 3.7)
        XCTAssertEqual(ZoomLayoutHold.stretch(base: base * 3.7, live: base) * out, 1,
                       accuracy: 1e-12)
    }

    /// Zero, negative, NaN and infinite extents all answer 1 — draw it where it is.
    func testDegenerateInputsAnswerOne() {
        XCTAssertEqual(ZoomLayoutHold.stretch(base: 0, live: 1000), 1)
        XCTAssertEqual(ZoomLayoutHold.stretch(base: 1000, live: 0), 1)
        XCTAssertEqual(ZoomLayoutHold.stretch(base: -1000, live: 1000), 1)
        XCTAssertEqual(ZoomLayoutHold.stretch(base: 1000, live: -1000), 1)
        XCTAssertEqual(ZoomLayoutHold.stretch(base: .nan, live: 1000), 1)
        XCTAssertEqual(ZoomLayoutHold.stretch(base: 1000, live: .nan), 1)
        XCTAssertEqual(ZoomLayoutHold.stretch(base: .infinity, live: 1000), 1)
        XCTAssertEqual(ZoomLayoutHold.stretch(base: 1000, live: .infinity), 1)
    }

    /// The extremes a deep zoom actually reaches stay finite and positive — the
    /// property the view layer relies on rather than the exact numbers.
    func testExtremesStayFiniteAndPositive() {
        for live in [1e-6, 1e-3, 1.0, 1e3, 1e6, 1e9] {
            let scale = ZoomLayoutHold.stretch(base: 1633, live: live)
            XCTAssertTrue(scale.isFinite, "scale for live=\(live) must be finite")
            XCTAssertGreaterThan(scale, 0, "scale for live=\(live) must be positive")
        }
    }

    /// The quiet window is long enough to sit inside a gesture's own event gaps and
    /// short enough to read as one motion. Stated as a range so the number can be
    /// tuned without the test becoming a copy of it.
    func testQuietWindowIsAGestureGapNotAPause() {
        let ms = Double(ZoomLayoutHold.quietNanoseconds) / 1_000_000
        XCTAssertGreaterThanOrEqual(ms, 80, "shorter than this ends holds mid-gesture")
        XCTAssertLessThanOrEqual(ms, 250, "longer than this reads as a lag, not a settle")
    }
}
