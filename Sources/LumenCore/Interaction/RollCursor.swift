// RollCursor.swift
// "Where does this photograph sit in the roll?" — asked once per keystroke by every
// surface that draws the roll, and answered until now by walking the roll.
//
// The cost is not theoretical and it is not constant. Culling a 500–2,000 frame folder
// means holding an arrow key down: macOS repeats at roughly 25–30 events a second, and
// each event asked that question from the contact sheet's ring prefetch, from the
// filmstrip's, and from the loupe's — three linear searches over the same unchanged
// array, per keystroke, on the main actor, in front of the frame the photographer is
// waiting for. Measured over 2,000 file URLs, two searches plus the two `map(\.id)`
// projections that fed them cost ~95 µs per keystroke against an 8.3 ms frame budget:
// small, entirely wasted, and LINEAR — the same folder at 20,000 frames pays ten times
// that, which is the point at which a contact sheet starts to feel like it is thinking.
//
// So the answer is memoised here. What makes this worth a type of its own rather than a
// dictionary at each call site is the invalidation, which is the half that is easy to
// get quietly wrong: a stale position map does not crash, it points at the WRONG
// photograph, and every consumer of it — a prefetch window, an auto-advance, a range
// selection — then does something plausible to the wrong frame. A cull session that
// rates the neighbour of what is on screen is the worst outcome this app has.
//
// The rule that makes staleness impossible is that a memoised answer is VERIFIED
// against the roll it is about to be used on, in O(1), before it is returned: the roll
// still has to be the length the map was built from, and the photograph still has to be
// standing at the index the map remembers. Anything else rebuilds. The map is therefore
// never trusted — it is consulted, checked, and used only when the roll itself agrees —
// which is why this needs no change notification, no version stamp, and no cooperation
// from the callers who mutate the roll.
//
// A MISS ALWAYS REBUILDS, and that is the one asymmetry. "This photograph is not in the
// roll" is the single answer that cannot be checked against the roll in constant time,
// so trusting it would mean trusting the map, which is exactly what the paragraph above
// refuses to do. The cost is one full pass while the cursor sits on a photograph the
// roll no longer contains — rejecting a frame under a "Picked" filter is that state,
// and it lasts until the cursor advances off it.

import Foundation

/// A memoised "where is this in the roll?", verified against the roll on every answer.
///
/// Holds no roll of its own on purpose. The roll belongs to whoever owns the library —
/// it is an array of photographs in one place and an array of URLs in another — and a
/// second copy kept here to compare against would be both the memory this is trying to
/// save and a fifth thing that can go stale. The caller passes the roll's length and a
/// way to read the identity at an index, and gets back the same answer
/// `firstIndex(of:)` would have given.
public struct RollCursor: Sendable {

    /// How many times the position map has been built from scratch.
    ///
    /// Exposed because it is the ONLY externally visible difference between this and the
    /// linear search it replaces: both return the same index for the same roll, so a
    /// test that checks only the answers passes just as well against a search that
    /// walks the array every time. Counting the builds is what makes "memoised" a claim
    /// a test can falsify.
    public private(set) var rebuilds: Int = 0

    /// Identity to first index. First, not last: `firstIndex(of:)` is what this
    /// replaces, and a roll that somehow carries the same file twice must answer the
    /// same way it did before.
    private var positions: [URL: Int] = [:]

    /// The roll length `positions` was built from. `-1` is "nothing built yet", which is
    /// distinguishable from an empty roll.
    private var builtCount: Int = -1

    public init() {}

    /// The index of `id` in a roll of `count` entries whose identity at index i is
    /// `idAt(i)`, or nil when the roll does not contain it.
    ///
    /// `idAt` is called at most once on the fast path — for the verification — and
    /// `count` times when the map has to be rebuilt.
    public mutating func index(of id: URL, inRollOf count: Int,
                               idAt: (Int) -> URL) -> Int? {
        guard count > 0 else {
            positions.removeAll(keepingCapacity: true)
            builtCount = count
            return nil
        }
        // The whole of the fast path: the roll is the length we indexed, we remember a
        // position for this photograph, and the photograph is still standing there.
        if builtCount == count, let memo = positions[id], memo < count, idAt(memo) == id {
            return memo
        }
        rebuild(count: count, idAt: idAt)
        return positions[id]
    }

    private mutating func rebuild(count: Int, idAt: (Int) -> URL) {
        positions.removeAll(keepingCapacity: true)
        positions.reserveCapacity(count)
        for i in 0..<count {
            let id = idAt(i)
            if positions[id] == nil { positions[id] = i }
        }
        builtCount = count
        rebuilds += 1
    }
}
