// The loupe's viewport geometry. What must hold: the picture point under the cursor
// stays under it while zooming, nothing moves when nothing is input (a hold ending,
// a frame of another pixel size landing), fit is a floor reached without a jump, and
// the pan is free past the borders up to one stated limit.
import XCTest
@testable import LumenCore

final class ViewerViewportTests: XCTestCase {

    // A 7008×4672 raw in a 1600×1000 pt pane on a 2× display.
    private let container = CGSize(width: 1600, height: 1000)
    private let native = CGSize(width: 7008, height: 4672)
    private let fitSettle = CGSize(width: 3072, height: 2048)

    private func world(delivered: CGSize? = nil, native: CGSize?? = .none,
                       container: CGSize? = nil, fallback: Double = 4096)
        -> ViewerViewport.World {
        ViewerViewport.World(container: container ?? self.container,
                             displayScale: 2,
                             delivered: delivered ?? fitSettle,
                             native: native ?? self.native,
                             fallbackLongEdge: fallback)
    }

    private func viewport() -> ViewerViewport {
        var v = ViewerViewport()
        v.setWorld(world())
        return v
    }

    private func assertSameRect(_ a: CGRect, _ b: CGRect, accuracy: Double = 1e-6,
                                _ message: String = "",
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Double(a.minX), Double(b.minX), accuracy: accuracy, message,
                       file: file, line: line)
        XCTAssertEqual(Double(a.minY), Double(b.minY), accuracy: accuracy, message,
                       file: file, line: line)
        XCTAssertEqual(Double(a.width), Double(b.width), accuracy: accuracy, message,
                       file: file, line: line)
        XCTAssertEqual(Double(a.height), Double(b.height), accuracy: accuracy, message,
                       file: file, line: line)
    }

    /// Where on screen the picture's unit point `unit` is.
    private func screen(_ unit: CGPoint, in v: ViewerViewport) -> CGPoint {
        let r = v.pictureRect
        return CGPoint(x: Double(r.minX) + Double(unit.x) * Double(r.width),
                       y: Double(r.minY) + Double(unit.y) * Double(r.height))
    }

    // MARK: Fit

    func testFitFillsTheContainerCentred() {
        let v = viewport()
        XCTAssertTrue(v.isFit)
        assertSameRect(v.pictureRect, CGRect(x: 50, y: 0, width: 1500, height: 1000),
                       accuracy: 0.5)
        // The fit ratio is the zoom whose draw is the fitted one.
        XCTAssertEqual(Double(v.drawn(atZoom: v.fitZoom).width),
                       Double(v.drawn.width), accuracy: 1e-9)
    }

    func testFitDoesNotPan() {
        var v = viewport()
        v.pan(by: CGSize(width: 120, height: -40))
        XCTAssertEqual(v.pan, .zero)
    }

    // MARK: The first pinch

    /// THE REGRESSION this type exists for. The frame on screen at fit is a
    /// 3072 px settle of a 7008 px raw. The loupe used to denominate the zoom in
    /// whichever of those the render model happened to hold, so the first event of a
    /// pinch out of fit drew the picture at 3072/7008 of its size and the sharp frame
    /// landing afterwards blew it back up.
    func testTheFirstPinchOutOfFitGrowsThePictureByExactlyThePinch() {
        var v = viewport()
        let fitted = v.drawn
        v.magnify(by: 1.03, anchor: CGPoint(x: 800, y: 500), hold: true)
        XCTAssertFalse(v.isFit)
        XCTAssertEqual(Double(v.drawn.width), Double(fitted.width) * 1.03, accuracy: 1e-9)
        XCTAssertEqual(Double(v.drawn.height), Double(fitted.height) * 1.03, accuracy: 1e-9)
    }

    /// There is no dead zone: the smallest increment moves the picture by that much.
    func testTheSmallestIncrementOutOfFitIsHonoured() {
        var v = viewport()
        let fitted = Double(v.drawn.width)
        v.magnify(by: 1.001, anchor: nil, hold: false)
        XCTAssertEqual(Double(v.drawn.width), fitted * 1.001, accuracy: 1e-9)
    }

    /// Pinching out at fit is nothing at all — no publish, no hold begun.
    func testPinchingOutAtFitChangesNothing() {
        var v = viewport()
        let before = v
        v.magnify(by: 0.9, anchor: CGPoint(x: 10, y: 10), hold: true)
        XCTAssertEqual(v, before)
    }

    // MARK: Frames of other sizes

    /// A draft, a native settle, a region's full-frame report with fractional
    /// extents: none of them is input, so none of them moves or resizes the picture.
    func testAFrameOfAnotherPixelSizeMovesNothing() {
        var v = viewport()
        v.magnify(by: 2.37, anchor: CGPoint(x: 300, y: 700), hold: false)
        v.pan(by: CGSize(width: -90, height: 35))
        let before = v
        for delivered in [CGSize(width: 1024, height: 683),
                          CGSize(width: 2048, height: 1365),
                          CGSize(width: 7008, height: 4672),
                          CGSize(width: 4096.4, height: 2730.9),
                          CGSize(width: 640, height: 427)] {
            v.setWorld(world(delivered: delivered))
            XCTAssertEqual(v, before, "a \(delivered) delivery moved the viewport")
        }
    }

    /// The same with no prediction to lean on: the first frame's shape is kept
    /// across later frames that differ from it by rounding alone.
    func testWithoutAPredictionRoundingBetweenDeliveriesMovesNothing() {
        var v = ViewerViewport()
        v.setWorld(world(delivered: CGSize(width: 3072, height: 2048),
                         native: .some(nil)))
        v.magnify(by: 3, anchor: CGPoint(x: 900, y: 200), hold: false)
        let before = v
        for delivered in [CGSize(width: 1024, height: 683),
                          CGSize(width: 2048, height: 1365),
                          CGSize(width: 4096, height: 2731)] {
            v.setWorld(world(delivered: delivered, native: .some(nil)))
            XCTAssertEqual(v, before)
        }
    }

    // MARK: Anchoring

    func testAPinchKeepsThePointUnderTheCursor() throws {
        var v = viewport()
        let cursor = CGPoint(x: 431.5, y: 712.25)
        let unit = try XCTUnwrap(v.unitPoint(at: cursor))
        for _ in 0..<120 {
            v.magnify(by: 1.021, anchor: cursor, hold: true)
            let now = screen(unit, in: v)
            XCTAssertEqual(Double(now.x), Double(cursor.x), accuracy: 1e-6)
            XCTAssertEqual(Double(now.y), Double(cursor.y), accuracy: 1e-6)
        }
        XCTAssertGreaterThan(v.zoom, 4)
    }

    /// Sixty small events and one large one are the same gesture.
    func testAPinchIsIndependentOfHowItIsChunked() {
        let cursor = CGPoint(x: 1200, y: 300)
        var fine = viewport()
        for _ in 0..<60 { fine.magnify(by: pow(3.0, 1.0 / 60.0), anchor: cursor, hold: false) }
        var coarse = viewport()
        coarse.magnify(by: 3, anchor: cursor, hold: false)
        XCTAssertEqual(fine.zoom, coarse.zoom, accuracy: 1e-9)
        assertSameRect(fine.pictureRect, coarse.pictureRect)
    }

    /// A later pinch compounds from where the last one left the picture.
    func testASecondPinchCompounds() {
        var v = viewport()
        v.magnify(by: 2, anchor: nil, hold: true)
        v.endContinuousZoom()
        let between = Double(v.drawn.width)
        v.magnify(by: 1.5, anchor: nil, hold: true)
        XCTAssertEqual(Double(v.drawn.width), between * 1.5, accuracy: 1e-9)
    }

    /// A cursor off the picture zooms about the nearest point ON it, which stays
    /// where it is: the picture neither jumps to the cursor nor runs from it.
    func testACursorOffThePictureAnchorsAtTheNearestEdge() {
        var v = viewport()
        let leftEdge = Double(v.pictureRect.minX)
        v.magnify(by: 1.5, anchor: CGPoint(x: 10, y: 500), hold: false)
        XCTAssertEqual(Double(v.pictureRect.minX), leftEdge, accuracy: 1e-9)
    }

    func testTheKeysAnchorThroughTheSameGeometry() throws {
        var v = viewport()
        let cursor = CGPoint(x: 1100, y: 250)
        let unit = try XCTUnwrap(v.unitPoint(at: cursor))
        v.setZoom(ZoomLadder.oneToOne, anchor: cursor)
        XCTAssertEqual(v.zoom, 1)
        // 1:1 is one frame pixel per device pixel.
        XCTAssertEqual(Double(v.drawn.width), 7008.0 / 2, accuracy: 1e-9)
        let now = screen(unit, in: v)
        XCTAssertEqual(Double(now.x), Double(cursor.x), accuracy: 1e-6)
        XCTAssertEqual(Double(now.y), Double(cursor.y), accuracy: 1e-6)
        v.setZoom(ZoomLadder.fit, anchor: nil)
        XCTAssertTrue(v.isFit)
        XCTAssertEqual(v.pan, .zero)
    }

    func testTheCeilingHolds() {
        var v = viewport()
        v.magnify(by: 1000, anchor: nil, hold: false)
        XCTAssertEqual(v.zoom, ZoomLadder.maximum)
        let before = v
        v.magnify(by: 1.2, anchor: CGPoint(x: 5, y: 5), hold: true)
        XCTAssertEqual(v, before, "an event at the ceiling is not a change")
    }

    // MARK: Fit as the floor

    /// Zoom in off-centre, pan, pinch all the way out somewhere else: the picture
    /// arrives at fit centred, and no single event on the way moves it by more than
    /// a step's worth.
    func testPinchingOutArrivesAtFitWithoutAJump() {
        var v = viewport()
        v.magnify(by: 6, anchor: CGPoint(x: 300, y: 250), hold: false)
        v.pan(by: CGSize(width: -700, height: 420))
        let fitted = viewport().pictureRect
        var previous = v.pictureRect
        var steps = 0
        while !v.isFit, steps < 2000 {
            v.magnify(by: 0.985, anchor: CGPoint(x: 1400, y: 850), hold: true)
            let now = v.pictureRect
            let moved = Swift.max(abs(Double(now.minX - previous.minX)),
                                  abs(Double(now.maxX - previous.maxX)),
                                  abs(Double(now.minY - previous.minY)),
                                  abs(Double(now.maxY - previous.maxY)))
            // 1.5% of a picture at most 6× the pane, plus the pull's share.
            XCTAssertLessThan(moved, 0.04 * Double(previous.width),
                              "step \(steps) moved an edge \(moved) pt")
            previous = now
            steps += 1
        }
        XCTAssertTrue(v.isFit)
        XCTAssertEqual(v.pan, .zero)
        // The last zoomed frame was already the fitted one, to within the step.
        assertSameRect(v.pictureRect, fitted)
    }

    /// The step that lands on fit is no bigger than the ones before it.
    func testTheLandingOnFitIsContinuous() {
        var v = viewport()
        v.magnify(by: 4, anchor: CGPoint(x: 200, y: 900), hold: false)
        let fitted = viewport().pictureRect
        var last = v.pictureRect
        while !v.isFit {
            last = v.pictureRect
            v.magnify(by: 0.99, anchor: CGPoint(x: 1500, y: 100), hold: false)
        }
        assertSameRect(last, fitted, accuracy: 0.011 * Double(fitted.width))
    }

    /// Zooming out about a corner cursor never pulls a picture edge inside the pane's
    /// while the picture is still larger than the pane.
    func testZoomingOutNeverOpensAGap() {
        var v = viewport()
        v.magnify(by: 6, anchor: CGPoint(x: 800, y: 500), hold: false)
        while !v.isFit {
            v.magnify(by: 0.97, anchor: CGPoint(x: 1590, y: 990), hold: false)
            let r = v.pictureRect
            if Double(r.width) >= 1600 {
                XCTAssertLessThanOrEqual(Double(r.minX), 1e-6)
                XCTAssertGreaterThanOrEqual(Double(r.maxX), 1600 - 1e-6)
            } else {
                XCTAssertEqual(Double(r.midX), 800, accuracy: 1e-6, "centred once it fits")
            }
            if Double(r.height) >= 1000 {
                XCTAssertLessThanOrEqual(Double(r.minY), 1e-6)
                XCTAssertGreaterThanOrEqual(Double(r.maxY), 1000 - 1e-6)
            }
        }
    }

    /// A gap the pan put there is not snapped shut: it shrinks with the share of
    /// the way to fit still left, and is gone exactly at fit.
    func testAGapAlreadyThereClosesInStepWithTheWayToFit() {
        var v = viewport()
        v.magnify(by: 3, anchor: nil, hold: false)
        v.pan(by: CGSize(width: 1900, height: 0))
        let gap = Double(v.pictureRect.minX)
        XCTAssertGreaterThan(gap, 400)
        // Halfway to fit in size is half the gap.
        v.magnify(by: 2.0 / 3.0, anchor: CGPoint(x: Double(v.pictureRect.minX), y: 500),
                  hold: false)
        XCTAssertEqual(Double(v.drawn.width), 3000, accuracy: 1e-9)
        XCTAssertEqual(Double(v.pictureRect.minX), gap / 2, accuracy: 1e-6)
    }

    /// While the picture covers the pane, zooming out is anchored exactly.
    func testZoomingOutIsAnchoredWhileThePictureCoversThePane() throws {
        var v = viewport()
        let cursor = CGPoint(x: 800, y: 500)
        v.magnify(by: 8, anchor: cursor, hold: false)
        let unit = try XCTUnwrap(v.unitPoint(at: cursor))
        for _ in 0..<40 {
            v.magnify(by: 0.97, anchor: cursor, hold: false)
            let now = screen(unit, in: v)
            XCTAssertEqual(Double(now.x), Double(cursor.x), accuracy: 1e-6)
            XCTAssertEqual(Double(now.y), Double(cursor.y), accuracy: 1e-6)
        }
    }

    func testAZoomEndingAHairAboveFitBecomesFit() {
        var v = viewport()
        v.magnify(by: 1.015, anchor: CGPoint(x: 200, y: 200), hold: true)
        XCTAssertFalse(v.isFit, "never while the hand is moving")
        v.endContinuousZoom()
        XCTAssertTrue(v.isFit)
        XCTAssertEqual(v.pan, .zero)
        XCTAssertNil(v.held)

        var further = viewport()
        further.magnify(by: 1.05, anchor: nil, hold: true)
        let before = further.pictureRect
        further.endContinuousZoom()
        XCTAssertFalse(further.isFit)
        assertSameRect(further.pictureRect, before)
    }

    /// A small picture at 1:1 is smaller than fit. Pinching in grows it from there
    /// straight through the fitted size; pinching out is fit.
    func testAPictureSmallerThanFit() {
        var v = ViewerViewport()
        let small = CGSize(width: 1200, height: 800)
        v.setWorld(world(delivered: small, native: .some(small)))
        v.setZoom(ZoomLadder.oneToOne, anchor: nil)
        XCTAssertEqual(Double(v.drawn.width), 600, accuracy: 1e-9)
        XCTAssertLessThan(v.zoom, v.fitZoom)
        v.magnify(by: 1.1, anchor: nil, hold: false)
        XCTAssertEqual(Double(v.drawn.width), 660, accuracy: 1e-9)
        v.magnify(by: 4, anchor: nil, hold: false)
        XCTAssertEqual(Double(v.drawn.width), 2640, accuracy: 1e-9)
        v.setZoom(ZoomLadder.oneToOne, anchor: nil)
        v.magnify(by: 0.9, anchor: nil, hold: false)
        XCTAssertTrue(v.isFit)
    }

    // MARK: Pan

    /// The owner: "it can also pan off screen if needed so its not only in the
    /// borders." An axis with nothing hidden moves too, and the bound is the stated
    /// one: a quarter of the pane keeps picture in it.
    func testThePanIsFreePastTheBordersUpToTheLimit() {
        var v = viewport()
        v.magnify(by: 1.04, anchor: nil, hold: false)
        // 1560 pt wide in a 1600 pt pane: the horizontal axis hides nothing.
        XCTAssertLessThan(Double(v.drawn.width), 1600)
        v.pan(by: CGSize(width: 300, height: 0))
        XCTAssertEqual(Double(v.pan.width), 300, accuracy: 1e-9)

        v.pan(by: CGSize(width: 99_999, height: 99_999))
        let rect = v.pictureRect
        XCTAssertEqual(1600 - Double(rect.minX), 400, accuracy: 1e-9,
                       "a quarter of the pane's width still has picture in it")
        XCTAssertEqual(1000 - Double(rect.minY), 250, accuracy: 1e-9)
        v.pan(by: CGSize(width: -99_999, height: -99_999))
        XCTAssertEqual(Double(v.pictureRect.maxX), 400, accuracy: 1e-9)
        XCTAssertEqual(Double(v.pictureRect.maxY), 250, accuracy: 1e-9)
    }

    func testAPictureSmallerThanTheKeepStaysWhollyInside() {
        XCTAssertEqual(ViewerViewport.limited(9_999, drawn: 100, container: 1000),
                       450, accuracy: 1e-9)
        XCTAssertEqual(ViewerViewport.limited(-9_999, drawn: 100, container: 1000),
                       -450, accuracy: 1e-9)
        XCTAssertEqual(ViewerViewport.limited(.nan, drawn: 100, container: 1000), 0)
    }

    /// Pinch and two-finger pan interleave freely: each pan moves the picture by its
    /// delta, each pinch keeps the point under the cursor.
    func testPinchAndPanInterleave() throws {
        var v = viewport()
        let cursor = CGPoint(x: 700, y: 400)
        v.magnify(by: 3, anchor: cursor, hold: true)
        for step in 0..<40 {
            let before = v.pictureRect
            v.pan(by: CGSize(width: 3, height: -2))
            XCTAssertEqual(Double(v.pictureRect.minX - before.minX), 3, accuracy: 1e-9)
            XCTAssertEqual(Double(v.pictureRect.minY - before.minY), -2, accuracy: 1e-9)
            let unit = try XCTUnwrap(v.unitPoint(at: cursor))
            v.magnify(by: step % 2 == 0 ? 1.01 : 1.02, anchor: cursor, hold: true)
            let now = screen(unit, in: v)
            XCTAssertEqual(Double(now.x), Double(cursor.x), accuracy: 1e-6)
            XCTAssertEqual(Double(now.y), Double(cursor.y), accuracy: 1e-6)
        }
    }

    // MARK: The hold

    /// The held canvas, scaled by `stretch`, IS the picture — so the hold beginning
    /// and ending are both invisible.
    func testTheHoldIsGeometricallyNeutral() {
        var v = viewport()
        v.magnify(by: 1.4, anchor: CGPoint(x: 400, y: 300), hold: false)
        let laidOut = v.layout
        XCTAssertNil(v.held)
        v.magnify(by: 1.3, anchor: CGPoint(x: 400, y: 300), hold: true)
        v.magnify(by: 1.3, anchor: CGPoint(x: 420, y: 310), hold: true)
        v.pan(by: CGSize(width: 12, height: 7))
        XCTAssertEqual(v.held, laidOut, "the layout stays where the gesture found it")
        XCTAssertEqual(v.layout, laidOut)
        XCTAssertEqual(Double(v.layoutDrawn.width) * v.stretch, Double(v.drawn.width),
                       accuracy: 1e-9)
        XCTAssertEqual(Double(v.layoutDrawn.height) * v.stretch, Double(v.drawn.height),
                       accuracy: 1e-9)

        let before = v.pictureRect
        let zoom = v.zoom
        v.releaseHold()
        XCTAssertNil(v.held)
        XCTAssertEqual(v.stretch, 1)
        XCTAssertEqual(v.zoom, zoom)
        XCTAssertEqual(v.pictureRect, before)
        XCTAssertEqual(v.layoutDrawn, v.drawn)
    }

    /// The render ask is sized from the held layout, so it does not move mid-gesture.
    func testTheRegionAskIsFrozenWhileHeld() {
        var v = viewport()
        v.magnify(by: 5, anchor: CGPoint(x: 500, y: 500), hold: false)
        let ask = ZoomRegion.requestUnit(container: container, drawnFull: v.layoutDrawn,
                                         pan: v.layout.pan)
        XCTAssertNotNil(ask)
        for _ in 0..<30 {
            v.magnify(by: 1.03, anchor: CGPoint(x: 900, y: 200), hold: true)
            XCTAssertEqual(ZoomRegion.requestUnit(container: container,
                                                  drawnFull: v.layoutDrawn,
                                                  pan: v.layout.pan), ask)
        }
    }

    /// A pinch out of fit holds the FIT layout: no zoomed render is asked for until
    /// the fingers lift.
    func testAPinchOutOfFitHoldsTheFitLayout() {
        var v = viewport()
        v.magnify(by: 1.5, anchor: nil, hold: true)
        XCTAssertEqual(v.layout.zoom, ZoomLadder.fit)
        XCTAssertEqual(v.stretch, 1.5, accuracy: 1e-9)
        v.endContinuousZoom()
        XCTAssertGreaterThan(v.layout.zoom, 0)
    }

    // MARK: Re-denomination

    /// Learning the true frame size mid-inspection: a freely zoomed picture keeps
    /// its size and the zoom NUMBER moves.
    func testAFreeZoomKeepsItsSizeWhenTheFrameIsRedenominated() {
        var v = ViewerViewport()
        v.setWorld(world(native: .some(nil), fallback: 4096))
        v.magnify(by: 2.2, anchor: CGPoint(x: 600, y: 300), hold: false)
        let before = v.pictureRect
        let zoom = v.zoom
        v.setWorld(world())
        assertSameRect(v.pictureRect, before, accuracy: 0.5)
        XCTAssertEqual(v.zoom, zoom * 4096 / 7008, accuracy: 1e-9)
    }

    /// On a named ratio the ratio is the promise: 1:1 stays one frame pixel per
    /// device pixel and the viewport's centre keeps its picture point.
    func testANamedRatioSurvivesRedenomination() throws {
        var v = ViewerViewport()
        v.setWorld(world(native: .some(nil), fallback: 4096))
        v.setZoom(ZoomLadder.oneToOne, anchor: CGPoint(x: 500, y: 400))
        let centre = CGPoint(x: 800, y: 500)
        let unit = try XCTUnwrap(v.unitPoint(at: centre))
        v.setWorld(world())
        XCTAssertEqual(v.zoom, 1)
        XCTAssertEqual(Double(v.drawn.width), 3504, accuracy: 1e-9)
        let now = screen(unit, in: v)
        XCTAssertEqual(Double(now.x), 800, accuracy: 0.5)
        XCTAssertEqual(Double(now.y), 500, accuracy: 0.5)
    }

    func testNamedRatios() {
        for ratio in [0.25, 0.5, 1, 2, 4, 8, 16] { XCTAssertTrue(ZoomLadder.isNamedRatio(ratio)) }
        for ratio in [0, -1, 0.457, 1.003, 1.5, 3, .nan, .infinity] {
            XCTAssertFalse(ZoomLadder.isNamedRatio(ratio), "\(ratio)")
        }
    }

    func testAResizedPaneKeepsAZoomedPictureWhereItIs() {
        var v = viewport()
        v.magnify(by: 3, anchor: CGPoint(x: 300, y: 300), hold: false)
        let size = v.drawn
        let pan = v.pan
        v.setWorld(world(container: CGSize(width: 1200, height: 900)))
        XCTAssertEqual(v.drawn, size)
        XCTAssertEqual(v.pan, pan, "the offset from the pane's centre is unchanged")
        // And an unusable pane on the way does not lose the pan.
        v.setWorld(world(container: .zero))
        XCTAssertEqual(v.pan, pan)
    }

    func testANewPhotographStartsAtFit() {
        var v = viewport()
        v.magnify(by: 3, anchor: nil, hold: true)
        v.reset()
        XCTAssertTrue(v.isFit)
        XCTAssertEqual(v.pan, .zero)
        XCTAssertNil(v.held)
    }

    // MARK: Which frame

    func testThePredictionIsTheFrameWhenThePictureHasItsShape() {
        let w = world(delivered: CGSize(width: 1024, height: 683))
        XCTAssertEqual(ViewerViewport.resolveFrame(current: .zero, world: w), native)
    }

    /// A sideways prediction (a portrait raw reporting its landscape readout) must
    /// never reshape the picture: the picture's own shape wins, at the predicted size.
    func testATransposedPredictionDoesNotReshapeThePicture() {
        let portrait = CGSize(width: 2048, height: 3072)
        let frame = ViewerViewport.resolveFrame(current: .zero,
                                                world: world(delivered: portrait))
        XCTAssertEqual(Double(frame.height), 7008, accuracy: 1e-9)
        XCTAssertEqual(Double(frame.width / frame.height), 2048.0 / 3072.0, accuracy: 1e-12)
    }

    /// A camera's embedded preview is often not the raw's aspect (1616×1080 against
    /// 3:2). It is drawn in its own shape.
    func testAnEmbeddedPreviewOfAnotherAspectKeepsItsOwnShape() {
        let preview = CGSize(width: 1616, height: 1080)
        let frame = ViewerViewport.resolveFrame(current: .zero,
                                                world: world(delivered: preview))
        XCTAssertEqual(Double(frame.width / frame.height), 1616.0 / 1080.0, accuracy: 1e-12)
        XCTAssertEqual(Double(frame.width), 7008, accuracy: 1e-9)
    }

    /// 1:1 must be the delivered pixels exactly. A source whose metadata size is not
    /// the decoder's predicts a frame a row or two off; the first full-resolution
    /// frame replaces the prediction with its own extent, and drafts landing after
    /// it do not put the prediction back.
    func testAFullResolutionDeliveryIsTheFrameAndStaysIt() {
        let predicted = CGSize(width: 7008, height: 4674.7)
        var v = ViewerViewport()
        v.setWorld(world(delivered: fitSettle, native: .some(predicted)))
        XCTAssertEqual(v.frame, predicted)
        v.setZoom(ZoomLadder.oneToOne, anchor: nil)

        v.setWorld(world(delivered: CGSize(width: 7008, height: 4672),
                         native: .some(predicted)))
        XCTAssertEqual(v.frame, CGSize(width: 7008, height: 4672))
        XCTAssertEqual(v.zoom, 1)
        XCTAssertEqual(Double(v.drawn.height), 2336, accuracy: 1e-9)

        let settled = v
        for delivered in [CGSize(width: 2048, height: 1365), CGSize(width: 1024, height: 683),
                          CGSize(width: 7008.2, height: 4672.3)] {
            v.setWorld(world(delivered: delivered, native: .some(predicted)))
            XCTAssertEqual(v, settled)
        }
    }

    func testNothingOnScreenUsesThePredictionOrNothing() {
        XCTAssertEqual(ViewerViewport.resolveFrame(current: .zero,
                                                   world: world(delivered: .zero)), native)
        XCTAssertEqual(ViewerViewport.resolveFrame(
            current: .zero, world: world(delivered: .zero, native: .some(nil))), .zero)
    }

    func testTheNativeFrameIsWhatAZoomedSettleDelivers() throws {
        let source = CGSize(width: 7008, height: 4672)
        // Uncropped, under the cap: the sensor's own pixels.
        let whole = try XCTUnwrap(ViewerViewport.nativeFrame(
            source: source, decoderLongEdge: 7008, geometry: Geometry(), askLongEdge: 7008))
        XCTAssertEqual(Double(whole.width), 7008, accuracy: 1e-9)
        XCTAssertEqual(Double(whole.height), 4672, accuracy: 1e-9)
        // Cropped to the middle half: half the pixels on each axis, not the ask.
        let half = try XCTUnwrap(ViewerViewport.nativeFrame(
            source: source, decoderLongEdge: 7008,
            geometry: Geometry(crop: Crop(x: 0.25, y: 0.25, w: 0.5, h: 0.5)),
            askLongEdge: 7008))
        XCTAssertEqual(Double(half.width), 3504, accuracy: 1e-9)
        XCTAssertEqual(Double(half.height), 2336, accuracy: 1e-9)
        // An ask below the sensor decodes at the ask.
        let capped = try XCTUnwrap(ViewerViewport.nativeFrame(
            source: source, decoderLongEdge: 7008, geometry: Geometry(), askLongEdge: 4096))
        XCTAssertEqual(Double(capped.width), 4096, accuracy: 1e-9)
        // The decoder's long edge outranks a metadata size that disagrees with it.
        let decoder = try XCTUnwrap(ViewerViewport.nativeFrame(
            source: CGSize(width: 7028, height: 4688), decoderLongEdge: 7008,
            geometry: Geometry(), askLongEdge: 7028))
        XCTAssertEqual(Double(decoder.width), 7008, accuracy: 1e-9)
        // A straightened frame is its inscribed rectangle.
        let turned = try XCTUnwrap(ViewerViewport.nativeFrame(
            source: source, decoderLongEdge: nil, geometry: Geometry(angle: 5),
            askLongEdge: 16384))
        XCTAssertLessThan(Double(turned.width), 7008)
        XCTAssertNil(ViewerViewport.nativeFrame(source: .zero, decoderLongEdge: nil,
                                                geometry: Geometry(), askLongEdge: 4096))
    }

    // MARK: The whole gesture, as the app lives it

    /// Pinch out of fit, lift, and let every frame the render path then produces
    /// land: a native draft, the native settle, a region. After the last input the
    /// picture's rectangle never changes again.
    func testNothingMovesAfterTheFingersLift() {
        var v = viewport()
        let cursor = CGPoint(x: 520, y: 610)
        for _ in 0..<45 { v.magnify(by: 1.03, anchor: cursor, hold: true) }
        let held = v.pictureRect
        v.endContinuousZoom()
        XCTAssertEqual(v.pictureRect, held, "the hold ending moved the picture")
        let rest = v
        for delivered in [CGSize(width: 2048, height: 1365),
                          CGSize(width: 7008, height: 4672),
                          CGSize(width: 7008.0, height: 4672.0),
                          CGSize(width: 1024, height: 683)] {
            v.setWorld(world(delivered: delivered))
            XCTAssertEqual(v, rest)
        }
    }

    // MARK: Arbitrary interleavings

    private struct LCG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func uniform(_ low: Double, _ high: Double) -> Double {
            low + (high - low) * next()
        }
    }

    /// The anchored pan the gesture asks for before any pull or limit — the oracle
    /// the zoom-out branch is judged against.
    private func anchoredPan(from before: ViewerViewport, to after: ViewerViewport,
                             cursor: CGPoint) -> (x: Double, y: Double) {
        let r = before.pictureRect
        let ax = Swift.min(Swift.max(Double(cursor.x), Double(r.minX)), Double(r.maxX))
        let ay = Swift.min(Swift.max(Double(cursor.y), Double(r.minY)), Double(r.maxY))
        let ux = (ax - Double(r.minX)) / Double(r.width)
        let uy = (ay - Double(r.minY)) / Double(r.height)
        return (ax - 800 - (ux - 0.5) * Double(after.drawn.width),
                ay - 500 - (uy - 0.5) * Double(after.drawn.height))
    }

    /// For arbitrary interleavings of zoom events at a cursor, pans, the hold
    /// beginning and ending, and frames of differing extents landing:
    ///   · zooming IN keeps the picture point under the cursor exactly;
    ///   · zooming OUT keeps it on every axis where the picture still covers the
    ///     pane, and otherwise only ever moves the picture toward centred;
    ///   · a frame landing or a hold ending moves nothing at all;
    ///   · the held canvas scaled by `stretch` is the picture;
    ///   · the picture is never lost, and never smaller than fit.
    func testArbitraryInterleavingsKeepTheInvariants() throws {
        let deliveries = [CGSize(width: 3072, height: 2048), CGSize(width: 1024, height: 683),
                          CGSize(width: 2048, height: 1365), CGSize(width: 7008, height: 4672),
                          CGSize(width: 5120.6, height: 3413.7), CGSize(width: 640, height: 427)]
        for seed in 1...200 {
            var rng = LCG(state: UInt64(seed) &* 0x9E37_79B9_7F4A_7C15)
            var v = viewport()
            let fitted = Double(v.drawn.width)
            for step in 0..<300 {
                let context = "seed \(seed) step \(step)"
                let before = v
                let cursor = CGPoint(x: rng.uniform(0, 1600), y: rng.uniform(0, 1000))
                let pick = rng.next()
                if pick < 0.30 {
                    // Zoom in.
                    v.magnify(by: rng.uniform(1.001, 1.25), anchor: cursor,
                              hold: rng.next() < 0.7)
                    if v.zoom != before.zoom {
                        let want = anchoredPan(from: before, to: v, cursor: cursor)
                        XCTAssertEqual(Double(v.pan.width), want.x, accuracy: 1e-6, context)
                        XCTAssertEqual(Double(v.pan.height), want.y, accuracy: 1e-6, context)
                    } else {
                        XCTAssertEqual(v, before, context)
                    }
                } else if pick < 0.58 {
                    // Zoom out.
                    v.magnify(by: rng.uniform(0.8, 0.999), anchor: cursor,
                              hold: rng.next() < 0.7)
                    if v.isFit {
                        XCTAssertEqual(v.pan, .zero, context)
                    } else if v.zoom != before.zoom {
                        let want = anchoredPan(from: before, to: v, cursor: cursor)
                        for (got, asked, drawn, pane) in [
                            (Double(v.pan.width), want.x, Double(v.drawn.width), 1600.0),
                            (Double(v.pan.height), want.y, Double(v.drawn.height), 1000.0),
                        ] {
                            let cover = Swift.max(0, (drawn - pane) / 2)
                            if abs(asked) <= cover {
                                XCTAssertEqual(got, asked, accuracy: 1e-6, context)
                            } else {
                                // Pulled toward covering, never past it or away.
                                let edge = asked > 0 ? cover : -cover
                                XCTAssertGreaterThanOrEqual(got, Swift.min(edge, asked) - 1e-6,
                                                            context)
                                XCTAssertLessThanOrEqual(got, Swift.max(edge, asked) + 1e-6,
                                                         context)
                            }
                        }
                    }
                } else if pick < 0.78 {
                    // Two-finger pan.
                    let delta = CGSize(width: rng.uniform(-400, 400), height: rng.uniform(-400, 400))
                    v.pan(by: delta)
                    XCTAssertEqual(v.zoom, before.zoom, context)
                    XCTAssertEqual(v.held, before.held, context)
                } else if pick < 0.88 {
                    // A frame of some other pixel size lands.
                    let delivered = deliveries[Int(rng.uniform(0, Double(deliveries.count) - 0.001))]
                    v.setWorld(world(delivered: delivered))
                    XCTAssertEqual(v, before, context)
                } else if pick < 0.95 {
                    // The quiet window closes on the hold.
                    v.releaseHold()
                    XCTAssertEqual(v.zoom, before.zoom, context)
                    XCTAssertEqual(v.pictureRect, before.pictureRect, context)
                    XCTAssertNil(v.held, context)
                } else {
                    // A key.
                    let ratio = [ZoomLadder.fit, ZoomLadder.oneToOne, ZoomLadder.twoToOne][
                        Int(rng.uniform(0, 2.999))]
                    v.setZoom(ratio, anchor: cursor)
                    XCTAssertEqual(v.zoom, ratio, context)
                    XCTAssertEqual(v.held, before.held, context)
                }

                // Always.
                XCTAssertTrue(v.zoom.isFinite && v.zoom >= 0, context)
                XCTAssertLessThanOrEqual(v.zoom, ZoomLadder.maximum, context)
                XCTAssertGreaterThanOrEqual(Double(v.drawn.width), fitted - 1e-6, context)
                let rect = v.pictureRect
                let seenX = Swift.min(Double(rect.maxX), 1600) - Swift.max(Double(rect.minX), 0)
                let seenY = Swift.min(Double(rect.maxY), 1000) - Swift.max(Double(rect.minY), 0)
                XCTAssertGreaterThanOrEqual(seenX, 400 - 1e-6, context)
                XCTAssertGreaterThanOrEqual(seenY, 250 - 1e-6, context)
                XCTAssertEqual(Double(v.layoutDrawn.width) * v.stretch,
                               Double(v.drawn.width), accuracy: 1e-6, context)
                XCTAssertEqual(Double(v.layoutDrawn.height) * v.stretch,
                               Double(v.drawn.height), accuracy: 1e-6, context)
                if v.held == nil { XCTAssertEqual(v.stretch, 1, context) }
            }
        }
    }
}

final class ViewerMagnifyTests: XCTestCase {

    /// AppKit reports the change since the last event, so events compound.
    func testAnEventsFactorIsOnePlusItsMagnification() {
        XCTAssertEqual(ViewerMagnify.factor(magnification: 0.02), 1.02)
        XCTAssertEqual(ViewerMagnify.factor(magnification: -0.02), 0.98)
        XCTAssertNil(ViewerMagnify.factor(magnification: 0))
        XCTAssertNil(ViewerMagnify.factor(magnification: .nan))
        XCTAssertNil(ViewerMagnify.factor(magnification: .infinity))
    }

    /// A wild negative increment cannot invert or collapse the picture.
    func testOneEventCannotCollapseThePicture() {
        XCTAssertEqual(ViewerMagnify.factor(magnification: -3), ViewerMagnify.minimumFactor)
        XCTAssertGreaterThan(ViewerMagnify.minimumFactor, 0)
    }

    func testAnEndingEventStillCarriesItsIncrement() {
        XCTAssertEqual(ViewerMagnify.steps(magnification: 0.01, ended: false),
                       [.zoom(factor: 1.01)])
        XCTAssertEqual(ViewerMagnify.steps(magnification: 0.01, ended: true),
                       [.zoom(factor: 1.01), .ended])
        XCTAssertEqual(ViewerMagnify.steps(magnification: 0, ended: true), [.ended])
        XCTAssertEqual(ViewerMagnify.steps(magnification: 0, ended: false), [])
    }
}
