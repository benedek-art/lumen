// PasteSettings.swift
// Paste Settings and Paste Settings Without Masks, as one rule on the recipe.
//
// Both commands lived only in `AppState` (macOS-only, no lane runs it here), and both
// made the same omission: they handed the target the source's develop and look and left
// the target's `pipelineVersion` where it was (M-06). `LookSubset.applied(to:)` raises
// the stamp on purpose — a version-2 look can say "black and white, off, mix kept",
// which a version-1 reader renders as black and white — so the exact construct that
// door guards against travelled unguarded through the two commands photographers use
// across a whole shoot, and the catalog then stamped the row with the older number.
//
// The assignments are the ones `AppState` made, unchanged, including the render-preset
// rule `LookSubset.carriedRenderPreset` owns; the version is the one line added.
//
// Retouching (Heal and Clone spots, painted heal strokes) is the second rule here: it
// stays behind unless the photographer opts in (`RetouchPaste`, the Edit menu's "Paste
// Includes Spot Removal"). The two rules meet at the version stamp. A source's spots
// raise ITS stamp to `healSpotsPipelineVersion`, so taking "the newer of the two" from
// a source whose spots did not travel would stamp a spot-free target as a spot recipe —
// and an older build would then refuse to write a photograph it can represent fully.
// So when retouching is left behind, the source's contribution is capped below the
// spot version: the vocabulary it is credited with is the one it can express WITHOUT
// the spots. A stamp above the spot version (a newer build's document) is carried as
// it is — this build cannot tell what in it is retouch, and carrying is the safe side.

import Foundation

extension Recipe {

    /// This recipe with `source`'s develop and look — the look's render preset carried
    /// by `LookSubset.carriedRenderPreset` — and, when `includingMasks`, its masks and
    /// their folders. Retouching travels only when `includingRetouch`; otherwise this
    /// recipe keeps its own (`RetouchPaste.develop`). Stamped with the newer of the two
    /// vocabularies, because the result holds whatever `source` could express — less
    /// the spot vocabulary when the spots stayed behind.
    public func adoptingSettings(from source: Recipe, includingMasks: Bool,
                                 includingRetouch: Bool) -> Recipe {
        var out = self
        // Built as a `Develop` first and assigned once, so `develop`'s raise-only
        // observer only ever sees the retouching that actually lands here.
        out.develop = RetouchPaste.develop(source.develop, onto: develop,
                                           includingRetouch: includingRetouch)
        // Read BEFORE the assignment: after it, `out.look` is `source.look` and the
        // target's own preset is already gone.
        let own = look.render.preset
        out.look = source.look
        out.look.render.preset =
            LookSubset.carriedRenderPreset(source.look.render.preset, onto: own)
        if includingMasks {
            out.masks = source.masks
            // The folders come with their masks, or every pasted mask names a group
            // the target has not got and is silently ungrouped.
            out.maskGroups = source.maskGroups
        }
        var carried = source.pipelineVersion
        let sourceHasRetouch = !source.develop.heal.spots.isEmpty
            || source.develop.heal.strokesRef != nil
        if !includingRetouch, sourceHasRetouch, carried <= healSpotsPipelineVersion {
            carried = Swift.min(carried, healSpotsPipelineVersion - 1)
        }
        // `out.pipelineVersion` already holds this recipe's stamp, raised by the
        // `develop` observer if its own retouching (kept, or pasted) needs it.
        out.pipelineVersion = Swift.max(out.pipelineVersion, carried)
        return out
    }
}
