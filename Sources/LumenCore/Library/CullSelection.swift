// CullSelection.swift
// Selecting by decision: picks, rejects, unflagged, rated at least N, invert, and
// "deselect unpicked" — Lightroom's Edit-menu selection verbs.
//
// Every rule works on the photos currently SHOWN and leaves the filter alone. Without
// these, "select the picks" was a detour through the filter bar that also changed what
// the grid showed. A selected frame the filter hides is not in `shown`, so it drops out
// of every result — including Invert, whose answer is "shown minus selected".

import Foundation

public enum CullSelection {

    public enum Rule: Equatable, Sendable {
        case picks
        case rejects
        case unflagged
        /// At least this many stars, clamped to 1...5.
        case ratedAtLeast(Int)
        case invert
        /// Keep only the picks of the current selection.
        case deselectUnpicked
    }

    /// The selection a rule produces over `shown`, in no particular order.
    public static func apply<P: LibraryFilterable & Identifiable>(
        _ rule: Rule, to shown: [P], selection: Set<P.ID>
    ) -> Set<P.ID> {
        var result: Set<P.ID> = []
        for photo in shown where includes(rule, photo, selected: selection.contains(photo.id)) {
            result.insert(photo.id)
        }
        return result
    }

    private static func includes<P: LibraryFilterable>(_ rule: Rule, _ photo: P,
                                                       selected: Bool) -> Bool {
        switch rule {
        case .picks: return photo.flag == .pick
        case .rejects: return photo.flag == .reject
        case .unflagged: return photo.flag == .unflagged
        case .ratedAtLeast(let stars):
            return photo.rating >= Swift.min(Swift.max(stars, 1), 5)
        case .invert: return !selected
        case .deselectUnpicked: return selected && photo.flag == .pick
        }
    }

    /// What the status bar says afterwards: the count, and when it is zero, why.
    public static func summary(_ rule: Rule, selected: Int, shown: Int) -> String {
        let noun: String
        switch rule {
        case .picks: noun = selected == 1 ? "pick" : "picks"
        case .rejects: noun = selected == 1 ? "reject" : "rejects"
        case .unflagged: noun = selected == 1 ? "unflagged photo" : "unflagged photos"
        case .ratedAtLeast(let stars):
            let clamped = Swift.min(Swift.max(stars, 1), 5)
            noun = (selected == 1 ? "photo" : "photos") + " rated \(clamped)★ or more"
        case .invert, .deselectUnpicked: noun = selected == 1 ? "photo" : "photos"
        }
        if selected == 0 {
            switch rule {
            case .invert: return "Selection inverted — nothing left selected"
            case .deselectUnpicked: return "No picks in the selection — nothing left selected"
            default: return "No \(noun) among the \(shown) shown"
            }
        }
        return "Selected \(selected) \(noun)"
    }
}
