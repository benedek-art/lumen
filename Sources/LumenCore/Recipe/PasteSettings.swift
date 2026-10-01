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

import Foundation

extension Recipe {

    /// This recipe with `source`'s develop and look — the look's render preset carried
    /// by `LookSubset.carriedRenderPreset` — and, when `includingMasks`, its masks and
    /// their folders. Stamped with the newer of the two vocabularies, because the
    /// result holds whatever `source` could express.
    public func adoptingSettings(from source: Recipe, includingMasks: Bool) -> Recipe {
        var out = self
        out.develop = source.develop
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
        out.pipelineVersion = Swift.max(pipelineVersion, source.pipelineVersion)
        return out
    }
}
