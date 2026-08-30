// The viewer's scroll grammar (docs/32 fifth round): a wheel zooms because it has no
// pinch, a trackpad pans because that is what two fingers mean on this platform, and
// ⌥ zooms on either. The owner's report was that the picture answered none of it.
import XCTest
@testable import LumenCore

final class ViewerScrollTests: XCTestCase {

    func testWheelZoomsWithoutAModifier() {
        // A wheel is the instrument with no pinch: plain scroll must zoom, or it has
        // no continuous zoom verb at all — the owner's "pretty broken right now".
        let verb = ViewerScroll.verb(deltaX: 0, deltaY: 1, precise: false,
                                     zoomModifier: false, zoomed: false)
        guard case .zoom(let factor) = verb else {
            return XCTFail("a wheel scroll must zoom, got \(verb)")
        }
        XCTAssertGreaterThan(factor, 1, "scrolling the way you scroll up zooms in")
    }

    func testWheelDirectionIsSymmetric() {
        guard case .zoom(let up) = ViewerScroll.verb(deltaX: 0, deltaY: 3,
                                                     precise: false,
                                                     zoomModifier: false,
                                                     zoomed: true),
              case .zoom(let down) = ViewerScroll.verb(deltaX: 0, deltaY: -3,
                                                       precise: false,
                                                       zoomModifier: false,
                                                       zoomed: true) else {
            return XCTFail("both directions must zoom")
        }
        XCTAssertEqual(up * down, 1, accuracy: 1e-12,
                       "equal travel out must undo equal travel in, exactly")
    }

    func testThreeWheelClicksDoubleTheZoom() {
        // The claim `pointsPerLine`'s comment makes, pinned so a change to either
        // constant has to restate it.
        var factor = 1.0
        for _ in 0..<3 {
            guard case .zoom(let f) = ViewerScroll.verb(deltaX: 0, deltaY: 1,
                                                        precise: false,
                                                        zoomModifier: false,
                                                        zoomed: true) else {
                return XCTFail("a wheel click must zoom")
            }
            factor *= f
        }
        XCTAssertEqual(factor, 2, accuracy: 1e-9)
    }

    func testTrackpadScrollPansWhenZoomed() {
        let verb = ViewerScroll.verb(deltaX: 12, deltaY: -30, precise: true,
                                     zoomModifier: false, zoomed: true)
        XCTAssertEqual(verb, .pan(dx: 12, dy: -30),
                       "two fingers move the picture with them, both axes")
    }

    func testTrackpadScrollAtFitIsIgnored() {
        XCTAssertEqual(ViewerScroll.verb(deltaX: 0, deltaY: -30, precise: true,
                                         zoomModifier: false, zoomed: false),
                       .ignore,
                       "there is nothing to pan when the whole frame is on screen")
    }

    func testOptionZoomsOnEitherInstrument() {
        for precise in [true, false] {
            let verb = ViewerScroll.verb(deltaX: 0, deltaY: 60, precise: precise,
                                         zoomModifier: true, zoomed: true)
            guard case .zoom(let factor) = verb else {
                return XCTFail("⌥-scroll must zoom (precise: \(precise))")
            }
            XCTAssertGreaterThan(factor, 1)
        }
    }

    func testATrackpadFlickIsNotTheWholeRange() {
        // Why `pointsPerDoubling` is coarser than the scrub's: a comfortable flick is
        // on the order of 150 points, and it must not cross fit → 16:1.
        guard case .zoom(let factor) = ViewerScroll.verb(deltaX: 0, deltaY: 150,
                                                         precise: true,
                                                         zoomModifier: true,
                                                         zoomed: true) else {
            return XCTFail("⌥-scroll must zoom")
        }
        XCTAssertLessThan(factor, 2, "one flick is under a doubling")
        XCTAssertGreaterThan(factor, 1.2, "and still worth doing")
    }

    /// N points of scrolling are worth the same zoom however the events are chopped
    /// up — the multiplicative analogue of `ScrollNudge`'s property, and what keeps a
    /// coalesced event stream from changing where a gesture lands.
    func testZoomIsIndependentOfEventChunking() {
        guard case .zoom(let whole) = ViewerScroll.verb(deltaX: 0, deltaY: 80,
                                                        precise: true,
                                                        zoomModifier: true,
                                                        zoomed: true) else {
            return XCTFail("⌥-scroll must zoom")
        }
        var chopped = 1.0
        for _ in 0..<80 {
            guard case .zoom(let f) = ViewerScroll.verb(deltaX: 0, deltaY: 1,
                                                        precise: true,
                                                        zoomModifier: true,
                                                        zoomed: true) else {
                return XCTFail("⌥-scroll must zoom")
            }
            chopped *= f
        }
        XCTAssertEqual(whole, chopped, accuracy: 1e-9)
    }

    func testMomentumIsHonouredForPanAndNotForZoom() {
        XCTAssertTrue(ViewerScroll.honoursMomentum(.pan(dx: 0, dy: 10)),
                      "a document coasts")
        XCTAssertFalse(ViewerScroll.honoursMomentum(.zoom(factor: 1.1)),
                       "magnification after the fingers stop lands nowhere chosen")
        XCTAssertFalse(ViewerScroll.honoursMomentum(.ignore))
    }

    func testZeroAndNonFiniteDeltasAreIgnored() {
        XCTAssertEqual(ViewerScroll.verb(deltaX: 0, deltaY: 0, precise: false,
                                         zoomModifier: false, zoomed: true), .ignore)
        XCTAssertEqual(ViewerScroll.verb(deltaX: 0, deltaY: 0, precise: true,
                                         zoomModifier: false, zoomed: true), .ignore)
        XCTAssertEqual(ViewerScroll.verb(deltaX: .nan, deltaY: 1, precise: true,
                                         zoomModifier: false, zoomed: true), .ignore)
        XCTAssertEqual(ViewerScroll.verb(deltaX: 0, deltaY: .infinity, precise: false,
                                         zoomModifier: true, zoomed: true), .ignore)
    }
}
