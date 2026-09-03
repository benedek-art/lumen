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

/// Reported when a slider takes or loses keyboard focus, so the key dispatcher can hand
/// the arrows back (docs/28 Phase 7).
///
/// An environment hook rather than an `@EnvironmentObject` for the same reason as the
/// gesture one above: `LumenSlider` deliberately does not observe `AppState`, and making
/// ninety sliders observers so three of them could report focus would re-body every panel
/// on every publish. The default is a no-op so previews and tests need no setup.
private struct SliderFocusKey: EnvironmentKey {
    static let defaultValue: (Bool) -> Void = { _ in }
}

extension EnvironmentValues {
    var sliderGestureChanged: (Bool) -> Void {
        get { self[SliderGestureKey.self] }
        set { self[SliderGestureKey.self] = newValue }
    }

    var sliderFocusChanged: (Bool) -> Void {
        get { self[SliderFocusKey.self] }
        set { self[SliderFocusKey.self] = newValue }
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
    /// The crop tool's "show me the whole frame" mode — a render input the loupe
    /// passes to every render call and, for one release, did not put in its key: R
    /// toggled the overlay while the picture kept its old cropping, so the rectangle
    /// was drawn against a frame it is not expressed in — the exact compounding-crop
    /// class the comments around the crop overlay warn about. Compare panes have no
    /// crop tool and default it false.
    let showingUncropped: Bool

    /// Bumped once when a slider gesture ends (`AppState.settleTick`). Not a render
    /// input — a request for the quality pass the drag deferred. It is in the KEY
    /// rather than in a callback because `onEnded` usually commits the value the last
    /// motion event already committed: the recipe is identical, so nothing else in
    /// this key moves, and without the tick the picture would rest on its final draft
    /// forever.
    let settleTick: Int

    /// The zoomed region ask (`ZoomRegion.requestUnit`), quantized — nil for
    /// whole-frame renders, which is every fit render and every compare pane. In the
    /// key because a pan past the rendered margin must re-render; quantization is what
    /// keeps that from being every pan point, and the loupe holds it STICKY while a
    /// pinch is in flight so a continuous zoom does not mint a request per quantum.
    let regionUnit: CGRect?

    /// The current key for a surface showing `url` with `recipe` at `longEdge`.
    /// Reads the beside-the-recipe inputs from the one place they live.
    @MainActor
    static func current(url: URL, recipe: Recipe, longEdge: Int,
                        state: AppState,
                        showingUncropped: Bool = false,
                        regionUnit: CGRect? = nil) -> ViewerRenderKey {
        ViewerRenderKey(url: url, recipe: recipe, longEdge: longEdge,
                        strokeRefs: Set(state.strokeSets(for: recipe).keys),
                        softProof: state.activeSoftProof,
                        matteKinds: state.maskMatteKinds(for: url),
                        showingUncropped: showingUncropped,
                        settleTick: state.settleTick,
                        regionUnit: regionUnit)
    }
}

#endif
