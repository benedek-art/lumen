// What `RenderPlan` costs to construct — the CPU half of a frame, on the free lane.
//
// Every performance instrument this project has is macOS-only (`PerfProbeTests`,
// `DragProbeTests`), which means the CPU side of the render loop has only ever been
// measured on the scarce runner, in whatever build that lane happens to use. It does
// not need to be: `RenderPlan` is pure LumenCore, it is constructed once per frame on
// the render actor IN FRONT of the GPU work, and the thing that dominates it — a 33³
// colour table, ~36 000 evaluations of a transform holding three cube roots, an
// `atan2`, a sine and a cosine — is arithmetic Linux can time perfectly well.
//
// WHAT THIS PROBE IS FOR, concretely. The interesting number is not the cost, it is the
// GAP between the two paths:
//
//   · DRAFT (`allowStaleTables: true`) is what every frame of a slider drag pays. It
//     serves the newest table the cache holds and lets the exact bake for this event's
//     key land in the background, so the frame never blocks on one.
//   · SETTLE (`allowStaleTables: false`) is what the single frame after the hand stops
//     pays. It blocks on the exact bake, which is the whole reason the picture at rest
//     is exact.
//
// That GAP is useful telemetry, but not proof of which work ran: key construction,
// the deliberately exact tone cube, and contention with the background bake all
// contribute to a draft. A former draft < settle / 4 assertion failed even with
// ZERO synchronous colour/finish bakes. The operation-count test below establishes
// that contract directly, including the final exact pixels after the worker drains.
//
// It PRINTS and asserts only a sanity ceiling: a shared runner's CPU is not the owner's,
// and a threshold tuned to one fails spuriously on the other. Read the ratios.
import XCTest
@testable import LumenCore

final class PlanCostProbeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        drainAllSlots()
        PlanTableCache.clear()
        PlanTableCache.setRenderIdentity("plan-cost-probe")
    }

    override func tearDown() {
        drainAllSlots()
        PlanTableCache.clear()
        PlanTableCache.setRenderIdentity("")
        super.tearDown()
    }

    /// `clear` intentionally does not cancel an in-flight bake. Wait FIRST, across
    /// every slot, or old work can repopulate a supposedly cold measurement.
    private func drainAllSlots(file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(20)
        while PlanTableCache.Slot.allCases.contains(where: { PlanTableCache.hasPendingBake($0) }),
              Date() < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertFalse(PlanTableCache.Slot.allCases.contains(where: { PlanTableCache.hasPendingBake($0) }),
                       "background work did not drain", file: file, line: line)
    }

    /// A photograph that already has work on it: an empty recipe short-circuits half
    /// the identity checks and would price a plan nobody builds.
    private func base() -> Recipe {
        var r = Recipe()
        r.develop.tone.exposure = 0.4
        r.develop.tone.contrast = 20
        r.develop.tone.highlights = -40
        r.develop.tone.shadows = 25
        r.develop.raw.temp = 5200
        r.develop.color.vibrance = 10
        r.develop.detail.clarity = 25
        r.develop.detail.sharpen.amount = 60
        r.develop.denoise.mode = .classic
        return r
    }

    /// Which control the hand is on, and what each one invalidates.
    private static let controls: [(name: String, move: (inout Recipe, Double) -> Void)] = [
        // Re-keys the tone gain cube only.
        ("exposure", { r, t in r.develop.tone.exposure = -1 + 2 * t }),
        // Moves the tone ANCHORS, so it re-keys the finish table as well.
        ("whites", { r, t in r.develop.tone.whites = -60 + 120 * t }),
        // Re-keys the colour+grade table.
        ("saturation", { r, t in r.develop.color.saturation = -50 + 100 * t }),
        // Re-keys nothing: presence is not a table. The floor every other row is
        // measured against.
        ("texture", { r, t in r.develop.detail.texture = 100 * t }),
    ]

    private func percentile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let i = Swift.min(sorted.count - 1,
                          Swift.max(0, Int((Double(sorted.count - 1) * q).rounded())))
        return sorted[i]
    }

    func testPrintPlanConstructionCostPerControl() {
        let events = 60
        #if DEBUG
        print("PLANPROBE build: DEBUG — a table bake is inflated roughly 10× against "
                + "the shipping build. Read the DRAFT/SETTLE ratio, not the absolutes.")
        #else
        print("PLANPROBE build: RELEASE")
        #endif

        for (name, move) in Self.controls {
            var medians: [Double] = []
            for stale in [true, false] {
                drainAllSlots()
                PlanTableCache.clear()
                // One warm construction so the cache has something to be stale FROM;
                // the first request for a slot bakes synchronously by design.
                var warm = base()
                move(&warm, 0.5)
                _ = RenderPlan(recipe: warm, lutSize: LUT3D.interactiveSize,
                               allowStaleTables: stale)
                PlanTableCache.resetStats()

                var samples: [Double] = []
                samples.reserveCapacity(events)
                for i in 0..<events {
                    var recipe = base()
                    move(&recipe, (Double(i) + 0.5) / Double(events))
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    _ = RenderPlan(recipe: recipe, lutSize: LUT3D.interactiveSize,
                                   allowStaleTables: stale)
                    samples.append(
                        Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
                }
                let sorted = samples.sorted()
                medians.append(percentile(sorted, 0.5))
                let path = stale ? "draft " : "settle"
                let label = path + " " + name
                    + String(repeating: " ", count: Swift.max(0, 11 - name.count))
                print(String(format: "PLANPROBE %@ p50 %7.2f  p95 %7.2f  max %7.2f ms",
                             label, percentile(sorted, 0.5), percentile(sorted, 0.95),
                             sorted.last ?? 0))
                // Count completed deferred work as well, outside the timed region.
                drainAllSlots()
                for slot in PlanTableCache.Slot.allCases {
                    let count = PlanTableCache.traffic(slot)
                    print("PLANPROBE \(label) \(slot.rawValue): hits \(count.hits), "
                          + "sync \(count.bakes), stale \(count.staleServes), "
                          + "deferred \(count.deferredBakes), joined \(count.joinedBakes)")
                }
                XCTAssertLessThan(sorted.last ?? 0, 30_000,
                                  "\(label): building one plan took over thirty "
                                      + "seconds — broken, not merely slow")
            }
            print(String(format: "PLANPROBE %@ draft/settle p50 ratio %.3f (telemetry, not a bake-count assertion)",
                         name, medians[0] / Swift.max(medians[1], .leastNonzeroMagnitude)))
        }
    }

    /// Real plans, with the deferred worker held behind a test-owned semaphore. Every
    /// changed expensive table MUST serve stale, not synchronously bake; after release,
    /// newest-request coalescing must publish exact tables used by the settle. A timing
    /// ratio cannot establish any of these properties. The gate never suspends a queue,
    /// has a bounded wait, and releases/drains on every exit, including assertion failure.
    func testATableRekeyingDragDoesNotPayTheBakePerFrame() {
        for control in ["whites", "saturation"] {
            guard let move = Self.controls.first(where: { $0.name == control })?.move
            else { return XCTFail("fixture names a control that is not in the table") }
            drainAllSlots()
            PlanTableCache.clear()
            var live = base()
            // A live grade makes the Whites anchor change actual colour samples,
            // not only the conservative colour-table key used by the timing fixture.
            live.look.wheels.high.sat = 25
            live.look.wheels.high.hue = 30
            var warmRecipe = live
            move(&warmRecipe, 0.5)
            let warm = RenderPlan(recipe: warmRecipe)

            // These recipes have no proof, so this slot can occupy the serial bake
            // worker without touching either real table being tested.
            let marker = LUT3D.identity(size: 2)
            _ = PlanTableCache.table(.finishProofed, key: "probe-worker-idle", size: 2) { marker }
            let started = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            _ = PlanTableCache.tableAllowingStale(.finishProofed, key: "probe-worker-running", size: 2) {
                started.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 20), .success,
                               "test must release the deferred worker")
                return marker
            }
            defer { release.signal(); drainAllSlots() }
            guard started.wait(timeout: .now() + 5) == .success else {
                return XCTFail("test deferred worker never started")
            }
            PlanTableCache.resetStats()
            let events = 12
            var lastRecipe = warmRecipe
            for i in 0..<events {
                var recipe = live
                move(&recipe, (Double(i) + 0.5) / Double(events))
                let draft = RenderPlan(recipe: recipe, allowStaleTables: true)
                XCTAssertEqual(draft.recipe, recipe)
                XCTAssertTrue(draft.colorGradeLUT == warm.colorGradeLUT,
                               "same-photo stale colour pixels must be the previous plan's")
                XCTAssertTrue(draft.finishLUT == warm.finishLUT,
                               "same-photo stale finish pixels must be the previous plan's")
                XCTAssertEqual(draft.finishScale, warm.finishScale,
                               "a stale table must retain its matching normalization scalar")
                lastRecipe = recipe
            }
            let changedSlots: [PlanTableCache.Slot] = control == "whites"
                ? [.colorGrade, .finish] : [.colorGrade]
            for slot in changedSlots {
                let traffic = PlanTableCache.traffic(slot)
                XCTAssertEqual(traffic.staleServes, events, "\(control) \(slot)")
                XCTAssertEqual(traffic.hits, 0, "fixture must exercise fresh keys")
                XCTAssertEqual(traffic.bakes, 0, "\(control) \(slot) must not bake on the render path")
                XCTAssertEqual(traffic.deferredBakes, 0, "test worker is still held")
            }
            let tone = PlanTableCache.traffic(.toneGain)
            XCTAssertEqual(tone.bakes, control == "whites" ? events : 0,
                           "the tone cube stays exact; do not make it stale to win a timing ratio")
            XCTAssertEqual(tone.hits, control == "whites" ? 0 : events)
            XCTAssertEqual(tone.staleServes, 0)
            if control == "saturation" {
                XCTAssertEqual(PlanTableCache.traffic(.finish).hits, events)
                XCTAssertEqual(PlanTableCache.traffic(.finish).bakes, 0)
            }

            release.signal()
            drainAllSlots()
            for slot in changedSlots {
                XCTAssertEqual(PlanTableCache.traffic(slot).deferredBakes, 1,
                               "with no target bake in flight, only the newest pending key should bake")
            }
            PlanTableCache.resetStats()
            let settled = RenderPlan(recipe: lastRecipe)
            for slot in [PlanTableCache.Slot.colorGrade, .finish, .toneGain] {
                XCTAssertEqual(PlanTableCache.traffic(slot).hits, 1, "settle must use the published exact key")
                XCTAssertEqual(PlanTableCache.traffic(slot).bakes, 0, "settle must not repair missing publication")
            }
            PlanTableCache.clear()
            let fresh = RenderPlan(recipe: lastRecipe)
            XCTAssertTrue(settled.colorGradeLUT == fresh.colorGradeLUT, "settled colour must equal fresh pixels")
            XCTAssertTrue(settled.finishLUT == fresh.finishLUT, "settled finish must equal fresh pixels")
            XCTAssertEqual(settled.finishScale, fresh.finishScale)
            XCTAssertTrue(settled.toneGainCubeBaked == fresh.toneGainCubeBaked)
            XCTAssertEqual(settled.toneGainScale, fresh.toneGainScale)
            XCTAssertTrue(fresh.colorGradeLUT != warm.colorGradeLUT, "fixture must change actual colour pixels")
            if control == "whites" {
                XCTAssertTrue(fresh.finishLUT != warm.finishLUT)
                XCTAssertTrue(fresh.toneGainCubeBaked != warm.toneGainCubeBaked)
            }
        }
    }

    func testColdDraftAndWarmCurrentPlansHaveExplicitPerSlotCosts() {
        let recipe = base()
        PlanTableCache.resetStats()
        let cold = RenderPlan(recipe: recipe, allowStaleTables: true)
        for slot in [PlanTableCache.Slot.colorGrade, .finish, .toneGain] {
            let traffic = PlanTableCache.traffic(slot)
            XCTAssertEqual(traffic.bakes, 1, "a cold draft has nothing to borrow")
            XCTAssertEqual(traffic.hits, 0)
            XCTAssertEqual(traffic.staleServes, 0)
        }
        PlanTableCache.resetStats()
        let warm = RenderPlan(recipe: recipe, allowStaleTables: true)
        for slot in [PlanTableCache.Slot.colorGrade, .finish, .toneGain] {
            XCTAssertEqual(PlanTableCache.traffic(slot).hits, 1)
            XCTAssertEqual(PlanTableCache.traffic(slot).bakes, 0)
        }
        XCTAssertTrue(cold.finishLUT == warm.finishLUT)
        XCTAssertTrue(cold.colorGradeLUT == warm.colorGradeLUT)

        // An inherited identity must not lend a stale table to a different photo.
        PlanTableCache.setRenderIdentity("plan-cost-other-photo")
        var changed = recipe
        changed.develop.tone.whites = 45
        PlanTableCache.resetStats()
        let otherPhoto = RenderPlan(recipe: changed, allowStaleTables: true)
        for slot in [PlanTableCache.Slot.colorGrade, .finish, .toneGain] {
            XCTAssertEqual(PlanTableCache.traffic(slot).bakes, 1)
            XCTAssertEqual(PlanTableCache.traffic(slot).staleServes, 0)
        }
        PlanTableCache.clear()
        let exact = RenderPlan(recipe: changed)
        XCTAssertTrue(otherPhoto.finishLUT == exact.finishLUT)
        XCTAssertTrue(otherPhoto.colorGradeLUT == exact.colorGradeLUT)
    }
}
