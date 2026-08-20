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
// `LensCorrections.defringe` nil means the axial-CA pass is not running; the
// disclosure's toggle creates the struct at its documented LR defaults (purple 30/70,
// green 40/60) and writes nil back when switched off.

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

    @State private var showDefringe: Bool = false
    @State private var showGrain: Bool = false

    private var binder: RecipeBinder { RecipeBinder(state: state) }
    private var recipe: Recipe { state.currentRecipe }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            vignetteSection
            grainSection
            cropSection
            lensSection
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
                            + "the display transform and masked to the crop rectangle, "
                            + "so it stays post-crop by construction.")
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
                                range: 0...100, hardRange: nil, defaultValue: 0,
                                step: 1, decimals: 0, bipolar: false)
                    LumenSlider(title: "Size",
                                value: binder.custom("look.grain.size",
                                                     get: { r in r.look.filmLab?.grain.size ?? 1 },
                                                     set: { r, v in r.look.filmLab?.grain.size = v }),
                                range: 0.5...2.0, hardRange: nil, defaultValue: 1.0,
                                step: 0.05, decimals: 2, bipolar: true)
                    DevelopNote("Size is the grain pitch at the gate relative to the "
                                + "stock's own. Grain is anchored to print size, so it "
                                + "does not change character when the export does.")
                }
            } else {
                DevelopNote("Grain belongs to a film stock, not to the frame. Load a "
                            + "stock in the Look panel and its amount and size appear "
                            + "here.")
            }
        }
    }

    private var isGrainModified: Bool {
        guard let film = recipe.look.filmLab else { return false }
        return film.grain != FilmGrain()
    }

    private var grainReset: (() -> Void)? {
        guard recipe.look.filmLab != nil else { return nil }
        return {
            binder.edit("look.grain.reset") { recipe in
                recipe.look.filmLab?.grain = FilmGrain()
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
                LumenToggleRow(title: "Flip horizontal",
                               isOn: binder.flag(\.develop.geometry.flipH, "geometry.flipH"),
                               help: "Mirror the frame. Orientation flips with X inside "
                                   + "the crop tool.")
                DevelopNote("Crop, rotation, perspective and lens distortion compose "
                            + "into one Lanczos-3 resample that runs last, so every "
                            + "upstream cache is crop-independent.")
            }
        }
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
            // The on-image crop tool is not reachable in this build — `showCrop` has no
            // writer — so this no longer sends the user looking for it. The ratios here
            // are the whole crop surface for now, and they are measured against the
            // real frame aspect rather than an assumed 3:2.
            .help("Standard ratios, centred on the frame. Free-form dragging on the "
                  + "image is not in this build.")
        }
        .frame(height: Lumen.rowHeight)
    }

    /// Reports what the stored rectangle *is*, not what was last clicked — the same
    /// grammar the white-balance preset row uses.
    private var currentAspectName: String {
        let crop = recipe.develop.geometry.crop
        if crop == Crop() { return "Original" }
        let frame = effectiveFrameAspect
        guard crop.h > 0 else { return "Custom" }
        let ratio = (crop.w * frame) / crop.h
        for aspect in cropAspects {
            if let target = aspect.ratio, abs(target - ratio) < 0.005 {
                return aspect.name
            }
        }
        return "Custom"
    }

    private func applyAspect(_ aspect: CropAspect) {
        let frame = effectiveFrameAspect
        binder.edit("geometry.crop.aspect") { recipe in
            guard let ratio = aspect.ratio, ratio > 0, frame > 0 else {
                recipe.develop.geometry.crop = Crop()
                return
            }
            // Largest centred rectangle of the requested ratio inside the frame,
            // expressed in the normalized source coordinates the recipe stores.
            var w = 1.0
            var h = 1.0
            if ratio >= frame {
                h = frame / ratio
            } else {
                w = ratio / frame
            }
            recipe.develop.geometry.crop = Crop(x: (1 - w) / 2, y: (1 - h) / 2, w: w, h: h)
        }
    }

    private var isGeometryModified: Bool {
        let geometry = recipe.develop.geometry
        return geometry.crop != Crop() || geometry.angle != 0 || geometry.flipH
    }

    private func resetGeometry() {
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
                LumenToggleRow(title: "Remove chromatic aberration",
                               isOn: binder.flag(\.develop.geometry.lens.removeCA,
                                                 "geometry.lens.removeCA"),
                               help: "Lateral CA: R and B are re-registered to G by a "
                                   + "radial polynomial fit, folded into the geometry "
                                   + "warp.")
                defringeDisclosure
                DevelopNote("No lens-profile database in v1, and Lumen never refuses a "
                            + "file: a lens we have no profile for still develops, "
                            + "uncorrected and honest about it.")
                // `removeCA` and every field under Defringe have a wire format and no
                // reader: grep across Sources/ finds them only in the `Recipe` struct.
                // `lens.profile` is the one thing here that is consumed, at decode.
                // Said plainly, the way `MaskPanel` says it about the local curve — a
                // control that stores a value and changes no pixel costs the user the
                // time to find that out.
                DevelopNote("Remove chromatic aberration and Defringe are not wired "
                            + "yet — they store their settings and no stage reads "
                            + "them. Lens profile corrections do apply, at decode.")
            }
        }
    }

    private var defringeDisclosure: some View {
        DevelopDisclosure("Defringe", isExpanded: $showDefringe) {
            VStack(alignment: .leading, spacing: 2) {
                LumenToggleRow(title: "Defringe",
                               isOn: binder.customFlag(
                                   "geometry.lens.defringe.enabled",
                                   get: { r in r.develop.geometry.lens.defringe != nil },
                                   set: { recipe, on in
                                       recipe.develop.geometry.lens.defringe =
                                           on ? Defringe() : nil
                                   }),
                               help: "Axial CA, computed in OKLCh on the two hue bands "
                                   + "that actually fringe.")
                if recipe.develop.geometry.lens.defringe != nil {
                    defringeRows
                }
            }
        }
    }

    private var defringeRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenSlider(title: "Purple",
                        value: defringeBinding("purpleAmount",
                                               get: { d in d.purpleAmount },
                                               set: { d, v in d.purpleAmount = v }),
                        range: 0...20, hardRange: nil, defaultValue: 0,
                        step: 1, decimals: 0, bipolar: false)
            LumenSlider(title: "Purple Hue Lo",
                        value: defringeBinding("purpleHueLo",
                                               get: { d in d.purpleHueLo },
                                               set: { d, v in d.purpleHueLo = v }),
                        range: 0...100, hardRange: nil, defaultValue: 30,
                        step: 1, decimals: 0, bipolar: true)
            LumenSlider(title: "Purple Hue Hi",
                        value: defringeBinding("purpleHueHi",
                                               get: { d in d.purpleHueHi },
                                               set: { d, v in d.purpleHueHi = v }),
                        range: 0...100, hardRange: nil, defaultValue: 70,
                        step: 1, decimals: 0, bipolar: true)
            LumenSlider(title: "Green",
                        value: defringeBinding("greenAmount",
                                               get: { d in d.greenAmount },
                                               set: { d, v in d.greenAmount = v }),
                        range: 0...20, hardRange: nil, defaultValue: 0,
                        step: 1, decimals: 0, bipolar: false)
            LumenSlider(title: "Green Hue Lo",
                        value: defringeBinding("greenHueLo",
                                               get: { d in d.greenHueLo },
                                               set: { d, v in d.greenHueLo = v }),
                        range: 0...100, hardRange: nil, defaultValue: 40,
                        step: 1, decimals: 0, bipolar: true)
            LumenSlider(title: "Green Hue Hi",
                        value: defringeBinding("greenHueHi",
                                               get: { d in d.greenHueHi },
                                               set: { d, v in d.greenHueHi = v }),
                        range: 0...100, hardRange: nil, defaultValue: 60,
                        step: 1, decimals: 0, bipolar: true)
        }
    }

    /// Defringe lives behind an optional struct, so its rows read through a default
    /// instance and write only when the struct exists.
    private func defringeBinding(_ field: String,
                                 get: @escaping (Defringe) -> Double,
                                 set: @escaping (inout Defringe, Double) -> Void)
        -> Binding<Double> {
        binder.custom("geometry.lens.defringe.\(field)",
                      get: { recipe in
                          get(recipe.develop.geometry.lens.defringe ?? Defringe())
                      },
                      set: { recipe, value in
                          var defringe = recipe.develop.geometry.lens.defringe ?? Defringe()
                          set(&defringe, value)
                          recipe.develop.geometry.lens.defringe = defringe
                      })
    }
}

#endif
