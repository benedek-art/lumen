// EffectsPanel.swift
// Vignette, film grain, crop/straighten and lens corrections — the creative and
// geometric layers, in pipeline order (S13 effects, S16 geometry).
//
// Two things this panel makes visible that most editors hide:
//   · The vignette is denominated in EV. A −0.7 EV edge burn means the same thing on
//     every exposure, and because the display transform is hue-preserving, darkened
//     corners do not colour-shift — so there is no "Highlight Priority / Colour
//     Priority" dropdown to explain. Position in the pipeline does that work.
//   · Geometry runs last, so dragging a crop re-runs one warp of an already-rendered
//     buffer rather than the pipeline. Crop, straighten, perspective and lens
//     distortion compose into a single resample.
//
// Optional-field policy: `Look.filmLab` nil means no stock is loaded, so the grain
// rows are absent rather than dead — grain belongs to a stock, not to the frame.
//
// The same rule, applied harder, is why Lens Corrections shows one control. Remove
// chromatic aberration and the seven Defringe controls were live, wrote the recipe, and
// reached no stage; the CA toggle was on by default and its tooltip described the
// polynomial fit it does not perform. They are gone until a stage reads them.

#if os(macOS)

import Foundation
import LumenCore
import SwiftUI

// MARK: - Aspect ratios

/// The standard ratio list (docs/09 §13.1), in Lightroom's order. `ratio` is
/// width ÷ height in *image* pixels; nil is Original, which clears the crop.
private struct CropAspect: Identifiable {
    let name: String
    let ratio: Double?

    var id: String { name }
}

private let cropAspects: [CropAspect] = [
    CropAspect(name: "Original", ratio: nil),
    CropAspect(name: "1:1", ratio: 1.0),
    CropAspect(name: "5:4", ratio: 5.0 / 4.0),
    CropAspect(name: "4:3", ratio: 4.0 / 3.0),
    CropAspect(name: "3:2", ratio: 3.0 / 2.0),
    CropAspect(name: "7:5", ratio: 7.0 / 5.0),
    CropAspect(name: "16:9", ratio: 16.0 / 9.0),
    CropAspect(name: "16:10", ratio: 16.0 / 10.0),
]

/// The frame aspect the ratio menu falls back to before the real one is known.
///
/// The crop rectangle is stored normalized to the source frame, so turning "3:2" into a
/// rectangle needs the frame's own aspect. `AppState.primaryFrameAspect` supplies it
/// from the decoded dimensions; this covers the moment before that lands, and the case
/// where there is no selection at all. It is right for most of the corpus and wrong in
/// a visible way — not the silent way it was wrong when it was the ONLY path.
private let assumedFrameAspect: Double = 3.0 / 2.0

// MARK: - Effects panel

struct EffectsPanel: View {
    @EnvironmentObject var state: AppState

    /// Width ÷ height of the decoded frame, when the caller knows it. Overrides the
    /// live value from `state` — nothing passes it today, and it exists so the ratio
    /// maths can be exercised against a frame that is not on screen.
    var frameAspect: Double?

    /// What the ratio menu actually measures against: an explicit override, else the
    /// primary selection's real decoded aspect, else the 3:2 assumption.
    ///
    /// The assumption used to be the only path. `EffectsPanel` is constructed with no
    /// argument, so `frameAspect` was always nil and every ratio was computed against
    /// 3:2 — wrong on every 4:3 body and on every portrait-orientation frame.
    private var effectiveFrameAspect: Double {
        frameAspect ?? state.primaryFrameAspect ?? assumedFrameAspect
    }

    @State private var showGrain: Bool = false

    /// The ruler button arms an overlay that lives in the viewer, so this panel needs a
    /// handle on the same viewport the keymap drives.
    @ObservedObject private var viewport: LoupeViewport = LoupeViewport.shared

    private var binder: RecipeBinder { RecipeBinder(state: state) }
    private var recipe: Recipe { state.currentRecipe }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            vignetteSection
            grainSection
            cropSection
            lensSection
            retouchSection
            proofSection
        }
    }

    // MARK: Vignette

    private var vignetteSection: some View {
        DevelopSection("Vignette", isModified: recipe.look.vignette != 0,
                       onReset: { binder.edit("look.vignette.reset") {
                           $0.look.vignette = 0
                       } }) {
            VStack(alignment: .leading, spacing: 2) {
                LumenSlider(title: "Amount",
                            value: binder.value(\.look.vignette, "look.vignette"),
                            range: -3.0...1.0, hardRange: nil, defaultValue: 0,
                            step: 0.01, decimals: 2)
                DevelopNote("Stops at the corner, applied on scene-linear data before "
                            + "the display transform, with the ellipse taken from the "
                            + "crop rectangle so it stays centred on what you see. A "
                            + "straighten angle shifts it slightly — the crop is "
                            + "measured on the straightened frame and this stage runs "
                            + "before the rotation.")
            }
        }
    }

    // MARK: Film grain

    @ViewBuilder
    private var grainSection: some View {
        DevelopSection("Grain", isModified: isGrainModified, onReset: grainReset) {
            if let film = recipe.look.filmLab {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Stock")
                            .font(.system(size: 10))
                            .foregroundStyle(Lumen.secondaryText)
                        Spacer()
                        LumenBadge(text: FilmStock.named(film.stock)?.name ?? film.stock)
                    }
                    .frame(height: Lumen.rowHeight)

                    LumenSlider(title: "Amount",
                                value: binder.custom("look.grain.amount",
                                                     get: { r in r.look.filmLab?.grain.amount ?? 0 },
                                                     set: { r, v in r.look.filmLab?.grain.amount = v }),
                                // The stock's own grain, matching LookPanel — the
                                // two panels bind the SAME field and disagreed about
                                // its default, so after picking Portra 400 one read
                                // "modified" and the other "default", and
                                // double-clicking reset it to two different numbers.
                                range: 0...100, hardRange: nil,
                                defaultValue: grainDefault,
                                step: 1, decimals: 0, bipolar: false)
                    LumenSlider(title: "Size",
                                value: binder.custom("look.grain.size",
                                                     get: { r in r.look.filmLab?.grain.size ?? 1 },
                                                     set: { r, v in r.look.filmLab?.grain.size = v }),
                                range: 0.5...2.0, hardRange: nil, defaultValue: 1.0,
                                step: 0.05, decimals: 2, bipolar: true)
                    // The CONCLUSION here was right and the mechanism was backwards.
                    // This said "Grain is anchored to print size", and `LookPanel`'s
                    // caption on the same field said the print size cancels out — which
                    // it does, algebraically, out of `plateScale`, pinned to 1e-12 by
                    // `testGrainFollowsTheGateAndTheRenderSizeNotThePrintSize`. What
                    // keeps the character constant is the other half: the footprint is
                    // denominated at the GATE and scales with the render's pixel count,
                    // so it is the same fraction of the picture at every size. Two
                    // panels binding one value must not tell opposite stories about it.
                    DevelopNote("Size is the grain pitch at the gate relative to the "
                                + "stock's own. The footprint is anchored to the gate "
                                + "and scales with the render, so grain keeps its "
                                + "character whatever size the picture is delivered at.")
                }
            } else {
                DevelopNote("Grain belongs to a film stock, not to the frame. Load a "
                            + "stock in the Look panel and its amount and size appear "
                            + "here.")
            }
        }
    }

    /// The loaded stock's own grain amount — the same default `LookPanel` uses for the
    /// same field. Two panels binding one value must agree about what neutral is, or
    /// one of them shows "modified" while the other shows "default" for one number.
    private var grainDefault: Double {
        FilmStock.named(recipe.look.filmLab?.stock ?? "")?.grainDefault ?? 0
    }

    private var isGrainModified: Bool {
        guard let film = recipe.look.filmLab else { return false }
        return film.grain != FilmGrain(size: 1.0, amount: grainDefault)
    }

    private var grainReset: (() -> Void)? {
        guard recipe.look.filmLab != nil else { return nil }
        // Reset lands on the STOCK's grain, the same number `isGrainModified`
        // compares against and the Amount slider calls default. It wrote FilmGrain()
        // (amount 0) — so the section stayed marked modified after its own Reset,
        // and the two reset affordances in one section landed on two different
        // numbers.
        let neutral = FilmGrain(size: 1.0, amount: grainDefault)
        return {
            binder.edit("look.grain.reset") { recipe in
                recipe.look.filmLab?.grain = neutral
            }
        }
    }

    // MARK: Crop & straighten

    private var cropSection: some View {
        DevelopSection("Crop", isModified: isGeometryModified, onReset: { resetGeometry() }) {
            VStack(alignment: .leading, spacing: 2) {
                aspectRow
                LumenSlider(title: "Angle",
                            value: binder.value(\.develop.geometry.angle, "geometry.angle"),
                            range: -45...45, hardRange: nil, defaultValue: 0,
                            step: 0.1, decimals: 1)
                rulerRow
                LumenToggleRow(title: "Flip horizontal",
                               isOn: binder.flag(\.develop.geometry.flipH, "geometry.flipH"),
                               // "Orientation flips with X inside the crop tool" was
                               // false in the way that costs the most: X IS bound —
                               // to the reject flag, everywhere, with no crop-mode
                               // branch anywhere in `Keymap`. A photographer following
                               // this tip inside the crop tool rejects the photograph
                               // they are cropping. Portrait/landscape crop swapping
                               // does not exist at all (GEO-04); the ratio menu offers
                               // only landscape-oriented ratios.
                               help: "Mirror the frame. This is a mirror, not a "
                                   + "rotation — swapping a crop between portrait and "
                                   + "landscape is not built yet.")
                DevelopNote("Crop and rotation compose into one Lanczos-3 resample that "
                            + "runs last, so every upstream cache is crop-independent. "
                            + "Perspective correction is not implemented: `Upright` is a "
                            + "wire format with no stage behind it, so there are no "
                            + "sliders for it here.")
            }
        }
    }

    /// Arms the ruler and opens the crop tool, which is where it lives — the loupe shows
    /// the whole straightened frame while R is open, and that is the frame the angle is
    /// expressed in.
    ///
    /// docs/09 binds this to ⌘-drag inside crop mode. It is an explicit arm here instead,
    /// because a modifier-qualified drag is a gesture nobody can discover and a button
    /// that says "Ruler" is one they can. The gesture itself is the specced one: drag a
    /// line, and the frame levels to whichever axis the line is nearer.
    private var rulerRow: some View {
        HStack(spacing: 6) {
            Text("Ruler")
                .font(.system(size: 11))
                .foregroundStyle(Lumen.secondaryText)
                .frame(width: Lumen.labelWidth, alignment: .leading)
            Button(viewport.showStraighten ? "Drag a line…" : "Straighten by line") {
                state.showLoupe()
                viewport.showCrop = true
                viewport.showStraighten.toggle()
            }
            .font(.system(size: 10))
            .help("Drag along a horizon or a doorframe and the frame levels to whichever "
                  + "axis that line is nearer. The angle it writes is the one in the "
                  + "slider above — nothing is hidden behind it.")
            Spacer()
        }
        .frame(height: Lumen.rowHeight)
    }

    private var aspectRow: some View {
        HStack(spacing: 6) {
            Text("Aspect")
                .font(.system(size: 11))
                .foregroundStyle(Lumen.secondaryText)
                .frame(width: Lumen.labelWidth, alignment: .leading)
            Menu {
                ForEach(cropAspects) { aspect in
                    Button(aspect.name) { applyAspect(aspect) }
                }
            } label: {
                Text(currentAspectName)
                    .font(.system(size: 10))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Ratios are measured against the real frame aspect rather than an
            // assumed 3:2. Free-form dragging is on the image, under R.
            .help("Standard ratios, centred on the frame. Press R to crop freely on "
                  + "the image.")
        }
        .frame(height: Lumen.rowHeight)
    }

    /// Reports what the stored rectangle *is*, not what was last clicked — the same
    /// grammar the white-balance preset row uses.
    private var currentAspectName: String {
        let geometry = recipe.develop.geometry
        if geometry.crop == Crop() { return "Original" }
        // Against the USABLE frame at the current angle, which is what the crop is a
        // fraction of. Reading it back against the source's own aspect makes the menu
        // disagree with the rectangle it just wrote as soon as the photo is straightened.
        guard let size = frameSizeForCrop,
              let ratio = CropGeometry.displayedAspect(geometry.crop,
                                                       sourceWidth: size.width,
                                                       sourceHeight: size.height,
                                                       degrees: geometry.angle)
        else { return "Custom" }
        for aspect in cropAspects {
            if let target = aspect.ratio, abs(target - ratio) < 0.005 {
                return aspect.name
            }
        }
        return "Custom"
    }

    /// The source frame in pixels, which the crop arithmetic needs — an aspect alone is
    /// not enough once a straighten angle is involved, because the inscribed rectangle
    /// depends on both edges.
    private var frameSizeForCrop: (width: Double, height: Double)? {
        if let size = state.primaryFrameSize, size.width > 0, size.height > 0 {
            return (Double(size.width), Double(size.height))
        }
        let aspect = effectiveFrameAspect
        guard aspect > 0 else { return nil }
        return (aspect, 1)
    }

    private func applyAspect(_ aspect: CropAspect) {
        guard let size = frameSizeForCrop else { return }
        // The lock is a mode the user chose, so picking a ratio arms it and "Original"
        // clears it. Without it the menu wrote a 3:2 rectangle and the very next corner
        // drag made it free-form again, after which the menu read it back as "Custom".
        viewport.cropAspectLock = aspect.ratio
        binder.edit("geometry.crop.aspect") { recipe in
            guard let ratio = aspect.ratio, ratio > 0 else {
                recipe.develop.geometry.crop = Crop()
                return
            }
            recipe.develop.geometry.crop = CropGeometry.centred(
                aspect: ratio, sourceWidth: size.width, sourceHeight: size.height,
                degrees: recipe.develop.geometry.angle)
        }
    }

    private var isGeometryModified: Bool {
        let geometry = recipe.develop.geometry
        return geometry.crop != Crop() || geometry.angle != 0 || geometry.flipH
    }

    private func resetGeometry() {
        // Outside the edit closure: that one mutates a recipe and may not run here, and
        // the lock is view state.
        viewport.cropAspectLock = nil
        binder.edit("geometry.reset") { recipe in
            recipe.develop.geometry.crop = Crop()
            recipe.develop.geometry.angle = 0
            recipe.develop.geometry.flipH = false
        }
    }

    // MARK: Lens corrections

    private var lensSection: some View {
        DevelopSection("Lens Corrections",
                       isModified: recipe.develop.geometry.lens != LensCorrections(),
                       onReset: { binder.edit("geometry.lens.reset") {
                           $0.develop.geometry.lens = LensCorrections()
                       } }) {
            VStack(alignment: .leading, spacing: 2) {
                LumenToggleRow(title: "Built-in profile",
                               isOn: binder.flag(\.develop.geometry.lens.profile,
                                                 "geometry.lens.profile"),
                               help: "Applies the correction opcodes and manufacturer "
                                   + "profile embedded in the file, at decode.")
                DevelopNote("No lens-profile database in v1, and Lumen never refuses a "
                            + "file: a lens we have no profile for still develops, "
                            + "uncorrected and honest about it.")
                // Not shown: Remove chromatic aberration, and the seven controls under
                // Defringe. `removeCA` and every field of `Defringe` have a wire format
                // and no reader — grep across Sources/ finds them only in the `Recipe`
                // struct — and `lens.profile` is the one thing in this section that is
                // genuinely consumed, at decode.
                //
                // A footnote admitting that was not enough, and this section is the
                // reason the rule exists. The removed CA toggle DEFAULTED TO ON, so
                // every photo in the library carried a ticked box doing nothing, and
                // its own tooltip described the machinery in detail — "R and B are
                // re-registered to G by a radial polynomial fit, folded into the
                // geometry warp" — two rows above the note conceding none of it runs.
                // A reader who trusts the control loses the time it takes to find out,
                // and one who trusts the footnote is left wondering which half of the
                // panel to believe. `MaskPanel` had already settled the form for the
                // local group: take the controls out, keep the sentence.
                DevelopNote("Remove chromatic aberration and Defringe are not shown: "
                            + "neither is wired to a stage, so nothing they store "
                            + "reaches a pixel. They come back when the correction "
                            + "does. Lens profile corrections do apply, at decode.")
            }
        }
    }

    // MARK: Retouch

    /// No controls, on purpose.
    ///
    /// `Heal { strokesRef, count }` is declared in the recipe and reaches no stage on any
    /// path — there is no writer, no blob loader and no renderer for it. A slider that
    /// stored spots nothing removed would be worse than this note, because absence is
    /// honest and a dead control is not. The note exists so that somebody looking for the
    /// spot-removal tool learns it is missing here rather than concluding they cannot
    /// find it.
    private var retouchSection: some View {
        DevelopSection("Retouch", isModified: false, onReset: nil) {
            // Prominent: the whole point of this note is that someone hunting for
            // the spot-removal tool LEARNS it is missing — behind the hover-ⓘ they
            // find an empty section and conclude they cannot find the tool, the
            // exact outcome the note was written to prevent.
            DevelopNote("Heal and clone are not implemented. The recipe format reserves "
                        + "them, and nothing renders them — a file that arrives carrying "
                        + "healed spots will show every spot still there. There is no "
                        + "control here rather than one that stores a value no stage "
                        + "reads.",
                        prominent: true)
        }
    }

    // MARK: Soft proof

    /// A viewing mode, not an edit (docs/11), which is why it binds to `AppState` and not
    /// through `binder` — it changes no recipe, appears in no undo step and is not copied
    /// with settings.
    private var proofSection: some View {
        DevelopSection("Soft Proof", isModified: state.softProof.enabled,
                       onReset: { state.softProof = SoftProof() }) {
            VStack(alignment: .leading, spacing: 2) {
                LumenToggleRow(title: "Soft proof", isOn: $state.softProof.enabled,
                               help: "⇧S. Renders the picture through the destination "
                                   + "space so you can see what the delivery will hold.")
                if state.softProof.enabled {
                    HStack(spacing: 6) {
                        Text("Destination")
                            .font(.system(size: 11))
                            .foregroundStyle(Lumen.secondaryText)
                            .frame(width: Lumen.labelWidth, alignment: .leading)
                        Picker("", selection: $state.softProof.space) {
                            ForEach(ExportColorSpace.allCases, id: \.self) { space in
                                Text(space.displayName).tag(space)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                    }
                    .frame(height: Lumen.rowHeight)

                    HStack(spacing: 6) {
                        Text("Intent")
                            .font(.system(size: 11))
                            .foregroundStyle(Lumen.secondaryText)
                            .frame(width: Lumen.labelWidth, alignment: .leading)
                        LumenSegmented(options: intentOptions,
                                       selection: $state.softProof.intent)
                    }
                    .frame(height: Lumen.rowHeight)

                    LumenToggleRow(title: "Gamut warning",
                                   isOn: $state.softProof.showGamutWarning,
                                   help: "Flat grey over every pixel the destination "
                                       + "cannot store.")
                    LumenToggleRow(title: "Simulate paper & ink",
                                   isOn: $state.softProof.simulatePaperWhite,
                                   help: "Brings white down to a sheet's reflectance and "
                                       + "black up to the ink's, which is the flatness a "
                                       + "print has and a screen does not.")
                    DevelopNote(proofNote)
                }
            }
        }
    }

    private var intentOptions: [(value: RenderingIntent, label: String)] {
        [(value: .perceptual, label: "Perceptual"),
         (value: .relativeColorimetric, label: "Relative")]
    }

    /// What the proof does and does not tell you. The second half matters: the loupe
    /// hands SwiftUI an sRGB image, so a destination at least as wide as sRGB looks
    /// almost the same proofed or not — the warning and the paper simulation are the
    /// parts that carry information there.
    private var proofNote: String {
        "The proof rides in the finish table both render paths apply, so what is on "
            + "screen is the picture through the destination's primaries. The gamut "
            + "warning is computed per pixel rather than baked, so its edge is the real "
            + "gamut boundary. Two limits: the loupe is drawn as an sRGB image, so "
            + "proofing to a space at least as wide as sRGB changes little on screen "
            + "beyond the warning and the paper simulation; and there is no ICC profile "
            + "behind \"paper & ink\" — it uses one documented white and black."
    }
}

#endif
