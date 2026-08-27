// LoupeView.swift
// The loupe: Lumen's main image viewer. It draws the CGImage the render coordinator
// returns, at an explicit zoom ratio (fit / 1:1 / 2:1 / click-to-zoom-at-point) with
// drag-to-pan when the drawn image is larger than the viewport.
//
// Three behaviours this file exists to keep honest:
//   · Two-tier progressive refine (docs/12 §B2): a draft pass lands within a frame,
//     the quality pass once a short debounce says the hand has stopped. The whole of
//     it — debounce plus both passes — is budgeted at 200 ms from the last input, and
//     the split between the debounce and the passes is `RefineBudget` in LumenCore
//     rather than a bare sleep here. Stale results are discarded by generation number
//     and never reach the screen.
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
///
/// The arithmetic is `ZoomLadder` in LumenCore and this is the app's name for it. It
/// forwards rather than reimplementing: three surfaces zoom — the loupe, the compare
/// panes and the keymap — and every time one of them has computed its own next ratio,
/// the mouse and the keyboard have ended up on different ladders.
enum LoupeZoom {
    static let fit: Double = ZoomLadder.fit
    static let oneToOne: Double = ZoomLadder.oneToOne
    static let twoToOne: Double = ZoomLadder.twoToOne

    /// What `cycleZoom` walks through.
    static let ladder: [Double] = ZoomLadder.ladder

    static func label(_ ratio: Double) -> String { ZoomLadder.label(ratio) }
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
    /// Width ÷ height in pixels the crop drag must hold, or nil for a free crop.
    ///
    /// Set by the ratio menu and cleared by "Original", so it is a mode the user chose
    /// rather than one inferred from whatever the rectangle happens to measure. Inferring
    /// it would mean a free crop that lands within a rounding error of 16:9 silently
    /// stops letting you nudge one edge.
    ///
    /// UI state, not recipe state: the rectangle is what gets saved, and the lock only
    /// governs how the next drag behaves.
    @Published var cropAspectLock: Double?
    /// True while the straighten ruler is armed. It disarms itself when the drag ends,
    /// so it reads as a tool you fire rather than a mode you have to remember to leave.
    @Published var showStraighten: Bool = false
    @Published var showReadout: Bool = true
    /// Overlay tint strength. A `let`, not a `@Published var`: nothing ever set it, so
    /// it was a constant wearing a setting's clothes — observable state that could not
    /// be observed to change, in a batch whose thesis was reachability. If it becomes
    /// adjustable it goes back to being published, with a control that writes it.
    static let maskOverlayOpacity: Double = 0.45

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
        let clamped: Double = ZoomLadder.clamp(ratio)
        if ZoomLadder.isFit(clamped) { pan = .zero }
        state.zoomLevel = clamped
    }

    @MainActor
    func setZoom(_ ratio: Double, in state: AppState) {
        setZoom(ratio, at: lastCursor, in: state)
    }

    /// `Space` and `Z`: fit ↔ 1:1, centred on the cursor (docs/12 §B15 defaults).
    ///
    /// Space reaches this now. It used to set `state.zoomLevel` from the keymap
    /// directly — `zoomLevel == 0 ? 1 : 0` — which is the same ratio and none of the
    /// anchoring, so the one key whose documentation promised "centred on the cursor"
    /// was the one key that zoomed about the middle of the window.
    @MainActor
    func toggleZoom(at point: CGPoint?, in state: AppState) {
        let target: Double = ZoomLadder.toggleTarget(from: state.zoomLevel)
        let anchor: CGPoint? = ZoomLadder.anchorsAtCursor(target: target)
            ? (point ?? lastCursor)
            : nil
        setZoom(target, at: anchor, in: state)
    }

    @MainActor
    func toggleZoom(in state: AppState) { toggleZoom(at: lastCursor, in: state) }

    /// Walks fit → 1:1 → 2:1 → fit.
    @MainActor
    func cycleZoom(in state: AppState) {
        let target: Double = ZoomLadder.cycleTarget(from: state.zoomLevel)
        setZoom(target, at: ZoomLadder.anchorsAtCursor(target: target) ? lastCursor : nil,
                in: state)
    }

    @MainActor
    func fit(in state: AppState) { setZoom(LoupeZoom.fit, at: nil, in: state) }

    @MainActor
    func oneToOne(in state: AppState) { setZoom(LoupeZoom.oneToOne, at: lastCursor, in: state) }

    @MainActor
    func twoToOne(in state: AppState) { setZoom(LoupeZoom.twoToOne, at: lastCursor, in: state) }

    @MainActor
    func zoomIn(in state: AppState) {
        setZoom(ZoomLadder.zoomInTarget(from: state.zoomLevel), at: lastCursor, in: state)
    }

    @MainActor
    func zoomOut(in state: AppState) {
        guard !ZoomLadder.isFit(state.zoomLevel) else { return }
        let target: Double = ZoomLadder.zoomOutTarget(from: state.zoomLevel)
        setZoom(target, at: ZoomLadder.anchorsAtCursor(target: target) ? lastCursor : nil,
                in: state)
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

    /// The draw ratio while zoomed. `zoomLevel` means "one FULL-RESOLUTION pixel to
    /// this many display pixels" — but the rendered image on screen is whatever proxy
    /// the render path could afford: the ladder-capped draft, the instant embedded
    /// preview, or the settle itself. Multiplying the proxy's own pixel count by the
    /// bare zoom level drew a 1024px draft and a 4600px settle at a 4.5× different
    /// on-screen size, which during a drag is every mouse event — the owner's
    /// "glitches all over the place", and MAC-07's face. Normalizing by
    /// full/rendered pins every proxy to the extent the settle will occupy, so what
    /// changes between draft and settle is sharpness alone — the same contract fit
    /// mode always had.
    static func zoomedRatio(zoomLevel: Double, fullLongEdge: Int,
                            renderedLongEdge: Int) -> Double {
        guard zoomLevel > 0 else { return 1 }
        guard fullLongEdge > 0, renderedLongEdge > 0 else { return zoomLevel }
        let r = zoomLevel * Double(fullLongEdge) / Double(renderedLongEdge)
        return r.isFinite && r > 0 ? r : zoomLevel
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
/// Generation numbers order everything: every request takes the next number, and the
/// two rules of `FrameDelivery` (LumenCore) are applied against them — a request that
/// is already superseded is dropped BEFORE it renders, but a frame that has finished
/// rendering is delivered whatever happened to its task, guarded only by identity
/// (still the photograph on screen) and order (newer than what is showing). The
/// second rule is why a drag reads as a slope: its events cancel the running task
/// faster than any render finishes, and the discipline that discarded those finished
/// frames froze the picture until the hand paused.
final class PhotoRenderModel: ObservableObject {

    @Published private(set) var image: CGImage?
    @Published private(set) var imageURL: URL?
    /// Bumped whenever `image` is replaced — a cheap `Equatable` handle for `.task(id:)`
    /// since `CGImage` is not `Equatable`.
    @Published private(set) var revision: Int = 0

    /// Which resolution the next draft renders at, learned from what drafts have been
    /// costing on THIS machine — `DraftLadder` in LumenCore, with tests. Per model, so
    /// a compare pane's small frames never teach the loupe's ladder anything.
    private var draftLadder = DraftLadder()

    /// What the zoomed draw normalizes against (`LoupeGeometry.zoomedRatio`): the
    /// settle's ACTUAL pixel long edge once one has landed for the current request,
    /// and the request's target until then. Reset when the request changes — a fit
    /// settle is a proxy for the zoomed target, not the authority on it; the estimate
    /// is only wrong (briefly, by the native-size shortfall) for a photo smaller than
    /// the request, and the first zoomed settle corrects it.
    private var settledActualLongEdge: Int?
    private var requestedFullLongEdge: Int = 0
    var displayFullLongEdge: Int? {
        settledActualLongEdge ?? (requestedFullLongEdge > 0 ? requestedFullLongEdge : nil)
    }
    @Published private(set) var isDraft: Bool = false
    @Published private(set) var usedEmbeddedPreview: Bool = false
    /// Whatever the coordinator wants said out loud — "kernel library unavailable",
    /// "decoded from the embedded preview". Printed verbatim (docs/12: never
    /// "Something went wrong").
    @Published private(set) var note: String?
    @Published private(set) var isUnreadable: Bool = false

    /// The settle debounce before the quality pass.
    ///
    /// It used to be 250 ms, under a comment claiming that 250 ms "is the settle window
    /// plus the pass itself". It was not, and the order of the statements below says
    /// so: the sleep runs and THEN the quality pass is asked for, so full quality
    /// landed at 250 ms plus render time against a docs/12 budget of 200 ms — a loop
    /// that no render could meet, however fast. The comment described a design nobody
    /// had written.
    ///
    /// The constant now comes from `RefineBudget`, which splits the 200 ms into the
    /// debounce and what is left for the passes, and asserts in LumenCore that the
    /// first is a small fraction of the second. What is still unmeasured is whether a
    /// real pass fits in the remainder; that is audit UX-01, and it needs a Mac.
    static let settleNanoseconds: UInt64 = RefineBudget.loupe.settleNanoseconds

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

    /// The url of the most recent `load` call — the user's current intent, whatever
    /// state its task is in. `FrameDelivery.shouldShow`'s identity input: a completed
    /// frame for any other photograph must never be applied, however fresh.
    private var currentRequestURL: URL?
    /// Generation of the newest frame actually applied — `shouldShow`'s order input,
    /// so a slow old render can never overwrite a newer picture.
    private var appliedGeneration: UInt64 = 0

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
              showingUncropped: Bool = false,
              softProof: SoftProof? = nil) async {

        currentRequestURL = url

        // New photo: drop the previous photo's pixels rather than showing them under a
        // new filename, and give this one the instant embedded-preview path (Law 11).
        if imageURL != url {
            image = nil
            imageURL = nil
            isDraft = false
            usedEmbeddedPreview = false
            isUnreadable = false
            note = nil
            settledActualLongEdge = nil
            revision &+= 1
            if let thumbnails,
               let preview = await thumbnails.load(
                   url: url, maxPixel: ThumbnailLadder.loupeInstantPixels),
               let cg = preview.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                guard !Task.isCancelled else { return }
                image = cg
                imageURL = url
                usedEmbeddedPreview = true
                isDraft = true
                revision &+= 1
            }
        }

        // A new full-resolution target (zoom changed the request) outdates the old
        // settle's authority over the zoomed draw scale.
        if requestedFullLongEdge != fullLongEdge {
            requestedFullLongEdge = fullLongEdge
            settledActualLongEdge = nil
        }

        let draftGeneration: UInt64 = PhotoRenderModel.nextGeneration()
        latestGeneration = draftGeneration
        // Half the settled request, floored at the old fixed size: enough that the
        // draft reads as the same photograph at fit, cheap enough to stay ahead of the
        // cursor. The colour is now identical to the settle by construction, so what
        // remains between draft and settle is sharpness alone — which reads as the
        // picture resolving rather than as the picture changing.
        // Half the settled request, floored at the zoom-aware draft size — then capped
        // by the ladder's current rung, which is the one lever left now that a draft
        // runs the full pipeline: a machine whose drafts run hot steps down within one
        // frame, one with headroom earns the top rung back over a streak.
        let draftRequested = Swift.max(draftLongEdge, fullLongEdge / 2)
        let draftTarget = draftLadder.longEdge(requested: draftRequested)
        let draftStarted = DispatchTime.now().uptimeNanoseconds
        let draft = await coordinator.render(url: url, recipe: recipe,
                                             maxLongEdge: Swift.max(draftTarget, 64),
                                             draft: true, generation: draftGeneration,
                                             strokeSets: strokeSets,
                                             showingUncropped: showingUncropped,
                                             softProof: softProof)
        // Delivery BEFORE the cancellation check, deliberately — FrameDelivery in
        // LumenCore is the law and holds the arithmetic. During a drag every event
        // cancels this task and starts the next one, so "apply only if still current"
        // meant every completed draft of the gesture was rendered and then discarded,
        // and the picture moved only at pauses in the hand — the owner's "goes by
        // notches ... changes in one frame instead of a slope". A finished frame is
        // the freshest completed picture of the user's intent that exists; the only
        // questions are identity and order, and `shouldShow` asks exactly those.
        if let draft {
            // Wall time around the await, actor queueing included — queueing is what
            // a hand feels. The ladder learns from the same number the HUD shows,
            // and it learns from every completed draft, delivered or not: the cost
            // was real either way.
            let draftMs = Double(DispatchTime.now().uptimeNanoseconds - draftStarted) / 1e6
            draftLadder.record(draftMilliseconds: draftMs,
                               renderedLongEdge: Swift.max(draftTarget, 64),
                               requested: draftRequested)
            LatencyHUD.shared.noteDraft(milliseconds: draftMs,
                                        longEdge: Swift.max(draftTarget, 64))
            if FrameDelivery.shouldShow(frameFor: url,
                                        currentRequest: currentRequestURL,
                                        generation: draft.generation,
                                        newestShown: appliedGeneration) {
                apply(draft, url: url)
            }
        }
        guard !Task.isCancelled else { return }

        // The debounce, and nothing but the debounce: everything after this point still
        // has to happen inside the deadline, so the wait is the part of the budget that
        // buys the least and is kept the smallest.
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
            let settleStarted = DispatchTime.now().uptimeNanoseconds
            let result = await coordinator.render(url: url, recipe: recipe,
                                                  maxLongEdge: Swift.max(fullLongEdge, 64),
                                                  draft: false, generation: generation,
                                                  strokeSets: strokeSets,
                                                  showingUncropped: showingUncropped,
                                                  softProof: softProof)
            guard !Task.isCancelled else { return }
            if let result, result.generation == generation, latestGeneration == generation {
                apply(result, url: url)
                LatencyHUD.shared.noteSettle(
                    milliseconds: Double(DispatchTime.now().uptimeNanoseconds - settleStarted) / 1e6,
                    longEdge: Swift.max(fullLongEdge, 64))
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
        appliedGeneration = Swift.max(appliedGeneration, result.generation)
        image = result.image
        imageURL = url
        isDraft = result.isDraft
        usedEmbeddedPreview = result.usedEmbeddedPreview
        note = result.note
        isUnreadable = false
        if !result.isDraft {
            settledActualLongEdge = Swift.max(result.image.width, result.image.height)
        }
        revision &+= 1
    }
}

// MARK: - Loupe

struct LoupeView: View {

    @EnvironmentObject var state: AppState
    let photo: PhotoItem

    // The render key is `ViewerRenderKey` in RenderRequest.swift — shared with the
    // compare and survey panes so the beside-the-recipe inputs (brush blobs, mattes,
    // soft proof) can never again be in one surface's key and not another's.

    /// Above this we stop asking for more pixels; a real 1:1 on a 45 MP frame is the
    /// tiled Metal viewport's job, and the badge says which one you are looking at.
    static let maxRenderLongEdge: Int = 4096
    /// Floor for the draft pass. The draft now follows the VIEWPORT rather than being
    /// pinned here — a fixed 1024 was being blown up two to three times into a Retina
    /// loupe, so the frame under the cursor during a drag was soft as well as being a
    /// different colour, and both resolved only after the settle. This stays as the
    /// lower bound for a tiny window and as the fallback when the container size is not
    /// yet known.
    static let draftLongEdge: Int = 1024

    @StateObject private var model: PhotoRenderModel = PhotoRenderModel()
    @StateObject private var beforeModel: PhotoRenderModel = PhotoRenderModel()
    @ObservedObject private var viewport: LoupeViewport = LoupeViewport.shared

    @State private var containerSize: CGSize = .zero
    @State private var cursor: CGPoint?
    @State private var panStart: CGSize?
    /// When the current press began, so its release can tell a click from a hold. Nil
    /// between gestures.
    @State private var pressBegan: Date?
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
                warmNeighbours()
            }
            .onChange(of: container) { _, newValue in
                containerSize = newValue
            }
            .onChange(of: state.zoomLevel) { oldValue, newValue in
                applyZoomChange(from: oldValue, to: newValue, container: container)
            }
            // `.task`'s action is `@Sendable`, so it touches no main-actor state
            // directly: everything goes through the `@MainActor` methods below.
            .task(id: ViewerRenderKey.current(url: photo.id, recipe: recipe,
                                              longEdge: longEdge, state: state)) {
                await renderCurrent(longEdge: longEdge)
            }
            .task(id: BeforeKey(url: photo.id, recipe: beforeRecipe,
                                wanted: needsBeforeRender, longEdge: longEdge,
                                strokeRefs: Set(state.strokeSets(for: beforeRecipe).keys))) {
                await renderBefore(longEdge: longEdge)
            }
            .task(id: SamplerKey(revision: model.revision, needed: samplerNeeded)) {
                await rebuildSampler()
            }
        }
        .background(Lumen.viewerBackground)
        .focusable()
        .focused($focused)
        // The viewer must stay focusable — the whole bare-key culling grammar depends
        // on it holding keyboard focus, which is what `.onAppear { focused = true }`
        // above is for. What it must not do is let macOS draw its focus ring around it:
        // that ring is a saturated blue rectangle framing a photograph, and Law 7
        // (docs/00) makes chrome zero-chroma 18–25% grey precisely so that nothing in
        // the surround biases a colour judgement. It was the owner's first reaction to
        // the app — "I think we should remove that blue square" — and he read it as a
        // defect rather than as an affordance, which is the correct reading of a
        // permanent decoration that never changes.
        //
        // What is deliberately NOT replaced with a quieter indicator: nothing on screen
        // now says the viewer holds focus. The judgement is that the ring was not
        // answering the question a photographer actually has, which is not "does the
        // image have focus" but "why did my keys stop working" — and the answer to THAT
        // is always a text field having taken it, which the ring never said. An
        // indicator on the thing that took focus would be the honest fix; a blue
        // rectangle around the photograph is not it. Recorded here rather than silently
        // suppressed.
        .focusEffectDisabled()
        .onMoveCommand { direction in handleMove(direction) }
        .onChange(of: photo.id) { _, _ in
            viewport.resetForNewPhoto()
            sampler = nil
            warmNeighbours()
        }
    }

    /// Aim the ring at the level THIS view reads from, on every advance.
    ///
    /// The viewer used to depend entirely on the filmstrip for that, and the strip
    /// warmed its own 256 only — so the instant path's request landed in an empty
    /// bucket every single time. Warming from here as well means F, which hides the
    /// strip, hides the strip rather than also turning off the cache the paging budget
    /// is built on. The strip's call and this one aim the same window at the same
    /// cursor, so the second one costs a dictionary lookup per file.
    @MainActor
    private func warmNeighbours() {
        state.thumbnails.prefetch(around: photo.id,
                                  in: state.photos.map(\.id),
                                  size: ThumbnailLadder.loupeInstantPixels,
                                  surface: .loupe)
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
                         // Zoomed, a draft with fewer pixels than the settle is drawn
                         // SMALLER — the frame's size above fit is the proxy's extent
                         // times the ratio, so the shipped 2048-against-4096 pair drew
                         // the photograph at half size and then doubled it, on every
                         // render, which during a drag is every mouse event. The rule
                         // is `DraftResolution`, in LumenCore, with tests; at fit it
                         // returns this same floor and nothing changes.
                         draftLongEdge: DraftResolution.draftLongEdge(
                             settledLongEdge: longEdge,
                             fitLongEdge: LoupeView.draftLongEdge,
                             zoomRatio: state.zoomLevel),
                         fullLongEdge: longEdge,
                         strokeSets: state.strokeSets(for: recipe),
                         // While the crop tool is open the loupe shows the frame
                         // WITHOUT its crop, so the rectangle being dragged is drawn
                         // against the frame it is expressed in.
                         showingUncropped: viewport.showCrop
                             && state.activeSection == .effects,
                         // The proof is what the photographer is looking THROUGH; the
                         // before rendition below deliberately does not get it, because
                         // a before/after of "proofed vs not" is not the comparison the
                         // key is for.
                         softProof: state.activeSoftProof)
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
                               // Same geometry, same rule: the before rendition shares
                               // this canvas and would pump in size beside the edit.
                               draftLongEdge: DraftResolution.draftLongEdge(
                                   settledLongEdge: longEdge,
                                   fitLongEdge: LoupeView.draftLongEdge,
                                   zoomRatio: state.zoomLevel),
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
                                strength: LoupeViewport.maskOverlayOpacity)
                    .frame(width: drawn.width, height: drawn.height)
            }

            // Reachable again, and correct this time. The renderer is asked for the
            // frame WITHOUT its crop while this is open (`showingUncropped`), so the
            // rectangle is drawn against the frame it is expressed in rather than
            // inside a picture that has already been cut to it.
            if viewport.showCrop && state.activeSection == .effects {
                CropOverlayView(crop: cropBinding,
                                lockedAspect: viewport.cropAspectLock,
                                frameAspect: cropFrameAspect)
                    .frame(width: drawn.width, height: drawn.height)

                // Above the crop rectangle, so the ruler's drag belongs to the ruler
                // while it is armed. It lives inside the crop tool because that is the
                // one place the loupe shows the whole straightened frame — a ruler drawn
                // over an already-cropped picture would be measuring a frame the angle
                // is not expressed in.
                if viewport.showStraighten {
                    StraightenOverlayView(
                        currentAngle: recipe.develop.geometry.angle,
                        isFlipped: recipe.develop.geometry.flipH,
                        onAngle: { angle in
                            state.updateRecipe(coalescingKey: "straighten") { recipe in
                                recipe.develop.geometry.angle = angle
                            }
                        },
                        onFinish: { viewport.showStraighten = false })
                        .frame(width: drawn.width, height: drawn.height)
                }
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
        // `[` / `]` are a display gain over the frame already on screen (docs/10 §10.5)
        // — held, never applied. With no hold down this returns `cg` unchanged, so the
        // normal path costs one nil check.
        Image(decorative: InspectionGain.displayed(cg, hold: state.inspectionHold),
              scale: 1, orientation: .up)
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
            if state.showLatencyHUD {
                LatencyHUDView()
            }
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

    /// One ratio rule for every caller: at fit, the rendered image's own pixel count
    /// sets the ratio (so any proxy fills the container); zoomed, the bare zoom level
    /// is normalized by full/rendered (`LoupeGeometry.zoomedRatio`) so any proxy
    /// occupies the settle's extent. Both branches are size-stable across the
    /// draft/settle handoff by construction.
    private func ratio(forZoom zoom: Double, image: CGImage,
                       container: CGSize) -> Double {
        if zoom > 0 {
            return LoupeGeometry.zoomedRatio(
                zoomLevel: zoom,
                fullLongEdge: model.displayFullLongEdge ?? 0,
                renderedLongEdge: Swift.max(image.width, image.height))
        }
        return LoupeGeometry.fitRatio(imageWidth: image.width, imageHeight: image.height,
                                      container: container, displayScale: displayScale)
    }

    private func effectiveRatio(image: CGImage, container: CGSize) -> Double {
        ratio(forZoom: state.zoomLevel, image: image, container: container)
    }

    /// Keeps the anchor point pinned across a zoom change, then re-clamps the pan.
    private func applyZoomChange(from oldValue: Double, to newValue: Double,
                                 container: CGSize) {
        guard let cg = model.image else {
            viewport.pan = .zero
            return
        }
        let oldRatio = ratio(forZoom: oldValue, image: cg, container: container)
        let newRatio = ratio(forZoom: newValue, image: cg, container: container)
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
                // When the button went down, so the release can tell a click from a
                // hold. `minimumDistance: 0` means this fires on the press itself.
                if pressBegan == nil { pressBegan = Date() }
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
                // A press is a click-to-zoom only if it was AIMED at the photograph and
                // was actually a click. This used to ask one question — did the pointer
                // move less than three points? — and toggle the zoom whenever the
                // answer was yes. The gesture covers the whole canvas and the pan
                // branch above returns immediately at fit, so at fit this gesture was a
                // zoom toggle and nothing else: a press on the grey surround beside a
                // fitted frame, a click to bring the window forward, a press held while
                // deciding, a modifier-click — every one of them jumped to 1:1, and the
                // next one dropped back to fit. That is the "lots of zoom in, zoom out
                // things" of the owner's first session, and looking at `zoomLevel`'s
                // single writer could never have found it, because this IS the writer.
                //
                // The verb itself stays: click-to-zoom is the inherited grammar
                // (docs/12's muscle-memory argument) and this file's header promises
                // it. The rule is `ViewportClick`, in LumenCore, with tests.
                let began = pressBegan
                pressBegan = nil
                panStart = nil
                let travel = abs(value.translation.width) + abs(value.translation.height)
                let press = ViewportPress(
                    travel: Double(travel),
                    duration: began.map { Date().timeIntervalSince($0) } ?? 0,
                    landedOnImage: pressLandedOnImage(value.location,
                                                      container: container),
                    hadModifier: modifierHeld)
                if ViewportClick.togglesZoom(press) {
                    viewport.toggleZoom(at: value.location, in: state)
                }
            }
    }

    /// Whether a point in the viewport landed on the drawn photograph rather than on
    /// the surround. A fitted frame letterboxes on one axis, and that grey is not the
    /// picture — pressing it is not aiming at anything.
    private func pressLandedOnImage(_ point: CGPoint, container: CGSize) -> Bool {
        guard let cg = model.image else { return false }
        let ratio = effectiveRatio(image: cg, container: container)
        let drawn = LoupeGeometry.drawnSize(imageWidth: cg.width, imageHeight: cg.height,
                                            ratio: ratio, displayScale: displayScale)
        let pan = LoupeGeometry.clampPan(viewport.pan, container: container, drawn: drawn)
        return LoupeGeometry.imageUnitPoint(point, container: container, drawn: drawn,
                                            pan: pan) != nil
    }

    /// True while any of ⌘ ⌥ ⇧ ⌃ is down. Modifier-clicks on an image mean other things
    /// throughout this application and none of them mean zoom.
    private var modifierHeld: Bool {
        let flags = NSEvent.modifierFlags
        return flags.contains(.command) || flags.contains(.option)
            || flags.contains(.shift) || flags.contains(.control)
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
                LoupeGeometry.drawnSize(
                    imageWidth: $0.width, imageHeight: $0.height,
                    ratio: ratio(forZoom: state.zoomLevel, image: $0,
                                 container: containerSize),
                    displayScale: displayScale)
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

    /// Whether anything on screen actually reads the sampler right now. It used to be
    /// rebuilt unconditionally on every rendered frame — a full-resolution draw and up
    /// to ~45 MB of allocation per draft AND settle, for a readout usually not under
    /// the cursor and overlays usually off. The task key carries this flag, so turning
    /// an overlay on (or the cursor arriving with the readout enabled) builds it then,
    /// at the cost of the readout appearing one build later instead of instantly.
    private var samplerNeeded: Bool {
        (viewport.showReadout && cursor != nil)
            || state.clippingOverlay != nil
            || state.soloMaskOverlay != nil
    }

    private struct SamplerKey: Equatable {
        var revision: Int
        var needed: Bool
    }

    @MainActor
    private func rebuildSampler() async {
        guard samplerNeeded, let cg = model.image else {
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

    /// The USABLE frame's width ÷ height in pixels — the inscribed rectangle at the
    /// current straighten angle, not the source frame.
    ///
    /// The crop is normalized to that frame, so it is what converts the ratio menu's
    /// pixel ratio into the normalized one a drag works in. Using the source's aspect
    /// instead is the same class of error that once made "1:1" produce an 8:9 rectangle
    /// on a 4:3 body; it just needs a straighten angle rather than an unusual sensor.
    private var cropFrameAspect: Double {
        guard let size = state.primaryFrameSize, size.width > 0, size.height > 0 else {
            return 1
        }
        let usable = CropGeometry.usableSize(width: Double(size.width),
                                             height: Double(size.height),
                                             degrees: recipe.develop.geometry.angle)
        guard usable.height > 0 else { return 1 }
        return usable.width / usable.height
    }

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
