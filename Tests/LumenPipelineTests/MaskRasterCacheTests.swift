// The mask-raster cache's contract, tested at the policy level (docs/23 M1a): a DRAFT
// frame may show a mask's previous raster while the exact one bakes; a settle frame
// may not; the first sight of a mask bakes synchronously; and a burst of changes bakes
// a handful of rasters, not one per event. Mirrors PlanTableCacheTests' stale-while-
// bake suite — same pattern, planes instead of tables.
#if os(macOS)
import XCTest
@testable import LumenCore
@testable import LumenPipeline

final class MaskRasterCacheTests: XCTestCase {

    private func marked(_ value: Float) -> Plane {
        var plane = Plane(width: 4, height: 4)
        for i in 0..<plane.values.count { plane.values[i] = value }
        return plane
    }

    private func waitForBakes(_ cache: MaskRasterCache, maskID: String,
                              timeoutSeconds: Double = 5.0) {
        let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
        while cache.hasPendingBake(maskID), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertFalse(cache.hasPendingBake(maskID),
                       "background raster did not drain within \(timeoutSeconds)s")
    }

    func testClearRejectsAnAlreadyRunningBakeWithoutDisturbingANewSameKeyRequest() {
        let cache = MaskRasterCache()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let newBake = DispatchSemaphore(value: 0)
        defer { release.signal() }
        _ = cache.plane(maskID: "m", key: "A", identity: "photo", allowStale: false) {
            self.marked(1)
        }
        _ = cache.plane(maskID: "m", key: "B", identity: "photo", allowStale: true) {
            started.signal()
            _ = release.wait(timeout: .now() + 5)
            return self.marked(2)
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        cache.clear()
        // Seed the new source, then request the exact same key the old source is
        // baking. The old worker must not remove or consume this new-era job.
        _ = cache.plane(maskID: "m", key: "A", identity: "photo", allowStale: false) {
            self.marked(3)
        }
        _ = cache.plane(maskID: "m", key: "B", identity: "photo", allowStale: true) {
            newBake.signal()
            return self.marked(4)
        }
        release.signal()
        XCTAssertEqual(newBake.wait(timeout: .now() + 5), .success,
                       "the old worker lost the replacement source's same-key job")
        // A queued different-mask bake is a deterministic barrier: the serial bake
        // queue can only reach it after publishing m's new pixels.
        let barrier = DispatchSemaphore(value: 0)
        _ = cache.plane(maskID: "barrier", key: "A", identity: "photo", allowStale: false) {
            self.marked(0)
        }
        _ = cache.plane(maskID: "barrier", key: "B", identity: "photo", allowStale: true) {
            barrier.signal()
            return self.marked(0)
        }
        XCTAssertEqual(barrier.wait(timeout: .now() + 5), .success)
        var rebaked = false
        let actual = cache.plane(maskID: "m", key: "B", identity: "photo", allowStale: false) {
            rebaked = true
            return self.marked(99)
        }
        XCTAssertFalse(rebaked)
        XCTAssertEqual(actual.values, marked(4).values)
    }

    func testClearPreventsAnOldBakeFromRepopulatingAnEmptyCache() {
        let cache = MaskRasterCache()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        _ = cache.plane(maskID: "m", key: "A", identity: "photo", allowStale: false) {
            self.marked(1)
        }
        _ = cache.plane(maskID: "m", key: "B", identity: "photo", allowStale: true) {
            started.signal()
            _ = release.wait(timeout: .now() + 5)
            return self.marked(2)
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        cache.clear()
        let barrier = DispatchSemaphore(value: 0)
        _ = cache.plane(maskID: "barrier", key: "A", identity: "photo", allowStale: false) {
            self.marked(0)
        }
        _ = cache.plane(maskID: "barrier", key: "B", identity: "photo", allowStale: true) {
            barrier.signal()
            return self.marked(0)
        }
        release.signal()
        XCTAssertEqual(barrier.wait(timeout: .now() + 5), .success)
        var rebaked = false
        let actual = cache.plane(maskID: "m", key: "B", identity: "photo", allowStale: false) {
            rebaked = true
            return self.marked(3)
        }
        XCTAssertTrue(rebaked, "an invalidated in-flight bake repopulated the cache")
        XCTAssertEqual(actual.values, marked(3).values)
    }

    func testClearDuringASynchronousBakePreventsPublication() {
        let cache = MaskRasterCache()
        _ = cache.plane(maskID: "m", key: "A", identity: "photo", allowStale: false) {
            cache.clear()
            return self.marked(1)
        }
        var rebaked = false
        let actual = cache.plane(maskID: "m", key: "A", identity: "photo", allowStale: false) {
            rebaked = true
            return self.marked(2)
        }
        XCTAssertTrue(rebaked)
        XCTAssertEqual(actual.values, marked(2).values)
    }

    func testTheFirstSightOfAMaskBakesSynchronously() {
        let cache = MaskRasterCache()
        var bakes = 0
        let out = cache.plane(maskID: "m", key: "A", identity: "photo", allowStale: true) {
            bakes += 1
            return self.marked(1)
        }
        XCTAssertEqual(bakes, 1, "a mask never seen before has nothing to be stale from")
        XCTAssertEqual(out.values, marked(1).values)
    }

    func testADraftServesThePreviousRasterAndThenConverges() {
        let cache = MaskRasterCache()
        _ = cache.plane(maskID: "m", key: "A", identity: "photo", allowStale: true) { self.marked(1) }

        let immediate = cache.plane(maskID: "m", key: "B", identity: "photo", allowStale: true) {
            self.marked(2)
        }
        XCTAssertEqual(immediate.values, marked(1).values,
                       "the draft frame should get A's raster while B bakes")

        waitForBakes(cache, maskID: "m")
        var rebaked = false
        let after = cache.plane(maskID: "m", key: "B", identity: "photo", allowStale: true) {
            rebaked = true
            return self.marked(2)
        }
        XCTAssertEqual(after.values, marked(2).values)
        XCTAssertFalse(rebaked, "the exact raster should come from the background bake")
    }

    func testASettleFrameNeverGetsAStaleRaster() {
        let cache = MaskRasterCache()
        _ = cache.plane(maskID: "m", key: "A", identity: "photo", allowStale: true) { self.marked(1) }
        let settled = cache.plane(maskID: "m", key: "C", identity: "photo", allowStale: false) {
            self.marked(3)
        }
        XCTAssertEqual(settled.values, marked(3).values,
                       "allowStale: false must bake the exact raster now")
    }

    func testABurstOfMaskEditsCoalescesToTheNewestRaster() {
        let cache = MaskRasterCache()
        _ = cache.plane(maskID: "m", key: "k0", identity: "photo", allowStale: true) { self.marked(0) }

        let counterLock = NSLock()
        var bakes = 0
        for i in 1...40 {
            _ = cache.plane(maskID: "m", key: "k\(i)", identity: "photo", allowStale: true) {
                counterLock.lock(); bakes += 1; counterLock.unlock()
                Thread.sleep(forTimeInterval: 0.005)
                return self.marked(Float(i))
            }
        }
        waitForBakes(cache, maskID: "m")

        counterLock.lock(); let executed = bakes; counterLock.unlock()
        XCTAssertLessThan(executed, 10,
            "a 40-event mask drag executed \(executed) background rasters — pending "
                + "should keep only the newest, not replay the drag")

        var rebaked = false
        let newest = cache.plane(maskID: "m", key: "k40", identity: "photo", allowStale: false) {
            rebaked = true
            return self.marked(40)
        }
        XCTAssertFalse(rebaked, "k40 should already be held from the drain")
        XCTAssertEqual(newest.values, marked(40).values)
    }

    /// The stale door never crosses photographs — the same discipline
    /// `PlanTableCacheTests.testAStaleServeNeverCrossesPhotographs` pins for the
    /// colour tables (docs/31 round two §4), here because mask ids travel verbatim
    /// across photographs via Paste Settings: "this mask id's previous raster" can
    /// be a DIFFERENT photograph's rasterized selection, and a draft frame right
    /// after a photo switch must render its masks fresh rather than wear it.
    func testADraftNeverWearsAnotherPhotographsRaster() {
        let cache = MaskRasterCache()
        _ = cache.plane(maskID: "m", key: "A", identity: "photo-1", allowStale: true) {
            self.marked(1)
        }

        var baked = false
        let served = cache.plane(maskID: "m", key: "B", identity: "photo-2",
                                 allowStale: true) {
            baked = true
            return self.marked(2)
        }
        XCTAssertTrue(baked, "a cross-photo miss must rasterize fresh, not borrow")
        XCTAssertEqual(served.values, marked(2).values,
                       "photo 2's draft was served photo 1's selection")
    }
}
#endif
