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

/// `LatestWinsPump` for drafts, with the render started off the main actor: when a
/// render finishes, the newest waiting request starts at once and the finished frame
/// lands on the main actor beside it, so a busy main thread delays the picture but
/// not the next render.
final class RenderAheadPump<Value: Equatable, Output>: @unchecked Sendable {

    /// The render itself; runs on no particular actor.
    typealias Render = () async -> Output
    /// Puts a finished render on screen. Returns whether it landed. `successorWaiting`
    /// is whether a newer request was queued when the render finished.
    typealias Land = @MainActor (_ output: Output, _ successorWaiting: Bool) -> Bool

    private let lock = NSLock()
    private var machine = FramePump<Value>()
    private var queued: [UInt64: (render: Render, land: Land)] = [:]
    private var waiters: [UInt64: [CheckedContinuation<Bool, Never>]] = [:]

    /// As `LatestWinsPump.submit`: returns once this request's frame has landed or
    /// been refused (true if it landed), or once a newer request replaced it.
    @MainActor
    func submit(_ value: Value, render: @escaping Render, land: @escaping Land) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            lock.lock()
            let admission = machine.submit(value)
            var dropped: [CheckedContinuation<Bool, Never>] = []
            if let superseded = admission.superseded {
                queued[superseded] = nil
                dropped = waiters.removeValue(forKey: superseded) ?? []
            }
            waiters[admission.ticket, default: []].append(continuation)
            switch admission.turn {
            case .starts: break
            case .waits: queued[admission.ticket] = (render, land)
            case .joins: break
            }
            lock.unlock()
            for waiter in dropped { waiter.resume(returning: false) }
            if admission.turn == .starts { start(admission.ticket, render, land) }
        }
    }

    private func start(_ first: UInt64, _ firstRender: @escaping Render,
                       _ firstLand: @escaping Land) {
        Task.detached(priority: .userInitiated) { [self] in
            var ticket = first
            var job = (render: firstRender, land: firstLand)
            while true {
                let output = await job.render()
                lock.lock()
                let successorWaiting = machine.hasPending
                var next = machine.finish()
                var skipped: [CheckedContinuation<Bool, Never>] = []
                while let candidate = next, queued[candidate] == nil {
                    skipped += waiters.removeValue(forKey: candidate) ?? []
                    next = machine.finish()
                }
                let following = next.flatMap { ticket in
                    queued.removeValue(forKey: ticket).map { (ticket, $0) }
                }
                lock.unlock()
                for waiter in skipped { waiter.resume(returning: false) }
                let finished = ticket
                let land = job.land
                Task { @MainActor [self] in
                    let landed = land(output, successorWaiting)
                    self.release(finished, landed: landed)
                }
                guard let following else { return }
                ticket = following.0
                job = following.1
            }
        }
    }

    private func release(_ ticket: UInt64, landed: Bool) {
        lock.lock()
        let done = waiters.removeValue(forKey: ticket) ?? []
        lock.unlock()
        for waiter in done { waiter.resume(returning: landed) }
    }
}

#endif
