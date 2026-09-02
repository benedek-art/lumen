// HistoryCoalescing.swift
// The one rule that decides whether an edit folds into the open undo step or opens a
// new one. Stated here, in LumenCore, so it is a tested law rather than an `if` in
// the app layer — the same treatment FrameDelivery got, for the same reason.
//
// The rule used to be key + recency alone, and that pair is not an identity: the
// coalescing key names a CONTROL ("tone.exposure"), so dragging Exposure on photo A,
// arrowing to photo B, and dragging Exposure again inside the 1.2 s window folded
// B's drag into A's open step. Undo then reverted A — the photo no longer on screen
// — and B's pre-drag state was never recorded anywhere: not in the open step's
// `before` (kept from A's first event) and not in any later step. The third
// condition, "the same photos", is what makes the step an identity again.

import Foundation

public enum HistoryCoalescing {

    /// True when an edit belongs in the open step: the same control, the same set of
    /// photos, and recent enough to still be one gesture of thought.
    ///
    /// The photo-set comparison is equality, not subset: a step is "this edit to
    /// these photos", and an event touching more photos (a selection change between
    /// events) or fewer is a different edit even mid-window. Equality also keeps the
    /// merge closed — folding can never grow the step's photo set, so `before`
    /// stays complete for every photo the step claims to restore.
    /// - Parameters:
    ///   - openEpoch: the gesture the open step was recorded during, if any.
    ///   - epoch: the gesture this edit is arriving during, if any.
    ///
    /// WHAT MAKES A GESTURE ONE STEP IS THE GESTURE, NOT THE CONTROL — and that is the
    /// clause below, which comes first because the key-and-window rule cannot express
    /// it. The key rule assumes one drag moves one field. A grading wheel moves two:
    /// its puck writes `hue` and then `sat` inside a single `onChanged`, through two
    /// bindings with two different coalescing keys. The open step's key therefore
    /// alternates `…hue`, `…sat`, `…hue`, and never equals the incoming one, so the
    /// first guard failed on every mouse event and coalescing never happened once.
    ///
    /// Two steps per event, sixty events a second, against `HistoryStack.limit` of 400:
    /// about three and a half seconds of moving a puck fills the ring, and everything
    /// older — the crop, the white balance, a mask built ten minutes earlier — is
    /// dropped off the front and can never be undone back to. The photographer holds
    /// ⌘Z expecting the grade to come off and arrives somewhere in the middle of it,
    /// with the rest of the session gone from the Edit menu.
    ///
    /// The epoch answers the question the key was standing in for. It is monotonic and
    /// bumped once per gesture, so every edit inside one drag carries the same value
    /// however many fields the drag writes, and no edit outside it can collide. The
    /// photo set must still match: a drag that spans a photograph switch must not fold
    /// the second photograph's edit into the first's step. The time window is
    /// deliberately NOT applied — a long, careful drag is one decision, and an
    /// abandoned one is closed by the silence watchdog that already exists.
    public static func shouldCoalesce(openKey: String?, openURLs: Set<URL>,
                                      key: String?, urls: Set<URL>,
                                      sinceLastEdit: TimeInterval,
                                      window: TimeInterval,
                                      openEpoch: Int? = nil,
                                      epoch: Int? = nil) -> Bool {
        guard urls == openURLs else { return false }
        if let epoch, let openEpoch, epoch == openEpoch { return true }
        guard let key, let openKey, key == openKey else { return false }
        return sinceLastEdit < window
    }
}
