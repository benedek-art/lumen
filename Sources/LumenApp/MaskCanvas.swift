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
// This view owns no application state. It reads the component it is editing and hands
// finished values back through `commit`, which the host routes into
// `AppState.updateRecipe` — `MaskCanvas.apply(_:in:)` is that routing, written once.

#if os(macOS)

import AppKit
import CoreGraphics
import Foundation
import LumenCore
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

/// `imageRect` is the photo's drawn rect **in this view's own coordinate space**, and
/// `sourceSize` is the source image's pixel extent. Both are needed: the rect converts
/// points, the pixel size fixes the aspect a Shift-constrained circle is round in.
struct MaskCanvas: View {
    let imageRect: CGRect
    let sourceSize: CGSize
    let maskID: String
    let componentIndex: Int
    let component: MaskComponent?
    let strokes: BrushStrokeSet
    let commit: (MaskCanvasEdit) -> Void

    @ObservedObject private var brush: MaskBrushStore = MaskBrushStore.shared

    @State private var mode: DragMode = .idle
    @State private var originLine: [Double] = []
    @State private var originCenter: [Double] = []
    @State private var originRadii: [Double] = []
    @State private var livePoints: [BrushPoint] = []
    @State private var strokeStarted: Date? = nil
    @State private var hover: CGPoint? = nil

    init(imageRect: CGRect,
         sourceSize: CGSize,
         maskID: String,
         componentIndex: Int,
         component: MaskComponent?,
         strokes: BrushStrokeSet = BrushStrokeSet(),
         commit: @escaping (MaskCanvasEdit) -> Void) {
        self.imageRect = imageRect
        self.sourceSize = sourceSize
        self.maskID = maskID
        self.componentIndex = componentIndex
        self.component = component
        self.strokes = strokes
        self.commit = commit
    }

    private enum DragMode: Equatable {
        case idle
        /// 0 = start handle, 1 = end handle, 2 = whole line, 3 = drawing a new one.
        case line(handle: Int)
        /// 0 = move centre, 1 = major radius, 2 = minor radius, 3 = drawing a new one.
        case radial(handle: Int)
        case brush
    }

    // MARK: Body

    var body: some View {
        Canvas { context, _ in
            guard let component, isLive else { return }
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
            switch phase {
            case .active(let point): hover = point
            case .ended: hover = nil
            }
        }
        .allowsHitTesting(isLive)
        .help(helpText)
    }

    /// True only when there is something to manipulate: the range and AI kinds are
    /// edited in the panel and by the sampler, and the overlay must pass their clicks
    /// through to the viewer rather than swallowing them.
    private var isLive: Bool {
        guard imageRect.width > 1, imageRect.height > 1, let component else { return false }
        switch component.kind {
        case .linear, .similarityLine, .radial, .brush: return true
        default: return false
        }
    }

    private var helpText: String {
        guard let component else { return "" }
        switch component.kind {
        case .linear, .similarityLine:
            return "Drag to place the gradient; Shift constrains it to 0/90°."
        case .radial:
            return "Drag to place the ellipse; Shift keeps it round, Option draws from "
                 + "the centre."
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
                guard let component else { return }
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
                guard let component else { return }
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
        if mode == .idle {
            originLine = line
            mode = .line(handle: lineHandle(at: value.startLocation, line: line))
        }
        guard case .line(let handle) = mode else { return }

        var updated = originLine.count == 4 ? originLine : line
        let current = value.location
        switch handle {
        case 0:
            let anchor = viewPoint(updated[2], updated[3])
            let p = constrained(current, anchor: anchor)
            let n = normalized(p)
            updated[0] = Double(n.x)
            updated[1] = Double(n.y)
        case 1:
            let anchor = viewPoint(updated[0], updated[1])
            let p = constrained(current, anchor: anchor)
            let n = normalized(p)
            updated[2] = Double(n.x)
            updated[3] = Double(n.y)
        case 2:
            let dx = Double(value.translation.width / Swift.max(imageRect.width, 1))
            let dy = Double(value.translation.height / Swift.max(imageRect.height, 1))
            updated = [MaskCanvas.coord(updated[0] + dx), MaskCanvas.coord(updated[1] + dy),
                       MaskCanvas.coord(updated[2] + dx), MaskCanvas.coord(updated[3] + dy)]
        default:
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

    private func lineHandle(at point: CGPoint, line: [Double]) -> Int {
        guard line.count == 4 else { return 3 }
        let p0 = viewPoint(line[0], line[1])
        let p1 = viewPoint(line[2], line[3])
        let mid = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
        if MaskCanvas.distance(point, p0) <= MaskCanvas.handleRadius { return 0 }
        if MaskCanvas.distance(point, p1) <= MaskCanvas.handleRadius { return 1 }
        if MaskCanvas.distance(point, mid) <= MaskCanvas.handleRadius { return 2 }
        return 3
    }

    // MARK: Radial gradient

    private func dragRadial(_ value: DragGesture.Value, _ component: MaskComponent,
                            ended: Bool) {
        let centre = MaskCanvas.pair(component.center, fallback: [0.5, 0.5])
        let radii = MaskCanvas.pair(component.radii, fallback: [0.25, 0.25])
        let rotation = component.rotation ?? 0
        if mode == .idle {
            originCenter = centre
            originRadii = radii
            mode = .radial(handle: radialHandle(at: value.startLocation, centre: centre,
                                                radii: radii, rotation: rotation))
        }
        guard case .radial(let handle) = mode else { return }

        var nextCentre = originCenter.count == 2 ? originCenter : centre
        var nextRadii = originRadii.count == 2 ? originRadii : radii

        switch handle {
        case 0:
            let dx = Double(value.translation.width / Swift.max(imageRect.width, 1))
            let dy = Double(value.translation.height / Swift.max(imageRect.height, 1))
            nextCentre = [MaskCanvas.coord(nextCentre[0] + dx),
                          MaskCanvas.coord(nextCentre[1] + dy)]
        case 1, 2:
            let local = localVector(from: nextCentre, to: value.location, rotation: rotation)
            if handle == 1 {
                nextRadii[0] = MaskCanvas.radius(abs(local.x))
            } else {
                nextRadii[1] = MaskCanvas.radius(abs(local.y))
            }
            if isShiftDown { nextRadii = roundedRadii(nextRadii, drivenByX: handle == 1) }
        default:
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

    private func radialHandle(at point: CGPoint, centre: [Double], radii: [Double],
                              rotation: Double) -> Int {
        let c = viewPoint(centre[0], centre[1])
        let major = viewPoint(from: centre, offset: (radii[0], 0), rotation: rotation)
        let minor = viewPoint(from: centre, offset: (0, radii[1]), rotation: rotation)
        if MaskCanvas.distance(point, c) <= MaskCanvas.handleRadius { return 0 }
        if MaskCanvas.distance(point, major) <= MaskCanvas.handleRadius { return 1 }
        if MaskCanvas.distance(point, minor) <= MaskCanvas.handleRadius { return 2 }
        return 3
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
        if mode != .brush {
            mode = .brush
            livePoints = []
            strokeStarted = Date()
        }
        let n = normalized(value.location)
        let elapsed = strokeStarted.map { Date().timeIntervalSince($0) } ?? 0
        let milliseconds = Int(Num.clamp(elapsed * 1000, 0, 3_600_000))
        let point = BrushPoint(x: Double(n.x), y: Double(n.y), pressure: 1,
                               t: milliseconds)
        // Sub-pixel resampling is the rasterizer's job (arc-length Catmull-Rom); the
        // recorder only needs to drop duplicate events.
        if let last = livePoints.last {
            let dx = (last.x - point.x) * Double(imageRect.width)
            let dy = (last.y - point.y) * Double(imageRect.height)
            if (dx * dx + dy * dy) < 0.25 && !ended { return }
        }
        livePoints.append(point)

        guard ended else { return }
        defer {
            livePoints = []
            strokeStarted = nil
        }
        guard !livePoints.isEmpty else { return }
        var set = strokes
        set.strokes.append(brush.stroke(points: livePoints))
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
        handle(&context, viewPoint(centre[0], centre[1]), small: true)
        handle(&context, viewPoint(from: centre, offset: (radii[0], 0), rotation: rotation))
        handle(&context, viewPoint(from: centre, offset: (0, radii[1]), rotation: rotation))
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
        guard let hover else { return }
        let rect = CGRect(x: hover.x - diameter / 2, y: hover.y - diameter / 2,
                          width: diameter, height: diameter)
        var ring = Path()
        ring.addEllipse(in: rect)
        stroke(&context, ring, width: 1, alpha: brush.erase ? 0.5 : 0.85)
    }

    private var brushDiameter: CGFloat {
        let long = Swift.max(imageRect.width, imageRect.height)
        let d = CGFloat(Num.clamp(brush.size, 0.0005, 2)) * long
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
        let x = Double((point.x - imageRect.minX) / imageRect.width)
        let y = Double((point.y - imageRect.minY) / imageRect.height)
        return CGPoint(x: MaskCanvas.coord(x), y: MaskCanvas.coord(y))
    }

    private func viewPoint(_ nx: Double, _ ny: Double) -> CGPoint {
        CGPoint(x: imageRect.minX + CGFloat(nx) * imageRect.width,
                y: imageRect.minY + CGFloat(ny) * imageRect.height)
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

    private func coalescingKey(_ what: String) -> String {
        "mask.canvas.\(what).\(maskID).\(componentIndex)"
    }

    // MARK: Static helpers

    static let handleRadius: CGFloat = 9

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

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
        guard let values, values.count == 2,
              values.allSatisfy({ $0.isFinite }) else { return fallback }
        return values
    }

    // MARK: Committing

    /// The one place a canvas edit becomes a recipe write. Every index is
    /// bounds-checked at write time as well as at read time: the panel's selection can
    /// be one edit stale, and a stale index must be a no-op rather than a trap.
    ///
    /// The stroke payload is handed back on the edit rather than written here — blob
    /// storage is the catalog's job (`blob:xxh64:<hash>` addressing, docs/15 §15.4),
    /// and this file does no I/O.
    @MainActor
    static func apply(_ edit: MaskCanvasEdit, in state: AppState) {
        switch edit {
        case .component(let maskID, let index, let component, let key):
            state.updateRecipe(coalescingKey: key) { recipe in
                guard let m = recipe.masks.firstIndex(where: { $0.id == maskID }),
                      recipe.masks[m].components.indices.contains(index) else { return }
                recipe.masks[m].components[index] = component
            }
        case .strokes(let maskID, let index, _, let ref, _):
            guard let ref else { return }
            state.updateRecipe(coalescingKey: nil) { recipe in
                guard let m = recipe.masks.firstIndex(where: { $0.id == maskID }),
                      recipe.masks[m].components.indices.contains(index) else { return }
                recipe.masks[m].components[index].strokesRef = ref
            }
        }
    }
}

#endif
