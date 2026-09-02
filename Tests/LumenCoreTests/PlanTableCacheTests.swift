// PlanTableCacheTests.swift
// The invariant the plan-table cache lives or dies by: a hit must be indistinguishable
// from a cold bake.
//
// A render cache that returns the wrong table does not crash and does not look obviously
// wrong — it shows the photographer the picture they had a moment ago and keeps showing
// it while they drag. That is the worst class of bug this project can ship, so the test
// is written to fail in both directions: every case asserts that the cached plan equals a
// freshly built one, AND that the mutation actually moved a table, so a case that has
// quietly stopped exercising the key announces itself instead of passing.

import XCTest
@testable import LumenCore

final class PlanTableCacheTests: XCTestCase {

    /// A recipe with a live colour stack and a live grade, so both tables are baked
    /// rather than short-circuited to the 2-sample identity.
    private func liveRecipe() -> Recipe {
        var recipe = Recipe()
        recipe.develop.mixer.bands[2].sat = 40
        recipe.look.wheels.shadows.sat = 30
        recipe.look.wheels.shadows.hue = 210
        return recipe
    }

    func testACacheHitEqualsAColdBake() {
        let recipe = liveRecipe()

        // Each case must move at least one table, or it tests nothing about the key.
        // `printerLights` is deliberately absent: it reaches pixels through
        // `LinearStage.printerLightGains`, not through either table, so mutating it
        // proves nothing here. It stays IN the key anyway — over-keying costs a cache
        // miss, under-keying shows a stale picture.
        //
        // A wheel's hue is absent for the same reason: a hue angle at zero saturation is
        // a rotation of nothing, so `wheels.high.hue` alone leaves both tables identical.
        // The saturation is what makes the case bite.
        let cases: [(String, (inout Recipe) -> Void)] = [
            ("tone.whites", { $0.develop.tone.whites = 60 }),
            ("tone.blacks", { $0.develop.tone.blacks = -40 }),
            ("curve.parametric.highlights", { $0.develop.curve.parametric.highlights = 55 }),
            ("curve.point", { $0.develop.curve.point = [[0, 0], [0.5, 0.7], [1, 1]] }),
            ("render.preset", { $0.look.render.preset = "Linear" }),
            ("mixer.bands[2].sat", { $0.develop.mixer.bands[2].sat = -40 }),
            ("wheels.high.sat", { $0.look.wheels.high.sat = 45 }),
            ("color.saturation", { $0.develop.color.saturation = 25 }),
            ("color.vibrance", { $0.develop.color.vibrance = 35 }),
            ("primaries.rHue", { $0.look.primaries.rHue = 8 }),
        ]

        for (name, mutate) in cases {
            var changed = recipe
            mutate(&changed)

            // Warm the cache on the ORIGINAL, then ask for the changed one. If the key
            // misses anything the closures read, this is where the stale table comes
            // back.
            PlanTableCache.clear()
            let base = RenderPlan(recipe: recipe, asShotKelvin: 5500, asShotTint: 0,
                                  lutSize: 17)
            let viaCache = RenderPlan(recipe: changed, asShotKelvin: 5500, asShotTint: 0,
                                      lutSize: 17)

            PlanTableCache.clear()
            let fresh = RenderPlan(recipe: changed, asShotKelvin: 5500, asShotTint: 0,
                                   lutSize: 17)

            XCTAssertEqual(viaCache.finishLUT, fresh.finishLUT,
                           "finishLUT came back stale after \(name)")
            XCTAssertEqual(viaCache.colorGradeLUT, fresh.colorGradeLUT,
                           "colorGradeLUT came back stale after \(name)")
            XCTAssertTrue(base.finishLUT != fresh.finishLUT
                            || base.colorGradeLUT != fresh.colorGradeLUT,
                          "\(name) moved neither table, so it cannot exercise the key")
        }
    }

    /// The same recipe twice must hit, and the hit must be the same object's worth of
    /// values. Without this the suite above would pass for a cache that never stores
    /// anything — which is correct, and pointless.
    func testTheSameRecipeIsServedFromTheCache() {
        let recipe = liveRecipe()
        PlanTableCache.clear()
        let first = RenderPlan(recipe: recipe, asShotKelvin: 5500, asShotTint: 0,
                               lutSize: 17)

        // A slider that touches neither table: this is the drag case the cache exists
        // for, and it must not invalidate.
        var dragged = recipe
        dragged.develop.detail.texture = 62
        dragged.develop.detail.clarity = -31
        dragged.look.vignette = -0.8
        let second = RenderPlan(recipe: dragged, asShotKelvin: 5500, asShotTint: 0,
                                lutSize: 17)

        XCTAssertEqual(first.finishLUT, second.finishLUT)
        XCTAssertEqual(first.colorGradeLUT, second.colorGradeLUT)
        // And the plan still carries the moved values, so nothing was over-cached.
        XCTAssertEqual(second.detail.texture, 62)
        XCTAssertEqual(second.vignetteEV, -0.8)
    }

    /// Toggling the soft proof must not show the previous proof.
    ///
    /// The proofed finish table is DERIVED from the plain one — mapped, not re-baked —
    /// so it rides a second cache slot whose key is the plain table's key plus the proof
    /// settings. Leave the settings out and the plain table's key still hits, so
    /// switching destination or intent keeps rendering the old proof: a stale picture
    /// through a door the rest of this suite does not know about. This is that door.
    func testProofSettingsAreInTheKey() {
        let recipe = liveRecipe()
        let cases: [(String, SoftProof)] = [
            ("off", SoftProof(enabled: false)),
            ("sRGB relative", SoftProof(enabled: true, space: .srgb,
                                        intent: .relativeColorimetric)),
            ("sRGB perceptual", SoftProof(enabled: true, space: .srgb,
                                          intent: .perceptual)),
            ("sRGB + paper white", SoftProof(enabled: true, space: .srgb,
                                             intent: .relativeColorimetric,
                                             simulatePaperWhite: true)),
        ]
        for (name, proof) in cases {
            // Warm on a DIFFERENT proof, then ask for this one.
            PlanTableCache.clear()
            _ = RenderPlan(recipe: recipe, asShotKelvin: 5500, asShotTint: 0, lutSize: 17,
                           softProof: SoftProof(enabled: true, space: .displayP3,
                                                intent: .perceptual))
            let viaCache = RenderPlan(recipe: recipe, asShotKelvin: 5500, asShotTint: 0,
                                      lutSize: 17, softProof: proof)
            PlanTableCache.clear()
            let fresh = RenderPlan(recipe: recipe, asShotKelvin: 5500, asShotTint: 0,
                                   lutSize: 17, softProof: proof)
            XCTAssertEqual(viaCache.finishLUT, fresh.finishLUT,
                           "the proofed finish table came back stale for \(name)")
        }

        // And the proofs must actually differ from each other, or the check above
        // passes for a proof that does nothing.
        PlanTableCache.clear()
        let off = RenderPlan(recipe: recipe, asShotKelvin: 5500, asShotTint: 0,
                             lutSize: 17, softProof: SoftProof(enabled: false))
        let on = RenderPlan(recipe: recipe, asShotKelvin: 5500, asShotTint: 0,
                            lutSize: 17,
                            softProof: SoftProof(enabled: true, space: .srgb,
                                                 intent: .perceptual))
        XCTAssertNotEqual(off.finishLUT, on.finishLUT,
                          "proofing to sRGB perceptual changed nothing, so this test "
                              + "cannot tell a stale table from a fresh one")
    }

    /// Export-size bakes are not cached, because holding 6.6 MB for a table used once is
    /// worse than rebuilding it. The behaviour must still be identical.
    func testExportSizeIsCorrectWhetherOrNotItIsCached() {
        let recipe = liveRecipe()
        PlanTableCache.clear()
        let a = RenderPlan(recipe: recipe, asShotKelvin: 5500, asShotTint: 0,
                           lutSize: LUT3D.exportSize)
        let b = RenderPlan(recipe: recipe, asShotKelvin: 5500, asShotTint: 0,
                           lutSize: LUT3D.exportSize)
        XCTAssertEqual(a.finishLUT, b.finishLUT)
        XCTAssertEqual(a.colorGradeLUT, b.colorGradeLUT)
        XCTAssertEqual(a.finishLUT.size, LUT3D.exportSize)
    }

    /// A different bake size must never be served the other size's table.
    func testSizeIsPartOfTheKey() {
        let recipe = liveRecipe()
        PlanTableCache.clear()
        let draft = RenderPlan(recipe: recipe, asShotKelvin: 5500, asShotTint: 0,
                               lutSize: 17)
        let interactive = RenderPlan(recipe: recipe, asShotKelvin: 5500, asShotTint: 0,
                                     lutSize: LUT3D.interactiveSize)
        XCTAssertEqual(draft.finishLUT.size, 17)
        XCTAssertEqual(interactive.finishLUT.size, LUT3D.interactiveSize)
        XCTAssertEqual(draft.colorGradeLUT.size, 17)
        XCTAssertEqual(interactive.colorGradeLUT.size, LUT3D.interactiveSize)
    }

    /// The HUD's counters (docs/23 M1b) count what actually happened: a cold key is
    /// a bake, a repeat is a hit, a draft-miss with something to be stale from is a
    /// stale serve. Deltas from a snapshot, so the test owes nothing to suite order.
    func testTheStatsCountersCountWhatActuallyHappened() {
        PlanTableCache.clear()
        let before = PlanTableCache.currentStats

        _ = PlanTableCache.table(.finish, key: "stats-A", size: 5) {
            LUT3D(size: 5) { $0 }
        }
        _ = PlanTableCache.table(.finish, key: "stats-A", size: 5) {
            LUT3D(size: 5) { $0 }
        }
        _ = PlanTableCache.tableAllowingStale(.finish, key: "stats-B", size: 5) {
            LUT3D(size: 5) { $0 }
        }

        let after = PlanTableCache.currentStats
        XCTAssertEqual(after.bakes - before.bakes, 1, "one cold key, one bake")
        XCTAssertEqual(after.hits - before.hits, 1, "one repeat, one hit")
        XCTAssertEqual(after.staleServes - before.staleServes, 1,
                       "one draft miss with a table to be stale from")
    }

    // MARK: - The tone gain cube (session C: the last uncached bake)

    /// A tone drag re-plans on every mouse event, and the tone gain cube — 32³ =
    /// 32 768 samples — was the one expensive table not routed through this cache, so
    /// it was rebuilt on every one of them. Every basic tone slider and every zone
    /// invalidates it, which is to say the controls a photographer reaches for first.
    func testATonePlanBakesItsGainCubeOnceAcrossAWholeDrag() {
        PlanTableCache.clear()
        var recipe = Recipe()
        // Contrast, not Exposure: exposure is a pure gain carried by the linear stage,
        // so a tone engine holding only an exposure is still IDENTITY and bakes no
        // cube at all. The controls that build this table are the ones that shape the
        // curve.
        recipe.develop.tone.contrast = 45
        recipe.develop.tone.highlights = -30

        // Per-SLOT traffic, deliberately: the aggregate counters cannot tell a cube
        // that was cached from a cube that never came through the cache at all, so a
        // test written against the totals stays green for the defect it exists to
        // catch. Asked of the tone slot, the numbers have to be about the cube.
        // Deltas: the counters are cumulative for the life of the process, and other
        // cases in this file plan tone recipes too.
        let before = PlanTableCache.traffic(.toneGain)
        _ = RenderPlan(recipe: recipe)
        let afterFirst = PlanTableCache.traffic(.toneGain)
        XCTAssertEqual(afterFirst.bakes - before.bakes, 1,
                       "the cold plan's tone cube must be baked THROUGH the cache")

        // The rest of the drag: the same tone, re-planned the way every mouse event
        // re-plans it. Not one further bake — the whole point.
        for _ in 0..<20 { _ = RenderPlan(recipe: recipe) }
        let afterDrag = PlanTableCache.traffic(.toneGain)
        XCTAssertEqual(afterDrag.bakes, afterFirst.bakes,
                       "re-planning an unchanged tone must not bake the cube again")
        XCTAssertEqual(afterDrag.hits - afterFirst.hits, 20,
                       "every re-plan must be a hit")
    }

    /// The key has to be complete in the other direction too: moving a tone control
    /// must produce a DIFFERENT cube, not a cached one from the previous value.
    func testTheToneCubeKeyTracksToneAndZones() {
        PlanTableCache.clear()
        var a = Recipe()
        a.develop.tone.contrast = 40
        var b = Recipe()
        b.develop.tone.contrast = 80
        var c = Recipe()
        c.develop.tone.contrast = 40
        c.develop.zones.mid.ev = 0.4

        guard let cubeA = RenderPlan(recipe: a).toneGainCubeBaked,
              let cubeB = RenderPlan(recipe: b).toneGainCubeBaked,
              let cubeC = RenderPlan(recipe: c).toneGainCubeBaked else {
            return XCTFail("a moved tone control must bake a cube")
        }
        XCTAssertNotEqual(cubeA.data, cubeB.data,
                          "a moved Contrast must not be served A's cube")
        XCTAssertNotEqual(cubeA.data, cubeC.data,
                          "a zone move must not be served A's cube")
        XCTAssertEqual(RenderPlan(recipe: a).toneGainCubeBaked?.data, cubeA.data,
                       "the same tone must be served the same cube")
        XCTAssertEqual(cubeB.data.count, cubeA.data.count)
    }

    // MARK: - Stale-while-bake (docs/23 M1a)
    //
    // The contract: a DRAFT frame may show the previous event's table while the exact
    // one bakes off the render path; a settle or export frame may not. Staleness is
    // bounded to "the newest table the slot holds", and it converges the moment the
    // background bake lands. These tests drive the cache directly; the RenderPlan
    // plumbing that chooses between `table` and `tableAllowingStale` is asserted by
    // testACacheHitEqualsAColdBake above continuing to pass for the settle path.

    /// A tiny distinguishable table: every sample carries `mark` in its red channel.
    private func markedLUT(_ mark: Double) -> LUT3D {
        LUT3D(size: 5) { rgb in RGB(mark, rgb.g, rgb.b) }
    }

    private func waitForBakes(timeoutSeconds: Double = 5.0) {
        let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
        while PlanTableCache.hasPendingBake(.finish), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertFalse(PlanTableCache.hasPendingBake(.finish),
                       "background bake did not drain within \(timeoutSeconds)s")
    }

    func testTheFirstEverRequestBakesSynchronously() {
        PlanTableCache.clear()
        waitForBakes()
        PlanTableCache.clear()
        var builds = 0
        let out = PlanTableCache.tableAllowingStale(.finish, key: "first", size: 5) {
            builds += 1
            return self.markedLUT(1)
        }
        XCTAssertEqual(builds, 1, "an empty slot has nothing to be stale from")
        XCTAssertEqual(out, markedLUT(1))
    }

    func testAStaleTableIsServedWhileTheExactOneBakesAndThenConverges() {
        PlanTableCache.clear()
        waitForBakes()
        PlanTableCache.clear()
        _ = PlanTableCache.tableAllowingStale(.finish, key: "A", size: 5) { self.markedLUT(1) }

        let immediate = PlanTableCache.tableAllowingStale(.finish, key: "B", size: 5) {
            self.markedLUT(2)
        }
        XCTAssertEqual(immediate, markedLUT(1),
                       "the draft frame should get A's table while B bakes")

        waitForBakes()
        var rebaked = false
        let after = PlanTableCache.tableAllowingStale(.finish, key: "B", size: 5) {
            rebaked = true
            return self.markedLUT(2)
        }
        XCTAssertEqual(after, markedLUT(2), "the next frame should pick up the exact table")
        XCTAssertFalse(rebaked, "the exact table should come from the background bake, "
                           + "not a second synchronous one")
    }

    func testTheBlockingPathNeverReturnsStale() {
        PlanTableCache.clear()
        waitForBakes()
        PlanTableCache.clear()
        _ = PlanTableCache.tableAllowingStale(.finish, key: "A", size: 5) { self.markedLUT(1) }
        // The settle/export path asks `table` for a key the slot does not hold: it
        // must bake NOW, whatever the stale machinery is doing.
        let settled = PlanTableCache.table(.finish, key: "C", size: 5) { self.markedLUT(3) }
        XCTAssertEqual(settled, markedLUT(3))
    }

    func testABurstOfKeysCoalescesToTheNewestBake() {
        PlanTableCache.clear()
        waitForBakes()
        PlanTableCache.clear()
        _ = PlanTableCache.tableAllowingStale(.finish, key: "A", size: 5) { self.markedLUT(0) }

        let counterLock = NSLock()
        var builds = 0
        for i in 1...40 {
            _ = PlanTableCache.tableAllowingStale(.finish, key: "k\(i)", size: 5) {
                counterLock.lock(); builds += 1; counterLock.unlock()
                Thread.sleep(forTimeInterval: 0.005)
                return self.markedLUT(Double(i))
            }
        }
        waitForBakes()

        counterLock.lock(); let executed = builds; counterLock.unlock()
        XCTAssertLessThan(executed, 10,
            "a 40-event burst executed \(executed) background bakes — pending should "
                + "keep only the newest, not replay the drag")

        // The newest key must be exactly what the drain left behind.
        var rebaked = false
        let newest = PlanTableCache.table(.finish, key: "k40", size: 5) {
            rebaked = true
            return self.markedLUT(40)
        }
        XCTAssertFalse(rebaked, "k40 should already be in the cache from the drain")
        XCTAssertEqual(newest, markedLUT(40))
    }

    // MARK: - The stale door never crosses photographs (docs/31 round two §4)
    //
    // The key describes the RECIPE completely, so an exact hit is correct for any
    // photograph. The STALE serve is different: it is a claim about time — "the
    // picture from one mouse event ago" — and across a photo change the newest
    // entry in the slot is a different photograph's picture formation. Stepping
    // from a black-and-white edit to a colour frame rendered the colour frame
    // monochrome for a frame. These tests pin the identity discipline that ends
    // it. Every other test in this file runs under the default (empty) identity,
    // which is an identity like any other, so the pre-identity contract tests
    // above are unchanged — including AccuracyProbeTests'
    // `testTheFinishTableAndItsScaleStayAPairOnTheDRAFTPath`, which holds the
    // table-and-scalar pairing across a stale serve.

    func testAStaleServeNeverCrossesPhotographs() {
        defer { PlanTableCache.setRenderIdentity("") }
        PlanTableCache.clear()
        waitForBakes()
        PlanTableCache.clear()

        // Photograph A carries a B&W look; its finish table lands in the slot.
        PlanTableCache.setRenderIdentity("photo-A")
        _ = PlanTableCache.tableAllowingStale(.finish, key: "bw-look", size: 5) {
            self.markedLUT(1)
        }

        // Step to photograph B, whose recipe is a colour look: a MISS with nothing
        // of B's to be stale from. The old code returned the newest entry in the
        // slot from ANY photograph — A's monochrome table — for a frame. The
        // contract is a fresh, blocking bake instead.
        PlanTableCache.setRenderIdentity("photo-B")
        var baked = false
        let served = PlanTableCache.tableAllowingStale(.finish, key: "colour-look",
                                                       size: 5) {
            baked = true
            return self.markedLUT(2)
        }
        XCTAssertEqual(served, markedLUT(2),
                       "photo B's first draft frame was served photo A's picture "
                           + "formation — the stale door crossed photographs")
        XCTAssertTrue(baked, "a cross-photo miss must bake fresh, not borrow")
    }

    func testAStaleServeStillBorrowsWithinOnePhotograph() {
        defer { PlanTableCache.setRenderIdentity("") }
        PlanTableCache.clear()
        waitForBakes()
        PlanTableCache.clear()

        PlanTableCache.setRenderIdentity("photo-A")
        _ = PlanTableCache.tableAllowingStale(.finish, key: "drag-1", size: 5) {
            self.markedLUT(1)
        }
        // The next event of the SAME photograph's drag: one mouse event stale is
        // the documented contract, and the identity fix must not have broken it.
        let immediate = PlanTableCache.tableAllowingStale(.finish, key: "drag-2",
                                                          size: 5) {
            self.markedLUT(2)
        }
        XCTAssertEqual(immediate, markedLUT(1),
                       "the same photograph's drag frame should ride the previous "
                           + "event's table while the exact one bakes")
        waitForBakes()
    }

    func testAnExactHitCrossesPhotographsAndTheEntryAdoptsThem() {
        defer { PlanTableCache.setRenderIdentity("") }
        PlanTableCache.clear()
        waitForBakes()
        PlanTableCache.clear()

        // A bakes the default-recipe finish table.
        PlanTableCache.setRenderIdentity("photo-A")
        _ = PlanTableCache.table(.finish, key: "default-look", size: 5) {
            self.markedLUT(1)
        }

        // B, carrying the SAME recipe, must hit — the key determines the table
        // bit-for-bit, and rebaking 23.7 ms of identical samples on every photo
        // step is the regression the identity fix was not allowed to introduce.
        PlanTableCache.setRenderIdentity("photo-B")
        var rebaked = false
        let hit = PlanTableCache.table(.finish, key: "default-look", size: 5) {
            rebaked = true
            return self.markedLUT(1)
        }
        XCTAssertFalse(rebaked, "an exact key hit must be shared across photographs")
        XCTAssertEqual(hit, markedLUT(1))

        // And the hit ADOPTED photo B: B's next draft miss may now borrow it —
        // it is the very picture B was showing a moment ago.
        let borrowed = PlanTableCache.tableAllowingStale(.finish, key: "b-drag",
                                                         size: 5) {
            self.markedLUT(3)
        }
        XCTAssertEqual(borrowed, markedLUT(1),
                       "after an exact hit, the entry belongs to photo B and its "
                           + "drag may ride it")
        waitForBakes()
    }
}

// MARK: - Joining a bake instead of repeating it (I1-01, I1-03)
//
// The two doors into this cache did not know about each other. A drag frame goes
// through `tableAllowingStale`: on a miss it serves the newest table and posts the
// EXACT one to `pending` for the background queue. The settle frame that follows goes
// through `table`, which read `entries` and nothing else — so it missed, and baked a
// second copy of the table `bakeQueue` was already making. Then `drainPending` popped
// its own entry, found the key it had queued, and baked a third.
//
// Measured on the release build: a Saturation settle is 269.4 ms against a 24.1 ms
// draft, a Whites settle 388.0 against 69.0 — 245 and 319 ms of one and two 33³ bakes
// the machine had already started. That is the third of a second of nothing between
// letting go of a slider and the picture sharpening.
//
// The counters could not see it either. `drainPending` never touched `stats`, so the
// HUD line added to make a defeated cache visible on a live machine was structurally
// blind to every background bake.

extension PlanTableCacheTests {

    /// A build that announces itself and then takes its time, so the test can put a
    /// settle inside the window where the bake is genuinely in flight.
    private func slowBuild(_ mark: Double, started: DispatchSemaphore,
                           counter: BuildCounter,
                           seconds: Double = 0.25) -> LUT3D {
        counter.bump()
        started.signal()
        Thread.sleep(forTimeInterval: seconds)
        return LUT3D(size: 5) { rgb in RGB(mark, rgb.g, rgb.b) }
    }

    private func freshCache() {
        PlanTableCache.clear()
        waitForBakes()
        PlanTableCache.clear()
    }

    /// Warm the slot so the next miss has something to be stale from — otherwise the
    /// draft path bakes synchronously and there is no background bake to join.
    private func warmSlot() {
        _ = PlanTableCache.table(.finish, key: "warm", size: 5) {
            LUT3D(size: 5) { rgb in RGB(0, rgb.g, rgb.b) }
        }
    }

    // MARK: The defect

    /// THE ONE THAT COSTS THE THIRD OF A SECOND. The settle asks for the key the drag
    /// just queued, while that bake is running, and must wait for it rather than start
    /// its own copy of it.
    func testASettleJoinsTheDragsBackgroundBakeInsteadOfRepeatingIt() {
        freshCache()
        warmSlot()
        PlanTableCache.resetStats()

        let started = DispatchSemaphore(value: 0)
        let counter = BuildCounter()

        // The drag's last event: serves stale, posts "final" to the bake queue.
        _ = PlanTableCache.tableAllowingStale(.finish, key: "final", size: 5) {
            self.slowBuild(2, started: started, counter: counter)
        }
        // Do not race the queue: wait until that bake has actually begun.
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success,
                       "the background bake never started, so this proves nothing")

        // The settle, on the same key, mid-bake.
        _ = PlanTableCache.table(.finish, key: "final", size: 5) {
            counter.bump()
            return LUT3D(size: 5) { rgb in RGB(9, rgb.g, rgb.b) }
        }
        waitForBakes()

        XCTAssertEqual(counter.count, 1,
                       "the settle baked its own copy of a table that was already "
                       + "baking — 245 ms on Saturation, 319 ms on Whites, for a table "
                       + "the machine was seconds from having")
        XCTAssertEqual(PlanTableCache.traffic(.finish).bakes, 0,
                       "no bake belongs on the render path here")
        XCTAssertEqual(PlanTableCache.traffic(.finish).joinedBakes, 1,
                       "and the join must be visible on the HUD, or the next round "
                       + "cannot tell whether it is still happening")
    }

    /// The other half: the bake is QUEUED but not started, so there is nothing to wait
    /// for. The settle must take it off the queue, or the drain pops the same key
    /// afterwards and bakes it a second time on top of the settle's own.
    func testASettleTakesAQueuedBakeSoTheDrainCannotRepeatIt() {
        freshCache()
        warmSlot()
        PlanTableCache.resetStats()

        let firstStarted = DispatchSemaphore(value: 0)
        let busy = BuildCounter()
        // Occupy the drain with a different key, so the next request only ever queues.
        _ = PlanTableCache.tableAllowingStale(.finish, key: "mid-drag", size: 5) {
            self.slowBuild(3, started: firstStarted, counter: busy)
        }
        XCTAssertEqual(firstStarted.wait(timeout: .now() + 5), .success)

        let target = BuildCounter()
        // The drag's LAST event lands while the drain is busy: queued, not started.
        _ = PlanTableCache.tableAllowingStale(.finish, key: "final", size: 5) {
            target.bump()
            return LUT3D(size: 5) { rgb in RGB(4, rgb.g, rgb.b) }
        }
        // The settle for that same last value.
        _ = PlanTableCache.table(.finish, key: "final", size: 5) {
            target.bump()
            return LUT3D(size: 5) { rgb in RGB(4, rgb.g, rgb.b) }
        }
        waitForBakes()

        XCTAssertEqual(target.count, 1,
                       "the final table was baked twice: once by the settle and once "
                       + "again by the drain, which still held the queued request")
    }

    /// Background bakes are real CPU competing with the render thread, and until they
    /// were counted the HUD read `48b` for a drag performing up to 96 more.
    func testADeferredBakeIsCounted() {
        freshCache()
        warmSlot()
        PlanTableCache.resetStats()

        _ = PlanTableCache.tableAllowingStale(.finish, key: "deferred", size: 5) {
            LUT3D(size: 5) { rgb in RGB(5, rgb.g, rgb.b) }
        }
        waitForBakes()

        XCTAssertEqual(PlanTableCache.currentStats.deferredBakes, 1,
                       "the bake the stale serve queued happened, and the counter "
                       + "that exists to make a defeated cache visible did not see it")
        XCTAssertEqual(PlanTableCache.currentStats.staleServes, 1)
    }

    // MARK: What must NOT change

    /// The join must not turn into "wait for anything". A settle for a DIFFERENT key
    /// than the one baking has nothing to join and must bake immediately — waiting for
    /// an unrelated table would be the same third of a second, spent differently.
    func testASettleForADifferentKeyDoesNotWaitForTheBakeInFlight() {
        freshCache()
        warmSlot()
        PlanTableCache.resetStats()

        let started = DispatchSemaphore(value: 0)
        let other = BuildCounter()
        _ = PlanTableCache.tableAllowingStale(.finish, key: "in-flight", size: 5) {
            self.slowBuild(6, started: started, counter: other, seconds: 0.6)
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)

        let clock = Date()
        _ = PlanTableCache.table(.finish, key: "unrelated", size: 5) {
            LUT3D(size: 5) { rgb in RGB(7, rgb.g, rgb.b) }
        }
        let elapsed = Date().timeIntervalSince(clock)
        XCTAssertLessThan(elapsed, 0.3,
                          "a settle waited \(elapsed)s on a bake for a key it will "
                          + "never ask for")
        waitForBakes()
    }

    /// And the table a joining settle receives is the RIGHT one — the exact table for
    /// its key, not the stale one the drag frame was served.
    func testTheJoinedSettleReceivesTheExactTableAndNotTheStaleOne() {
        freshCache()
        warmSlot()

        let started = DispatchSemaphore(value: 0)
        let counter = BuildCounter()
        let draft = PlanTableCache.tableAllowingStale(.finish, key: "exact", size: 5) {
            self.slowBuild(2, started: started, counter: counter)
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)

        let settle = PlanTableCache.table(.finish, key: "exact", size: 5) {
            XCTFail("the settle should have joined the bake in flight")
            return LUT3D(size: 5) { $0 }
        }
        waitForBakes()

        // `data` is size³ × 4 interleaved floats, so element 0 is the first sample's
        // red — which is where `markedLUT` writes its mark.
        XCTAssertEqual(draft.data.first, 0,
                       "the draft frame is served the warm table — one event stale")
        XCTAssertEqual(settle.data.first, 2,
                       "the settle must land on the exact table it waited for; serving "
                       + "it the stale one would rest a wrong picture at rest")
    }
}

/// A build counter that is safe to bump from `bakeQueue` and read from the test.
final class BuildCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
