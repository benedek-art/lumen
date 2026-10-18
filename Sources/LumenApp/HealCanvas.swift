// HealCanvas.swift
// The Heal tool (docs/09 §Heal / Clone, docs/12 §12.3 `Q`): circular spots placed on
// the photograph, the first slice of retouching.
//
//   Q              arms the tool on the loupe; Q again or Esc puts it away
//   click          a new spot at the pointer — Heal or Clone, at the bar's size,
//                  feather and opacity — with its source chosen by `SpotSourceSearch`
//   drag a circle  the solid one moves the spot, the dashed one moves its source
//   /              re-picks the selected spot's source: the next-best, cycling
//   Brush mode     a drag paints a heal STROKE, healed along its length from one
//                  offset `StrokeSourceSearch` picks (a click is a dab); in Spot mode
//                  a click on a stroke selects it
//   ⌫              deletes the selected spot or stroke
//
// What a press MEANS is `SpotHandles`, in LumenCore where it is tested; this file draws
// and routes. Every write goes through `AppState.updateRecipe` with the PRIMARY photo as
// its only target: a spot is put on a blemish in one photograph, and writing it through
// the selection would stamp the same blemish fix onto every other selected frame.
//
// Spots live in SOURCE coordinates (`HealSpot`), so every gesture is converted through
// the inverse of the geometry the preview was rendered with, exactly as `MaskCanvas`
// converts — a crop or a straighten never moves a spot off its blemish.

#if os(macOS)

import AppKit
import CoreGraphics
import Foundation
import LumenCore
import LumenPipeline
import SwiftUI

// MARK: - Tool state

/// The Heal tool's session state: whether it is armed, which spot is selected, and the
/// settings the NEXT spot is placed with. Session state by design — a spot records its
/// own mode, size, feather and opacity in the recipe when it is placed.
final class HealTool: ObservableObject {
    static let shared = HealTool()

    @Published var armed: Bool = false
    @Published var selectedSpotID: String?
    @Published var mode: HealMode = .heal
    /// Fraction of the source long edge, as `HealSpot.radius`.
    @Published var radius: Double = HealSpot.defaultRadius
    @Published var feather: Double = HealSpot.defaultFeather
    @Published var opacity: Double = HealSpot.defaultOpacity
    /// Visualize Spots (docs/09): the loupe shows `SpotVisualization`'s inverted
    /// band-pass instead of the photograph, so dust can be found. A view setting —
    /// session state, never in the recipe, never rendered.
    @Published var visualize: Bool = false
    @Published var visualizeThreshold: Double = SpotVisualization.defaultThreshold
    /// Brush mode: a drag on clear space paints a heal stroke instead of doing nothing.
    @Published var brush: Bool = false
    /// The selected painted stroke, by its index in the heal stroke set. Exclusive with
    /// `selectedSpotID` — one thing is selected, so ⌫ has one meaning.
    @Published var selectedStrokeIndex: Int?
}

struct HealCanvasToolSettings: Equatable {
    let mode: HealMode
    let radius: Double
    let feather: Double
    let opacity: Double
    let brush: Bool

    @MainActor init() {
        let tool = HealTool.shared
        mode = tool.mode
        radius = tool.radius
        feather = tool.feather
        opacity = tool.opacity
        brush = tool.brush
    }
}

/// The coordinate basis used to interpret the press, checked synchronously on
/// every changed/released callback rather than waiting for lifecycle observation.
struct HealCanvasMapping: Equatable {
    let imageRect: CGRect
    let sourceSize: CGSize

    func accepts(imageRect: CGRect, sourceSize: CGSize) -> Bool {
        self.imageRect == imageRect && self.sourceSize == sourceSize
    }
}

/// The photograph and retouch state a pointer press actually began on. Whole-heal
/// equality also catches undo, deleted/replaced spots and changes to prior donors.
struct HealCanvasEditContext: Equatable {
    let url: URL
    let catalogID: Int64?
    let source: SourceFileIdentity?
    let geometry: Geometry
    var expected: Heal
    let tool: HealCanvasToolSettings

    @MainActor init(photo: PhotoItem, recipe: Recipe) {
        url = photo.id
        catalogID = photo.catalogID
        source = photo.sourceIdentity ?? SourceFileIdentity.read(photo.id)
        geometry = recipe.develop.geometry
        expected = recipe.develop.heal
        tool = HealCanvasToolSettings()
    }

    func sameTarget(as other: Self) -> Bool {
        url == other.url && catalogID == other.catalogID && source == other.source
            && geometry == other.geometry && tool == other.tool
    }

    @MainActor
    func isCurrent(in state: AppState) -> Bool {
        state.healCanvasContextIsCurrent(self)
    }
}

enum HealCanvasEdit {
    case move(HealSpot)
    case add(x: Double, y: Double)
    case paint([BrushPoint])
}

// MARK: - Verbs

extension AppState {
    /// Kept on AppState so the non-View context only delegates. HealCanvas is the
    /// observing leaf; toolbar actions invoke this check directly on the main actor.
    func healCanvasContextIsCurrent(_ context: HealCanvasEditContext) -> Bool {
        guard let photo = primarySelection, photo.id == context.url,
              photo.catalogID == context.catalogID, let source = context.source,
              SourceFileIdentity.read(context.url) == source else { return false }
        let current = recipe(for: photo)
        return current.develop.geometry == context.geometry
            && current.develop.heal == context.expected
    }

    /// Canvas-only boundary. Toolbar verbs remain independent, explicit actions.
    /// A reachable original is required, just as for mask gestures. This stat token
    /// detects filesystem generations, not byte-level content equivalence.
    func applyHealCanvasEdit(_ edit: HealCanvasEdit,
                             context: HealCanvasEditContext) -> Heal? {
        func refuse() -> Heal? {
            if statusMessage == nil {
                statusMessage = "Heal gesture cancelled because its photograph, original or retouch state changed"
            }
            return nil
        }
        guard context.isCurrent(in: self), context.tool == HealCanvasToolSettings(),
              let photo = primarySelection else { return refuse() }
        let before = context.expected
        switch edit {
        case .move(let spot):
            let values: [Double] = [spot.x, spot.y, spot.sourceX, spot.sourceY,
                                    spot.radius, spot.feather, spot.opacity]
            guard values.allSatisfy({ $0.isFinite }) else { return refuse() }
            guard let index = before.spots.firstIndex(where: { $0.id == spot.id }) else { return refuse() }
            var requested = before
            requested.spots[index] = spot
            updateSpot(id: spot.id, coalescingKey: "heal.drag.\(spot.id)", label: "Move Spot") { $0 = spot }
            guard recipe(for: photo).develop.heal == requested else { return refuse() }
        case .add(let x, let y):
            guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y)
            else { return refuse() }
            addSpot(sourceX: x, sourceY: y)
            let result = recipe(for: photo).develop.heal
            guard result.spots.count == before.spots.count + 1,
                  Array(result.spots.dropLast()) == before.spots,
                  result.spots.last?.x == x, result.spots.last?.y == y,
                  result.strokesRef == before.strokesRef, result.count == before.count
            else { return refuse() }
        case .paint(let points):
            guard !points.isEmpty,
                  points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.pressure.isFinite })
            else { return refuse() }
            // Never replace an unreadable old painting with a newly appended empty
            // base. Payload availability is checked before the verb publishes bytes.
            let prior: BrushStrokeSet
            if let ref = before.strokesRef {
                guard let loaded = strokeSet(ref: ref) else { return refuse() }
                prior = loaded
            } else { prior = BrushStrokeSet() }
            addHealStroke(points: points)
            let result = recipe(for: photo).develop.heal
            guard let ref = result.strokesRef, let set = strokeSet(ref: ref),
                  set.strokes.count == prior.strokes.count + 1,
                  Array(set.strokes.dropLast()) == prior.strokes,
                  set.strokes.last?.points == points,
                  result.count == set.strokes.count, result.spots == before.spots
            else { return refuse() }
        }
        // ACK only a value that the synchronous verb actually made visible.
        return recipe(for: photo).develop.heal
    }


    /// `Q`: a round trip. Arming leaves masking and puts the crop rectangle away, for the
    /// reason `enterMasking` puts it away — two tools that both take the drags on the
    /// photograph cannot both be up.
    func toggleHealTool() {
        let tool = HealTool.shared
        if tool.armed {
            tool.armed = false
            return
        }
        if PanelLayout.shared.layout.isMasking {
            PanelLayout.shared.setMasking(false)
        }
        let viewport = LoupeViewport.shared
        if viewport.showCrop {
            viewport.showCrop = false
            viewport.showStraighten = false
            CropTool.shared.forgetArming()
        }
        showLoupe()
        tool.armed = true
    }

    /// The spots on the primary photograph.
    var primarySpots: [HealSpot] {
        guard let photo = primarySelection else { return [] }
        return recipe(for: photo).develop.heal.spots
    }

    /// A new spot at a source-normalized point. It lands at once with a provisional
    /// source beside it, so the click answers immediately; the search then replaces that
    /// source — in the same undo step — unless the photographer has already moved it.
    func addSpot(sourceX x: Double, sourceY y: Double) {
        guard let photo = primarySelection else { return }
        let tool = HealTool.shared
        let size = sourceFrameSize ?? CGSize(width: 1, height: 1)
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        var spot = HealSpot(mode: tool.mode, x: x, y: y, sourceX: x, sourceY: y,
                            radius: tool.radius, feather: tool.feather,
                            opacity: tool.opacity)
        let provisional = SpotHandles.provisionalSource(for: spot, sourceWidth: width,
                                                        sourceHeight: height)
        spot.sourceX = provisional.x
        spot.sourceY = provisional.y
        let prior = recipe(for: photo).develop.heal.spots
        let key = "heal.add.\(spot.id)"
        let placed = spot
        updateRecipe(coalescingKey: key, label: "Add Spot", targets: [photo]) { _, recipe in
            recipe.develop.heal.spots.append(placed)
        }
        tool.selectedSpotID = spot.id
        tool.selectedStrokeIndex = nil

        let url = photo.id
        let current = recipe(for: photo)
        let searchContext = HealCanvasEditContext(photo: photo, recipe: current)
        Task {
            let found = await renderCoordinator.healAutoSource(url: url, recipe: current,
                                                               spot: placed,
                                                               priorSpots: prior)
            guard let found, searchContext.isCurrent(in: self) else { return }
            updateRecipe(coalescingKey: key, label: "Add Spot", targets: [photo]) { _, recipe in
                guard let i = recipe.develop.heal.spots.firstIndex(where: { $0.id == placed.id }),
                      recipe.develop.heal.spots[i].sourceX == provisional.x,
                      recipe.develop.heal.spots[i].sourceY == provisional.y
                else { return }
                recipe.develop.heal.spots[i].sourceX = found.x
                recipe.develop.heal.spots[i].sourceY = found.y
            }
        }
    }

    /// Rewrite one spot. `coalescingKey` folds a drag into one undo step.
    func updateSpot(id: String, coalescingKey: String?, label: String,
                    _ change: @escaping (inout HealSpot) -> Void) {
        guard let photo = primarySelection else { return }
        updateRecipe(coalescingKey: coalescingKey, label: label, targets: [photo]) { _, recipe in
            guard let i = recipe.develop.heal.spots.firstIndex(where: { $0.id == id })
            else { return }
            change(&recipe.develop.heal.spots[i])
        }
    }

    /// `/` while healing: move the selected spot's source to the next-best distinct
    /// candidate, cycling (`SpotSourceSearch.nextSource`). Which alternative the spot is
    /// on is read off the spot itself, so nothing here remembers a position in the cycle.
    /// The search reads the picture through the spots BEFORE this one, as its render does.
    func repickSelectedSpotSource() {
        let tool = HealTool.shared
        guard let id = tool.selectedSpotID, let photo = primarySelection else { return }
        let current = recipe(for: photo)
        let spots = current.develop.heal.spots
        guard let index = spots.firstIndex(where: { $0.id == id }) else { return }
        let spot = spots[index]
        let prior = Array(spots[..<index])
        let size = sourceFrameSize ?? CGSize(width: 1, height: 1)
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        let url = photo.id
        let searchContext = HealCanvasEditContext(photo: photo, recipe: current)
        Task {
            let candidates = await renderCoordinator.healSourceCandidates(
                url: url, recipe: current, spot: spot, priorSpots: prior)
            guard searchContext.isCurrent(in: self),
                  let next = SpotSourceSearch.nextSource(for: spot, candidates: candidates,
                                                         sourceWidth: width,
                                                         sourceHeight: height)
            else { return }
            updateSpot(id: id, coalescingKey: nil, label: "Re-pick Source") { live in
                // Only if the source is still where the search started from: a drag
                // that landed while it ran is the photographer's answer, not ours.
                guard live.sourceX == spot.sourceX, live.sourceY == spot.sourceY else { return }
                live.sourceX = next.x
                live.sourceY = next.y
            }
        }
    }

    /// The painted heal strokes on the primary photograph, from the session's blob cache
    /// (and the blob store on a miss — see `strokeSet(ref:)`).
    var primaryHealStrokes: [BrushStroke] {
        guard let photo = primarySelection else { return [] }
        return strokeSet(ref: recipe(for: photo).develop.heal.strokesRef)?.strokes ?? []
    }

    /// Write `set` as the primary photograph's heal strokes: bytes to the blob store
    /// FIRST, then the reference into the recipe — `MaskCanvas.apply`'s order, for its
    /// reason (a `strokesRef` with no bytes behind it renders nothing, forever, and
    /// looks exactly like one that works). An empty set clears the reference.
    @discardableResult
    func writeHealStrokes(_ set: BrushStrokeSet, coalescingKey: String?, label: String,
                          on photo: PhotoItem) -> Bool {
        guard !set.strokes.isEmpty else {
            updateRecipe(coalescingKey: coalescingKey, label: label, targets: [photo]) { _, r in
                r.develop.heal.strokesRef = nil
                r.develop.heal.count = 0
            }
            return true
        }
        guard let payload = try? set.encode(),
              let stored = try? catalog?.blobs.store(payload),
              stored == BrushStrokeSet.blobRef(for: payload) else {
            statusMessage = "Could not save that heal stroke — the photo is unchanged"
            return false
        }
        remember(set, ref: stored)
        updateRecipe(coalescingKey: coalescingKey, label: label, targets: [photo]) { _, r in
            r.develop.heal.strokesRef = stored
            r.develop.heal.count = set.strokes.count
        }
        return true
    }

    /// A painted heal stroke, in source-normalized points. It lands at once with a
    /// provisional offset beside it; the search then replaces the offset in the same
    /// undo step, unless the stroke was changed or removed meanwhile.
    func addHealStroke(points: [BrushPoint]) {
        guard let photo = primarySelection, !points.isEmpty else { return }
        let tool = HealTool.shared
        let size = sourceFrameSize ?? CGSize(width: 1, height: 1)
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        let diameter = tool.radius * 2
        let provisional = StrokeHandles.provisionalOffset(points: points, size: diameter,
                                                          sourceWidth: width,
                                                          sourceHeight: height)
        let stroke = BrushStroke(points: points, size: diameter, feather: tool.feather,
                                 density: tool.opacity,
                                 retouch: StrokeRetouch(mode: tool.mode, dx: provisional.dx,
                                                        dy: provisional.dy))
        let prior = primaryHealStrokes
        var set = BrushStrokeSet(strokes: prior)
        set.strokes.append(stroke)
        let key = "heal.stroke.\(UUID().uuidString)"
        guard writeHealStrokes(set, coalescingKey: key, label: "Heal Stroke", on: photo)
        else { return }
        tool.selectedSpotID = nil
        tool.selectedStrokeIndex = set.strokes.count - 1

        let url = photo.id
        let current = recipe(for: photo)
        let searchContext = HealCanvasEditContext(photo: photo, recipe: current)
        Task {
            let found = await renderCoordinator.healStrokeAutoOffset(
                url: url, recipe: current, stroke: stroke, priorStrokes: prior)
            guard let found, searchContext.isCurrent(in: self) else { return }
            // Only onto the stroke as it was placed: same index, same points, the
            // provisional offset untouched.
            var live = BrushStrokeSet(strokes: primaryHealStrokes)
            let index = prior.count
            guard live.strokes.indices.contains(index), live.strokes[index] == stroke
            else { return }
            live.strokes[index].retouch?.dx = found.dx
            live.strokes[index].retouch?.dy = found.dy
            writeHealStrokes(live, coalescingKey: key, label: "Heal Stroke", on: photo)
        }
    }

    /// `⌫` while healing: the selected stroke, else the selected spot.
    func deleteSelectedSpot() {
        let tool = HealTool.shared
        if let index = tool.selectedStrokeIndex, let photo = primarySelection {
            var set = BrushStrokeSet(strokes: primaryHealStrokes)
            tool.selectedStrokeIndex = nil
            guard set.strokes.indices.contains(index) else { return }
            set.strokes.remove(at: index)
            writeHealStrokes(set, coalescingKey: nil, label: "Delete Heal Stroke", on: photo)
            return
        }
        guard let id = tool.selectedSpotID, let photo = primarySelection else { return }
        updateRecipe(label: "Delete Spot", targets: [photo]) { _, recipe in
            recipe.develop.heal.spots.removeAll { $0.id == id }
        }
        tool.selectedSpotID = nil
    }
}

// MARK: - Canvas

struct HealCanvas: View {
    @EnvironmentObject private var edits: EditRevision

    let imageRect: CGRect
    let sourceSize: CGSize
    let geometry: Geometry
    let spots: [HealSpot]
    let selectedID: String?
    /// The painted heal strokes, and Brush mode's state.
    var strokes: [BrushStroke] = []
    var selectedStroke: Int? = nil
    var brush: Bool = false
    /// The diameter a new stroke is painted at, fraction of the long edge.
    var brushSize: Double = HealSpot.defaultRadius * 2
    var selectStroke: (Int?) -> Void = { _ in }
    let select: (String?) -> Void
    let editContext: HealCanvasEditContext
    let commit: (HealCanvasEdit, HealCanvasEditContext) -> Heal?

    @Environment(\.sliderGestureChanged) private var sliderGestureChanged

    private struct Grab {
        let part: SpotHandles.Part
        let origin: HealSpot
        let start: CGPoint
    }

    @State private var grab: Grab?
    @State private var pressed: Bool = false
    @State private var pressContext: HealCanvasEditContext?
    @State private var pressMapping: HealCanvasMapping?
    @State private var cancelled = false
    @State private var gestureSignalled = false
    /// The stroke being painted, source-normalized, and when it started.
    @State private var painting: [BrushPoint] = []
    @State private var paintStarted: Date?

    /// The grab tolerance in view points — `MaskHandles`' size, so every handle on the
    /// photograph is the same target.
    static let grabPoints: CGFloat = 11

    var body: some View {
        Canvas { context, _ in
            for (index, stroke) in strokes.enumerated() where stroke.retouch != nil {
                draw(&context, stroke, selected: index == selectedStroke)
            }
            if !painting.isEmpty {
                draw(&context, BrushStroke(points: painting, size: brushSize,
                                           retouch: StrokeRetouch(dx: 0, dy: 0)),
                     selected: true, live: true)
            }
            for spot in spots {
                draw(&context, spot, selected: spot.id == selectedID)
            }
        }
        .contentShape(Rectangle())
        .gesture(press)
        .lumenPickCursor(true)
        .help("Click a blemish to heal it. Drag the solid circle to move the spot, the "
              + "dashed one to choose where it borrows from; / re-picks it. ⌫ deletes "
              + "the selected spot; Q or Esc puts the tool away.")
        .onChange(of: editContext) { _, next in
            if let pressContext, !pressContext.sameTarget(as: next) { cancelPress() }
        }
        .onChange(of: imageRect) { _, _ in cancelPress() }
        .onChange(of: sourceSize) { _, _ in cancelPress() }
        .onAppear {
            // A hidden view can miss mouse-up. Recover only after the physical
            // press ended; reappearing under a held button must stay cancelled.
            if NSEvent.pressedMouseButtons == 0 { finishPress() }
        }
        .onDisappear { cancelPress() }
    }

    private func continuePress() -> Bool {
        guard !cancelled else { return false }
        if let pressContext {
            guard pressContext.sameTarget(as: editContext),
                  pressMapping?.accepts(imageRect: imageRect, sourceSize: sourceSize) == true
            else { cancelPress(); return false }
        } else {
            pressContext = editContext
            pressMapping = HealCanvasMapping(imageRect: imageRect, sourceSize: sourceSize)
        }
        return true
    }

    private func submit(_ edit: HealCanvasEdit) {
        guard continuePress(), var context = pressContext else { return }
        guard let applied = commit(edit, context) else { cancelPress(); return }
        context.expected = applied
        pressContext = context
    }

    private func cancelPress() {
        if pressContext != nil { cancelled = true }
        grab = nil
        painting = []
        paintStarted = nil
        if gestureSignalled {
            gestureSignalled = false
            sliderGestureChanged(false)
        }
    }

    private func finishPress() {
        cancelPress()
        pressContext = nil
        pressMapping = nil
        cancelled = false
        pressed = false
    }

    private var press: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard continuePress() else { return }
                if !pressed {
                    pressed = true
                    let n = normalized(value.startLocation)
                    if let hit = SpotHandles.hit(x: Double(n.x), y: Double(n.y),
                                                 spots: spots,
                                                 sourceWidth: sourcePixels.w,
                                                 sourceHeight: sourcePixels.h,
                                                 minimumGrab: minimumGrabPixels),
                       let spot = spots.first(where: { $0.id == hit.id }) {
                        select(hit.id)
                        grab = Grab(part: hit.part, origin: spot, start: n)
                        gestureSignalled = true
                        sliderGestureChanged(true)
                    } else {
                        grab = nil
                        if brush {
                            paintStarted = Date()
                            painting = [BrushPoint(x: Double(n.x), y: Double(n.y))]
                        }
                    }
                }
                if brush, grab == nil, let started = paintStarted {
                    let n = normalized(value.location)
                    let t = Int(Date().timeIntervalSince(started) * 1000)
                    // A new sample per quarter of a radius of travel: enough for the
                    // resampler, and a long stroke stays a small blob.
                    if let last = painting.last {
                        let size = sourcePixels
                        let edge = Double(Swift.max(size.w, size.h))
                        let moved = hypot((Double(n.x) - last.x) * Double(size.w),
                                          (Double(n.y) - last.y) * Double(size.h))
                        guard moved >= Swift.max(brushSize * edge / 8, 0.5) else { return }
                    }
                    painting.append(BrushPoint(x: Double(n.x), y: Double(n.y), t: t))
                    return
                }
                guard let grab else { return }
                let now = normalized(value.location)
                submit(.move(SpotHandles.dragged(grab.origin, part: grab.part,
                                         dx: Double(now.x - grab.start.x),
                                         dy: Double(now.y - grab.start.y))))
            }
            .onEnded { value in
                defer { finishPress() }
                guard continuePress() else { return }
                if let grab {
                    let now = normalized(value.location)
                    submit(.move(SpotHandles.dragged(grab.origin, part: grab.part,
                                             dx: Double(now.x - grab.start.x),
                                             dy: Double(now.y - grab.start.y))))
                    return
                }
                let travel = hypot(value.location.x - value.startLocation.x,
                                   value.location.y - value.startLocation.y)
                let n = normalized(value.startLocation)
                // Brush mode: the drag WAS a stroke, and a click is a dab.
                if brush {
                    let end = normalized(value.location)
                    var points = painting
                    if travel >= 4 {
                        points.append(BrushPoint(x: Double(end.x), y: Double(end.y)))
                    }
                    guard n.x >= 0, n.x <= 1, n.y >= 0, n.y <= 1, !points.isEmpty
                    else { return }
                    submit(.paint(points))
                    return
                }
                // A click on a painted stroke selects it.
                if travel < 4, let index = StrokeHandles.hit(
                    x: Double(n.x), y: Double(n.y), strokes: strokes,
                    sourceWidth: sourcePixels.w, sourceHeight: sourcePixels.h,
                    minimumGrab: minimumGrabPixels) {
                    selectStroke(index)
                    return
                }
                // A click on clear space places a spot; a drag across it does nothing,
                // so a photographer reaching to pan does not litter the frame.
                guard travel < 4 else { return }
                guard n.x >= 0, n.x <= 1, n.y >= 0, n.y <= 1 else { return }
                submit(.add(x: Double(n.x), y: Double(n.y)))
            }
    }

    // MARK: Drawing

    private func draw(_ context: inout GraphicsContext, _ spot: HealSpot, selected: Bool) {
        let centre = viewPoint(spot.x, spot.y)
        let source = viewPoint(spot.sourceX, spot.sourceY)
        let radius = viewRadius(spot)
        let ink = Color.white.opacity(selected ? 0.95 : 0.6)
        let width: CGFloat = selected ? 1.75 : 1

        var link = Path()
        link.move(to: source)
        link.addLine(to: centre)
        context.stroke(link, with: .color(ink.opacity(0.5)), lineWidth: 1)

        let destinationRect = CGRect(x: centre.x - radius, y: centre.y - radius,
                                     width: radius * 2, height: radius * 2)
        let sourceRect = CGRect(x: source.x - radius, y: source.y - radius,
                                width: radius * 2, height: radius * 2)
        // A dark keyline under each ring so it reads over a bright sky and a dark coat.
        context.stroke(Path(ellipseIn: destinationRect),
                       with: .color(Color.black.opacity(0.45)), lineWidth: width + 1.5)
        context.stroke(Path(ellipseIn: destinationRect), with: .color(ink),
                       lineWidth: width)
        context.stroke(Path(ellipseIn: sourceRect),
                       with: .color(Color.black.opacity(0.45)), lineWidth: width + 1.5)
        context.stroke(Path(ellipseIn: sourceRect), with: .color(ink),
                       style: StrokeStyle(lineWidth: width, dash: [4, 3]))
    }

    /// A painted stroke: its tube as a wide translucent line, its source as a dashed
    /// centreline beside it.
    private func draw(_ context: inout GraphicsContext, _ stroke: BrushStroke,
                      selected: Bool, live: Bool = false) {
        guard let first = stroke.points.first, let retouch = stroke.retouch else { return }
        let size = sourcePixels
        let edge = Double(Swift.max(size.w, size.h))
        let a = viewPoint(first.x, first.y)
        let b = viewPoint(first.x + stroke.size / 2 * edge / Double(size.w), first.y)
        let width = Swift.max(hypot(b.x - a.x, b.y - a.y) * 2, 2)
        var line = Path()
        var source = Path()
        for (i, p) in stroke.points.enumerated() {
            let v = viewPoint(p.x, p.y)
            let s = viewPoint(p.x + retouch.dx, p.y + retouch.dy)
            if i == 0 {
                line.move(to: v)
                source.move(to: s)
            } else {
                line.addLine(to: v)
                source.addLine(to: s)
            }
        }
        if stroke.points.count == 1 {
            line.addLine(to: a)
            source.addLine(to: viewPoint(first.x + retouch.dx, first.y + retouch.dy))
        }
        let round = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
        context.stroke(line, with: .color(Color.white.opacity(selected ? 0.32 : 0.18)),
                       style: round)
        guard !live else { return }
        context.stroke(source, with: .color(Color.black.opacity(0.45)),
                       style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        context.stroke(source, with: .color(Color.white.opacity(selected ? 0.95 : 0.6)),
                       style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [4, 3]))
    }

    // MARK: Coordinates — `MaskCanvas`'s, through the same inverse geometry

    private var sourcePixels: (w: Int, h: Int) {
        (Swift.max(Int(sourceSize.width.rounded()), 1),
         Swift.max(Int(sourceSize.height.rounded()), 1))
    }

    private func normalized(_ point: CGPoint) -> CGPoint {
        guard imageRect.width > 0, imageRect.height > 0 else { return .zero }
        let u = Double((point.x - imageRect.minX) / imageRect.width)
        let v = Double((point.y - imageRect.minY) / imageRect.height)
        return PipelineRenderer.sourceNormalized(displayedX: u, displayedY: v,
                                                 geometry: geometry,
                                                 sourceSize: sourceSize)
    }

    private func viewPoint(_ nx: Double, _ ny: Double) -> CGPoint {
        let displayed = PipelineRenderer.displayedNormalized(sourceX: nx, sourceY: ny,
                                                             geometry: geometry,
                                                             sourceSize: sourceSize)
        return CGPoint(x: imageRect.minX + displayed.x * imageRect.width,
                       y: imageRect.minY + displayed.y * imageRect.height)
    }

    /// The spot's radius on screen: one radius along the source x axis, projected.
    private func viewRadius(_ spot: HealSpot) -> CGFloat {
        let size = sourcePixels
        let edge = Double(Swift.max(size.w, size.h))
        let centre = viewPoint(spot.x, spot.y)
        let rim = viewPoint(spot.x + spot.radius * edge / Double(size.w), spot.y)
        return Swift.max(hypot(rim.x - centre.x, rim.y - centre.y), 2)
    }

    /// The view-point grab tolerance, in source pixels at the current zoom.
    private var minimumGrabPixels: Double {
        let a = normalized(CGPoint(x: imageRect.midX, y: imageRect.midY))
        let b = normalized(CGPoint(x: imageRect.midX + Self.grabPoints, y: imageRect.midY))
        let size = sourcePixels
        return hypot(Double(b.x - a.x) * Double(size.w), Double(b.y - a.y) * Double(size.h))
    }
}

// MARK: - Bar

/// Mode, size, feather and opacity: the selected spot's own when one is selected, the
/// next spot's otherwise — one set of controls, so there is never a question of which
/// one is live.
struct HealToolBar: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var tool: HealTool = HealTool.shared

    /// The source long edge in pixels, for showing Size in pixels as docs/09 states it.
    private var edge: Double {
        let size = state.sourceFrameSize ?? CGSize(width: 6000, height: 4000)
        return Double(Swift.max(size.width, size.height))
    }

    private var selected: HealSpot? {
        guard let id = tool.selectedSpotID else { return nil }
        return state.primarySpots.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(selected == nil
                     ? (tool.selectedStrokeIndex != nil ? "Heal — selected stroke"
                                                        : "Heal — new spots")
                     : "Heal — selected spot")
                    .font(.lumenCaptionStrong)
                Spacer(minLength: 0)
                if selected != nil || tool.selectedStrokeIndex != nil {
                    Button("Delete") { state.deleteSelectedSpot() }
                        .buttonStyle(.plain)
                        .font(.lumenCaption)
                        .help("Delete the selected spot (⌫)")
                }
                Button("Done") { tool.armed = false }
                    .buttonStyle(.plain)
                    .font(.lumenCaption)
                    .help("Put the Heal tool away (Q or Esc)")
            }
            LumenSegmented(options: [(value: false, label: "Spot"),
                                     (value: true, label: "Brush")],
                           selection: $tool.brush)
                .help("Spot: click a blemish. Brush: paint along a scratch, a hair or a "
                      + "wire, healed along its length.")
            HStack(spacing: 6) {
                LumenCheckbox(isOn: $tool.visualize)
                Text("Visualize Spots").font(.lumenCaption)
            }
            .help("Show an inverted edge view so sensor dust stands out. A view only: "
                  + "it is never saved or exported.")
            if tool.visualize {
                LumenSlider(title: "Threshold", value: $tool.visualizeThreshold,
                            range: 0...100,
                            defaultValue: SpotVisualization.defaultThreshold,
                            step: 1, decimals: 0, bipolar: false,
                            help: "Higher shows fainter spots, and more noise with them.")
            }
            LumenSegmented(options: [(value: HealMode.heal, label: "Heal"),
                                     (value: HealMode.clone, label: "Clone")],
                           selection: modeBinding)
            LumenSlider(title: "Size", value: sizeBinding, range: 2...400,
                        defaultValue: HealSpot.defaultRadius * 2 * edge,
                        step: 1, decimals: 0, bipolar: false,
                        help: "The spot's diameter, in pixels of the original file.")
            LumenSlider(title: "Feather", value: binding("feather", \.feather, \.feather),
                        range: 0...100, defaultValue: HealSpot.defaultFeather,
                        step: 1, decimals: 0, bipolar: false,
                        help: "How much of the spot's radius is a soft edge.")
            LumenSlider(title: "Opacity", value: binding("opacity", \.opacity, \.opacity),
                        range: 0...100, defaultValue: HealSpot.defaultOpacity,
                        step: 1, decimals: 0, bipolar: false,
                        help: "How much of the fill replaces the original.")
        }
        .padding(10)
        .frame(width: 250)
        .lumenHUD(radius: Lumen.radiusCard)
    }

    private var modeBinding: Binding<HealMode> {
        Binding(get: { selected?.mode ?? tool.mode }, set: { mode in
            tool.mode = mode
            guard let id = selected?.id else { return }
            state.updateSpot(id: id, coalescingKey: nil, label: "Spot Mode") { $0.mode = mode }
        })
    }

    private var sizeBinding: Binding<Double> {
        let edge = self.edge
        return Binding(get: { (selected?.radius ?? tool.radius) * 2 * edge }, set: { px in
            let radius = Num.clamp(px / 2 / edge, HealSpot.radiusRange.lowerBound,
                                   HealSpot.radiusRange.upperBound)
            tool.radius = radius
            guard let id = selected?.id else { return }
            state.updateSpot(id: id, coalescingKey: "heal.size.\(id)",
                             label: "Spot Size") { $0.radius = radius }
        })
    }

    private func binding(_ name: String,
                         _ toolPath: ReferenceWritableKeyPath<HealTool, Double>,
                         _ spotPath: WritableKeyPath<HealSpot, Double>) -> Binding<Double> {
        Binding(get: {
            if let selected { return selected[keyPath: spotPath] }
            return tool[keyPath: toolPath]
        }, set: { value in
            tool[keyPath: toolPath] = value
            guard let id = selected?.id else { return }
            state.updateSpot(id: id, coalescingKey: "heal.\(name).\(id)",
                             label: "Spot") { $0[keyPath: spotPath] = value }
        })
    }
}

#endif
