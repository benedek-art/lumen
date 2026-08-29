// EffectsPanel.swift
// Vignette, film grain, lens corrections and the soft proof — the creative layers, the
// one geometric correction that reaches a stage, and the check you make before you write
// the file.
//
// Two things this panel makes visible that most editors hide:
//   · The vignette is denominated in EV. A −0.7 EV edge burn means the same thing on
//     every exposure, and because the display transform is hue-preserving, darkened
//     corners do not colour-shift — so there is no "Highlight Priority / Colour
//     Priority" dropdown to explain. Position in the pipeline does that work.
//   · Geometry runs last, so a crop re-runs one warp of an already-rendered buffer
//     rather than the pipeline. Crop, straighten, perspective and lens distortion
//     compose into a single resample.
//
// Optional-field policy: `Look.filmLab` nil means no stock is loaded, so the grain
// rows are absent rather than dead — grain belongs to a stock, not to the frame. What
// stands in their place is the one move that leads anywhere from here: a button into
// Film Lab. A sentence explaining the emptiness leaves the photographer exactly where
// it found them, and the one that was here named a panel that no longer exists.
//
// The same rule, applied harder, is why Lens Corrections shows one control. Remove
// chromatic aberration and the seven Defringe controls were live, wrote the recipe, and
// reached no stage; the CA toggle was on by default and its tooltip described the
// polynomial fit it does not perform. They are gone until a stage reads them.
//
// Retouch is gone for the same reason taken one step further: its entire content was a
// paragraph saying heal and clone are not implemented. An absent feature costs nothing;
// a section that exists to explain its own absence costs a header, a chevron, a place in
// the accordion and a paragraph, on every visit. It comes back when a stage renders a
// stroke.
//
// CROP LEFT, AND IT IS THE ONE SPLIT THAT WAS NOT ABOUT WORKSPACES. The other four
// sections here are settings: a row, a number, a recipe field. The crop is a tool you
// use on the photograph, with session state — a ratio lock, a guide, a baseline to
// revert to — that no other section in this file has any use for. It is `CropPanel.swift`
// now, and Optics composes the two.
//
// FOUR SECTIONS, THREE WORKSPACES. docs/28 §5.1 sends the creative layers to Grade's
// Effects, the lens correction to the Crop workspace's Optics, and the proof to Deliver.
// The rest stay in one file because they share `binder`; `only` is how the column asks
// for one of them.

#if os(macOS)

import Foundation
import LumenCore
import SwiftUI

// MARK: - Effects panel

struct EffectsPanel: View {
    @EnvironmentObject var state: AppState
    /// This surface shows the edit, so it observes the edit signal —
    /// `AppState.recipes` is deliberately not published (see `EditRevision`).
    @EnvironmentObject var edits: EditRevision

    private var binder: RecipeBinder { RecipeBinder(state: state) }
    private var recipe: Recipe { state.currentRecipe }

    /// The one section the column wants drawn. nil renders every section this panel
    /// owns, which is what the tab did.
    var only: WorkspaceSection?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Ordered as the tab ordered them rather than grouped by workspace, so that
            // nil is still exactly the Effects tab, less Retouch — which sat between
            // Lens and Soft Proof, and is deleted rather than moved.
            if shows(.effects) {
                vignetteSection
                grainSection
            }
            // TWO SECTIONS, not one. They were `optics` together until Crop became a
            // workspace, and then the column read "Lens" above a sub-section called
            // "Crop" — a heading naming half its own contents. The split also gives each
            // its own Reset, which is the half that was a real defect.
            if shows(.frame) { CropSection() }
            if shows(.optics) { lensSection }
            if shows(.softProof) {
                // Deliver's own header prints "Soft Proof", so wrapping these in a
                // section titled "Soft Proof" would print the name twice. The tab has
                // no header above them and keeps the one they came with.
                if only == nil { proofSection } else { proofRows }
            }
        }
    }

    private func shows(_ section: WorkspaceSection) -> Bool {
        only == nil || only == section
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
                    // Size is the pitch at the gate relative to the stock's own. The
                    // footprint is denominated at the GATE and scales with the render's
                    // pixel count, so it is the same fraction of the picture at every
                    // delivery size — print size cancels algebraically out of
                    // `plateScale`, pinned to 1e-12 by
                    // `testGrainFollowsTheGateAndTheRenderSizeNotThePrintSize`. Kept as
                    // a comment because `LookPanel` binds this same field, and two
                    // panels binding one value must not tell opposite stories about it.
                    LumenSlider(title: "Size",
                                value: binder.custom("look.grain.size",
                                                     get: { r in r.look.filmLab?.grain.size ?? 1 },
                                                     set: { r, v in r.look.filmLab?.grain.size = v }),
                                range: 0.5...2.0, hardRange: nil, defaultValue: 1.0,
                                step: 0.05, decimals: 2, bipolar: true)
                }
            } else {
                // The empty state is the way out of the empty state. Grain is a
                // property of a stock, so the only move that leads anywhere from here
                // is loading one, and `jump` promotes the register if Film Lab is
                // hiding in Simple.
                HStack(spacing: 6) {
                    Button("Load a film stock") { state.jump(to: .filmLab) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(Lumen.accent)
                    Spacer()
                }
                .frame(height: Lumen.rowHeight)
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
                                   + "profile embedded in the file, at decode. There is "
                                   + "no lens database in this build, so a file carrying "
                                   + "no profile develops uncorrected.")
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
                // geometry warp" — two rows above a note conceding none of it runs.
                // A reader who trusts the control loses the time it takes to find out,
                // and one who trusts the footnote is left wondering which half of the
                // panel to believe. `MaskPanel` had already settled the form for the
                // local group: take the controls out. The sentence that stood in for
                // them has now gone too — a panel owes nobody an inventory of what it
                // does not contain, and this comment is where such an inventory belongs.
            }
        }
    }

    // MARK: Soft proof

    /// A viewing mode, not an edit (docs/11), which is why it binds to `AppState` and not
    /// through `binder` — it changes no recipe, appears in no undo step and is not copied
    /// with settings.
    private var proofSection: some View {
        DevelopSection("Soft Proof", isModified: state.softProof.enabled,
                       onReset: { state.softProof = SoftProof() }) {
            proofRows
        }
    }

    /// Split from the wrapper so there is one definition of the rows and two framings:
    /// the section header under the tab, and the column's own header under `only`.
    private var proofRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenToggleRow(title: "Soft proof", isOn: $state.softProof.enabled,
                           // The second clause is the one that saves a photographer
                           // from concluding the proof is broken: the loupe is handed
                           // to SwiftUI as an sRGB image, so a destination at least as
                           // wide as sRGB looks almost the same proofed or not, and the
                           // warning and the paper simulation are what carry the
                           // information there.
                           help: "⇧S. Renders the picture through the destination "
                               + "space so you can see what the delivery will hold. The "
                               + "loupe is drawn as sRGB, so a destination that wide "
                               + "changes little beyond the gamut warning and the paper "
                               + "simulation.")
            if state.softProof.enabled {
                // THE POPUP THAT SAT FOUR INCHES FROM THE PHOTOGRAPH. This is the one
                // the owner's complaint names most sharply without naming it:
                // `NSPopUpButton` draws its chevron well in the system accent, so a
                // blue lozenge sat beside a picture whose colour you are here to judge
                // — a Law 7 violation that survived four design passes only because
                // AppKit was the one painting it. `LumenMenuPicker` draws the row in
                // this app's greys, and puts its label on the same 86-point column as
                // the Intent row beneath it and every slider in the panel.
                //
                // No glyphs on the destinations, for the reason `LumenMenu` gives: a
                // colour space has no shape, and five invented ones beside a
                // photograph would be exactly the decoration this panel must not add.
                LumenMenuPicker(title: "Destination",
                                options: proofSpaceOptions,
                                selection: $state.softProof.space,
                                help: "The space the picture is rendered through while "
                                    + "the proof is on")

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
                                   + "print has and a screen does not — from one "
                                   + "documented white and black, not an ICC profile.")
            }
        }
    }

    private var intentOptions: [(value: RenderingIntent, label: String)] {
        [(value: .perceptual, label: "Perceptual"),
         (value: .relativeColorimetric, label: "Relative")]
    }

    /// Every space the exporter can write, in the enum's own order, so proofing and
    /// delivering offer the same list in the same sequence — the proof is worthless if
    /// it is not against a destination you can actually export to.
    private var proofSpaceOptions: [LumenMenuOption<ExportColorSpace>] {
        ExportColorSpace.allCases.map { LumenMenuOption($0, $0.displayName) }
    }
}

#endif
