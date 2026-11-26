// FramePump.swift
// Which request renders next on a serial render lane: one in flight, the newest one
// waiting, nothing else. An in-flight render is never abandoned and a waiting one is
// only ever replaced by a newer one, so input arriving faster than frames can be made
// costs intermediate values, never the picture.

import Foundation

/// A latest-wins mailbox in front of a serial renderer.
///
/// Pure state: the caller owns the clock and the work. `submit` says whether the value
/// starts now, waits, or is already covered; `finish` says what starts next. A value
/// is only "covered" while it is in flight or waiting: resubmitted to an idle lane it
/// renders again, because whether the frame on screen still answers it is the
/// caller's to know.
public struct FramePump<Value: Equatable> {

    public enum Turn: Equatable, Sendable {
        /// The lane was idle: render this ticket now.
        case starts
        /// A render is in flight: this ticket runs when it finishes, unless replaced.
        case waits
        /// The same value is already in flight or waiting under this ticket.
        case joins
    }

    public struct Admission: Equatable, Sendable {
        public let ticket: UInt64
        public let turn: Turn
        /// A waiting ticket this submission displaced. It will never render.
        public let superseded: UInt64?
    }

    private struct Held {
        let ticket: UInt64
        let value: Value
    }

    private var minted: UInt64 = 0
    private var inFlight: Held?
    private var pending: Held?

    public init() {}

    public var inFlightTicket: UInt64? { inFlight?.ticket }
    public var pendingTicket: UInt64? { pending?.ticket }
    public var isIdle: Bool { inFlight == nil }
    /// A newer value is waiting behind the render in flight.
    public var hasPending: Bool { pending != nil }

    public mutating func submit(_ value: Value) -> Admission {
        guard let running = inFlight else {
            let slot = mint(value)
            inFlight = slot
            return Admission(ticket: slot.ticket, turn: .starts, superseded: nil)
        }
        if running.value == value {
            // The newest value is the one being rendered, so whatever waited is stale.
            let dropped = pending?.ticket
            pending = nil
            return Admission(ticket: running.ticket, turn: .joins,
                             superseded: dropped)
        }
        if let waiting = pending, waiting.value == value {
            return Admission(ticket: waiting.ticket, turn: .joins, superseded: nil)
        }
        let dropped = pending?.ticket
        let slot = mint(value)
        pending = slot
        return Admission(ticket: slot.ticket, turn: .waits, superseded: dropped)
    }

    /// The render in flight has ended, landed or not. Returns the ticket to start now.
    public mutating func finish() -> UInt64? {
        inFlight = pending
        pending = nil
        return inFlight?.ticket
    }

    private mutating func mint(_ value: Value) -> Held {
        minted &+= 1
        return Held(ticket: minted, value: value)
    }
}

/// `FramePump` driven over virtual time, so the policy the viewer runs can be costed
/// without a GPU and a measured timeline can be compared with what it predicts.
public enum FramePumpSimulation {

    public struct Landing<Value: Equatable>: Equatable {
        public let value: Value
        /// When the value was submitted, when its render began, when it landed (ms).
        public let requestedAt: Double
        public let startedAt: Double
        public let landedAt: Double
    }

    /// - Parameters:
    ///   - events: `(at, value)` in ascending time, milliseconds.
    ///   - handoff: time between a render finishing and the pump being told — the hop
    ///     back to the thread that owns it.
    ///   - cost: render time for a value whose render starts at the given time.
    public static func run<Value: Equatable>(
        events: [(at: Double, value: Value)],
        handoff: Double = 0,
        cost: (Value, Double) -> Double
    ) -> [Landing<Value>] {
        var pump = FramePump<Value>()
        var submitted: [UInt64: (value: Value, at: Double)] = [:]
        var running: (ticket: UInt64, startedAt: Double, doneAt: Double)?
        var frames: [Landing<Value>] = []
        var next = 0

        func begin(_ ticket: UInt64, at now: Double)
        -> (ticket: UInt64, startedAt: Double, doneAt: Double)? {
            guard let request = submitted[ticket] else { return nil }
            let took = Swift.max(0, cost(request.value, now)) + Swift.max(0, handoff)
            return (ticket, now, now + took)
        }

        while next < events.count || running != nil {
            let eventAt = next < events.count ? events[next].at : Double.infinity
            if let current = running, current.doneAt <= eventAt {
                if let request = submitted.removeValue(forKey: current.ticket) {
                    frames.append(Landing(value: request.value, requestedAt: request.at,
                                        startedAt: current.startedAt,
                                        landedAt: current.doneAt))
                }
                running = pump.finish().flatMap { begin($0, at: current.doneAt) }
                continue
            }
            let event = events[next]
            next += 1
            let admission = pump.submit(event.value)
            if let dropped = admission.superseded { submitted[dropped] = nil }
            switch admission.turn {
            case .starts:
                submitted[admission.ticket] = (event.value, event.at)
                running = begin(admission.ticket, at: event.at)
            case .waits:
                submitted[admission.ticket] = (event.value, event.at)
            case .joins:
                break
            }
        }
        return frames
    }
}
