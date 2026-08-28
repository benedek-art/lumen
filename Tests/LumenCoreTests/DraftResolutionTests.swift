// DraftResolutionTests.swift
// The other half of "lots of zoom in, zoom out things": the picture changing size while
// the zoom state does not move at all.
//
// The defect this pins: above fit the viewer draws a frame at `proxyPixels × ratio ÷
// displayScale`, and the refine driver USED TO render the draft at half the settle's
// long edge (round 3 removed the halving everywhere — see
// `testAtFitTheDraftAsksForTheSettlesOwnResolutionAndLetsTheLadderDecide`). `renderPreview` scales the decode by `maxLongEdge ÷ native`
// identically for both passes, so half the long edge is half the extent is half the
// drawn size. The photograph therefore shrank to half and grew back on every render —
// and during a slider drag a render is every mouse event, so it pumped under the cursor
// for the whole gesture. Nothing wrote `zoomLevel`, which is why the single-writer
// discipline could hold and the symptom still be zoom.

import XCTest
@testable import LumenCore

final class DraftResolutionTests: XCTestCase {

    func testAtFitTheProxysResolutionIsInvisibleInTheGeometry() {
        // The fit ratio is derived from the same extent it is then multiplied by, so
        // the two cancel and a proxy of any size draws at the container. A coarse draft
        // costs SHARPNESS here and nothing else, which is why the size defect this file
        // is about never showed at the rung most editing happens on.
        XCTAssertFalse(DraftResolution.sizeFollowsProxyPixels(zoomRatio: ZoomLadder.fit))
    }

    /// WHAT COSTS SHARPNESS IS FREE IS NOT THE SAME AS WHAT SHOULD BE SPENT.
    ///
    /// This rule used to return the bare floor at fit, and the viewer then took
    /// `max(floor, settle / 2)` — so a drag was capped at half the settle's resolution
    /// on every machine forever, whatever it could afford. The owner's report on the
    /// round-3 build is exactly that: "when I press and hold any of the sliders I get a
    /// blurry picture while I'm sliding it, and only when I let it go it turns clear."
    ///
    /// The halving was a fair guess when nothing measured a frame. `DraftLadder` now
    /// measures every one and steps down within a single hot frame, so the honest
    /// request is the settle's own resolution and the ladder gives back exactly what
    /// this machine turns out to need — none of it, on one with headroom.
    func testAtFitTheDraftAsksForTheSettlesOwnResolutionAndLetsTheLadderDecide() {
        XCTAssertEqual(DraftResolution.draftLongEdge(settledLongEdge: 4096,
                                                     fitLongEdge: 1024,
                                                     zoomRatio: ZoomLadder.fit),
                       4096,
                       "a drag capped at half the settle is soft under the hand on a "
                           + "machine that could have drawn it sharp")
        XCTAssertEqual(DraftResolution.draftLongEdge(settledLongEdge: 2560,
                                                     fitLongEdge: 1024,
                                                     zoomRatio: ZoomLadder.fit),
                       2560)
    }

    func testAboveFitTheProxysResolutionIsTheFramesSizeOnScreen() {
        for ratio in [ZoomLadder.oneToOne, ZoomLadder.twoToOne, 1.5, 4] {
            XCTAssertTrue(DraftResolution.sizeFollowsProxyPixels(zoomRatio: ratio),
                          "at \(ratio) the drawn size is proxy pixels times the ratio")
        }
    }

    func testTheShippedPairOfLongEdgesDrewThePhotographAtHalfSize() {
        // The exact numbers the viewer used: a 4096 px settle, and a draft the refine
        // driver takes as `max(1024, min(4096 / 2, 2048))` — 2048. At 1:1 on a Retina
        // panel that is 2048 points against 1024. Half, then double, every pass.
        let settled = DraftResolution.drawnLongEdge(proxyLongEdge: 4096,
                                                    zoomRatio: ZoomLadder.oneToOne,
                                                    displayScale: 2)
        let shippedDraft = DraftResolution.drawnLongEdge(proxyLongEdge: 2048,
                                                         zoomRatio: ZoomLadder.oneToOne,
                                                         displayScale: 2)
        XCTAssertEqual(settled, 2048)
        XCTAssertEqual(shippedDraft, 1024)
        XCTAssertEqual(shippedDraft, settled / 2)
    }

    func testZoomedTheDraftIsAskedForTheSettlesOwnLongEdge() {
        // The fix. Both passes carry the same pixel count, so both draw at the same
        // size and what changes between them is sharpness — which is what a progressive
        // refine is supposed to be.
        let draft = DraftResolution.draftLongEdge(settledLongEdge: 4096,
                                                  fitLongEdge: 1024,
                                                  zoomRatio: ZoomLadder.oneToOne)
        XCTAssertEqual(draft, 4096)
        XCTAssertEqual(DraftResolution.drawnLongEdge(proxyLongEdge: draft,
                                                     zoomRatio: ZoomLadder.oneToOne,
                                                     displayScale: 2),
                       DraftResolution.drawnLongEdge(proxyLongEdge: 4096,
                                                     zoomRatio: ZoomLadder.oneToOne,
                                                     displayScale: 2))
    }

    func testTheTwoPassesDrawAtOneSizeAtEveryRungAboveFit() {
        for ratio in [ZoomLadder.oneToOne, ZoomLadder.twoToOne, 1.25, 8] {
            let draft = DraftResolution.draftLongEdge(settledLongEdge: 4096,
                                                      fitLongEdge: 1024,
                                                      zoomRatio: ratio)
            XCTAssertEqual(
                DraftResolution.drawnLongEdge(proxyLongEdge: draft, zoomRatio: ratio,
                                              displayScale: 2),
                DraftResolution.drawnLongEdge(proxyLongEdge: 4096, zoomRatio: ratio,
                                              displayScale: 2),
                "the frame changed size between the draft and the settle at \(ratio)")
        }
    }

    func testTheFloorIsAFloorAndNotAnOverride() {
        // A settle smaller than the viewer's draft floor must not make the draft
        // BIGGER than the settle: that is a draft costing more than the pass it exists
        // to stand in for.
        XCTAssertEqual(DraftResolution.draftLongEdge(settledLongEdge: 640,
                                                     fitLongEdge: 1024,
                                                     zoomRatio: ZoomLadder.oneToOne),
                       1024)
        XCTAssertEqual(DraftResolution.draftLongEdge(settledLongEdge: 2048,
                                                     fitLongEdge: 1024,
                                                     zoomRatio: ZoomLadder.oneToOne),
                       2048)
    }

    func testADegenerateFrameMeasuresAsNothingRatherThanAsANaN() {
        XCTAssertEqual(DraftResolution.drawnLongEdge(proxyLongEdge: 0, zoomRatio: 1,
                                                     displayScale: 2), 0)
        XCTAssertEqual(DraftResolution.drawnLongEdge(proxyLongEdge: 4096,
                                                     zoomRatio: .nan,
                                                     displayScale: 2), 0)
        // A display scale below 1 is meaningless and must not divide the frame up.
        XCTAssertEqual(DraftResolution.drawnLongEdge(proxyLongEdge: 1000, zoomRatio: 1,
                                                     displayScale: 0), 1000)
    }

    func testANonFiniteZoomRatioIsFitAndThereforeCostsNoDraftPixels() {
        // `ZoomLadder.clamp` turns a non-finite ratio into fit rather than letting a
        // NaN propagate into the geometry; the draft rule reads the same ladder, so it
        // has to agree.
        XCTAssertFalse(DraftResolution.sizeFollowsProxyPixels(zoomRatio: .nan))
        // And the draft request is the settle's own resolution there as everywhere —
        // a NaN must not decide how many pixels a frame gets.
        XCTAssertEqual(DraftResolution.draftLongEdge(settledLongEdge: 4096,
                                                     fitLongEdge: 1024,
                                                     zoomRatio: .nan),
                       4096)
    }
}
