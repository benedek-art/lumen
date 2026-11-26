// InteractionTimelineTests.swift
// The summary the automation driver reads: frames during input, the longest wait for
// one, and whether the last value reached the screen.

import Foundation
import XCTest
@testable import LumenCore

final class InteractionTimelineTests: XCTestCase {

    private func ms(_ value: Double) -> UInt64 { UInt64(value * 1_000_000) }

    private func input(_ at: Double, _ revision: Int) -> InteractionTimeline.Stamp {
        .init(kind: .input, nanoseconds: ms(at), revision: revision)
    }

    private func frame(_ at: Double, _ revision: Int,
                       draft: Bool = true) -> InteractionTimeline.Stamp {
        .init(kind: .frame, nanoseconds: ms(at), revision: revision, draft: draft,
              longEdge: 2560, renderMilliseconds: 30)
    }

    func testAHealthyDragReportsItsCadenceAndItsLatency() {
        var timeline = InteractionTimeline()
        // Input every 10 ms for a second; a frame every 30 ms, each 30 ms behind.
        for step in 0...100 { timeline.record(input(1000 + Double(step) * 10, step + 1)) }
        for landing in stride(from: 1030.0, through: 2030.0, by: 30) {
            let revision = Int((landing - 30 - 1000) / 10) + 1
            timeline.record(frame(landing, Swift.min(revision, 101)))
        }
        timeline.record(frame(2060, 101))
        timeline.record(frame(2300, 101, draft: false))

        let summary = timeline.summary()
        XCTAssertEqual(summary.inputs, 101)
        XCTAssertEqual(summary.inputSpanMilliseconds, 1000, accuracy: 1e-6)
        XCTAssertEqual(summary.framesDuringInput, 33)
        XCTAssertEqual(summary.maxFrameGapMilliseconds ?? -1, 30, accuracy: 1e-6)
        XCTAssertEqual(summary.maxInputToFrameMilliseconds ?? -1, 60, accuracy: 1e-6,
                       "the settle of a revision already shown is not input latency")
        XCTAssertEqual(summary.lastInputToFrameMilliseconds ?? -1, 60, accuracy: 1e-6)
        XCTAssertTrue(summary.lastInputWasRendered)
    }

    /// The owner's report as a timeline: nothing until the hand stops.
    func testAStarvedDragIsOneGapTheLengthOfTheDrag() {
        var timeline = InteractionTimeline()
        for step in 0...100 { timeline.record(input(Double(step) * 10, step + 1)) }
        timeline.record(frame(1040, 101))
        let summary = timeline.summary()
        XCTAssertEqual(summary.framesDuringInput, 0)
        XCTAssertEqual(summary.maxFrameGapMilliseconds ?? -1, 1040, accuracy: 1e-6)
        XCTAssertTrue(summary.lastInputWasRendered)
    }

    /// Where a frame's time went: inside the renderer, or getting there and back; and
    /// how long the main thread took to ask at all.
    func testTheSummarySeparatesTheRendererFromTheThreadThatAsked() {
        var timeline = InteractionTimeline()
        for step in 0..<5 {
            let at = Double(step) * 40
            timeline.record(input(at, step + 1))
            timeline.record(.init(kind: .request, nanoseconds: ms(at + Double(step + 1)),
                                  revision: step + 1))
            timeline.record(.init(kind: .start, nanoseconds: ms(at + 6), revision: step + 1))
            timeline.record(.init(kind: .frame, nanoseconds: ms(at + 36), revision: step + 1,
                                  draft: true, longEdge: 2560,
                                  renderMilliseconds: 30, laneMilliseconds: 20 + Double(step)))
        }
        timeline.record(.init(kind: .frame, nanoseconds: ms(400), revision: 5, draft: false,
                              longEdge: 2560, renderMilliseconds: 90, laneMilliseconds: 88))
        let summary = timeline.summary()
        XCTAssertEqual(summary.medianInputToRequestMilliseconds ?? -1, 3, accuracy: 1e-6)
        XCTAssertEqual(summary.maxInputToRequestMilliseconds ?? -1, 5, accuracy: 1e-6)
        XCTAssertEqual(summary.medianDraftRenderMilliseconds ?? -1, 30, accuracy: 1e-6)
        XCTAssertEqual(summary.medianDraftLaneMilliseconds ?? -1, 22, accuracy: 1e-6,
                       "the settle's 88 ms is not a draft")
    }

    /// An overlay is measured the way frames are, each under its own name.
    func testAnOverlayThatWaitsForTheHandToStopIsOneLongGap() {
        var timeline = InteractionTimeline()
        for step in 0...50 { timeline.record(input(Double(step) * 10, step + 1)) }
        for landing in stride(from: 30.0, through: 510.0, by: 30) {
            timeline.record(frame(landing, Int(landing / 10) - 1))
            timeline.record(.init(kind: .overlay, nanoseconds: ms(landing + 4),
                                  revision: Int(landing / 10) - 1, name: "clipping"))
        }
        timeline.record(frame(540, 51))
        timeline.record(.init(kind: .overlay, nanoseconds: ms(700), revision: 51,
                              name: "maskWash"))
        let summary = timeline.summary()
        let clipping = summary.overlays["clipping"]
        XCTAssertEqual(clipping?.updatesDuringInput, 16)
        XCTAssertEqual(clipping?.maxGapMilliseconds ?? -1, 34, accuracy: 1e-6)
        XCTAssertNil(clipping?.lastInputToUpdateMilliseconds,
                     "it never showed the final value")
        let wash = summary.overlays["maskWash"]
        XCTAssertEqual(wash?.updates, 1)
        XCTAssertEqual(wash?.updatesDuringInput, 0)
        XCTAssertEqual(wash?.maxGapMilliseconds ?? -1, 700, accuracy: 1e-6)
        XCTAssertEqual(wash?.lastInputToUpdateMilliseconds ?? -1, 200, accuracy: 1e-6)
        XCTAssertEqual(summary.framesDuringInput, 16, "overlays are not frames")
    }

    /// What one input costs the main thread, whatever happens to its frame.
    func testTheMainThreadTimePerInputIsSummarised() {
        var timeline = InteractionTimeline()
        for (step, cost) in [3.0, 9.0, 4.0, 21.0, 5.0].enumerated() {
            timeline.record(input(Double(step) * 30, step + 1))
            timeline.record(.init(kind: .turn, nanoseconds: ms(Double(step) * 30 + cost),
                                  revision: step + 1, mainMilliseconds: cost))
        }
        let summary = timeline.summary()
        XCTAssertEqual(summary.medianInputTurnMilliseconds ?? -1, 5, accuracy: 1e-6)
        XCTAssertEqual(summary.maxInputTurnMilliseconds ?? -1, 21, accuracy: 1e-6)
        XCTAssertNil(InteractionTimeline().summary().medianInputTurnMilliseconds)
    }

    func testAFinalValueThatNeverRenderedIsReported() {
        var timeline = InteractionTimeline()
        timeline.record(input(0, 1))
        timeline.record(input(10, 2))
        timeline.record(frame(20, 1))
        let summary = timeline.summary()
        XCTAssertFalse(summary.lastInputWasRendered)
        XCTAssertNil(summary.lastInputToFrameMilliseconds)
        XCTAssertNotNil(summary.maxFrameGapMilliseconds)
    }

    func testNoInputAndNoFrameAreNotGaps() {
        XCTAssertEqual(InteractionTimeline().summary(), InteractionTimeline.Summary())
        var timeline = InteractionTimeline()
        timeline.record(input(0, 1))
        let summary = timeline.summary()
        XCTAssertNil(summary.maxFrameGapMilliseconds)
        XCTAssertFalse(summary.lastInputWasRendered)
        XCTAssertTrue(InteractionTimeline.Summary().lastInputWasRendered)
    }

    func testTheBufferIsBoundedAndKeepsTheNewest() {
        var timeline = InteractionTimeline()
        for revision in 0..<(InteractionTimeline.capacity + 10) {
            timeline.record(input(Double(revision), revision))
        }
        XCTAssertEqual(timeline.entries.count, InteractionTimeline.capacity)
        XCTAssertEqual(timeline.entries.last?.revision, InteractionTimeline.capacity + 9)
        timeline.removeAll()
        XCTAssertTrue(timeline.entries.isEmpty)
    }

    func testTheTranscriptRoundTripsAsJSON() throws {
        var timeline = InteractionTimeline()
        timeline.record(input(0, 7))
        timeline.record(frame(12.5, 7, draft: false))
        let data = try JSONEncoder().encode(timeline.transcript())
        let decoded = try JSONDecoder().decode(InteractionTimeline.Transcript.self, from: data)
        XCTAssertEqual(decoded, timeline.transcript())
        XCTAssertEqual(decoded.summary.lastInputToFrameMilliseconds ?? -1, 12.5, accuracy: 1e-6)
    }
}
