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
// A zone is an exposure and nothing else. `ZoneAdjust` used to carry a wheel, a
// saturation and a falloff that no stage ever read (WS-08 audit Z-7); they are gone from
// the model rather than shown here, and colour by tonal range is Colour Grading's job.
//
// The pivots are zone CENTRES, not boundaries: `ZoneWeights.weights` finds the interval
// containing x and crossfades between the two pivots bounding it with a raised cosine,
// so a zone's influence peaks exactly at its own pivot and reaches zero at its
// neighbours'. The strip draws that, which is why it is worth drawing at all. The axis is
// −9 … +5 EV whatever Whites and Blacks do (`ToneEngine.zoneAxis`), and pivots stay at
// least a stop apart (`Zones.minimumPivotGap`).
//
// Two neighbours too far apart would make a brighter tone render darker. The engine
// delivers a zone's request at its own pivot and lets untouched neighbours carry the
// excess, and only holds a request back where two touched zones conflict
// (`ToneEngine.appliedZoneEV`). Either way the row that moved says so in its own caption
// (`AppliedReadout.zoneEasing`): "+2.05 EV carried from Darks", or "Applied +0.95 of
// +3.00 EV (conflicts with Midtones)".

#if os(macOS)

import AppKit
import Foundation
import LumenCore
import SwiftUI

struct ZonesPanel: View {
    @EnvironmentObject var state: AppState
    /// This surface shows the edit, so it observes the edit signal —
    /// `AppState.recipes` is deliberately not published (see `EditRevision`).
    @EnvironmentObject var edits: EditRevision

    /// Whether the register draws its own "Zones" section header.
    ///
    /// False when the caller has already titled it. docs/28 §5.1 folds Zones into Tone as
    /// a disclosure instead of giving it a section, and BasicPanel supplies that
    /// disclosure's header — a header reading "Zones" opening onto a section reading
    /// "Zones" announces two levels where there is one. The default is what every
    /// standalone rendering keeps, unchanged.
    var showsSectionHeader: Bool = true

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

    /// THE ZONE ROWS' QUANTUM, IN STOPS — 0.05, up from 0.01.
    ///
    /// 0.01 was a number the readout advertised and no gesture could land on. The
    /// arithmetic, which is the whole argument: the register sits in a
    /// `DevelopDisclosure` inside a develop-column card, so its track is the column
    /// less 8 pt of scroll inset, 20 pt of card gutter, 16 pt of fold inset and 150 pt
    /// of row chrome (an 86 pt label, two 6 pt gaps, a 52 pt readout) — 126 pt at the
    /// 320 pt minimum column, 186 pt at the 380 pt default. Six stops at 0.01 is 600
    /// addressable values across that, which is **0.21 pt of travel per step** at the
    /// minimum and 0.31 at the default: a one-pixel tremor of the hand moves the value
    /// three to five steps, and roughly five in six of the values the two decimals
    /// promise cannot be landed on by dragging at all.
    ///
    /// At 0.05 the same track carries 120 steps — 1.05 pt/step at the minimum column and
    /// 1.55 at the default — which clears the floor `LumenControls.swift` states in its
    /// own words ("~1.0, under which a one-pixel tremor costs a whole unit") at every
    /// width the column can be dragged to. The step is coarsened rather than the panel
    /// widened because the panel's width is not this row's to spend.
    ///
    /// Two decimals STAY: 0.05 needs the hundredths place, so the readout is not
    /// promising precision the track does not have — it is spelling the quantum. The
    /// hard range still accepts a typed 1.37 for anyone who wants one.
    ///
    /// Coarser than Exposure's 0.01 EV on purpose. That is the master control a frame is
    /// set by, and the app's answer for it is the readout's own scrub; these are per-zone
    /// trims, and a twentieth of a stop is already finer than the difference two adjacent
    /// zones make at any pivot spacing the strip allows.
    private static let stopStep: Double = 0.05

    private static let register: [ZoneRow] = [
        ZoneRow(name: "Darks", path: \Zones.dark),
        ZoneRow(name: "Shadows", path: \Zones.shadow),
        ZoneRow(name: "Midtones", path: \Zones.mid),
        ZoneRow(name: "Lights", path: \Zones.light),
        ZoneRow(name: "Brights", path: \Zones.bright),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.rowGap) {
            if showsSectionHeader {
                DevelopSection("Zones", isModified: isModified, onReset: { reset() }) {
                    rows
                }
            } else {
                // The Reset affordance goes with the header, and under the accordion
                // that is not a loss: the column's Tone header resets the six sliders and
                // this register together, because folded in under Tone they are one
                // section to a photographer. `DevelopDisclosure` carries no reset of its
                // own and does not need one — a second reset button here would be a
                // second place for the same decision to be recorded differently.
                rows
            }
        }
    }

    /// The register's rows with no header of their own: exactly what the section always
    /// wrapped, and the whole of what a caller supplying its own header wants.
    private var rows: some View {
        // Astra AI-07. The register eases its own seams (`easing`, below), so on its
        // own it never reaches the bake's forward clamp. Combined with Contrast or the
        // six sliders it still can, and the clamp renders a band of input tones as ONE
        // value. The engine measures that band (`ToneEngine.zoneFlattening`), and this
        // is where the photographer hears it — marked on the strip at the tones it
        // covers, and named under it in EV. Nil whenever the clamp is idle.
        let flattened = AppliedReadout.zoneFlattening(tone: recipe.develop.tone,
                                                      zones: zones)
        // The zones the engine renders at other than their slider says — carried or
        // held back — each captioned under its own row with the amount the render uses.
        // Empty for ordinary edits.
        let easing = AppliedReadout.zoneEasing(tone: recipe.develop.tone, zones: zones)
        return VStack(alignment: .leading, spacing: Lumen.rowGap) {
            ZonePivotStrip(pivots: normalizedPivots,
                           levels: Self.register.map { zones[keyPath: $0.path].ev },
                           flattened: flattened.map { $0.lowX...$0.highX },
                           onPivotChanged: { index, position in
                               movePivot(index, to: position)
                           },
                           names: Self.register.map(\.name),
                           onPivotReset: { index in
                               // One pivot home, through the same neighbour clamp a
                               // drag uses; the five zone EVs are left alone.
                               guard let home = Self.defaultPivot(at: index) else { return }
                               movePivot(index, to: home)
                           })
            if let flattened {
                Text(flattened.caption)
                    .font(.lumenCaption)
                    .foregroundStyle(Lumen.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // No note between the strip and the rows. Its last clause — "drag a pivot
            // to say where a zone sits" — is already on the handle you would drag, and
            // the strip is a picture of the crossfade, which is a better account of
            // what a zone is than a sentence about it.
            ForEach(Self.register) { zone in
                // One help for all five rows: the mechanics are shared, the tooltip's
                // composed title names the zone, and the strip above draws where each
                // one sits.
                LumenSlider(title: zone.name,
                            value: evBinding(zone.path, key: "zones.\(zone.name)"),
                            range: -3...3, hardRange: -5...5,
                            defaultValue: 0, step: Self.stopStep, decimals: 2,
                            help: "Exposure for this zone alone, in stops. Its pull "
                                + "is strongest at the zone's own pivot and fades to "
                                + "nothing at its neighbours', so zones blend instead "
                                + "of stepping.")
                if let eased = easing.first(where: { $0.name == zone.name }) {
                    Text(eased.caption)
                        .font(.lumenCaption)
                        .foregroundStyle(Lumen.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // AND THEN IT DID NOT SURVIVE (U2). It was kept through the hairline cull
            // because it marks a change of SCOPE inside a section — five per-zone rows
            // above, one flat trim across the whole axis below — rather than fencing
            // two sections. The distinction was real and the line was still a line, and
            // it was the last one left in the owned panels while the direction says
            // there are none.
            //
            // What it was actually saying is "what follows is a different KIND of
            // thing", and space says that at least as well once nothing else in the
            // column is drawing rules: eight points where the rows run at two is a
            // clear break, and it does not put a stroke across a panel sitting inches
            // from a photograph.
            Color.clear.frame(height: 8)

            // The divider above is what said "this one is different"; the note that
            // used to say it again in words is gone, and so is its closing clause about
            // fields with a wire format and no reader — which was a line addressed to
            // whoever maintains this file, printed in a photographer's panel. It is at
            // the top of this one now.
            LumenSlider(title: "Global",
                        value: evBinding(\Zones.global, key: "zones.Global"),
                        range: -3...3, hardRange: -5...5,
                        defaultValue: 0, step: Self.stopStep, decimals: 2,
                        help: "A flat exposure trim across the whole axis, in stops — "
                            + "the same at every tone, so a finished zone set can be "
                            + "brightened or darkened as one.")
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
    /// sidecar another tool wrote, so the panel must not assume either. Touching pivots
    /// are pushed apart by `Zones.minimumPivotGap`, the gap `Zones.decodedPivots`
    /// repairs with, so this is the identity on every list the decoder hands over.
    private var normalizedPivots: [Double] {
        let stored = zones.pivots
        guard stored.count == Zones.defaultPivots.count,
              stored.allSatisfy({ $0.isFinite }) else { return Zones.defaultPivots }
        var out = stored.map { Num.saturate($0) }
        for i in 1..<out.count where out[i] <= out[i - 1] {
            out[i] = Swift.min(out[i - 1] + Zones.minimumPivotGap, 1)
        }
        return out
    }

    /// Clamped against its neighbours by `Zones.movingPivot`, a stop apart, so a drag
    /// cannot push two pivots together and collapse a zone's window. The rule lives in
    /// LumenCore so a test can reach it.
    private func movePivot(_ index: Int, to position: Double) {
        state.updateRecipe(coalescingKey: "zones.pivot.\(index)") { recipe in
            let moved = Zones.movingPivot(index, to: position,
                                          in: recipe.develop.zones.pivots)
            if moved != recipe.develop.zones.pivots {
                recipe.develop.zones.pivots = moved
            }
        }
    }

    /// Where a double-click puts pivot `index` back to, or nil for an index the
    /// register does not have.
    nonisolated static func defaultPivot(at index: Int) -> Double? {
        Zones.defaultPivots.indices.contains(index) ? Zones.defaultPivots[index] : nil
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
    /// The stretch of the axis the bake's clamp renders flat, in strip coordinates —
    /// `AppliedReadout.zoneFlattening`. Nil draws nothing.
    var flattened: ClosedRange<Double>? = nil
    let onPivotChanged: (Int, Double) -> Void
    /// The zone each pivot is the centre of, in order — what VoiceOver names a handle.
    var names: [String] = []
    /// A double-click on a handle: put that one pivot back. Nil leaves it drag-only.
    var onPivotReset: ((Int) -> Void)? = nil

    private static let height: CGFloat = 46

    /// One assistive step of a pivot: a hundredth of the axis, snapped so repeated
    /// steps land on whole percents, and kept on the axis. `movePivot` then keeps it
    /// inside its neighbours.
    nonisolated static let assistiveStep: Double = 0.01

    nonisolated static func steppedPivot(_ position: Double,
                                         _ direction: SliderAccessibility.Direction) -> Double {
        let base = position.isFinite ? position : 0
        let moved = base + (direction == .increment ? assistiveStep : -assistiveStep)
        return Num.saturate((moved / assistiveStep).rounded() * assistiveStep)
    }

    /// A pivot's position as a photographer reads it: stops from mid-grey on the
    /// register's fixed −9 … +5 EV axis, not a percentage of the strip.
    nonisolated static func pivotValue(_ position: Double) -> String {
        let span = ToneEngine.defaultWhiteAnchorEV - ToneEngine.defaultBlackAnchorEV
        let ev = ToneEngine.defaultBlackAnchorEV + Num.saturate(position) * span
        return String(format: "%+.2f EV", ev).replacingOccurrences(of: "-", with: "\u{2212}")
    }

    nonisolated static func pivotLabel(index: Int, names: [String]) -> String {
        names.indices.contains(index) ? "\(names[index]) centre" : "Zone centre \(index + 1)"
    }

    /// Where the handle was when the drag began. Dragging by TRANSLATION rather than by
    /// absolute location keeps the handle under the pointer without needing a shared
    /// coordinate space — the same reason `ZoneWeightStrip` does it this way.
    @State private var dragOrigin: Double? = nil
    /// The press was the second click of a double-click and reset the pivot; the rest
    /// of that gesture is inert, as on `LumenSlider`.
    @State private var pressWasReset = false
    /// The gesture-in-flight signal every slider fires (docs/23 audit queue item 5).
    @Environment(\.sliderGestureChanged) private var sliderGestureChanged

    var body: some View {
        let solved = pivots
        let ev = levels
        let flat = flattened

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

                // The flattened band: a faint accent wash over the tones that render
                // as one, at least two points wide so a band pinned against an end of
                // the axis is still visible.
                if let flat {
                    let lo = size.width * CGFloat(Num.saturate(flat.lowerBound))
                    let hi = size.width * CGFloat(Num.saturate(flat.upperBound))
                    let width = Swift.max(hi - lo, 2)
                    let x = Swift.min(lo, size.width - width)
                    context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)),
                                 with: .color(Lumen.accent.opacity(0.22)))
                }
            }
            .background(Lumen.controlBackground)
            .clipShape(RoundedRectangle(cornerRadius: Lumen.radiusControl, style: .continuous))

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
        // The curve's split handles are adjustable elements; these are the same kind
        // of control and were invisible to VoiceOver.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.pivotLabel(index: index, names: names)))
        .accessibilityValue(Text(Self.pivotValue(position)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: stepPivot(index, from: position, .increment)
            case .decrement: stepPivot(index, from: position, .decrement)
            @unknown default: break
            }
        }
        .position(x: x, y: height / 2)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    guard width > 0, !pressWasReset else { return }
                    // The second press of a double-click resets this pivot, read off
                    // the AppKit event for the reason `LumenSlider` gives: a tap
                    // gesture behind a minimumDistance-0 drag never fires.
                    if dragOrigin == nil, let onPivotReset,
                       (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                        pressWasReset = true
                        onPivotReset(index)
                        return
                    }
                    sliderGestureChanged(true)
                    let start = dragOrigin ?? position
                    if dragOrigin == nil { dragOrigin = start }
                    let moved = start + Double(drag.translation.width / width)
                    onPivotChanged(index, Num.saturate(moved))
                }
                .onEnded { drag in
                    if pressWasReset {
                        pressWasReset = false
                        return
                    }
                    // The release is a sample, and the last one (`LumenSlider`'s rule):
                    // under load the final motion event is coalesced away, so resolve
                    // the release location before letting go.
                    if width > 0, let start = dragOrigin {
                        let moved = start + Double(drag.translation.width / width)
                        onPivotChanged(index, Num.saturate(moved))
                    }
                    dragOrigin = nil
                    sliderGestureChanged(false)
                }
        )
        .help("Zone centre — drag to move it along the tonal axis, double-click to put it back")
    }

    /// One assistive step, bracketed like a drag.
    private func stepPivot(_ index: Int, from position: Double,
                           _ direction: SliderAccessibility.Direction) {
        let next = Self.steppedPivot(position, direction)
        guard next != position else { return }
        sliderGestureChanged(true)
        onPivotChanged(index, next)
        sliderGestureChanged(false)
    }
}

#endif
