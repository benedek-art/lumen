// HealCanvas.swift
// The Heal tool (docs/09 §Heal / Clone, docs/12 §12.3 `Q`): circular spots placed on
// the photograph, the first slice of retouching.
//
//   Q              arms the tool on the loupe; Q again or Esc puts it away
//   click          a new spot at the pointer — Heal or Clone, at the bar's size,
//                  feather and opacity — with its source chosen by `SpotSourceSearch`
//   drag a circle  the solid one moves the spot, the dashed one moves its source
//   ⌫              deletes the selected spot
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
}

// MARK: - Verbs

extension AppState {

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

        let url = photo.id
        let current = recipe(for: photo)
        Task {
            let found = await renderCoordinator.healAutoSource(url: url, recipe: current,
                                                               spot: placed,
                                                               priorSpots: prior)
            guard let found, primarySelection?.id == url else { return }
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

    /// `⌫` while healing.
    func deleteSelectedSpot() {
        let tool = HealTool.shared
        guard let id = tool.selectedSpotID, let photo = primarySelection else { return }
        updateRecipe(label: "Delete Spot", targets: [photo]) { _, recipe in
            recipe.develop.heal.spots.removeAll { $0.id == id }
        }
        tool.selectedSpotID = nil
    }
}

// MARK: - Canvas

struct HealCanvas: View {
    let imageRect: CGRect
    let sourceSize: CGSize
    let geometry: Geometry
    let spots: [HealSpot]
    let selectedID: String?
    let add: (Double, Double) -> Void
    let select: (String?) -> Void
    /// The spot as the drag has it now; `finished` on the last event.
    let drag: (HealSpot, Bool) -> Void

    @Environment(\.sliderGestureChanged) private var sliderGestureChanged

    private struct Grab {
        let part: SpotHandles.Part
        let origin: HealSpot
        let start: CGPoint
    }

    @State private var grab: Grab?
    @State private var pressed: Bool = false

    /// The grab tolerance in view points — `MaskHandles`' size, so every handle on the
    /// photograph is the same target.
    static let grabPoints: CGFloat = 11

    var body: some View {
        Canvas { context, _ in
            for spot in spots {
                draw(&context, spot, selected: spot.id == selectedID)
            }
        }
        .contentShape(Rectangle())
        .gesture(press)
        .lumenPickCursor(true)
        .help("Click a blemish to heal it. Drag the solid circle to move the spot, the "
              + "dashed one to choose where it borrows from. ⌫ deletes the selected "
              + "spot; Q or Esc puts the tool away.")
    }

    private var press: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
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
                        sliderGestureChanged(true)
                    } else {
                        grab = nil
                    }
                }
                guard let grab else { return }
                let now = normalized(value.location)
                drag(SpotHandles.dragged(grab.origin, part: grab.part,
                                         dx: Double(now.x - grab.start.x),
                                         dy: Double(now.y - grab.start.y)), false)
            }
            .onEnded { value in
                defer {
                    grab = nil
                    pressed = false
                }
                if let grab {
                    let now = normalized(value.location)
                    drag(SpotHandles.dragged(grab.origin, part: grab.part,
                                             dx: Double(now.x - grab.start.x),
                                             dy: Double(now.y - grab.start.y)), true)
                    sliderGestureChanged(false)
                    return
                }
                // A click on clear space places a spot; a drag across it does nothing,
                // so a photographer reaching to pan does not litter the frame.
                let travel = hypot(value.location.x - value.startLocation.x,
                                   value.location.y - value.startLocation.y)
                guard travel < 4 else { return }
                let n = normalized(value.startLocation)
                guard n.x >= 0, n.x <= 1, n.y >= 0, n.y <= 1 else { return }
                add(Double(n.x), Double(n.y))
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
                Text(selected == nil ? "Heal — new spots" : "Heal — selected spot")
                    .font(.lumenCaptionStrong)
                Spacer(minLength: 0)
                if selected != nil {
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
