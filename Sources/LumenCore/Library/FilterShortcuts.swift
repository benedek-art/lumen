// FilterShortcuts.swift
// The culling filters as keyboard verbs: Picks only, Unflagged only, Rejected only,
// Rated ≥ N, and Lightroom's ⌘L "Enable Filters" toggle.
//
// A two-pass cull — P/X over the unflagged, then stars over the picks — flips between
// these scopes dozens of times a session, and every flip was a trip to a popover. The
// flag verbs set the flag criterion exactly as the sidebar's rows do (ContentView's
// `counts`): the same value again clears it, and nothing else in the filter moves. The
// rating verbs do the same with `minRating`.

import Foundation

public enum FilterShortcut: Equatable, Sendable {
    case picksOnly
    case unflaggedOnly
    case rejectedOnly
    /// At least this many stars, clamped to 1...5.
    case ratedAtLeast(Int)

    /// `filter` with this shortcut toggled. Only the one criterion it names changes.
    public func toggled(in filter: LibraryFilter) -> LibraryFilter {
        var next = filter
        switch self {
        case .picksOnly: next.flags = Self.toggle([.pick], filter.flags)
        case .unflaggedOnly: next.flags = Self.toggle([.unflagged], filter.flags)
        case .rejectedOnly: next.flags = Self.toggle([.reject], filter.flags)
        case .ratedAtLeast(let stars):
            let clamped = Swift.min(Swift.max(stars, 1), 5)
            next.minRating = filter.minRating == clamped ? 0 : clamped
        }
        return next
    }

    /// Whether `filter` currently shows this shortcut's scope — the menu's checkmark.
    public func isOn(in filter: LibraryFilter) -> Bool {
        switch self {
        case .picksOnly: return filter.flags == [.pick]
        case .unflaggedOnly: return filter.flags == [.unflagged]
        case .rejectedOnly: return filter.flags == [.reject]
        case .ratedAtLeast(let stars):
            return filter.minRating == Swift.min(Swift.max(stars, 1), 5)
        }
    }

    private static func toggle(_ wanted: Set<PhotoFlag>, _ current: Set<PhotoFlag>)
        -> Set<PhotoFlag> {
        current == wanted ? [] : wanted
    }
}

/// ⌘L: turn the filter off without losing it, and back on again.
///
/// ⌘\ clears the filter for good; this keeps the last active filter so the same chord
/// brings it back. Editing the filter while it is off starts a new one — the stash is
/// only restored onto an empty bar, so it can never overwrite criteria set since.
public struct FilterToggleMemory: Equatable, Sendable {

    public private(set) var stashed: LibraryFilter?

    public init() {}

    public enum Outcome: Equatable, Sendable {
        case turnedOff
        case turnedOn
        /// No filter is lit and none is stashed.
        case nothingToRestore
    }

    /// The filter after the toggle, and what happened.
    public mutating func toggle(_ current: LibraryFilter) -> (LibraryFilter, Outcome) {
        if current.isActive {
            stashed = current
            var off = LibraryFilter()
            // The All/Any join is how the bar reads, not a criterion; keep it.
            off.matchAny = current.matchAny
            return (off, .turnedOff)
        }
        guard let restored = stashed else { return (current, .nothingToRestore) }
        stashed = nil
        return (restored, .turnedOn)
    }
}
