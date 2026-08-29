// ZonesPanel.swift
// The Zones register (D7, docs/04 §Zones): five named tonal zones plus a global trim,
// each an exposure in STOPS, over draggable pivots on the normalized tonal axis.
//
// This panel did not exist. `develop.zones` reaches pixels on both render paths —
// `ToneEngine.zonePanelStops` → `stops(at:)` → `bakeGainLUT`, consumed by the reference
// at `RenderPlan.referenceColor` and by the graph through the edge-aware guided mask —
// and nothing in the app ever wrote it. The engine was complete, tested and unreachable,
// which made the one feature docs/04 calls the category-creating difference from
// Lightroom impossible to use. `pasteSettings` could copy zones between photos; nothing
// could originate a non-zero value.
//
// What this panel deliberately does NOT show: `ZoneAdjust.wheel`, `.sat` and `.falloff`.
// They are a wire format that no stage reads — `zonePanelStops` takes `.ev` and nothing
// else, and `zonePanelIsIdentity` inspects `.ev` alone, so a non-neutral zone wheel does
// not even force a re-render. Shipping them as live sliders would cost the user the time
// to find out. The note at the foot of the panel says so rather than leaving a gap.
//
// The pivots are zone CENTRES, not boundaries: `ZoneWeights.weights` finds the interval
// containing x and crossfades between the two pivots bounding it with a raised cosine,
// so a zone's influence peaks exactly at its own pivot and reaches zero at its
// neighbours'. The strip draws that, which is why it is worth drawing at all.

#if os(macOS)

import Foundation
import LumenCore
import SwiftUI

struct ZonesPanel: View {
    @EnvironmentObject var state: AppState
    /// This surface shows the edit, so it observes the edit signal —
    /// `AppState.recipes` is deliberately not published (see `EditRevision`).
    @EnvironmentObject var edits: EditRevision

    private var binder: RecipeBinder { RecipeBinder(state: state) }
    private var recipe: Recipe { state.currentRecipe }
    private var zones: Zones { recipe.develop.zones }

    /// One row of the register.
    ///
    /// A named struct rather than a tuple because `ForEach(_:id:)` needs a key path,
    /// and Swift key paths cannot refer to tuple members — `\.name` on a tuple is a
    /// compile error, not a style preference.
    private struct ZoneRow: Identifiable {
        let name: String
        let path: WritableKeyPath<Zones, ZoneAdjust>
        var id: String { name }
    }

    private static let register: [ZoneRow] = [
        ZoneRow(name: "Darks", path: \Zones.dark),
        ZoneRow(name: "Shadows", path: \Zones.shadow),
        ZoneRow(name: "Midtones", path: \Zones.mid),
        ZoneRow(name: "Lights", path: \Zones.light),
        ZoneRow(name: "Brights", path: \Zones.bright),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            DevelopSection("Zones", isModified: isModified, onReset: { reset() }) {
                VStack(alignment: .leading, spacing: 2) {
                    ZonePivotStrip(pivots: normalizedPivots,
                                   levels: Self.register.map { zones[keyPath: $0.path].ev },
                                   onPivotChanged: { index, position in
                                       movePivot(index, to: position)
                                   })

                    DevelopNote("Each zone is an exposure in stops, applied through the "
                                + "same edge-aware mask the six sliders use — so a zone "
                                + "lift follows edges instead of haloing across them. "
                                + "Drag a pivot to say where a zone sits.")

                    ForEach(Self.register) { zone in
                        LumenSlider(title: zone.name,
                                    value: evBinding(zone.path, key: "zones.\(zone.name)"),
                                    range: -3...3, hardRange: -5...5,
                                    defaultValue: 0, step: 0.01, decimals: 2)
                    }

                    // Survives the hairline cull (design audit §1.1) for the same reason
                    // the Uniformity rule in ColorPanel does: it marks a change of scope
                    // INSIDE a section — five per-zone rows above, one flat trim across
                    // the whole axis below — rather than fencing two sections, which is
                    // the job space now does.
                    Divider().overlay(Lumen.separator).padding(.vertical, 2)

                    LumenSlider(title: "Global",
                                value: evBinding(\Zones.global, key: "zones.Global"),
                                range: -3...3, hardRange: -5...5,
                                defaultValue: 0, step: 0.01, decimals: 2)

                    DevelopNote("Global is a flat trim across the whole axis — the same "
                                + "as Exposure, but recorded here so a zone set reads as "
                                + "one decision. Per-zone colour, saturation and falloff "
                                + "have a wire format and no stage reads them, so they "
                                + "are not shown.")
                }
            }
        }
    }

    // MARK: Bindings

    private func evBinding(_ path: WritableKeyPath<Zones, ZoneAdjust>,
                           key: String) -> Binding<Double> {
        binder.custom(key,
                      get: { $0.develop.zones[keyPath: path].ev },
                      set: { recipe, value in
                          recipe.develop.zones[keyPath: path].ev = value
                      })
    }

    // MARK: Pivots

    /// Pivots as the engine will read them: ascending, the right count, in range.
    ///
    /// `zonePanelStops` falls back to the defaults when the count is wrong, and
    /// `ZoneWeights.weights` requires ascending pivots — a recipe can arrive from a
    /// sidecar another tool wrote, so the panel must not assume either.
    private var normalizedPivots: [Double] {
        let stored = zones.pivots
        guard stored.count == Zones.defaultPivots.count,
              stored.allSatisfy({ $0.isFinite }) else { return Zones.defaultPivots }
        var out = stored.map { Num.saturate($0) }
        for i in 1..<out.count where out[i] <= out[i - 1] {
            out[i] = Swift.min(out[i - 1] + Self.minimumGap, 1)
        }
        return out
    }

    /// Pivots cannot cross or coincide: `weights` divides by the gap between the two
    /// bounding pivots, and a zero gap is a division by zero rather than a hard edge.
    private static let minimumGap: Double = 0.02

    private func movePivot(_ index: Int, to position: Double) {
        state.updateRecipe(coalescingKey: "zones.pivot.\(index)") { recipe in
            var pivots = recipe.develop.zones.pivots
            guard pivots.count == Zones.defaultPivots.count,
                  pivots.indices.contains(index) else {
                pivots = Zones.defaultPivots
                recipe.develop.zones.pivots = pivots
                return
            }
            // Clamped against its neighbours rather than against 0 and 1, so a drag
            // cannot push two pivots together and collapse a zone's window.
            let gap = Self.minimumGap
            let lower = index > 0 ? pivots[index - 1] + gap : 0
            let upper = index < pivots.count - 1 ? pivots[index + 1] - gap : 1
            guard upper > lower else { return }
            pivots[index] = Swift.min(Swift.max(position, lower), upper)
            recipe.develop.zones.pivots = pivots
        }
    }

    // MARK: Section state

    private var isModified: Bool {
        zones != Zones()
    }

    private func reset() {
        binder.edit("zones.reset") { $0.develop.zones = Zones() }
    }
}

// MARK: - Pivot strip

/// The five zone windows, drawn from the same `ZoneWeights` the engine evaluates, with
/// a draggable handle at each zone's centre.
///
/// Drawn from `ZoneWeights.weights` rather than from an approximation of it: the whole
/// value of a strip like this is that the picture and the maths cannot disagree, and a
/// second implementation of the crossfade is exactly how they start to.
struct ZonePivotStrip: View {
    let pivots: [Double]
    /// Each zone's current exposure, only so a lifted zone reads as lifted.
    let levels: [Double]
    let onPivotChanged: (Int, Double) -> Void

    private static let height: CGFloat = 46

    /// Where the handle was when the drag began. Dragging by TRANSLATION rather than by
    /// absolute location keeps the handle under the pointer without needing a shared
    /// coordinate space — the same reason `ZoneWeightStrip` does it this way.
    @State private var dragOrigin: Double? = nil
    /// The gesture-in-flight signal every slider fires (docs/23 audit queue item 5).
    @Environment(\.sliderGestureChanged) private var sliderGestureChanged

    var body: some View {
        let solved = pivots
        let ev = levels

        return ZStack(alignment: .topLeading) {
            Canvas { context, size in
                guard size.width > 0, size.height > 2, solved.count >= 2 else { return }
                let usable = size.height - 2
                let steps = 96

                for zone in solved.indices {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: size.height))
                    for step in 0...steps {
                        let x = Double(step) / Double(steps)
                        let w = ZoneWeights.weights(x: x, pivots: solved)
                        let v = zone < w.count ? w[zone] : 0
                        path.addLine(to: CGPoint(
                            x: size.width * CGFloat(x),
                            y: size.height - 1 - CGFloat(Num.saturate(v)) * usable))
                    }
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.closeSubpath()

                    // Dark to light left to right, so the strip reads like the tonal
                    // axis it describes; a lifted zone brightens, a pulled one dims.
                    let base = 0.26 + 0.14 * Double(zone)
                    let lift = zone < ev.count ? Num.clamp(ev[zone] / 6, -0.18, 0.18) : 0
                    context.fill(path,
                                 with: .color(Color(white: Num.saturate(base + lift))
                                     .opacity(0.5)))
                }
            }
            .background(Lumen.controlBackground)
            .clipShape(RoundedRectangle(cornerRadius: 3))

            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    ForEach(solved.indices, id: \.self) { index in
                        handle(index: index,
                               position: Num.saturate(solved[index]),
                               width: geometry.size.width,
                               height: geometry.size.height)
                    }
                }
            }
        }
        .frame(height: ZonePivotStrip.height)
        .padding(.vertical, 2)
    }

    private func handle(index: Int, position: Double,
                        width: CGFloat, height: CGFloat) -> some View {
        let x = CGFloat(position) * width
        return ZStack {
            Rectangle()
                .fill(Color.clear)
                .frame(width: 14, height: height)
            Capsule()
                .fill(Lumen.primaryText)
                .frame(width: 3, height: Swift.max(height - 4, 1))
                .shadow(radius: 1)
        }
        .contentShape(Rectangle())
        .position(x: x, y: height / 2)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    guard width > 0 else { return }
                    sliderGestureChanged(true)
                    let start = dragOrigin ?? position
                    if dragOrigin == nil { dragOrigin = start }
                    let moved = start + Double(drag.translation.width / width)
                    onPivotChanged(index, Num.saturate(moved))
                }
                .onEnded { _ in
                    dragOrigin = nil
                    sliderGestureChanged(false)
                }
        )
        .help("Zone centre — drag to move where this zone sits on the tonal axis")
    }
}

#endif
