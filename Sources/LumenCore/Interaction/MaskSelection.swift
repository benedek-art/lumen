// MaskSelection.swift
// Which component is being edited, given a selection and the mask being drawn.
//
// The mask panel discloses several masks at once — one chevron each, any number open —
// while exactly one mask is SELECTED, and the selected mask is what the canvas edits and
// what the develop column's sliders point at. Those are two different questions and for
// one round the panel answered both with one number.
//
// It read `activeComponentIndex`, which resolves against the selected mask, inside every
// row of every disclosed mask. So opening a second mask's chevron without selecting it
// drew that mask's parts highlighted at the OTHER mask's index, opened an editor on
// whatever component happened to sit at that position, and decided whether the Brush
// tools appeared by what the other mask's index landed on in this mask's list. Tapping a
// row there moved the selected mask's index, so the next Contribution drag landed on a
// mask that was not under the pointer — an edit to a photograph's mask that the
// photographer did not make and could not see.
//
// The panel's own thesis is "the row selects, the chevron discloses". This is that
// sentence carried one level down, where it had only ever been applied at the top: one
// component is active at a time, it belongs to the selected mask, and a mask that is
// merely disclosed shows its parts with none of them chosen.
//
// It lives here rather than in the view for the reason every rule in this directory
// does: `Sources/LumenApp` is `#if os(macOS)`, it compiles on one CI lane, and no test
// in the package can construct the view that held this logic. Selection arithmetic is
// exactly the kind that is wrong in a way nobody notices until an edit lands on the
// wrong photograph.

import Foundation

public enum MaskSelection {

    /// The component index to draw as chosen for `maskID`, or nil for none.
    ///
    /// - Parameters:
    ///   - maskID: the mask being drawn — NOT necessarily the selected one.
    ///   - componentCount: how many parts that mask has.
    ///   - selectedMaskID: the mask the panel and canvas are pointed at.
    ///   - selectedComponent: the index within the selected mask, which may be stale by
    ///     one edit — a component can be removed between a click and the next body pass
    ///     — so it is clamped rather than trusted.
    ///
    /// Returns nil when the mask is not the selected one, and when it has no components
    /// at all. Both are "nothing is being edited here", which is what a disclosed mask
    /// should show before you choose a part of it.
    public static func activeComponent(maskID: String,
                                       componentCount: Int,
                                       selectedMaskID: String?,
                                       selectedComponent: Int) -> Int? {
        guard let selectedMaskID, maskID == selectedMaskID else { return nil }
        guard componentCount > 0 else { return nil }
        return Swift.min(Swift.max(selectedComponent, 0), componentCount - 1)
    }
}
