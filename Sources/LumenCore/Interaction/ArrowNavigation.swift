// ArrowNavigation.swift
// What an arrow key does to the cursor and the selection — the one decision, in one
// place, as a value.
//
// The defect this exists to stop: in Compare and Survey, → ran the same "select the
// next photo" path the grid uses, and that path REBUILDS the selection as a single
// photo. Compare and Survey are views OF the selection — the set of frames on screen
// is the selection — so the key documented as cycling the candidate collapsed a
// six-frame survey to one frame plus its neighbour. The comparison was destroyed by
// the key whose entire job is to move around inside it.
//
// The reason it survived is that "which list does this arrow walk" is a rule about
// state, expressed as a method on a SwiftUI observable object in a target with no
// tests. Here it is arithmetic over two integers and a flag, and it fails when it is
// wrong.

import Foundation

public enum ArrowNavigation {

    /// The outcome of one arrow press.
    public enum Step: Equatable, Sendable {
        /// Move the cursor to this index in the library and make that photo the whole
        /// selection. Browsing: the selection follows the cursor because the cursor is
        /// what the user is choosing.
        case selectSingle(index: Int)
        /// Move the cursor to this index in the SELECTION, leaving the selection
        /// exactly as it is. Comparing: the set on screen is the thing being decided
        /// about, so nothing that merely moves attention may edit it.
        case moveWithinSelection(index: Int)
        /// The press lands where the cursor already is. Nothing to do, and in
        /// particular no selection rebuild to do.
        case stay
    }

    /// Resolve one press.
    ///
    /// - Parameters:
    ///   - delta: signed step. ±1 for ← →, ±one row for ↑ ↓ in the grid.
    ///   - libraryCursor: where the cursor sits in the visible roll, nil if nowhere.
    ///   - libraryCount: how many photos the roll is showing.
    ///   - selectionCursor: where the cursor sits within the selected photos, in the
    ///     order they are drawn, nil if the cursor is not one of them.
    ///   - selectionCount: how many photos are selected.
    ///   - comparing: true in Compare and Survey — the views whose content IS the
    ///     selection.
    ///
    /// Both walks clamp at their ends rather than wrapping: a key held down at the last
    /// frame should stop, not silently return to the first.
    public static func step(delta: Int,
                            libraryCursor: Int?,
                            libraryCount: Int,
                            selectionCursor: Int?,
                            selectionCount: Int,
                            comparing: Bool) -> Step {
        guard libraryCount > 0 else { return .stay }

        // A comparison only exists once two or more frames have been chosen. Comparing
        // with a single photo selected is the cull gesture "this one against the next
        // one", where the second frame is implied by the cursor — so the arrows there
        // walk the roll, exactly as they do in the grid, and both frames advance.
        if comparing && selectionCount >= 2 {
            guard let cursor = selectionCursor else {
                // The cursor is outside the set being compared — a ⌘-click can leave it
                // there. Land back inside it rather than walking the roll and rebuilding
                // the selection, which is the failure this whole rule is about.
                return .moveWithinSelection(index: delta >= 0 ? 0 : selectionCount - 1)
            }
            let next = clamp(cursor + delta, count: selectionCount)
            return next == cursor ? .stay : .moveWithinSelection(index: next)
        }

        guard let cursor = libraryCursor else { return .selectSingle(index: 0) }
        let next = clamp(cursor + delta, count: libraryCount)
        return next == cursor ? .stay : .selectSingle(index: next)
    }

    private static func clamp(_ index: Int, count: Int) -> Int {
        Swift.min(Swift.max(index, 0), count - 1)
    }
}
