// ColorPanel.swift
// The Colour panel: the 8-band Mixer, Point Colour and the Black & White treatment.
//
// Three things this panel exists to get right:
//   · The band strip DRAWS ColorEngine's own weights rather than a redrawn
//     approximation, so "what does this band actually touch" is answerable by looking.
//     The bands are a smooth partition of unity — there are no wedge edges to see.
//   · Luminance is chroma-preserving (D13). Darkening a blue sky must not desaturate
//     it, and the caption says so next to the slider rather than in a manual.
//   · A caption says what the control does, not what it was going to do. Uniformity sat
//     under the band selector captioned "converges THIS BAND's hues" and is one global
//     value the engine applies to all eight — so selecting Blue and dragging it also
//     pulled skin toward Orange, and the panel said otherwise. Making it per-band is a
//     wire-format change (`Mixer.uniformity` would become eight fields, and every
//     sidecar and the canonical fixture would move with it). The convergence target is
//     docs/05's now: `measuredBandMeanHues` reaches every rendering plan through
//     `RenderPlan(bandMeanHues:)`, so Uniformity converges on the image's own measured
//     hues, falling back to the core-arc midpoint only when the frame measures as
//     grey. The caption is what was false, so the caption is what changed.
//   · Switching to B&W and back loses nothing, and "nothing" now means per photo and
//     across a quit. The Mixer lives in `develop.mixer` and the B&W mix in `look.bw`;
//     the treatment toggle never writes across that line, and it writes `bw.enabled`
//     rather than deleting the slot, so the mix belongs to the photograph. The rule
//     itself is `BlackAndWhite.toggled` in LumenCore, where a test can reach it — this
//     panel used to hold the mix in view state, which leaked it between photos.
//
// Every slider is a LumenSlider: the slider contract (D45) has exactly one
// implementation, and a panel that hand-rolls one is a bug the user feels first.

#if os(macOS)

import AppKit
import Foundation
import LumenCore
import SwiftUI

struct ColorPanel: View {
    @EnvironmentObject var state: AppState

    @State private var selectedBand: Int = 0
    @State private var allBands: Bool = false
    @State private var selectedSwatch: Int = 0
    @State private var mixerExpanded: Bool = true
    @State private var pointExpanded: Bool = true
    @State private var bwExpanded: Bool = true

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                mixerSection
                Divider()
                pointColorSection
                Divider()
                blackAndWhiteSection
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 18)
        }
        .background(Lumen.panelBackground)
    }

    // MARK: - Mixer

    private var mixerSection: some View {
        let mixer = state.currentRecipe.develop.mixer
        let bands = ColorPanel.normalizedBands(mixer.bands)
        // The engine's own resolved geometry, not the raw wire values: the ring must
        // draw the arc the pixel loop uses, including the min-reach clamp, or a handle
        // dragged past the limit would sit somewhere the render disagrees with.
        let arcs = ColorEngine.bandArcs(bands)
        let touched = bands.contains(where: { $0.hue != 0 || $0.sat != 0 || $0.lum != 0 })
        let reshaped = arcs != ColorEngine.canonicalArcs
        let modified = touched || mixer.uniformity != 0 || reshaped
        let index = min(max(selectedBand, 0), ColorEngine.bandCount - 1)

        return VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Colour Mixer",
                               isExpanded: $mixerExpanded,
                               isModified: modified,
                               onReset: { state.updateRecipe { $0.develop.mixer = Mixer() } })

            if mixerExpanded {
                LumenSegmented(options: [(value: false, label: "Band"),
                                         (value: true, label: "All bands")],
                               selection: $allBands)
                    .padding(.vertical, 2)

                bandSwatches(bands)

                bandReach(arcs, index)

                LumenSlider(title: "Hue", value: mixerBinding(.hue),
                            range: -100...100, defaultValue: 0, step: 1, decimals: 0)
                LumenSlider(title: "Saturation", value: mixerBinding(.sat),
                            range: -100...100, defaultValue: 0, step: 1, decimals: 0)
                LumenSlider(title: "Luminance", value: mixerBinding(.lum),
                            range: -100...100, defaultValue: 0, step: 1, decimals: 0)

                caption("Luminance holds chroma: a darkened sky stays as blue as it was.")

                // Not inside the band block above, and titled for what it is. There is
                // one `Mixer.uniformity` on the wire and the engine applies it to all
                // eight bands, each converging on its own core arc — so selecting Blue
                // and dragging this also pulls skin toward Orange.
                Divider()
                    .padding(.vertical, 2)

                LumenSlider(title: "Uniformity (all bands)",
                            value: bind("mixer.uniformity",
                                        get: { $0.develop.mixer.uniformity },
                                        set: { $0.develop.mixer.uniformity = $1 }),
                            range: 0...100, defaultValue: 0, step: 1, decimals: 0,
                            bipolar: false)

                caption("Uniformity converges EVERY band's hues toward that band's "
                        + "measured mean hue in this photo — not just the selected "
                        + "band. A frame too grey to measure falls back to the middle "
                        + "of each band's core arc, so the inner handles still steer "
                        + "it. Texture-preserving convergence needs a spatial pass the "
                        + "shipping graph does not run yet; today it moves the whole "
                        + "pixel.")
            }
        }
    }

    // MARK: - Ring handles (D13: visible, draggable range + feather)

    /// Write one dragged handle back into the band's wire geometry.
    ///
    /// Everything is stored relative to the band's canonical centre, and the centre
    /// itself never moves — it is the wire format's identity for the band. Dragging the
    /// two inner handles to the same side is how you re-centre the band on a colour, and
    /// `ColorEngine.BandArc.coreCentre` is what reads that back out for Uniformity.
    private func moveHandle(_ band: Int, _ handle: MixerArcHandle, to degrees: Double) {
        state.updateRecipe(coalescingKey: "mixer.arc.\(band).\(handle.rawValue)") { recipe in
            var bands = ColorPanel.normalizedBands(recipe.develop.mixer.bands)
            guard bands.indices.contains(band),
                  ColorEngine.bandHueCentres.indices.contains(band) else { return }
            let centre = ColorEngine.bandHueCentres[band]
            let delta = Num.hueDelta(centre, degrees)     // signed, (−180, 180]
            var core = ColorPanel.pair(bands[band].core, MixerBand.defaultCore)
            var feather = ColorPanel.pair(bands[band].feather, MixerBand.defaultFeather)
            let coreLo = ColorEngine.bandCoreMinDegrees
            let coreHi = ColorEngine.bandCoreMaxDegrees
            let featherLo = ColorEngine.bandFeatherMinDegrees
            let featherHi = ColorEngine.bandFeatherMaxDegrees
            switch handle {
            case .coreStart:
                core[0] = Num.clamp(-delta, coreLo, coreHi)
            case .coreEnd:
                core[1] = Num.clamp(delta, coreLo, coreHi)
            case .featherStart:
                feather[0] = Num.clamp(-delta - core[0], featherLo, featherHi)
            case .featherEnd:
                feather[1] = Num.clamp(delta - core[1], featherLo, featherHi)
            }
            bands[band].core = core
            bands[band].feather = feather
            recipe.develop.mixer.bands = bands
        }
    }

    /// Back to the canonical wedge, leaving the band's three sliders alone.
    private func resetArc(_ band: Int) {
        state.updateRecipe { recipe in
            var bands = ColorPanel.normalizedBands(recipe.develop.mixer.bands)
            guard bands.indices.contains(band) else { return }
            bands[band].core = MixerBand.defaultCore
            bands[band].feather = MixerBand.defaultFeather
            recipe.develop.mixer.bands = bands
        }
    }

    /// Ring, ribbon and the sentence under them — the three views that answer "what does
    /// this band reach", grouped so `mixerSection`'s builder stays inside its ten-child
    /// limit and so the three can never be shown without each other.
    private func bandReach(_ arcs: [ColorEngine.BandArc], _ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            MixerHueRing(arcs: arcs,
                         selected: index,
                         allBands: allBands,
                         onHandleMoved: { handle, degrees in
                             moveHandle(index, handle, to: degrees)
                         },
                         onResetArc: { resetArc(index) })

            MixerBandRibbon(weights: ColorPanel.ribbonWeights(arcs),
                            colors: ColorPanel.bandSwatchColors,
                            selected: index,
                            allBands: allBands)

            Text(allBands
                 ? "All bands move together; the spread between them is preserved."
                 : "\(ColorPanel.bandName(index)) — centred on "
                   + String(format: "%.1f°", ColorPanel.bandCentre(index))
                   + " in OKLCh, " + ColorPanel.arcSummary(arcs, index))
                .font(.system(size: 10))
                .foregroundStyle(Lumen.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 2)
        }
    }

    private func bandSwatches(_ bands: [MixerBand]) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(0..<ColorEngine.bandCount), id: \.self) { index in
                let isSelected = !allBands && index == selectedBand
                let touched = index < bands.count
                    && (bands[index].hue != 0 || bands[index].sat != 0 || bands[index].lum != 0)
                Button {
                    allBands = false
                    selectedBand = index
                } label: {
                    ZStack(alignment: .topTrailing) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(ColorPanel.swatch(index))
                            .frame(height: 16)
                            .opacity(allBands ? 0.55 : 1)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(isSelected ? Lumen.primaryText : Lumen.separator,
                                                  lineWidth: isSelected ? 1.5 : 0.5)
                            )
                        if touched {
                            Circle()
                                .fill(Lumen.primaryText)
                                .frame(width: 3, height: 3)
                                .padding(2)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(ColorPanel.bandName(index))
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Point colour

    private var pointColorSection: some View {
        let swatches = state.currentRecipe.develop.pointColors
        let index: Int? = swatches.isEmpty
            ? nil : min(max(selectedSwatch, 0), swatches.count - 1)

        return VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Point Colour",
                               isExpanded: $pointExpanded,
                               isModified: !swatches.isEmpty,
                               onReset: { state.updateRecipe { $0.develop.pointColors = [] } })

            if pointExpanded {
                HStack(spacing: 4) {
                    ForEach(Array(swatches.indices), id: \.self) { i in
                        Button {
                            selectedSwatch = i
                        } label: {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(ColorPanel.chipColor(swatches[i]))
                                .frame(width: 22, height: 16)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3)
                                        .strokeBorder(i == index ? Lumen.primaryText : Lumen.separator,
                                                      lineWidth: i == index ? 1.5 : 0.5)
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Swatch \(i + 1)")
                    }
                    Spacer(minLength: 0)
                    Button(action: addSwatch) {
                        Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(swatches.count < ColorPanel.maxSwatches
                                     ? Lumen.primaryText : Lumen.secondaryText)
                    .disabled(swatches.count >= ColorPanel.maxSwatches)
                    .help("Add a swatch (up to \(ColorPanel.maxSwatches))")

                    Button(action: removeSwatch) {
                        Image(systemName: "minus").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(index == nil ? Lumen.secondaryText : Lumen.primaryText)
                    .disabled(index == nil)
                    .help("Remove the selected swatch")
                }
                .frame(height: Lumen.rowHeight)

                if let index {
                    LumenSlider(title: "Hue", value: pointBinding(index, .hue),
                                range: -60...60, defaultValue: 0, step: 1, decimals: 0)
                    LumenSlider(title: "Saturation", value: pointBinding(index, .sat),
                                range: -100...100, defaultValue: 0, step: 1, decimals: 0)
                    LumenSlider(title: "Luminance", value: pointBinding(index, .lum),
                                range: -100...100, defaultValue: 0, step: 1, decimals: 0)
                    LumenSlider(title: "Range", value: pointBinding(index, .range),
                                range: 0...100, defaultValue: 50, step: 1, decimals: 0,
                                bipolar: false)
                    LumenSlider(title: "Variance", value: pointBinding(index, .variance),
                                range: -100...100, defaultValue: 0, step: 1, decimals: 0)
                    caption("Range is how much of the picture this swatch claims. "
                            + "Variance compresses (−) or expands (+) what is inside it.")
                } else {
                    caption("No swatches yet. Add one to shift a single colour without "
                            + "touching its neighbours on the hue circle.")
                }
            }
        }
    }

    /// Arms a pick rather than appending a grey swatch and hoping.
    ///
    /// Every swatch used to be born `[0.18, 0.18, 0.18]`, and with a neutral target the
    /// chordal hue term is identically zero — so the control was not merely
    /// unconfigured, it was a "low-chroma mid-tones" selector wearing five sliders. The
    /// swatch now comes into existence carrying a colour, so there is no state in which
    /// it looks live and selects nothing.
    private func addSwatch() {
        guard state.currentRecipe.develop.pointColors.count < ColorPanel.maxSwatches
        else { return }
        state.beginPick(.newPointColor)
    }

    private func removeSwatch() {
        let target = selectedSwatch
        state.updateRecipe { recipe in
            guard recipe.develop.pointColors.indices.contains(target) else { return }
            recipe.develop.pointColors.remove(at: target)
        }
        let count = state.currentRecipe.develop.pointColors.count
        selectedSwatch = max(0, min(target, count - 1))
    }

    // MARK: - Black & white

    private var blackAndWhiteSection: some View {
        let bw = state.currentRecipe.look.bw
        let bands = ColorPanel.normalizedDoubles(bw?.bands)
        let isOn = state.currentRecipe.look.blackAndWhiteIsOn
        let hasStoredMix = bw != nil && bands.contains(where: { $0 != 0 })

        return VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Black & White",
                               isExpanded: $bwExpanded,
                               isModified: bw != nil,
                               onReset: { state.updateRecipe { $0.look.bw = nil } })

            if bwExpanded {
                LumenToggleRow(title: "Black & white treatment",
                               isOn: Binding(get: { isOn }, set: { setTreatment($0) }),
                               help: "Toggling the treatment keeps both sets of settings "
                                   + "with this photo — the mix is stored in its recipe "
                                   + "and the colour mixer is not touched. Reset above "
                                   + "is what discards the mix.")

                if isOn {
                    ForEach(Array(0..<ColorEngine.bandCount), id: \.self) { i in
                        LumenSlider(title: ColorPanel.bandName(i),
                                    value: bwBinding(i),
                                    range: -100...100, defaultValue: 0, step: 1, decimals: 0)
                    }
                    caption("Same eight bands as the mixer, same smooth weighting — an "
                            + "aggressive mix darkens cleanly instead of banding. Toning "
                            + "is the grading wheels in the Look panel, not a second tool.")
                } else if hasStoredMix {
                    caption("The mix is kept with this photo. Turn the treatment back on "
                            + "and it returns exactly as it was, today or next month.")
                } else {
                    caption("Off. The colour mixer above keeps its own state either way.")
                }
            }
        }
    }

    /// One boolean per photo, and every photo answers with its own mix.
    ///
    /// `updateRecipe` runs this closure once per edit target, so a multi-selection
    /// toggle now gives each frame back what it had. The version this replaced restored
    /// from a stash held on the view, which named no photo: toggling off on one frame
    /// and on again on another wrote the first frame's mix into the second's recipe and
    /// into every frame selected with it.
    private func setTreatment(_ on: Bool) {
        state.updateRecipe { recipe in
            recipe.look.bw = BlackAndWhite.toggled(recipe.look.bw, on: on)
        }
    }

    // MARK: - Bindings

    private enum MixerComponent: String {
        case hue, sat, lum

        func value(_ band: MixerBand) -> Double {
            switch self {
            case .hue: return band.hue
            case .sat: return band.sat
            case .lum: return band.lum
            }
        }

        func write(_ band: inout MixerBand, _ v: Double) {
            switch self {
            case .hue: band.hue = v
            case .sat: band.sat = v
            case .lum: band.lum = v
            }
        }
    }

    /// One slider, two modes. In "all bands" the slider reads the mean and writes the
    /// difference, so a global move keeps whatever spread the user built by hand.
    private func mixerBinding(_ component: MixerComponent) -> Binding<Double> {
        Binding(
            get: {
                let bands = ColorPanel.normalizedBands(state.currentRecipe.develop.mixer.bands)
                if allBands {
                    let total = bands.reduce(0.0) { $0 + component.value($1) }
                    return total / Double(bands.count)
                }
                let i = min(max(selectedBand, 0), bands.count - 1)
                return component.value(bands[i])
            },
            set: { newValue in
                let key = "mixer.\(component.rawValue).\(allBands ? -1 : selectedBand)"
                let everything = allBands
                let index = selectedBand
                state.updateRecipe(coalescingKey: key) { recipe in
                    var bands = ColorPanel.normalizedBands(recipe.develop.mixer.bands)
                    if everything {
                        let sum = bands.reduce(0.0) { $0 + component.value($1) }
                        let mean = sum / Double(bands.count)
                        let delta = newValue - mean
                        for i in bands.indices {
                            let moved = component.value(bands[i]) + delta
                            component.write(&bands[i], Num.clamp(moved, -100, 100))
                        }
                    } else {
                        let i = min(max(index, 0), bands.count - 1)
                        component.write(&bands[i], Num.clamp(newValue, -100, 100))
                    }
                    recipe.develop.mixer.bands = bands
                }
            })
    }

    private enum PointComponent: String {
        case hue, sat, lum, range, variance

        func value(_ p: PointColor) -> Double {
            switch self {
            case .hue: return p.shift.h
            case .sat: return p.shift.s
            case .lum: return p.shift.l
            case .range: return p.range
            case .variance: return p.variance
            }
        }

        func write(_ p: inout PointColor, _ v: Double) {
            switch self {
            case .hue: p.shift.h = Num.clamp(v, -60, 60)
            case .sat: p.shift.s = Num.clamp(v, -100, 100)
            case .lum: p.shift.l = Num.clamp(v, -100, 100)
            case .range: p.range = Num.clamp(v, 0, 100)
            case .variance: p.variance = Num.clamp(v, -100, 100)
            }
        }
    }

    private func pointBinding(_ index: Int, _ component: PointComponent) -> Binding<Double> {
        Binding(
            get: {
                let list = state.currentRecipe.develop.pointColors
                guard list.indices.contains(index) else { return 0 }
                return component.value(list[index])
            },
            set: { newValue in
                state.updateRecipe(coalescingKey: "point.\(index).\(component.rawValue)") { recipe in
                    guard recipe.develop.pointColors.indices.contains(index) else { return }
                    component.write(&recipe.develop.pointColors[index], newValue)
                }
            })
    }

    private func bwBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: {
                let bands = ColorPanel.normalizedDoubles(state.currentRecipe.look.bw?.bands)
                guard bands.indices.contains(index) else { return 0 }
                return bands[index]
            },
            set: { newValue in
                state.updateRecipe(coalescingKey: "bw.\(index)") { recipe in
                    var bands = ColorPanel.normalizedDoubles(recipe.look.bw?.bands)
                    guard bands.indices.contains(index) else { return }
                    bands[index] = Num.clamp(newValue, -100, 100)
                    // The slider is only reachable while the treatment is on, but the
                    // flag is carried rather than reasserted: a write that assumes a
                    // state instead of preserving it is how the old stash worked.
                    recipe.look.bw = BlackAndWhite(bands: bands,
                                                   enabled: recipe.look.bw?.enabled ?? true)
                }
            })
    }

    private func bind(_ key: String,
                      get: @escaping (Recipe) -> Double,
                      set: @escaping (inout Recipe, Double) -> Void) -> Binding<Double> {
        Binding(
            get: { get(state.currentRecipe) },
            set: { v in state.updateRecipe(coalescingKey: key) { set(&$0, v) } })
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(Lumen.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 4)
    }

    // MARK: - Static helpers

    static let maxSwatches: Int = 8

    /// The recipe guarantees eight bands; a decoded file does not. Every read and every
    /// write goes through here, so an eight-slider panel can never index past the end.
    static func normalizedBands(_ bands: [MixerBand]) -> [MixerBand] {
        var out = bands.count > ColorEngine.bandCount
            ? Array(bands.prefix(ColorEngine.bandCount)) : bands
        while out.count < ColorEngine.bandCount { out.append(MixerBand()) }
        return out
    }

    static func normalizedDoubles(_ values: [Double]?) -> [Double] {
        var out = values ?? []
        if out.count > ColorEngine.bandCount { out = Array(out.prefix(ColorEngine.bandCount)) }
        while out.count < ColorEngine.bandCount { out.append(0) }
        return out
    }

    static func bandName(_ index: Int) -> String {
        let names = ColorEngine.bandNames
        guard names.indices.contains(index) else { return "Band \(index + 1)" }
        return names[index]
    }

    static func bandCentre(_ index: Int) -> Double {
        let centres = ColorEngine.bandHueCentres
        guard centres.indices.contains(index) else { return 0 }
        return centres[index]
    }

    static func swatch(_ index: Int) -> Color {
        guard bandSwatchColors.indices.contains(index) else { return Lumen.controlBackground }
        return bandSwatchColors[index]
    }

    /// Reference colours, not the OKLCh centres: the swatch labelled Orange has to look
    /// orange (docs/06 brief §1.1). The centres are what the ribbon plots.
    static let bandSwatchColors: [Color] = [
        Color(red: 0.84, green: 0.24, blue: 0.22),
        Color(red: 0.86, green: 0.51, blue: 0.18),
        Color(red: 0.84, green: 0.77, blue: 0.24),
        Color(red: 0.34, green: 0.69, blue: 0.34),
        Color(red: 0.26, green: 0.71, blue: 0.71),
        Color(red: 0.28, green: 0.46, blue: 0.84),
        Color(red: 0.55, green: 0.35, blue: 0.82),
        Color(red: 0.82, green: 0.30, blue: 0.66),
    ]

    static let ribbonSteps: Int = 96

    /// The engine's own membership vectors. The strip is a drawing of the weights the
    /// pixel loop uses — not a picture of what they ought to look like.
    ///
    /// A function of the live arcs, not a cached constant. It was a `static let`
    /// computed once from the canonical geometry, which was correct exactly as long as
    /// the geometry could not be edited; the moment the ring's handles landed, a cached
    /// ribbon would have drawn a band's reach that the render no longer agreed with —
    /// the specific failure this panel's header says it exists to avoid.
    static func ribbonWeights(_ arcs: [ColorEngine.BandArc]) -> [[Double]] {
        var out: [[Double]] = []
        out.reserveCapacity(ColorPanel.ribbonSteps + 1)
        for step in 0...ColorPanel.ribbonSteps {
            let hue = Double(step) / Double(ColorPanel.ribbonSteps) * 360
            out.append(ColorEngine.bandWeights(hue: hue, arcs: arcs))
        }
        return out
    }

    /// Two finite values from a wire array that a decoded file could have made anything.
    static func pair(_ values: [Double], _ fallback: [Double]) -> [Double] {
        var out = fallback
        for i in 0..<2 where i < values.count && values[i].isFinite { out[i] = values[i] }
        return out
    }

    /// The sentence under the ring, in the units the handles are dragged in.
    static func arcSummary(_ arcs: [ColorEngine.BandArc], _ index: Int) -> String {
        guard arcs.indices.contains(index) else { return "feathered into its neighbours." }
        let a = arcs[index]
        return String(format: "core −%.0f°/+%.0f°, feather %.0f°/%.0f°.",
                      a.coreBelow, a.coreAbove, a.featherBelow, a.featherAbove)
    }

    /// A hue's actual colour, for the ring — evaluated through OKLCh and the working
    /// space rather than through SwiftUI's HSB, whose hue angle is a different number
    /// entirely. A ring that put "29°" somewhere other than where the engine's red band
    /// sits would be a diagram of a different tool.
    static func hueColor(_ degrees: Double, L: Double = 0.72, C: Double = 0.13) -> Color {
        let working = OKLabTransform.working.toRGB(OKLCh(L: L, C: C, h: degrees))
        let display = ColorPanel.workingToSRGB.apply(working)
        let encoded = TransferFunction.srgb.encode(RGB(Num.saturate(display.r),
                                                       Num.saturate(display.g),
                                                       Num.saturate(display.b)))
        return Color(red: Num.saturate(encoded.r),
                     green: Num.saturate(encoded.g),
                     blue: Num.saturate(encoded.b))
    }

    static let workingToSRGB: Mat3 = ColorEngine.workingSpace.matrix(to: .srgb)

    /// The ring's wedge colours, computed once.
    ///
    /// A hundred and eighty OKLab round trips per redraw is real work to repeat on every
    /// frame of a slider drag, and the hue circle is a constant — the same reason
    /// `ribbonWeights` used to be cached before the handles made it a function of the
    /// recipe. This one genuinely is not.
    static let ringColors: [Color] = (0..<MixerHueRing.steps).map { step in
        let a0 = Double(step) / Double(MixerHueRing.steps) * 360
        let a1 = Double(step + 1) / Double(MixerHueRing.steps) * 360
        return ColorPanel.hueColor((a0 + a1) / 2)
    }

    /// A chip for a sampled swatch. The sample is scene-linear working RGB, so it gets
    /// a rough encode before it is shown — otherwise every swatch reads as too dark.
    static func chipColor(_ point: PointColor) -> Color {
        guard point.sample.count >= 3 else { return Lumen.controlBackground }
        let r = Num.saturate(pow(Num.saturate(point.sample[0]), 1.0 / 2.2))
        let g = Num.saturate(pow(Num.saturate(point.sample[1]), 1.0 / 2.2))
        let b = Num.saturate(pow(Num.saturate(point.sample[2]), 1.0 / 2.2))
        return Color(red: r, green: g, blue: b)
    }
}

// MARK: - Hue ring

/// Which of the four handles on the selected band's arc is being dragged.
enum MixerArcHandle: String, Hashable, Sendable {
    case featherStart, coreStart, coreEnd, featherEnd
}

/// The hue ring, with the selected band's core arc and its four draggable handles.
///
/// This is the control docs/05 buys the whole Mixer entry with: Lightroom's band extents
/// are invisible AND fixed, Capture One exposes one global Smoothness, and DxO's
/// ColorWheel — the interaction grammar adopted here on purpose — is the only shipping
/// tool that lets you see and move them. Two inner handles bound the core, two outer
/// ones set the per-side falloff, and the arc drawn is the one `ColorEngine.bandArcs`
/// resolved, clamps included.
struct MixerHueRing: View {
    let arcs: [ColorEngine.BandArc]
    let selected: Int
    let allBands: Bool
    let onHandleMoved: (MixerArcHandle, Double) -> Void
    let onResetArc: () -> Void

    static let diameter: CGFloat = 118
    static let ringWidth: CGFloat = 13
    /// Steps around the ring. 180 is 2° per wedge — below the width of the thinnest
    /// feather anyone can drag, so the colour never reads as stepped.
    static let steps: Int = 180

    /// Which handle the drag grabbed. Decided once, on the first event: re-deciding on
    /// every event let a fast drag hand the pointer to a neighbouring handle halfway
    /// through, which reads as the arc snapping inside out.
    @State private var grabbed: MixerArcHandle? = nil
    /// The press turned out to be a double-click reset; swallow the rest of the
    /// gesture so the reset is not immediately re-edited by the same press.
    @State private var pressWasReset = false
    /// The gesture-in-flight signal every slider fires (docs/23 audit queue item 5).
    @Environment(\.sliderGestureChanged) private var sliderGestureChanged

    var body: some View {
        let arcList = arcs
        let index = selected
        let showHandles = !allBands && arcList.indices.contains(index)
        let palette = ColorPanel.ringColors

        return ZStack {
            Canvas { context, size in
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                // The arc and its handles live OUTSIDE the colour wheel, in the margin
                // the frame reserves for them — drawn at the wheel's own radius they
                // were clipped by the view bounds and the two upper handles vanished.
                let bound = Swift.min(size.width, size.height) / 2
                let arcRadius = bound - 5
                let outer = arcRadius - 6
                let inner = outer - MixerHueRing.ringWidth
                guard inner > 2 else { return }

                // The hue wheel itself, wedge by wedge, in real OKLCh hues.
                for step in palette.indices {
                    let a0 = Double(step) / Double(MixerHueRing.steps) * 360
                    let a1 = Double(step + 1) / Double(MixerHueRing.steps) * 360
                    var wedge = Path()
                    wedge.move(to: MixerHueRing.point(centre, inner, a0))
                    wedge.addLine(to: MixerHueRing.point(centre, outer, a0))
                    wedge.addLine(to: MixerHueRing.point(centre, outer, a1))
                    wedge.addLine(to: MixerHueRing.point(centre, inner, a1))
                    wedge.closeSubpath()
                    context.fill(wedge, with: .color(palette[step]))
                }

                // Every band's centre, as a tick: the eight fixed hues the wire format
                // is denominated in, so a re-centred core is visibly off its own tick.
                for arc in arcList {
                    var tick = Path()
                    tick.move(to: MixerHueRing.point(centre, inner - 3, arc.centre))
                    tick.addLine(to: MixerHueRing.point(centre, inner, arc.centre))
                    context.stroke(tick, with: .color(Lumen.separator), lineWidth: 1)
                }

                guard showHandles, arcList.indices.contains(index) else { return }
                let arc = arcList[index]

                // Core and feather at ONE radius, so they read as a single arc with a
                // bright middle and two dim tails: the core is what the band fully
                // claims and the feather is how it lets go, and the picture should say
                // that they are the same reach measured in two parts.
                context.stroke(MixerHueRing.arcPath(centre, arcRadius,
                                                    from: arc.centre - arc.coreBelow - arc.featherBelow,
                                                    to: arc.centre - arc.coreBelow),
                               with: .color(Lumen.primaryText.opacity(0.30)), lineWidth: 2)
                context.stroke(MixerHueRing.arcPath(centre, arcRadius,
                                                    from: arc.centre + arc.coreAbove,
                                                    to: arc.centre + arc.coreAbove + arc.featherAbove),
                               with: .color(Lumen.primaryText.opacity(0.30)), lineWidth: 2)
                context.stroke(MixerHueRing.arcPath(centre, arcRadius,
                                                    from: arc.centre - arc.coreBelow,
                                                    to: arc.centre + arc.coreAbove),
                               with: .color(Lumen.primaryText), lineWidth: 2.5)

                // Where Uniformity converges: the midpoint of the core arc, which sits
                // off the band's tick as soon as the two inner handles stop matching.
                var target = Path()
                target.move(to: MixerHueRing.point(centre, arcRadius - 4, arc.coreCentre))
                target.addLine(to: MixerHueRing.point(centre, arcRadius + 4, arc.coreCentre))
                context.stroke(target, with: .color(Lumen.accent), lineWidth: 1.5)

                for handle in MixerHueRing.allHandles {
                    let isCore = handle == .coreStart || handle == .coreEnd
                    let p = MixerHueRing.point(centre, arcRadius,
                                               MixerHueRing.degrees(of: handle, in: arc))
                    let r: CGFloat = isCore ? 4 : 3
                    let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r,
                                                     width: r * 2, height: r * 2))
                    context.fill(dot, with: .color(isCore
                                                   ? Lumen.primaryText
                                                   : Lumen.primaryText.opacity(0.55)))
                    context.stroke(dot, with: .color(Lumen.panelBackground), lineWidth: 1)
                }
            }
            .frame(width: MixerHueRing.diameter + 12, height: MixerHueRing.diameter + 12)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard showHandles else { return }
                        // Double-click reset, read the way the slider and the wheel
                        // read it (LumenControls): a minimumDistance-0 drag claims
                        // every press, so an onTapGesture(count: 2) behind it never
                        // fires — and here each click of the attempt also MOVED the
                        // nearest handle to the clicked angle, so following the
                        // ring's own help text silently reshaped the band twice.
                        if !pressWasReset,
                           let event = NSApp.currentEvent, event.clickCount >= 2 {
                            pressWasReset = true
                            grabbed = nil
                            onResetArc()
                            return
                        }
                        if pressWasReset { return }
                        sliderGestureChanged(true)
                        let box = MixerHueRing.diameter + 12
                        let dx = Double(drag.location.x - box / 2)
                        let dy = Double(drag.location.y - box / 2)
                        guard dx != 0 || dy != 0 else { return }
                        let degrees = Num.wrapHue(atan2(dy, dx) * 180 / .pi)
                        let handle = grabbed
                            ?? MixerHueRing.nearestHandle(to: degrees, in: arcList[index])
                        if grabbed == nil { grabbed = handle }
                        onHandleMoved(handle, degrees)
                    }
                    .onEnded { _ in
                        grabbed = nil
                        pressWasReset = false
                        sliderGestureChanged(false)
                    }
            )

            if allBands {
                Text("All bands")
                    .font(.system(size: 9))
                    .foregroundStyle(Lumen.secondaryText)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
        .help(allBands
              ? "Band reach is per band; pick one to shape its arc."
              : "Drag the inner handles for the core range, the outer ones for the "
                + "feather. Double-click to reset the arc.")
    }

    static let allHandles: [MixerArcHandle] =
        [.featherStart, .coreStart, .coreEnd, .featherEnd]

    static func degrees(of handle: MixerArcHandle, in arc: ColorEngine.BandArc) -> Double {
        switch handle {
        case .featherStart: return arc.featherStart
        case .coreStart: return arc.coreStart
        case .coreEnd: return arc.coreEnd
        case .featherEnd: return arc.featherEnd
        }
    }

    /// Whichever of the four is closest, in degrees around the ring.
    /// The parameter is deliberately not called `degrees`: that name is already the
    /// lookup function one line down, and shadowing it makes the call unresolvable.
    static func nearestHandle(to angle: Double,
                              in arc: ColorEngine.BandArc) -> MixerArcHandle {
        var best: MixerArcHandle = .coreStart
        var bestDistance = Double.infinity
        for handle in allHandles {
            let d = abs(Num.hueDelta(MixerHueRing.degrees(of: handle, in: arc), angle))
            if d < bestDistance {
                bestDistance = d
                best = handle
            }
        }
        return best
    }

    /// Screen point at a hue angle. Same convention as `LumenColorWheel`: hue 0 at three
    /// o'clock, increasing clockwise, because y grows downward.
    static func point(_ centre: CGPoint, _ radius: CGFloat, _ degrees: Double) -> CGPoint {
        let a = degrees * .pi / 180
        return CGPoint(x: centre.x + radius * CGFloat(cos(a)),
                       y: centre.y + radius * CGFloat(sin(a)))
    }

    /// A polyline arc. Sampled rather than `addArc`, so there is no sweep-direction
    /// argument to get backwards and the wrap at 360° needs no special case.
    static func arcPath(_ centre: CGPoint, _ radius: CGFloat,
                        from start: Double, to end: Double) -> Path {
        var path = Path()
        let span = Swift.max(end - start, 0)
        let steps = Swift.max(2, Int(span / 2) + 2)
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let p = point(centre, radius, start + span * t)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }
}

// MARK: - Band ribbon

/// The 8-band partition of unity, drawn. Because the bands overlap smoothly there are
/// no wedge edges to show — which is exactly the point, and why the strip is worth the
/// pixels: the selected band's reach is visible instead of imagined.
struct MixerBandRibbon: View {
    let weights: [[Double]]
    let colors: [Color]
    let selected: Int
    let allBands: Bool

    var body: some View {
        let samples = weights
        let palette = colors
        let highlighted = selected
        let all = allBands

        return Canvas { context, size in
            let count = samples.count
            guard count > 1, size.width > 0, size.height > 2 else { return }
            let usable = size.height - 2

            for band in palette.indices {
                var path = Path()
                var started = false
                for step in 0..<count {
                    let vector = samples[step]
                    guard band < vector.count else { continue }
                    let x = size.width * CGFloat(step) / CGFloat(count - 1)
                    let y = size.height - 1 - CGFloat(min(max(vector[band], 0), 1)) * usable
                    let point = CGPoint(x: x, y: y)
                    if started {
                        path.addLine(to: point)
                    } else {
                        path.move(to: point)
                        started = true
                    }
                }
                guard started else { continue }
                let emphasised = all || band == highlighted
                context.stroke(path,
                               with: .color(palette[band].opacity(emphasised ? 0.95 : 0.30)),
                               lineWidth: emphasised ? 1.6 : 1.0)
            }
        }
        .frame(height: 30)
        .background(Lumen.controlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .help("Band membership across the hue circle — the weights the engine uses.")
    }
}

#endif
