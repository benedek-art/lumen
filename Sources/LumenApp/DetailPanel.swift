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
// Optional-field policy (CaptureSharpen.amount): nil means "measured from the frame's
// own greens" — a real number that only the decode knows. The Amount row stands in the
// engine's own 100 while the field is nil and badges the section AUTO; the first move
// pins a concrete value, and "Use measured values" writes nil back.
//
// There is no Radius row and no Overrides fold, both deliberately.
// `CaptureSharpen.radius` reaches only `DetailEngine.captureSharpen`, which has no
// caller — the RAW stage reads `strengthFraction` and nothing else — so the control
// stored a number no stage read, and the panel had to carry a paragraph saying so. A
// fold whose two rows were one live control and one dead one is depth bought with a
// lie. Both come back with the stage.
//
// All three belong to Develop's Detail (docs/28 §5.1), and Denoise is a fold inside it
// rather than a section of its own — which is the difference between Develop being six
// rows deep and being eight. `only` is how the column asks for the section; the panel
// answers all-or-nothing, because it owns exactly one.

#if os(macOS)

import Foundation
import LumenCore
import SwiftUI

/// What the capture-sharpen Amount row shows while the recipe says "auto" — the
/// engine's own default strength.
///
/// 100, not 50: both readers of `CaptureSharpen.amount` treat nil as 100
/// (`DetailEngine.captureSharpen`, `AppleRawSource`). Showing 50 while auto renders at
/// 100 meant the first nudge of the slider halved the sharpening.
private let captureAmountStandIn: Double = 100

struct DetailPanel: View {
    @EnvironmentObject var state: AppState
    /// This surface shows the edit, so it observes the edit signal —
    /// `AppState.recipes` is deliberately not published (see `EditRevision`).
    @EnvironmentObject var edits: EditRevision

    /// Denoise starts closed. A fold that opens by itself gives back the depth it was
    /// folded away to save, and these are rows a photographer sets once per ISO.
    @State private var noiseExpanded = false

    private var binder: RecipeBinder { RecipeBinder(state: state) }
    private var recipe: Recipe { state.currentRecipe }

    /// The one section the column wants drawn. nil renders every section this panel
    /// owns, which is what the tab did.
    var only: WorkspaceSection?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if only == nil || only == .detail {
                captureSection
                manualSection
                noiseSection
            }
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
                if recipe.develop.detail.capture.auto { captureOverrides }
            }
        }
    }

    private var captureOverrides: some View {
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

            // Optional-backed, where nil means "use the measured value", so
            // double-clicking to reset must CLEAR rather than write the stand-in —
            // writing it pins an override and only flips the badge from Auto to Manual.
            // The range is the engine's 0…150 rather than stopping at the default.
            LumenSlider(title: "Amount",
                        value: binder.value(\.develop.detail.capture.amount,
                                            "detail.capture.amount",
                                            orAuto: captureAmountStandIn),
                        range: 0...150, hardRange: nil,
                        defaultValue: captureAmountStandIn,
                        step: 1, decimals: 0, bipolar: false,
                        onReset: { clearCaptureOverrides() })
        }
    }

    private var hasCaptureOverride: Bool {
        recipe.develop.detail.capture.radius != nil
            || recipe.develop.detail.capture.amount != nil
    }

    private var isCaptureModified: Bool {
        recipe.develop.detail.capture != CaptureSharpen()
    }

    /// Clears `radius` as well, though no control writes it now: a recipe from another
    /// build can carry one, and "Use measured values" must mean all of them.
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
                // Radius here is in RAW PIXELS and the band steps are fixed pixel
                // counts, while every other spatial stage in the graph sizes itself
                // off the long edge. A preview is also capped at 4096 px, so no view in
                // this application — 1:1 included — shows a 45 MP export's sharpening.
                // The person that costs is the one judging an export by a preview, and
                // this is the row they are looking at when it costs them.
                LumenSlider(title: "Radius",
                            value: binder.value(\.develop.detail.sharpen.radius,
                                                "detail.sharpen.radius"),
                            range: 0.5...3.0, hardRange: nil, defaultValue: 1.0,
                            step: 0.1, decimals: 1, bipolar: false)
                    .help("Pixels, not a fraction of the frame, so a full-size export is "
                          + "less sharpened than the preview it was judged on — and "
                          + "previews cap at 4096 px.")
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
                // Nothing when capture sharpening is on: it owns the baseline, which
                // is why Amount above starts at 0. The hint is for the refugee who has
                // no capture stage and no starting point.
                if !recipe.develop.detail.capture.auto { lightroomClassicHint }
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
        }
        // No row at all when there is no profiled ISO — a rendered file, or one that
        // records none. The three branches that used to be here were sentences saying
        // why there is no number, which is a paragraph in place of a blank.
    }

    /// A `DevelopDisclosure` rather than a `DevelopSection`, because the disclosure
    /// supplies its own header and two stacked headings both reading "Noise Reduction"
    /// is the one thing this fold must not produce.
    ///
    /// What went with the section is worth naming: the modified dot and the Reset that
    /// put the whole of Denoise back to the ISO profile. A disclosure has nowhere to
    /// hang either, so the coarse reset is gone and what is left is the per-slider
    /// double-click — which lands on the same ISO-adaptive numbers, one row at a time.
    private var noiseSection: some View {
        DevelopDisclosure("Noise Reduction", isExpanded: $noiseExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                LumenSegmented(options: [(value: Denoise.Mode.off, label: "Off"),
                                         (value: Denoise.Mode.classic, label: "Classic"),
                                         (value: Denoise.Mode.ai, label: "AI (stand-in)")],
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
            // Off means off, Hot Pixels included — there is nothing to draw and nothing
            // to say about it.
            EmptyView()
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
                    .help("Raises the shrinkage threshold, so texture survives — and so "
                          + "does the noise beside it.")
                LumenSlider(title: "Luminance Contrast",
                            value: binder.value(\.develop.denoise.classic.lumaContrast,
                                                "denoise.classic.lumaContrast"),
                            range: 0...100, hardRange: nil,
                            defaultValue: isoDefault.classic.lumaContrast,
                            step: 1, decimals: 0, bipolar: false)
                    .help("Keeps coarse luminance structure, at the cost of mottling.")
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
                    .help("Protects thin colour edges.")
                LumenSlider(title: "Colour Smoothness",
                            value: binder.value(\.develop.denoise.classic.colorSmoothness,
                                                "denoise.classic.colorSmoothness"),
                            range: 0...100, hardRange: nil,
                            defaultValue: isoDefault.classic.colorSmoothness,
                            step: 1, decimals: 0, bipolar: false)
                    // The one row here with a cost worth naming, so it is named on the
                    // row rather than in a paragraph four rows below it.
                    .help("Reaches the large blotches. Its guided pass follows "
                          + "luminance, so it softens a boundary that is pure colour.")
                LumenSlider(title: "Hot Pixels",
                            value: binder.value(\.develop.denoise.classic.hotPixels,
                                                "denoise.classic.hotPixels"),
                            range: 0...100, hardRange: nil, defaultValue: 0,
                            step: 1, decimals: 0, bipolar: false)
            }
        case .ai:
            VStack(alignment: .leading, spacing: 2) {
                // Tier 2 does not exist: no model ships, `AIDenoiseSplice` has no
                // caller, and Amount reaches the decoder's own denoise instead — which
                // is why dragging it is slow, the stand-in being part of the decode key,
                // so each step re-demosaics the frame. The segment above says
                // "(stand-in)" so that fact is on the control that offers the mode,
                // where it costs no rows and is read before anything is dragged.
                //
                // And it reaches the RAW decoder only: `RenderedImageSource.decode`
                // takes the recipe and reads nothing out of it but the scale factor, so
                // on a rendered file this slider moves a value no stage consumes. That
                // is a different sentence, and the only place it belongs is the row.
                LumenSlider(title: "Amount",
                            value: binder.value(\.develop.denoise.amount, "denoise.amount"),
                            range: 0...100, hardRange: nil, defaultValue: 50,
                            step: 1, decimals: 0, bipolar: false)
                    .help(isRenderedFile
                          ? "The stand-in is part of the raw decode, which this file "
                              + "does not go through, so Amount changes nothing here. "
                              + "Classic is the engine that runs."
                          : "No model ships yet: Amount drives the raw decoder's own "
                              + "noise reduction, and because that is part of the "
                              + "decode, each step re-decodes the frame.")
                // Switching to AI zeroes the Tier-1 masters unless they were hand-set
                // — `ISODefaults.coupled` owns that rule and its tests — on the
                // reasoning that the noise they compensate for is gone by then. It is
                // invisible from this screen, since the Classic rows are not on it, and
                // it was two more sentences under a slider that already has one.
            }
        }
    }
}

#endif
