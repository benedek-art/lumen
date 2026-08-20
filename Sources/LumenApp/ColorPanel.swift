// ColorPanel.swift
// The Colour panel: the 8-band Mixer, Point Colour and the Black & White treatment.
//
// Three things this panel exists to get right:
//   · The band strip DRAWS ColorEngine's own weights rather than a redrawn
//     approximation, so "what does this band actually touch" is answerable by looking.
//     The bands are a smooth partition of unity — there are no wedge edges to see.
//   · Luminance is chroma-preserving (D13). Darkening a blue sky must not desaturate
//     it, and the caption says so next to the slider rather than in a manual.
//   · Switching to B&W and back loses nothing. The Mixer lives in `develop.mixer` and
//     the B&W mix in `look.bw`; the treatment toggle never writes across that line, and
//     the mix is held here for the session while the wire format still spells "off" as
//     nil (docs/06 brief §7.3 — `bw.enabled` is a pending format addition).
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
    /// The B&W mix, kept alive across a treatment toggle. See the file header: the
    /// format says "off" with nil, so somebody has to remember, and it is not the user.
    @State private var stashedBWBands: [Double] = Array(repeating: 0, count: 8)

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
        let touched = bands.contains(where: { $0.hue != 0 || $0.sat != 0 || $0.lum != 0 })
        let modified = touched || mixer.uniformity != 0

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

                MixerBandRibbon(weights: ColorPanel.ribbonWeights,
                                colors: ColorPanel.bandSwatchColors,
                                selected: selectedBand,
                                allBands: allBands)

                Text(allBands
                     ? "All bands move together; the spread between them is preserved."
                     : "\(ColorPanel.bandName(selectedBand)) — centred on "
                       + String(format: "%.1f°", ColorPanel.bandCentre(selectedBand))
                       + " in OKLCh, feathered into its neighbours.")
                    .font(.system(size: 10))
                    .foregroundStyle(Lumen.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 2)

                LumenSlider(title: "Hue", value: mixerBinding(.hue),
                            range: -100...100, defaultValue: 0, step: 1, decimals: 0)
                LumenSlider(title: "Saturation", value: mixerBinding(.sat),
                            range: -100...100, defaultValue: 0, step: 1, decimals: 0)
                LumenSlider(title: "Luminance", value: mixerBinding(.lum),
                            range: -100...100, defaultValue: 0, step: 1, decimals: 0)

                caption("Luminance holds chroma: a darkened sky stays as blue as it was.")

                LumenSlider(title: "Uniformity",
                            value: bind("mixer.uniformity",
                                        get: { $0.develop.mixer.uniformity },
                                        set: { $0.develop.mixer.uniformity = $1 }),
                            range: 0...100, defaultValue: 0, step: 1, decimals: 0,
                            bipolar: false)

                caption("Uniformity converges each band's low-frequency hue variation; "
                        + "local texture survives.")
            }
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

    private func addSwatch() {
        state.updateRecipe { recipe in
            guard recipe.develop.pointColors.count < ColorPanel.maxSwatches else { return }
            // Mid-grey in the scene-referred working space: a swatch with no sample yet
            // is inert, which is the honest state until the eyedropper lands.
            recipe.develop.pointColors.append(PointColor(sample: [0.18, 0.18, 0.18]))
        }
        let count = state.currentRecipe.develop.pointColors.count
        selectedSwatch = max(0, count - 1)
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
        let isOn = bw != nil

        return VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Black & White",
                               isExpanded: $bwExpanded,
                               isModified: isOn,
                               onReset: { state.updateRecipe { $0.look.bw = nil } })

            if bwExpanded {
                LumenToggleRow(title: "Black & white treatment",
                               isOn: Binding(get: { isOn }, set: { setTreatment($0) }),
                               help: "Toggling the treatment keeps both sets of settings — "
                                   + "the colour mixer is not touched.")

                if isOn {
                    ForEach(Array(0..<ColorEngine.bandCount), id: \.self) { i in
                        LumenSlider(title: ColorPanel.bandName(i),
                                    value: bwBinding(i),
                                    range: -100...100, defaultValue: 0, step: 1, decimals: 0)
                    }
                    caption("Same eight bands as the mixer, same smooth weighting — an "
                            + "aggressive mix darkens cleanly instead of banding. Toning "
                            + "is the grading wheels in the Look panel, not a second tool.")
                } else if bands.contains(where: { $0 != 0 }) || stashedBWBands.contains(where: { $0 != 0 }) {
                    caption("The mix is kept. Turn the treatment back on and it returns "
                            + "exactly as it was.")
                } else {
                    caption("Off. The colour mixer above keeps its own state either way.")
                }
            }
        }
    }

    private func setTreatment(_ on: Bool) {
        if on {
            let restored = stashedBWBands
            state.updateRecipe { recipe in
                if recipe.look.bw == nil {
                    recipe.look.bw = BlackAndWhite(bands: ColorPanel.normalizedDoubles(restored))
                }
            }
        } else {
            stashedBWBands = ColorPanel.normalizedDoubles(state.currentRecipe.look.bw?.bands)
            state.updateRecipe { $0.look.bw = nil }
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
                    recipe.look.bw = BlackAndWhite(bands: bands)
                }
                stashedBWBands = ColorPanel.normalizedDoubles(state.currentRecipe.look.bw?.bands)
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

    /// The engine's own membership vectors, sampled once. The strip is a drawing of the
    /// weights the pixel loop uses — not a picture of what they ought to look like.
    static let ribbonWeights: [[Double]] = {
        var out: [[Double]] = []
        out.reserveCapacity(ColorPanel.ribbonSteps + 1)
        for step in 0...ColorPanel.ribbonSteps {
            let hue = Double(step) / Double(ColorPanel.ribbonSteps) * 360
            out.append(ColorEngine.bandWeights(hue: hue))
        }
        return out
    }()

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
