// DetailPanel.swift
// Capture sharpening, manual sharpening and noise reduction — the three places the
// pipeline touches high-frequency structure, in pipeline order (S4, S12, and S3,
// which is upstream of both).
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
    /// This surface shows the edit, so it observes the edit signal —
    /// `AppState.recipes` is deliberately not published (see `EditRevision`).
    @EnvironmentObject var edits: EditRevision

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
                               // The RL story is docs/06's, and RL does not run:
                               // `DetailEngine.captureSharpen` has no caller. Saying so
                               // here rather than selling the algorithm the panel wishes
                               // it were running.
                               //
                               // It also said "written and TESTED". It is not tested:
                               // `richardsonLucy`, `estimatePSFSigma` and
                               // `captureSharpen` appear in no file under Tests/, so
                               // nothing has ever observed them produce a pixel. Code
                               // with no caller and no test is written, and that is the
                               // whole of what may be claimed for it — "tested" is the
                               // word that turns an honest disclosure into a second
                               // claim the reader has no way to check.
                               help: "Scales the decoder's own at-demosaic sharpener. "
                                   + "Lumen's measured-PSF deconvolution is written but "
                                   + "has no caller and no test, so it does not run and "
                                   + "there is no per-frame radius measurement in this "
                                   + "build.")
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

                // Both rows are optional-backed, where nil means "use the measured
                // value", so double-clicking to reset must CLEAR rather than write the
                // stand-in — writing it pins an override and only flips the badge from
                // Auto to Manual.
                LumenSlider(title: "Radius",
                            value: binder.value(\.develop.detail.capture.radius,
                                                "detail.capture.radius",
                                                orAuto: captureRadiusStandIn),
                            range: 0.4...2.0, hardRange: nil,
                            defaultValue: captureRadiusStandIn,
                            step: 0.05, decimals: 2, bipolar: false,
                            onReset: { clearCaptureOverrides() })
                LumenSlider(title: "Amount",
                            value: binder.value(\.develop.detail.capture.amount,
                                                "detail.capture.amount",
                                                orAuto: captureAmountStandIn),
                            range: 0...150, hardRange: nil,
                            defaultValue: captureAmountStandIn,
                            step: 1, decimals: 0, bipolar: false,
                            onReset: { clearCaptureOverrides() })
                // Radius is honest about being reference-only: `CaptureSharpen.radius`
                // reaches only `DetailEngine.captureSharpen`, which has no caller — the
                // RAW stage reads `strengthFraction` and nothing else. Amount's range
                // now matches the engine's 0…150 rather than stopping at the default.
                DevelopNote("Amount pins the strength for this photo. Radius is stored "
                            + "but not applied in this build — the decode stage takes "
                            + "the strength and measures the radius itself.",
                            prominent: true)
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
                                + "photo, so Amount starts at 0.")
                } else {
                    lightroomClassicHint
                }
                // Radius here is in RAW PIXELS and the band steps are fixed pixel
                // counts, while every other spatial stage in the graph sizes itself off
                // the long edge. A preview is also capped at 4096 px, so there is no
                // view in this application — 1:1 included — that shows a 45 MP export's
                // sharpening. Saying so is not a fix; it is the least the panel owes a
                // user judging an export by a preview.
                // Honesty work stays prominent (DevelopNote's own rule): this is a
                // disclosure that the export differs from every preview, for the
                // person judging an export by one — behind the hover-ⓘ they see
                // nothing at the moment it matters.
                DevelopNote("Sharpening is measured in pixels, not in fractions of the "
                            + "frame, so a full-size export is less sharpened than the "
                            + "preview it was judged on. Previews also render at up to "
                            + "4096 px, which means no view here — 1:1 included — shows "
                            + "an export's sharpening on a high-resolution file.",
                            prominent: true)
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

    /// The ISO the DENOISE PROFILE will actually be resolved against, which is not the
    /// same as the ISO the file records.
    ///
    /// `AppState.startingRecipe` applies the ISO table only to non-rendered files: a
    /// camera JPEG has already been denoised in-body and its pixels no longer follow any
    /// sensor noise model this table knows. `ImageSource` agrees and reports `iso: nil`
    /// for a rendered source, so the render itself uses the base-ISO profile.
    ///
    /// This read the catalog's ISO for every format, and `CaptureMetadataReader` fills
    /// that from any file ImageIO can open. So on a JPEG shot at ISO 3200 the panel said
    /// "Adjusted from the ISO 3200 defaults" and badged an untouched photo "Manual", the
    /// section showed its modified dot, double-clicking Luminance wrote 18.75 — a value
    /// `startingRecipe` had just decided this file must not get — and those numbers were
    /// then applied against the ISO 100 profile anyway. Every JPEG, HEIC and TIFF in the
    /// library, wrong in four places at once.
    private var captureISO: Double? {
        guard let photo = state.primarySelection,
              !PhotoFormats.isRendered(photo.id) else { return nil }
        return photo.iso.map { Double($0) }
    }

    /// The ISO the FILE records, whether or not the profile uses it. Only for saying so.
    private var recordedISO: Double? {
        state.primarySelection?.iso.map { Double($0) }
    }

    /// Whether this photo is one the ISO table deliberately skips.
    private var isRenderedFile: Bool {
        state.primarySelection.map { PhotoFormats.isRendered($0.id) } ?? false
    }

    /// What an unedited frame at this ISO starts on — the same resolution
    /// `AppState.startingRecipe` writes, so "modified" means modified against the
    /// photo's own defaults rather than against a flat table, and double-clicking a
    /// slider goes back to the ISO-adaptive value instead of to somebody else's guess.
    private var isoDefault: Denoise {
        ISODefaults.startingDenoise(forISO: captureISO)
    }

    /// Says which profile the numbers came from, because "Luminance 19" means nothing
    /// without it. docs/07 D11 asks for the resolved value to be shown, not the word
    /// "auto" standing in for a number nobody can see.
    @ViewBuilder
    private var isoBadgeRow: some View {
        if let iso = captureISO {
            HStack(spacing: 6) {
                Text(recipe.develop.denoise == isoDefault
                     ? "Defaults for ISO \(Int(iso))"
                     : "Adjusted from the ISO \(Int(iso)) defaults")
                    .font(.system(size: 10))
                    .foregroundStyle(Lumen.secondaryText)
                Spacer()
                LumenBadge(text: recipe.develop.denoise == isoDefault ? "Auto" : "Manual")
            }
            .frame(height: Lumen.rowHeight)
        } else if isRenderedFile, let iso = recordedISO {
            // The file HAS an ISO. Saying "no ISO recorded" here would be a second lie
            // on top of the one this branch exists to stop.
            DevelopNote("This file records ISO \(Int(iso)), but it is already a rendered "
                        + "picture — the camera denoised it, so the sensor noise model "
                        + "does not describe these pixels. These start flat and the "
                        + "profile is the base one.")
        } else if isRenderedFile {
            DevelopNote("A rendered file: the camera has already denoised it, so these "
                        + "start at the flat defaults rather than at a profiled guess.")
        } else {
            DevelopNote("No ISO recorded for this file, so these start at the flat "
                        + "defaults rather than at a profiled guess.")
        }
    }

    private var noiseSection: some View {
        DevelopSection("Noise Reduction", isModified: recipe.develop.denoise != isoDefault,
                       onReset: { binder.edit("denoise.reset") {
                           $0.develop.denoise = ISODefaults.startingDenoise(
                               forISO: self.captureISO)
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
            DevelopNote("No denoise at all — Hot Pixels included, because off means "
                        + "off. Capture sharpening still gates itself away from "
                        + "low-contrast regions, so this is a usable setting at base ISO.")
        case .classic:
            VStack(alignment: .leading, spacing: 2) {
                isoBadgeRow
                // The two masters write a `userSet` bit as well as a value. It is the
                // only record that a number came from the photographer rather than from
                // the ISO table, and `ISODefaults.coupled` needs it: switching to AI
                // zeroes an inherited master and must leave a hand-set one alone.
                LumenSlider(title: "Luminance",
                            value: binder.custom(
                                "denoise.classic.luma",
                                get: { $0.develop.denoise.classic.luma },
                                set: { recipe, value in
                                    recipe.develop.denoise.classic.luma = value
                                    recipe.develop.denoise.classic.lumaUserSet = true
                                }),
                            range: 0...100, hardRange: nil,
                            defaultValue: isoDefault.classic.luma,
                            step: 1, decimals: 0, bipolar: false,
                            // Reset CLEARS the user-set bit along with the value. A
                            // plain defaultValue write went through the binding
                            // above, which stamps the bit — so double-clicking a
                            // master at its default changed no number and still
                            // flipped Auto to Manual, and a later switch to AI kept
                            // the master instead of zeroing it.
                            onReset: { binder.edit("denoise.classic.luma") { recipe in
                                recipe.develop.denoise.classic.luma =
                                    isoDefault.classic.luma
                                recipe.develop.denoise.classic.lumaUserSet = false
                            } })
                LumenSlider(title: "Luminance Detail",
                            value: binder.value(\.develop.denoise.classic.lumaDetail,
                                                "denoise.classic.lumaDetail"),
                            range: 0...100, hardRange: nil,
                            defaultValue: isoDefault.classic.lumaDetail,
                            step: 1, decimals: 0, bipolar: false)
                LumenSlider(title: "Luminance Contrast",
                            value: binder.value(\.develop.denoise.classic.lumaContrast,
                                                "denoise.classic.lumaContrast"),
                            range: 0...100, hardRange: nil,
                            defaultValue: isoDefault.classic.lumaContrast,
                            step: 1, decimals: 0, bipolar: false)
                LumenSlider(title: "Colour",
                            value: binder.custom(
                                "denoise.classic.chroma",
                                get: { $0.develop.denoise.classic.chroma },
                                set: { recipe, value in
                                    recipe.develop.denoise.classic.chroma = value
                                    recipe.develop.denoise.classic.chromaUserSet = true
                                }),
                            range: 0...100, hardRange: nil,
                            defaultValue: isoDefault.classic.chroma,
                            step: 1, decimals: 0, bipolar: true,
                            // Same clearing reset as Luminance above, same reason.
                            onReset: { binder.edit("denoise.classic.chroma") { recipe in
                                recipe.develop.denoise.classic.chroma =
                                    isoDefault.classic.chroma
                                recipe.develop.denoise.classic.chromaUserSet = false
                            } })
                LumenSlider(title: "Colour Detail",
                            value: binder.value(\.develop.denoise.classic.colorDetail,
                                                "denoise.classic.colorDetail"),
                            range: 0...100, hardRange: nil,
                            defaultValue: isoDefault.classic.colorDetail,
                            step: 1, decimals: 0, bipolar: false)
                LumenSlider(title: "Colour Smoothness",
                            value: binder.value(\.develop.denoise.classic.colorSmoothness,
                                                "denoise.classic.colorSmoothness"),
                            range: 0...100, hardRange: nil,
                            defaultValue: isoDefault.classic.colorSmoothness,
                            step: 1, decimals: 0, bipolar: false)
                LumenSlider(title: "Hot Pixels",
                            value: binder.value(\.develop.denoise.classic.hotPixels,
                                                "denoise.classic.hotPixels"),
                            range: 0...100, hardRange: nil, defaultValue: 0,
                            step: 1, decimals: 0, bipolar: false)
                DevelopNote("Profiled wavelet noise reduction, live on every frame. "
                            + "Luminance is gentle by design and Colour is aggressive: "
                            + "chroma smoothing costs almost nothing to look at, and "
                            + "blotches are the artefact nobody wants to see.")
                DevelopNote("Detail raises the shrinkage threshold, so texture — and "
                            + "the noise beside it — survives. Contrast keeps coarse "
                            + "luminance structure at the cost of mottling. Colour "
                            + "Detail protects thin colour edges; Colour Smoothness "
                            + "reaches the large blotches, and it is the one row here "
                            + "with a measured cost — its guided pass follows "
                            + "luminance, so it softens a boundary that is pure colour.")
                DevelopNote("Hot Pixels replaces single-pixel outliers with the median "
                            + "of their neighbours, and only where the pixel is a "
                            + "strict extremum — an edge or a fine line always has a "
                            + "neighbour on its own side, so neither is touched.")
            }
        case .ai:
            VStack(alignment: .leading, spacing: 2) {
                LumenSlider(title: "Amount",
                            value: binder.value(\.develop.denoise.amount, "denoise.amount"),
                            range: 0...100, hardRange: nil, defaultValue: 50,
                            step: 1, decimals: 0, bipolar: false)
                // Tier 2 does not exist: no model ships, `AIDenoiseSplice` has no
                // caller, and Amount reaches the decoder's own denoise instead. That
                // is also why dragging it is slow — the stand-in is part of the decode
                // key, so each step re-demosaics the frame.
                //
                // And it reaches the RAW decoder only. `RenderedImageSource.decode`
                // takes the recipe and reads nothing out of it but the scale factor,
                // so on a rendered file this slider moves a value no stage consumes.
                // The note used to describe the raw behaviour for both.
                if isRenderedFile {
                    DevelopNote("On a rendered file this slider does nothing: no AI "
                                + "model ships, and the decoder stand-in Amount drives "
                                + "on raw files is part of the raw decode, which this "
                                + "file does not go through. Classic is the engine "
                                + "that runs here.",
                                prominent: true)
                } else {
                    DevelopNote("No AI model ships yet. Amount drives the raw decoder's "
                                + "own noise reduction as a stand-in, and because that "
                                + "is part of the decode, dragging it re-decodes the "
                                + "frame rather than blending a cached result.")
                }
                // Switching to AI zeroes the Tier-1 masters, on the reasoning that the
                // noise they compensate for is gone by then. That is invisible from
                // this screen, since the Classic rows are not on it — so it is said.
                DevelopNote("Turning this on drops the Classic Luminance and Colour to "
                            + "zero, unless you set them yourself — a hand-set value is "
                            + "kept. Luminance Detail, Contrast, Colour Detail, Colour "
                            + "Smoothness and Hot Pixels are untouched either way.")
                DevelopNote("Classic is the profiled engine and it runs on every frame "
                            + "and every export. It is the one to reach for until a "
                            + "model ships.")
            }
        }
    }
}

#endif
