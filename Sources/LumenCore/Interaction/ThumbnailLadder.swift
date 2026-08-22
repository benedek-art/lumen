// ThumbnailLadder.swift
// The browse cache's size ladder and the ring geometry that warms it — the two pieces
// of the prefetch that are arithmetic rather than AppKit, moved here so they can be
// tested on a machine with no window server.
//
// Why they are worth pulling out: the cache is keyed by (url, level), so a prefetcher
// and a requester that disagree about the level are two different caches wearing one
// name. That is not a hypothetical. The loupe's instant path asked for 1600 pixels,
// which resolves to the 2048 level; the only ring prefetch that ran while the loupe
// was on screen ran at the filmstrip's 256. Every arrow press in the loupe therefore
// missed, decoded a 2048-class embedded JPEG cold and then rendered — against a
// headline goal of "next photo in under 50 ms from a pre-decoded cache". Nothing was
// wrong with either number on its own; they were never compared, because nothing could
// compare them.
//
// So the level a request lands in, and the levels a cursor move must warm, are stated
// here once, as data, and asserted against each other in a test.

import Foundation

/// The view a cursor move is happening in. Which levels have to be warm is a fact
/// about the surface the user is paging in, not about the loader.
public enum PagingSurface: String, Sendable, CaseIterable {
    /// The contact sheet. Paging moves the grid cursor; the loupe is not on screen.
    case grid
    /// The strip while the loupe is the view. Paging here IS loupe paging, so it warms
    /// both its own cells and the level the viewer above it draws from.
    case filmstrip
    /// The viewer itself. It warms one level — its own — so that hiding the strip
    /// stops showing the strip and does not also empty the cache paging reads.
    case loupe
}

public enum ThumbnailLadder {

    /// Sizes the cache is allowed to hold. A request snaps up to one of these so a
    /// thumbnail-size slider drag reuses decodes instead of spawning one per pixel step.
    public static let levels: [Int] = [256, 512, 1024, 2048]

    /// The level a request of `size` pixels lands in.
    public static func bucket(for size: Int) -> Int {
        for level in levels where size <= level { return level }
        return levels[levels.count - 1]
    }

    /// What the loupe's instant path asks the browse cache for, before the pipeline has
    /// produced anything. A constant here rather than a literal at the call site,
    /// because the whole defect was that this number and the prefetch's number lived in
    /// different files and were never put side by side.
    public static let loupeInstantPixels: Int = 1600

    /// The level `loupeInstantPixels` actually resolves to.
    public static var loupeBucket: Int { bucket(for: loupeInstantPixels) }

    /// Every cache level one cursor move has to warm, most urgent first.
    ///
    /// Most urgent first is load-bearing: the caller maps the order onto descending
    /// queue priority, so the strip's own visible cells cannot be starved by the
    /// heavier level behind them.
    public static func warmSizes(for surface: PagingSurface, browsePixels: Int) -> [Int] {
        let browse = bucket(for: browsePixels)
        switch surface {
        case .grid:
            return [browse]
        case .filmstrip:
            // The strip's visible cells first, then the level the next arrow press will
            // be drawn from. Without the second entry the loupe pages off a cold cache
            // however warm the strip is.
            return browse == loupeBucket ? [browse] : [browse, loupeBucket]
        case .loupe:
            // `browsePixels` is deliberately ignored: the viewer's level is a property
            // of the viewer, not of the thumbnail-size slider, and reading a size the
            // caller happened to pass is how the two drifted apart in the first place.
            return [loupeBucket]
        }
    }
}

/// D34's ring: `ahead` frames in the direction of travel, `behind` the other way.
/// Fixed policy, not a preference. Pure index arithmetic — the loader owns the URLs,
/// the queue and the direction memory; this owns only which offsets are in the window.
public struct PrefetchRing: Sendable, Equatable {

    public let ahead: Int
    public let behind: Int

    public init(ahead: Int = 8, behind: Int = 2) {
        self.ahead = Swift.max(0, ahead)
        self.behind = Swift.max(0, behind)
    }

    /// The window around `anchor`, split so the caller can give the two halves
    /// different priorities. The leading half always starts with the anchor itself:
    /// the frame under the cursor is the one thing that must never be speculative.
    ///
    /// Both halves are clamped to the list, deduplicated and never overlap, so a
    /// window near either end asks for fewer decodes rather than for the same decode
    /// twice.
    public func window(anchor: Int, count: Int,
                       direction: Int) -> (ahead: [Int], behind: [Int]) {
        guard count > 0, anchor >= 0, anchor < count else { return ([], []) }
        let travel = direction >= 0 ? 1 : -1
        var forward: [Int] = [anchor]
        var seen: Set<Int> = [anchor]
        if ahead > 0 {
            for step in 1...ahead {
                let i = anchor + step * travel
                guard i >= 0, i < count, seen.insert(i).inserted else { continue }
                forward.append(i)
            }
        }
        var back: [Int] = []
        if behind > 0 {
            for step in 1...behind {
                let i = anchor - step * travel
                guard i >= 0, i < count, seen.insert(i).inserted else { continue }
                back.append(i)
            }
        }
        return (forward, back)
    }

    /// The direction of travel implied by the cursor moving from `previous` to
    /// `anchor`. A move with no history, or a move to where the cursor already was,
    /// keeps the direction it had — so a repeated key does not flip the window.
    public static func direction(from previous: Int?, to anchor: Int,
                                 current: Int) -> Int {
        guard let previous, previous != anchor else { return current >= 0 ? 1 : -1 }
        return anchor >= previous ? 1 : -1
    }
}
