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
    public static func shouldCoalesce(openKey: String?, openURLs: Set<URL>,
                                      key: String?, urls: Set<URL>,
                                      sinceLastEdit: TimeInterval,
                                      window: TimeInterval) -> Bool {
        guard let key, let openKey, key == openKey else { return false }
        guard urls == openURLs else { return false }
        return sinceLastEdit < window
    }
}
