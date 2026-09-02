// LoupeView.swift
// The loupe: Lumen's main image viewer. It draws the CGImage the render coordinator
// returns, at an explicit zoom ratio — fit, the 1:1/2:1 rungs, or any continuous
// ratio from the pinch and scrubby-drag gestures — with drag-to-pan when the drawn
// image is larger than the viewport. Click-to-zoom is deliberately GONE (session C,
// owner: "this strange zoom … I'd like to honestly remove it"); a click does nothing,
// Space and Z still toggle from the keymap, and the continuous gestures are the
// pointer's way in.
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

    /// True while the crop tool is armed. `R` toggles it, and the crop workspace is the
    /// other half of the gate (`LoupeView`'s rectangle, and the render's
    /// `showingUncropped`).
    ///
    /// It is the only piece of the crop tool left here. The ratio lock was beside it, as
    /// one `Double?` for the whole application, so a ratio chosen on one photograph
    /// silently held every photograph opened afterwards; the lock, the guide, the revert
    /// baseline and the double-press timing are `CropTool` now, where the lock carries
    /// the frame it was chosen for.
    @Published var showCrop: Bool = false
    /// True while the straighten ruler is armed. It disarms itself when the drag ends,
    /// so it reads as a tool you fire rather than a mode you have to remember to leave.
    @Published var showStraighten: Bool = false
    /// A `let`, for the reason `maskOverlayOpacity` below is one: nothing anywhere sets
    /// it. Four reads gate the on-image cursor readout and the pixel sampler; there is no
    /// key, no menu item and no control that writes it, so the `@Published var` was a
    /// constant wearing a setting's clothes — observable state that could not be observed
    /// to change. docs/12 specifies the ghost readout as always on, which is what this
    /// value has always meant. If it becomes a setting it goes back to being published,
    /// with the control that writes it.
    let showReadout: Bool = true
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

    /// Called when the photo changes: a new frame starts at fit, centred.
    ///
    /// THE ZOOM GOES TOO, and it did not before. Pan was reset and `zoomLevel` was
    /// left, which is not a policy — it is half of each of the two coherent ones. Keep
    /// both and you have Lightroom's behaviour, where staying at 1:1 across a burst is
    /// how you check focus; keep neither and every photograph opens whole. Keeping the
    /// magnification while throwing away the place it was pointed at is the one
    /// combination that serves nobody: you arrive at 1142% on a new photograph, looking
    /// at its centre, which is not where you were looking and not the picture either.
    ///
    /// It was also expensive, which is what brought it to attention. The owner: "if I
    /// press a picture, I get put into the preview page of the image for around a
    /// minute." Entering the loupe already zoomed means `zoomedFullBasis` has no native
    /// size yet — `primaryFrameSize` is cleared by the selection and the model's own
    /// answer arrives with the first result — so it falls back to the fit cap and asks
    /// for a WHOLE-FRAME 4096 draft and settle on a 33 MP file. There is no region ask
    /// to save it either, because a region needs a frame on screen to be a region OF.
    /// Then the native size lands, the render key moves, and both of those renders are
    /// thrown away and paid again at 7008. Two discarded whole-frame passes and a
    /// full-sensor demosaic, per grid click, for a magnification the photographer did
    /// not choose for this photograph.
    ///
    /// Restoring the Lightroom behaviour deliberately is a fine thing to want later.
    /// It means keeping the pan as well, and seeding the zoomed basis synchronously so
    /// the first pass asks the right question — the catalog already stores EXIF
    /// dimensions, with the caveat that they need not equal `CIRAWFilter.nativeSize`.
    /// That is a change worth measuring on a Mac; this one is worth making now.
    @MainActor
    func resetForNewPhoto(in state: AppState) {
        // Through the verb, not by assignment: `setZoom` is where fit clears the pan
        // and where every other zoom source in the app already goes. `ZoomLadder`'s own
        // header is the story of what two ladders cost this project.
        setZoom(LoupeZoom.fit, at: nil, in: state)
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
    /// The source file's own long edge, learned from the first result that knew it.
    ///
    /// `@Published` because the ZOOMED ask is sized from it (`requestedLongEdge`):
    /// the first zoomed render of a photo goes out at the fit cap before this is
    /// known, and learning it must re-body the view so the render key moves and the
    /// native ask follows. It changes once per photograph, not per frame.
    @Published private(set) var nativeLongEdge: Int?

    /// What the pixels on screen COVER: nil for a whole-frame image, else the unit
    /// rectangle of the full frame (top-left origin) the current `image` is a region
    /// of, with the full frame's own pixel size beside it. Plain vars, deliberately:
    /// they change only when `image` does, and `revision` publishes that.
    private(set) var regionUnit: CGRect?
    private(set) var regionFullPixel: CGSize?
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

    /// The recipe the frame ON SCREEN was settled with, or nil when what is showing is
    /// a draft, an embedded preview, or nothing. Compared against the incoming recipe
    /// to tell a RESOLUTION change from an EDIT — see `load`.
    private var settledRecipe: Recipe?

    /// The recipe of whatever is on screen right now — draft OR settle. Distinct from
    /// `settledRecipe`, which is nil while a draft is showing; this one answers "is the
    /// picture up there already this edit, at whatever quality".
    private var shownRecipe: Recipe?

    /// The `AppState.settleTick` the last request carried, so a request can tell that
    /// the ONLY thing that moved was the tick — which happens exactly once, when a hand
    /// comes off a slider. See `load`.
    private var lastSettleTick: Int?

    /// When the previous draft landed, so the ladder can be costed by the interval
    /// between delivered frames rather than by the render's own wall time — see
    /// `DraftLadder.costSample`. Cleared on a photo change: a new photograph's first
    /// frame continues nothing.
    private var lastDraftAt: UInt64?
    /// WHETHER THE PREVIOUS DRAFT HAD WORK QUEUED BEHIND IT, which is the other half of
    /// the saturation test and was missing.
    ///
    /// The interval the ladder is costed by runs from the PREVIOUS frame's landing to
    /// this one's, and `Task.isCancelled` is read at the END of it. That answers "was
    /// the loop busy when this frame landed" and says nothing about whether it was busy
    /// when the interval opened. A hand that pauses mid-gesture with the button still
    /// down and then resumes hard produces exactly the false positive: the interval is
    /// mostly the pause, the first frame after the resume is cancelled by the event
    /// behind it, and the whole pause is charged to the machine as render cost. The
    /// owner's 285/378/399 ms samples all sit under `continuityCeilingMilliseconds`
    /// (500) — the band a human hesitation occupies, not the band a stall does.
    ///
    /// Saturation has to hold at BOTH ends: if the previous frame was itself cancelled,
    /// a newer request already existed when it landed, so this frame's render should
    /// have started immediately and any gap before it is genuinely the machine's.
    private var lastDraftWasSaturated = false
    /// The size the previous draft was RENDERED at, so the ladder can tell a
    /// steady-state frame from the one that paid for a fresh decode at a new size —
    /// see `DraftLadder.isRepresentative`. Cleared with `lastDraftAt` and for the same
    /// reason.
    private var lastDraftLongEdge: Int?
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
              softProof: SoftProof? = nil,
              settleTick: Int = 0,
              region: CGRect? = nil,
              /// What the frame occupies on the panel, in device pixels — the ladder's
              /// sharpness floor (`DraftLadder.sharpnessFloor`). Nil where the caller
              /// cannot say, which leaves the ladder exactly as it was.
              drawnDeviceLongEdge: Double? = nil,
              gestureInFlight: () -> Bool = { false }) async {

        currentRequestURL = url
        // The tick moves only in `AppState.flushSliderGesture` — a release, a photo
        // switch or the watchdog — so a request whose tick differs from the last one's
        // is the ask for the quality pass the drag deferred, and nothing else.
        let isSettleAsk = lastSettleTick != nil && lastSettleTick != settleTick
        lastSettleTick = settleTick
        // The hand came up: let the ladder spend any headroom the gesture banked. It
        // is held during the drag because a rung earned back under a moving hand is a
        // visible change of sharpness; here it is one change, at rest, invisible.
        if isSettleAsk { draftLadder.gestureEnded() }

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
            settledRecipe = nil
            shownRecipe = nil
            lastDraftAt = nil
            lastDraftWasSaturated = false
            lastDraftLongEdge = nil
            nativeLongEdge = nil
            regionUnit = nil
            regionFullPixel = nil
            revision &+= 1
            if let thumbnails,
               let preview = await thumbnails.load(
                   url: url, maxPixel: ThumbnailLadder.loupeInstantPixels),
               let cg = preview.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                guard !Task.isCancelled else { return }
                // Only into the void this task itself cleared. A superseded sibling's
                // COMPLETED draft may legally land while the thumbnail loads (that is
                // FrameDelivery's whole point), and the camera JPEG must not paint
                // over a real render — an EMBEDDED PREVIEW badge over a frame that
                // had a genuine draft, for one draft-interval, on every fast
                // photo-bounce.
                guard imageURL == nil else { return }
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

        // A RESOLUTION change, not an edit: the photograph and the recipe are the ones
        // already settled on screen, and only the number of pixels asked for moved —
        // which is what every zoom across the fit boundary does, in both directions.
        //
        // The draft pass exists to put an honest picture up within a frame while a
        // settle renders. Here there already IS one: the settled frame being shown,
        // which the geometry rescales the instant the zoom changes. Rendering a draft
        // over it REPLACES those pixels with the ladder's coarse ones — the owner's
        // "when I'm zooming in, it's bad quality for a few seconds and then the good
        // quality version loads. And then when I zoom out, same thing again". Keeping
        // the settled frame means what changes on a zoom is sharpness arriving, never
        // sharpness leaving. The debounce goes with it: it buys a draft time it is no
        // longer taking, and nothing is being coalesced — a zoom crosses this boundary
        // at most twice per gesture.
        let keepShowingSettled = image != nil && !isDraft && !usedEmbeddedPreview
            && imageURL == url && settledRecipe == recipe

        // THE HAND JUST CAME OFF, AND THE PICTURE IS ALREADY THIS EDIT.
        //
        // A release bumps `settleTick` and changes nothing else: `onEnded` commits the
        // value the last motion event already committed, so the recipe is identical to
        // the one whose draft is on screen. This pass would therefore render a draft
        // that produces the picture already showing, wait 40 ms, and only then start
        // the settle — about seventy milliseconds of the deadline spent re-deriving a
        // frame nobody is waiting for, at the one moment the photographer IS waiting
        // for sharpness.
        //
        // Both halves are skipped, and both are safe because of how narrow the
        // condition is. The draft exists to put an honest picture up within a frame,
        // and there is one up. The debounce exists to let a burst of events coalesce
        // before something expensive; a burst would have moved the recipe, and the
        // recipe has not moved. Deliberately gated on the TICK rather than on "the
        // recipe is unchanged" alone: a matte landing, a brush blob loading or ⇧S
        // toggling the proof also leaves the recipe unchanged, and those must still
        // get their fast draft rather than waiting out a full-resolution pass.
        let alreadyShowingThisEdit = image != nil && !usedEmbeddedPreview
            && imageURL == url && shownRecipe == recipe
        // The rule itself is `FrameDelivery.needsDraft` in LumenCore, where it is
        // tested and where its narrowness is argued — a rule about which passes run
        // that lives only in a view is the shape this file's own header warns about.
        let needsDraft = FrameDelivery.needsDraft(
            showingSettledOfThisRecipe: keepShowingSettled,
            showingAnyFrameOfThisRecipe: alreadyShowingThisEdit,
            requestIsOnlyTheSettleAsk: isSettleAsk)

        let draftGeneration: UInt64 = PhotoRenderModel.nextGeneration()
        latestGeneration = draftGeneration
        if needsDraft {
            // Half the settled request, floored at the old fixed size: enough that the
            // draft reads as the same photograph at fit, cheap enough to stay ahead of
            // the cursor. The colour is now identical to the settle by construction, so
            // what remains between draft and settle is sharpness alone — which reads as
            // the picture resolving rather than as the picture changing.
            // ASK FOR THE SETTLE'S OWN RESOLUTION, and let the ladder take back what
            // this machine cannot afford.
            //
            // This used to be `max(draftLongEdge, fullLongEdge / 2)` — a draft capped
            // at half the settle on every machine, forever. That is a guess from before
            // anything measured a frame, and it is what put a soft picture under the
            // hand and a sharp one on release however fast the Mac was. `DraftLadder`
            // measures every frame and steps down within one hot frame now, so the
            // honest request is the whole thing; a machine with headroom keeps it and
            // the drag is simply sharp.
            let draftRequested = draftLongEdge
            // A REGION draft does not consult the ladder: the rungs price a WHOLE
            // frame against the drag budget, and a region render's cost is the
            // viewport's, whatever the ask — which is the entire point (docs/32
            // fifth round: the ladder stepped to 1024 exactly when the magnification
            // made 1024 unwatchable, because it was pricing 33 MP nobody could see).
            // Sharp region drafts are what the margin arithmetic in `ZoomRegion`
            // sizes to be affordable.
            let draftTarget = region != nil
                ? draftRequested
                : draftLadder.longEdge(
                    requested: draftRequested,
                    // …and the ladder may not descend past a 2× magnification of what
                    // is on screen. `DraftLadder.maxUpscale` argues it; the short
                    // version is that the low rungs' justification — a moving image
                    // cannot show detail — is the assumption the owner keeps refuting.
                    notBelow: DraftLadder.sharpnessFloor(
                        drawnDeviceLongEdge: drawnDeviceLongEdge))
            let draftStarted = DispatchTime.now().uptimeNanoseconds
            let draft = await coordinator.render(url: url, recipe: recipe,
                                                 maxLongEdge: Swift.max(draftTarget, 64),
                                                 draft: true, generation: draftGeneration,
                                                 strokeSets: strokeSets,
                                                 showingUncropped: showingUncropped,
                                                 softProof: softProof,
                                                 region: region)
            // Delivery BEFORE the cancellation check, deliberately — FrameDelivery in
            // LumenCore is the law and holds the arithmetic. During a drag every event
            // cancels this task and starts the next one, so "apply only if still
            // current" meant every completed draft of the gesture was rendered and then
            // discarded, and the picture moved only at pauses in the hand — the owner's
            // "goes by notches ... changes in one frame instead of a slope". A finished
            // frame is the freshest completed picture of the user's intent that exists;
            // the only questions are identity and order, and `shouldShow` asks those.
            if let draft {
                // Wall time around the await, actor queueing included — queueing is
                // what a hand feels. The ladder learns from the same number the HUD
                // shows, and it learns from every completed draft, delivered or not:
                // the cost was real either way.
                let landedAt = DispatchTime.now().uptimeNanoseconds
                let draftMs = Double(landedAt - draftStarted) / 1e6
                // WHAT THE INTERVAL BETWEEN TWO FRAMES ACTUALLY CONTAINS, stated
                // correctly here for the first time — the previous version of this
                // comment claimed it was "the SwiftUI handoff, the body pass and the
                // texture upload", and three rounds of investigation reasoned from
                // that. The arithmetic says otherwise and is worth writing out, since
                // it is not obvious from any single line:
                //
                //     period   = landedAt(N)    - landedAt(N-1)
                //     draftMs  = landedAt(N)    - draftStarted(N)
                //     period - draftMs = draftStarted(N) - landedAt(N-1)
                //
                // `draftStarted` is stamped BEFORE the await, so everything the
                // coordinator does — queueing included — is inside `draftMs` and none
                // of it is in the remainder. The remainder is the gap between one frame
                // landing and the next render being REQUESTED. It is an input and
                // scheduling measure, not a display-path one, and it is usually zero
                // or negative because `.task(id:)` starts frame N+1 without waiting for
                // frame N.
                //
                // That makes it a measure of the request stream STOPPING, which during
                // a gesture with the button still down means the hand paused. Costing
                // the ladder for that is costing it for the photographer's hesitation.
                // `handWasWaiting` is the guard, and it has to hold at both ends of the
                // interval — see `lastDraftWasSaturated`.
                let period = lastDraftAt.map { Double(landedAt - $0) / 1e6 }
                let saturated = Task.isCancelled
                let handWasWaiting = DraftLadder.loopWasSaturated(
                    thisFrameCancelled: saturated,
                    previousFrameCancelled: lastDraftWasSaturated)
                let cost = DraftLadder.costSample(renderMilliseconds: draftMs,
                                                  sincePreviousFrameMilliseconds: period,
                                                  handWasWaiting: handWasWaiting)
                lastDraftAt = landedAt
                lastDraftWasSaturated = saturated
                // ONLY A FRAME THAT MEASURES THE STEADY STATE TEACHES THE LADDER.
                //
                // The decode is keyed by the scale factor this size implies, so the
                // first frame at any new size pays a fresh RAW decode no later frame at
                // that size pays. Believing it makes every step down look like it did
                // not help, and the ladder walks itself to the floor — a drag that gets
                // blurrier the longer it is held. `DraftLadder.isRepresentative` holds
                // the rule and the argument; `DraftLadderTests` shows the cascade it
                // prevents, eight rungs of it.
                //
                // THE SIZE DELIVERED, not the size asked for — the same correction the
                // HUD line below already carried, now applied where it is load-bearing
                // (docs/31 §23). This used to pass `draftTarget`, the ask, so the
                // ladder's own-answer guard compared the ask with itself — a check that
                // could never fire — and every sample was filed under a size the
                // picture did not have. On a cropped photograph the delivered edge is
                // the crop's, and feeding the ask instead is what made the ladder's
                // climb and the settle recovery misfire exactly there: the owner's
                // "I get the blurry effect until I let go", on the photographs he had
                // cropped.
                let renderedLongEdge =
                    Swift.max(Swift.max(draft.image.width, draft.image.height), 64)
                // A region draft's delivered edge is the REGION's pixels — a size in
                // a different denomination from the whole-frame rungs. The ladder
                // learns nothing from it (same reason `learnsFromSettle` refuses the
                // native settle: evidence in the wrong denominator reads as heat).
                if region == nil, DraftLadder.isRepresentative(
                    renderedLongEdge: renderedLongEdge,
                    previousRenderedLongEdge: lastDraftLongEdge) {
                    draftLadder.record(draftMilliseconds: cost,
                                       // BOTH numbers, because the two directions ask
                                       // different questions. `cost` is what the hand
                                       // felt and decides the descent; `draftMs` is what
                                       // the render actually cost and decides the climb,
                                       // since it is the only part of `cost` that fewer
                                       // pixels can change. Passing only `cost` pinned
                                       // the ladder at its floor: a stall in delivery
                                       // dropped rungs the render never earned back.
                                       renderMilliseconds: draftMs,
                                       renderedLongEdge: renderedLongEdge,
                                       requested: draftRequested,
                                       // Monotone downward while the hand is down: a
                                       // rung earned back mid-drag is a visible change
                                       // of sharpness, and at a rung boundary it
                                       // oscillates.
                                       allowStepUp: !gestureInFlight())
                }
                lastDraftLongEdge = renderedLongEdge
                // THE SIZE DELIVERED, not the size asked for.
                //
                // This line used to report `draftTarget` — the request — so the HUD
                // could only ever confirm the viewer's own intention. Three rounds of
                // "the picture is blurry while I drag" were investigated against a
                // number that was incapable of disagreeing with the code that set it.
                // The render path has several places where a frame can come back
                // shorter than asked (`applyGeometry` clamps to `min(1, wanted)` and
                // never upscales, so a crop or a decoder that declines a scale factor
                // both land here), and none of them were visible from inside.
                //
                // So: measure the pixels, print the ask beside them. A shortfall on a
                // cropped photograph is honest rather than a fault — the crop really
                // is smaller than the frame — but on an uncropped one it is a lead.
                LatencyHUD.shared.noteDecode(milliseconds: draft.decodeMilliseconds)
                LatencyHUD.shared.noteDraft(
                    milliseconds: draftMs,
                    longEdge: Swift.max(draft.image.width, draft.image.height),
                    requestedLongEdge: Swift.max(draftTarget, 64),
                    // The same interval `costSample` folds into the ladder, reported
                    // separately: the ladder needs one number to act on, a person needs
                    // to know which half of the frame is large, because the two halves
                    // have opposite fixes.
                    afterRenderMilliseconds: DraftLadder.afterRenderMilliseconds(
                        renderMilliseconds: draftMs,
                        sincePreviousFrameMilliseconds: period,
                        handWasWaiting: handWasWaiting))
                if FrameDelivery.shouldShow(frameFor: url,
                                            currentRequest: currentRequestURL,
                                            generation: draft.generation,
                                            newestShown: appliedGeneration) {
                    apply(draft, url: url, recipe: recipe)
                }
            }
            guard !Task.isCancelled else { return }

            // The debounce, and nothing but the debounce: everything after this point
            // still has to happen inside the deadline, so the wait is the part of the
            // budget that buys the least and is kept the smallest.
            try? await Task.sleep(nanoseconds: PhotoRenderModel.settleNanoseconds)
        }
        guard !Task.isCancelled, latestGeneration == draftGeneration else { return }

        // THE HAND IS STILL MOVING — the drag owns the render lane, so stop here.
        //
        // This is the notch the owner has been describing since the first session:
        // "every single slider is … updating little by little". The debounce below the
        // draft is 40 ms and a draft costs ~35, so on any drag with a human's micro-
        // pauses in it the settle was routinely reachable MID-GESTURE — and a settle is
        // the most expensive thing the app does: full resolution, a fresh decode at a
        // different scale factor, and EXACT table bakes (its whole point is that it
        // does not serve stale). The render coordinator is a serial actor whose passes
        // have no cancellation points, so once one started every event behind it waited
        // 100–300 ms for a lane that could not be given back. The picture then jumped
        // to wherever the hand had got to. That is the notch: not the draft cadence,
        // which is honest, but a quality pass repeatedly cutting in front of it.
        //
        // `AppState.settleTick` is the other half: it bumps when the gesture ends,
        // changes this surface's render key, and the settle happens then — once, at
        // rest, which is exactly what `RefineBudget` describes.
        guard !gestureInFlight() else { return }

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
                                                  softProof: softProof,
                                                  region: region)
            guard !Task.isCancelled else { return }
            if let result, result.generation == generation, latestGeneration == generation {
                apply(result, url: url, recipe: recipe)
                let settleMs =
                    Double(DispatchTime.now().uptimeNanoseconds - settleStarted) / 1e6
                // THE MEASUREMENT THE LADDER WAS THROWING AWAY. A settle is a render at
                // the full requested size, timed by this same clock, and it pays EXACT
                // table bakes where a draft serves them stale — so a settle inside the
                // budget proves a draft at that size is affordable. Without this the
                // ladder climbed one rung per gesture and stayed at its floor for eight
                // drags after any transient, which is what the owner saw as "all of the
                // sliders are still extremely blurry" once the decode was fixed.
                //
                // BOTH sizes: the delivered edge gates the sample, the ASK carries the
                // claim. On a cropped photograph the delivered edge is a crop fraction
                // below the ask, and claiming only up to it made this recovery a no-op
                // there (docs/31 §23) — the settle's cost already contains the whole
                // graph at the ask's decode scale, so the ask is what it proved.
                // …but never from a native-inspection settle. The zoomed settle asks
                // for the sensor's own size now, and ~1 s at 7000 px projected onto
                // the drafts' cost model reads as "nothing is affordable" — the
                // rungs would crash and take the FIT drag with them. The rule is
                // `DraftLadder.learnsFromSettle`, tested in LumenCore.
                if DraftLadder.learnsFromSettle(
                        requestedLongEdge: Swift.max(fullLongEdge, 64)) {
                    draftLadder.recordSettle(milliseconds: settleMs,
                                             renderedLongEdge: Swift.max(
                                                 result.image.width, result.image.height),
                                             requestedLongEdge: Swift.max(fullLongEdge, 64))
                }
                // THE SIZE DELIVERED, not the size asked for — the same correction
                // the draft line already carries, and for the reason its own comment
                // gives: "printing only the request is how a blurry picture reported
                // @2560 for three rounds", because a number chosen by the code cannot
                // disagree with it. The delivered extent is already measured a few lines
                // up, where the ladder is fed it; the HUD was reading the request
                // beside it. On a cropped photograph the two genuinely differ.
                LatencyHUD.shared.noteDecode(milliseconds: result.decodeMilliseconds)
                LatencyHUD.shared.noteSettle(
                    milliseconds: settleMs,
                    longEdge: Swift.max(result.image.width, result.image.height))
                return
            }
            // Something newer of ours is already in flight: that request owns the frame.
            guard latestGeneration == generation else { return }
            // A draft of this very recipe is already up. It is the edit, just coarser —
            // keep it rather than churning the queue. UNLESS a table bake is still
            // outstanding: a draft may legally ride the previous event's finish or
            // colour-grade table (stale-while-bake), and giving up here would leave
            // that stale picture on screen AT REST — the one place the staleness
            // contract forbids it. `anyBakePending` is the caller `hasPendingBake`
            // was written for and never had (docs/23 audit queue item 7); while it
            // answers true, this loop keeps re-settling.
            //
            // TWO NARROWINGS, because the question as first written was far wider than
            // the thing it was protecting and each retry costs a full-resolution graph
            // (I1-04). It asked "is ANY table baking, anywhere", and answered yes for
            // most of every drag's tail.
            //
            // `isDraft` — the staleness contract is a statement about DRAFT frames.
            // `PlanTableCache`'s own header: "Settle and export must never come
            // through here; they call `table`, which blocks on the exact bake, so the
            // picture at rest and the exported file are exact by construction." So an
            // exact frame on screen cannot be riding a stale table, whatever is baking,
            // and re-settling cannot improve it. Reaching this line with `isDraft`
            // false means an earlier settle for this very recipe is up — the drafts
            // above paint the current edit whenever they run at all.
            //
            // The identity — a bake queued under a DIFFERENT photograph cannot change
            // a pixel of this one, because the stale door refuses to cross photographs.
            // The compare pane's other half and the tail of the drag on the frame the
            // photographer just stepped away from were both keeping this loop awake.
            if image != nil, !usedEmbeddedPreview,
               !(isDraft && PlanTableCache.anyBakePending(
                    for: PlanTableCache.renderIdentity(for: url))) {
                return
            }
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
    private func apply(_ result: RenderResult, url: URL, recipe: Recipe) {
        appliedGeneration = Swift.max(appliedGeneration, result.generation)
        image = result.image
        imageURL = url
        isDraft = result.isDraft
        usedEmbeddedPreview = result.usedEmbeddedPreview
        note = result.note
        isUnreadable = false
        shownRecipe = recipe
        if result.nativeLongEdge > 0 {
            nativeLongEdge = result.nativeLongEdge
        }
        regionUnit = result.regionUnit
        regionFullPixel = result.fullPixelSize
        if result.isDraft {
            // What is on screen is no longer a settled frame, so the next request may
            // not skip its draft on the strength of it.
            settledRecipe = nil
        } else {
            // For a REGION settle the frame equivalent is the full frame the region
            // belongs to — the delivered image's own extent is the region's, a size
            // in a different denomination from everything this value normalizes.
            if result.regionUnit != nil, let full = result.fullPixelSize {
                settledActualLongEdge = Int(Swift.max(full.width, full.height).rounded())
            } else {
                settledActualLongEdge = Swift.max(result.image.width, result.image.height)
            }
            settledRecipe = recipe
        }
        revision &+= 1
    }
}

// MARK: - Loupe

extension ProxyResampling {
    /// The SwiftUI spelling. Kept here rather than in LumenCore so the rule itself
    /// stays free of SwiftUI and can be tested on the free lane.
    var swiftUIInterpolation: Image.Interpolation {
        switch self {
        case .none: return .none
        case .linear: return .low
        case .filtered: return .high
        }
    }
}

struct LoupeView: View {

    @EnvironmentObject var state: AppState
    /// This surface shows the edit, so it observes the edit signal —
    /// `AppState.recipes` is deliberately not published (see `EditRevision`).
    @EnvironmentObject var edits: EditRevision
    let photo: PhotoItem

    // The render key is `ViewerRenderKey` in RenderRequest.swift — shared with the
    // compare and survey panes so the beside-the-recipe inputs (brush blobs, mattes,
    // soft proof) can never again be in one surface's key and not another's.

    /// The FIT ask's ceiling, and the fallback basis for a photo whose native size
    /// nothing knows yet. It is no longer the largest ask in the app: the zoomed
    /// settle goes to the sensor's own size (`zoomedFullBasis`, capped by
    /// `DraftLadder.inspectionLongEdgeCeiling`), because "a real 1:1 is the tiled
    /// Metal viewport's job" turned out to mean the owner pixel-peeping a 4096 proxy
    /// of a 7008 px ARW — mush, at the moment of judging sharpness.
    ///
    /// The ladder's own ceiling rather than a third copy of 4096: this used to be
    /// written down here, in `DraftLadder.rungs[0]`, and in
    /// `DecodeMaterializer.longEdgeLimit` — and the third one said 3072, which put every
    /// zoomed settle above the line where a decode stops being cached as pixels.
    static let maxRenderLongEdge: Int = DraftLadder.interactiveLongEdgeCeiling
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
    /// THE ARRANGEMENT, because two on-image tools are gated on where the photographer
    /// is standing in the panel — the crop rectangle and the mask canvas. Both used to
    /// read `AppState.activeSection`; that field is gone with the tab strip, and a gate
    /// left reading a stale idea of "which tab" would take its tool dead SILENTLY, which
    /// is the defect class this project has been bitten by twice.
    @ObservedObject private var panel: PanelLayout = PanelLayout.shared

    @State private var containerSize: CGSize = .zero
    @State private var cursor: CGPoint?
    @State private var panStart: CGSize?
    /// Whether the current drag began at fit — decided once at the first event and
    /// held for the whole gesture, so a scrub that has already zoomed keeps scrubbing
    /// instead of turning into a pan mid-hold. Nil between gestures.
    @State private var scrubFromFit: Bool?
    /// The zoom the current pinch began at, so the gesture's total magnification
    /// multiplies one start value instead of compounding per event. Nil between
    /// gestures.
    @State private var pinchStartZoom: Double?
    /// The region ask captured at the pinch's first event and held for the whole
    /// gesture — nil is a REAL value here (a pinch begun at fit holds whole-frame),
    /// which is why this is read only while `pinchStartZoom` is non-nil. Without the
    /// hold, a continuous zoom re-quantizes the region per event and mints a render
    /// key per grid line — the request storm `ZoomRegion.grid` exists to prevent.
    @State private var pinchRegion: CGRect?
    @State private var sampler: PixelSampler?

    @Environment(\.displayScale) private var displayScale: CGFloat
    @FocusState private var focused: Bool

    private var recipe: Recipe { state.recipe(for: photo) }

    /// The SOURCE frame every overlay places itself against — the crop rectangle, the
    /// mask handles, the eyedropper. Reconciled in `AppState`, so the crop PANEL's
    /// arithmetic and this canvas's cannot hold different answers.
    private var sourceFrameSize: CGSize? { state.sourceFrameSize }

    /// Learn the reconciliation from a delivery the renderer made of the WHOLE frame.
    ///
    /// Only a whole-frame delivery can answer it: a crop legitimately turns a landscape
    /// frame portrait, and transposing on that would be the same defect wearing the
    /// other hat. The crop tool renders uncropped by construction, so opening it always
    /// supplies one — which is the surface the owner reported the stretch on.
    @MainActor
    private func learnSourceOrientation(fullPixel: CGSize?, uncropped: Bool) {
        guard uncropped,
              let delivered = fullPixel ?? model.image.map({
                  CGSize(width: $0.width, height: $0.height) }),
              let reported = state.primaryFrameSize else { return }
        state.noteFrameTransposed(
            FrameOrientation.isTransposed(reported: reported, delivered: delivered))
    }

    /// True when the frame the renderer is delivering is the whole photograph, so its
    /// extent may be compared with the reported size. `cropArmed` strips the crop AND
    /// the angle (`renderRecipe`); otherwise an identity crop with no straighten is the
    /// same guarantee.
    private var deliveringWholeFrame: Bool {
        if cropArmed { return true }
        let geometry = recipe.develop.geometry
        return geometry.crop == Crop() && geometry.angle == 0
    }

    /// True while the crop tool is live on this surface: armed AND in its workspace —
    /// the same two-part gate the overlay, the render request and the panel share.
    private var cropArmed: Bool {
        viewport.showCrop && panel.layout.workspace == .crop
    }

    /// What the render request carries. While the crop tool is armed, the crop AND the
    /// straighten angle are left off (the flip stays): the pipeline delivers the full
    /// frame once, and the angle lives in `cropCanvas`'s view-layer rotation instead.
    ///
    /// The angle stripping is what makes tilting smooth — it used to re-render the
    /// whole pipeline per rotate-drag event, because the angle rode the recipe into
    /// `ViewerRenderKey` — and it is also what puts the picture's tilted corners on
    /// screen at all: `renderPreview` cuts to the inscribed rectangle whenever an angle
    /// goes through it, which is exactly the "automatically removes all the stuff" the
    /// owner reported. The crop stripping matches `showingUncropped` (the renderer
    /// would strip it again anyway); doing it here as well keeps the render KEY still
    /// while the rectangle is dragged, so a crop drag re-renders nothing either.
    private var renderRecipe: Recipe {
        guard cropArmed else { return recipe }
        var stripped = recipe
        stripped.develop.geometry.crop = Crop()
        stripped.develop.geometry.angle = 0
        return stripped
    }

    /// "Before" is just another recipe through the same pipeline (docs/12 §B8): the
    /// import default, i.e. an empty recipe at this photo's pipeline version.
    private var beforeRecipe: Recipe { Recipe(pipelineVersion: recipe.pipelineVersion) }

    private var needsBeforeRender: Bool {
        state.showBefore || viewport.beforeMode.showsPair
    }

    var body: some View {
        GeometryReader { geometry in
            let container: CGSize = geometry.size
            // The zoomed region ask — held STILL through both continuous zoom
            // gestures. A pinch reads the rectangle captured at its first event; the
            // scrub always began at fit, so its whole gesture is whole-frame. Panning
            // is deliberately NOT held: a pan past the margin is exactly the moment a
            // new region must be rendered, and `ZoomRegion.grid` keeps that from
            // being every pan point.
            let region: CGRect? = {
                if pinchStartZoom != nil { return pinchRegion }
                if scrubFromFit == true { return nil }
                return requestedRegion(container: container)
            }()
            // WHAT THE PANEL ACTUALLY DRAWS, in device pixels, computed ONCE and given
            // to both passes. It used to be computed here for the draft and not at all
            // for the settle, and the two consequences were both expensive:
            //
            //   · the settle rendered the CONTAINER's bucketed long edge, which for a
            //     portrait photograph in a landscape pane is far more pixels than the
            //     panel shows — the owner's HUD read `draft @3212` beside
            //     `settle @4096` on one frame, a third of them discarded by the
            //     downsample that follows;
            //   · and because `AppleRawSource.DecodeKey` carries the scale factor, two
            //     asks are TWO CACHE ENTRIES and two full demosaics of a 33 MP file per
            //     photograph — one of them purely to be thrown away. That is a load-time
            //     cost wearing a frame-time costume, and it is the best current
            //     explanation for "five to ten seconds to open a photo" (docs/34 §3).
            //
            // One value, both passes, one decode. Stable under a resize because a fit
            // ratio is derived from the ASPECT: the drawn extent does not move when the
            // pixel count does, so this cannot chase its own tail through the render.
            let drawnDevice: Double? = region == nil
                ? model.image.map { cg in
                    let d = drawnFull(forZoom: state.zoomLevel, image: cg,
                                      container: container)
                    return Double(Swift.max(d.width, d.height))
                        * Double(Swift.max(displayScale, 1))
                }
                : nil
            let longEdge: Int = requestedLongEdge(container: container,
                                                  drawnDeviceLongEdge: drawnDevice)
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
            // The wheel and the two-finger scroll, which the picture answered not at
            // all before — the second half of the owner's fifth round, "both with the
            // mouse and with the trackpad are pretty broken". `ViewerScroll` (LumenCore,
            // tested) decides what a scroll means; this passes it the state and applies
            // the verb. Above the gestures in the modifier order and below them in
            // routing: `hitTest` claims scroll events only, so the drag, the pinch and
            // the double-click reach SwiftUI exactly as they do today.
            .lumenViewerScroll(zoomed: { state.zoomLevel > 0 }) { verb in
                applyScroll(verb, container: container)
            }
            .gesture(dragGesture(container: container))
            .simultaneousGesture(magnifyGesture(container: container))
            // The way BACK. The scrub only zooms while the press is held and only
            // from fit, so once a gesture ends zoomed there was no pointer verb that
            // returned — "when I zoom in, I can't zoom out". Double-click is the
            // inherited grammar for exactly that and costs nothing at fit, where it
            // is deliberately inert (a stray double-click on a fitted frame must not
            // become the click-to-zoom that was just removed).
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                guard !ZoomLadder.isFit(state.zoomLevel) else { return }
                viewport.fit(in: state)
            })
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
            // `renderRecipe`, not `recipe`: while the crop tool is armed the framing
            // fields are stripped, so a crop or rotate drag moves the key not at all
            // and the session renders once instead of once per event.
            .task(id: ViewerRenderKey.current(url: photo.id, recipe: renderRecipe,
                                              longEdge: longEdge, state: state,
                                              showingUncropped: cropArmed,
                                              regionUnit: region)) {
                await renderCurrent(longEdge: longEdge, region: region,
                                    drawnDevice: drawnDevice)
                // `load` returns when the settle has landed (or been deliberately
                // skipped), so this line IS the "photographer has stopped to work"
                // signal `DecodeWarming` is gated on — no timer guesses at it. A task
                // that was superseded never gets here, which is exactly the paging case
                // that must not warm.
                // The settled frame feeds the instruments before it warms a neighbour:
                // the scopes used to render their own 512 px proxy, which was a second
                // full read of the RAW per photograph and a second occupant of the
                // render actor (docs/34). Measuring what is on screen is cheaper and
                // describes the picture the photographer is actually looking at.
                if let cg = model.image, !model.isDraft, model.imageURL == photo.id {
                    state.measureScopes(fromViewerFrame: cg, url: photo.id)
                    // And file it, so coming back to this photograph does not read the
                    // RAW again. Only a SETTLED frame is worth filing: a draft is the
                    // same edit at lower quality, and caching one would hand the next
                    // visit a picture the settle has already improved on.
                    //
                    // Region frames are excluded by `!model.isDraft` alone not being
                    // enough — a zoomed settle covers a rectangle, not the frame — so
                    // the whole-frame test is explicit.
                    if model.regionUnit == nil, !cropArmed {
                        state.thumbnails.recordDeveloped(url: photo.id, image: cg)
                    }
                }
                await warmNextPhoto(longEdge: longEdge)
            }
            .task(id: BeforeKey(url: photo.id, recipe: beforeRecipe,
                                wanted: needsBeforeRender, longEdge: longEdge,
                                strokeRefs: Set(state.strokeSets(for: beforeRecipe).keys))) {
                await renderBefore(longEdge: longEdge)
            }
            .task(id: SamplerKey(revision: model.revision, needed: samplerNeeded)) {
                await rebuildSampler()
            }
            // Every delivered frame is a chance to learn which way up this photograph
            // is; the first WHOLE-FRAME one answers it and the rest are a nil check.
            .onChange(of: model.revision) { _, _ in
                learnSourceOrientation(fullPixel: model.regionFullPixel,
                                       uncropped: deliveringWholeFrame)
            }
            // …and the reported size arrives asynchronously — `refreshPrimaryFrameSize`
            // opens the file off the selection path — so it can land after the frame it
            // has to be compared against.
            .onChange(of: state.primaryFrameSize) { _, _ in
                learnSourceOrientation(fullPixel: model.regionFullPixel,
                                       uncropped: deliveringWholeFrame)
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
            viewport.resetForNewPhoto(in: state)
            sampler = nil
            warmNeighbours()
        }
    }

    /// Decode the photograph the owner is most likely to open next, while he is still
    /// working on this one.
    ///
    /// The point is not to decode faster — a read off his offload drive measured 2.4 s
    /// against 0.4 s from the internal SSD, and no code here changes a bus. The point is
    /// to spend that time BEFORE it is felt. `DecodeWarming` (LumenCore, tested) holds
    /// both halves of the rule: which neighbour, and the gate that keeps a warm from
    /// landing in front of a photographer who is paging rather than editing.
    @MainActor
    private func warmNextPhoto(longEdge: Int) async {
        guard !Task.isCancelled else { return }
        guard DecodeWarming.mayWarm(currentIsSettled: !model.isDraft,
                                    viewerHasPhoto: model.imageURL == photo.id,
                                    gestureInFlight: state.sliderGestureActive)
        else { return }
        let ids = state.photos.map(\.id)
        guard let cursor = ids.firstIndex(of: photo.id) else { return }
        // Forward unless the last move was backward — a photographer who just pressed
        // left is going left again.
        let targets = DecodeWarming.indices(cursor: cursor, count: ids.count,
                                            movingForward: state.movingForward)
        for i in targets {
            guard !Task.isCancelled else { return }
            let url = ids[i]
            await state.renderCoordinator.warmDecode(
                url: url, recipe: state.recipe(for: state.photos[i]), longEdge: longEdge)
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
    private func renderCurrent(longEdge: Int, region: CGRect?,
                               drawnDevice: Double?) async {
        // The same framing-stripped recipe the task key carries — see `renderRecipe`.
        let wanted = renderRecipe
        // `drawnDevice` arrives from `body` rather than being recomputed here: it read
        // `containerSize` (the @State) where the ask read the geometry's own container,
        // and two values that disagree for one layout pass are two decode keys.
        await model.load(url: photo.id,
                         recipe: wanted,
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
                             zoomRatio: state.zoomLevel,
                             drawnDeviceLongEdge: drawnDevice),
                         fullLongEdge: longEdge,
                         strokeSets: state.strokeSets(for: wanted),
                         // While the crop tool is open the loupe shows the frame
                         // WITHOUT its crop, so the rectangle being dragged is drawn
                         // against the frame it is expressed in.
                         showingUncropped: cropArmed,
                         // The proof is what the photographer is looking THROUGH; the
                         // before rendition below deliberately does not get it, because
                         // a before/after of "proofed vs not" is not the comparison the
                         // key is for.
                         softProof: state.activeSoftProof,
                         // Lets the model recognise the one request that is purely the
                         // deferred settle being asked for, so it can skip the draft
                         // and the debounce it does not need.
                         settleTick: state.settleTick,
                         // The zoomed viewport's rectangle, or nil for whole-frame —
                         // computed once in `body` so the key and the render always
                         // agree on it.
                         region: region,
                         drawnDeviceLongEdge: drawnDevice,
                         // Asked at the moment the settle would start rather than at
                         // load time, so a release landing mid-draft settles at once
                         // instead of waiting for the tick's fresh task.
                         gestureInFlight: { state.sliderGestureActive })
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
        // DELIBERATELY NOT GIVEN THE SETTLE GUARD the compare panes just received.
        //
        // The guard SKIPS a settle while a hand is down, and something has to ask for
        // it again afterwards. For the loupe and the panes that is `settleTick` inside
        // `ViewerRenderKey`; `BeforeKey` has no tick, so a guard here would trade a rare
        // extra settle for a before rendition left permanently soft.
        //
        // And the storm the guard exists to stop is not here: `BeforeKey.recipe` is
        // `beforeRecipe`, the recipe with the edited section reverted, which does not
        // move while that section's sliders do. This task therefore fires on a key
        // change rather than per event — at most once at the start of a drag, not
        // dozens of times through it.
    }

    // MARK: Content

    @ViewBuilder
    private func content(container: CGSize) -> some View {
        if let cg = model.image, model.imageURL == photo.id {
            if cropArmed {
                // The crop tool owns the canvas while it is armed — before/after and
                // the ordinary zoomed canvas both wait until the framing is done.
                cropCanvas(cg: cg, container: container)
            } else if viewport.beforeMode.isTwoPane, let before = beforeImage {
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
        // THE SAME FALLBACK THE PANEL USES. `MaskPanel.activeMask` and both keyboard
        // verbs read `activeMaskID ?? masks.first?.id`; this required it non-nil and
        // returned nil otherwise, so `MaskCanvas` was never constructed at all. Nothing
        // sets `activeMaskID` on entering masking and `cursorDidChange` clears it on
        // every photo change — so a photograph with a gradient mask from a previous
        // session showed the row highlighted, the sliders bound and Refine live, with no
        // handles on the picture and dragging doing nothing until you clicked the row.
        // Three readers of one selection, two of them agreeing and this one not.
        guard let id = state.activeMaskID ?? recipe.masks.first?.id,
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
        // What the pixels on screen cover — nil for a whole-frame image. Everything
        // BUT the image layer is laid out against the FULL frame's drawn extent
        // (`drawnFull`): the overlays' geometry, the pan clamp and this ZStack's
        // frame all describe the photograph, not the patch of it that happens to be
        // rendered, so they need no region arithmetic at all.
        let region: CGRect? = model.regionUnit
        let ratio: Double = effectiveRatio(image: cg, container: container)
        let drawn: CGSize = drawnFull(forZoom: state.zoomLevel, image: cg,
                                      container: container)
        let offset: CGSize = LoupeGeometry.clampPan(viewport.pan,
                                                    container: container, drawn: drawn)

        ZStack {
            imageLayer(cg: cg, ratio: ratio, drawn: drawn, region: region)

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
                                sourceSize: sourceFrameSize
                                    ?? CGSize(width: cg.width, height: cg.height),
                                mode: state.maskOverlayMode, tint: state.maskOverlayTint,
                                strength: LoupeViewport.maskOverlayOpacity)
                    .frame(width: drawn.width, height: drawn.height)
            }

            // No crop overlay here: while the tool is armed, `content` routes to
            // `cropCanvas` below and this canvas is never built.

            // Mask geometry is edited on the image, not in the panel: gradients,
            // radials and brush strokes are placed where they land. The canvas is
            // inert unless the masks section is open with a drawable component
            // selected, so it never eats a pan or a click-to-zoom.
            // Gated on masking, not on a section: the mask editor IS the develop column
            // while it is up (`WorkspaceLayout.isMasking`), and the handles on the
            // photograph are the other half of that one surface. Masks used to be one of
            // eight tabs, so editing a gradient meant leaving whatever else you were
            // doing; now the picture and the panel enter and leave together.
            if panel.layout.isMasking, let target = maskEditTarget {
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
                           sourceSize: sourceFrameSize
                               ?? CGSize(width: cg.width, height: cg.height),
                           geometry: recipe.develop.geometry,
                           maskID: target.maskID,
                           componentIndex: target.index,
                           component: target.component,
                           strokes: existingStrokes(target.component),
                           // Every mask, so the ones not being edited are still visible
                           // and their pins are still reachable.
                           allMasks: recipe.masks,
                           selectMask: { id in
                               state.activeMaskID = id
                               state.activeComponentIndex = 0
                               state.flashMaskOverlay(id)
                           }) { edit in
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
                    sourceSize: sourceFrameSize
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

    /// Breathing room while the crop tool is armed: the usable frame is fitted into the
    /// container inset by this much per side, so the picture is never flush against the
    /// panel or the window edge and the corner brackets — which overhang the rectangle
    /// by construction — always have somewhere to be drawn.
    private static let cropInset: CGFloat = 24

    /// The canvas while the crop tool is armed: the FULL frame — rendered with its flip
    /// but with the straighten angle and the crop left off (`renderRecipe`) — turned by
    /// the display tilt right here in the view layer, under the crop overlay sized to
    /// the usable (inscribed) frame. Both are centred on the container, which is what
    /// makes the overlay's bounds exactly the inscribed rectangle of the turning plate.
    ///
    /// Three owner complaints land on this one arrangement (docs/32 Stream B):
    ///   · "when I change the angle it automatically removes all the stuff… instead of
    ///     giving me that gray top/bottom/left/right" — the renderer used to cut the
    ///     picture to the inscribed rectangle per angle event, so tilting LOOKED like a
    ///     re-crop: every edge stayed screen-aligned and the corners simply vanished.
    ///     Now the whole picture visibly turns, and everything outside the rectangle —
    ///     tilted corners included — sits under the overlay's dim.
    ///   · Tilting was janky: the angle rode the recipe into the render key, so every
    ///     rotate-drag event re-ran the whole pipeline. The angle now lives in a
    ///     `rotationEffect`, and a rotate drag renders nothing at all.
    ///   · The frame sat flush against the panel and the brackets clipped at the window
    ///     edge — `cropInset` is the breathing room.
    ///
    /// Zoom and pan are deliberately not honoured here: framing is a whole-frame
    /// judgement (Lightroom's crop tool makes the same call), and a rectangle partly
    /// off screen is a rectangle you cannot frame with. The zoom keys work again the
    /// moment the tool is put away, at whatever level they held.
    @ViewBuilder
    private func cropCanvas(cg: CGImage, container: CGSize) -> some View {
        let source: CGSize = sourceFrameSize
            ?? CGSize(width: cg.width, height: cg.height)
        let geometry: Geometry = recipe.develop.geometry
        let usable = CropGeometry.usableSize(width: Double(source.width),
                                             height: Double(source.height),
                                             degrees: geometry.angle)
        let availW: Double = Double(Swift.max(
            container.width - LoupeView.cropInset * 2, 64))
        let availH: Double = Double(Swift.max(
            container.height - LoupeView.cropInset * 2, 64))
        // Points per source pixel. `usable` is non-degenerate whenever `source` is —
        // and `source` falls back to the delivered image, which has pixels by
        // construction — but the guard keeps a zero out of the division all the same.
        let k: Double = usable.width > 0 && usable.height > 0
            ? Swift.min(availW / usable.width, availH / usable.height)
            : 1
        let usableDrawn = CGSize(width: usable.width * k, height: usable.height * k)
        let plateDrawn = CGSize(width: Double(source.width) * k,
                                height: Double(source.height) * k)
        // The display tilt, clockwise positive: the renderer would have turned the
        // picture by +angle, negated under the mirror (`Straighten`'s derivation) —
        // and the plate this canvas is handed has the flip already applied and the
        // angle left off.
        let tilt: Double = geometry.flipH ? -geometry.angle : geometry.angle
        // Image pixels per device pixel, for `ProxyResampling` — the plate's drawn
        // extent is denominated in SOURCE pixels, which the proxy merely approximates.
        let plateRatio: Double = cg.width > 0
            ? Double(plateDrawn.width) * Double(Swift.max(displayScale, 1)) / Double(cg.width)
            : 1
        ZStack {
            plate(cg, ratio: plateRatio, drawn: plateDrawn, zoomRatio: LoupeZoom.fit)
                .rotationEffect(.degrees(tilt))

            CropOverlayView(crop: cropBinding,
                            geometry: geometry,
                            // The SOURCE frame, not `cg` — the same reason the mask
                            // canvas needs it: the overlay's conversions are stated in
                            // source pixels.
                            sourceSize: source,
                            // The plate above is the frame WITHOUT its crop, and the
                            // overlay is sized to the usable frame. Passed rather than
                            // assumed, because the day that changes the rectangle must
                            // move with it.
                            viewShowsCrop: false,
                            photoID: photo.id,
                            onAngle: { angle in applyRotation(angle) },
                            frameAspect: cropFrameAspect)
                .frame(width: usableDrawn.width, height: usableDrawn.height)

            // Above the crop rectangle, so the ruler's drag belongs to the ruler while
            // it is armed. It lives inside the crop tool because that is the one place
            // the whole straightened frame is on screen — a ruler over an
            // already-cropped picture would be measuring a frame the angle is not
            // expressed in.
            if viewport.showStraighten {
                StraightenOverlayView(
                    currentAngle: geometry.angle,
                    isFlipped: geometry.flipH,
                    onAngle: { angle in applyRotation(angle) },
                    onFinish: { viewport.showStraighten = false })
                    .frame(width: usableDrawn.width, height: usableDrawn.height)
            }
        }
        .frame(width: container.width, height: container.height)
        .clipped()
    }

    /// A turn of the picture — from the rotate drag or the ruler: one write, BOTH
    /// fields. The crop is restated against the new frame (`CropGeometry.reangled`) in
    /// the same recipe write as the angle, so the rectangle keeps its pixel size and
    /// centre — tilting stops being a re-crop, and a locked ratio survives the angle
    /// (docs/31 #10). The Angle slider's binding in `CropPanel` does the same, so all
    /// three hands turn the same mechanism; the shared coalescing key keeps any of
    /// them one undo step.
    private func applyRotation(_ angle: Double) {
        let source: CGSize = sourceFrameSize
            ?? model.image.map { CGSize(width: $0.width, height: $0.height) }
            ?? .zero
        state.updateRecipe(coalescingKey: "straighten") { recipe in
            if source.width > 0, source.height > 0 {
                recipe.develop.geometry.crop = CropGeometry.reangled(
                    recipe.develop.geometry.crop,
                    sourceWidth: Double(source.width),
                    sourceHeight: Double(source.height),
                    from: recipe.develop.geometry.angle, to: angle)
            }
            recipe.develop.geometry.angle = angle
        }
    }

    /// The image itself, honouring the before/after presentation that shares this
    /// canvas's geometry (flip and split; the two-pane modes are handled upstream).
    @ViewBuilder
    private func imageLayer(cg: CGImage, ratio: Double, drawn: CGSize,
                            region: CGRect? = nil) -> some View {
        // The BEFORE plates are always whole-frame — `regionActive` turns the region
        // ask off with any before mode up, and `beforeModel` is never handed one —
        // so they draw at the full extent directly. Only the EDIT's plate can be a
        // region, and it can be one here transiently: a before mode entered while a
        // region is still on screen must flip at once rather than wait out the
        // whole-frame re-render its key change just started.
        if viewport.beforeMode == .split, let before = beforeImage {
            BeforeAfterSplit(split: $viewport.splitPosition) {
                plate(before, ratio: ratio, drawn: drawn)
            } after: {
                afterPlate(cg, ratio: ratio, drawn: drawn, region: region)
            }
            .frame(width: drawn.width, height: drawn.height)
        } else if state.showBefore, let before = beforeImage {
            plate(before, ratio: ratio, drawn: drawn)
        } else {
            afterPlate(cg, ratio: ratio, drawn: drawn, region: region)
        }
    }

    /// The edit's plate, region-aware: whole-frame pixels fill the drawn extent as
    /// ever; region pixels get the region's share of it, centred where the region
    /// sits. The unit rect is top-left origin and SwiftUI's y grows downward, so the
    /// offset is the region centre's departure from the frame centre in both axes
    /// directly. The resampling rule reads the full-frame-EQUIVALENT extent: a
    /// native-sharp region at 1:1 IS the photograph's pixels, and judging it by its
    /// own small extent would smooth exactly the inspection the region was rendered
    /// sharp for.
    @ViewBuilder
    private func afterPlate(_ cg: CGImage, ratio: Double, drawn: CGSize,
                            region: CGRect?) -> some View {
        if let region {
            plate(cg,
                  ratio: Double(Swift.max(drawn.width * region.width,
                                          drawn.height * region.height))
                      * Double(Swift.max(displayScale, 1))
                      / Double(Swift.max(Swift.max(cg.width, cg.height), 1)),
                  drawn: CGSize(width: drawn.width * region.width,
                                height: drawn.height * region.height),
                  resamplingLongEdge: effectiveRenderedLongEdge(cg))
                .offset(x: (region.midX - 0.5) * drawn.width,
                        y: (region.midY - 0.5) * drawn.height)
        } else {
            plate(cg, ratio: ratio, drawn: drawn)
        }
    }

    /// One drawn plate.
    ///
    /// How it is resampled is `ProxyResampling.mode` in LumenCore, where it is tested.
    /// It used to be `ratio >= 1 ? .none : .high` inline — which drew every draft at
    /// fit with nearest-neighbour, because a proxy smaller than the viewport has a
    /// drawn ratio above 1 just as a 1:1 inspection does. See that type for the
    /// arithmetic; the short version is that a 1280 px draft in this pane was magnified
    /// 1.84× unsmoothed, and the ladder's cheaper rungs magnify 3.07× and 4.10×.
    /// `zoomRatio` overrides `state.zoomLevel` for the resampling decision alone — the
    /// crop canvas passes fit, because it lays the plate out at fit whatever the zoom
    /// number still holds, and a stale 1:1 would pick the unsmoothed mode for a plate
    /// that is being scaled.
    /// `resamplingLongEdge` overrides the extent the resampling rule judges — a
    /// region image passes its full-frame equivalent, because its own pixel count is
    /// denominated in the wrong frame (see `effectiveRenderedLongEdge`).
    private func plate(_ cg: CGImage, ratio: Double, drawn: CGSize,
                       zoomRatio: Double? = nil,
                       resamplingLongEdge: Int? = nil) -> some View {
        let resampling = ProxyResampling.mode(
            zoomRatio: zoomRatio ?? state.zoomLevel,
            drawnRatio: ratio,
            renderedLongEdge: resamplingLongEdge ?? Swift.max(cg.width, cg.height),
            fullLongEdge: model.displayFullLongEdge)
        // `[` / `]` are a display gain over the frame already on screen (docs/10 §10.5)
        // — held, never applied. With no hold down this returns `cg` unchanged, so the
        // normal path costs one nil check.
        return Image(decorative: InspectionGain.displayed(cg, hold: state.inspectionHold),
                     scale: 1, orientation: .up)
            .resizable()
            .interpolation(resampling.swiftUIInterpolation)
            .antialiased(resampling != .none)
            .frame(width: drawn.width, height: drawn.height)
            // ISO 12646'S DIFFUSE-WHITE ANCHOR, in assessment mode only.
            //
            // The mid-grey field is a reference, and a reference needs something at
            // display white beside it or the eye adapts to the picture and the grey
            // stops meaning anything — which is the whole mechanism the standard exists
            // to defeat. A thin strip at the image edge is the smallest thing that
            // does it.
            //
            // `strokeBorder` so it grows inward and cannot change where the photograph
            // is drawn: an anchor that moved the picture by two points every time the
            // mode came on would be its own illusion. Off in ordinary use, because a
            // white line around a photograph is a border and this app draws none.
            .overlay(
                Rectangle()
                    .strokeBorder(
                        ViewingConditions.showsWhiteAnchor(assessment: state.assessmentMode)
                            ? Color.white : Color.clear,
                        lineWidth: 2))
    }

    private var unreadable: some View {
        LumenEmptyState(symbol: "exclamationmark.triangle",
                        headline: "Can't read \(photo.filename)",
                        detail: "No RAW decode and no embedded preview. The file is "
                            + "still on disk and untouched.")
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
            if cropArmed {
                // The armed canvas is fit-only (`cropCanvas`), whatever `zoomLevel`
                // still holds from before the tool came up — the badge reports what is
                // on screen, not the number waiting for the tool to close.
                LumenBadge(text: LoupeZoom.label(LoupeZoom.fit))
            } else if state.zoomLevel >= 1, let cg = model.image,
                      effectiveRenderedLongEdge(cg)
                          < (model.displayFullLongEdge ?? Int.max) {
                // The frame on screen has fewer pixels than the settle will deliver —
                // a draft mid-gesture, or the first pass before the native ask lands.
                // Say so. Once the native settle is up the suffix goes, because the
                // pixels ARE the sensor's and "1:1" is the whole claim. Judged by the
                // full-frame EQUIVALENT extent: a native-sharp region is not a proxy,
                // however few pixels its rectangle holds.
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
        // Full-frame drawn extents (`drawnFull`), not the delivered image's: while a
        // REGION is on screen the image's own dims describe the patch, and clamping
        // the kept pan against the patch's short edge would yank the picture toward
        // centre on every pinch event.
        let oldDrawn = drawnFull(forZoom: oldValue, image: cg, container: container)
        let newDrawn = drawnFull(forZoom: newValue, image: cg, container: container)
        let anchor: CGPoint? = viewport.anchorNextZoomAtCursor ? viewport.lastCursor : nil
        let target: CGPoint = anchor
            ?? CGPoint(x: container.width / 2, y: container.height / 2)
        let kept = LoupeGeometry.panKeeping(target, container: container,
                                            oldDrawn: oldDrawn, newDrawn: newDrawn,
                                            pan: viewport.pan)
        viewport.pan = LoupeGeometry.clampPan(kept, container: container, drawn: newDrawn)
        viewport.anchorNextZoomAtCursor = true
    }

    /// What a zoomed render will actually deliver — the basis `zoomLevel` is
    /// denominated against once a gesture has left fit, AND the zoomed ask itself
    /// (`requestedLongEdge`). Read from the SOURCE frame rather than from the current
    /// request, which is what makes the fit zoom continuous across the boundary.
    ///
    /// The cap moved from the interactive ceiling (4096) to the inspection ceiling:
    /// a 7008 px ARW at 1142% was a 4096 proxy blown up into mush, with "1:1"
    /// meaning proxy pixels — the owner's fourth-round screenshots. The basis is the
    /// sensor's own size now, so 1:1 is the photograph's pixels; the metadata frame
    /// size answers first, the first render's own report backs it up, and only a
    /// photo NOBODY knows the size of yet falls back to the fit cap for one pass.
    private var zoomedFullBasis: Int {
        let native = state.primaryFrameSize.map { Int(Swift.max($0.width, $0.height)) }
            ?? model.nativeLongEdge
        guard let native, native > 0 else { return LoupeView.maxRenderLongEdge }
        return ContinuousZoom.zoomedFullLongEdge(
            nativeLongEdge: native,
            renderCap: DraftLadder.inspectionLongEdgeCeiling)
    }

    /// The zoom level at which the picture exactly fills the viewport — the floor the
    /// continuous gestures snap to, expressed in the zoomed denomination.
    ///
    /// Residual, deliberately accepted: on a CROPPED frame the settle delivers fewer
    /// pixels than `zoomedFullBasis` predicts from the source extent, so the drawn
    /// size corrects by that shortfall when the first zoomed settle lands. The
    /// uncropped case — every photograph until someone crops it — is exact.
    private func trueFitZoom(image cg: CGImage, container: CGSize) -> Double {
        // The FULL frame's extent, not the delivered image's: a region image's own
        // dims would compute the zoom at which the PATCH fills the viewport, and the
        // pinch-out snap would land there instead of at fit.
        let fullPx: CGSize = model.regionFullPixel
            ?? CGSize(width: cg.width, height: cg.height)
        let w = Int(fullPx.width.rounded())
        let h = Int(fullPx.height.rounded())
        return ContinuousZoom.fitZoom(
            proxyFitRatio: LoupeGeometry.fitRatio(imageWidth: w,
                                                  imageHeight: h,
                                                  container: container,
                                                  displayScale: displayScale),
            proxyLongEdge: Swift.max(w, h),
            zoomedFullLongEdge: zoomedFullBasis)
    }

    /// One drag gesture, two jobs decided by where it BEGAN: begun at fit it is the
    /// scrubby zoom (press and drag right to zoom in, left to come back — the
    /// Lightroom grammar the owner asked for), begun zoomed it pans. A click — no
    /// travel — does nothing at all: click-to-zoom is deliberately gone, and Space/Z
    /// still toggle from the keymap.
    private func dragGesture(container: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                viewport.lastCursor = value.location
                if viewport.showReadout { cursor = value.location }
                // The crop canvas ignores zoom and pan, so a drag that fell past the
                // overlay must not scrub `zoomLevel` invisibly — the number would sit
                // there, unseen, until the tool was put away and the picture jumped.
                guard !cropArmed else { return }
                guard let cg = model.image else { return }
                if scrubFromFit == nil {
                    scrubFromFit = ZoomLadder.isFit(state.zoomLevel)
                }
                if scrubFromFit == true {
                    // Anchored at the PRESS point, not the moving cursor: the place
                    // the owner aimed at is the place the zoom grows around.
                    let target = ContinuousZoom.scrubbed(
                        startZoom: ZoomLadder.fit,
                        fitRatio: trueFitZoom(image: cg, container: container),
                        horizontalTravel: Double(value.translation.width))
                    viewport.setZoom(target, at: value.startLocation, in: state)
                    return
                }
                let drawn = drawnFull(forZoom: state.zoomLevel, image: cg,
                                      container: container)
                guard drawn.width > container.width || drawn.height > container.height else {
                    return
                }
                if panStart == nil { panStart = viewport.pan }
                let base: CGSize = panStart ?? .zero
                let moved = CGSize(width: base.width + value.translation.width,
                                   height: base.height + value.translation.height)
                viewport.pan = LoupeGeometry.clampPan(moved, container: container, drawn: drawn)
            }
            .onEnded { _ in
                scrubFromFit = nil
                panStart = nil
            }
    }

    /// The trackpad pinch: continuous zoom about the gesture's start point, through
    /// the same `setZoom` verb as every other zoom source. `ContinuousZoom` (LumenCore,
    /// tested) holds the arithmetic — including the snap back to fit, so pinching out
    /// always lands ON fit rather than a hair above it.
    private func magnifyGesture(container: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                // Same guard as the scrub above: the armed canvas is fit-only.
                guard !cropArmed else { return }
                guard let cg = model.image else { return }
                let start = pinchStartZoom ?? state.zoomLevel
                if pinchStartZoom == nil {
                    // Capture the region ask BEFORE this event moves the zoom, so
                    // it matches the key already rendered and the gesture's first
                    // frame re-renders nothing. Held until `onEnded` — see `body`.
                    pinchRegion = requestedRegion(container: container)
                    pinchStartZoom = start
                }
                let target = ContinuousZoom.pinched(
                    startZoom: start,
                    fitRatio: trueFitZoom(image: cg, container: container),
                    magnification: Double(value.magnification))
                viewport.setZoom(target, at: value.startLocation, in: state)
            }
            .onEnded { _ in
                pinchStartZoom = nil
                pinchRegion = nil
            }
    }

    /// One scroll event, applied. The arithmetic is `ViewerScroll`'s; what is left
    /// here is the same two verbs every other zoom and pan source in this file goes
    /// through, so a wheel cannot acquire a private ladder — the two-ladders defect
    /// `ZoomLadder`'s own header says this project has shipped twice.
    @MainActor
    private func applyScroll(_ verb: ViewerScroll.Verb, container: CGSize) {
        // The crop canvas ignores zoom and pan (`cropCanvas`), so a scroll over it
        // must not move either invisibly — the same guard the scrub and the pinch use.
        guard !cropArmed else { return }
        switch verb {
        case .zoom(let factor):
            guard let cg = model.image else { return }
            let target = ContinuousZoom.scrolled(
                currentZoom: state.zoomLevel,
                fitRatio: trueFitZoom(image: cg, container: container),
                factor: factor)
            // Under the pointer, like every other zoom this app has: the cursor is
            // where the photographer is looking, and `onContinuousHover` already
            // tracks it for exactly this.
            viewport.setZoom(target, at: viewport.lastCursor, in: state)
        case .pan(let dx, let dy):
            viewport.panBy(CGSize(width: dx, height: dy))
            let drawn: CGSize = model.image.map {
                drawnFull(forZoom: state.zoomLevel, image: $0, container: container)
            } ?? container
            viewport.pan = LoupeGeometry.clampPan(viewport.pan,
                                                  container: container, drawn: drawn)
        case .ignore:
            break
        }
    }

    /// Arrows page the selection at fit, and pan when zoomed in — the key means the
    /// thing you are looking at, which is the keymap's scope rule (docs/12 §B3).
    private func handleMove(_ direction: MoveCommandDirection) {
        let step: CGFloat = 80
        // While the crop tool is armed the canvas ignores zoom and pan, so the arrows
        // page the roll whatever `zoomLevel` happens to hold — panning a pan nothing
        // draws would make the keys read as dead.
        if state.zoomLevel > 0 && !cropArmed {
            switch direction {
            case .left: viewport.panBy(CGSize(width: step, height: 0))
            case .right: viewport.panBy(CGSize(width: -step, height: 0))
            case .up: viewport.panBy(CGSize(width: 0, height: step))
            case .down: viewport.panBy(CGSize(width: 0, height: -step))
            @unknown default: break
            }
            let drawn: CGSize = model.image.map {
                drawnFull(forZoom: state.zoomLevel, image: $0, container: containerSize)
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
    /// render queue. Zoomed, the ask is the SOURCE'S OWN LONG EDGE — that is what
    /// makes "1:1" mean the sensor's pixels: the drawn extent is `zoom × ask`
    /// (`LoupeGeometry.zoomedRatio` normalizes every proxy to it), so an ask below
    /// native denominates the zoom in proxy pixels and draws mush at depth — the
    /// owner's 1142% screenshot of a 4096 proxy of a 7008 px ARW. Until the native
    /// size is known (the first result carries it) the fit cap stands in, and the
    /// key moving re-asks. The ladder still sizes DRAFTS below the rung ceiling;
    /// only the settle pays the native price, at rest.
    private func requestedLongEdge(container: CGSize,
                                   drawnDeviceLongEdge: Double? = nil) -> Int {
        if state.zoomLevel > 0 {
            // THE ASK IS THE DENOMINATION BASIS, one value — `zoomedFullBasis` also
            // feeds the pinch math and the fit-snap, so asking for anything else
            // would draw at one size and gesture at another.
            return Swift.max(zoomedFullBasis, 64)
        }
        let scale = Double(Swift.max(displayScale, 1))
        let longEdge = Double(Swift.max(container.width, container.height)) * scale
        guard longEdge.isFinite, longEdge > 0 else { return 1024 }
        let bucket = Int((longEdge / 256).rounded(.up)) * 256
        let asked = Swift.min(Swift.max(bucket, 640), LoupeView.maxRenderLongEdge)
        // AND NOT ONE PIXEL MORE THAN THE PANEL DRAWS. The bucket is the CONTAINER's
        // long edge; a portrait photograph in a landscape pane is fitted by its height
        // and occupies far less. Rendering the difference is rendering pixels that the
        // downsample to the panel discards — invisible by construction, which is what
        // makes this free.
        //
        // The same ceiling already bounded the DRAFT (`DraftResolution.draftLongEdge`),
        // and applying it to only one of the two passes was the expensive half of the
        // mistake: the settle then asked a different size, and a different size is a
        // different `DecodeKey`, so every photograph paid two full RAW demosaics — the
        // one it shows and one it discards (docs/34 §3).
        guard let ceiling = DraftResolution.visibleCeiling(drawnDeviceLongEdge) else {
            return asked
        }
        return Swift.max(Swift.min(asked, ceiling), 64)
    }

    // MARK: Region rendering

    /// Whether the current render may ask for a REGION of the frame rather than all
    /// of it — the fifth-round mechanism (`ZoomRegion`'s header): zoomed, a
    /// whole-frame render pays for pixels nobody can see, and the draft ladder
    /// steps to its coarse rungs exactly when the magnification makes them
    /// unwatchable.
    ///
    /// Zoomed only — fit is whole-frame by definition. Every consumer that reads
    /// the on-screen raster AS the whole frame forces whole-frame rendering: the
    /// clipping and mask overlays draw from a sampler whose pixels they take to
    /// cover the full extent, the before modes put frames beside each other that
    /// must match, the mask canvas is gated conservatively with them, and the crop
    /// tool lays the canvas out its own way entirely.
    private var regionActive: Bool {
        state.zoomLevel > 0
            && !cropArmed
            && state.clippingOverlay == nil
            && state.soloMaskOverlay == nil
            && !panel.layout.isMasking
            && !needsBeforeRender
    }

    /// The zoomed region ask for the current viewport, or nil for whole-frame.
    /// Pure arithmetic over the same drawn frame and clamped pan the canvas lays
    /// out with — `ZoomRegion` (LumenCore, tested) holds the rectangle rule.
    private func requestedRegion(container: CGSize) -> CGRect? {
        guard regionActive, let cg = model.image, model.imageURL == photo.id else {
            return nil
        }
        let drawn = drawnFull(forZoom: state.zoomLevel, image: cg, container: container)
        let pan = LoupeGeometry.clampPan(viewport.pan, container: container, drawn: drawn)
        return ZoomRegion.requestUnit(container: container, drawnFull: drawn, pan: pan)
    }

    /// The FULL delivered frame's drawn extent at `zoom` — what every layout
    /// quantity (the canvas frame, the pan clamp, the region ask, the readout's
    /// unit conversion) is denominated in, whether the pixels on screen cover the
    /// whole frame or a region of it.
    ///
    /// For a whole-frame image this is exactly the old `drawnSize(effectiveRatio)`
    /// arithmetic — the delivery's `fullPixelSize` IS the image's extent there. For
    /// a region image the full extent comes from the same delivery, normalized by
    /// the same rule (`zoomedRatio`), so the drawn frame does not change size when
    /// a region result replaces a whole-frame one or the other way round.
    private func drawnFull(forZoom zoom: Double, image cg: CGImage,
                           container: CGSize) -> CGSize {
        let fullPx: CGSize = model.regionFullPixel
            ?? CGSize(width: cg.width, height: cg.height)
        let w = Int(fullPx.width.rounded())
        let h = Int(fullPx.height.rounded())
        let ratio: Double = zoom > 0
            ? LoupeGeometry.zoomedRatio(zoomLevel: zoom,
                                        fullLongEdge: model.displayFullLongEdge
                                            ?? Swift.max(w, h),
                                        renderedLongEdge: Swift.max(w, h))
            : LoupeGeometry.fitRatio(imageWidth: w, imageHeight: h,
                                     container: container, displayScale: displayScale)
        return LoupeGeometry.drawnSize(imageWidth: w, imageHeight: h,
                                       ratio: ratio, displayScale: displayScale)
    }

    /// The full-frame-EQUIVALENT long edge of the frame on screen — for a region
    /// image, what a whole-frame render at the same sharpness would have measured.
    /// The badge and the resampling rule both compare against the settle's full
    /// extent, and a region's own pixel count is denominated in the wrong frame:
    /// a native-sharp 1900 px region of a 7008 px photograph is not a proxy.
    private func effectiveRenderedLongEdge(_ cg: CGImage) -> Int {
        let long = Swift.max(cg.width, cg.height)
        guard let region = model.regionUnit else { return long }
        // BOTH axes, and the larger answer — not "the region image's long edge over
        // its own fraction". A region has its own aspect: a tall strip of a landscape
        // frame is a portrait image, so picking the axis by the IMAGE's orientation
        // reconstructs the frame's SHORT edge and badges a native-sharp inspection
        // PROXY. Each axis independently reconstructs the full frame's extent on that
        // axis; the frame's long edge is the larger of the two.
        var estimate = 0.0
        if region.width > 0 { estimate = Double(cg.width) / Double(region.width) }
        if region.height > 0 {
            estimate = Swift.max(estimate, Double(cg.height) / Double(region.height))
        }
        guard estimate.isFinite, estimate > 0 else { return long }
        return Int(estimate.rounded())
    }

    // MARK: Readout

    /// Whether anything on screen actually reads the sampler right now. It used to be
    /// rebuilt unconditionally on every rendered frame — a full-resolution draw and up
    /// to ~45 MB of allocation per draft AND settle, for a readout usually not under
    /// the cursor and overlays usually off. The task key carries this flag, so turning
    /// an overlay on (or the cursor arriving with the readout enabled) builds it then,
    /// at the cost of the readout appearing one build later instead of instantly.
    private var samplerNeeded: Bool {
        // Not while the crop tool is armed: the armed canvas draws neither the readout
        // nor the raster overlays (the plate is rotated in the view layer, which none
        // of their geometry accounts for), so a sampler built from it would only feed
        // misplaced answers.
        guard !cropArmed else { return false }
        return (viewport.showReadout && cursor != nil)
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
        // The armed canvas lays the picture out its own way (`cropCanvas`), which this
        // arithmetic does not describe — and `samplerNeeded` has already declined to
        // build a sampler for it.
        guard !cropArmed else { return nil }
        guard viewport.showReadout, let cg = model.image, let sampler else { return nil }
        // The FULL frame's drawn extent — the same one the canvas laid out with —
        // so the cursor's unit point is denominated in the photograph.
        let drawn = drawnFull(forZoom: state.zoomLevel, image: cg, container: container)
        let pan = LoupeGeometry.clampPan(viewport.pan, container: container, drawn: drawn)
        guard let unit = LoupeGeometry.imageUnitPoint(point, container: container,
                                                      drawn: drawn, pan: pan) else {
            return nil
        }
        var u = Double(unit.x)
        var v = Double(unit.y)
        // The sampler holds the REGION's pixels when one is up: map the full-frame
        // unit into the region's own space, and decline points outside it — the
        // margin means the visible frame is inside by construction, so this only
        // refuses the sliver a pan can expose before its re-render lands.
        if let region = model.regionUnit {
            guard region.width > 0, region.height > 0 else { return nil }
            u = (u - Double(region.minX)) / Double(region.width)
            v = (v - Double(region.minY)) / Double(region.height)
            guard u >= 0, u <= 1, v >= 0, v <= 1 else { return nil }
        }
        return sampler.readout(u: u, v: v, space: state.readoutSpace)
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
        guard let size = sourceFrameSize, size.width > 0, size.height > 0 else {
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
