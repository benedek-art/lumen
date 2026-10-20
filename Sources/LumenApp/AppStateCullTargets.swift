// AppStateCullTargets.swift
// Which photos a cull key decides about, per view, and where auto-advance goes after
// it. The rule is `CullTargeting` in LumenCore, where it is tested on Linux; this file
// only feeds it the app's state.
//
// Grid: the whole selection, as before. Loupe, Compare and Survey: the active frame
// (the cursor) only, and the selection is left alone so a survey stays populated.
// Develop edits are untouched — they still go to `editTargets`.

#if os(macOS)

import Foundation
import LumenCore

extension AppState {

    /// The surface a cull key was pressed in, in LumenCore's words.
    var cullSurface: CullTargeting.Surface {
        switch viewMode {
        case .grid: return .grid
        case .loupe: return .loupe
        case .compare: return .compare
        case .survey: return .survey
        }
    }

    /// The photos `setFlag`, `setRating` and `setLabel` change. In the grid this is
    /// `editTargets`; elsewhere it is the photo under the cursor.
    var cullTargetIDs: [URL] {
        let surface = cullSurface
        // Only the grid reads the selection, so only the grid pays for building it.
        let selected: [URL]
        if CullTargeting.scope(on: surface) == .selection, selection.count > 1 {
            selected = selectedPhotos.map(\.id)
        } else {
            selected = []
        }
        // Compare and Survey only decide about a cursor that is one of their frames.
        let shown: [URL]? = surface.isComparing ? comparisonSet.map(\.id) : nil
        return CullTargeting.targets(on: surface,
                                     selection: selected,
                                     active: primarySelection?.id,
                                     shown: shown)
    }

    /// Auto-advance after a cull decision, for every case the roll walk must not
    /// handle. Returns true when it has dealt with the advance (moved the cursor inside
    /// the comparison, or decided to stay); false hands over to `advanceIfNeeded`'s
    /// step through the roll.
    func advanceHandledByCullRule(forced: Bool = false) -> Bool {
        let surface = cullSurface
        let set: [PhotoItem] = surface.isComparing ? comparisonSet : []
        let cursor: Int?
        if let current = primarySelection {
            cursor = set.firstIndex { $0.id == current.id }
        } else {
            cursor = nil
        }
        let step = CullTargeting.advance(on: surface,
                                         autoAdvance: autoAdvance || forced,
                                         selectionCount: selection.count,
                                         comparisonCursor: cursor,
                                         comparisonCount: set.count)
        switch step {
        case .nextInRoll:
            return false
        case .stay:
            return true
        case .withinComparison(let index):
            if set.indices.contains(index) { moveCursor(to: set[index]) }
            return true
        }
    }

    // MARK: Pane clicks

    /// Flag one Compare or Survey pane from its badge strip: make it the active frame,
    /// then run the same verb the P/X keys run.
    func cullPane(_ photo: PhotoItem, flag: PhotoFlag) {
        focusPaneForCull(photo)
        setFlag(flag)
    }

    /// Rate one Compare or Survey pane from its badge strip; see `cullPane(_:flag:)`.
    func cullPane(_ photo: PhotoItem, rating: Int) {
        focusPaneForCull(photo)
        setRating(rating)
    }

    /// Move the cursor to the clicked pane without disturbing the comparison. A pane
    /// that is outside the selection — the implied neighbour of a one-photo 2-up — is
    /// selected outright, which is what → would have done to reach it.
    private func focusPaneForCull(_ photo: PhotoItem) {
        guard primarySelection?.id != photo.id else { return }
        if selection.count >= 2, selection.contains(photo.id) {
            moveCursor(to: photo)
        } else {
            select(photo)
        }
    }
}

#endif
