// FramePumpTests.swift
// The viewer's scheduling policy, costed without a GPU: for input at 60 and 120 Hz and
// renders from 4 to 120 ms, frames keep landing through the drag at one per render,
// the last value always renders, a landed frame is never older than one render plus
// one event (two renders for the final value), and no value renders twice.

import Foundation
import XCTest
@testable import LumenCore

final class FramePumpTests: XCTestCase {

    // MARK: The state machine

    func testAnIdleLaneStartsAtOnce() {
        var pump = FramePump<Int>()
        XCTAssertTrue(pump.isIdle)
        let first = pump.submit(1)
        XCTAssertEqual(first.turn, .starts)
        XCTAssertNil(first.superseded)
        XCTAssertEqual(pump.inFlightTicket, first.ticket)
        XCTAssertFalse(pump.hasPending)
    }

    func testOneRendersOneWaitsAndTheNewestWaitingWins() {
        var pump = FramePump<Int>()
        let a = pump.submit(1)
        let b = pump.submit(2)
        XCTAssertEqual(b.turn, .waits)
        XCTAssertNil(b.superseded)
        let c = pump.submit(3)
        XCTAssertEqual(c.turn, .waits)
        XCTAssertEqual(c.superseded, b.ticket, "the displaced request is named so its waiters can be released")
        XCTAssertEqual(pump.inFlightTicket, a.ticket, "input never disturbs the render in flight")

        XCTAssertEqual(pump.finish(), c.ticket)
        XCTAssertEqual(pump.inFlightTicket, c.ticket)
        XCTAssertFalse(pump.hasPending)
        XCTAssertNil(pump.finish())
        XCTAssertTrue(pump.isIdle)
    }

    func testTheValueInFlightIsJoinedAndWhatWaitedBehindItIsDropped() {
        var pump = FramePump<Int>()
        let a = pump.submit(1)
        let b = pump.submit(2)
        let again = pump.submit(1)
        XCTAssertEqual(again.turn, .joins)
        XCTAssertEqual(again.ticket, a.ticket)
        XCTAssertEqual(again.superseded, b.ticket)
        XCTAssertNil(pump.finish(), "1 is the newest value and it has just rendered")
    }

    func testTheWaitingValueIsJoined() {
        var pump = FramePump<Int>()
        _ = pump.submit(1)
        let b = pump.submit(2)
        let again = pump.submit(2)
        XCTAssertEqual(again.turn, .joins)
        XCTAssertEqual(again.ticket, b.ticket)
        XCTAssertNil(again.superseded)
        XCTAssertEqual(pump.finish(), b.ticket)
    }

    func testFinishingAnIdleLaneIsHarmless() {
        var pump = FramePump<Int>()
        XCTAssertNil(pump.finish())
        XCTAssertEqual(pump.submit(1).turn, .starts)
    }

    // MARK: A drag, over virtual time

    private static let rates: [Double] = [60, 120]
    private static let costs: [Double] = [4, 8, 12, 16, 24, 33, 50, 80, 120]
    private static let dragMilliseconds: Double = 2000

    private func drag(hertz: Double) -> [(at: Double, value: Int)] {
        let interval = 1000 / hertz
        let count = Int(Self.dragMilliseconds / interval)
        return (0..<count).map { (at: Double($0) * interval, value: $0) }
    }

    func testFramesLandThroughTheDragAtOnePerRender() {
        for hertz in Self.rates {
            let events = drag(hertz: hertz)
            let interval = 1000 / hertz
            let lastInput = events[events.count - 1].at
            for cost in Self.costs {
                let frames = FramePumpSimulation.run(events: events) { _, _ in cost }
                let during = frames.filter { $0.landedAt <= lastInput }
                // The cadence is the slower of the renderer and the hand.
                let period = Swift.max(cost, interval)
                let label = "\(hertz) Hz, \(cost) ms"
                XCTAssertGreaterThanOrEqual(during.count, Int(lastInput / period) - 1, label)
                XCTAssertEqual(frames.first?.landedAt ?? -1, cost, accuracy: 1e-6, label)
                for (previous, frame) in zip(during, during.dropFirst()) {
                    XCTAssertLessThanOrEqual(frame.landedAt - previous.landedAt,
                                             period + 1e-6, label)
                }
            }
        }
    }

    func testTheLastValueAlwaysRenders() {
        for hertz in Self.rates {
            let events = drag(hertz: hertz)
            for cost in Self.costs {
                let frames = FramePumpSimulation.run(events: events) { _, _ in cost }
                XCTAssertEqual(frames.last?.value, events.last?.value, "\(hertz) Hz, \(cost) ms")
                // And promptly: at worst behind the one render that was in flight.
                let settledBy = (events.last?.at ?? 0) + 2 * cost
                XCTAssertLessThanOrEqual(frames.last?.landedAt ?? .infinity, settledBy + 1e-6)
            }
        }
    }

    /// While input keeps arriving, the value that waits is the newest one, so a landed
    /// frame is at most one render plus one event old. The final value has nothing
    /// newer to replace it and can wait out a whole render first: two renders.
    func testALandedFrameIsNeverOlderThanOneRenderPlusOneEvent() {
        for hertz in Self.rates {
            let events = drag(hertz: hertz)
            let interval = 1000 / hertz
            let final = events[events.count - 1].value
            for cost in Self.costs {
                let frames = FramePumpSimulation.run(events: events) { _, _ in cost }
                for frame in frames {
                    let bound = frame.value == final ? 2 * cost : cost + interval
                    XCTAssertLessThanOrEqual(frame.landedAt - frame.requestedAt,
                                             bound + 1e-6,
                                             "\(hertz) Hz, \(cost) ms, value \(frame.value)")
                }
            }
        }
    }

    func testNoValueRendersTwiceAndNoneOutOfOrder() {
        for hertz in Self.rates {
            let events = drag(hertz: hertz)
            for cost in Self.costs {
                let values = FramePumpSimulation.run(events: events) { _, _ in cost }
                    .map(\.value)
                XCTAssertEqual(Set(values).count, values.count, "\(hertz) Hz, \(cost) ms")
                XCTAssertEqual(values, values.sorted(), "\(hertz) Hz, \(cost) ms")
            }
        }
    }

    /// A release re-asks for the value the last motion event already asked for.
    func testTheReleaseDoesNotRenderTheLastValueAgain() {
        var events = drag(hertz: 120)
        let last = events[events.count - 1]
        events.append((at: last.at + 1, value: last.value))
        for cost in Self.costs {
            let values = FramePumpSimulation.run(events: events) { _, _ in cost }.map(\.value)
            XCTAssertEqual(values.filter { $0 == last.value }.count, 1, "\(cost) ms")
        }
    }

    /// Costs that change from frame to frame, 4–120 ms, as a real graph's do.
    func testAnUnevenRendererStillNeverStarves() {
        func cost(_ value: Int) -> Double { 4 + Double((value &* 7919) % 117) }
        for hertz in Self.rates {
            let events = drag(hertz: hertz)
            let interval = 1000 / hertz
            let lastInput = events[events.count - 1].at
            let frames = FramePumpSimulation.run(events: events) { value, _ in cost(value) }
            XCTAssertEqual(frames.last?.value, events.last?.value)
            XCTAssertEqual(Set(frames.map(\.value)).count, frames.count)
            let during = frames.filter { $0.landedAt <= lastInput }
            XCTAssertGreaterThan(during.count, Int(lastInput / 120) - 2)
            // A cheap frame can leave the lane idle until the next event arrives.
            for (previous, frame) in zip(during, during.dropFirst()) {
                XCTAssertLessThanOrEqual(frame.landedAt - previous.landedAt,
                                         120 + interval + 1e-6)
            }
        }
    }

    /// The hop back to the pump's owner adds to the period and to nothing else.
    func testTheHandoffIsPaidOncePerFrame() {
        let events = drag(hertz: 120)
        let frames = FramePumpSimulation.run(events: events, handoff: 6) { _, _ in 30 }
        let lastInput = events[events.count - 1].at
        let during = frames.filter { $0.landedAt <= lastInput }
        for (previous, frame) in zip(during, during.dropFirst()) {
            XCTAssertEqual(frame.landedAt - previous.landedAt, 36, accuracy: 1e-6)
        }
        XCTAssertEqual(frames.last?.value, events.last?.value)
    }

    // MARK: The rule this replaces, as a model

    /// The scheme the viewer ran before: every event cancels its predecessor's request,
    /// and the lane drops a request that is already cancelled when its turn comes. A
    /// request is therefore renderable only between reaching the lane (`arrival` after
    /// its event) and its successor's event being seen (`cancel` after that event).
    /// This is a model with stated latencies, not a measurement: it shows what the
    /// rule does once a request takes an event interval longer to arrive than to be
    /// cancelled — nothing renders until input stops, whatever a render costs.
    private func framesUnderCancelOnSupersede(events: [(at: Double, value: Int)],
                                              arrival: Double, cancel: Double,
                                              cost: Double) -> [(value: Int, landedAt: Double)] {
        var landed: [(value: Int, landedAt: Double)] = []
        var laneFreeAt = 0.0
        for (index, event) in events.enumerated() {
            let arrives = event.at + arrival
            let cancelledAt = index + 1 < events.count
                ? events[index + 1].at + cancel : Double.infinity
            // The lane reaches this request when it is both free and the request is there.
            let reachedAt = Swift.max(arrives, laneFreeAt)
            guard reachedAt < cancelledAt else { continue }
            laneFreeAt = reachedAt + cost
            landed.append((event.value, laneFreeAt))
        }
        return landed
    }

    func testCancellationAsTheSupersedeSignalStarvesOnceRequestsArriveLate() {
        let events = drag(hertz: 120)
        let interval = 1000.0 / 120
        let lastInput = events[events.count - 1].at
        for cost in [4.0, 30, 120] {
            // Requests arrive promptly: the old rule keeps up.
            let prompt = framesUnderCancelOnSupersede(events: events, arrival: 2,
                                                      cancel: 1, cost: cost)
            XCTAssertGreaterThan(prompt.filter { $0.landedAt <= lastInput }.count, 10)
            // One event interval of main-thread work between cancel and arrival: zero
            // frames for the whole drag, then the final value after it.
            let late = framesUnderCancelOnSupersede(events: events, arrival: interval + 2,
                                                    cancel: 1, cost: cost)
            XCTAssertEqual(late.filter { $0.landedAt <= lastInput }.count, 0, "\(cost) ms")
            XCTAssertEqual(late.count, 1)
            XCTAssertEqual(late.last?.value, events.last?.value)
            // The pump, handed the same late requests, lands a frame per render.
            let delayed = events.map { (at: $0.at + interval + 2, value: $0.value) }
            let pumped = FramePumpSimulation.run(events: delayed) { _, _ in cost }
            XCTAssertGreaterThanOrEqual(
                pumped.filter { $0.landedAt <= lastInput }.count,
                Int((lastInput - interval - 2) / Swift.max(cost, interval)) - 1, "\(cost) ms")
        }
    }
}
