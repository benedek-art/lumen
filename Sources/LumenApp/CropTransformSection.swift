// CropTransformSection.swift
// The Crop panel's Transform section (WS-25): Upright's modes and the manual
// perspective sliders, plus the on-canvas tool Guided draws its lines with.
//
// THE LINES ARE FOUND ONCE. Choosing Auto, Level, Vertical or Full runs the line
// detector on this photograph's decode (`RenderCoordinator.uprightSegments`) and writes
// the mode and the lines to the recipe in one step, so the picture that renders —
// preview, export, the CPU fallback — is solved from the same numbers every time
// (`UprightSolver`). Switching between those four reuses the lines already stored; Off
// keeps them, so coming back costs nothing.
//
// GUIDED is drawn, not typed: with Guided chosen, "Draw guides" arms
// `UprightGuideOverlayView` over the crop canvas, a drag lays one guide (up to four,
// Lightroom's limit), and each lands in SOURCE coordinates through the same map the
// plate under it was rendered with — so a guide drawn on an already-corrected picture
// still means the line in the photograph.

#if os(macOS)

import Foundation
import LumenCore
import SwiftUI

/// Whether a drag on the crop canvas lays a Guided Upright line. Session state, like
/// `CropTool`'s: it changes no pixel.
final class UprightGuideTool: ObservableObject {
    static let shared = UprightGuideTool()
    private init() {}

    @Published var isDrawing = false

    /// Lightroom's limit, and the most the solver uses: two verticals and two
    /// horizontals pin both vanishing points.
    static let maximumGuides = 4
}

struct CropTransformSection: View {
    @EnvironmentObject var state: AppState
    /// This surface shows the edit, so it observes the edit signal.
    @EnvironmentObject var edits: EditRevision
    @ObservedObject private var guideTool = UprightGuideTool.shared

    @State private var expanded: Bool
    @State private var analysing = false

    /// `initiallyExpanded` exists for the UI snapshot, which draws the fold open.
    init(initiallyExpanded: Bool = false) {
        _expanded = State(initialValue: initiallyExpanded)
    }

    private var binder: RecipeBinder { RecipeBinder(state: state) }
    private var upright: Upright { state.currentRecipe.develop.geometry.upright ?? Upright() }

    private let modes: [(value: Upright.Mode, label: String)] = [
        (.off, "Off"), (.auto, "Auto"), (.level, "Level"),
        (.vertical, "Vertical"), (.full, "Full"), (.guided, "Guided"),
    ]

    var body: some View {
        DevelopDisclosure("Transform", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: Lumen.rowGap) {
                LumenSegmented(options: modes, selection: modeBinding,
                               marked: upright.mode == .off ? [] : [upright.mode])
                    .disabled(analysing)
                    .help("Upright straightens the building, not just the horizon. Level "
                          + "turns the frame so the lines are level; Vertical also stands "
                          + "converging verticals up; Full corrects the horizontals too; "
                          + "Auto is Vertical with a gentler horizontal correction. Guided "
                          + "follows two to four lines you draw on the photograph.")
                if analysing {
                    Text("Finding lines…")
                        .font(.lumenCaption)
                        .foregroundStyle(Lumen.secondaryText)
                }
                if upright.mode == .guided { guidedRow }
                if upright.mode != .off {
                    slider("Amount", \.strength, range: 0...100, defaultValue: 100,
                           bipolar: false,
                           help: "How much of the automatic correction to apply. 100 is "
                               + "the whole solution; lower backs it off toward the "
                               + "photograph as shot.")
                }
                slider("Vertical", \.vertical, range: -100...100,
                       help: "Tilts the picture about its horizontal axis. Negative widens "
                           + "the top, standing up a building shot from below.")
                slider("Horizontal", \.horizontal, range: -100...100,
                       help: "Turns the picture about its vertical axis, squaring a wall "
                           + "shot from the side.")
                slider("Rotate", \.rotate, range: -10...10, step: 0.1, decimals: 1,
                       help: "Turns the corrected picture, clockwise for positive — the "
                           + "same sense as Angle above, applied before the crop.")
                slider("Aspect", \.aspect, range: -100...100,
                       help: "Stretches the corrected picture wider (positive) or taller, "
                           + "for the squash a strong correction leaves.")
                slider("Scale", \.scale, range: 50...150, defaultValue: 100, bipolar: false,
                       help: "100 fills the frame with the corrected picture. Lower shows "
                           + "the edges the correction pulled in, as transparent.")
                slider("X Offset", \.offsetX, range: -100...100,
                       help: "Slides the corrected picture sideways under the frame.")
                slider("Y Offset", \.offsetY, range: -100...100,
                       help: "Slides the corrected picture up or down under the frame.")
            }
        }
        .onChange(of: upright.mode) { _, mode in
            if mode != .guided { guideTool.isDrawing = false }
        }
    }

    // MARK: Mode

    private var modeBinding: Binding<Upright.Mode> {
        Binding(get: { upright.mode }, set: { chooseMode($0) })
    }

    private func chooseMode(_ mode: Upright.Mode) {
        guard let photo = state.primarySelection else { return }
        let needsLines = [.auto, .level, .vertical, .full].contains(mode)
            && upright.segments.isEmpty
        guard needsLines else {
            write("geometry.upright.mode", label: "Upright", targets: [photo]) { $0.mode = mode }
            if mode == .guided, upright.guides.isEmpty { guideTool.isDrawing = true }
            return
        }
        analysing = true
        let recipe = state.currentRecipe
        let url = photo.id
        let coordinator = state.renderCoordinator
        Task { @MainActor in
            let lines = await coordinator.uprightSegments(url: url, recipe: recipe) ?? []
            analysing = false
            // The lines belong to the photograph they were found on.
            guard state.primarySelection?.id == url else { return }
            write("geometry.upright.mode", label: "Upright", targets: [photo]) { u in
                u.mode = mode
                u.segments = lines
            }
            if lines.isEmpty {
                state.statusMessage = "Upright found no straight lines to work from."
            }
        }
    }

    // MARK: Guided

    private var guidedRow: some View {
        HStack(spacing: 8) {
            Text("Guides")
                .font(.lumenBody)
                .foregroundStyle(Lumen.secondaryText)
                .frame(width: Lumen.labelWidth, alignment: .leading)
            Text("\(upright.guides.count) of \(UprightGuideTool.maximumGuides)")
                .font(.lumenNumeric)
                .foregroundStyle(Lumen.secondaryText)
            Spacer(minLength: 0)
            Button(guideTool.isDrawing ? "Done" : "Draw") {
                guideTool.isDrawing.toggle()
                if guideTool.isDrawing { LoupeViewport.shared.showCrop = true }
            }
            .font(.lumenCaption)
            .disabled(!guideTool.isDrawing
                      && upright.guides.count >= UprightGuideTool.maximumGuides)
            .help("Drag along an edge in the photograph that should be vertical or "
                  + "horizontal. Two verticals stand the building up; two horizontals "
                  + "square it; one of either levels by it.")
            Button("Clear") {
                guard let photo = state.primarySelection else { return }
                write("geometry.upright.guides", label: "Clear Guides", targets: [photo]) {
                    $0.guides = []
                }
            }
            .font(.lumenCaption)
            .disabled(upright.guides.isEmpty)
        }
        .frame(height: Lumen.rowHeight)
    }

    // MARK: Rows

    private func slider(_ title: String, _ path: WritableKeyPath<Upright, Double>,
                        range: ClosedRange<Double>, defaultValue: Double = 0,
                        step: Double = 1, decimals: Int = 0, bipolar: Bool = true,
                        help: String) -> some View {
        LumenSlider(title: title,
                    value: binder.custom("geometry.upright.\(title)",
                                         get: { ($0.develop.geometry.upright ?? Upright())[keyPath: path] },
                                         set: { r, v in
                                             var u = r.develop.geometry.upright ?? Upright()
                                             u[keyPath: path] = v
                                             r.develop.geometry.upright = Self.stored(u)
                                         }),
                    range: range, hardRange: nil, defaultValue: defaultValue,
                    step: step, decimals: decimals, bipolar: bipolar, help: help)
    }

    private func write(_ key: String, label: String, targets: [PhotoItem],
                       _ mutate: @escaping (inout Upright) -> Void) {
        state.updateRecipe(coalescingKey: key, label: label, targets: targets) { _, r in
            var u = r.develop.geometry.upright ?? Upright()
            mutate(&u)
            r.develop.geometry.upright = Self.stored(u)
        }
    }

    /// A default Upright with nothing drawn is stored as no Upright, so an untouched
    /// recipe stays byte-identical to one written before this section existed.
    static func stored(_ u: Upright) -> Upright? {
        u.isIdentity && u.guides.isEmpty && u.segments.isEmpty && u.strength == 100 ? nil : u
    }
}

// MARK: - The guide tool

/// Laid over the crop canvas's PLATE — the straightened frame without its crop or its
/// angle, flip and Upright applied — while Guided is drawing. Framed and rotated
/// exactly as the plate is, so its local normalized coordinates are the plate's, and
/// `GeometryMap` with the angle and crop taken out converts them to the source.
struct UprightGuideOverlayView: View {
    let geometry: Geometry
    let sourceSize: CGSize
    let onAdd: (Upright.Segment) -> Void

    @State private var start: CGPoint?
    @State private var current: CGPoint?

    private var plateMap: GeometryMap {
        var g = geometry
        g.angle = 0
        g.crop = Crop()
        return GeometryMap(geometry: g, sourceWidth: Int(sourceSize.width.rounded()),
                           sourceHeight: Int(sourceSize.height.rounded()))
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let map = plateMap
            ZStack {
                Color.clear.contentShape(Rectangle())
                Path { path in
                    for g in geometry.upright?.guides ?? [] {
                        let a = map.displayedNormalized(sourceX: g.x0, sourceY: g.y0)
                        let b = map.displayedNormalized(sourceX: g.x1, sourceY: g.y1)
                        path.move(to: CGPoint(x: a.x * size.width, y: a.y * size.height))
                        path.addLine(to: CGPoint(x: b.x * size.width, y: b.y * size.height))
                    }
                    if let start, let current {
                        path.move(to: start)
                        path.addLine(to: current)
                    }
                }
                .stroke(Lumen.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        start = value.startLocation
                        current = value.location
                    }
                    .onEnded { value in
                        defer { start = nil; current = nil }
                        let long = Swift.max(size.width, size.height)
                        let dx = value.location.x - value.startLocation.x
                        let dy = value.location.y - value.startLocation.y
                        // A click that moved is not a line (`Straighten`'s floor).
                        guard long > 0, hypot(dx, dy) / long >= Straighten.minimumDragFraction
                        else { return }
                        func source(_ p: CGPoint) -> (x: Double, y: Double) {
                            map.sourceNormalized(displayedX: Double(p.x / size.width),
                                                 displayedY: Double(p.y / size.height))
                        }
                        let a = source(value.startLocation), b = source(value.location)
                        onAdd(Upright.Segment(x0: a.x, y0: a.y, x1: b.x, y1: b.y))
                    })
        }
        .help("Drag along a line that should be vertical or horizontal.")
    }
}

extension AppState {
    /// One Guided line, appended to the primary photograph's Upright (WS-25).
    func addUprightGuide(_ segment: Upright.Segment) {
        guard let photo = primarySelection else { return }
        updateRecipe(coalescingKey: nil, label: "Add Guide", targets: [photo]) { _, r in
            var u = r.develop.geometry.upright ?? Upright()
            guard u.guides.count < UprightGuideTool.maximumGuides else { return }
            u.mode = .guided
            u.guides.append(segment)
            r.develop.geometry.upright = u
        }
        let count = recipe(for: photo).develop.geometry.upright?.guides.count ?? 0
        if count >= UprightGuideTool.maximumGuides { UprightGuideTool.shared.isDrawing = false }
    }
}

#endif
