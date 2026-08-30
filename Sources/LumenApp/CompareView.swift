// CompareView.swift
// The two compare canvases (docs/12 §B1: `C` and `N` are views of one context, not
// modules): 2-up compare with synced zoom and pan, and the N-up survey grid. Both are
// driven by `AppState.selectedPhotos` — selecting is how you populate a comparison,
// which is why neither view has an "add to compare" ceremony of its own.
//
// Zoom and pan sync as an image-normalized centre point rather than as a pixel offset,
// so two frames of different pixel dimensions still hold the same part of the picture
// under the same part of the window. Every pane renders through `PhotoRenderModel`, the
// same two-tier draft-then-quality driver the loupe uses — no second preview system.

#if os(macOS)

import AppKit
import CoreGraphics
import Foundation
import LumenCore
import SwiftUI

// MARK: - Layout

enum CompareLayout: String, CaseIterable, Identifiable, Sendable {
    /// `C` — two frames, synced.
    case twoUp
    /// `N` — as many frames as are selected, each fit.
    case survey

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .twoUp: return "Compare"
        case .survey: return "Survey"
        }
    }
}

/// The shared viewport for a 2-up compare: one ratio and one image-normalized centre,
/// so both panes move together whatever their pixel dimensions.
final class CompareSync: ObservableObject {

    /// 0 = fit, otherwise a ratio of image pixels to device pixels.
    @Published var zoom: Double = 0
    /// The point of the picture held at the centre of each pane, in unit coordinates
    /// with the origin at the top-left.
    @Published var center: CGPoint = CGPoint(x: 0.5, y: 0.5)

    func fit() {
        zoom = ZoomLadder.fit
        center = CGPoint(x: 0.5, y: 0.5)
    }

    func setZoom(_ ratio: Double, at unitPoint: CGPoint?) {
        let clamped: Double = ZoomLadder.clamp(ratio)
        zoom = clamped
        if ZoomLadder.isFit(clamped) {
            center = CGPoint(x: 0.5, y: 0.5)
        } else if let unitPoint {
            center = unitPoint
        }
    }

    /// The same rung the loupe's Space and Z land on, from the same function. A third
    /// implementation of "fit ↔ 1:1" is a third chance for the panes and the viewer to
    /// disagree about where a key lands.
    func toggleZoom(at unitPoint: CGPoint?) {
        setZoom(ZoomLadder.toggleTarget(from: zoom), at: unitPoint)
    }
}

// MARK: - Compare

struct CompareView: View {

    @EnvironmentObject var state: AppState
    /// This surface shows the edit, so it observes the edit signal —
    /// `AppState.recipes` is deliberately not published (see `EditRevision`).
    @EnvironmentObject var edits: EditRevision
    /// Pass a layout to pin one; leave it nil and the view follows `AppState.viewMode`,
    /// so `C` and `N` reach the same view without the shell having to know which.
    var layout: CompareLayout?

    @StateObject private var sync: CompareSync = CompareSync()

    private var effectiveLayout: CompareLayout {
        if let layout { return layout }
        return state.viewMode == .survey ? .survey : .twoUp
    }

    var body: some View {
        Group {
            if comparisonSet.isEmpty {
                empty
            } else if effectiveLayout == .survey {
                survey
            } else {
                twoUp
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Lumen.viewerBackground)
    }

    /// What is being compared. The rule lives on `AppState` because the arrow keys move
    /// the cursor INSIDE this set and must be looking at the same set the panes draw;
    /// a copy here is how the key and the view come to disagree.
    private var comparisonSet: [PhotoItem] { state.comparisonSet }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 34))
            Text("Select two or more photos to compare")
                .font(.system(size: 12))
        }
        .foregroundStyle(Lumen.secondaryText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 2-up

    private var twoUp: some View {
        // The window follows the cursor rather than being the first two, always. With
        // three or more frames selected, `prefix(2)` meant → moved the cursor to member
        // four while these two panes stayed on members one and two — the highlight left
        // the canvas and the key that cycles the candidate did nothing anyone could see.
        // With two selected, which is the ordinary compare, this is the same pair.
        let set = comparisonSet
        let cursor = set.firstIndex { $0.id == state.primarySelection?.id }
        let window = ComparePanes.pairWindow(cursor: cursor, count: set.count)
        let pair = Array(set[window])
        return HStack(spacing: 1) {
            ForEach(pair) { photo in
                ComparePane(photo: photo,
                            sync: sync,
                            isPrimary: photo.id == state.primarySelection?.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // The cursor verb's double-click lives INSIDE the pane's own
                    // drag gesture (clickCount, the LumenControls way) — a tap
                    // gesture attached here sat behind the pane's
                    // minimumDistance-0 drag and never fired.
            }
            if pair.count == 1 {
                VStack(spacing: 6) {
                    Image(systemName: "plus.rectangle")
                        .font(.system(size: 26))
                    Text("Select a second photo")
                        .font(.system(size: 11))
                }
                .foregroundStyle(Lumen.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Lumen.viewerBackground)
            }
        }
        .overlay(alignment: .topTrailing) {
            LumenBadge(text: LoupeZoom.label(sync.zoom))
                .padding(8)
                .allowsHitTesting(false)
        }
    }

    // MARK: N-up survey

    private var survey: some View {
        GeometryReader { geometry in
            let count = Swift.max(comparisonSet.count, 1)
            let minimum = surveyCellMinimum(count: count, in: geometry.size)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: 6)],
                          spacing: 6) {
                    ForEach(comparisonSet) { photo in
                        SurveyCell(photo: photo,
                                   isPrimary: photo.id == state.primarySelection?.id)
                            .frame(height: minimum * 0.78)
                            .onTapGesture { state.moveCursor(to: photo) }
                    }
                }
                .padding(6)
            }
            // docs/30: every scroll view in the app is silent. A legacy scroller insets
            // its content, so an indicator appearing is a relayout of everything inside it.
            .scrollIndicators(.never)
        }
    }

    /// Aim for roughly square tiles that use the pane without producing one enormous
    /// cell for a survey of two. Guarded against a zero-sized container.
    private func surveyCellMinimum(count: Int, in size: CGSize) -> CGFloat {
        let width = size.width > 0 ? size.width : 900
        let columns = CGFloat(Swift.max(1, Int(Double(count).squareRoot().rounded(.up))))
        let candidate = (width - 12) / columns - 6
        return Swift.min(Swift.max(candidate, 160), 520)
    }
}

// MARK: - Synced pane

/// One frame of a 2-up compare. Reads its ratio and centre from the shared `CompareSync`
/// and writes both back when dragged or clicked, so the other pane follows within the
/// same frame.
private struct ComparePane: View {

    @EnvironmentObject var state: AppState
    @EnvironmentObject var edits: EditRevision
    let photo: PhotoItem
    @ObservedObject var sync: CompareSync
    let isPrimary: Bool

    @StateObject private var model: PhotoRenderModel = PhotoRenderModel()
    @Environment(\.displayScale) private var displayScale: CGFloat
    @State private var dragStartCenter: CGPoint?
    /// The press turned out to be the cursor verb's double-click; swallow the rest
    /// of the gesture so it neither pans nor toggles zoom on release.
    @State private var pressWasCursorMove = false

    var body: some View {
        GeometryReader { geometry in
            let container = geometry.size
            let longEdge: Int = requestedLongEdge(container: container)
            ZStack(alignment: .bottomLeading) {
                Lumen.viewerBackground

                if let cg = model.image, model.imageURL == photo.id {
                    plate(cg, container: container)
                } else if model.isUnreadable {
                    Text("Can't read \(photo.filename)")
                        .font(.system(size: 11))
                        .foregroundStyle(Lumen.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                VStack(alignment: .leading, spacing: 4) {
                    if model.usedEmbeddedPreview, model.imageURL == photo.id {
                        LumenBadge(text: "EMBEDDED PREVIEW", emphasized: true)
                    }
                    if let note = model.note {
                        LumenBadge(text: note, emphasized: true)
                    }
                    LumenBadge(text: photo.filename)
                }
                .padding(8)
                .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .contentShape(Rectangle())
            .gesture(dragGesture(container: container))
            .overlay {
                Rectangle()
                    .strokeBorder(isPrimary ? Lumen.fillColor : Lumen.separator,
                                  lineWidth: isPrimary ? 2 : 1)
                    .allowsHitTesting(false)
            }
            .task(id: ViewerRenderKey.current(url: photo.id,
                                              recipe: state.recipe(for: photo),
                                              longEdge: longEdge, state: state)) {
                await render(longEdge: longEdge)
            }
        }
    }

    @MainActor
    private func render(longEdge: Int) async {
        let recipe = state.recipe(for: photo)
        await model.load(url: photo.id,
                         recipe: recipe,
                         coordinator: state.renderCoordinator,
                         thumbnails: state.thumbnails,
                         // `DraftResolution`, exactly as the loupe: a fixed draft size
                         // above fit drew the photograph at half size and doubled it on
                         // every render — the zoom pump, fixed in the loupe and still
                         // live here until this line.
                         draftLongEdge: DraftResolution.draftLongEdge(
                             settledLongEdge: longEdge,
                             fitLongEdge: LoupeView.draftLongEdge,
                             zoomRatio: sync.zoom),
                         fullLongEdge: longEdge,
                         strokeSets: state.strokeSets(for: recipe),
                         // ⇧S must mean the same thing in E and C: the loupe passes
                         // the proof, so the panes do too.
                         softProof: state.activeSoftProof,
                         // THE TWO ARGUMENTS THE LOUPE PASSES AND THESE PANES DID NOT.
                         //
                         // `PhotoRenderModel.load` defaults them to `0` and `{ false }`,
                         // so every event of a slider drag scheduled a FULL-RESOLUTION
                         // settle from these panes — on the same serial coordinator the
                         // loupe's drafts queue on, whose passes have no cancellation
                         // points. That is verbatim the defect the loupe documents and
                         // fixed in one place only: "once one started every event behind
                         // it waited 100-300 ms for a lane that could not be given
                         // back." With a pane open it lands in the loupe's own frame
                         // interval as a scattered several-hundred-millisecond gap,
                         // which is exactly what the owner's HUD reported.
                         //
                         // Passing `settleTick` is not optional alongside the guard: the
                         // guard SKIPS a settle during the gesture, and the tick moving
                         // at release is what asks for it again. `ViewerRenderKey`
                         // already carries the tick, so the task re-fires and the pane
                         // settles once, at rest — the loupe's exact bargain. It also
                         // gives these panes' ladders their `gestureEnded()`, which they
                         // have never once received.
                         settleTick: state.settleTick,
                         gestureInFlight: { state.sliderGestureActive },
                         )
    }

    // MARK: Geometry

    private func ratio(for cg: CGImage, container: CGSize) -> Double {
        if sync.zoom > 0 {
            // Normalized for proxy resolution, exactly as the loupe (MAC-07): a bare
            // `sync.zoom` drew a 2048-px draft at half the size of its 4096-px settle
            // and doubled it back per event — the zoom pump, fixed in the loupe and
            // still alive here through the DRAW ratio (the request size above was
            // fixed first and the fix stopped one line short).
            return LoupeGeometry.zoomedRatio(
                zoomLevel: sync.zoom,
                fullLongEdge: model.displayFullLongEdge
                    ?? Swift.max(cg.width, cg.height),
                renderedLongEdge: Swift.max(cg.width, cg.height))
        }
        return LoupeGeometry.fitRatio(imageWidth: cg.width, imageHeight: cg.height,
                                      container: container, displayScale: displayScale)
    }

    /// Pan that puts the shared centre point at the centre of this pane, clamped so the
    /// image can never be dragged off screen.
    private func offset(for cg: CGImage, container: CGSize, drawn: CGSize) -> CGSize {
        let raw = CGSize(width: -(sync.center.x - 0.5) * drawn.width,
                         height: -(sync.center.y - 0.5) * drawn.height)
        return LoupeGeometry.clampPan(raw, container: container, drawn: drawn)
    }

    private func plate(_ cg: CGImage, container: CGSize) -> some View {
        let r = ratio(for: cg, container: container)
        let drawn = LoupeGeometry.drawnSize(imageWidth: cg.width, imageHeight: cg.height,
                                            ratio: r, displayScale: displayScale)
        // The inspection holds work in Compare too (docs/10 §10.5 names loupe, survey
        // and compare), and a hold that lifted one pane and not the other would be
        // worse than none.
        return Image(decorative: InspectionGain.displayed(cg, hold: state.inspectionHold),
                     scale: 1, orientation: .up)
            .resizable()
            .interpolation(r >= 1 ? .none : .high)
            .antialiased(r < 1)
            .frame(width: drawn.width, height: drawn.height)
            .offset(offset(for: cg, container: container, drawn: drawn))
            .frame(width: container.width, height: container.height)
            .clipped()
    }

    private func dragGesture(container: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // The cursor verb's double-click, read the way every control behind a
                // minimumDistance-0 drag has to read it (LumenControls): the outer
                // onTapGesture(count: 2) never fired behind this drag, and the press
                // fell through to onEnded's sub-3-pt branch — so double-clicking a
                // pane to move the cursor toggled 1:1 instead, twice.
                if dragStartCenter == nil, !pressWasCursorMove,
                   let event = NSApp.currentEvent, event.clickCount >= 2 {
                    pressWasCursorMove = true
                    return
                }
                if pressWasCursorMove { return }
                guard let cg = model.image else { return }
                let r = ratio(for: cg, container: container)
                let drawn = LoupeGeometry.drawnSize(imageWidth: cg.width,
                                                    imageHeight: cg.height,
                                                    ratio: r, displayScale: displayScale)
                guard drawn.width > 0, drawn.height > 0 else { return }
                guard drawn.width > container.width || drawn.height > container.height else {
                    return
                }
                let base = dragStartCenter ?? sync.center
                if dragStartCenter == nil { dragStartCenter = base }
                let moved = CGSize(width: -(base.x - 0.5) * drawn.width + value.translation.width,
                                   height: -(base.y - 0.5) * drawn.height + value.translation.height)
                let clamped = LoupeGeometry.clampPan(moved, container: container, drawn: drawn)
                sync.center = CGPoint(x: 0.5 - clamped.width / drawn.width,
                                      y: 0.5 - clamped.height / drawn.height)
            }
            .onEnded { value in
                if pressWasCursorMove {
                    pressWasCursorMove = false
                    state.moveCursor(to: photo)
                    return
                }
                dragStartCenter = nil
                let travel = abs(value.translation.width) + abs(value.translation.height)
                guard travel < 3 else { return }
                guard let cg = model.image else {
                    sync.toggleZoom(at: nil)
                    return
                }
                let r = ratio(for: cg, container: container)
                let drawn = LoupeGeometry.drawnSize(imageWidth: cg.width,
                                                    imageHeight: cg.height,
                                                    ratio: r, displayScale: displayScale)
                let pan = offset(for: cg, container: container, drawn: drawn)
                let unit = LoupeGeometry.imageUnitPoint(value.location, container: container,
                                                        drawn: drawn, pan: pan)
                sync.toggleZoom(at: unit)
            }
    }

    private func requestedLongEdge(container: CGSize) -> Int {
        // DELIBERATELY still the interactive cap, where the loupe went native
        // (docs/32 owner round): compare renders one frame PER PANE, and N native
        // planes at 260 MB each is a different budget than one. A pixel-level verdict
        // belongs to the loupe; if the owner wants native compare at 1:1, this is the
        // one line, and the decode-cache inspection rule already handles residency.
        if sync.zoom > 0 { return LoupeView.maxRenderLongEdge }
        let scale = Double(Swift.max(displayScale, 1))
        let longEdge = Double(Swift.max(container.width, container.height)) * scale
        guard longEdge.isFinite, longEdge > 0 else { return 1024 }
        let bucket = Int((longEdge / 256).rounded(.up)) * 256
        return Swift.min(Swift.max(bucket, 640), LoupeView.maxRenderLongEdge)
    }
}

// MARK: - Survey cell

/// One frame of the N-up survey: always fit, no zoom, and a reject affordance so the
/// survey narrows the way culling actually works — you take frames out until the keeper
/// is the one left.
private struct SurveyCell: View {

    @EnvironmentObject var state: AppState
    @EnvironmentObject var edits: EditRevision
    let photo: PhotoItem
    let isPrimary: Bool

    @StateObject private var model: PhotoRenderModel = PhotoRenderModel()
    @Environment(\.displayScale) private var displayScale: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let container = geometry.size
            let longEdge: Int = requestedLongEdge(container: container)
            ZStack(alignment: .bottomLeading) {
                Lumen.viewerBackground

                if let cg = model.image, model.imageURL == photo.id {
                    Image(decorative: InspectionGain.displayed(cg,
                                                               hold: state.inspectionHold),
                          scale: 1, orientation: .up)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.isUnreadable {
                    Text("Can't read \(photo.filename)")
                        .font(.system(size: 10))
                        .foregroundStyle(Lumen.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                VStack(alignment: .leading, spacing: 3) {
                    if model.usedEmbeddedPreview, model.imageURL == photo.id {
                        LumenBadge(text: "EMBEDDED PREVIEW", emphasized: true)
                    }
                    LumenBadge(text: photo.filename)
                }
                .padding(6)
                .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .overlay(alignment: .topTrailing) {
                Button {
                    state.selection.remove(photo.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(4)
                        .background(Color.black.opacity(0.55), in: Circle())
                        .foregroundStyle(Lumen.primaryText)
                }
                .buttonStyle(.plain)
                .padding(5)
                .help("Remove \(photo.filename) from the survey")
            }
            .overlay {
                Rectangle()
                    .strokeBorder(isPrimary ? Lumen.fillColor : Lumen.separator,
                                  lineWidth: isPrimary ? 2 : 1)
                    .allowsHitTesting(false)
            }
            .task(id: ViewerRenderKey.current(url: photo.id,
                                              recipe: state.recipe(for: photo),
                                              longEdge: longEdge, state: state)) {
                await render(longEdge: longEdge)
            }
        }
    }

    @MainActor
    private func render(longEdge: Int) async {
        let recipe = state.recipe(for: photo)
        await model.load(url: photo.id,
                         recipe: recipe,
                         coordinator: state.renderCoordinator,
                         thumbnails: state.thumbnails,
                         // Survey panes have no zoom; DraftResolution at fit returns
                         // the floor, so this stays the cheap 512 draft it was — but
                         // through the shared rule rather than a bare number.
                         draftLongEdge: DraftResolution.draftLongEdge(
                             settledLongEdge: longEdge,
                             fitLongEdge: 512,
                             zoomRatio: 0),
                         fullLongEdge: longEdge,
                         strokeSets: state.strokeSets(for: recipe),
                         softProof: state.activeSoftProof,
                         // Same two arguments, same reason — see the compare pane
                         // above. A survey grid renders many panes, so the settle storm
                         // this removes is multiplied by however many are on screen.
                         settleTick: state.settleTick,
                         gestureInFlight: { state.sliderGestureActive },
                         )
    }

    private func requestedLongEdge(container: CGSize) -> Int {
        let scale = Double(Swift.max(displayScale, 1))
        let longEdge = Double(Swift.max(container.width, container.height)) * scale
        guard longEdge.isFinite, longEdge > 0 else { return 640 }
        let bucket = Int((longEdge / 256).rounded(.up)) * 256
        return Swift.min(Swift.max(bucket, 512), 2048)
    }
}

#endif
