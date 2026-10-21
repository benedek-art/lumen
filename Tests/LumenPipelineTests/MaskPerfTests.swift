// MaskPerfTests.swift
// The settle rung of the brush plane cache, and the one property that makes holding it
// legal: THE SETTLED PICTURE IS THE SAME PICTURE WHETHER IT WAS REACHED THROUGH THE
// FAST INTERACTIVE PATH OR THROUGH A COLD FULL RENDER.
//
// The stall this closes is the surviving half of the owner's "the mask isn't updating
// quick enough". `AppState.refreshMaskOverlay` answered the overlay half — the coloured
// wash trailing the handle — and left the picture's own half alone: after a mask edit
// the settle took 1.7–3.0 s, and took it again on the next stroke, and got worse the
// more the photographer had painted.
//
// WHERE IT WENT. `BrushPlaneCache.store` refused to hold any plane above the 1024 draft
// proxy, so the settle — which since docs/31 round two §3 rasterizes at the render
// target's own resolution — found no prefix to resume from and repainted the WHOLE
// stroke set at up to 4096 px. A stroke commits on mouse-up (`MaskCanvas` publishes
// `livePoints` to the canvas and the finished STROKE to the recipe), so the set grows by
// one per gesture: the draft after it painted one stroke and the settle painted all
// sixty. That is docs/36 §1.2 exactly, one resolution up, and it is quadratic in the
// number of strokes drawn — the file's own header claimed "two rungs (draft and
// settle)" while `store` made the second one unreachable.
//
// WHAT THESE TESTS HAVE TO PROVE, and why the equality is the important half: a cache is
// only an optimisation if the answer is the same. Every assertion about a saving below
// is paired with the equality that makes the saving legal, at ACCURACY ZERO —
// `MaskRaster.accumulatedBrushPlane`'s resume is bit-identical to a whole repaint
// (`BrushAccumulationTests` proves the property, `MaskCostTests` proves it across a
// whole session, and these prove the cache actually reaches it).
//
// The mask RASTER cache holds the settle rung too since lane M9, now that its key names
// the whole reference closure; `testTheRasterCacheHoldsSettleRastersWithinItsByteBudget`
// is the bound on it.
//
// These do not run on the Linux lane — `LumenPipeline` is `#if os(macOS)`.

#if os(macOS)
import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

final class MaskPerfTests: XCTestCase {

    /// Just above `PipelineRenderer.maskRasterLongEdge`, so these planes land in the
    /// settle rung rather than the draft one, and small enough that painting a set at
    /// this size is a test rather than a benchmark.
    private let settleSize = (width: 1100, height: 734)
    private let draftSize = (width: 1024, height: 683)

    private func strokeSet(count: Int) -> BrushStrokeSet {
        // Deliberately the same fixture shape as `BrushAccumulationTests`: overlapping
        // strokes with alternating feather and a periodic eraser, so the fold order and
        // the density ceiling both matter and an implementation that quietly repainted
        // could not accidentally agree.
        var strokes: [BrushStroke] = []
        for i in 0..<count {
            let t = Double(i) / Double(Swift.max(count - 1, 1))
            let y = 0.25 + 0.5 * t
            let points = (0...6).map { step -> BrushPoint in
                let u = Double(step) / 6
                return BrushPoint(x: 0.15 + 0.7 * u,
                                  y: y + 0.06 * sin(u * 6.2 + Double(i)),
                                  pressure: 1, t: step * 8)
            }
            strokes.append(BrushStroke(points: points, size: 0.10,
                                       feather: i.isMultiple(of: 2) ? 60 : 10,
                                       flow: 55, density: 90,
                                       erase: i.isMultiple(of: 5) && i > 0,
                                       automask: false))
        }
        return BrushStrokeSet(strokes: strokes)
    }

    private func prefix(_ set: BrushStrokeSet, _ k: Int) -> BrushStrokeSet {
        BrushStrokeSet(strokes: Array(set.strokes.prefix(k)))
    }

    private func worstDifference(_ a: Plane, _ b: Plane) -> Double {
        guard a.width == b.width, a.height == b.height else { return .infinity }
        var worst: Double = 0
        for i in 0..<a.values.count {
            worst = Swift.max(worst, abs(Double(a.values[i]) - Double(b.values[i])))
        }
        return worst
    }

    private func marked(_ value: Float) -> Plane {
        Plane(width: 4, height: 4, fill: Double(value))
    }

    // MARK: - The invariant

    /// THE ONE THAT MATTERS. A settle reached by appending a stroke to a warm cache is
    /// bit-identical to a settle reached by a cold cache painting the whole set — and
    /// the warm one painted exactly the stroke that was added.
    ///
    /// Both halves are needed and neither is sufficient. Without the equality the
    /// saving is a wrong mask; without the stroke count the equality is satisfied by
    /// the shipped behaviour, which repaints everything and is therefore trivially
    /// equal to itself.
    func testTheSettledPlaneIsTheSameWhetherTheCacheWasWarmOrCold() {
        let set = strokeSet(count: 6)
        let key = "mask-a#0"

        let cold = BrushPlaneCache()
        let coldPlane = cold.plane(componentKey: key, set: set, size: settleSize,
                                   sourceKey: "-", source: nil)

        // The warm sequence, in the order the app produces it: five strokes settle,
        // then the sixth is drawn and the settle runs again.
        let warm = BrushPlaneCache()
        _ = warm.plane(componentKey: key, set: prefix(set, 5), size: settleSize,
                       sourceKey: "-", source: nil)
        let before = BrushPlaneCache.currentStats.strokesPainted
        let warmPlane = warm.plane(componentKey: key, set: set, size: settleSize,
                                   sourceKey: "-", source: nil)
        let painted = BrushPlaneCache.currentStats.strokesPainted - before

        XCTAssertEqual(worstDifference(coldPlane, warmPlane), 0, accuracy: 0,
                       "a settle served from a warm brush cache is not the picture a "
                       + "cold render produces. The whole safety of the settle rung is "
                       + "this equality; a resume that is merely close is a wrong mask "
                       + "in the loupe and in the delivered file.")
        XCTAssertEqual(painted, 1,
                       "the settle repainted \(painted) strokes for a set that grew by "
                       + "one. The settle rung is not being held — `store`'s retention "
                       + "rule is refusing planes above the 1024 draft proxy again, "
                       + "which is docs/36 §1.2 alive at settle resolution: every "
                       + "stroke a photographer draws repaints every stroke before it, "
                       + "at up to sixteen times the proxy's pixels.")
    }

    /// The same statement carried across a session rather than one append, and stated
    /// as the number the docs/36 counter exists to report: painting a set of N strokes
    /// one gesture at a time costs N strokes in total, not N(N+1)/2.
    func testASessionOfStrokesCostsItsStrokesAndNotTheirSquare() {
        let cache = BrushPlaneCache()
        let set = strokeSet(count: 7)
        let before = BrushPlaneCache.currentStats.strokesPainted
        for n in 1...set.strokes.count {
            _ = cache.plane(componentKey: "m#0", set: prefix(set, n), size: settleSize,
                            sourceKey: "-", source: nil)
        }
        let painted = BrushPlaneCache.currentStats.strokesPainted - before
        XCTAssertEqual(painted, set.strokes.count,
                       "a seven-stroke session painted \(painted) strokes at the settle "
                       + "rung. Unheld, it is 28 — and at sixty strokes it is 1830.")
    }

    // MARK: - What the settle rung still refuses

    /// A DELIVERY IS STILL REFUSED. An export paints at the export target with no
    /// ceiling, a single 45 MP plane is ~180 MB, and a one-shot render has nothing to
    /// resume into — the one thing the original long-edge rule was right about.
    func testAnExportSizedBrushPlaneIsNotHeld() {
        let cache = BrushPlaneCache()
        let set = strokeSet(count: 2)
        let long = DraftLadder.interactiveLongEdgeCeiling + 8
        let size = (width: long, height: 8)

        _ = cache.plane(componentKey: "m#0", set: set, size: size,
                        sourceKey: "-", source: nil)
        let before = BrushPlaneCache.currentStats.strokesPainted
        _ = cache.plane(componentKey: "m#0", set: set, size: size,
                        sourceKey: "-", source: nil)
        XCTAssertEqual(BrushPlaneCache.currentStats.strokesPainted - before, 2,
                       "an export-sized brush plane is being held; deliveries are the "
                       + "one thing the byte budget must not be spent on")
    }

    /// The budget is a BYTE budget and it bounds. A count cap cannot: the same twelve
    /// entries are 34 MB at the draft proxy and 537 MB at the interactive ceiling, and
    /// which one you get depends on the size of the photographer's display.
    func testTheSettleRungIsBoundedByBytesRatherThanByCount() {
        let cache = BrushPlaneCache()
        let set = strokeSet(count: 1)
        let size = (width: 2600, height: 1733)
        let each = size.width * size.height * MemoryLayout<Float>.stride
        let fitting = BrushPlaneCache.settleResidencyBudget / each
        XCTAssertGreaterThan(fitting, 1, "the fixture must fit more than one plane")

        for i in 0...fitting {
            _ = cache.plane(componentKey: "m#\(i)", set: set, size: size,
                            sourceKey: "-", source: nil)
        }
        let before = BrushPlaneCache.currentStats.strokesPainted
        _ = cache.plane(componentKey: "m#0", set: set, size: size,
                        sourceKey: "-", source: nil)
        XCTAssertEqual(BrushPlaneCache.currentStats.strokesPainted - before, 1,
                       "the settle rung grew past its byte budget. A long-edge cap "
                       + "cannot bound this — that is the whole reason the rule is "
                       + "written in bytes.")
    }

    /// A draft-rung plane is never resumed into a settle-rung request. Newly
    /// reachable: until the settle rung was held, only one size was ever in this cache.
    ///
    /// The key carries `WxH`, so the two are different entries; this asserts the
    /// consequence rather than the mechanism, because a future key that dropped the
    /// size term would look locally reasonable and would silently paint a 1024 plane
    /// into a 4096 mask.
    func testADraftRungPlaneIsNeverResumedIntoASettleRungRequest() {
        let cache = BrushPlaneCache()
        let set = strokeSet(count: 4)
        _ = cache.plane(componentKey: "m#0", set: set, size: draftSize,
                        sourceKey: "-", source: nil)

        let before = BrushPlaneCache.currentStats.strokesPainted
        let settle = cache.plane(componentKey: "m#0", set: set, size: settleSize,
                                 sourceKey: "-", source: nil)
        let painted = BrushPlaneCache.currentStats.strokesPainted - before

        XCTAssertEqual(painted, set.strokes.count,
                       "the settle resumed from the DRAFT rung's plane — a plane of a "
                       + "different size, which is a different mask")
        XCTAssertEqual(settle.width, settleSize.width)
        XCTAssertEqual(settle.height, settleSize.height)

        let cold = BrushPlaneCache()
        let reference = cold.plane(componentKey: "m#0", set: set, size: settleSize,
                                   sourceKey: "-", source: nil)
        XCTAssertEqual(worstDifference(reference, settle), 0, accuracy: 0)
    }

    /// A brush plane painted WITH the picture is not served to a request without it,
    /// and the other way round. `sourceKey` is the only term in this key that is
    /// trusted rather than verified — the strokes are compared for real — so it is the
    /// one worth a test of its own.
    func testTheAutomaskSourceTermSeparatesTwoOtherwiseIdenticalPlanes() {
        let cache = BrushPlaneCache()
        let set = strokeSet(count: 3)
        _ = cache.plane(componentKey: "m#0", set: set, size: settleSize,
                        sourceKey: "photo|tone-a", source: nil)
        let before = BrushPlaneCache.currentStats.strokesPainted
        _ = cache.plane(componentKey: "m#0", set: set, size: settleSize,
                        sourceKey: "photo|tone-b", source: nil)
        XCTAssertEqual(BrushPlaneCache.currentStats.strokesPainted - before,
                       set.strokes.count,
                       "a plane painted against one picture was served for another")
    }

    // MARK: - The raster cache

    /// The mask RASTER cache holds the settle rung now (lane M9), within a byte budget.
    ///
    /// This used to assert the opposite, and the refusal was right while the raster key
    /// did not name the masks a `maskRef` component resolves against. The key now closes
    /// over the whole reference closure (`maskSelectionFingerprint` of
    /// `MaskDependency.closure`, plus the closure's stroke refs and matte generation —
    /// `MaskReferencePipelineTests` exercises each), so the under-key the refusal was
    /// covering for is gone and holding the raster is only a memory question. What must
    /// still hold: an identical settle key is a hit, a changed key bakes, the bytes
    /// held stay under `settleResidencyBudget`, and an export-size raster is not held.
    func testTheRasterCacheHoldsSettleRastersWithinItsByteBudget() {
        let cache = MaskRasterCache()
        let settleRaster = Plane(width: 1100, height: 734, fill: 0.375)
        var bakes = 0
        for _ in 0..<2 {
            _ = cache.plane(maskID: "m", key: "settle", identity: "photo",
                            allowStale: false) { bakes += 1; return settleRaster }
        }
        XCTAssertEqual(bakes, 1, "an identical settle key rasterized twice")
        _ = cache.plane(maskID: "m", key: "settle-2", identity: "photo",
                        allowStale: false) { bakes += 1; return settleRaster }
        XCTAssertEqual(bakes, 2, "a changed key must bake")

        // Fill past the budget with the largest interactive raster, many masks.
        let large = Plane(width: 4096, height: 2731, fill: 0.5)
        for i in 0..<8 {
            _ = cache.plane(maskID: "big\(i)", key: "k", identity: "photo",
                            allowStale: false) { large }
        }
        XCTAssertLessThanOrEqual(cache.settledBytes, MaskRasterCache.settleResidencyBudget)
        // The newest 4096-class raster is held: asking again does not bake.
        _ = cache.plane(maskID: "big7", key: "k", identity: "photo", allowStale: false) {
            XCTFail("the newest 4096×2731 settle raster was not held")
            return large
        }
        XCTAssertGreaterThan(cache.settledBytes, 0)

        // Above the interactive ceiling is a delivery, and it is never held.
        let export = Plane(width: 6000, height: 4, fill: 0.5)
        var exportBakes = 0
        for _ in 0..<2 {
            _ = cache.plane(maskID: "x", key: "export", identity: "photo",
                            allowStale: false) { exportBakes += 1; return export }
        }
        XCTAssertEqual(exportBakes, 2, "an export-size raster was held")
    }

    /// A settle drops the drag's queued draft raster: it is work for a frame of a
    /// gesture that has ended, competing for memory bandwidth with the bake the
    /// photographer is waiting for.
    ///
    /// Asserted through the pending flag rather than by timing, so it is a statement
    /// about the queue and not about a machine.
    func testASettleCancelsTheDragsQueuedDraftRaster() {
        let cache = MaskRasterCache()
        let started = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        _ = cache.plane(maskID: "m", key: "k0", identity: "photo",
                        allowStale: true) { self.marked(0) }

        // ONE BAKE IN FLIGHT AND HELD THERE, so the queue below is deterministic: the
        // drain cannot reach k2 until k1 returns, and k1 does not return until this
        // test says so. Without the handshake the drain could legitimately pick k2 up
        // before the settle arrives, and the assertion would be about scheduling.
        _ = cache.plane(maskID: "m", key: "k1", identity: "photo", allowStale: true) {
            started.signal()
            gate.wait()
            return self.marked(1)
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success,
                       "the background raster never started")
        _ = cache.plane(maskID: "m", key: "k2", identity: "photo", allowStale: true) {
            XCTFail("the queued draft raster ran after the hand stopped")
            return self.marked(2)
        }

        _ = cache.plane(maskID: "m", key: "k3", identity: "photo",
                        allowStale: false) { self.marked(3) }
        gate.signal()

        let deadline = Date(timeIntervalSinceNow: 5)
        while cache.hasPendingBake("m"), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertFalse(cache.hasPendingBake("m"),
                       "the drag's queued raster outlived the settle that superseded it")
    }

    // MARK: - The mask image over a held raster

    private func pixels(_ image: CIImage, width: Int, height: Int) -> [Float] {
        var out = [Float](repeating: -1, count: width * height)
        let context = CIContext(options: [.workingColorSpace: NSNull(),
                                          .outputColorSpace: NSNull()])
        out.withUnsafeMutableBytes { raw in
            context.render(image, toBitmap: raw.baseAddress!,
                           rowBytes: width * MemoryLayout<Float>.size,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .Rf, colorSpace: nil)
        }
        return out
    }

    /// A draft frame handed the SAME held plane reuses the image built over it, and
    /// anything else — equal bytes in other storage, another extent, a settle, a
    /// cleared photograph — builds a fresh one. The equality half: the reused image
    /// renders exactly what `image(from:)` builds from the same plane.
    func testTheMaskImageIsReusedOnlyForTheSameHeldPlane() {
        let renderer = PipelineRenderer()
        let extent = CGRect(x: 0, y: 0, width: 8, height: 8)
        let values = (0..<16).map { Float($0) / 15 }
        let held = Plane(width: 4, height: 4, values: values)

        let first = renderer.maskImage(maskID: "m", plane: held, extent: extent,
                                       memoize: true)
        let second = renderer.maskImage(maskID: "m", plane: held, extent: extent,
                                        memoize: true)
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second, "the same held plane rebuilt its image")
        let fresh = PipelineRenderer.image(from: held, targetExtent: extent)!
        XCTAssertEqual(pixels(second!, width: 8, height: 8),
                       pixels(fresh, width: 8, height: 8),
                       "the reused mask image does not render what a fresh one does")

        // Equal bytes, separate storage: identity is the contract, not equality.
        let copy = Plane(width: 4, height: 4, values: values.map { $0 })
        let rebuilt = renderer.maskImage(maskID: "m", plane: copy, extent: extent,
                                         memoize: true)
        XCTAssertFalse(rebuilt === second)

        // Different values must never be served the old image.
        let other = Plane(width: 4, height: 4, fill: 0.25)
        let changed = renderer.maskImage(maskID: "m", plane: other, extent: extent,
                                         memoize: true)!
        XCTAssertFalse(changed === rebuilt)
        XCTAssertNotEqual(pixels(changed, width: 8, height: 8),
                          pixels(second!, width: 8, height: 8))

        // Another extent (zoom, resolution) is another transform.
        let wider = renderer.maskImage(maskID: "m", plane: other,
                                       extent: CGRect(x: 0, y: 0, width: 16, height: 16),
                                       memoize: true)
        XCTAssertFalse(wider === changed)

        // A settle-size raster is never pinned, and does not disturb the memo.
        let settle = renderer.maskImage(maskID: "m", plane: other,
                                        extent: CGRect(x: 0, y: 0, width: 16, height: 16),
                                        memoize: false)
        XCTAssertFalse(settle === wider)
        XCTAssertTrue(renderer.maskImage(maskID: "m", plane: other,
                                         extent: CGRect(x: 0, y: 0, width: 16, height: 16),
                                         memoize: true) === wider)

        // Pruned with the plan, and cleared with the photograph.
        renderer.pruneMaskImages(keeping: ["n"])
        let afterPrune = renderer.maskImage(maskID: "m", plane: other,
                                            extent: CGRect(x: 0, y: 0, width: 16, height: 16),
                                            memoize: true)
        XCTAssertFalse(afterPrune === wider)
        renderer.forgetMattes(for: URL(fileURLWithPath: "/tmp/x.dng"))
        XCTAssertFalse(renderer.maskImage(maskID: "m", plane: other,
                                          extent: CGRect(x: 0, y: 0, width: 16, height: 16),
                                          memoize: true) === afterPrune)
    }
}
#endif
