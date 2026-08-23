// DraftResolutionTests.swift
// The other half of "lots of zoom in, zoom out things": the picture changing size while
// the zoom state does not move at all.
//
// The defect this pins: above fit the viewer draws a frame at `proxyPixels × ratio ÷
// displayScale`, and the refine driver deliberately renders the draft at half the
// settle's long edge. `renderPreview` scales the decode by `maxLongEdge ÷ native`
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
        // the two cancel and a proxy of any size draws at the container. That is why a
        // coarse draft is free here — and it is the reason the defect never showed at
        // the rung most editing happens on.
        XCTAssertFalse(DraftResolution.sizeFollowsProxyPixels(zoomRatio: ZoomLadder.fit))
        XCTAssertEqual(DraftResolution.draftLongEdge(settledLongEdge: 4096, fitLongEdge: 1024,
                                                     zoomRatio: ZoomLadder.fit),
                       1024)
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
        let draft = DraftResolution.draftLongEdge(settledLongEdge: 4096, fitLongEdge: 1024,
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
            let draft = DraftResolution.draftLongEdge(settledLongEdge: 4096, fitLongEdge: 1024,
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
        XCTAssertEqual(DraftResolution.draftLongEdge(settledLongEdge: 640, fitLongEdge: 1024,
                                                     zoomRatio: ZoomLadder.oneToOne),
                       1024)
        XCTAssertEqual(DraftResolution.draftLongEdge(settledLongEdge: 2048, fitLongEdge: 1024,
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
        XCTAssertEqual(DraftResolution.draftLongEdge(settledLongEdge: 4096, fitLongEdge: 1024,
                                                     zoomRatio: .nan),
                       1024)
    }
}
