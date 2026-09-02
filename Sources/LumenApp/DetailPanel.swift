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
        VStack(alignment: .leading, spacing: Lumen.rowGap) {
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
            VStack(alignment: .leading, spacing: Lumen.rowGap) {
                LumenToggleRow(title: "Capture sharpening",
                               isOn: captureToggleBinding,
                               help: captureToggleHelp)
                if isRenderedFile {
                    renderedCaptureNote
                } else if recipe.develop.detail.capture.auto {
                    captureOverrides
                }
            }
            // DISABLED ON A RENDERED FILE — ON THIS STACK, WHICH IS THE FIX.
            //
            // The comment that used to stand above the toggle said the section was
            // disabled here. It was not: the only `.disabled(isRenderedFile)` in this
            // file sat on `captureOverrides`, so the badge row and Amount went grey and
            // THE TOGGLE STAYED LIVE. On every JPEG, HEIC and TIFF in the library it
            // moved, lit the section's modified dot, wrote the recipe and the sidecar
            // and spent an undo step, and changed the photograph by not one code value.
            // A comment is not a modifier, and this is how that survived: nothing could
            // fail. `CaptureSharpenScopeTests` now reads this line.
            //
            // Why it reaches nothing: both the toggle and the Amount row write fields
            // whose ONLY reader is `AppleRawSource` — the raw decoder — and a rendered
            // file goes through `RenderedImageSource`, whose whole `decode` reads
            // nothing out of the recipe but the scale factor. docs/06 §Capture
            // Sharpening has said so from the start: "on (raw only)", "off for
            // JPEG/HEIC (already sharpened in camera)". Only the code disagreed.
            //
            // `PhotoFormats.isRendered` is the SAME predicate
            // `RenderCoordinator.source(for:)` uses to choose between those two
            // decoders. That is deliberate and tested: a second copy of "is this file
            // already demosaiced" is a panel that can drift out of step with the
            // pipeline one extension at a time.
            //
            // The header's Reset is outside this stack and stays live, deliberately. A
            // recipe written by another build can arrive carrying capture edits, the
            // dot lights for them truthfully — the recipe really does differ — and the
            // photographer has to be able to put them back.
            .disabled(isRenderedFile)
        }
    }

    /// The switch's binding — a constant OFF on a rendered file, rather than the
    /// recipe's `auto`.
    ///
    /// `CaptureSharpen()` defaults `auto` to true, so simply disabling the row would
    /// leave a switch stuck in the ON position on every JPEG in the library: the same
    /// claim the live toggle was making — that a stage is running on this photograph —
    /// said more quietly. Off is what is true of the picture, and it is what docs/06
    /// specifies for these files. The recipe field is untouched either way; nothing
    /// here writes, which is the point.
    ///
    /// Computed rather than a ternary in the argument list, with the two `help`
    /// strings below and for the same reason: `check-swift-surface.py` has a verified
    /// blind spot on multi-line ternary ARGUMENTS (docs/31 postscript), so branching
    /// stays out of call sites in this file.
    private var captureToggleBinding: Binding<Bool> {
        guard !isRenderedFile else { return .constant(false) }
        return binder.flag(\.develop.detail.capture.auto, "detail.capture.auto")
    }

    /// The toggle's tooltip.
    ///
    /// The non-raw branch is new; the raw branch had a claim in it that stopped being
    /// true. It read "has no caller and no test", and half of that is now false:
    /// `FieldBaselineProbeTests` renders a blurred edge through
    /// `DetailEngine.captureSharpen` — and so through `richardsonLucy` — and asserts it
    /// recovers the edge. What survives is narrower and worth stating exactly, because
    /// the argument for this panel is that its disclosures can be checked: the
    /// deconvolution has a baseline probe and no caller, and the per-frame radius
    /// measurement has neither, since that probe pins a radius rather than measuring
    /// one.
    private var captureToggleHelp: String {
        if isRenderedFile {
            return "Capture sharpening happens inside the raw decode, which this file "
                + "does not go through — it was demosaiced and sharpened in the camera, "
                + "so there is nothing here for this stage to undo. Sharpening below "
                + "does run on this file."
        }
        return "Scales the decoder's own at-demosaic sharpener. Lumen's own "
            + "measured-PSF deconvolution has a baseline probe in the test suite but no "
            + "caller, and the per-frame radius measurement has neither, so no radius "
            + "is measured for this frame in this build."
    }

    /// The reason, on the panel rather than only in a tooltip.
    ///
    /// A greyed row says "you cannot use this" and nothing else; a photographer who has
    /// to hover a dead control to learn why it is dead has already spent the time the
    /// disable was meant to save him. This is the same shape as the badge row it stands
    /// in for — caption left, badge right, one row tall — so the section keeps its
    /// rhythm as the selection moves between a raw file and a JPEG, and the Amount
    /// slider is not drawn at all rather than drawn grey.
    private var renderedCaptureNote: some View {
        HStack(spacing: 6) {
            Text("Already demosaiced — no capture stage to scale")
                .font(.lumenCaption)
                .foregroundStyle(Lumen.secondaryText)
            Spacer()
            LumenBadge(text: "Raw only")
        }
        .frame(height: Lumen.rowHeight)
        .help(captureStateHelp)
    }

    private var captureOverrides: some View {
        VStack(alignment: .leading, spacing: Lumen.rowGap) {
            // The badge row explains itself on hover — the owner's report was "the
            // Auto for the measured is just kind of sitting there and I'm not really
            // sure what that does." The caption now says where the values come from,
            // and the row's help says what Auto means and how to leave or return to
            // it. Nothing in this row lights up, because nothing in it is clickable
            // except the "Use measured values" button, which carries its own help.
            HStack(spacing: 6) {
                Text(hasCaptureOverride ? "Manual" : "Measured from the file")
                    .font(.lumenCaption)
                    .foregroundStyle(Lumen.secondaryText)
                Spacer()
                if hasCaptureOverride {
                    Button("Use measured values") { clearCaptureOverrides() }
                        .buttonStyle(.plain)
                        .font(.lumenCaption)
                        .foregroundStyle(Lumen.accent)
                        .help("Clears the hand-set Amount back to the strength the "
                              + "decode measured")
                } else {
                    LumenBadge(text: "Auto")
                }
            }
            .frame(height: Lumen.rowHeight)
            .help(captureStateHelp)

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
                        help: captureAmountHelp,
                        onReset: { clearCaptureOverrides() })
        }
        // No `.disabled(isRenderedFile)` here any more. It moved up to the section's
        // stack, which is what covers the toggle as well — and leaving a copy behind
        // would be a second answer to the same question in the same file, which is the
        // shape of the defect this fix closed. These rows are not drawn at all on a
        // rendered file now; `renderedCaptureNote` stands where they were.
    }

    /// What the Auto/Manual badge row means, said on the row itself — and, in its first
    /// branch, what the "Raw only" row that replaces it on a rendered file means. Three
    /// states, so it is a computed property rather than a ternary in the argument —
    /// `check-swift-surface.py` has a verified blind spot on multi-line ternary
    /// arguments (docs/31 postscript), so branching help stays out of call sites.
    private var captureStateHelp: String {
        if isRenderedFile {
            return "Capture sharpening is part of the raw decode, which a JPEG, HEIC or "
                + "TIFF does not go through — so no capture stage runs on this "
                + "photograph and the switch above is off and disabled. Manual "
                + "sharpening below does run."
        }
        if hasCaptureOverride {
            return "Manual — a hand-set Amount is overriding the strength the decode "
                + "measured. \u{201C}Use measured values\u{201D} clears it."
        }
        return "Auto — measured from the file: the raw decode sets this frame's "
            + "capture sharpening itself, and Amount is applying it at full measured "
            + "strength. The first move pins a manual value."
    }

    /// Amount's tooltip, branching on file type the way the AI-denoise row already
    /// does — and kept out of the argument for the same checker-blind-spot reason as
    /// `captureStateHelp`.
    ///
    /// The `isRenderedFile` branch is no longer reachable from this panel: the row it
    /// belongs to is not drawn on a rendered file at all now. Kept rather than deleted
    /// because it is the true sentence for that state, and it is the row's own answer
    /// if the gate above it is ever loosened.
    private var captureAmountHelp: String {
        if isRenderedFile {
            return "Capture sharpening is part of the raw decode, which this file "
                + "does not go through — so this changes nothing here. Manual "
                + "sharpening below does run."
        }
        return "Scales the sharpening the raw decode measured for this frame: 100 "
            + "applies it exactly as measured, lower backs it off, higher pushes "
            + "past it. Reset clears a hand-set value back to measured."
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
            VStack(alignment: .leading, spacing: Lumen.rowGap) {
                LumenSlider(title: "Amount",
                            value: binder.value(\.develop.detail.sharpen.amount,
                                                "detail.sharpen.amount"),
                            range: 0...150, hardRange: nil, defaultValue: 0,
                            step: 1, decimals: 0, bipolar: false,
                            help: "The strength of manual sharpening — the gain on "
                                + "the edge pass the three rows below shape, applied "
                                + "late so masked clarity is never double-sharpened. "
                                + "It starts at 0 because capture sharpening owns the "
                                + "baseline.")
                // Radius here is in RAW PIXELS and the band steps are fixed pixel
                // counts, while every other spatial stage in the graph sizes itself
                // off the long edge. A preview is also capped at 4096 px, so no view in
                // this application — 1:1 included — shows a 45 MP export's sharpening.
                // The person that costs is the one judging an export by a preview, and
                // this is the row they are looking at when it costs them.
                //
                // The warning moved from a `.help` MODIFIER onto the `help:` parameter,
                // with every other row here: an outer `.help` is shadowed by the
                // label's own composed tooltip, so hovering the slider's NAME — the
                // natural place to ask "what is this" — showed only the reset hint.
                LumenSlider(title: "Radius",
                            value: binder.value(\.develop.detail.sharpen.radius,
                                                "detail.sharpen.radius"),
                            range: 0.5...3.0, hardRange: nil, defaultValue: 1.0,
                            step: 0.1, decimals: 1, bipolar: false,
                            help: "How wide an edge the sharpening acts on, in pixels "
                                + "of the render — not a fraction of the frame, so a "
                                + "full-size export is less sharpened than the preview "
                                + "it was judged on, and previews cap at 4096 px.")
                LumenSlider(title: "Detail",
                            value: binder.value(\.develop.detail.sharpen.detail,
                                                "detail.sharpen.detail"),
                            range: 0...100, hardRange: nil, defaultValue: 25,
                            step: 1, decimals: 0, bipolar: true,
                            help: "Balances clean edge sharpening against the finest "
                                + "texture: low keeps to edges, high emphasises the "
                                + "finest detail — and the noise that lives at the "
                                + "same scale.")
                LumenSlider(title: "Masking",
                            value: binder.value(\.develop.detail.sharpen.masking,
                                                "detail.sharpen.masking"),
                            range: 0...100, hardRange: nil, defaultValue: 0,
                            step: 1, decimals: 0, bipolar: false,
                            help: "Confines sharpening to edges: at 0 everything is "
                                + "sharpened evenly, and raising it protects smooth "
                                + "areas — skin, sky — from being gritted up.")
                // The honest tense: the damp is measured landing mid-edge rather than
                // on the rim it exists for (the pinned defect record in
                // FieldBaselineProbeTests), so the tooltip must not promise a halo
                // cure the engine does not yet deliver. Reword when that test flips.
                LumenSlider(title: "Halo Suppression",
                            value: binder.value(\.develop.detail.sharpen.haloSuppression,
                                                "detail.sharpen.haloSuppression"),
                            range: 0...100, hardRange: nil, defaultValue: 0,
                            step: 1, decimals: 0, bipolar: false,
                            help: "Damps the bright side of a sharpened edge — where "
                                + "halos live — and never the dark side. In this build "
                                + "the damping lands mid-edge rather than on the rim "
                                + "itself, so it reads as a gentler sharpen more than "
                                + "a halo cure.")
                // Nothing when capture sharpening is on: it owns the baseline, which
                // is why Amount above starts at 0. The hint is for the refugee who has
                // no capture stage and no starting point.
                //
                // `isRenderedFile` first, because on a JPEG there is never a capture
                // stage whatever the recipe's `auto` says. While the hint keyed on that
                // field alone, an inert toggle decided whether the one piece of real
                // help on this screen appeared — the second-order cost of the toggle
                // being live, and it survives the toggle being disabled, because a
                // recipe from another build can still arrive with `auto` true.
                if isRenderedFile || !recipe.develop.detail.capture.auto {
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
                .font(.lumenCaption)
                .foregroundStyle(Lumen.secondaryText)
            Spacer()
            Button("Apply") { applyClassicSharpen() }
                .buttonStyle(.plain)
                .font(.lumenCaption)
                .foregroundStyle(Lumen.accent)
                .help("Writes the classic 40 / 1.0 / 25 / 0 into the four rows above")
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
                    .font(.lumenCaption)
                    .foregroundStyle(Lumen.secondaryText)
                Spacer()
                LumenBadge(text: recipe.develop.denoise == isoDefault ? "Auto" : "Manual")
            }
            .frame(height: Lumen.rowHeight)
            // The same self-explanation the capture badge row carries, for the same
            // reason: a badge that is not clickable owes the pointer an answer, not
            // an affordance.
            .help("Noise-reduction defaults follow the photo's ISO. Auto means the "
                  + "rows below still sit on the ISO \(Int(iso)) profile; Manual "
                  + "that at least one has been hand-set. Double-click a row to "
                  + "return it to the profile.")
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
            VStack(alignment: .leading, spacing: Lumen.rowGap) {
                LumenSegmented(options: [(value: Denoise.Mode.off, label: "Off"),
                                         (value: Denoise.Mode.classic, label: "Classic"),
                                         (value: Denoise.Mode.ai, label: "AI (stand-in)")],
                               selection: binder.choice(\.develop.denoise.mode,
                                                        "denoise.mode"))
                    .help("Which engine cleans the noise: Off is off, Classic is the "
                          + "wavelet engine the rows below tune, and the AI stand-in "
                          + "drives the raw decoder's own noise reduction until a "
                          + "model ships.")
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
            VStack(alignment: .leading, spacing: Lumen.rowGap) {
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
                            help: "The master strength of luminance smoothing — how "
                                + "hard grain is pushed down before the two rows "
                                + "below decide what survives. Its default follows "
                                + "the photo's ISO.",
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
                // NAMED FOR WHAT THEY DO, AND SUBORDINATE TO THEIR MASTER.
                //
                // They were `Luminance Detail`, `Luminance Contrast`, `Colour Detail`
                // and `Colour Smoothness`, and two of those measure past the label
                // column's shrink floor: `Luminance Contrast` is 104.3 pt at 11 pt in
                // an 86 pt frame and `Colour Smoothness` 102.4, so both rendered as
                // `Luminance C…` and `Colour S…` at every column width — the "two
                // controls indistinguishable without a hover" failure the column was
                // widened to avoid, arrived by another route.
                //
                // Widening the column again is the wrong lever: `labelWidth` is a fixed
                // frame that does not vary with the panel, so 104 would buy these two
                // rows their names at the cost of eighteen points of TRACK on all
                // ninety-two rows in the app. Naming them for what they do and indenting
                // them under the master they belong to costs nothing, and it is
                // Lightroom's own Detail panel layout: Luminance, then Detail and
                // Contrast; Colour, then Detail and Smoothness. Two rows read "Detail"
                // and that is correct — each sits directly under the master it details,
                // which is the whole point of the indent.
                //
                // These four also moved from `.help` modifiers onto the `help:` parameter:
                // the outer modifier is shadowed by the label's composed tooltip, so
                // hovering the row's NAME showed only the reset hint. The words are
                // unchanged where they were already right.
                LumenSlider(title: "Detail",
                            value: binder.value(\.develop.denoise.classic.lumaDetail,
                                                "denoise.classic.lumaDetail"),
                            range: 0...100, hardRange: nil,
                            defaultValue: isoDefault.classic.lumaDetail,
                            step: 1, decimals: 0, bipolar: false,
                            indented: true,
                            help: "Raises the shrinkage threshold, so texture survives "
                                + "— and so does the noise beside it.")
                LumenSlider(title: "Contrast",
                            value: binder.value(\.develop.denoise.classic.lumaContrast,
                                                "denoise.classic.lumaContrast"),
                            range: 0...100, hardRange: nil,
                            defaultValue: isoDefault.classic.lumaContrast,
                            step: 1, decimals: 0, bipolar: false,
                            indented: true,
                            help: "Keeps coarse luminance structure, at the cost of "
                                + "mottling.")
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
                            help: "The master strength of colour smoothing — the "
                                + "chroma speckle high ISO leaves — working on colour "
                                + "alone, so edges and texture stay put. Its default "
                                + "follows the photo's ISO.",
                            // Same clearing reset as Luminance above, same reason.
                            onReset: { binder.edit("denoise.classic.chroma") { recipe in
                                recipe.develop.denoise.classic.chroma =
                                    isoDefault.classic.chroma
                                recipe.develop.denoise.classic.chromaUserSet = false
                            } })
                LumenSlider(title: "Detail",
                            value: binder.value(\.develop.denoise.classic.colorDetail,
                                                "denoise.classic.colorDetail"),
                            range: 0...100, hardRange: nil,
                            defaultValue: isoDefault.classic.colorDetail,
                            step: 1, decimals: 0, bipolar: false,
                            indented: true,
                            help: "Protects thin colour edges.")
                // The one row here with a cost worth naming, so it is named on the
                // row rather than in a paragraph four rows below it.
                LumenSlider(title: "Smoothness",
                            value: binder.value(\.develop.denoise.classic.colorSmoothness,
                                                "denoise.classic.colorSmoothness"),
                            range: 0...100, hardRange: nil,
                            defaultValue: isoDefault.classic.colorSmoothness,
                            step: 1, decimals: 0, bipolar: false,
                            indented: true,
                            help: "Reaches the large blotches. Its guided pass follows "
                                + "luminance, so it softens a boundary that is pure "
                                + "colour.")
                LumenSlider(title: "Hot Pixels",
                            value: binder.value(\.develop.denoise.classic.hotPixels,
                                                "denoise.classic.hotPixels"),
                            range: 0...100, hardRange: nil, defaultValue: 0,
                            step: 1, decimals: 0, bipolar: false,
                            help: "Replaces lone pixels sitting far off their "
                                + "neighbours — the stuck bright or dark specks long "
                                + "exposures and high ISO leave. Raise it until they "
                                + "vanish; it only ever touches extremes.")
            }
        case .ai:
            VStack(alignment: .leading, spacing: Lumen.rowGap) {
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
                // On the `help:` parameter so the row's NAME answers the hover too,
                // and computed out of the argument — the branching text lives in
                // `aiAmountHelp`, because the surface checker's argument-order pass
                // has a verified blind spot on multi-line ternary arguments.
                LumenSlider(title: "Amount",
                            value: binder.value(\.develop.denoise.amount, "denoise.amount"),
                            range: 0...100, hardRange: nil, defaultValue: 50,
                            step: 1, decimals: 0, bipolar: false,
                            help: aiAmountHelp)
                // Switching to AI zeroes the Tier-1 masters unless they were hand-set
                // — `ISODefaults.coupled` owns that rule and its tests — on the
                // reasoning that the noise they compensate for is gone by then. It is
                // invisible from this screen, since the Classic rows are not on it, and
                // it was two more sentences under a slider that already has one.
            }
        }
    }

    /// The AI Amount tooltip — the two sentences that used to sit in a `.help`
    /// modifier's ternary, verbatim.
    private var aiAmountHelp: String {
        if isRenderedFile {
            return "The stand-in is part of the raw decode, which this file does not "
                + "go through, so Amount changes nothing here. Classic is the engine "
                + "that runs."
        }
        return "No model ships yet: Amount drives the raw decoder's own noise "
            + "reduction, and because that is part of the decode, each step "
            + "re-decodes the frame."
    }
}

#endif
