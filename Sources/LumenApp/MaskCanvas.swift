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
    @State private var livePoints: [BrushPoint] = []
    @State private var strokeStarted: Date? = nil
    @State private var hover: CGPoint? = nil

    init(imageRect: CGRect,
         sourceSize: CGSize,
         geometry: Geometry,
         maskID: String,
         componentIndex: Int,
         component: MaskComponent?,
         strokes: BrushStrokeSet = BrushStrokeSet(),
         commit: @escaping (MaskCanvasEdit) -> Void) {
        self.imageRect = imageRect
        self.sourceSize = sourceSize
        self.geometry = geometry
        self.maskID = maskID
        self.componentIndex = componentIndex
        self.component = component
        self.strokes = strokes
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
    private enum DragMode: Equatable {
        case idle
        case line(MaskHandles.LinearGrab)
        case radial(MaskHandles.RadialGrab)
        case brush
    }

    // MARK: Body

    var body: some View {
        Canvas { context, _ in
            guard let component = component, isLive else { return }
            switch component.kind {
            case .linear, .similarityLine:
                drawLine(&context, component)
            case .radial:
                drawRadial(&context, component)
            case .brush:
                drawBrush(&context)
            default:
                break
            }
        }
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .onContinuousHover(coordinateSpace: .local) { phase in
            if case .active(let point) = phase {
                hover = point
            } else {
                hover = nil
            }
        }
        .allowsHitTesting(isLive)
        .help(helpText)
    }

    /// True only when there is something to manipulate: the range and AI kinds are
    /// edited in the panel and by the sampler, and the overlay must pass their clicks
    /// through to the viewer rather than swallowing them.
    private var isLive: Bool {
        guard imageRect.width > 1, imageRect.height > 1,
              let component = component else { return false }
        switch component.kind {
        case .linear, .similarityLine, .radial, .brush: return true
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
            return "Drag inside to move, the edge to resize; Shift keeps it round. "
                 + "⌘-drag draws a new ellipse, and Option draws it from the centre."
        case .brush:
            return "Drag to paint. The stroke commits on mouse-up as one undo step."
        default:
            return ""
        }
    }

    // MARK: Gesture

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let component = component else { return }
                sliderGestureChanged(true)
                switch component.kind {
                case .linear, .similarityLine:
                    dragLine(value, component, ended: false)
                case .radial:
                    dragRadial(value, component, ended: false)
                case .brush:
                    dragBrush(value, ended: false)
                default:
                    break
                }
            }
            .onEnded { value in
                defer { sliderGestureChanged(false) }
                guard let component = component else { return }
                switch component.kind {
                case .linear, .similarityLine:
                    dragLine(value, component, ended: true)
                case .radial:
                    dragRadial(value, component, ended: true)
                case .brush:
                    dragBrush(value, ended: true)
                default:
                    break
                }
                mode = .idle
            }
    }

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
            grab = lineGrab(at: value.startLocation, line: line)
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
        if case .radial(let existing) = mode {
            grab = existing
            nextCentre = originCenter.count == 2 ? originCenter : centre
            nextRadii = originRadii.count == 2 ? originRadii : radii
        } else {
            grab = radialGrab(at: value.startLocation, centre: centre, radii: radii,
                              rotation: rotation)
            nextCentre = centre
            nextRadii = radii
            originCenter = centre
            originRadii = radii
            mode = .radial(grab)
        }

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
        }

        var next = component
        next.center = nextCentre
        next.radii = nextRadii
        if next.feather == nil { next.feather = 50 }
        if next.rotation == nil { next.rotation = 0 }
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
                            rotation: Double) -> MaskHandles.RadialGrab {
        // ⌘ means "another one", wherever the press landed. See `lineGrab`.
        if isCommandDown { return .create }
        let major = viewPoint(from: centre, offset: (radii[0], 0), rotation: rotation)
        let minor = viewPoint(from: centre, offset: (0, radii[1]), rotation: rotation)
        return MaskHandles.radialGrab(press: point,
                                      centre: viewPoint(centre[0], centre[1]),
                                      majorHandle: major, minorHandle: minor)
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

    private func dragBrush(_ value: DragGesture.Value, ended: Bool) {
        // The whole stroke accumulates locally; nothing reaches the recipe until mouse-up,
        // so a stroke is one undo step and a mouse-moved event is not a recipe write.
        let isNew = mode != .brush
        let started: Date = isNew ? Date() : (strokeStarted ?? Date())
        var points: [BrushPoint] = isNew ? [] : livePoints
        if isNew {
            mode = .brush
            strokeStarted = started
        }
        let n = normalized(value.location)
        let ms = Int(Num.clamp(Date().timeIntervalSince(started) * 1000, 0, 3_600_000))
        let point = BrushPoint(x: Double(n.x), y: Double(n.y), pressure: 1, t: ms)
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
        livePoints = []
        strokeStarted = nil
        guard !points.isEmpty else { return }
        var set = strokes
        set.strokes.append(brush.stroke(points: points))
        let payload = try? set.encode()
        let ref = payload.map { BrushStrokeSet.blobRef(for: $0) }
        commit(.strokes(maskID: maskID, index: componentIndex, strokes: set,
                        ref: ref, payload: payload))
    }

    // MARK: Drawing

    private func drawLine(_ context: inout GraphicsContext, _ component: MaskComponent) {
        let line = MaskCanvas.line(component)
        guard line.count == 4 else { return }
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
        let centre = MaskCanvas.pair(component.center, fallback: [0.5, 0.5])
        let radii = MaskCanvas.pair(component.radii, fallback: [0.25, 0.25])
        let rotation = component.rotation ?? 0
        let feather = Num.clamp(component.feather ?? 50, 0, 100) / 100

        stroke(&context, ellipsePath(centre, radii, rotation, scale: 1), width: 1, alpha: 0.85)
        let inner = Swift.max(1 - feather, 0.02)
        if inner < 0.999 {
            stroke(&context, ellipsePath(centre, radii, rotation, scale: inner),
                   width: 1, alpha: 0.35)
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
                           with: .color(Color.white.opacity(brush.erase ? 0.18 : 0.32)),
                           style: StrokeStyle(lineWidth: diameter, lineCap: .round,
                                              lineJoin: .round))
        }
        guard let hover = hover else { return }
        let rect = CGRect(x: hover.x - diameter / 2, y: hover.y - diameter / 2,
                          width: diameter, height: diameter)
        var ring = Path()
        ring.addEllipse(in: rect)
        stroke(&context, ring, width: 1, alpha: brush.erase ? 0.5 : 0.85)
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

    /// A point at `offset` in the ellipse's own (rotated, per-axis normalized) frame.
    /// The rotation convention is the rasterizer's: it rotates in normalized space, so
    /// the handles must too or they would drift off the drawn edge on a non-square frame.
    private func viewPoint(from centre: [Double], offset: (Double, Double),
                           rotation: Double) -> CGPoint {
        guard centre.count == 2 else { return .zero }
        let a = rotation * Double.pi / 180
        let c = cos(a)
        let s = sin(a)
        let dx = offset.0 * c - offset.1 * s
        let dy = offset.0 * s + offset.1 * c
        return viewPoint(centre[0] + dx, centre[1] + dy)
    }

    /// The inverse of `viewPoint(from:offset:rotation:)`: a view point expressed in the
    /// ellipse's own frame, which is what a resize handle needs.
    private func localVector(from centre: [Double], to point: CGPoint,
                             rotation: Double) -> (x: Double, y: Double) {
        guard centre.count == 2 else { return (0, 0) }
        let n = normalized(point)
        let dx = Double(n.x) - centre[0]
        let dy = Double(n.y) - centre[1]
        let a = -rotation * Double.pi / 180
        let c = cos(a)
        let s = sin(a)
        return (dx * c - dy * s, dx * s + dy * c)
    }

    /// Shift constrains a drag to the horizontal or vertical axis through its anchor —
    /// the 0/90° gradient the spec asks for.
    private func constrained(_ point: CGPoint, anchor: CGPoint) -> CGPoint {
        guard isShiftDown else { return point }
        let dx = abs(point.x - anchor.x)
        let dy = abs(point.y - anchor.y)
        return dy >= dx ? CGPoint(x: anchor.x, y: point.y) : CGPoint(x: point.x, y: anchor.y)
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
