// CullTargeting.swift
// Which photos a cull key (P, X, U, 0–5, 6–9, -) decides about, and where the cursor
// goes afterwards — per viewing surface, as a value.
//
// The defect this exists to stop: Compare and Survey are views OF the selection, and
// every cull key wrote to the whole selection whatever was on screen. Pressing X in a
// six-frame survey to throw out the frame under the cursor rejected all six; pressing
// 3 rated all six. Lightroom (Auto Sync off) decides about the ACTIVE photo in Loupe,
// Compare and Survey and about the selection only in the Grid, and so does this.
//
// Develop edits are not covered here: they still go to `editTargets`.

import Foundation

public enum CullTargeting {

    /// The viewing surface the key was pressed in. Mirrors the app's `ViewMode`, which
    /// is a LumenApp type.
    public enum Surface: String, Sendable, CaseIterable {
        case grid, loupe, compare, survey

        /// Compare and Survey: the surfaces whose content is the selection.
        public var isComparing: Bool { self == .compare || self == .survey }
    }

    /// What one cull decision is applied to.
    public enum Scope: Equatable, Sendable {
        /// Every selected photo, or the cursor's photo when at most one is selected.
        case selection
        /// The photo under the cursor only; the selection is left alone.
        case activeOnly
    }

    public static func scope(on surface: Surface) -> Scope {
        surface == .grid ? .selection : .activeOnly
    }

    /// The photos one cull decision changes.
    ///
    /// - Parameters:
    ///   - selection: the selected photos, in drawing order.
    ///   - active: the photo under the cursor, if any.
    ///
    /// The grid branch is `AppState.editTargets` exactly. The active-only branch never
    /// falls back to the selection when there is no cursor: broadcasting is the bug.
    public static func targets<ID: Hashable>(on surface: Surface,
                                             selection: [ID],
                                             active: ID?) -> [ID] {
        switch scope(on: surface) {
        case .selection:
            if selection.count > 1 { return selection }
            if let active { return [active] }
            return []
        case .activeOnly:
            if let active { return [active] }
            return []
        }
    }

    /// Where auto-advance takes the cursor after a cull decision.
    public enum Advance: Equatable, Sendable {
        /// Leave the cursor where it is.
        case stay
        /// Step to the next photo of the roll (the old, single-photo behaviour).
        case nextInRoll
        /// Step to this index of the comparison set, leaving the selection alone.
        case withinComparison(index: Int)
    }

    /// Resolve auto-advance.
    ///
    /// - Parameters:
    ///   - autoAdvance: the user's `A` toggle.
    ///   - selectionCount: how many photos are selected.
    ///   - comparisonCursor: the cursor's index in the comparison set, nil if outside.
    ///   - comparisonCount: how many frames the comparison is showing.
    ///
    /// A comparison of two or more selected frames advances INSIDE itself and stops at
    /// its last frame, the way the arrow keys do (`ArrowNavigation`). Anywhere else a
    /// multi-selection does not advance at all: stepping the roll would rebuild the
    /// selection as one photo.
    public static func advance(on surface: Surface,
                               autoAdvance: Bool,
                               selectionCount: Int,
                               comparisonCursor: Int?,
                               comparisonCount: Int) -> Advance {
        guard autoAdvance else { return .stay }
        if surface.isComparing && selectionCount >= 2 {
            guard let cursor = comparisonCursor, cursor >= 0,
                  cursor + 1 < comparisonCount else { return .stay }
            return .withinComparison(index: cursor + 1)
        }
        return selectionCount <= 1 ? .nextInRoll : .stay
    }
}

/// The words for one photo's cull state, for a badge's tooltip and accessibility label.
public enum CullMarks {

    /// "Picked, 3 stars, Red label"; "Unflagged, no rating" when nothing is set.
    /// `labelName` lets a caller pass a renamed label; nil uses the built-in name.
    public static func summary(flag: PhotoFlag,
                               rating: Int,
                               label: ColorLabel?,
                               labelName: String? = nil) -> String {
        var parts = [flag.displayName]
        let stars = Swift.min(Swift.max(rating, 0), 5)
        switch stars {
        case 0: parts.append("no rating")
        case 1: parts.append("1 star")
        default: parts.append("\(stars) stars")
        }
        if let label {
            parts.append("\(labelName ?? label.displayName) label")
        }
        return parts.joined(separator: ", ")
    }

    /// The tooltip for one star button: clicking the current rating clears it, the
    /// same toggle the digit keys apply.
    public static func starHelp(index: Int, rating: Int) -> String {
        index == rating ? "Clear the rating" : "Rate \(index)"
    }
}
