// EventRate.swift
// A sliding-window rate counter, so the latency HUD can print the two numbers that
// distinguish the only two explanations for "the slider ticks".
//
// Three rounds of responsiveness work on this project have been argued from latency —
// how long one frame took — and latency cannot tell those two explanations apart. Both
// look identical to a photographer and they want opposite fixes:
//
//   · The RENDER is the bottleneck. Input arrives at 60–120 events per second and
//     frames leave at 8. The hand is being seen and the picture cannot keep up, so the
//     answer is fewer pixels per frame or less work per pixel.
//   · The INPUT is being dropped. The main actor cannot finish its per-event work
//     inside the gap between two mouse-moved events, AppKit coalesces the ones it has
//     not delivered, and the app never learns where the hand went. Input arrives at 10
//     events per second and frames leave at 10 — a perfectly efficient render loop
//     serving a gesture it can only see a tenth of. No amount of render optimisation
//     touches this one, and the thumb and the number tick along with the picture,
//     because all three are downstream of the events that were never delivered.
//
// Printing input/s beside frames/s makes the next owner session answer that in one
// glance instead of another round of reasoning. It is arithmetic in LumenCore rather
// than expressions in a HUD's body for the usual reason: the app target has no place to
// test it and a rate computed slightly wrong is worse than no rate at all, because it
// will be believed.

import Foundation

/// Events per second over a trailing window.
///
/// Deliberately takes the timestamp rather than reading a clock, so its behaviour is a
/// function of its inputs and a test can drive a whole drag through it in no time.
public struct EventRate: Sendable, Equatable {

    /// How far back the count reaches. One second is long enough that a 60 Hz stream
    /// gives a stable number and short enough that letting go of a slider clears it
    /// within a beat.
    public static let windowSeconds: Double = 1.0

    /// Trailing timestamps inside the window, oldest first.
    private var stamps: [Double] = []

    public init() {}

    /// Note an event at `seconds` on a monotonic clock.
    ///
    /// Out-of-order and non-finite stamps are dropped rather than accepted: a rate
    /// derived from a clock that went backwards is a wrong number wearing a
    /// measurement's clothes, and this one is read to make decisions.
    public mutating func record(at seconds: Double) {
        guard seconds.isFinite else { return }
        if let last = stamps.last, seconds < last { return }
        stamps.append(seconds)
        trim(before: seconds - Self.windowSeconds)
    }

    /// Events per second as of `seconds`, or nil when fewer than two events are inside
    /// the window — one event is a timestamp, not a rate.
    ///
    /// Measured across the events themselves (`(n − 1) ÷ span`) rather than as
    /// `n ÷ window`. A gesture that started 200 ms ago has delivered its events into a
    /// fifth of the window, and dividing by the whole of it would report a fifth of the
    /// true rate for the first second of every drag — exactly when someone is watching.
    public func perSecond(now seconds: Double) -> Double? {
        let live = stamps.filter { $0 >= seconds - Self.windowSeconds }
        guard live.count >= 2, let first = live.first, let last = live.last else {
            return nil
        }
        let span = last - first
        guard span > 0 else { return nil }
        return Double(live.count - 1) / span
    }

    /// Whether anything at all has been seen inside the window — the difference between
    /// "nothing is happening" and "one thing happened".
    public func isIdle(now seconds: Double) -> Bool {
        !stamps.contains { $0 >= seconds - Self.windowSeconds }
    }

    private mutating func trim(before cutoff: Double) {
        guard let index = stamps.firstIndex(where: { $0 >= cutoff }) else {
            stamps.removeAll()
            return
        }
        if index > 0 { stamps.removeFirst(index) }
    }
}
