// RenderRequest.swift
// The ONE render key every image surface uses — loupe, compare panes, survey panes.
//
// This exists because the key was fixed once, in the loupe, and the fix never
// travelled: `LoupeView` learned that brush blobs and AI mattes arrive asynchronously
// BESIDE the recipe and that the soft proof is a viewing mode OUTSIDE it — so all
// three went into its task id — while both compare panes kept a private three-field
// copy. The consequences were exactly the ones the loupe's comments warn about, alive
// in compare: a photo whose mask uses a brush painted in an earlier session rendered
// with that component contributing nothing and stayed that way; a Subject mask's matte
// arrived and no re-render noticed; ⇧S changed the loupe's picture and not the
// compare panes', unbadged. A correct rule that lives in one view is a defect with a
// delay; this file is where the rule lives now, and the views just call it.

#if os(macOS)

import Foundation
import LumenCore
import SwiftUI

// MARK: - The drag-in-flight signal

/// Fired `true` at the first movement of any slider or wheel gesture and `false` at
/// its release, injected once at the root. `AppState.sliderGesture(active:)` is the
/// one consumer: it defers per-event catalog writes and scope re-binning to the
/// gesture's end. The default is a no-op so previews and tests need no setup.
private struct SliderGestureKey: EnvironmentKey {
    static let defaultValue: (Bool) -> Void = { _ in }
}

extension EnvironmentValues {
    var sliderGestureChanged: (Bool) -> Void {
        get { self[SliderGestureKey.self] }
        set { self[SliderGestureKey.self] = newValue }
    }
}

/// Everything that should restart a surface's render task, cheap to compare
/// (`Recipe` is `Equatable` — no fingerprint hashing on the main actor per body pass).
struct ViewerRenderKey: Equatable {
    let url: URL
    let recipe: Recipe
    let longEdge: Int
    /// Which brush blobs are actually in memory right now. A `strokesRef` is a promise
    /// that bytes exist, not the bytes; they load asynchronously and publish beside
    /// the recipe, so a key without them never restarts when they land.
    let strokeRefs: Set<String>
    /// A viewing mode, not an edit — outside the recipe, so named here explicitly.
    let softProof: SoftProof?
    /// Which AI mattes the renderer holds for this file right now. Same shape as
    /// `strokeRefs`, same trap.
    let matteKinds: Set<String>

    /// The current key for a surface showing `url` with `recipe` at `longEdge`.
    /// Reads the three beside-the-recipe inputs from the one place they live.
    @MainActor
    static func current(url: URL, recipe: Recipe, longEdge: Int,
                        state: AppState) -> ViewerRenderKey {
        ViewerRenderKey(url: url, recipe: recipe, longEdge: longEdge,
                        strokeRefs: Set(state.strokeSets(for: recipe).keys),
                        softProof: state.activeSoftProof,
                        matteKinds: state.maskMatteKinds(for: url))
    }
}

#endif
