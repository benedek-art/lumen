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

    func testTheFirstSightOfAMaskBakesSynchronously() {
        let cache = MaskRasterCache()
        var bakes = 0
        let out = cache.plane(maskID: "m", key: "A", allowStale: true) {
            bakes += 1
            return self.marked(1)
        }
        XCTAssertEqual(bakes, 1, "a mask never seen before has nothing to be stale from")
        XCTAssertEqual(out.values, marked(1).values)
    }

    func testADraftServesThePreviousRasterAndThenConverges() {
        let cache = MaskRasterCache()
        _ = cache.plane(maskID: "m", key: "A", allowStale: true) { self.marked(1) }

        let immediate = cache.plane(maskID: "m", key: "B", allowStale: true) {
            self.marked(2)
        }
        XCTAssertEqual(immediate.values, marked(1).values,
                       "the draft frame should get A's raster while B bakes")

        waitForBakes(cache, maskID: "m")
        var rebaked = false
        let after = cache.plane(maskID: "m", key: "B", allowStale: true) {
            rebaked = true
            return self.marked(2)
        }
        XCTAssertEqual(after.values, marked(2).values)
        XCTAssertFalse(rebaked, "the exact raster should come from the background bake")
    }

    func testASettleFrameNeverGetsAStaleRaster() {
        let cache = MaskRasterCache()
        _ = cache.plane(maskID: "m", key: "A", allowStale: true) { self.marked(1) }
        let settled = cache.plane(maskID: "m", key: "C", allowStale: false) {
            self.marked(3)
        }
        XCTAssertEqual(settled.values, marked(3).values,
                       "allowStale: false must bake the exact raster now")
    }

    func testABurstOfMaskEditsCoalescesToTheNewestRaster() {
        let cache = MaskRasterCache()
        _ = cache.plane(maskID: "m", key: "k0", allowStale: true) { self.marked(0) }

        let counterLock = NSLock()
        var bakes = 0
        for i in 1...40 {
            _ = cache.plane(maskID: "m", key: "k\(i)", allowStale: true) {
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
        let newest = cache.plane(maskID: "m", key: "k40", allowStale: false) {
            rebaked = true
            return self.marked(40)
        }
        XCTAssertFalse(rebaked, "k40 should already be held from the drain")
        XCTAssertEqual(newest.values, marked(40).values)
    }
}
#endif
