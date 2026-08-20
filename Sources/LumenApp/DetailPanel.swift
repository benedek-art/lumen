// DetailPanel.swift
// Capture sharpening, manual sharpening and noise reduction — the three places the
// pipeline touches high-frequency structure, in pipeline order (S4, S12, and the
// decode-adjacent denoise stage).
//
// The panel's job is to keep the division of labour visible: capture sharpening
// undoes the sensor's own blur once, at decode, from the frame's measured PSF; manual
// sharpening is a creative amount applied late, after local edits, so masked clarity
// is never double-sharpened. A user who understands that stops stacking one on top of
// the other to fix the other's artefacts.
//
// Optional-field policy (CaptureSharpen.radius/amount): nil means "measured from the
// frame's own greens" — a real number that only the decode knows. The override rows
// stand in 0.80 px and 50 while the fields are nil and badge the section AUTO; the
// first move pins a concrete value, and "Use measured values" writes nil back.

#if os(macOS)

import Foundation
import LumenCore
import SwiftUI

/// What the capture-sharpen override rows show while the recipe says "auto". The
/// radius stand-in is the middle of the 0.4–2.0 px estimation range for a modern
/// full-frame sensor at a good aperture; the amount stand-in is the engine's own
/// default strength.
private let captureRadiusStandIn: Double = 0.8
// 100, not 50: both readers of `CaptureSharpen.amount` treat nil as 100
// (`DetailEngine.captureSharpen`, `AppleRawSource`). Showing 50 while auto renders at
// 100 meant the first nudge of the slider halved the sharpening.
private let captureAmountStandIn: Double = 100

struct DetailPanel: View {
    @EnvironmentObject var state: AppState

    @State private var showCaptureOverrides: Bool = false

    private var binder: RecipeBinder { RecipeBinder(state: state) }
    private var recipe: Recipe { state.currentRecipe }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            captureSection
            manualSection
            noiseSection
        }
    }

    // MARK: Capture sharpening

    private var captureSection: some View {
        DevelopSection("Capture Sharpening", isModified: isCaptureModified,
                       onReset: { binder.edit("detail.capture.reset") {
                           $0.develop.detail.capture = CaptureSharpen()
                       } }) {
            VStack(alignment: .leading, spacing: 2) {
                LumenToggleRow(title: "Capture sharpening",
                               isOn: binder.flag(\.develop.detail.capture.auto,
                                                 "detail.capture.auto"),
                               help: "Richardson–Lucy deconvolution at a radius "
                                   + "measured from adjacent unclipped Bayer greens — "
                                   + "this exposure, this lens, this aperture, no lens "
                                   + "database.")
                if recipe.develop.detail.capture.auto {
                    captureOverrides
                } else {
                    DevelopNote("Capture sharpening is off for this photo. It is on by "
                                + "default for raw and off for JPEG/HEIC, where the "
                                + "camera has already sharpened.")
                }
            }
        }
    }

    private var captureOverrides: some View {
        DevelopDisclosure("Overrides", isExpanded: $showCaptureOverrides) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(hasCaptureOverride ? "Manual" : "Measured")
                        .font(.system(size: 10))
                        .foregroundStyle(Lumen.secondaryText)
                    Spacer()
                    if hasCaptureOverride {
                        Button("Use measured values") { clearCaptureOverrides() }
                            .buttonStyle(.plain)
                            .font(.system(size: 10))
                            .foregroundStyle(Lumen.accent)
                    } else {
                        LumenBadge(text: "Auto")
                    }
                }
                .frame(height: Lumen.rowHeight)

                LumenSlider(title: "Radius",
                            value: binder.value(\.develop.detail.capture.radius,
                                                "detail.capture.radius",
                                                orAuto: captureRadiusStandIn),
                            range: 0.4...2.0, hardRange: nil,
                            defaultValue: captureRadiusStandIn,
                            step: 0.05, decimals: 2, bipolar: false)
                LumenSlider(title: "Amount",
                            value: binder.value(\.develop.detail.capture.amount,
                                                "detail.capture.amount",
                                                orAuto: captureAmountStandIn),
                            range: 0...100, hardRange: nil,
                            defaultValue: captureAmountStandIn,
                            step: 1, decimals: 0, bipolar: false)
                DevelopNote("Moving either row pins it for this photo. The iteration "
                            + "count, corner boost and ISO-adaptive noise gate stay "
                            + "with the engine.")
            }
        }
    }

    private var hasCaptureOverride: Bool {
        recipe.develop.detail.capture.radius != nil
            || recipe.develop.detail.capture.amount != nil
    }

    private var isCaptureModified: Bool {
        recipe.develop.detail.capture != CaptureSharpen()
    }

    private func clearCaptureOverrides() {
        binder.edit("detail.capture.auto.restore") { recipe in
            recipe.develop.detail.capture.radius = nil
            recipe.develop.detail.capture.amount = nil
        }
    }

    // MARK: Manual sharpening

    private var manualSection: some View {
        DevelopSection("Sharpening", isModified: recipe.develop.detail.sharpen != ManualSharpen(),
                       onReset: { binder.edit("detail.sharpen.reset") {
                           $0.develop.detail.sharpen = ManualSharpen()
                       } }) {
            VStack(alignment: .leading, spacing: 2) {
                LumenSlider(title: "Amount",
                            value: binder.value(\.develop.detail.sharpen.amount,
                                                "detail.sharpen.amount"),
                            range: 0...150, hardRange: nil, defaultValue: 0,
                            step: 1, decimals: 0, bipolar: false)
                LumenSlider(title: "Radius",
                            value: binder.value(\.develop.detail.sharpen.radius,
                                                "detail.sharpen.radius"),
                            range: 0.5...3.0, hardRange: nil, defaultValue: 1.0,
                            step: 0.1, decimals: 1, bipolar: false)
                LumenSlider(title: "Detail",
                            value: binder.value(\.develop.detail.sharpen.detail,
                                                "detail.sharpen.detail"),
                            range: 0...100, hardRange: nil, defaultValue: 25,
                            step: 1, decimals: 0, bipolar: true)
                LumenSlider(title: "Masking",
                            value: binder.value(\.develop.detail.sharpen.masking,
                                                "detail.sharpen.masking"),
                            range: 0...100, hardRange: nil, defaultValue: 0,
                            step: 1, decimals: 0, bipolar: false)
                LumenSlider(title: "Halo Suppression",
                            value: binder.value(\.develop.detail.sharpen.haloSuppression,
                                                "detail.sharpen.haloSuppression"),
                            range: 0...100, hardRange: nil, defaultValue: 0,
                            step: 1, decimals: 0, bipolar: false)
                if recipe.develop.detail.capture.auto {
                    DevelopNote("Capture sharpening already owns the baseline for this "
                                + "photo, so Amount starts at 0. Halo Suppression damps "
                                + "bright overshoot asymmetrically, which is what lets "
                                + "Amount above 80 stay clean.")
                } else {
                    lightroomClassicHint
                }
            }
        }
    }

    /// The inline hint that gives a refugee somewhere to stand when capture sharpening
    /// is off: Lightroom's classic default quartet, one click away.
    private var lightroomClassicHint: some View {
        HStack(spacing: 6) {
            Text("No capture stage — try 40 / 1.0 / 25 / 0")
                .font(.system(size: 10))
                .foregroundStyle(Lumen.secondaryText)
            Spacer()
            Button("Apply") { applyClassicSharpen() }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(Lumen.accent)
        }
        .frame(height: Lumen.rowHeight)
    }

    private func applyClassicSharpen() {
        binder.edit("detail.sharpen.classic") { recipe in
            recipe.develop.detail.sharpen.amount = 40
            recipe.develop.detail.sharpen.radius = 1.0
            recipe.develop.detail.sharpen.detail = 25
            recipe.develop.detail.sharpen.masking = 0
        }
    }

    // MARK: Noise reduction

    private var noiseSection: some View {
        DevelopSection("Noise Reduction", isModified: recipe.develop.denoise != Denoise(),
                       onReset: { binder.edit("denoise.reset") {
                           $0.develop.denoise = Denoise()
                       } }) {
            VStack(alignment: .leading, spacing: 4) {
                LumenSegmented(options: [(value: Denoise.Mode.off, label: "Off"),
                                         (value: Denoise.Mode.classic, label: "Classic"),
                                         (value: Denoise.Mode.ai, label: "AI")],
                               selection: binder.choice(\.develop.denoise.mode,
                                                        "denoise.mode"))
                noiseControls
            }
        }
    }

    @ViewBuilder
    private var noiseControls: some View {
        switch recipe.develop.denoise.mode {
        case .off:
            DevelopNote("No denoise. Capture sharpening still gates itself away from "
                        + "low-contrast regions, so this is a usable setting at base ISO.")
        case .classic:
            VStack(alignment: .leading, spacing: 2) {
                LumenSlider(title: "Luminance",
                            value: binder.value(\.develop.denoise.classic.luma,
                                                "denoise.classic.luma"),
                            range: 0...100, hardRange: nil, defaultValue: 0,
                            step: 1, decimals: 0, bipolar: false)
                LumenSlider(title: "Colour",
                            value: binder.value(\.develop.denoise.classic.chroma,
                                                "denoise.classic.chroma"),
                            range: 0...100, hardRange: nil, defaultValue: 25,
                            step: 1, decimals: 0, bipolar: true)
                LumenSlider(title: "Hot Pixels",
                            value: binder.value(\.develop.denoise.classic.hotPixels,
                                                "denoise.classic.hotPixels"),
                            range: 0...100, hardRange: nil, defaultValue: 0,
                            step: 1, decimals: 0, bipolar: false)
                DevelopNote("Instant, non-destructive, and enough for most frames. "
                            + "Colour starts mild rather than at zero because chroma "
                            + "blotches are the artefact nobody wants to see.")
            }
        case .ai:
            VStack(alignment: .leading, spacing: 2) {
                LumenSlider(title: "Amount",
                            value: binder.value(\.develop.denoise.amount, "denoise.amount"),
                            range: 0...100, hardRange: nil, defaultValue: 50,
                            step: 1, decimals: 0, bipolar: false)
                DevelopNote("The AI pass is a cached artefact, never a new file on disk, "
                            + "and Amount blends it after it computes — so the slider "
                            + "stays instant once the pass has run.")
            }
        }
    }
}

#endif
