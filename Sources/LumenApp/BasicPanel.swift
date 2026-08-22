// BasicPanel.swift
// White balance, the six-slider tone contract, presence, and vibrance/saturation —
// the register a photographer lives in, in Lightroom's order and with Lightroom's
// names and ranges, because the muscle memory is real and there is nothing to gain
// by renaming Highlights.
//
// What is different is underneath: Exposure is honest scene-linear gain, the four
// zonal sliders are one edge-aware engine (ToneEngine) so they cannot halo, Contrast
// is a slope around an explicit pivot rather than an undocumented S-curve, and
// Vibrance/Saturation compute in the H-K-aware UCS model so a saturation move does
// not quietly change how bright a colour looks.
//
// Optional-field policy (RawParams.temp/tint): nil means "as shot" — the decode's own
// neutral, which is a real number the UI does not know. The sliders stand in 5500 K
// and 0 tint while the fields are nil and say "As Shot" in the preset row; the first
// move writes a concrete Kelvin, and the preset menu's As Shot entry writes nil back.

#if os(macOS)

import Foundation
import LumenCore
import SwiftUI

// MARK: - White balance presets

/// The named illuminants (docs/04 §2.1). Values are the conventional daylight/tungsten
/// anchors; picking one writes ordinary Temp/Tint numbers the user can then argue with.
private struct WBIlluminant: Identifiable {
    let name: String
    let kelvin: Double
    let tint: Double

    var id: String { name }
}

private let wbIlluminants: [WBIlluminant] = [
    WBIlluminant(name: "Daylight", kelvin: 5500, tint: 10),
    WBIlluminant(name: "Cloudy", kelvin: 6500, tint: 10),
    WBIlluminant(name: "Shade", kelvin: 7500, tint: 10),
    WBIlluminant(name: "Tungsten", kelvin: 2850, tint: 0),
    WBIlluminant(name: "Fluorescent", kelvin: 3800, tint: 21),
    WBIlluminant(name: "Flash", kelvin: 5500, tint: 0),
]

/// What the Temp and Tint rows show while the recipe says "as shot".
private let asShotTempStandIn: Double = 5500
private let asShotTintStandIn: Double = 0

// MARK: - Basic panel

struct BasicPanel: View {
    @EnvironmentObject var state: AppState

    @State private var showPivot: Bool = false
    @State private var showSaturationAdvanced: Bool = false

    private var binder: RecipeBinder { RecipeBinder(state: state) }
    private var recipe: Recipe { state.currentRecipe }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            whiteBalanceSection
            toneSection
            presenceSection
            saturationSection
        }
    }

    // MARK: White balance

    private var whiteBalanceSection: some View {
        DevelopSection("White Balance", isModified: isWhiteBalanceModified,
                       onReset: { applyAsShot() }) {
            VStack(alignment: .leading, spacing: 2) {
                presetRow
                // The Kelvin axis is perceptually log-scaled in the spec; the shipped
                // slider is linear until LumenSlider grows a scale transform, so typed
                // entry is the accurate way into the low end.
                LumenSlider(title: "Temp",
                            value: binder.value(\.develop.raw.temp, "wb.temp",
                                                orAuto: asShotTempStandIn),
                            range: 2000...50000,
                            hardRange: 2000...50000,
                            defaultValue: asShotTempStandIn,
                            step: 10, decimals: 0, bipolar: false,
                            // Double-clicking the label CLEARS the override rather than
                            // writing 5500 into it. `raw.temp` is optional and nil means
                            // as-shot; pinning a number there flips the section to
                            // "Custom" and changes the picture for any file not shot at
                            // that temperature.
                            onReset: { applyAsShot() })
                LumenSlider(title: "Tint",
                            value: binder.value(\.develop.raw.tint, "wb.tint",
                                                orAuto: asShotTintStandIn),
                            range: -150...150,
                            hardRange: -300...300,
                            defaultValue: asShotTintStandIn,
                            step: 1, decimals: 0,
                            onReset: { applyAsShot() })
            }
        }
    }

    private var presetRow: some View {
        HStack(spacing: 6) {
            Menu {
                Button("As Shot") { applyAsShot() }
                Button("Auto") {}
                    .disabled(true)
                    .help("Auto white balance needs the scene statistics the render "
                          + "coordinator will publish (docs/04 §2.2).")
                Divider()
                ForEach(wbIlluminants) { illuminant in
                    Button(illuminant.name) {
                        applyIlluminant(illuminant)
                    }
                }
            } label: {
                Text(presetName)
                    .font(.system(size: 10))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("White balance preset — any manual move reads as Custom")

            Button {
                // Pressing it again disarms rather than stacking a second pick.
                if state.pickTarget == .neutral {
                    state.cancelPick()
                } else {
                    state.beginPick(.neutral)
                }
            } label: {
                Image(systemName: "eyedropper")
                    .font(.system(size: 11))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Lumen.controlBackground)
                    .foregroundStyle(Lumen.primaryText)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The probe this needed is `PipelineRenderer.sampleSceneLinear`: it reads
            // the DECODED frame, before any of Lumen's stages, which is the one tap
            // whose meaning does not shift when a slider moves. Sampling after white
            // balance would make the picked neutral depend on the white balance it is
            // being used to compute.
            .help(state.pickTarget == .neutral
                  ? "Click a neutral in the picture — or press again to cancel."
                  : "Click something grey in the picture and Temp/Tint solve for it.")
        }
        .frame(height: Lumen.rowHeight)
    }

    /// "Custom" is what any manual move means — matching Lightroom's grammar, where the
    /// preset row reports what the numbers are rather than what you last clicked.
    private var presetName: String {
        guard let temp = recipe.develop.raw.temp else { return "As Shot" }
        let tint = recipe.develop.raw.tint ?? 0
        for illuminant in wbIlluminants
        where abs(illuminant.kelvin - temp) < 1 && abs(illuminant.tint - tint) < 1 {
            return illuminant.name
        }
        return "Custom"
    }

    private var isWhiteBalanceModified: Bool {
        recipe.develop.raw.temp != nil || recipe.develop.raw.tint != nil
    }

    private func applyAsShot() {
        binder.edit("wb.preset") { recipe in
            recipe.develop.raw.temp = nil
            recipe.develop.raw.tint = nil
        }
    }

    private func applyIlluminant(_ illuminant: WBIlluminant) {
        binder.edit("wb.preset") { recipe in
            recipe.develop.raw.temp = illuminant.kelvin
            recipe.develop.raw.tint = illuminant.tint
        }
    }

    // MARK: Tone

    private var toneSection: some View {
        DevelopSection("Tone", isModified: recipe.develop.tone != Tone(),
                       onReset: { binder.edit("tone.reset") { $0.develop.tone = Tone() } }) {
            VStack(alignment: .leading, spacing: 2) {
                LumenSlider(title: "Exposure",
                            value: binder.value(\.develop.tone.exposure, "tone.exposure"),
                            range: -5...5, hardRange: -10...10, defaultValue: 0,
                            step: 0.01, decimals: 2)
                LumenSlider(title: "Contrast",
                            value: binder.value(\.develop.tone.contrast, "tone.contrast"),
                            range: -100...100, hardRange: nil, defaultValue: 0,
                            step: 1, decimals: 0)
                pivotDisclosure
                LumenSlider(title: "Highlights",
                            value: binder.value(\.develop.tone.highlights, "tone.highlights"),
                            range: -100...100, hardRange: nil, defaultValue: 0,
                            step: 1, decimals: 0)
                LumenSlider(title: "Shadows",
                            value: binder.value(\.develop.tone.shadows, "tone.shadows"),
                            range: -100...100, hardRange: nil, defaultValue: 0,
                            step: 1, decimals: 0)
                LumenSlider(title: "Whites",
                            value: binder.value(\.develop.tone.whites, "tone.whites"),
                            range: -100...100, hardRange: nil, defaultValue: 0,
                            step: 1, decimals: 0)
                LumenSlider(title: "Blacks",
                            value: binder.value(\.develop.tone.blacks, "tone.blacks"),
                            range: -100...100, hardRange: nil, defaultValue: 0,
                            step: 1, decimals: 0)
            }
        }
    }

    /// Contrast's disclosure. The pivot is the thing Lightroom hides: its Contrast is
    /// a fixed S-curve anchored near L≈50, never documented. Here the anchor is a
    /// number, in stops relative to mid-grey.
    private var pivotDisclosure: some View {
        DevelopDisclosure("Pivot", isExpanded: $showPivot) {
            VStack(alignment: .leading, spacing: 2) {
                LumenSlider(title: "Pivot",
                            value: binder.value(\.develop.tone.contrastPivot,
                                                "tone.contrastPivot"),
                            range: -4...4, hardRange: nil, defaultValue: 0,
                            step: 0.01, decimals: 2)
                DevelopNote("Contrast is a slope around this pivot in log-exposure "
                            + "space, relaxing back to 1 beyond ±4 EV so extremes "
                            + "compress instead of exploding.")
            }
        }
    }

    // MARK: Presence

    private var presenceSection: some View {
        DevelopSection("Presence", isModified: isPresenceModified,
                       onReset: { resetPresence() }) {
            VStack(alignment: .leading, spacing: 2) {
                LumenSlider(title: "Texture",
                            value: binder.value(\.develop.detail.texture, "detail.texture"),
                            range: -100...100, hardRange: nil, defaultValue: 0,
                            step: 1, decimals: 0)
                LumenSlider(title: "Clarity",
                            value: binder.value(\.develop.detail.clarity, "detail.clarity"),
                            range: -100...100, hardRange: nil, defaultValue: 0,
                            step: 1, decimals: 0)
                LumenSlider(title: "Dehaze",
                            value: binder.value(\.develop.detail.dehaze, "detail.dehaze"),
                            range: -100...100, hardRange: nil, defaultValue: 0,
                            step: 1, decimals: 0)
                // This used to claim all three "recombine one cached decomposition of
                // the frame, so dragging any of them costs a recombination, not a
                // re-analysis". There is no such cache: `applyDetailBands` builds fresh
                // guided filters every frame and `makeGraph` rebuilds the graph per
                // render. A panel note is a promise to the person reading it, and that
                // one was describing an optimisation nobody had written.
                DevelopNote("Texture and Clarity work on different scales of the same "
                            + "frame and neither can halo. Dehaze is a transmission "
                            + "estimate, so it lifts contrast where the air is, not "
                            + "everywhere.")
            }
        }
    }

    private var isPresenceModified: Bool {
        recipe.develop.detail.texture != 0
            || recipe.develop.detail.clarity != 0
            || recipe.develop.detail.dehaze != 0
    }

    private func resetPresence() {
        binder.edit("detail.presence.reset") { recipe in
            recipe.develop.detail.texture = 0
            recipe.develop.detail.clarity = 0
            recipe.develop.detail.dehaze = 0
        }
    }

    // MARK: Vibrance & saturation

    private var saturationSection: some View {
        DevelopSection("Colour", isModified: recipe.develop.color != ColorAdjust(),
                       onReset: { binder.edit("color.reset") {
                           $0.develop.color = ColorAdjust()
                       } }) {
            VStack(alignment: .leading, spacing: 2) {
                LumenSlider(title: "Vibrance",
                            value: binder.value(\.develop.color.vibrance, "color.vibrance"),
                            range: -100...100, hardRange: nil, defaultValue: 0,
                            step: 1, decimals: 0)
                LumenSlider(title: "Saturation",
                            value: binder.value(\.develop.color.saturation, "color.saturation"),
                            range: -100...100, hardRange: nil, defaultValue: 0,
                            step: 1, decimals: 0)
                advancedColourDisclosure
            }
        }
    }

    private var advancedColourDisclosure: some View {
        // Density blends Saturation's additive push against its subtractive one, and a
        // pull has no push to blend — the engine guards it on `satAmount > 0`. The dial
        // used to be drawn live across all of that half of Saturation's range while
        // doing exactly nothing, which is worse than a dead control because it looks
        // like it is working. The predicate is `ColorAdjust.densityIsLive`, in LumenCore
        // next to the field, with a test tying it to the engine's own guard.
        let densityIsLive = recipe.develop.color.densityIsLive
        return DevelopDisclosure("Advanced", isExpanded: $showSaturationAdvanced) {
            VStack(alignment: .leading, spacing: 2) {
                LumenSlider(title: "Density",
                            value: binder.value(\.develop.color.density, "color.density"),
                            range: 0...100, hardRange: nil, defaultValue: 50,
                            step: 1, decimals: 0, bipolar: true)
                    .disabled(!densityIsLive)
                    .help(densityIsLive
                          ? "How much of a Saturation push is subtractive."
                          : "Density acts on a Saturation push. Raise Saturation above "
                              + "zero and this comes live.")
                LumenSlider(title: "Protect Skin",
                            value: binder.value(\.develop.color.protectSkin,
                                                "color.protectSkin"),
                            range: 0...100, hardRange: nil, defaultValue: 70,
                            step: 1, decimals: 0, bipolar: true)
                DevelopNote("Density blends a Saturation PUSH between an additive one "
                            + "and a subtractive one — colour intensifying by darkening, "
                            + "the way stacked dye does. It does nothing on the way "
                            + "down. Protect Skin attenuates Vibrance and a Saturation "
                            + "push inside the skin-tone band; Saturation −100 still "
                            + "reaches true black and white everywhere.")
            }
        }
    }
}

#endif
