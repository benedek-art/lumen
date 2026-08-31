// MaskCanvas.swift
// The on-image interaction layer for masks: a transparent overlay that sits on the
// displayed photo and edits ONE component of ONE mask by direct manipulation —
// dragging a linear gradient's line, placing and resizing a radial, painting brush
// strokes into a `BrushStrokeSet`.
//
// The invariant this file exists to hold: masks live in SOURCE coordinates. Every
// gesture converts view points to source-normalized fractions through the displayed
// image rect before anything is written, and brush size is stored as a fraction of the
// source long edge. That is what makes a crop or a rotation re-rasterize a mask
// instead of orphaning it, and what keeps a stroke the same width at export
// resolution as it was on screen (docs/09 geometry invariant, docs/08 §8.2).
//
// Undo shape:
//   · A gradient drag streams live through one coalescing key, so the whole drag
//     collapses into a single history step.
//   · A brush stroke accumulates in local state while the mouse is down and is
//     committed once on mouse-up — one stroke, one undo step, and no recipe write
//     per mouse-moved event.
//
// WHAT A PRESS MEANS is not decided here. It is `MaskHandles`, in LumenCore, because
// this target has no tests and the rule it replaced could not be reached from one — a
// radial's only move target was the 9 pt dot at its centre, and every other press on the
// picture threw the ellipse away and started a new one from the drag ("if I go even a
// tiny bit out of that center dot, then I have to redraw it"). That file carries the
// full account. What matters at this end is the shape of the grammar it hands back:
//
//   radial   inside → move · the whole rim → resize that axis · clear space → new one
//   linear   the strip between the band lines → move · a band line → falloff ·
//            an endpoint dot → turn it · clear space → new one
//   both     ⌘ at the press → new one, wherever the press landed
//
// and the rule underneath all of it: a press that took hold of the shape can never
// replace it. Every drag below is a pure function of where the pointer is NOW and where
// the geometry was when the press landed — no accumulator, exactly as `SliderDrag`
// argues — so a dropped event cannot change what a gesture is worth, and a resize or a
// falloff drag that grabs somewhere other than the drawn dot does not begin by jumping
// the shape to the pointer.
//
// This view owns no application state. It reads the component it is editing and hands
// finished values back through `commit`, which the host routes into
// `AppState.updateRecipe` — `MaskCanvas.apply(_:in:)` is that routing, written once.

#if os(macOS)

import AppKit
import CoreGraphics
import Foundation
import LumenCore
import LumenPipeline
import SwiftUI

// MARK: - Brush settings

/// The brush parameters in force for the NEXT stroke. Session state by design: a
/// stroke records its own size/feather/flow/density/flags into the blob when it is
/// drawn (`BrushStroke`), so there is nothing per-component to store and nothing to
/// migrate. Deliberately not `@MainActor`-isolated so `shared` can be referenced from
/// a plain property initializer.
final class MaskBrushStore: ObservableObject {
    static let shared = MaskBrushStore()

    /// Stamp diameter as a fraction of the source LONG EDGE, matching `BrushStroke.size`.
    @Published var size: Double = BrushStroke.defaultSize
    @Published var feather: Double = 50
    @Published var flow: Double = 100
    @Published var density: Double = 100
    @Published var erase: Bool = false
    @Published var automask: Bool = false
    /// 0…100, and 0 is what shipped: a rigid connection between pointer and brush.
    /// See `BrushStabilizer` for why the useful range needs a squared curve.
    @Published var stabilize: Double = 0

    /// `[` and `]`: size, on a geometric ladder rather than a linear one.
    ///
    /// Size is a fraction of the long edge and spans 0.002…0.5 — two and a half decades
    /// — so a fixed step is either uselessly small at the top or unusably coarse at the
    /// bottom. 1.15× is about seventeen presses end to end, which is the same feel LR's
    /// pixel ladder has on a 24 MP frame.
    func nudgeSize(up: Bool) {
        size = Num.clamp(size * (up ? 1.15 : 1 / 1.15), 0.002, 0.5)
    }

    /// `⇧[` and `⇧]`: feather, which IS linear — it is a percentage of the stamp.
    func nudgeFeather(up: Bool) {
        feather = Num.clamp(feather + (up ? 10 : -10), 0, 100)
    }

    func stroke(points: [BrushPoint]) -> BrushStroke {
        BrushStroke(points: points,
                    size: Num.clamp(size, 0.0005, 2),
                    feather: Num.clamp(feather, 0, 100),
                    flow: Num.clamp(flow, 1, 100),
                    density: Num.clamp(density, 0, 100),
                    erase: erase,
                    automask: automask)
    }
}

// MARK: - Edits

/// What a gesture produced. The canvas never writes a recipe itself; it describes the
/// change and the host commits it.
enum MaskCanvasEdit {
    /// A component whose geometry the drag rewrote. `coalescingKey` is non-nil while
    /// the drag is live so the stream folds into one undo step.
    case component(maskID: String, index: Int, component: MaskComponent,
                   coalescingKey: String?)
    /// A finished brush stroke, appended to the component's stroke set. `ref` is the
    /// content-addressed reference for `payload`; the host writes `ref` into
    /// `MaskComponent.strokesRef` and persists `payload` in the blob store.
    case strokes(maskID: String, index: Int, strokes: BrushStrokeSet,
                 ref: String?, payload: Data?)
}

// MARK: - Canvas

/// `imageRect` is the photo's drawn rect **in this view's own coordinate space**,
/// `sourceSize` is the SOURCE image's pixel extent, and `geometry` is the crop,
/// straighten and flip that sit between them.
///
/// All three are needed, and `geometry` used to be missing. What the canvas draws is
/// the preview, which `renderPreview` has already cropped and straightened; what a mask
/// component stores is normalized to the SOURCE frame. Without the transform between
/// them every gesture on a cropped photo was written somewhere other than where it was
/// made — on a left-half crop of a 6000 px frame, 1500 source pixels away — while the
/// handles drew somewhere else again and a brush painted several times wider than its
/// cursor ring. `sourceSize` was also being passed the cropped extent, which broke the
/// pixel-round guarantee below for the same reason.
struct MaskCanvas: View {
    let imageRect: CGRect
    let sourceSize: CGSize
    let geometry: Geometry
    let maskID: String
    let componentIndex: Int
    let component: MaskComponent?
    let strokes: BrushStrokeSet
    /// Every mask on this photograph, so the ones you are NOT editing can still be seen.
    ///
    /// Only the selected component drew anything, so a photograph with five masks
    /// showed one shape and four invisible ones — and the four you cannot see are
    /// exactly the ones you are about to overlap by accident (docs/35 §2.5). They draw
    /// faint; the selected one draws bright.
    var allMasks: [Mask] = []
    /// Selecting a mask from its pin, which is how a photographer picks the mask under
    /// the thing they are looking at rather than by reading a list.
    var selectMask: (String) -> Void = { _ in }
    let commit: (MaskCanvasEdit) -> Void

    @ObservedObject private var brush: MaskBrushStore = MaskBrushStore.shared

    /// The same gesture-in-flight signal every slider fires (docs/23 audit queue
    /// item 5): an on-image drag is a gesture like any other, and without this every
    /// event of a gradient or brush drag paid a SQLite write plus fingerprint
    /// codings while the sliders had stopped paying them.
    @Environment(\.sliderGestureChanged) private var sliderGestureChanged

    @State private var mode: DragMode = .idle
    @State private var originLine: [Double] = []
    @State private var originCenter: [Double] = []
    @State private var originRadii: [Double] = []
    /// The rotation the ellipse had when the turn started. Carried rather than re-read,
    /// because a turn computed against a value the previous event wrote compounds.
    @State private var originRotation: Double = 0
    /// True while this view owns the top of the `NSCursor` stack. See `setDrawCursor`.
    @State private var pushedDrawCursor = false
    @State private var livePoints: [BrushPoint] = []
    @State private var strokeStarted: Date? = nil
    @State private var hover: CGPoint? = nil
    /// Whether Option was down when this stroke began. See `dragBrush`.
    @State private var eraseHeld: Bool = false

    init(imageRect: CGRect,
         sourceSize: CGSize,
         geometry: Geometry,
         maskID: String,
         componentIndex: Int,
         component: MaskComponent?,
         strokes: BrushStrokeSet = BrushStrokeSet(),
         allMasks: [Mask] = [],
         selectMask: @escaping (String) -> Void = { _ in },
         commit: @escaping (MaskCanvasEdit) -> Void) {
        self.imageRect = imageRect
        self.sourceSize = sourceSize
        self.geometry = geometry
        self.maskID = maskID
        self.componentIndex = componentIndex
        self.component = component
        self.strokes = strokes
        self.allMasks = allMasks
        self.selectMask = selectMask
        self.commit = commit
    }

    /// What the press decided, carried for the rest of the drag.
    ///
    /// The two geometry cases hold a `MaskHandles` answer rather than the integers they
    /// used to hold. The integers were the defect's hiding place: "3" meant *drawing a
    /// new one* on both kinds and was the value every hit test fell through to, so the
    /// destructive branch was the DEFAULT of a switch nobody could test. A named case is
    /// returned only where the rule says so, and the compiler now requires this file to
    /// handle each one.
    /// The similarity point a press took hold of, for the life of the drag.
    @State private var pointGrab: PointGrab?

    /// The outline being traced by the current drag, or the vertex it took hold of.
    /// Both are gesture-lifetime state and both are cleared in `onEnded`, for the reason
    /// every grab in this file is carried rather than re-derived: a gesture must be a
    /// pure function of where the pointer is now and where the geometry was when the
    /// press landed, so a dropped event cannot change what the drag is worth.
    /// One stabilizer per stroke, carrying the brush's position between events. Reset
    /// in `onEnded` with the rest of the gesture's state.
    @State private var stabilizer: BrushStabilizer?
    @State private var tracing: [[Double]]?
    @State private var outlineGrab: Int?

    private enum DragMode: Equatable {
        case idle
        case line(MaskHandles.LinearGrab)
        case radial(MaskHandles.RadialGrab)
        case brush
        /// Dragging one vertex of an outline.
        case outlineVertex
        /// Tracing a new outline freehand — the lasso.
        case outlineTrace
        /// A press on empty space with a finished outline already there: a click adds
        /// a corner, and a drag does nothing, because tracing would replace the shape.
        case outlineCorner
        /// A press that landed on ANOTHER mask's pin. Carried for the drag so a press
        /// that turns into a small movement still selects rather than starting to draw.
        case pin(String)
    }

    // MARK: Body

    var body: some View {
        Canvas { context, _ in
            // THE MASKS YOU ARE NOT EDITING, first and faint. Only the selected
            // component drew anything, so a photograph with five masks showed one
            // shape and four invisible ones — and an invisible mask is exactly the one
            // you overlap by accident (docs/35 §2.5).
            drawOtherMasks(&context)
            drawPins(&context)
            guard let component = component, isLive else { return }
            switch component.kind {
            case .linear:
                drawLine(&context, component)
            case .similarityLine:
                drawLine(&context, component)
                drawPoints(&context, component)
            case .radial:
                drawRadial(&context, component)
            case .brush:
                drawBrush(&context)
            case .similarity:
                drawPoints(&context, component)
            case .polygon:
                drawOutline(&context, component)
            default:
                break
            }
        }
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .onContinuousHover(coordinateSpace: .local) { phase in
            if case .active(let point) = phase {
                hover = point
                // Cheap, and it is the only signal that arrives while a modifier is
                // being held over a stationary picture.
                let held = MaskCanvas.optionHeld()
                if held != eraseHeld { eraseHeld = held }
                setDrawCursor(true)
            } else {
                hover = nil
                setDrawCursor(false)
            }
        }
        .onDisappear { setDrawCursor(false) }
        .allowsHitTesting(isLive)
        .help(helpText)
    }

    /// A CROSSHAIR WHILE THERE IS NOTHING DRAWN YET, which is the whole of what the
    /// canvas can say without words.
    ///
    /// Shapes are drawn rather than seeded now, so a photographer who chooses Radial
    /// Gradient sees an unchanged photograph and has to be told, once, that the next
    /// move is theirs. The panel's note says it in a sentence; this says it where they
    /// are looking. The moment the shape exists the cursor goes back to the arrow, so it
    /// is a prompt rather than a mode.
    ///
    /// PUSH/POP DISCIPLINE, `ViewerOverlays`' exactly: at most one push outstanding,
    /// driven off a single boolean, flipped on every hover event so a shape appearing
    /// mid-hover puts the cursor back — and popped in `onDisappear`, because the one
    /// thing that unbalances this is the panel switching away while the pointer is
    /// still inside.
    private func setDrawCursor(_ inside: Bool) {
        let wants = inside && needsDrawing
        guard wants != pushedDrawCursor else { return }
        if wants { NSCursor.crosshair.push() } else { NSCursor.pop() }
        pushedDrawCursor = wants
    }

    /// True when the selected component is one you draw and has not been drawn.
    private var needsDrawing: Bool {
        guard let component else { return false }
        switch component.kind {
        case .radial:
            return !MaskCanvas.hasEllipse(component)
        case .linear, .similarityLine:
            return MaskCanvas.optionalLine(component) == nil
        case .polygon:
            return MaskCanvas.outlinePath(component) == nil
        case .brush, .lumaRange, .luminosity, .colorRange, .similarity, .maskRef,
             .depthRange, .aiSubject, .aiSky, .aiBackground, .aiObject, .aiPerson,
             .aiLandscape:
            return false
        }
    }

    /// True only when there is something to manipulate: the range and AI kinds are
    /// edited in the panel and by the sampler, and the overlay must pass their clicks
    /// through to the viewer rather than swallowing them.
    /// True when the canvas has anything to be pressed ON — a drawable component, or
    /// somebody else's pin. A canvas that swallows clicks with nothing to do with them
    /// is the defect this guard exists for, and a pin is something to do with them.
    /// Whether the canvas has another mask's pin on it worth being live for.
    ///
    /// DOCKED PINS DO NOT COUNT. They are not grabbable — see `foreignPin` — so a canvas
    /// made live by one would accept gestures for a target that cannot be hit, which is
    /// the same lie as an affordance drawn where nothing can be grabbed.
    private var hasForeignPins: Bool {
        pinPositions().contains { $0.id != maskID && !$0.docked }
    }

    private var isLive: Bool {
        guard imageRect.width > 1, imageRect.height > 1 else { return false }
        if hasForeignPins { return true }
        guard let component = component else { return false }
        switch component.kind {
        case .linear, .similarityLine, .radial, .brush, .polygon: return true
        // A Colour Pick's points are placed by the eyedropper and MOVED here. The
        // picker overlay sits above this view while a pick is armed, so taking the
        // clicks back does not cost the eyedropper anything.
        case .similarity: return !(component.points ?? []).isEmpty
        default: return false
        }
    }

    private var helpText: String {
        guard let component = component else { return "" }
        switch component.kind {
        case .linear, .similarityLine:
            return "Drag the band to move it, a line to change the falloff, an end dot "
                 + "to turn it; Shift constrains to 0/90°. ⌘-drag draws a new gradient."
        case .radial:
            return "Drag out an ellipse on the picture. Then: inside to move, the edge "
                 + "to resize, the inner ring to feather, the outer dot to turn it. "
                 + "⇧ keeps it round or snaps the angle; ⌘-drag draws another."
        case .brush:
            return "Drag to paint, hold ⌥ to erase, ⇧-click to carry on in a straight "
                 + "line from the last stroke. [ and ] size it, ⇧[ and ⇧] feather it, "
                 + "digits set Flow, A stays inside edges."
        case .similarity:
            return "Drag a point to move it, its ring to change how far it reaches."
        case .polygon:
            return "Drag to lasso a shape, or click to place corners one at a time. "
                 + "Drag a corner to move it, ⌥-click to remove it. Once it is "
                 + "closed, ⌘-drag is how you start over."
        default:
            return ""
        }
    }

    // MARK: Gesture

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // A press on another mask's pin selects, and does nothing else. Checked
                // FIRST and only once per gesture: a pin sits on top of whatever
                // geometry is underneath it, and the press has to mean the pin.
                if case .idle = mode, let id = foreignPin(at: value.startLocation) {
                    mode = .pin(id)
                    return
                }
                if case .pin = mode { return }
                guard let component = component else { return }
                sliderGestureChanged(true)
                switch component.kind {
                case .linear, .similarityLine:
                    dragLine(value, component, ended: false)
                case .radial:
                    dragRadial(value, component, ended: false)
                case .brush:
                    dragBrush(value, ended: false)
                case .similarity:
                    dragPoint(value, component, ended: false)
                case .polygon:
                    dragOutline(value, component, ended: false)
                default:
                    break
                }
            }
            .onEnded { value in
                if case .pin(let id) = mode {
                    mode = .idle
                    pointGrab = nil
                    selectMask(id)
                    return
                }
                defer { sliderGestureChanged(false) }
                guard let component = component else { return }
                switch component.kind {
                case .linear, .similarityLine:
                    dragLine(value, component, ended: true)
                case .radial:
                    dragRadial(value, component, ended: true)
                case .brush:
                    dragBrush(value, ended: true)
                case .similarity:
                    dragPoint(value, component, ended: true)
                case .polygon:
                    dragOutline(value, component, ended: true)
                default:
                    break
                }
                mode = .idle
                pointGrab = nil
                tracing = nil
                outlineGrab = nil
            }
    }

    // MARK: Outline

    /// The closed outline, and a dot on every corner.
    ///
    /// While a lasso is being traced the path is drawn OPEN, with the closing edge
    /// dashed. That is not decoration: the one thing a photographer cannot see while
    /// dragging is where the shape will close, and a lasso whose two ends meet somewhere
    /// unexpected is the failure mode of every lasso tool ever shipped.
    private func drawOutline(_ context: inout GraphicsContext, _ c: MaskComponent) {
        let points = tracing ?? c.path ?? []
        let live = tracing != nil
        guard points.count >= 2 else {
            if let only = points.first, only.count == 2 {
                handle(&context, viewPoint(only[0], only[1]))
            }
            return
        }
        var path = Path()
        var first: CGPoint?
        var last: CGPoint?
        for entry in points where entry.count == 2 {
            guard entry[0].isFinite, entry[1].isFinite else { continue }
            let p = viewPoint(entry[0], entry[1])
            if first == nil {
                path.move(to: p)
                first = p
            } else {
                path.addLine(to: p)
            }
            last = p
        }
        guard let start = first, let end = last else { return }
        if !live { path.addLine(to: start) }
        stroke(&context, path, width: 1.5, alpha: 0.85)
        if live {
            var closing = Path()
            closing.move(to: end)
            closing.addLine(to: start)
            context.stroke(closing, with: .color(Color.white.opacity(0.5)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            // No corner dots on a trace: a freehand lasso has hundreds of vertices and
            // drawing one dot each would paint a solid line over the shape.
            return
        }
        for (index, entry) in points.enumerated() where entry.count == 2 {
            guard entry[0].isFinite, entry[1].isFinite else { continue }
            handle(&context, viewPoint(entry[0], entry[1]), small: index != outlineGrab)
        }
    }

    /// Three gestures on one tool, decided by what the press landed on and how far it
    /// travelled — which is the same rule the gradient uses and the reason a lasso and a
    /// polygon are one kind rather than two.
    ///
    ///   press on a corner, then move  →  move that corner
    ///   press on empty space, then move  →  trace a new outline
    ///   press and release without moving  →  add a corner where you clicked
    ///
    /// ⌘ forces the trace branch, so a shape already drawn can be replaced without
    /// deleting it first; ⌥ on a corner removes it. Both match the gradient's grammar.
    private func dragOutline(_ value: DragGesture.Value, _ component: MaskComponent,
                             ended: Bool) {
        let existing = (component.path ?? []).filter {
            $0.count == 2 && $0.allSatisfy(\.isFinite)
        }
        let travelled = hypot(value.location.x - value.startLocation.x,
                              value.location.y - value.startLocation.y)

        if mode == .idle {
            if !isCommandDown,
               let index = grabbedVertex(at: value.startLocation, path: existing) {
                if isOptionDown {
                    // Removing a corner is a whole gesture, finished on the press: the
                    // three-corner floor is `validationError`'s and taking a fourth
                    // corner off a triangle would make the component incomplete.
                    guard existing.count > 3 else { mode = .outlineVertex; return }
                    var next = component
                    next.path = existing.enumerated()
                        .filter { $0.offset != index }.map(\.element)
                    commit(.component(maskID: maskID, index: componentIndex,
                                      component: next, coalescingKey: nil))
                    mode = .outlineVertex
                    return
                }
                outlineGrab = index
                mode = .outlineVertex
            } else if existing.count >= 3 && !isCommandDown {
                // A FINISHED OUTLINE IS NOT REDRAWN BY ACCIDENT. Tracing replaces the
                // whole path, so without this a drag that started a few points off a
                // corner — reaching for one and missing is the ordinary way to miss —
                // would silently destroy a shape someone spent a minute placing. ⌘ is
                // the deliberate "draw another one", the same modifier the gradient and
                // the ellipse already use for exactly this.
                //
                // A click still adds a corner, which is how a polygon is built up and
                // is not destructive: this branch is the trace with the replace removed.
                mode = .outlineCorner
            } else {
                mode = .outlineTrace
            }
        }

        switch mode {
        case .outlineVertex:
            guard let index = outlineGrab, existing.indices.contains(index) else { return }
            // Travel in SOURCE coordinates, not position: `normalized` inverts the crop,
            // the straighten and the flip, and a displayed-space delta added to a
            // source-normalized value runs away at 1/crop.width.
            let from = normalized(value.startLocation)
            let to = normalized(value.location)
            var path = existing
            var moved = path[index]
            moved[0] = Num.clamp(moved[0] + Double(to.x - from.x), -0.5, 1.5)
            moved[1] = Num.clamp(moved[1] + Double(to.y - from.y), -0.5, 1.5)
            path[index] = moved
            var next = component
            next.path = path
            commit(.component(maskID: maskID, index: componentIndex, component: next,
                              coalescingKey: ended ? nil : coalescingKey("outline")))

        case .outlineCorner:
            // The outline is already closed, so a drag would REPLACE it. A click still
            // adds a corner, which is how a polygon is built up and costs nothing.
            guard ended, travelled < MaskCanvas.outlineClickSlop else { return }
            appendCorner(value, component, to: existing)

        case .outlineTrace:
            if travelled < MaskCanvas.outlineClickSlop {
                // A click, not a drag. Nothing happens until the release, so a press
                // that turns into a trace does not leave a stray corner behind.
                guard ended else { return }
                appendCorner(value, component, to: existing)
                return
            }
            let at = normalized(value.location)
            let point = [Double(at.x), Double(at.y)]
            var traced = tracing ?? [[Double(normalized(value.startLocation).x),
                                      Double(normalized(value.startLocation).y)]]
            // Thinned as it is recorded rather than afterwards. A 45 MP frame at 120 Hz
            // records several thousand samples across one sweep of the hand, and every
            // one of them is a vertex the rasterizer walks at every pixel inside the
            // bounding box — the difference between a shape that rasterizes in
            // milliseconds and one that does not.
            if let last = traced.last,
               hypot(point[0] - last[0], point[1] - last[1])
                   < MaskCanvas.outlineTraceStep, !ended {
                return
            }
            traced.append(point)
            tracing = traced
            guard ended else { return }
            tracing = nil
            guard traced.count >= 3 else { return }
            var next = component
            next.path = traced
            commit(.component(maskID: maskID, index: componentIndex, component: next,
                              coalescingKey: nil))

        default:
            break
        }
    }

    private func appendCorner(_ value: DragGesture.Value, _ component: MaskComponent,
                              to existing: [[Double]]) {
        let at = normalized(value.location)
        var next = component
        next.path = existing + [[Double(at.x), Double(at.y)]]
        commit(.component(maskID: maskID, index: componentIndex, component: next,
                          coalescingKey: nil))
    }

    private func grabbedVertex(at location: CGPoint, path: [[Double]]) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, entry) in path.enumerated() where entry.count == 2 {
            let p = viewPoint(entry[0], entry[1])
            let d = hypot(location.x - p.x, location.y - p.y)
            guard d <= MaskCanvas.pointRingGrab else { continue }
            if best == nil || d < best!.distance { best = (index, d) }
        }
        return best?.index
    }

    /// How far a press may travel and still count as a click that places a corner. Below
    /// the 11 pt grab radius, so a click near an existing corner grabs it rather than
    /// stacking a second one on top.
    static let outlineClickSlop: CGFloat = 4

    /// Minimum spacing between recorded lasso vertices, in source-normalized units —
    /// roughly a fifth of a percent of the frame, which is finer than the edge the
    /// rasterizer's one-pixel ramp can express at any sane display size.
    static let outlineTraceStep: Double = 0.002

    // MARK: Similarity points

    /// Which point a press took hold of, and whether it took the ring or the middle.
    /// Carried for the whole drag for the reason every other grab here is: a gesture is
    /// a pure function of where the pointer is NOW and where the geometry was when the
    /// press landed, so a dropped event cannot change what the drag is worth.
    private struct PointGrab: Equatable {
        var index: Int
        var resizing: Bool
        var origin: [Double]
    }

    /// Points are MOVED here and CREATED by the eyedropper.
    ///
    /// Deliberately not "clear space makes a new one", which is the radial's rule: a new
    /// similarity point needs a COLOUR as well as a position, and only the sampler can
    /// read one. A press on empty space therefore does nothing rather than making a
    /// point that matches whatever grey it was born with.
    private func dragPoint(_ value: DragGesture.Value, _ component: MaskComponent,
                           ended: Bool) {
        let points = component.points ?? []
        guard !points.isEmpty else { return }

        let grab: PointGrab
        if let existing = pointGrab {
            grab = existing
        } else {
            guard let found = grabbedPoint(at: value.startLocation, points: points)
            else { return }
            grab = found
            pointGrab = found
        }
        guard points.indices.contains(grab.index), grab.origin.count >= 3 else { return }

        var entry = grab.origin
        if grab.resizing {
            let centre = viewPoint(entry[0], entry[1])
            let d = hypot(value.location.x - centre.x, value.location.y - centre.y)
            entry[2] = pointRadiusFromView(d)
        } else {
            // Travel, not position, and measured in SOURCE coordinates — the defect the
            // gradient's and the ellipse's translate branches both record. `normalized`
            // inverts the crop, the straighten and the flip; a displayed-space delta
            // added to a source-normalized value runs away at 1/crop.width.
            let from = normalized(value.startLocation)
            let to = normalized(value.location)
            entry[0] = Num.clamp(entry[0] + Double(to.x - from.x), -0.5, 1.5)
            entry[1] = Num.clamp(entry[1] + Double(to.y - from.y), -0.5, 1.5)
        }

        var updated = points
        updated[grab.index] = entry
        var next = component
        next.points = updated
        commit(.component(maskID: maskID, index: componentIndex, component: next,
                          coalescingKey: ended ? nil : coalescingKey("point")))
    }

    /// The ring first, then the inside — so a point whose ring is inside a bigger
    /// point's body can still be resized. Nearest match wins among equals.
    private func grabbedPoint(at location: CGPoint, points: [[Double]]) -> PointGrab? {
        var best: (grab: PointGrab, score: CGFloat)? = nil
        for (index, entry) in points.enumerated() where entry.count >= 3 {
            guard entry[0].isFinite, entry[1].isFinite, entry[2].isFinite else { continue }
            let centre = viewPoint(entry[0], entry[1])
            let r = pointRadiusInView(entry[2])
            let d = hypot(location.x - centre.x, location.y - centre.y)
            if abs(d - r) <= MaskCanvas.pointRingGrab {
                let candidate = PointGrab(index: index, resizing: true, origin: entry)
                if best == nil || abs(d - r) < best!.score {
                    best = (candidate, abs(d - r))
                }
            } else if d <= r, best?.grab.resizing != true {
                let candidate = PointGrab(index: index, resizing: false, origin: entry)
                if best == nil || d < best!.score { best = (candidate, d) }
            }
        }
        return best?.grab
    }

    /// How near a ring a press has to land to mean "resize" rather than "move".
    /// The same 11 pt `MaskHandles` uses for a gradient's dots, for the same reason: a
    /// grab radius smaller than the thing drawn is a target you can see and not hit.
    static let pointRingGrab: CGFloat = 11

    // MARK: Linear gradient

    private func dragLine(_ value: DragGesture.Value, _ component: MaskComponent,
                          ended: Bool) {
        let line = MaskCanvas.line(component)
        // The grab is decided once, on mouse-down, and carried in a local as well as in
        // `mode`: reading @State back inside the same event would be a bet this does not
        // need to take.
        let grab: MaskHandles.LinearGrab
        var updated: [Double]
        if case .line(let existing) = mode {
            grab = existing
            updated = originLine.count == 4 ? originLine : line
        } else {
            // The RAW geometry, not the drawing fallback: `MaskCanvas.line` substitutes
            // a gradient down the middle so there is always something to draw, and
            // handing that to the hit test would make a gradient that does not exist
            // yet feel like one parked under the pointer.
            grab = lineGrab(at: value.startLocation,
                            line: MaskCanvas.optionalLine(component) ?? [])
            updated = line
            originLine = line
            mode = .line(grab)
        }

        let current = value.location
        switch grab {
        case .startHandle, .endHandle:
            // The endpoint follows the pointer's TRAVEL, not the pointer. Setting it to
            // the pointer was right only because the old hit test could not grab an
            // endpoint from anywhere but its own 9 pt dot; now that a dot can be grabbed
            // anywhere within 11 pt, assigning the raw position would snap the end to
            // the cursor by up to a whole grab radius the instant the mouse went down.
            // `updated` is the drag's origin, so this stays absolute in the pointer.
            let moving = grab == .startHandle ? 0 : 2
            let fixed = grab == .startHandle ? 2 : 0
            let anchor = viewPoint(updated[fixed], updated[fixed + 1])
            let origin = viewPoint(updated[moving], updated[moving + 1])
            let target = CGPoint(x: origin.x + (current.x - value.startLocation.x),
                                 y: origin.y + (current.y - value.startLocation.y))
            let n = normalized(constrained(target, anchor: anchor))
            updated[moving] = Double(n.x)
            updated[moving + 1] = Double(n.y)
        case .startBand, .endBand:
            // A band line is drawn straight across the picture, so dragging it moves it
            // — it does not swing the gradient round the far end. The endpoint slides
            // ALONG the axis by the pointer's travel projected onto that axis, which is
            // exactly the falloff: `linearPlane` ramps between the two lines and is flat
            // outside them, so the distance between them IS the feather (docs/08 §8.2,
            // "the span between the two lines IS the feather — there is no separate
            // control"). Turning the gradient stays on the end dots, where an affordance
            // that looks like a pivot is actually drawn.
            let p0 = viewPoint(updated[0], updated[1])
            let p1 = viewPoint(updated[2], updated[3])
            let wx = p1.x - p0.x
            let wy = p1.y - p0.y
            let length = (wx * wx + wy * wy).squareRoot()
            guard length > 1e-6 else { return }
            let ux = wx / length
            let uy = wy / length
            var slide = (current.x - value.startLocation.x) * ux
                      + (current.y - value.startLocation.y) * uy
            // The two ends may not pass each other, or meet: a gradient shorter than one
            // grab radius has no separable targets left, and one of zero length
            // rasterizes to nothing at all. Clamping here rather than letting the
            // degenerate guard below reject the commit keeps the line under the hand
            // instead of freezing it mid-drag.
            let minimumSpan = CGFloat(MaskHandles.grabRadius)
            if grab == .endBand {
                slide = Swift.max(slide, minimumSpan - length)
            } else {
                slide = Swift.min(slide, length - minimumSpan)
            }
            let moving = grab == .startBand ? 0 : 2
            let origin = viewPoint(updated[moving], updated[moving + 1])
            let slid = CGPoint(x: origin.x + ux * slide, y: origin.y + uy * slide)
            let n = normalized(slid)
            updated[moving] = Double(n.x)
            updated[moving + 1] = Double(n.y)
        case .move:
            // THE DELTA HAS TO BE MEASURED IN SOURCE COORDINATES, and it was measured in
            // displayed ones. Every other branch in this file routes through
            // `normalized()` → `PipelineRenderer.sourceNormalized`, which inverts the
            // crop, the straighten and the flip; these two "translate" branches added a
            // fraction of the DISPLAYED rect straight onto a SOURCE-normalized value.
            //
            // On a crop of `w=0.5`, a 100-point drag across a 750-point preview travels
            // 0.1333 of the displayed width — 400 source pixels, 0.0667 of the source —
            // and the old code wrote 0.1333, i.e. 800. The gradient ran away at 1/crop.w
            // times the pointer's speed, redrawing under the new value so the mismatch
            // was visible immediately. With a straighten angle it also slid diagonally,
            // because the delta was applied along the source axes rather than the
            // rotated ones.
            //
            // Two `normalized` calls and a subtraction gets both right at once: the
            // inverse transform is applied to each endpoint, so whatever it does to the
            // axes it does to both.
            let from = normalized(value.startLocation)
            let to = normalized(current)
            let dx = Double(to.x - from.x)
            let dy = Double(to.y - from.y)
            // `updated` is still the drag's origin here — nothing in this switch has
            // written to it on this path — which is what makes the delta absolute rather
            // than accumulating per event.
            let base = updated
            updated = [MaskCanvas.coord(base[0] + dx), MaskCanvas.coord(base[1] + dy),
                       MaskCanvas.coord(base[2] + dx), MaskCanvas.coord(base[3] + dy)]
        case .create:
            // Only reached when the press landed clear of the whole gradient, or with ⌘
            // down. A click is still not a gradient: without the travel guard a 3 pt
            // twitch replaces a placed gradient with a 3 pt one, which rasterizes as a
            // hard edge through the click and reads as the mask having been destroyed —
            // the same defect as the radial's, one order of magnitude less obvious.
            guard MaskHandles.drawsShape(from: value.startLocation, to: current) else {
                return
            }
            let start = normalized(value.startLocation)
            let end = normalized(constrained(current, anchor: value.startLocation))
            updated = [Double(start.x), Double(start.y), Double(end.x), Double(end.y)]
        }

        // A degenerate line rasterizes to nothing; keep the previous one until the
        // drag has actually travelled.
        let dx = updated[2] - updated[0]
        let dy = updated[3] - updated[1]
        guard (dx * dx + dy * dy) > 1e-8 else { return }

        var next = component
        next.line = updated
        commit(.component(maskID: maskID, index: componentIndex, component: next,
                          coalescingKey: ended ? nil : coalescingKey("line")))
    }

    /// The press, projected into view points and handed to the rule in `MaskHandles`.
    ///
    /// The projection is the whole of this view's contribution: the gradient is stored
    /// in SOURCE coordinates and the hand is aiming at the DISPLAYED picture, so the
    /// two endpoints are pushed through `viewPoint` — crop, straighten, flip and all —
    /// before any distance is measured. Measuring in source-normalized units instead
    /// would make every tolerance in `MaskHandles` mean a different number of screen
    /// points on every crop.
    private func lineGrab(at point: CGPoint, line: [Double]) -> MaskHandles.LinearGrab {
        guard line.count == 4 else { return .create }
        // ⌘ is the explicit "another one" gesture, and it exists so that the rule above
        // is free to be as protective as it is: a gradient whose band covers the frame
        // leaves no clear space to press, and without a modifier there would be no way
        // to start a fresh one on the picture at all. ⇧ and ⌥ are already spoken for
        // here (constrain, and draw-from-centre on the radial), and ⌃-drag is a
        // secondary click on macOS — ⌘ is the one that was free.
        if isCommandDown { return .create }
        return MaskHandles.linearGrab(press: point,
                                      start: viewPoint(line[0], line[1]),
                                      end: viewPoint(line[2], line[3]))
    }

    // MARK: Radial gradient

    private func dragRadial(_ value: DragGesture.Value, _ component: MaskComponent,
                            ended: Bool) {
        let centre = MaskCanvas.pair(component.center, fallback: [0.5, 0.5])
        let radii = MaskCanvas.pair(component.radii, fallback: [0.25, 0.25])
        let rotation = component.rotation ?? 0
        let grab: MaskHandles.RadialGrab
        var nextCentre: [Double]
        var nextRadii: [Double]
        var nextFeather = component.feather ?? 50
        var nextRotation = rotation
        if case .radial(let existing) = mode {
            grab = existing
            nextCentre = originCenter.count == 2 ? originCenter : centre
            nextRadii = originRadii.count == 2 ? originRadii : radii
        } else {
            grab = radialGrab(at: value.startLocation, centre: centre, radii: radii,
                              rotation: rotation,
                              feather: component.feather ?? 50,
                              hasGeometry: MaskCanvas.hasEllipse(component))
            nextCentre = centre
            nextRadii = radii
            originCenter = centre
            originRadii = radii
            // Carried for the whole drag, like every other origin here: `rotation` is
            // read back off the component each event, and a turn computed against a
            // value the previous event just wrote compounds instead of tracking.
            originRotation = rotation
            mode = .radial(grab)
        }
        if grab == .rotate { nextRotation = originRotation }

        switch grab {
        case .move:
            // Source coordinates, not displayed ones — see the note on the gradient's
            // translate branch above. Same defect, same fix.
            let from = normalized(value.startLocation)
            let to = normalized(value.location)
            // `nextCentre` is the drag's origin at this point (it is seeded from
            // `originCenter` on a continuation and from `centre` on the first event).
            let base = nextCentre
            nextCentre = [MaskCanvas.coord(base[0] + Double(to.x - from.x)),
                          MaskCanvas.coord(base[1] + Double(to.y - from.y))]
        case .resizeMajor, .resizeMinor:
            // The radius moves by what the POINTER moved, in the ellipse's own frame.
            // It used to be assigned the pointer's own distance from the centre, which
            // was indistinguishable from this while the only way to start a resize was
            // to press the drawn dot — there `|local|` at the press IS the radius, so
            // the two agree exactly. It stops being indistinguishable now that the whole
            // rim resizes: grabbing the rim 40° round from the major axis would have
            // snapped that radius to `r·cos 40° = 0.77 r` before the hand had moved, and
            // grabbing anywhere on a rim that a rotation has turned would jump further
            // still. `nextRadii` is the drag's origin, so this stays a pure function of
            // the current pointer — no accumulation across events.
            let atPress = localVector(from: nextCentre, to: value.startLocation,
                                      rotation: rotation)
            let local = localVector(from: nextCentre, to: value.location,
                                    rotation: rotation)
            if grab == .resizeMajor {
                let moved = abs(local.x) - abs(atPress.x)
                nextRadii[0] = MaskCanvas.radius(nextRadii[0] + moved)
            } else {
                let moved = abs(local.y) - abs(atPress.y)
                nextRadii[1] = MaskCanvas.radius(nextRadii[1] + moved)
            }
            if isShiftDown {
                nextRadii = roundedRadii(nextRadii, drivenByX: grab == .resizeMajor)
            }
        case .create:
            // Only reached when the press landed clear of the ellipse, or with ⌘ down.
            //
            // THE TRAVEL GUARD IS THE REPORTED DEFECT'S LAST INCH. Without it a press
            // with no movement writes `radii = [radius(0), radius(0)]`, and `radius`
            // clamps to 0.002 — a click used to shrink the mask to two thousandths of
            // the frame, which on screen is indistinguishable from deleting it, and it
            // fired on 99.99% of the canvas. The hit test above now refuses to call this
            // a create at all near an existing ellipse; this refuses to destroy one even
            // when the press was genuinely out in the open and the hand never moved.
            guard MaskHandles.drawsShape(from: value.startLocation,
                                         to: value.location) else { return }
            let start = normalized(value.startLocation)
            let end = normalized(value.location)
            if isOptionDown {
                nextCentre = [Double(start.x), Double(start.y)]
                nextRadii = [MaskCanvas.radius(abs(Double(end.x) - Double(start.x))),
                             MaskCanvas.radius(abs(Double(end.y) - Double(start.y)))]
            } else {
                nextCentre = [(Double(start.x) + Double(end.x)) / 2,
                              (Double(start.y) + Double(end.y)) / 2]
                nextRadii = [MaskCanvas.radius(abs(Double(end.x) - Double(start.x)) / 2),
                             MaskCanvas.radius(abs(Double(end.y) - Double(start.y)) / 2)]
            }
            if isShiftDown { nextRadii = roundedRadii(nextRadii, drivenByX: true) }

        case .feather:
            // WHERE THE POINTER IS, not how far it moved. The ring is a position on the
            // ray from the centre, so tracking the pointer's own fraction is what makes
            // the ring stay under the finger; a travel delta would drift away from it
            // over a long drag, which is the one thing a control you are LOOKING at may
            // not do.
            let local = localVector(from: nextCentre, to: value.location,
                                    rotation: rotation)
            let rx = Swift.max(abs(nextRadii[0]), 1e-9)
            let ry = Swift.max(abs(nextRadii[1]), 1e-9)
            let nx = local.x / rx, ny = local.y / ry
            let rho = (nx * nx + ny * ny).squareRoot()
            guard rho.isFinite else { return }
            nextFeather = Num.clamp((1 - rho) * 100, 0, 100)

        case .rotate:
            // The angle from the centre to the pointer, minus the angle it had at the
            // press, added to the rotation the ellipse started the drag with. Taking the
            // pointer's absolute angle instead would snap the major axis under the
            // finger the instant the handle was touched.
            let from = viewPoint(nextCentre[0], nextCentre[1])
            let a0 = atan2(Double(value.startLocation.y - from.y),
                           Double(value.startLocation.x - from.x))
            let a1 = atan2(Double(value.location.y - from.y),
                           Double(value.location.x - from.x))
            guard a0.isFinite, a1.isFinite else { return }
            var turned = originRotation + (a1 - a0) * 180 / Double.pi
            // ⇧ snaps to the same fifteen degrees the gradient uses, so one habit
            // covers both shapes.
            if isShiftDown {
                let step = MaskHandles.angleSnapDegrees
                turned = (turned / step).rounded() * step
            }
            nextRotation = turned.truncatingRemainder(dividingBy: 360)
        }

        var next = component
        next.center = nextCentre
        next.radii = nextRadii
        next.feather = nextFeather
        next.rotation = nextRotation
        commit(.component(maskID: maskID, index: componentIndex, component: next,
                          coalescingKey: ended ? nil : coalescingKey("radial")))
    }

    /// The press and the drawn ellipse, in view points, handed to the rule in
    /// `MaskHandles`.
    ///
    /// The three points passed across are exactly the three this view already draws, and
    /// that is deliberate: whatever the crop, the straighten and the flip do to the
    /// picture they do to these, so the shape the rule hit-tests is the shape on the
    /// screen down to the last point. A hit test written against `centre`/`radii`
    /// directly would be testing the shape in the SOURCE frame — the same class of
    /// mistake as the displayed-coordinates delta the move branch above documents.
    private func radialGrab(at point: CGPoint, centre: [Double], radii: [Double],
                            rotation: Double, feather: Double,
                            hasGeometry: Bool) -> MaskHandles.RadialGrab {
        // ⌘ means "another one", wherever the press landed. See `lineGrab`.
        if isCommandDown { return .create }
        let major = viewPoint(from: centre, offset: (radii[0], 0), rotation: rotation)
        let minor = viewPoint(from: centre, offset: (0, radii[1]), rotation: rotation)
        return MaskHandles.radialGrab(press: point,
                                      centre: viewPoint(centre[0], centre[1]),
                                      majorHandle: major, minorHandle: minor,
                                      feather: feather,
                                      hasGeometry: hasGeometry,
                                      rotateHandle: MaskCanvas.rotateHandle(
                                        centre: viewPoint(centre[0], centre[1]),
                                        major: major))
    }

    /// Where the rotation handle is drawn, and therefore where it can be grabbed: on
    /// the major axis, `rotateHandleOffset` points beyond the rim.
    ///
    /// Nil when the axis is too short to place it on — a freshly pinched ellipse has no
    /// direction to speak of, and a handle whose position is decided by rounding error
    /// jumps across the screen while you resize.
    /// One axis's half-length in view points, which is what both the feather ring's
    /// room test and the rotation handle's placement are measured in.
    static func axisLength(_ centre: CGPoint, _ handle: CGPoint) -> Double {
        let d = Double(hypot(handle.x - centre.x, handle.y - centre.y))
        return d.isFinite ? d : 0
    }

    static func rotateHandle(centre: CGPoint, major: CGPoint) -> CGPoint? {
        let dx = major.x - centre.x, dy = major.y - centre.y
        let length = hypot(dx, dy)
        guard length.isFinite, length > 4 else { return nil }
        let out = length + CGFloat(MaskHandles.rotateHandleOffset)
        return CGPoint(x: centre.x + dx / length * out, y: centre.y + dy / length * out)
    }

    /// Radii are normalized against width and height separately, so "round" is a
    /// statement about PIXELS: rx·W = ry·H.
    private func roundedRadii(_ radii: [Double], drivenByX: Bool) -> [Double] {
        guard radii.count == 2 else { return radii }
        let w = sourceSize.width > 0 ? Double(sourceSize.width) : Double(imageRect.width)
        let h = sourceSize.height > 0 ? Double(sourceSize.height) : Double(imageRect.height)
        guard w > 0, h > 0 else { return radii }
        if drivenByX { return [radii[0], MaskCanvas.radius(radii[0] * w / h)] }
        return [MaskCanvas.radius(radii[1] * h / w), radii[1]]
    }

    // MARK: Brush

    /// The pressure of the event being handled, 0…1.
    ///
    /// `BrushPoint.pressure` has been in the wire format and read by the rasterizer
    /// since the format was written; the recorder wrote a literal `1` on every point,
    /// so every tablet in the world drew like a mouse (docs/36 §2, "tablet pressure and
    /// tilt"). The field and the reader existed; only the writer did not.
    ///
    /// `NSApp.currentEvent` rather than a custom `NSView`: SwiftUI's `DragGesture`
    /// carries no pressure, and the event being dispatched right now is the one that
    /// produced this callback. A mouse or trackpad reports `pressure` 1 for a held
    /// button and 0 otherwise, which is why a zero is read as a mouse and promoted —
    /// a stroke that deposited nothing would be a worse bug than no pressure at all.
    /// Whether Option is held right now.
    ///
    /// `NSEvent.modifierFlags` rather than the gesture's, because SwiftUI's
    /// `DragGesture.Value` carries no modifiers and the alternative — an
    /// `.onModifierKeysChanged` in the view — would miss a modifier that was already
    /// down when the press landed, which is exactly how it is used.
    static func optionHeld() -> Bool {
        NSEvent.modifierFlags.contains(.option)
    }

    static func currentPressure() -> Double {
        guard let event = NSApp.currentEvent else { return 1 }
        switch event.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp,
             .tabletPoint, .tabletProximity:
            let p = Double(event.pressure)
            return (p.isFinite && p > 0) ? Num.saturate(p) : 1
        default:
            return 1
        }
    }

    private func dragBrush(_ value: DragGesture.Value, ended: Bool) {
        // The whole stroke accumulates locally; nothing reaches the recipe until mouse-up,
        // so a stroke is one undo step and a mouse-moved event is not a recipe write.
        let isNew = mode != .brush
        let started: Date = isNew ? Date() : (strokeStarted ?? Date())
        var points: [BrushPoint] = isNew ? [] : livePoints
        if isNew {
            mode = .brush
            strokeStarted = started
            // SHIFT CONTINUES FROM WHERE THE LAST STROKE ENDED, which is the one brush
            // gesture every other editor has and this one did not. Seeding the stroke
            // with the previous stroke's last point makes the segment between them a
            // stroke like any other: the rasterizer's arc-length interpolation walks it,
            // it takes the current size and feather, and it is one undo step.
            //
            // A click is a drag that did not move, so shift-click paints a straight
            // segment and shift-DRAG starts from the same anchor and then follows the
            // hand — both fall out of the same three lines rather than needing a mode.
            if isShiftDown, let anchor = strokes.strokes.last?.points.last {
                points = [BrushPoint(x: anchor.x, y: anchor.y,
                                     pressure: anchor.pressure, t: 0)]
            }
        }
        let n = normalized(value.location)
        let ms = Int(Num.clamp(Date().timeIntervalSince(started) * 1000, 0, 3_600_000))
        // The pulled string, between the pointer and what gets recorded. At Stabilize 0
        // it is a rigid connection and this is arithmetically the line it replaces.
        //
        // `finish` on the last event rather than `next`, because a stabilized stroke
        // otherwise stops one rope-length short of where the hand let go — every time,
        // which is a systematic error rather than smoothing and a visible gap on a
        // stroke drawn to meet another one.
        // HOLD-OPTION ERASES, which is docs/08 §8.6's contract and LR's, and which is
        // why there is no `E` key: `E` is the loupe in this application and taking it
        // would have been a collision fixed by making a photographer relearn a key they
        // already had. The modifier is read at the START of the stroke and carried, so
        // letting go mid-drag does not turn half a stroke into paint.
        //
        // Read here, beside the stabilizer's own start-of-stroke work, rather than
        // after the guard below: the first sample can never be swallowed by the rope
        // (there is nothing to be inside of yet), but a reader should not have to prove
        // that to know the eraser flag is set.
        if isNew {
            stabilizer = BrushStabilizer(strength: brush.stabilize)
            eraseHeld = Self.optionHeld()
        }
        var smoother = stabilizer ?? BrushStabilizer(strength: brush.stabilize)
        let moved = ended ? (smoother.finish(x: Double(n.x), y: Double(n.y))
                                ?? smoother.next(x: Double(n.x), y: Double(n.y)))
                          : smoother.next(x: Double(n.x), y: Double(n.y))
        stabilizer = smoother
        guard let moved else {
            // Inside the rope: nothing was painted, and the live stroke is unchanged.
            if ended { commitBrushStroke(points) }
            return
        }
        let point = BrushPoint(x: moved.x, y: moved.y,
                               pressure: Self.currentPressure(), t: ms)
        // Sub-pixel resampling is the rasterizer's job (arc-length Catmull-Rom); the
        // recorder only drops events that did not move.
        var accept = true
        if let last = points.last {
            let dx = (last.x - point.x) * Double(imageRect.width)
            let dy = (last.y - point.y) * Double(imageRect.height)
            accept = ended || (dx * dx + dy * dy) >= 0.25
        }
        if accept { points.append(point) }
        livePoints = points

        guard ended else { return }
        commitBrushStroke(points)
    }

    /// The end of a stroke, in one place because there are two ways to reach it: the
    /// ordinary last event, and a last event the stabilizer swallowed because the hand
    /// released inside the rope. Missing the second is a stroke that never lands.
    private func commitBrushStroke(_ points: [BrushPoint]) {
        livePoints = []
        strokeStarted = nil
        stabilizer = nil
        guard !points.isEmpty else {
            eraseHeld = false
            return
        }
        var set = strokes
        // The held modifier wins over the panel's toggle for THIS stroke only: the
        // toggle is a mode you set, the modifier is a thing you do, and the thing you
        // do while holding a key is what you meant.
        var stroke = brush.stroke(points: points)
        if eraseHeld { stroke.erase = true }
        eraseHeld = false
        set.strokes.append(stroke)
        let payload = try? set.encode()
        let ref = payload.map { BrushStrokeSet.blobRef(for: $0) }
        commit(.strokes(maskID: maskID, index: componentIndex, strokes: set,
                        ref: ref, payload: payload))
    }

    // MARK: Drawing

    private func drawLine(_ context: inout GraphicsContext, _ component: MaskComponent) {
        // Nothing until it has been drawn, for the reason `drawRadial` gives.
        guard let line = MaskCanvas.optionalLine(component) else { return }
        let p0 = viewPoint(line[0], line[1])
        let p1 = viewPoint(line[2], line[3])
        let dx = p1.x - p0.x
        let dy = p1.y - p0.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0.5 else { return }
        let ux = dx / length
        let uy = dy / length
        let reach = Swift.max(imageRect.width, imageRect.height) * 1.5

        var band = Path()
        for anchor in [p0, p1] {
            band.move(to: CGPoint(x: anchor.x - uy * reach, y: anchor.y + ux * reach))
            band.addLine(to: CGPoint(x: anchor.x + uy * reach, y: anchor.y - ux * reach))
        }
        var axis = Path()
        axis.move(to: p0)
        axis.addLine(to: p1)

        stroke(&context, band, width: 1, alpha: 0.85)
        stroke(&context, axis, width: 1, alpha: 0.55)
        handle(&context, p0)
        handle(&context, p1)
        handle(&context, CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2), small: true)
    }

    private func drawRadial(_ context: inout GraphicsContext, _ component: MaskComponent) {
        // NOTHING until it has been drawn. A ghost ellipse where the shape is about to
        // be would be a picture of a mask that does not exist yet, and the one thing it
        // would reliably teach is that the tool ignores where you press.
        guard MaskCanvas.hasEllipse(component) else { return }
        let centre = MaskCanvas.pair(component.center, fallback: [0.5, 0.5])
        let radii = MaskCanvas.pair(component.radii, fallback: [0.25, 0.25])
        let rotation = component.rotation ?? 0
        let feather = Num.clamp(component.feather ?? 50, 0, 100) / 100

        stroke(&context, ellipsePath(centre, radii, rotation, scale: 1), width: 1, alpha: 0.85)
        let inner = Swift.max(1 - feather, 0.02)
        if inner < 0.999 {
            stroke(&context, ellipsePath(centre, radii, rotation, scale: inner),
                   width: 1, alpha: 0.35)
            // A HANDLE ON THE RING, on the same two conditions the hit test uses — the
            // file's own rule about the rim's four dots is that a picture showing an
            // affordance where there isn't one is a picture that lies about where the
            // shape can be grabbed, and it lies just as badly the other way. The ring
            // has been drawn since this view was written and has never been draggable;
            // now that it is, it has to look it, and where it is NOT draggable — a
            // small ellipse, or a feather at either end of its travel — it must not.
            let shortest = Swift.min(
                MaskCanvas.axisLength(viewPoint(centre[0], centre[1]),
                                      viewPoint(from: centre, offset: (radii[0], 0),
                                                rotation: rotation)),
                MaskCanvas.axisLength(viewPoint(centre[0], centre[1]),
                                      viewPoint(from: centre, offset: (0, radii[1]),
                                                rotation: rotation)))
            if inner >= MaskHandles.featherRingFloor,
               inner <= MaskHandles.featherRingCeiling,
               inner * shortest >= 2 * MaskHandles.grabRadius {
                handle(&context,
                       viewPoint(from: centre, offset: (radii[0] * inner, 0),
                                 rotation: rotation),
                       small: true)
            }
        }
        // FOUR rim dots, not two. The hit test takes a resize from anywhere on the rim,
        // and a picture that shows an affordance on only half of it is a picture that
        // lies about where the shape can be grabbed — which is the habit that produced
        // the reported defect in the first place. The centre dot stays, drawn small: it
        // is no longer the only way to move the ellipse, it is the mark that says where
        // the ellipse is centred.
        handle(&context, viewPoint(centre[0], centre[1]), small: true)
        for offset in [(radii[0], 0.0), (-radii[0], 0.0),
                       (0.0, radii[1]), (0.0, -radii[1])] {
            handle(&context, viewPoint(from: centre, offset: offset, rotation: rotation))
        }

        // THE ROTATION HANDLE, on a stalk so it reads as belonging to the ellipse rather
        // than floating beside it. Drawn last, over everything, because it is the only
        // handle that lives outside the shape and a rim that crossed it would make it
        // look like part of the rim.
        let origin = viewPoint(centre[0], centre[1])
        let major = viewPoint(from: centre, offset: (radii[0], 0), rotation: rotation)
        if let knob = MaskCanvas.rotateHandle(centre: origin, major: major) {
            var stalk = Path()
            stalk.move(to: major)
            stalk.addLine(to: knob)
            stroke(&context, stalk, width: 1, alpha: 0.5)
            handle(&context, knob, small: true)
        }
    }

    private func drawBrush(_ context: inout GraphicsContext) {
        let diameter = brushDiameter
        if livePoints.count > 1 {
            var path = Path()
            for (index, point) in livePoints.enumerated() {
                let p = viewPoint(point.x, point.y)
                if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            context.stroke(path,
                           with: .color(Color.white.opacity((brush.erase || eraseHeld) ? 0.18 : 0.32)),
                           style: StrokeStyle(lineWidth: diameter, lineCap: .round,
                                              lineJoin: .round))
        }
        guard let hover = hover else { return }
        let rect = CGRect(x: hover.x - diameter / 2, y: hover.y - diameter / 2,
                          width: diameter, height: diameter)
        var ring = Path()
        ring.addEllipse(in: rect)
        // The cursor says which of the two this press would be — including while Option
        // is merely HELD, before anything has been drawn, which is the moment the
        // question is actually being asked.
        let erasing = brush.erase || eraseHeld
        stroke(&context, ring, width: 1, alpha: erasing ? 0.5 : 0.85)

        // THE SECOND RING, which is the hardness the stamp actually has.
        //
        // The cursor drew one circle, so Feather — a parameter that also cannot be
        // changed after the stroke is painted — could not be judged before it either.
        // The inner radius is `MaskRaster.stampProfile`'s flat core: full deposition
        // out to `hardness`, smoothstep shoulder to the rim. Drawn only when there is
        // a shoulder worth drawing and enough room to see it.
        let hardness = Num.saturate(1 - Num.clamp(brush.feather, 0, 100) / 100)
        let inner = diameter * CGFloat(hardness)
        if hardness > 0.02, diameter - inner > 3 {
            var core = Path()
            core.addEllipse(in: CGRect(x: hover.x - inner / 2, y: hover.y - inner / 2,
                                       width: inner, height: inner))
            stroke(&context, core, width: 1, alpha: erasing ? 0.28 : 0.42)
        }
    }

    /// The similarity points: where the colour is being matched, and how far.
    ///
    /// Without these on the picture, "Reach" was a slider with no referent — the one
    /// control whose whole meaning is a distance on the photograph, expressed as a
    /// number in a column. A positive point draws a full ring, a negative one a dashed
    /// ring, and both carry their sign at the centre.
    private func drawPoints(_ context: inout GraphicsContext, _ c: MaskComponent) {
        for (index, entry) in (c.points ?? []).enumerated() where entry.count >= 3 {
            guard entry[0].isFinite, entry[1].isFinite, entry[2].isFinite else { continue }
            let centre = viewPoint(entry[0], entry[1])
            let r = pointRadiusInView(entry[2])
            guard r.isFinite, r > 1 else { continue }
            let negative = entry.count >= 4 && entry[3] < 0
            var ring = Path()
            ring.addEllipse(in: CGRect(x: centre.x - r, y: centre.y - r,
                                       width: r * 2, height: r * 2))
            if negative {
                context.stroke(ring, with: .color(Color.black.opacity(0.4)),
                               style: StrokeStyle(lineWidth: 3, dash: [5, 4]))
                context.stroke(ring, with: .color(Color.white.opacity(0.8)),
                               style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            } else {
                stroke(&context, ring, width: 1, alpha: 0.8)
            }
            handle(&context, centre, small: index != pointGrab?.index)
            // The sign, drawn as a bar (and a crossbar for positive) rather than as
            // text: a glyph at this size has to be a shape, not a character.
            let arm: CGFloat = 3
            var mark = Path()
            mark.move(to: CGPoint(x: centre.x - arm, y: centre.y))
            mark.addLine(to: CGPoint(x: centre.x + arm, y: centre.y))
            if !negative {
                mark.move(to: CGPoint(x: centre.x, y: centre.y - arm))
                mark.addLine(to: CGPoint(x: centre.x, y: centre.y + arm))
            }
            context.stroke(mark, with: .color(Color.black.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
    }

    /// The id of another mask's pin under this point, if any. Nearest wins.
    private func foreignPin(at location: CGPoint) -> String? {
        var best: (id: String, d: CGFloat)? = nil
        // A DOCKED PIN IS NOT A TARGET, and that is the trade docking costs. Docking
        // puts a pin on the frame's edge, and this test runs BEFORE the brush — so with
        // another mask anchored off the visible picture, painting along that edge would
        // select the other mask instead of laying down paint. Losing a stroke to a
        // signpost is a real cost; not being able to select from a signpost is not,
        // because the row it stands for is in the list two inches away.
        for (id, point, docked) in pinPositions() where id != maskID && !docked {
            let d = hypot(location.x - point.x, location.y - point.y)
            guard d <= MaskCanvas.pinGrab else { continue }
            if best == nil || d < best!.d { best = (id, d) }
        }
        return best?.id
    }

    /// How near a pin a press has to land to mean it. The same 11 pt `MaskHandles` uses
    /// for a gradient's dots — a grab radius smaller than the thing drawn is a target
    /// you can see and cannot hit.
    static let pinGrab: CGFloat = 11

    /// Every other mask's geometry, at a quarter weight.
    ///
    /// Geometry only — a brush stroke has no outline worth drawing at this weight, and a
    /// range mask has no shape at all — so what appears is the set of shapes a gesture
    /// could collide with, which is what this is for.
    private func drawOtherMasks(_ context: inout GraphicsContext) {
        for mask in allMasks where mask.id != maskID && mask.enabled {
            for c in mask.components {
                switch c.kind {
                case .linear, .similarityLine:
                    guard let line = MaskCanvas.optionalLine(c) else { continue }
                    var path = Path()
                    path.move(to: viewPoint(line[0], line[1]))
                    path.addLine(to: viewPoint(line[2], line[3]))
                    stroke(&context, path, width: 1, alpha: 0.22)
                case .radial:
                    guard let centre = c.center, centre.count == 2,
                          let radii = c.radii, radii.count == 2 else { continue }
                    stroke(&context, ellipsePath(centre, radii, c.rotation ?? 0, scale: 1),
                           width: 1, alpha: 0.22)
                case .polygon:
                    guard let outline = MaskCanvas.outlinePath(c) else { continue }
                    var path = Path()
                    path.move(to: viewPoint(outline[0][0], outline[0][1]))
                    for entry in outline.dropFirst() {
                        path.addLine(to: viewPoint(entry[0], entry[1]))
                    }
                    path.closeSubpath()
                    stroke(&context, path, width: 1, alpha: 0.22)
                default:
                    continue
                }
            }
        }
    }

    /// One pin per mask: where it is, and which one is selected.
    ///
    /// docs/08 §8.1 clones Lightroom's pins and nothing drew one. A pin is how a
    /// photographer picks the mask under the thing they are looking AT, rather than by
    /// reading a list and remembering which name goes with which shape.
    ///
    /// A pin whose mask has no geometry — a Colour Range, a Subject — has no honest
    /// place on the picture, so it does not get one. Inventing a position would be a
    /// handle that lies about where its mask lives.
    private func drawPins(_ context: inout GraphicsContext) {
        for (id, point, docked) in pinPositions() {
            let selected = id == maskID
            // A DOCKED PIN IS A SIGNPOST, NOT A POSITION — the mask is not there, it is
            // that way — so it is drawn smaller and hollow. Drawn identically it would
            // be a picture claiming a mask sits in a corner it does not, which is the
            // same class of lie as an affordance where nothing can be grabbed.
            if docked {
                let r: CGFloat = selected ? 5 : 4
                let rect = CGRect(x: point.x - r, y: point.y - r,
                                  width: r * 2, height: r * 2)
                context.stroke(Path(ellipseIn: rect),
                               with: .color(Color.black.opacity(0.5)), lineWidth: 3)
                context.stroke(Path(ellipseIn: rect),
                               with: .color(Color.white.opacity(selected ? 0.9 : 0.45)),
                               lineWidth: 1.25)
                continue
            }
            let r: CGFloat = selected ? 6.5 : 5
            let rect = CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)
            context.fill(Path(ellipseIn: rect.insetBy(dx: -1.5, dy: -1.5)),
                         with: .color(Color.black.opacity(0.5)))
            context.fill(Path(ellipseIn: rect),
                         with: .color(Color.white.opacity(selected ? 0.95 : 0.55)))
            if selected {
                context.fill(Path(ellipseIn: rect.insetBy(dx: r - 2, dy: r - 2)),
                             with: .color(Color.black.opacity(0.75)))
            }
        }
    }

    /// Where each mask's pin sits, in view points. Masks with no drawable geometry are
    /// absent from the result rather than placed somewhere arbitrary.
    private func pinPositions() -> [(id: String, point: CGPoint, docked: Bool)] {
        var out: [(String, CGPoint, Bool)] = []
        for mask in allMasks where mask.enabled {
            guard let anchor = MaskCanvas.anchor(of: mask) else { continue }
            // DOCKED, not dropped. A pin off the visible picture used to vanish — at
            // 1:1 on a corner that is most of them — so the one control that selects a
            // mask from the photograph disappeared exactly when the list is the only
            // way left, which is the moment pins exist to avoid.
            guard let docked = MaskHandles.dockedPin(
                viewPoint(anchor.x, anchor.y),
                in: CGSize(width: imageRect.width, height: imageRect.height))
            else { continue }
            out.append((mask.id, docked.point, docked.docked))
        }
        return out
    }

    /// A mask's source-normalized anchor: the first component that has a position.
    static func anchor(of mask: Mask) -> (x: Double, y: Double)? {
        for c in mask.components {
            switch c.kind {
            case .radial:
                if let centre = c.center, centre.count == 2,
                   centre[0].isFinite, centre[1].isFinite {
                    return (centre[0], centre[1])
                }
            case .linear, .similarityLine:
                if let line = optionalLine(c) {
                    return ((line[0] + line[2]) / 2, (line[1] + line[3]) / 2)
                }
            case .similarity:
                if let first = (c.points ?? []).first, first.count >= 2,
                   first[0].isFinite, first[1].isFinite {
                    return (first[0], first[1])
                }
            case .polygon:
                // The centroid of the corners, not the first one: a pin on a vertex
                // sits on the shape's edge, where it overlaps the handle that is
                // already there and reads as belonging to whichever side of the
                // boundary it happens to land on.
                if let outline = outlinePath(c) {
                    let n = Double(outline.count)
                    return (outline.reduce(0) { $0 + $1[0] } / n,
                            outline.reduce(0) { $0 + $1[1] } / n)
                }
            default:
                continue
            }
        }
        return nil
    }

    /// True when this component has an ellipse to grab at all.
    ///
    /// A radial created from the picker no longer arrives with one — the owner's
    /// complaint was "I don't want to automatically be given the oval shape", and being
    /// handed a circle in the middle of the frame ALSO meant there was never clear space
    /// to draw in, so the `.create` gesture that has been there all along could not be
    /// reached. Nil geometry resolves to a fallback for drawing, so this is what the
    /// hit test asks instead of testing the fallback.
    static func hasEllipse(_ c: MaskComponent) -> Bool {
        guard let centre = c.center, centre.count == 2,
              let radii = c.radii, radii.count == 2 else { return false }
        return centre.allSatisfy(\.isFinite) && radii.allSatisfy(\.isFinite)
            && abs(radii[0]) > 1e-9 && abs(radii[1]) > 1e-9
    }

    /// A component's outline, when it has a well-formed one — three finite corners or
    /// more, which is the same floor `validationError` holds.
    static func outlinePath(_ c: MaskComponent) -> [[Double]]? {
        guard let path = c.path, path.count >= 3,
              path.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) })
        else { return nil }
        return path
    }

    /// A component's line, when it has a well-formed one.
    static func optionalLine(_ c: MaskComponent) -> [Double]? {
        guard let line = c.line, line.count == 4, line.allSatisfy({ $0.isFinite })
        else { return nil }
        return line
    }

    /// A similarity point's reach, in view points.
    ///
    /// The radius is stored as a fraction of the SOURCE long edge — the unit
    /// `BrushStroke.size` uses, so a point keeps its reach through a crop. Converting
    /// it through the DISPLAYED long edge is the defect the brush cursor already had:
    /// on a 0.35 crop the ring showed about a third of the reach the rasterizer used.
    private func pointRadiusInView(_ radius: Double) -> CGFloat {
        let perSourcePixel = PipelineRenderer.displayedPixelsPerSourcePixel(
            geometry, sourceSize: sourceSize,
            displayedLongEdge: Swift.max(imageRect.width, imageRect.height))
        let sourceLong = Swift.max(sourceSize.width, sourceSize.height)
        return CGFloat(Num.clamp(radius, 0, 2)) * sourceLong * perSourcePixel
    }

    /// The inverse, for the resize drag.
    private func pointRadiusFromView(_ points: CGFloat) -> Double {
        let perSourcePixel = PipelineRenderer.displayedPixelsPerSourcePixel(
            geometry, sourceSize: sourceSize,
            displayedLongEdge: Swift.max(imageRect.width, imageRect.height))
        let sourceLong = Swift.max(sourceSize.width, sourceSize.height)
        let denominator = sourceLong * perSourcePixel
        guard denominator > 0.0001 else { return 0.15 }
        return Num.clamp(Double(points / denominator), 0.01, 1.0)
    }

    /// The cursor ring, in view points.
    ///
    /// `brush.size` is a fraction of the SOURCE long edge, so converting it through the
    /// displayed long edge was only right on an uncropped photo. On a 0.35 crop the
    /// ring showed about a third of the width the stroke actually painted — the cursor
    /// promised one brush and the rasterizer used another.
    private var brushDiameter: CGFloat {
        let perSourcePixel = PipelineRenderer.displayedPixelsPerSourcePixel(
            geometry, sourceSize: sourceSize,
            displayedLongEdge: Swift.max(imageRect.width, imageRect.height))
        let sourceLong = Swift.max(sourceSize.width, sourceSize.height)
        let d = CGFloat(Num.clamp(brush.size, 0.0005, 2)) * sourceLong * perSourcePixel
        return Swift.max(d, 2)
    }

    private func ellipsePath(_ centre: [Double], _ radii: [Double], _ rotation: Double,
                             scale: Double) -> Path {
        var path = Path()
        let steps = 72
        for step in 0...steps {
            let u = Double(step) / Double(steps) * 2 * Double.pi
            let p = viewPoint(from: centre,
                              offset: (radii[0] * scale * cos(u), radii[1] * scale * sin(u)),
                              rotation: rotation)
            if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }

    /// Two passes: a dark under-stroke and a light over-stroke, so the affordance is
    /// legible over any photograph without introducing a hue (docs/00 Law 7).
    private func stroke(_ context: inout GraphicsContext, _ path: Path,
                        width: CGFloat, alpha: Double) {
        context.stroke(path, with: .color(Color.black.opacity(alpha * 0.5)),
                       style: StrokeStyle(lineWidth: width + 2, lineCap: .round))
        context.stroke(path, with: .color(Color.white.opacity(alpha)),
                       style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    private func handle(_ context: inout GraphicsContext, _ point: CGPoint,
                        small: Bool = false) {
        let r: CGFloat = small ? 3 : 4.5
        let rect = CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)
        context.fill(Path(ellipseIn: rect.insetBy(dx: -1, dy: -1)),
                     with: .color(Color.black.opacity(0.45)))
        context.fill(Path(ellipseIn: rect), with: .color(Color.white.opacity(0.95)))
    }

    // MARK: Coordinates

    /// View point → source-normalized fraction. Values are allowed a little way past
    /// the frame: a gradient anchored off-image and a stroke that overdraws the edge
    /// are both ordinary.
    private func normalized(_ point: CGPoint) -> CGPoint {
        guard imageRect.width > 0, imageRect.height > 0 else { return .zero }
        // View point -> displayed fraction -> SOURCE fraction, through the inverse of
        // the very transform the renderer applied. See `PipelineRenderer
        // .sourceNormalized`.
        let u = Double((point.x - imageRect.minX) / imageRect.width)
        let v = Double((point.y - imageRect.minY) / imageRect.height)
        let source = PipelineRenderer.sourceNormalized(displayedX: u, displayedY: v,
                                                       geometry: geometry,
                                                       sourceSize: sourceSize)
        return CGPoint(x: MaskCanvas.coord(Double(source.x)),
                       y: MaskCanvas.coord(Double(source.y)))
    }

    private func viewPoint(_ nx: Double, _ ny: Double) -> CGPoint {
        let displayed = PipelineRenderer.displayedNormalized(sourceX: nx, sourceY: ny,
                                                             geometry: geometry,
                                                             sourceSize: sourceSize)
        return CGPoint(x: imageRect.minX + displayed.x * imageRect.width,
                       y: imageRect.minY + displayed.y * imageRect.height)
    }

    /// The source frame's pixel extent, as the rasterizer sees it.
    ///
    /// Masks are rasterized in the SOURCE frame — `PipelineRenderer` takes the decoded
    /// extent and geometry runs after the graph — so this is the same `w`/`h` that
    /// `MaskRaster.radialPlane` normalises against, and the two conventions can be
    /// compared directly.
    private var sourcePixels: (w: Int, h: Int) {
        (Int(sourceSize.width.rounded()), Int(sourceSize.height.rounded()))
    }

    /// A point at `offset` in the ellipse's own rotated frame.
    ///
    /// **THIS USED TO ROTATE IN PER-AXIS NORMALIZED SPACE, and the rasterizer stopped
    /// doing that.** The comment here asserted "the rotation convention is the
    /// rasterizer's" and went on asserting it after `radialPlane` was changed to rotate
    /// in long-edge units — pixels are square and normalized coordinates are not, so a
    /// rotation matrix applied to (fraction of width, fraction of height) mixes two
    /// units and a 45° ellipse on a 3:2 frame renders at 33.7°.
    ///
    /// What the drift cost: on a 6000×4000 frame with a radial turned to 45°, the drawn
    /// rim, all four resize dots, the feather ring and the rotate stalk sat about 283
    /// source pixels — some 85 screen points — from the mask that was actually
    /// rendering, against an 11 pt grab radius. The outline did not match the effect;
    /// pressing the drawn rim could miss the real one and be read as "draw a new ellipse
    /// here", which throws the shape away; and `localVector` inverted the same wrong
    /// transform, so resize and feather dragged by the wrong amount.
    ///
    /// The conversion lives in `MaskRaster` now, beside the loop it has to agree with,
    /// and `RadialFrameTests` checks the handle positions against that loop's OUTPUT
    /// rather than against a second copy of its formula.
    private func viewPoint(from centre: [Double], offset: (Double, Double),
                           rotation: Double) -> CGPoint {
        guard centre.count == 2 else { return .zero }
        let size = sourcePixels
        let d = MaskRaster.radialOffset((x: offset.0, y: offset.1), rotation: rotation,
                                        width: size.w, height: size.h)
        return viewPoint(centre[0] + d.x, centre[1] + d.y)
    }

    /// The inverse of `viewPoint(from:offset:rotation:)`: a view point expressed in the
    /// ellipse's own frame, which is what a resize handle needs.
    private func localVector(from centre: [Double], to point: CGPoint,
                             rotation: Double) -> (x: Double, y: Double) {
        guard centre.count == 2 else { return (0, 0) }
        let n = normalized(point)
        let size = sourcePixels
        return MaskRaster.radialLocal((x: Double(n.x) - centre[0],
                                       y: Double(n.y) - centre[1]),
                                      rotation: rotation,
                                      width: size.w, height: size.h)
    }

    /// Shift snaps a drag to the nearest 15° through its anchor.
    ///
    /// It used to snap to the horizontal or the vertical and nothing else, which covers
    /// a level horizon and a straight-down sky and leaves you on your own for a gradient
    /// raked along a hillside — the ordinary case, and the one case the constraint could
    /// not help with. `MaskHandles.snapped` owns the arithmetic, in LumenCore where
    /// `MaskAngleSnapTests` can reach it; 0 and 90 are multiples of 15, so nothing
    /// anyone had learned about this key stopped working.
    private func constrained(_ point: CGPoint, anchor: CGPoint) -> CGPoint {
        guard isShiftDown else { return point }
        return MaskHandles.snapped(point, anchor: anchor)
    }

    private var isShiftDown: Bool { NSEvent.modifierFlags.contains(.shift) }
    private var isOptionDown: Bool { NSEvent.modifierFlags.contains(.option) }
    /// The deliberate "draw another one" modifier — the only destructive gesture this
    /// canvas still offers without asking the picture for permission first.
    private var isCommandDown: Bool { NSEvent.modifierFlags.contains(.command) }

    private func coalescingKey(_ what: String) -> String {
        "mask.canvas.\(what).\(maskID).\(componentIndex)"
    }

    // MARK: Static helpers

    // `handleRadius` and `distance` used to live here: a 9 pt tolerance and the
    // three-dot proximity test that spent it. Both are gone rather than reworded,
    // because keeping a second copy of a tolerance next to the rule that supersedes it
    // is how the two drift apart. The one that counts is `MaskHandles.grabRadius`.

    static func coord(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        return Num.clamp(v, -0.5, 1.5)
    }

    static func radius(_ v: Double) -> Double {
        guard v.isFinite else { return 0.01 }
        return Num.clamp(v, 0.002, 2)
    }

    static func line(_ component: MaskComponent) -> [Double] {
        guard let line = component.line, line.count == 4,
              line.allSatisfy({ $0.isFinite }) else {
            return [0.5, 0.75, 0.5, 0.25]
        }
        return line
    }

    static func pair(_ values: [Double]?, fallback: [Double]) -> [Double] {
        guard let values = values, values.count == 2,
              values.allSatisfy({ $0.isFinite }) else { return fallback }
        return values
    }

    // MARK: Committing

    /// The one place a canvas edit becomes a recipe write. Every index is
    /// bounds-checked at write time as well as at read time: the panel's selection can
    /// be one edit stale, and a stale index must be a no-op rather than a trap.
    ///
    /// The payload rides on the edit, and this writes it to the blob store before it
    /// writes the reference into the recipe. That order is the whole point: a
    /// `strokesRef` whose bytes were never stored is a mask that rasterizes empty
    /// forever, and it reaches the catalog and the sidecar looking exactly like a mask
    /// that works.
    @MainActor
    static func apply(_ edit: MaskCanvasEdit, in state: AppState) {
        switch edit {
        case .component(let maskID, let index, let component, let key):
            state.updateRecipe(coalescingKey: key) { recipe in
                guard let m = recipe.masks.firstIndex(where: { $0.id == maskID }),
                      recipe.masks[m].components.indices.contains(index) else { return }
                recipe.masks[m].components[index] = component
            }
        case .strokes(let maskID, let index, let set, let ref, let payload):
            // The reference is only a promise that the bytes exist. Store them first:
            // a `strokesRef` whose blob was never written is a mask that rasterizes
            // empty forever, and it survives into the catalog and the sidecar looking
            // exactly like a mask that works.
            guard let ref, let payload,
                  let stored = try? state.catalog?.blobs.store(payload),
                  stored == ref else {
                state.statusMessage = "Could not save that stroke — the mask is unchanged"
                return
            }
            // The bytes are already in hand, so the render path does not have to go
            // back to the disk to find out what was just painted.
            state.remember(set, ref: ref)
            state.updateRecipe(coalescingKey: nil) { recipe in
                guard let m = recipe.masks.firstIndex(where: { $0.id == maskID }),
                      recipe.masks[m].components.indices.contains(index) else { return }
                recipe.masks[m].components[index].strokesRef = ref
            }
        }
    }
}

#endif
