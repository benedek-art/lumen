// FrameDeliveryTests.swift
// The drag-storm arithmetic from FrameDelivery's header, held as a simulation.
//
// The model is the app's actual shape, reduced to times: events arrive every
// `eventInterval` ms and each one cancels the running task and enqueues a fresh
// request; the pipeline is serial and a render costs `renderCost` ms; when a render
// finishes, the newest queued request that passes `shouldStart` begins. The old
// delivery rule (a completed frame is dropped if its task was cancelled) and the new
// one (`FrameDelivery.shouldShow`) are both run over the same storm, because the
// point is not that the new rule delivers frames — it is that the old one delivers
// NONE, which is what "changes in one frame instead of a slope" was.

import Foundation
import XCTest
@testable import LumenCore

final class FrameDeliveryTests: XCTestCase {

    /// One simulated drag storm: events every 8 ms for a second against 30 ms
    /// renders. Returns frames delivered under each rule.
    private func stormOutcome(eventInterval: Double, renderCost: Double,
                              duration: Double) -> (oldRule: Int, newRule: Int) {
        let url = URL(fileURLWithPath: "/storm/photo.raw")
        var generation: UInt64 = 0
        var newestRequested: UInt64 = 0

        // The queue holds at most the newest waiting request; older ones fail
        // `shouldStart` when their turn comes, which is the backlog collapse.
        var waiting: (generation: UInt64, born: Double)? = nil
        var running: (generation: UInt64, born: Double, done: Double)? = nil

        var oldDelivered = 0
        var newDelivered = 0
        var newestShown: UInt64 = 0

        var nextEvent = 0.0
        var now = 0.0
        while now < duration {
            // The next thing that happens is either an event or a completion.
            let completion = running?.done ?? .infinity
            now = Swift.min(nextEvent, completion)
            guard now < duration else { break }

            if now == completion, let finished = running {
                running = nil
                // The task that owns this render was cancelled iff any newer event
                // arrived while it ran — which under a storm is every single time.
                let cancelled = finished.generation < newestRequested
                if !cancelled { oldDelivered += 1 }
                if FrameDelivery.shouldShow(frameFor: url, currentRequest: url,
                                            generation: finished.generation,
                                            newestShown: newestShown) {
                    newDelivered += 1
                    newestShown = finished.generation
                }
            }

            if now == nextEvent {
                nextEvent += eventInterval
                generation &+= 1
                newestRequested = generation
                waiting = (generation, now)
            }

            // Serial pipeline: when idle, the newest waiter that may start, starts.
            if running == nil, let candidate = waiting {
                waiting = nil
                let cancelled = candidate.generation < newestRequested
                if FrameDelivery.shouldStart(taskCancelled: cancelled,
                                             generation: candidate.generation,
                                             newestRequested: newestRequested) {
                    running = (candidate.generation, candidate.born, now + renderCost)
                }
            }
        }
        return (oldDelivered, newDelivered)
    }

    func testDragStormDeliversAtRenderCadenceNotHandPauses() {
        let outcome = stormOutcome(eventInterval: 8, renderCost: 30, duration: 1000)

        // The defect, as arithmetic: while events outpace renders, the old rule
        // delivers NOTHING — every frame's task was cancelled mid-render. This is
        // the owner's "notches": the screen moved only at pauses in the hand.
        XCTAssertEqual(outcome.oldRule, 0,
                       "the cancelled-task rule should deliver zero frames under a storm — "
                       + "if it delivers any, this simulation no longer models the defect")

        // The law: one render always in flight, every completion shown. A second of
        // storm at 30 ms/render is ~33 completions; allow scheduling slack but
        // require render-cadence, not pause-cadence.
        XCTAssertGreaterThanOrEqual(outcome.newRule, 30,
                                    "completed frames must reach the screen at the machine's "
                                    + "render cadence (~33/s here), got \(outcome.newRule)")
    }

    func testSlowMachineStillDeliversEveryCompletion() {
        // 120 ms renders — a struggling machine. The screen should still move ~8
        // times a second rather than freezing entirely.
        let outcome = stormOutcome(eventInterval: 8, renderCost: 120, duration: 1000)
        XCTAssertEqual(outcome.oldRule, 0)
        XCTAssertGreaterThanOrEqual(outcome.newRule, 7)
    }

    func testOrderAndIdentityGuards() {
        let a = URL(fileURLWithPath: "/a.raw")
        let b = URL(fileURLWithPath: "/b.raw")

        // A frame for the photo the viewer has moved away from must never show.
        XCTAssertFalse(FrameDelivery.shouldShow(frameFor: a, currentRequest: b,
                                                generation: 9, newestShown: 1))
        // Before any request exists there is nothing a frame could match.
        XCTAssertFalse(FrameDelivery.shouldShow(frameFor: a, currentRequest: nil,
                                                generation: 9, newestShown: 1))
        // A slow old render must not overwrite a newer frame already applied.
        XCTAssertFalse(FrameDelivery.shouldShow(frameFor: a, currentRequest: a,
                                                generation: 5, newestShown: 5))
        XCTAssertFalse(FrameDelivery.shouldShow(frameFor: a, currentRequest: a,
                                                generation: 4, newestShown: 5))
        // The plain case: right photo, newer frame.
        XCTAssertTrue(FrameDelivery.shouldShow(frameFor: a, currentRequest: a,
                                               generation: 6, newestShown: 5))

        // Starting is where staleness lives: cancelled or superseded never starts.
        XCTAssertFalse(FrameDelivery.shouldStart(taskCancelled: true,
                                                 generation: 7, newestRequested: 7))
        XCTAssertFalse(FrameDelivery.shouldStart(taskCancelled: false,
                                                 generation: 6, newestRequested: 7))
        XCTAssertTrue(FrameDelivery.shouldStart(taskCancelled: false,
                                                generation: 7, newestRequested: 7))
    }
}
