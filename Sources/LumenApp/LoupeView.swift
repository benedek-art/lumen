// LoupeView.swift
// The loupe: Lumen's main image viewer. It draws the CGImage the render coordinator
// returns, at an explicit zoom ratio (fit / 1:1 / 2:1 / click-to-zoom-at-point) with
// drag-to-pan when the drawn image is larger than the viewport.
//
// Three behaviours this file exists to keep honest:
//   · Two-tier progressive refine (docs/12 §B2): a draft pass lands within a frame,
//     the quality pass ~250 ms after interaction settles. Stale results are discarded
//     by generation number and never reach the screen.
//   · Honest badges (docs/10 handoff honesty, docs/12 §B14): when the render fell back
//     to the camera's embedded preview, or the kernel library was unavailable, the
//     viewer says so. It never shows something that is not the edit without saying it.
//   · Zoom grammar is state the keymap can drive: `LoupeViewport.shared` carries the
//     viewport verbs (`setZoom(_:at:)`, `toggleZoom(at:)`, `cycleZoom`, `fit`) so the
//     dispatch table calls them with the AppState it already holds. Space bar binding
//     is the keymap's job; this file only exposes what it calls.
//
// The Metal-layer viewport (EDR, fp16 extended-linear — docs/16 Phase 1) replaces the
// SwiftUI `Image` underneath; the geometry, overlays and refine plumbing stay.

#if os(macOS)

import AppKit
import CoreGraphics
import Foundation
import LumenCore
import SwiftUI

// MARK: - Zoom grammar

/// The zoom ladder. `AppState.zoomLevel` is the source of truth: 0 means "fit",
/// anything else is a ratio of image pixels to device pixels — so 1.0 is true 1:1
/// on the panel, and 2.0 puts one image pixel on a 2×2 block of device pixels.
enum LoupeZoom {
    static let fit: Double = 0
    static let oneToOne: Double = 1
    static let twoToOne: Double = 2

    /// What `cycleZoom` walks through.
    static let ladder: [Double] = [fit, oneToOne, twoToOne]

    static func label(_ ratio: Double) -> String {
        if ratio <= 0 { return "FIT" }
        if abs(ratio - 1) < 0.001 { return "1:1" }
        if abs(ratio - 2) < 0.001 { return "2:1" }
        return String(format: "%.0f%%", ratio * 100)
    }
}

/// Viewport state that outlives any one `LoupeView` body and that the keymap needs a
/// handle on. Zoom itself lives in `AppState.zoomLevel` (one source of truth); what
/// lives here is the pan, the last cursor position the zoom verbs anchor on, and the
/// viewing modes that have no home in `AppState` yet.
///
/// The type is deliberately not `@MainActor`-annotated so `shared` can be referenced
/// from a view's property initializer; every verb that touches `AppState` is.
final class LoupeViewport: ObservableObject {

    static let shared = LoupeViewport()

    /// Pan offset in points, from the centred position. Clamped by the view against
    /// the drawn size, so it can never carry the image off screen.
    @Published var pan: CGSize = .zero

    /// Before/after presentation. `AppState.showBefore` is the `\` flip; this is the
    /// `Y` / `⌥Y` / `⇧Y` family (docs/12 §B8).
    @Published var beforeMode: BeforeAfterMode = .off

    /// Divider position for the split compare, 0…1 across the canvas.
    @Published var splitPosition: Double = 0.5

    @Published var showCrop: Bool = false
    @Published var showReadout: Bool = true
    @Published var maskOverlayOpacity: Double = 0.45

    /// Last pointer position in loupe-local points. Not `@Published`: it changes on
    /// every mouse move and nothing should redraw because of it. The zoom verbs read
    /// it so a keymap-driven zoom lands under the cursor, exactly like a click does.
    var lastCursor: CGPoint?

    /// True when the next zoom change should keep `lastCursor` pinned.
    var anchorNextZoomAtCursor: Bool = true

    private init() {}

    // MARK: Zoom verbs (the keymap's entry points)

    /// Set an explicit ratio, keeping `point` (loupe-local points) under the pointer.
    /// Pass `nil` to zoom about the centre of the viewport.
    @MainActor
    func setZoom(_ ratio: Double, at point: CGPoint?, in state: AppState) {
        if let point {
            lastCursor = point
            anchorNextZoomAtCursor = true
        } else {
            anchorNextZoomAtCursor = false
        }
        let clamped: Double = ratio.isFinite ? Swift.max(0, Swift.min(ratio, 16)) : 0
        if clamped <= 0 { pan = .zero }
        state.zoomLevel = clamped
    }

    @MainActor
    func setZoom(_ ratio: Double, in state: AppState) {
        setZoom(ratio, at: lastCursor, in: state)
    }

    /// `Space`: fit ↔ 1:1, centred on the cursor (docs/12 §B15 defaults).
    @MainActor
    func toggleZoom(at point: CGPoint?, in state: AppState) {
        if state.zoomLevel > 0 {
            setZoom(LoupeZoom.fit, at: nil, in: state)
        } else {
            setZoom(LoupeZoom.oneToOne, at: point ?? lastCursor, in: state)
        }
    }

    @MainActor
    func toggleZoom(in state: AppState) { toggleZoom(at: lastCursor, in: state) }

    /// Walks fit → 1:1 → 2:1 → fit.
    @MainActor
    func cycleZoom(in state: AppState) {
        let current: Double = state.zoomLevel
        var index: Int = 0
        for (i, step) in LoupeZoom.ladder.enumerated() where abs(step - current) < 0.001 {
            index = i
        }
        let next: Int = (index + 1) % LoupeZoom.ladder.count
        setZoom(LoupeZoom.ladder[next], at: lastCursor, in: state)
    }

    @MainActor
    func fit(in state: AppState) { setZoom(LoupeZoom.fit, at: nil, in: state) }

    @MainActor
    func oneToOne(in state: AppState) { setZoom(LoupeZoom.oneToOne, at: lastCursor, in: state) }

    @MainActor
    func twoToOne(in state: AppState) { setZoom(LoupeZoom.twoToOne, at: lastCursor, in: state) }

    @MainActor
    func zoomIn(in state: AppState) {
        let current: Double = state.zoomLevel > 0 ? state.zoomLevel : LoupeZoom.oneToOne
        setZoom(current * 2, at: lastCursor, in: state)
    }

    @MainActor
    func zoomOut(in state: AppState) {
        guard state.zoomLevel > 0 else { return }
        let next: Double = state.zoomLevel / 2
        setZoom(next < 0.35 ? LoupeZoom.fit : next, at: lastCursor, in: state)
    }

    // MARK: Pan verbs

    func panBy(_ delta: CGSize) {
        pan = CGSize(width: pan.width + delta.width, height: pan.height + delta.height)
    }

    func resetPan() { pan = .zero }

    /// Called when the photo changes: a new frame starts centred.
    func resetForNewPhoto() {
        pan = .zero
        lastCursor = nil
    }
}

// MARK: - Geometry

/// The viewport's arithmetic, factored out so the loupe and the compare panes lay their
/// images out identically. Every entry point guards the divisions: a zero-sized
/// container or a zero-pixel image must produce a harmless number, never a NaN that
/// propagates into a frame.
enum LoupeGeometry {

    /// Ratio that fits `image` inside `container`, in image-pixels per device-pixel.
    static func fitRatio(imageWidth: Int, imageHeight: Int,
                         container: CGSize, displayScale: CGFloat) -> Double {
        let iw = Double(imageWidth)
        let ih = Double(imageHeight)
        let cw = Double(container.width)
        let ch = Double(container.height)
        guard iw > 0, ih > 0, cw > 0, ch > 0 else { return 1 }
        let scale = Double(Swift.max(displayScale, 1))
        let byWidth = cw * scale / iw
        let byHeight = ch * scale / ih
        let r = Swift.min(byWidth, byHeight)
        return r.isFinite && r > 0 ? r : 1
    }

    /// On-screen size, in points, of an image drawn at `ratio`.
    static func drawnSize(imageWidth: Int, imageHeight: Int,
                          ratio: Double, displayScale: CGFloat) -> CGSize {
        let scale = Double(Swift.max(displayScale, 1))
        guard imageWidth > 0, imageHeight > 0, ratio.isFinite, ratio > 0, scale > 0 else {
            return CGSize(width: 1, height: 1)
        }
        let w = Double(imageWidth) * ratio / scale
        let h = Double(imageHeight) * ratio / scale
        return CGSize(width: CGFloat(Swift.max(w, 1)), height: CGFloat(Swift.max(h, 1)))
    }

    /// Pan clamped so the image edge can never be dragged past the viewport centre:
    /// an axis that already fits is pinned to 0.
    static func clampPan(_ pan: CGSize, container: CGSize, drawn: CGSize) -> CGSize {
        let mx = Swift.max(0, (drawn.width - container.width) / 2)
        let my = Swift.max(0, (drawn.height - container.height) / 2)
        let x = pan.width.isFinite ? Swift.min(Swift.max(pan.width, -mx), mx) : 0
        let y = pan.height.isFinite ? Swift.min(Swift.max(pan.height, -my), my) : 0
        return CGSize(width: x, height: y)
    }

    /// Where in the image (unit coordinates, origin top-left) a viewport point lands.
    /// Returns nil when the point is off the drawn image.
    static func imageUnitPoint(_ point: CGPoint, container: CGSize,
                               drawn: CGSize, pan: CGSize) -> CGPoint? {
        guard drawn.width > 0, drawn.height > 0 else { return nil }
        let ux = (point.x - container.width / 2 - pan.width) / drawn.width + 0.5
        let uy = (point.y - container.height / 2 - pan.height) / drawn.height + 0.5
        guard ux.isFinite, uy.isFinite else { return nil }
        guard ux >= 0, ux <= 1, uy >= 0, uy <= 1 else { return nil }
        return CGPoint(x: ux, y: uy)
    }

    /// The pan that keeps whatever sat under `point` at `oldDrawn` sitting under it at
    /// `newDrawn` — this is what makes click-to-zoom land where the user clicked.
    static func panKeeping(_ point: CGPoint, container: CGSize,
                           oldDrawn: CGSize, newDrawn: CGSize, pan: CGSize) -> CGSize {
        guard oldDrawn.width > 0, oldDrawn.height > 0 else { return .zero }
        let ux = (point.x - container.width / 2 - pan.width) / oldDrawn.width + 0.5
        let uy = (point.y - container.height / 2 - pan.height) / oldDrawn.height + 0.5
        guard ux.isFinite, uy.isFinite else { return .zero }
        let cx = Swift.min(Swift.max(ux, 0), 1)
        let cy = Swift.min(Swift.max(uy, 0), 1)
        let px = point.x - container.width / 2 - (cx - 0.5) * newDrawn.width
        let py = point.y - container.height / 2 - (cy - 0.5) * newDrawn.height
        return CGSize(width: px.isFinite ? px : 0, height: py.isFinite ? py : 0)
    }
}

// MARK: - Progressive refine

/// Drives one photo's two-tier render and publishes exactly what is on screen plus the
/// honest facts about it. Shared by the loupe and by every compare pane, because a
/// second preview system is how the two drift apart.
///
/// Generation numbers are the whole stale-result defence: every request takes the next
/// number, `latestGeneration` records it, and a result whose generation is not the
/// latest is dropped before it can be assigned. The coordinator carries the number back
/// so a request superseded inside the actor is discarded there too.
final class PhotoRenderModel: ObservableObject {

    @Published private(set) var image: CGImage?
    @Published private(set) var imageURL: URL?
    /// Bumped whenever `image` is replaced — a cheap `Equatable` handle for `.task(id:)`
    /// since `CGImage` is not `Equatable`.
    @Published private(set) var revision: Int = 0
    @Published private(set) var isDraft: Bool = false
    @Published private(set) var usedEmbeddedPreview: Bool = false
    /// Whatever the coordinator wants said out loud — "kernel library unavailable",
    /// "decoded from the embedded preview". Printed verbatim (docs/12: never
    /// "Something went wrong").
    @Published private(set) var note: String?
    @Published private(set) var isUnreadable: Bool = false

    /// The settle debounce before the quality pass. The refine budget is ≤200 ms after
    /// the drag pause (docs/12 §B2); 250 ms is the settle window plus the pass itself,
    /// and it is one constant so it can be retuned in one place.
    static let settleNanoseconds: UInt64 = 250_000_000

    /// How many times the quality pass will re-ask when it comes back empty. See the
    /// comment at the retry loop: nil from the coordinator can mean "superseded by a
    /// sibling viewer", which is not a failure and must not badge like one.
    static let qualityAttempts: Int = 3

    @MainActor private static var generationCounter: UInt64 = 0

    @MainActor
    private static func nextGeneration() -> UInt64 {
        generationCounter &+= 1
        return generationCounter
    }

    private var latestGeneration: UInt64 = 0

    /// Request a render of `url` under `recipe`. Draft first so the frame is honest
    /// within one frame, quality after the settle pause. Both passes come from the same
    /// pipeline at two resolutions, so refine is visually monotone — quality improves,
    /// the picture never pops brighter or darker.
    @MainActor
    func load(url: URL,
              recipe: Recipe,
              coordinator: RenderCoordinator,
              thumbnails: ThumbnailLoader?,
              draftLongEdge: Int,
              fullLongEdge: Int,
              strokeSets: [String: BrushStrokeSet] = [:],
              showingUncropped: Bool = false) async {

        // New photo: drop the previous photo's pixels rather than showing them under a
        // new filename, and give this one the instant embedded-preview path (Law 11).
        if imageURL != url {
            image = nil
            imageURL = nil
            isDraft = false
            usedEmbeddedPreview = false
            isUnreadable = false
            note = nil
            revision &+= 1
            if let thumbnails,
               let preview = await thumbnails.load(url: url, maxPixel: 1600),
               let cg = preview.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                guard !Task.isCancelled else { return }
                image = cg
                imageURL = url
                usedEmbeddedPreview = true
                isDraft = true
                revision &+= 1
            }
        }

        let draftGeneration: UInt64 = PhotoRenderModel.nextGeneration()
        latestGeneration = draftGeneration
        let draft = await coordinator.render(url: url, recipe: recipe,
                                             maxLongEdge: Swift.max(draftLongEdge, 64),
                                             draft: true, generation: draftGeneration,
                                             strokeSets: strokeSets,
                                             showingUncropped: showingUncropped)
        guard !Task.isCancelled else { return }
        if let draft, draft.generation == latestGeneration {
            apply(draft, url: url)
        }

        try? await Task.sleep(nanoseconds: PhotoRenderModel.settleNanoseconds)
        guard !Task.isCancelled, latestGeneration == draftGeneration else { return }

        // The quality pass, with a bounded retry. The coordinator supersedes by
        // generation across *every* viewer sharing it, so a compare pane can lose the
        // race to a sibling pane and get a nil that means "superseded", not "failed".
        // Retrying a few times when there is nothing honest on screen turns that into a
        // slower first paint rather than a false "can't read this file".
        var attempt: Int = 0
        while attempt < PhotoRenderModel.qualityAttempts {
            let generation: UInt64 = PhotoRenderModel.nextGeneration()
            latestGeneration = generation
            let result = await coordinator.render(url: url, recipe: recipe,
                                                  maxLongEdge: Swift.max(fullLongEdge, 64),
                                                  draft: false, generation: generation,
                                                  strokeSets: strokeSets,
                                                  showingUncropped: showingUncropped)
            guard !Task.isCancelled else { return }
            if let result, result.generation == generation, latestGeneration == generation {
                apply(result, url: url)
                return
            }
            // Something newer of ours is already in flight: that request owns the frame.
            guard latestGeneration == generation else { return }
            // A draft of this very recipe is already up. It is the edit, just coarser —
            // keep it rather than churning the queue.
            if image != nil, !usedEmbeddedPreview { return }
            attempt += 1
            try? await Task.sleep(nanoseconds: UInt64(attempt) * 60_000_000)
            guard !Task.isCancelled else { return }
        }

        // Nothing came back and nothing honest is on screen: say so instead of spinning.
        if image == nil {
            isUnreadable = true
            note = "Can't render \(url.lastPathComponent) — no RAW decode and no embedded preview"
        }
    }

    @MainActor
    private func apply(_ result: RenderResult, url: URL) {
        image = result.image
        imageURL = url
        isDraft = result.isDraft
        usedEmbeddedPreview = result.usedEmbeddedPreview
        note = result.note
        isUnreadable = false
        revision &+= 1
    }
}

// MARK: - Loupe

struct LoupeView: View {

    @EnvironmentObject var state: AppState
    let photo: PhotoItem

    /// Everything that should trigger a re-render, cheap to compare (`Recipe` is
    /// `Equatable` — no fingerprint hashing on the main actor per body pass).
    private struct RenderKey: Equatable {
        let url: URL
        let recipe: Recipe
        let longEdge: Int
        /// Which brush blobs are actually in memory right now.
        ///
        /// The render consumes stroke sets that are passed alongside the recipe rather
        /// than contained in it — a `strokesRef` is a promise that bytes exist, not the
        /// bytes — and they arrive asynchronously: `loadStrokeSets` reads the blobs off
        /// the actor and publishes them into `strokeCache`. That publish re-evaluates
        /// `body`, but `.task(id:)` only restarts when the id CHANGES, and the id did
        /// not mention them. So selecting a photo whose mask uses a brush painted in an
        /// earlier session rendered with that component contributing nothing, and stayed
        /// that way until some unrelated edit moved the recipe. This is the same shape
        /// as a fingerprint that omits a field the render reads.
        let strokeRefs: Set<String>
    }

    /// Above this we stop asking for more pixels; a real 1:1 on a 45 MP frame is the
    /// tiled Metal viewport's job, and the badge says which one you are looking at.
    static let maxRenderLongEdge: Int = 4096
    static let draftLongEdge: Int = 1024

    @StateObject private var model: PhotoRenderModel = PhotoRenderModel()
    @StateObject private var beforeModel: PhotoRenderModel = PhotoRenderModel()
    @ObservedObject private var viewport: LoupeViewport = LoupeViewport.shared

    @State private var containerSize: CGSize = .zero
    @State private var cursor: CGPoint?
    @State private var panStart: CGSize?
    @State private var sampler: PixelSampler?

    @Environment(\.displayScale) private var displayScale: CGFloat
    @FocusState private var focused: Bool

    private var recipe: Recipe { state.recipe(for: photo) }

    /// "Before" is just another recipe through the same pipeline (docs/12 §B8): the
    /// import default, i.e. an empty recipe at this photo's pipeline version.
    private var beforeRecipe: Recipe { Recipe(pipelineVersion: recipe.pipelineVersion) }

    private var needsBeforeRender: Bool {
        state.showBefore || viewport.beforeMode.showsPair
    }

    var body: some View {
        GeometryReader { geometry in
            let container: CGSize = geometry.size
            let longEdge: Int = requestedLongEdge(container: container)
            ZStack(alignment: .bottomLeading) {
                Lumen.viewerBackground
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                content(container: container)

                badges
                    .padding(10)

                if let cursor, let sample = readout(at: cursor, container: container) {
                    ReadoutHUD(sample: sample)
                        .position(hudPosition(for: cursor, container: container))
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .contentShape(Rectangle())
            .gesture(dragGesture(container: container))
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point):
                    viewport.lastCursor = point
                    cursor = viewport.showReadout ? point : nil
                case .ended:
                    cursor = nil
                }
            }
            .onAppear {
                containerSize = container
                focused = true
            }
            .onChange(of: container) { _, newValue in
                containerSize = newValue
            }
            .onChange(of: state.zoomLevel) { oldValue, newValue in
                applyZoomChange(from: oldValue, to: newValue, container: container)
            }
            // `.task`'s action is `@Sendable`, so it touches no main-actor state
            // directly: everything goes through the `@MainActor` methods below.
            .task(id: RenderKey(url: photo.id, recipe: recipe, longEdge: longEdge,
                                strokeRefs: Set(state.strokeSets(for: recipe).keys))) {
                await renderCurrent(longEdge: longEdge)
            }
            .task(id: BeforeKey(url: photo.id, recipe: beforeRecipe,
                                wanted: needsBeforeRender, longEdge: longEdge,
                                strokeRefs: Set(state.strokeSets(for: beforeRecipe).keys))) {
                await renderBefore(longEdge: longEdge)
            }
            .task(id: model.revision) {
                await rebuildSampler()
            }
        }
        .background(Lumen.viewerBackground)
        .focusable()
        .focused($focused)
        .onMoveCommand { direction in handleMove(direction) }
        .onChange(of: photo.id) { _, _ in
            viewport.resetForNewPhoto()
            sampler = nil
        }
    }

    private struct BeforeKey: Equatable {
        let url: URL
        let recipe: Recipe
        let wanted: Bool
        let longEdge: Int
        /// See `RenderKey.strokeRefs`: the before rendition is passed stroke sets the
        /// same way and goes stale in the same way without them.
        let strokeRefs: Set<String>
    }

    // MARK: Render entry points

    @MainActor
    private func renderCurrent(longEdge: Int) async {
        await model.load(url: photo.id,
                         recipe: recipe,
                         coordinator: state.renderCoordinator,
                         thumbnails: state.thumbnails,
                         draftLongEdge: LoupeView.draftLongEdge,
                         fullLongEdge: longEdge,
                         strokeSets: state.strokeSets(for: recipe),
                         // While the crop tool is open the loupe shows the frame
                         // WITHOUT its crop, so the rectangle being dragged is drawn
                         // against the frame it is expressed in.
                         showingUncropped: viewport.showCrop
                             && state.activeSection == .effects)
    }

    /// The before rendition, evaluated through the same pipeline as the edit so the
    /// flip is a comparison and not a different renderer's opinion.
    @MainActor
    private func renderBefore(longEdge: Int) async {
        guard needsBeforeRender else { return }
        // Let the edited rendition claim the coordinator's generation lane first: it
        // supersedes by number, and the picture being edited must never lose that race
        // to its own before state.
        try? await Task.sleep(nanoseconds: 40_000_000)
        guard !Task.isCancelled, needsBeforeRender else { return }
        await beforeModel.load(url: photo.id,
                               recipe: beforeRecipe,
                               coordinator: state.renderCoordinator,
                               thumbnails: nil,
                               draftLongEdge: LoupeView.draftLongEdge,
                               fullLongEdge: longEdge,
                               strokeSets: state.strokeSets(for: beforeRecipe))
    }

    // MARK: Content

    @ViewBuilder
    private func content(container: CGSize) -> some View {
        if let cg = model.image, model.imageURL == photo.id {
            if viewport.beforeMode.isTwoPane, let before = beforeImage {
                // Two-pane compare fits each side in its own half: pan and zoom belong
                // to the split view, which shares one set of tiles.
                BeforeAfterPair(mode: viewport.beforeMode, before: before, after: cg)
                    .frame(width: container.width, height: container.height)
            } else {
                canvas(cg: cg, container: container)
            }
        } else if model.isUnreadable {
            unreadable
                .frame(width: container.width, height: container.height)
        } else {
            // Progress ladder (docs/12 §B2): under one second, nothing. No spinner,
            // no flash — the embedded preview normally lands first anyway.
            Color.clear
                .frame(width: container.width, height: container.height)
        }
    }

    private var beforeImage: CGImage? {
        guard beforeModel.imageURL == photo.id else { return nil }
        return beforeModel.image
    }

    /// The mask component the on-image canvas should edit, if any. Nil whenever the
    /// selection is stale — a mask deleted from under the canvas must make it inert,
    /// not make it index into nothing.
    private var maskEditTarget: (maskID: String, index: Int, component: MaskComponent?)? {
        guard let id = state.activeMaskID,
              let mask = recipe.masks.first(where: { $0.id == id }) else { return nil }
        let index = state.activeComponentIndex
        guard mask.components.indices.contains(index) else {
            return (mask.id, 0, nil)
        }
        return (mask.id, index, mask.components[index])
    }

    /// The stroke set already stored for a component, or an empty one when the
    /// component genuinely has no strokes yet.
    ///
    /// `AppState.strokeSet(ref:)` now reaches the blob store when memory misses, so an
    /// empty set here means empty rather than not-yet-loaded. That distinction is the
    /// whole safety of this call: the canvas APPENDS to what it is given and writes the
    /// result back, so handing it an empty set for a component that does have strokes
    /// replaces them all with the next stroke.
    private func existingStrokes(_ component: MaskComponent?) -> BrushStrokeSet {
        state.strokeSet(ref: component?.strokesRef) ?? BrushStrokeSet()
    }

    @ViewBuilder
    private func canvas(cg: CGImage, container: CGSize) -> some View {
        let ratio: Double = effectiveRatio(image: cg, container: container)
        let drawn: CGSize = LoupeGeometry.drawnSize(imageWidth: cg.width,
                                                    imageHeight: cg.height,
                                                    ratio: ratio,
                                                    displayScale: displayScale)
        let offset: CGSize = LoupeGeometry.clampPan(viewport.pan,
                                                    container: container, drawn: drawn)

        ZStack {
            imageLayer(cg: cg, ratio: ratio, drawn: drawn)

            if let mode = state.clippingOverlay, let sampler {
                ClippingOverlayView(sampler: sampler, mode: mode)
                    .frame(width: drawn.width, height: drawn.height)
            }

            // The real alpha, not nil. Passing nil made MaskOverlayView fall back to a
            // flat tint over the whole frame, which reads as "this mask selects
            // everything" — and this button is the app's only way to look at a mask.
            // The sampler goes in too: four of the six modes redraw the UNMASKED
            // pixels (grey, black or white), which needs the picture.
            if state.soloMaskOverlay != nil, let alpha = state.maskOverlayAlpha {
                MaskOverlayView(alpha: alpha, sampler: sampler,
                                geometry: recipe.develop.geometry,
                                sourceSize: state.primaryFrameSize
                                    ?? CGSize(width: cg.width, height: cg.height),
                                mode: state.maskOverlayMode, tint: state.maskOverlayTint,
                                strength: viewport.maskOverlayOpacity)
                    .frame(width: drawn.width, height: drawn.height)
            }

            // Reachable again, and correct this time. The renderer is asked for the
            // frame WITHOUT its crop while this is open (`showingUncropped`), so the
            // rectangle is drawn against the frame it is expressed in rather than
            // inside a picture that has already been cut to it.
            if viewport.showCrop && state.activeSection == .effects {
                CropOverlayView(crop: cropBinding)
                    .frame(width: drawn.width, height: drawn.height)
            }

            // Mask geometry is edited on the image, not in the panel: gradients,
            // radials and brush strokes are placed where they land. The canvas is
            // inert unless the masks section is open with a drawable component
            // selected, so it never eats a pan or a click-to-zoom.
            if state.activeSection == .masks, let target = maskEditTarget {
                // The strokes already on this component have to go IN as well as come
                // out: the canvas appends to the set it was given, so handing it an
                // empty one makes every stroke the only stroke.
                // `sourceSize` is the SOURCE frame, not `cg`. `cg` is the preview,
                // which the renderer has already cropped and straightened; passing its
                // extent here told the canvas the crop WAS the whole photo, so every
                // gesture on a cropped frame was stored against the wrong rectangle.
                // The geometry goes in alongside it so the canvas can invert exactly
                // what the renderer applied.
                MaskCanvas(imageRect: CGRect(origin: .zero, size: drawn),
                           sourceSize: state.primaryFrameSize
                               ?? CGSize(width: cg.width, height: cg.height),
                           geometry: recipe.develop.geometry,
                           maskID: target.maskID,
                           componentIndex: target.index,
                           component: target.component,
                           strokes: existingStrokes(target.component)) { edit in
                    MaskCanvas.apply(edit, in: state)
                }
                .frame(width: drawn.width, height: drawn.height)
            }

            // Last in the stack so it sits above the mask canvas and the crop tool:
            // while a pick is in flight the click belongs to the eyedropper and to
            // nothing else. `sourceSize` is the SOURCE frame for the same reason the
            // canvas needs it — `cg` has already been cropped and straightened.
            if state.pickTarget != nil {
                NeutralPickerOverlay(
                    sourceSize: state.primaryFrameSize
                        ?? CGSize(width: cg.width, height: cg.height),
                    geometry: recipe.develop.geometry
                ) { sourceX, sourceY in
                    state.resolvePick(on: photo, sourceX: sourceX, sourceY: sourceY)
                }
                .frame(width: drawn.width, height: drawn.height)
            }
        }
        .frame(width: drawn.width, height: drawn.height)
        .offset(offset)
        .frame(width: container.width, height: container.height)
        .clipped()
    }

    /// The image itself, honouring the before/after presentation that shares this
    /// canvas's geometry (flip and split; the two-pane modes are handled upstream).
    @ViewBuilder
    private func imageLayer(cg: CGImage, ratio: Double, drawn: CGSize) -> some View {
        if viewport.beforeMode == .split, let before = beforeImage {
            BeforeAfterSplit(split: $viewport.splitPosition) {
                plate(before, ratio: ratio, drawn: drawn)
            } after: {
                plate(cg, ratio: ratio, drawn: drawn)
            }
            .frame(width: drawn.width, height: drawn.height)
        } else if state.showBefore, let before = beforeImage {
            plate(before, ratio: ratio, drawn: drawn)
        } else {
            plate(cg, ratio: ratio, drawn: drawn)
        }
    }

    /// One drawn plate. Interpolation is off at ratios ≥ 1 so a 1:1 inspection shows
    /// the pixels that exist rather than a smoothed guess at them; below 1 the
    /// downscale is filtered, because nearest-neighbour minification is aliasing.
    private func plate(_ cg: CGImage, ratio: Double, drawn: CGSize) -> some View {
        Image(decorative: cg, scale: 1, orientation: .up)
            .resizable()
            .interpolation(ratio >= 1 ? .none : .high)
            .antialiased(ratio < 1)
            .frame(width: drawn.width, height: drawn.height)
    }

    private var unreadable: some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30))
            Text("Can't read \(photo.filename)")
                .font(.system(size: 12))
        }
        .foregroundStyle(Lumen.secondaryText)
    }

    // MARK: Badges

    private var badges: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.usedEmbeddedPreview, model.imageURL == photo.id {
                // Never silently show something that is not the edit.
                LumenBadge(text: "EMBEDDED PREVIEW", emphasized: true)
            }
            if let note = model.note {
                LumenBadge(text: note, emphasized: true)
            }
            if state.showBefore, beforeImage != nil, !viewport.beforeMode.showsPair {
                LumenBadge(text: "BEFORE")
            }
            if let maskName = soloMaskName {
                LumenBadge(text: "MASK · \(maskName)")
            }
            if let mode = state.clippingOverlay {
                LumenBadge(text: "CLIPPING · \(mode.rawValue.uppercased())")
            }
            if state.zoomLevel >= 1, let cg = model.image {
                // At 1:1 and above the pixels on screen are the render proxy's, not the
                // sensor's — say which, rather than implying a full-resolution loupe.
                LumenBadge(text: "\(LoupeZoom.label(state.zoomLevel)) · PROXY \(cg.width)×\(cg.height)")
            } else {
                LumenBadge(text: LoupeZoom.label(state.zoomLevel))
            }
        }
        .allowsHitTesting(false)
    }

    private var soloMaskName: String? {
        guard let id = state.soloMaskOverlay else { return nil }
        if let named = recipe.masks.first(where: { $0.id == id }), !named.name.isEmpty {
            return named.name
        }
        return String(id.prefix(8))
    }

    // MARK: Zoom / pan

    private func effectiveRatio(image: CGImage, container: CGSize) -> Double {
        if state.zoomLevel > 0 { return state.zoomLevel }
        return LoupeGeometry.fitRatio(imageWidth: image.width, imageHeight: image.height,
                                      container: container, displayScale: displayScale)
    }

    /// Keeps the anchor point pinned across a zoom change, then re-clamps the pan.
    private func applyZoomChange(from oldValue: Double, to newValue: Double,
                                 container: CGSize) {
        guard let cg = model.image else {
            viewport.pan = .zero
            return
        }
        let oldRatio: Double = oldValue > 0
            ? oldValue
            : LoupeGeometry.fitRatio(imageWidth: cg.width, imageHeight: cg.height,
                                     container: container, displayScale: displayScale)
        let newRatio: Double = newValue > 0
            ? newValue
            : LoupeGeometry.fitRatio(imageWidth: cg.width, imageHeight: cg.height,
                                     container: container, displayScale: displayScale)
        let oldDrawn = LoupeGeometry.drawnSize(imageWidth: cg.width, imageHeight: cg.height,
                                               ratio: oldRatio, displayScale: displayScale)
        let newDrawn = LoupeGeometry.drawnSize(imageWidth: cg.width, imageHeight: cg.height,
                                               ratio: newRatio, displayScale: displayScale)
        let anchor: CGPoint? = viewport.anchorNextZoomAtCursor ? viewport.lastCursor : nil
        let target: CGPoint = anchor
            ?? CGPoint(x: container.width / 2, y: container.height / 2)
        let kept = LoupeGeometry.panKeeping(target, container: container,
                                            oldDrawn: oldDrawn, newDrawn: newDrawn,
                                            pan: viewport.pan)
        viewport.pan = LoupeGeometry.clampPan(kept, container: container, drawn: newDrawn)
        viewport.anchorNextZoomAtCursor = true
    }

    /// One gesture covers both jobs: a drag pans when the image overflows the viewport,
    /// and a press that never really moved is a click-to-zoom at that point.
    private func dragGesture(container: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                viewport.lastCursor = value.location
                if viewport.showReadout { cursor = value.location }
                guard let cg = model.image else { return }
                let ratio = effectiveRatio(image: cg, container: container)
                let drawn = LoupeGeometry.drawnSize(imageWidth: cg.width,
                                                    imageHeight: cg.height,
                                                    ratio: ratio,
                                                    displayScale: displayScale)
                guard drawn.width > container.width || drawn.height > container.height else {
                    return
                }
                if panStart == nil { panStart = viewport.pan }
                let base: CGSize = panStart ?? .zero
                let moved = CGSize(width: base.width + value.translation.width,
                                   height: base.height + value.translation.height)
                viewport.pan = LoupeGeometry.clampPan(moved, container: container, drawn: drawn)
            }
            .onEnded { value in
                let travel = abs(value.translation.width) + abs(value.translation.height)
                panStart = nil
                if travel < 3 {
                    viewport.toggleZoom(at: value.location, in: state)
                }
            }
    }

    /// Arrows page the selection at fit, and pan when zoomed in — the key means the
    /// thing you are looking at, which is the keymap's scope rule (docs/12 §B3).
    private func handleMove(_ direction: MoveCommandDirection) {
        let step: CGFloat = 80
        if state.zoomLevel > 0 {
            switch direction {
            case .left: viewport.panBy(CGSize(width: step, height: 0))
            case .right: viewport.panBy(CGSize(width: -step, height: 0))
            case .up: viewport.panBy(CGSize(width: 0, height: step))
            case .down: viewport.panBy(CGSize(width: 0, height: -step))
            @unknown default: break
            }
            let drawn: CGSize = model.image.map {
                LoupeGeometry.drawnSize(imageWidth: $0.width, imageHeight: $0.height,
                                        ratio: state.zoomLevel, displayScale: displayScale)
            } ?? containerSize
            viewport.pan = LoupeGeometry.clampPan(viewport.pan,
                                                  container: containerSize, drawn: drawn)
            return
        }
        switch direction {
        case .left: state.selectPrevious()
        case .right: state.selectNext()
        default: break
        }
    }

    // MARK: Render sizing

    /// How many pixels to ask the coordinator for. At fit that is the viewport in
    /// device pixels, quantized to 256-px buckets so a window resize does not spam the
    /// render queue; zoomed in we ask for the cap and badge the result honestly.
    private func requestedLongEdge(container: CGSize) -> Int {
        if state.zoomLevel > 0 { return LoupeView.maxRenderLongEdge }
        let scale = Double(Swift.max(displayScale, 1))
        let longEdge = Double(Swift.max(container.width, container.height)) * scale
        guard longEdge.isFinite, longEdge > 0 else { return 1024 }
        let bucket = Int((longEdge / 256).rounded(.up)) * 256
        return Swift.min(Swift.max(bucket, 640), LoupeView.maxRenderLongEdge)
    }

    // MARK: Readout

    @MainActor
    private func rebuildSampler() async {
        guard let cg = model.image else {
            sampler = nil
            return
        }
        let built: PixelSampler? = await Task.detached(priority: .utility) {
            PixelSampler.make(from: cg)
        }.value
        guard !Task.isCancelled else { return }
        sampler = built
    }

    private func readout(at point: CGPoint, container: CGSize) -> ReadoutSample? {
        guard viewport.showReadout, let cg = model.image, let sampler else { return nil }
        let ratio = effectiveRatio(image: cg, container: container)
        let drawn = LoupeGeometry.drawnSize(imageWidth: cg.width, imageHeight: cg.height,
                                            ratio: ratio, displayScale: displayScale)
        let pan = LoupeGeometry.clampPan(viewport.pan, container: container, drawn: drawn)
        guard let unit = LoupeGeometry.imageUnitPoint(point, container: container,
                                                      drawn: drawn, pan: pan) else {
            return nil
        }
        return sampler.readout(u: Double(unit.x), v: Double(unit.y),
                               space: state.readoutSpace)
    }

    /// Keeps the pill on screen: it rides above-right of the cursor unless that would
    /// push it past an edge.
    private func hudPosition(for point: CGPoint, container: CGSize) -> CGPoint {
        let width: CGFloat = 190
        let height: CGFloat = 54
        var x = point.x + width / 2 + 18
        var y = point.y - height / 2 - 18
        if x + width / 2 > container.width { x = point.x - width / 2 - 18 }
        if y - height / 2 < 0 { y = point.y + height / 2 + 18 }
        x = Swift.min(Swift.max(x, width / 2), Swift.max(container.width - width / 2, width / 2))
        y = Swift.min(Swift.max(y, height / 2), Swift.max(container.height - height / 2, height / 2))
        return CGPoint(x: x, y: y)
    }

    // MARK: Crop

    /// Dragging the crop rectangle writes through `updateRecipe` with a coalescing key,
    /// exactly like the crop panel's sliders — one drag is one undo step, and the on-image
    /// gesture inherits that rather than reimplementing it (docs/12 §B6).
    private var cropBinding: Binding<Crop> {
        let state = self.state
        let photo = self.photo
        return Binding(
            get: { state.recipe(for: photo).develop.geometry.crop },
            set: { newValue in
                state.updateRecipe(coalescingKey: "crop") { recipe in
                    recipe.develop.geometry.crop = newValue
                }
            }
        )
    }
}

#endif
