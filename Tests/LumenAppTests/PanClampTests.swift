// How far the photograph may be moved, which had no test at all.
//
// `LoupeGeometry.clampPan` is the single bound on the viewer's pan — nine call sites,
// inherited by the compare panes — and `grep clampPan Tests` returned nothing before this
// file. It was changed on the owner's report ("I can only pan to the side of the image …
// sometimes I want to get really close to the corners"), and a bound that is changed is a
// bound that needs pinning, in both directions: it must reach the corner now, and it must
// still refuse to let go of the picture entirely.
//
// The old rule allowed `(drawn − container) / 2`, which is exactly the set of offsets
// where the photograph still covers the whole viewport. The new rule allows `drawn / 2`,
// which is exactly the set where any point of the photograph can be brought to the centre.
// The difference is `container / 2` per axis — a constant, which is the part worth
// testing, because it means no amount of zooming ever worked around it.

#if os(macOS)
import XCTest
@testable import LumenApp

final class PanClampTests: XCTestCase {

    private let container = CGSize(width: 1600, height: 1000)

    /// THE ASK, arithmetically. Putting the top-left corner at the centre of the viewport
    /// needs `pan = drawn/2`, because `screen(u) = container/2 + pan + (u − 0.5)·drawn`.
    func testACornerCanBeBroughtToTheCentreOfTheViewport() {
        for zoom in [1.5, 3.0, 8.0] {
            let drawn = CGSize(width: container.width * zoom, height: container.height * zoom)
            let wanted = CGSize(width: drawn.width / 2, height: drawn.height / 2)
            let got = LoupeGeometry.clampPan(wanted, container: container, drawn: drawn)

            XCTAssertEqual(got.width, wanted.width, accuracy: 1e-9,
                           "at \(zoom)x the left edge cannot reach the centre")
            XCTAssertEqual(got.height, wanted.height, accuracy: 1e-9,
                           "at \(zoom)x the top edge cannot reach the centre")
        }
    }

    /// THE OLD SHORTFALL, named so a regression to it is legible rather than just a
    /// number changing. It was half a viewport per axis at every zoom — the reason
    /// "zoom in further" was never a workaround.
    func testTheOldBoundFellShortByHalfAViewportAtEveryZoom() {
        for zoom in [1.5, 3.0, 8.0, 16.0] {
            let drawn = CGSize(width: container.width * zoom, height: container.height * zoom)
            let old = (drawn.width - container.width) / 2
            let far = CGSize(width: CGFloat.greatestFiniteMagnitude, height: 0)
            let now = LoupeGeometry.clampPan(far, container: container, drawn: drawn).width

            XCTAssertEqual(now - old, container.width / 2, accuracy: 1e-9,
                           "the gain over the old bound must be exactly half a viewport, "
                               + "and the same at every zoom")
        }
    }

    /// It is a bound, not an absence of one: the picture cannot be pushed out of the
    /// window altogether.
    func testThePanIsStillBounded() {
        let drawn = CGSize(width: 4800, height: 3000)
        let far = LoupeGeometry.clampPan(
            CGSize(width: 1_000_000, height: -1_000_000), container: container, drawn: drawn)

        XCTAssertEqual(far.width, drawn.width / 2, accuracy: 1e-9)
        XCTAssertEqual(far.height, -drawn.height / 2, accuracy: 1e-9)
    }

    /// AN AXIS WITH NOTHING HIDDEN STAYS CENTRED. The drag gate is an OR across the two
    /// axes, so without this a panorama zoomed just past the viewport's width could be
    /// dragged vertically out of the frame.
    func testAnAxisThatFitsIsPinned() {
        let drawn = CGSize(width: 4800, height: 600)   // wide overflows, tall fits
        let got = LoupeGeometry.clampPan(CGSize(width: 9999, height: 9999),
                                         container: container, drawn: drawn)

        XCTAssertEqual(got.width, drawn.width / 2, accuracy: 1e-9, "the hidden axis moves")
        XCTAssertEqual(got.height, 0, accuracy: 1e-9, "the visible axis does not")
    }

    /// Garbage in, centred out. `drawn` is derived from a published frame size and a zoom
    /// ratio, both of which can be absent or mid-flight, and a NaN reaching the `.offset`
    /// takes the photograph off screen with no way back.
    func testNonFiniteInputsCollapseToCentred() {
        let drawn = CGSize(width: 4800, height: 3000)
        for bad in [CGFloat.nan, .infinity, -.infinity] {
            let got = LoupeGeometry.clampPan(CGSize(width: bad, height: bad),
                                             container: container, drawn: drawn)
            XCTAssertEqual(got.width, 0, "a \(bad) pan must not reach the offset")
            XCTAssertEqual(got.height, 0, "a \(bad) pan must not reach the offset")
        }
    }

    /// A degenerate container — the window mid-resize, or a pane at zero width — must not
    /// produce a negative bound, which would invert the clamp.
    func testADegenerateContainerDoesNotInvertTheBound() {
        let got = LoupeGeometry.clampPan(CGSize(width: 500, height: 500),
                                         container: .zero,
                                         drawn: CGSize(width: 800, height: 800))
        XCTAssertEqual(got.width, 400, accuracy: 1e-9)
        XCTAssertEqual(got.height, 400, accuracy: 1e-9)
    }
}
#endif
