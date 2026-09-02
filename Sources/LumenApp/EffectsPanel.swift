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
// GRAIN USED TO BE ABSENT HERE WITHOUT A FILM STOCK, and this file argued for it: the
// note that stood in this paragraph said "grain belongs to a stock, not to the frame",
// and the section's whole content on a stockless photograph was a button into Film Lab.
// That was true of the WIRING — every grain reader on both render paths was gated on
// `plan.filmChain` — and false about photography, which is a bad way for a panel to be
// right. The owner's report closed it: *"a grain that we can only use when we load a
// film stock … no ability to make creative kinds of grain on the image."* `look.grain`
// is now a first-class creative stage with Amount, Size and Roughness, on any frame,
// through the same density-domain model the emulsions use. See `grainSection`.
//
// Optional-field policy still applies to what is left of it: the STOCK's two rows are
// absent rather than dead whenever the stock's grain is not what renders, and the
// creative three stand in their place — which is a control, not a sentence explaining an
// emptiness.
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

    /// Whether the selected photograph is one the raw decoder never sees. Two controls in
    /// this panel write fields whose only reader is `AppleRawSource`.
    private var isRenderedFile: Bool {
        state.primarySelection.map { PhotoFormats.isRendered($0.id) } ?? false
    }
    private var recipe: Recipe { state.currentRecipe }

    /// The one section the column wants drawn. nil renders every section this panel
    /// owns, which is what the tab did.
    var only: WorkspaceSection?

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.rowGap) {
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
            // The same only-aware split Soft Proof already makes below, for the same
            // reason: the column has drawn `WorkspaceSection.frame.title` — "Crop" —
            // and `WorkspaceSection.optics.title` — "Lens" — above these, so a section
            // wrapper here printed the heading twice, with two chevrons, two modified
            // dots and two Resets of different scope one row apart.
            if shows(.frame) { CropSection(only: only) }
            if shows(.optics) {
                if only == nil { lensSection } else { lensRows }
            }
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
        DevelopSection("Vignette", isModified: isVignetteModified,
                       onReset: { binder.edit("look.vignette.reset") {
                           $0.look.vignette = 0
                           $0.look.vignetteFeather = Look.vignetteFeatherDefault
                       } }) {
            VStack(alignment: .leading, spacing: Lumen.rowGap) {
                // The range is the ENGINE's, read rather than restated: it moved from
                // −3…+1 to −4…+2 and a slider carrying its own copy of a bound is how a
                // control ends up refusing to reach a value the renderer accepts. The
                // measurement behind the move is on `DetailEngine.vignetteAmountRange`;
                // the short version is that at −3 the control was still delivering 73%
                // of its rate at zero and at +1 it was delivering 81%, so both ends were
                // stops rather than limits — the owner's "a little bit soft at both
                // ends", which was never about the mapping.
                LumenSlider(title: "Amount",
                            value: binder.value(\.look.vignette, "look.vignette"),
                            range: DetailEngine.vignetteAmountRange, hardRange: nil,
                            defaultValue: 0,
                            step: 0.01, decimals: 2,
                            // Second sentence is the honest one and it is new. The
                            // number is a CORNER number: r = 1 is the four corner
                            // points, and the frame receives a fraction of the stated
                            // EV set by Feather — measured over a 3:2 frame, 0.04 of it
                            // at Feather 0, 0.29 at 50, 0.56 at 100. A photographer
                            // reading "−3.00 EV" and seeing a mean of 0.87 EV of
                            // darkening is entitled to know which of the two the slider
                            // is promising.
                            help: "Darkens the corners below zero and lifts them "
                                + "above, in stops AT THE CORNER — applied on "
                                + "scene-linear data before the display transform, "
                                + "so a burn keeps its colour and bright speculars "
                                + "punch through. How much of that reaches the rest "
                                + "of the frame is Feather's job below.")
                // Reads the engine's own geometry (docs/32 Stream E item 4): the
                // renderers derive the falloff's start from this via
                // `DetailEngine.vignetteInnerRadius(feather:)`, and 50 is the fixed
                // shape every recipe rendered with before the field existed.
                LumenSlider(title: "Feather",
                            value: binder.value(\.look.vignetteFeather,
                                                "look.vignetteFeather"),
                            range: 0...100, hardRange: nil,
                            defaultValue: Look.vignetteFeatherDefault,
                            step: 1, decimals: 0, bipolar: false,
                            // "How much of Amount the frame gets" is the sentence this
                            // row was missing, and it is the one that makes the pair
                            // usable: measured over a 3:2 frame the mean falloff is
                            // 0.04 at Feather 0, 0.29 at the default 50 and 0.56 at
                            // 100, so this control moves the delivered strength by
                            // twelve times while Amount is the one that reads like the
                            // strength. Saying so costs a clause.
                            help: "How gradually the burn arrives — 0 keeps it a "
                                + "tight ring near the corners, 100 lets it fall off "
                                + "across the whole frame from the centre. It is also "
                                + "how much of Amount the frame actually receives: "
                                + "about a twelfth of it at 0, a third at 50, over "
                                + "half at 100. It shapes the Amount above, so it "
                                + "changes nothing at Amount 0.")
            }
        }
    }

    /// Feather counts while Amount is 0 — it renders nothing then, but the recipe
    /// differs from its defaults and the header's Reset has to offer itself. Same rule
    /// as `WorkspaceSection.nonDefault`'s `.effects` clause, and the two must agree.
    private var isVignetteModified: Bool {
        recipe.look.vignette != 0
            || recipe.look.vignetteFeather != Look.vignetteFeatherDefault
    }

    // MARK: Grain

    /// GRAIN IS NO LONGER A PROPERTY OF A FILM STOCK, and this section is where that
    /// stopped being true.
    ///
    /// What was here: an `if let film = recipe.look.filmLab` whose else-branch was a
    /// button reading "Load a film stock", above a comment asserting that "grain is a
    /// property of a stock, so the only move that leads anywhere from here is loading
    /// one". That was a statement about the ENGINE's wiring — every grain reader on both
    /// paths was gated on `plan.filmChain` — dressed as a statement about photography,
    /// and the owner named it exactly: *"a grain that we can only use when we load a film
    /// stock … there's no ability to make creative kinds of grain on the image, which is
    /// kind of sad."* Grain is a darkroom instinct. Buying a colour rendering to get it
    /// is a wiring accident.
    ///
    /// So the section now always has controls, and which set it shows is decided by
    /// `GrainPlan.filmOwnsTheGrain` — the same three conditions `RenderPlan` resolves the
    /// stage with, called rather than restated, because a panel that guessed differently
    /// from the renderer would be drawing sliders that reach no pixel. That is the defect
    /// this section was ALREADY convicted of once: with Film Lab Strength at 0 the two
    /// rows below wrote the recipe and rendered nothing, and the panel's answer was a
    /// caption apologizing and a button to another workspace. That case is now the
    /// creative grain's, and it renders.
    ///
    /// The predicate does not ask whether the STOCK's grain Amount is above zero, and
    /// the reason is this panel's: it did, and the result was two rows that deleted
    /// themselves when the top one was dragged to the bottom of its travel. The
    /// argument is on `filmOwnsTheGrain`.
    ///
    /// The precedence, said once here and once in `GrainPlan`: a live stock's grain
    /// wins. It is what every existing recipe renders through, it is already exposed in
    /// Film Lab, and stacking two independent noise fields on one photograph would be
    /// two grains at twice the cost for one intent.
    @ViewBuilder
    private var grainSection: some View {
        DevelopSection("Grain", isModified: isGrainModified, onReset: grainReset) {
            if let film = recipe.look.filmLab, GrainPlan.filmOwnsTheGrain(recipe.look) {
                stockGrainRows(film)
            } else {
                creativeGrainRows
            }
        }
    }

    /// The stock's own grain — unchanged rows, unchanged bindings, unchanged defaults.
    /// Drawn only while the stock's grain is the grain that renders, so neither row can
    /// be dragged into a picture that ignores it.
    @ViewBuilder
    private func stockGrainRows(_ film: FilmLab) -> some View {
        VStack(alignment: .leading, spacing: Lumen.rowGap) {
            // The badge is not clickable, so it answers the pointer with an
            // explanation rather than an affordance — the capture-sharpening
            // badge's rule.
            HStack(spacing: 6) {
                Text("Stock")
                    .font(.lumenCaption)
                    .foregroundStyle(Lumen.secondaryText)
                Spacer()
                LumenBadge(text: FilmStock.named(film.stock)?.name ?? film.stock)
            }
            .frame(height: Lumen.rowHeight)
            .help("The grain is this stock's — its pitch and character come "
                  + "with the emulsion chosen in Film Lab. Pull Film Lab's "
                  + "Strength to 0 and these rows are replaced by a creative "
                  + "grain you shape by hand.")

            // `film.grain.amount`, NOT `look.grain.amount` — the same key `LookPanel`
            // binds this field under, and a different one from the creative row below
            // (C2-07). The old key was wrong twice over: it named a recipe path this
            // row does not write, and the creative Amount row twenty lines down used
            // the identical string for a different field. The two rows are never on
            // screen together, so nothing looked wrong — but a binder key is an
            // IDENTITY, and everything that resolves one (undo coalescing, the
            // last-edited-control record) could not tell a stock's grain from a
            // creative one. Sharing `LookPanel`'s key is the other half of the comment
            // below: two panels binding one value must not disagree about it, and a key
            // is part of what they agree on.
            LumenSlider(title: "Amount",
                        value: binder.custom("film.grain.amount",
                                             get: { r in r.look.filmLab?.grain.amount ?? 0 },
                                             set: { r, v in r.look.filmLab?.grain.amount = v }),
                        // The stock's own grain, matching LookPanel — the
                        // two panels bind the SAME field and disagreed about
                        // its default, so after picking Portra 400 one read
                        // "modified" and the other "default", and
                        // double-clicking reset it to two different numbers.
                        range: 0...100, hardRange: nil,
                        defaultValue: grainDefault,
                        step: 1, decimals: 0, bipolar: false,
                        help: "How much grain is laid down — in density, like the "
                            + "stock itself: strongest through the midtones, "
                            + "vanishing at pure black and white.")
            // Size is the pitch at the gate relative to the stock's own. The
            // footprint is denominated at the GATE and scales with the render's
            // pixel count, so it is the same fraction of the picture at every
            // delivery size — print size cancels algebraically out of
            // `plateScale`, pinned to 1e-12 by
            // `testGrainFollowsTheGateAndTheRenderSizeNotThePrintSize`. Kept as
            // a comment because `LookPanel` binds this same field, and two
            // panels binding one value must not tell opposite stories about it —
            // which is also why this row now carries `LookPanel`'s key.
            LumenSlider(title: "Size",
                        value: binder.custom("film.grain.size",
                                             get: { r in r.look.filmLab?.grain.size ?? 1 },
                                             set: { r, v in r.look.filmLab?.grain.size = v }),
                        range: 0.5...2.0, hardRange: nil, defaultValue: 1.0,
                        step: 0.05, decimals: 2, bipolar: true,
                        help: "The grain's pitch against the stock's own — "
                            + "1.0 is the emulsion's measured pitch at the "
                            + "film gate, and it stays the same fraction of "
                            + "the picture at every delivery size.")
        }
    }

    /// The creative grain: three rows, on any photograph, with or without a stock.
    ///
    /// Lightroom's three names, and each is used only where it is true —
    /// `CreativeGrain` carries the whole mapping and the help below is the short form of
    /// it. Roughness is the one a photographer will not have seen behave honestly
    /// elsewhere: it redistributes the plate's energy across its four octaves and the
    /// plate is renormalized afterwards, so it changes the grain's character and cannot
    /// secretly change its strength.
    @ViewBuilder
    private var creativeGrainRows: some View {
        VStack(alignment: .leading, spacing: Lumen.rowGap) {
            LumenSlider(title: "Amount",
                        value: creativeBinding("look.grain.amount",
                                               get: { $0.amount },
                                               set: { $0.amount = $1 }),
                        range: 0...100, hardRange: nil, defaultValue: 0,
                        step: 1, decimals: 0, bipolar: false,
                        help: "How much grain is laid down, in density — strongest "
                            + "through the midtones and vanishing at pure black and "
                            + "white, which is what makes it read as film rather than "
                            + "as noise laid over the picture. 0 is off, and off "
                            + "costs nothing.")
            LumenSlider(title: "Size",
                        value: creativeBinding("look.grain.size",
                                               get: { $0.size },
                                               set: { $0.size = $1 }),
                        range: 0...100, hardRange: nil, defaultValue: 50,
                        step: 1, decimals: 0, bipolar: false,
                        help: "The grain's pitch, measured at the gate of a 35 mm "
                            + "frame: 7 µm at 0 — about Ektar's — around 20 µm at 50 "
                            + "and 56 µm at 100, doubling every 33 points. Anchored to "
                            + "the gate, so the grain is the same fraction of the "
                            + "picture on a preview and on a full-size export.")
            LumenSlider(title: "Roughness",
                        value: creativeBinding("look.grain.roughness",
                                               get: { $0.roughness },
                                               set: { $0.roughness = $1 }),
                        range: 0...100, hardRange: nil, defaultValue: 50,
                        step: 1, decimals: 0, bipolar: false,
                        help: "How irregular the grain is. Low puts the energy into "
                            + "the coarsest structure — an even, regular field; high "
                            + "feeds the fine octaves for a gritty, clumpy one. 50 is "
                            + "the plate every film stock in the Film Lab uses. It "
                            + "changes the character only: the amplitude is Amount's.")
            // The one sentence a photographer needs when a stock is loaded but its
            // grain is switched off — otherwise these three rows look like they are
            // fighting the Film Lab. No button: this is a statement about what renders,
            // not a place to go.
            if recipe.look.filmLab != nil {
                Text("The loaded stock is not rendering, so this is the grain "
                     + "on the picture.")
                    .font(.lumenCaption)
                    .foregroundStyle(Lumen.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 2)
            }
        }
    }

    /// One field of the creative grain, through the OPTIONAL slot.
    ///
    /// `look.grain` is nil until a photograph has had grain on it, so a plain key-path
    /// binding cannot reach through it. Two rules live here rather than at three call
    /// sites: reading an absent slot reads the defaults, and writing one back to its
    /// defaults writes nil rather than a block of them. The second is the one that
    /// matters — `CreativeGrain.normalized` is what keeps "off" to a single spelling, so
    /// that dragging Amount up and back down leaves a recipe with the same fingerprint
    /// it started with instead of one that renders identically and busts every cached
    /// preview of the photograph.
    private func creativeBinding(_ key: String,
                                 get: @escaping (CreativeGrain) -> Double,
                                 set: @escaping (inout CreativeGrain, Double) -> Void)
        -> Binding<Double> {
        binder.custom(key,
                      get: { get($0.look.grain ?? CreativeGrain()) },
                      set: { recipe, value in
                          var grain = recipe.look.grain ?? CreativeGrain()
                          set(&grain, value)
                          recipe.look.grain = CreativeGrain.normalized(grain)
                      })
    }

    /// The loaded stock's own grain amount — the same default `LookPanel` uses for the
    /// same field. Two panels binding one value must agree about what neutral is, or
    /// one of them shows "modified" while the other shows "default" for one number.
    private var grainDefault: Double {
        FilmStock.named(recipe.look.filmLab?.stock ?? "")?.grainDefault ?? 0
    }

    /// Both grains count, and the section's dot has to admit to whichever one the
    /// photographer moved — including the creative one on a photograph that has never
    /// seen a film stock, which is now the common case. `WorkspaceModification`'s
    /// `.effects` clause states the same rule for the accordion header and the two must
    /// agree; that file's own header records what happened the last time they did not.
    private var isGrainModified: Bool {
        if CreativeGrain.normalized(recipe.look.grain) != nil { return true }
        guard let film = recipe.look.filmLab else { return false }
        return film.grain != FilmGrain(size: 1.0, amount: grainDefault)
    }

    /// Reset puts BOTH grains back, because the section draws whichever one renders and
    /// a Reset that cleared only the visible half would leave the other set behind a
    /// switch the photographer cannot see — load a stock, and yesterday's creative grain
    /// is waiting under it.
    ///
    /// The stock's half lands on the STOCK's grain rather than on zero: this section's
    /// Reset means "put back what I found", and what a photographer found after loading
    /// Portra was Portra's grain. It wrote `FilmGrain()` once, so the section stayed
    /// marked modified after its own Reset and the two reset affordances in one section
    /// landed on two different numbers.
    private var grainReset: (() -> Void)? {
        guard isGrainModified else { return nil }
        let neutral = FilmGrain(size: 1.0, amount: grainDefault)
        return {
            binder.edit("look.grain.reset") { recipe in
                recipe.look.grain = nil
                if recipe.look.filmLab != nil { recipe.look.filmLab?.grain = neutral }
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
            lensRows
        }
    }

    /// The rows with no heading of their own, for when the column has drawn one.
    private var lensRows: some View {
        VStack(alignment: .leading, spacing: Lumen.rowGap) {
                // DISABLED ON A RENDERED FILE, and it matters more here than for its
                // neighbours because this one DEFAULTS TO ON. `lens.profile`'s only
                // reader is `AppleRawSource`; a JPEG goes through `RenderedImageSource`,
                // which reads nothing from the recipe. So every non-raw file in the
                // library carried a ticked box that reached nothing — which is exactly
                // the state the note below says got Remove CA deleted.
                LumenToggleRow(title: "Built-in profile",
                               isOn: binder.flag(\.develop.geometry.lens.profile,
                                                 "geometry.lens.profile"),
                               help: isRenderedFile
                                   ? "The embedded profile is applied at raw decode, "
                                       + "which this file does not go through — so this "
                                       + "changes nothing here."
                                   : "Applies the correction opcodes and manufacturer "
                                       + "profile embedded in the file, at decode. There "
                                       + "is no lens database in this build, so a file "
                                       + "carrying no profile develops uncorrected.")
                    .disabled(isRenderedFile)
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
        VStack(alignment: .leading, spacing: Lumen.rowGap) {
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
                    // The picker's own help sits on its trigger; this outer copy is
                    // what the "Destination" LABEL answers with, since an outer
                    // `.help` shows wherever no inner one covers.
                    .help("The space the picture is rendered through while the proof "
                          + "is on")

                // `.lumenBody` and the picker's own row pitch, not a hand-rolled 11pt
                // with no vertical padding: this label sits directly under
                // Destination's, on the same 94-point column, and the two were one
                // point of type size and two points of rhythm apart for no reason.
                HStack(spacing: 6) {
                    Text("Intent")
                        .font(.lumenBody)
                        .foregroundStyle(Lumen.secondaryText)
                        .frame(width: Lumen.labelWidth, alignment: .leading)
                    LumenSegmented(options: intentOptions,
                                   selection: $state.softProof.intent)
                }
                .frame(height: Lumen.rowHeight)
                .padding(.vertical, 2)
                .help("What happens to colours the destination cannot hold: "
                      + "Perceptual eases the whole range in smoothly, Relative "
                      + "keeps in-gamut colours exact and clips the rest.")

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
