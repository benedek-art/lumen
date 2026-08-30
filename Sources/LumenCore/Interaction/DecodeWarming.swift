// DecodeWarming.swift
// Which photograph to decode BEFORE it is asked for, and — the harder half — when it is
// safe to.
//
// The owner's measurements, on a 33 MP ARW: a decode from his offload drive costs about
// 2.4 seconds and the same file from the internal SSD costs about 0.4. The difference is
// the bus, not the machine, and no amount of rendering work will change it. What CAN
// change is when the wait happens: a photograph decoded while he is still editing the
// previous one is a photograph that opens instantly.
//
// THE RULE THAT MATTERS IS NOT WHICH, IT IS WHEN. `RenderCoordinator` is a serial actor
// with no cancellation points inside a decode. A warm that is in flight when the
// photographer moves does not yield — his next photograph queues behind up to a full
// decode of one he did not ask for. Warming naively makes paging WORSE by exactly the
// amount it makes editing better, and the two are not the same activity:
//
//   · CULLING is fast paging. Every arrow key supersedes the last, the settle never
//     lands, and the embedded preview is what is actually being looked at. A warm here
//     is pure contention.
//   · EDITING is dwelling. The settle lands, the hand goes to a slider, and the next
//     photograph is seconds away. A warm here is free — the actor is idle and the
//     wait is spent before it is felt.
//
// So the gate is the SETTLE: warming is offered only once the current photograph has
// been fully rendered, which is a fact about the photographer's behaviour that no timer
// has to guess at. Page fast and no settle lands, so nothing is warmed and nothing is
// blocked; stop to work and the next frame is already decoded.

import Foundation

public enum DecodeWarming {

    /// How many photographs ahead to warm. One, deliberately.
    ///
    /// Two would double the memory held for frames nobody has asked for, and on the
    /// drive that makes this worth doing at all it would also double the window in
    /// which a page lands behind a warm. The second neighbour is worth revisiting only
    /// once a warm can be abandoned mid-decode, which today it cannot.
    public static let span: Int = 1

    /// The indices to warm, given where the cursor is and which way it last moved.
    ///
    /// Forward-biased because that is how a shoot is worked through and how
    /// auto-advance moves. Backward travel warms backward for the same reason: the
    /// photographer who just pressed left is going left again.
    ///
    /// Returns nothing when the cursor is at the end it is travelling toward — there is
    /// no next photograph to warm, and asking for one would warm the wrong one.
    public static func indices(cursor: Int, count: Int, movingForward: Bool,
                               span: Int = DecodeWarming.span) -> [Int] {
        guard count > 0, cursor >= 0, cursor < count, span > 0 else { return [] }
        let step = movingForward ? 1 : -1
        var out: [Int] = []
        var i = cursor
        while out.count < span {
            i += step
            guard i >= 0, i < count else { break }
            out.append(i)
        }
        return out
    }

    /// Whether a warm may be started at all.
    ///
    /// `currentIsSettled` is the whole rule — see this file's header. The other two are
    /// the cases where a warm is not merely unhelpful but wrong: nothing is worth
    /// warming for a viewer that is not showing a photograph, and a gesture in flight
    /// means the render lane belongs to the hand.
    public static func mayWarm(currentIsSettled: Bool,
                               viewerHasPhoto: Bool,
                               gestureInFlight: Bool) -> Bool {
        currentIsSettled && viewerHasPhoto && !gestureInFlight
    }
}
