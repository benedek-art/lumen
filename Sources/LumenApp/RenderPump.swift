// RenderPump.swift
// Runs one surface's interactive renders through `FramePump` (LumenCore): one in
// flight, the newest waiting. The work runs on the pump's own task, so the view task
// that asked for it being cancelled — which every drag event does — cannot stop a
// render from starting or its frame from landing.

#if os(macOS)

import Foundation
import LumenCore

final class LatestWinsPump<Value: Equatable> {

    /// One request's whole job: render, then land the frame. Returns whether a frame
    /// landed. `successorWaiting` answers, when asked, whether a newer request is
    /// queued behind this one.
    typealias Work = @MainActor (_ successorWaiting: @MainActor () -> Bool) async -> Bool

    private var machine = FramePump<Value>()
    private var queued: [UInt64: Work] = [:]
    private var waiters: [UInt64: [CheckedContinuation<Bool, Never>]] = [:]

    /// Ask for `value`. Returns once its work has run (true if its frame landed) or
    /// once a newer request has replaced it before it started (false). A request for
    /// the value already in flight or waiting shares that one's work and outcome.
    @MainActor
    func submit(_ value: Value, work: @escaping Work) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let admission = machine.submit(value)
            if let dropped = admission.superseded {
                queued[dropped] = nil
                release(dropped, landed: false)
            }
            waiters[admission.ticket, default: []].append(continuation)
            switch admission.turn {
            case .starts: run(admission.ticket, work)
            case .waits: queued[admission.ticket] = work
            case .joins: break
            }
        }
    }

    /// Never cancelled, and deliberately not a child of the caller: the caller's
    /// cancellation must not reach the render.
    @MainActor
    private func run(_ first: UInt64, _ firstWork: @escaping Work) {
        Task { @MainActor in
            var ticket = first
            var work = firstWork
            while true {
                let landed = await work({ self.machine.hasPending })
                var next = self.machine.finish()
                self.release(ticket, landed: landed)
                // A ticket with no work cannot happen; if it did, skip it rather than
                // leave the pump believing something is in flight.
                while let candidate = next, self.queued[candidate] == nil {
                    self.release(candidate, landed: false)
                    next = self.machine.finish()
                }
                guard let following = next,
                      let followingWork = self.queued.removeValue(forKey: following)
                else { return }
                ticket = following
                work = followingWork
            }
        }
    }

    @MainActor
    private func release(_ ticket: UInt64, landed: Bool) {
        for waiter in waiters.removeValue(forKey: ticket) ?? [] {
            waiter.resume(returning: landed)
        }
    }
}

#endif
