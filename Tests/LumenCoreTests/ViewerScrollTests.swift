// The viewer's scroll grammar, second version: a scroll zooms on every instrument
// (a Magic Mouse reports precise deltas like a trackpad, so splitting by instrument
// left the owner's two-finger scroll doing nothing at fit), and ⌥ pans.
import XCTest
@testable import LumenCore

final class ViewerScrollTests: XCTestCase {

    func testWheelZoomsWithoutAModifier() {
        let verb = ViewerScroll.verb(deltaX: 0, deltaY: 1, precise: false,
                                     panModifier: false, zoomed: false)
        guard case .zoom(let factor) = verb else {
            return XCTFail("a wheel scroll must zoom, got \(verb)")
        }
        XCTAssertGreaterThan(factor, 1, "scrolling the way you scroll up zooms in")
    }

    /// The owner's report: two fingers on a Magic Mouse or a trackpad did nothing at
    /// fit and panned when zoomed. Both must zoom.
    func testTwoFingerScrollZoomsAtFitAndWhenZoomed() {
        for zoomed in [false, true] {
            let verb = ViewerScroll.verb(deltaX: 0, deltaY: 30, precise: true,
                                         panModifier: false, zoomed: zoomed)
            guard case .zoom(let factor) = verb else {
                return XCTFail("a two-finger scroll must zoom (zoomed: \(zoomed)), got \(verb)")
            }
            XCTAssertGreaterThan(factor, 1)
        }
    }

    func testWheelDirectionIsSymmetric() {
        guard case .zoom(let up) = ViewerScroll.verb(deltaX: 0, deltaY: 3,
                                                     precise: false,
                                                     panModifier: false,
                                                     zoomed: true),
              case .zoom(let down) = ViewerScroll.verb(deltaX: 0, deltaY: -3,
                                                       precise: false,
                                                       panModifier: false,
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
                                                        panModifier: false,
                                                        zoomed: true) else {
                return XCTFail("a wheel click must zoom")
            }
            factor *= f
        }
        XCTAssertEqual(factor, 2, accuracy: 1e-9)
    }

    func testOptionPansWhenZoomed() {
        XCTAssertEqual(ViewerScroll.verb(deltaX: 12, deltaY: -30, precise: true,
                                         panModifier: true, zoomed: true),
                       .pan(dx: 12, dy: -30),
                       "⌥ + two fingers move the picture with them, both axes")
    }

    func testOptionPanAtFitIsIgnored() {
        XCTAssertEqual(ViewerScroll.verb(deltaX: 0, deltaY: -30, precise: true,
                                         panModifier: true, zoomed: false),
                       .ignore,
                       "there is nothing to pan when the whole frame is on screen")
    }

    func testASidewaysScrollDoesNotZoom() {
        XCTAssertEqual(ViewerScroll.verb(deltaX: 40, deltaY: 0, precise: true,
                                         panModifier: false, zoomed: true),
                       .ignore)
    }

    func testATrackpadFlickIsNotTheWholeRange() {
        // Why `pointsPerDoubling` is coarser than the scrub's: a comfortable flick is
        // on the order of 150 points, and it must not cross fit → 16:1.
        guard case .zoom(let factor) = ViewerScroll.verb(deltaX: 0, deltaY: 150,
                                                         precise: true,
                                                         panModifier: false,
                                                         zoomed: true) else {
            return XCTFail("a scroll must zoom")
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
                                                        panModifier: false,
                                                        zoomed: true) else {
            return XCTFail("a scroll must zoom")
        }
        var chopped = 1.0
        for _ in 0..<80 {
            guard case .zoom(let f) = ViewerScroll.verb(deltaX: 0, deltaY: 1,
                                                        precise: true,
                                                        panModifier: false,
                                                        zoomed: true) else {
                return XCTFail("a scroll must zoom")
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
                                         panModifier: false, zoomed: true), .ignore)
        XCTAssertEqual(ViewerScroll.verb(deltaX: 0, deltaY: 0, precise: true,
                                         panModifier: true, zoomed: true), .ignore)
        XCTAssertEqual(ViewerScroll.verb(deltaX: .nan, deltaY: 1, precise: true,
                                         panModifier: false, zoomed: true), .ignore)
        XCTAssertEqual(ViewerScroll.verb(deltaX: 0, deltaY: .infinity, precise: false,
                                         panModifier: false, zoomed: true), .ignore)
    }
}
