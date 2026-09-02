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
// neutral. The sliders stand that neutral in while the fields are nil and say "As Shot"
// in the preset row; the first move writes it as a concrete Kelvin, and the preset
// menu's As Shot entry writes nil back.
//
// It used to stand in a literal 5500 K, because the comment here said the neutral was
// "a real number the UI does not know" and left it there. It is known — `ImageSource`
// reads it off the file and `RenderPlan` adapts from it on every render — so the row
// was showing one number while the picture was made with another. On a 3200 K tungsten
// frame the first touch of Temp wrote 5500 and the adaptation honoured it: a 2300 K
// jump cut on a drag that had not finished starting. `AppState.primaryAsShotNeutral`
// carries it now, `WhiteBalanceEngine.displayed` is the rule, and until the source has
// answered the rows say so instead of guessing.

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
    /// The glyph the preset menu draws beside the name.
    ///
    /// Light sources were the first list in this app to earn one, and they earn it
    /// honestly: a photographer choosing a white balance is remembering what was
    /// lighting the room, and a sun, a cloud, a bulb and a flash say that in one
    /// saccade where six words in a column do not. The owner asked for exactly this —
    /// "I'd also love it if we could add visuals a little bit more" — and `LumenMenu`'s
    /// rule is that a list is glyphed all the way or not at all, so every row here has
    /// one and none of them is invented.
    let symbol: String

    var id: String { name }
}

private let wbIlluminants: [WBIlluminant] = [
    WBIlluminant(name: "Daylight", kelvin: 5500, tint: 10, symbol: "sun.max"),
    WBIlluminant(name: "Cloudy", kelvin: 6500, tint: 10, symbol: "cloud"),
    WBIlluminant(name: "Shade", kelvin: 7500, tint: 10, symbol: "cloud.sun"),
    WBIlluminant(name: "Tungsten", kelvin: 2850, tint: 0, symbol: "lightbulb"),
    WBIlluminant(name: "Fluorescent", kelvin: 3800, tint: 21, symbol: "light.panel"),
    WBIlluminant(name: "Flash", kelvin: 5500, tint: 0, symbol: "bolt"),
]

// What the Temp and Tint rows show while the recipe says "as shot" is
// `WhiteBalanceEngine.displayed`, in LumenCore, where a test can reach it. There is no
// constant here to be wrong any more.

// MARK: - Basic panel

struct BasicPanel: View {
    @EnvironmentObject var state: AppState
    /// This surface shows the edit, so it observes the edit signal —
    /// `AppState.recipes` is deliberately not published (see `EditRevision`).
    @EnvironmentObject var edits: EditRevision

    /// nil renders every section this panel owns, which is what the tab did.
    ///
    /// docs/28 §5.1 asks the column for one section at a time, and this panel's four
    /// sections are not one row of that column: Tone, Presence and White Balance land in
    /// three separate places in the accordion, two of them apart from each other. Naming
    /// the section from outside rather than cutting the file into three keeps every
    /// section's rows and bindings in one file; what the accordion takes over is the
    /// header, and the Reset and modified dot that live in it (see `sections(for:)`).
    /// The tab strip, which passes nothing, sees no change at all.
    var only: WorkspaceSection? = nil

    /// Zones opens closed. It is the register a photographer reaches for after the six
    /// sliders have not been enough, not one they want in the way while using them.
    @State private var zonesExpanded = false

    private var binder: RecipeBinder { RecipeBinder(state: state) }
    private var recipe: Recipe { state.currentRecipe }

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.rowGap) {
            if let only {
                sections(for: only)
            } else {
                // Tone first: the owner edits light before colour, every session, and
                // said so in exactly those words — the panel leads with Exposure and
                // friends, White Balance moves below the visual controls it used to sit
                // on top of. This order is the tab's; the accordion orders itself, by
                // `WorkspaceSection.canonicalRank`.
                toneSection
                presenceSection
                whiteBalanceSection
                saturationSection
            }
        }
    }

    /// What one accordion row of this panel holds.
    ///
    /// A section this panel does not own draws nothing rather than falling back to all
    /// of them: the column names the section it wants, so a name this panel cannot serve
    /// is a caller bug, and it should read as an empty row rather than as four sections
    /// appearing under somebody else's header.
    ///
    /// ROWS, NOT SECTIONS, for the three whose names collide. `WorkspaceSection.title`
    /// prints exactly the words this panel's own headers do — "Tone", "Presence",
    /// "White Balance" — and the column has already drawn one, so keeping the wrapper
    /// would stack two identical headings and read as two sections. What the wrapper
    /// carried comes with the column's header instead: the modified dot, and a Reset
    /// that has to do what this file's own reset does. Those are two statements of one
    /// rule now (`DevelopColumn`'s reset table and `applyAsShot()` / `resetPresence()` /
    /// the `tone.reset` edit below), and they must agree.
    @ViewBuilder
    private func sections(for section: WorkspaceSection) -> some View {
        switch section {
        case .whiteBalance:
            whiteBalanceRows
        case .tone:
            toneRows
            // Zones folds in here rather than standing as a section of its own — docs/28
            // §5.1, and `WorkspaceSection.tone` says so at the declaration. It is the
            // difference between Develop being six rows deep and eight, and it is the
            // right fold: a zone set is the six sliders continued at more points, not a
            // different subject. The register comes from `ZonesPanel` with its own header
            // suppressed, because the disclosure above it is already that header.
            //
            // Its Reset is on the column's Tone header, which clears the six sliders and
            // the zone register together — under the accordion they are one section to a
            // photographer. Do not go looking for it in `DevelopDisclosure`, which
            // carries no reset of its own.
            DevelopDisclosure("Zones", isExpanded: $zonesExpanded) {
                ZonesPanel(showsSectionHeader: false)
            }
        case .presence:
            presenceRows
            // Vibrance and Saturation ride with Presence, which is the one placement a
            // reader will stop at. §5.1 gives Develop no Colour section at all, and
            // `WorkspaceSection.color` is Grade's Mixer / Point Colour / B&W surface — a
            // different job at a different point in the edit, in another workspace. These
            // two are global punch of the same family as Texture, Clarity and Dehaze, and
            // a photographer reaching for saturation in a first pass wants it beside
            // Exposure rather than behind the Mixer.
            //
            // This one KEEPS its wrapper: "Saturation" under "Presence" is a sub-heading
            // rather than the same heading twice, and without it two unlabelled groups of
            // sliders would run together in one row.
            saturationSection
        default:
            EmptyView()
        }
    }

    // MARK: White balance

    /// The file's own neutral, once the source has answered. nil is "not known yet".
    private var asShotNeutral: WhiteBalanceEngine.Neutral? { state.primaryAsShotNeutral }

    /// What the two rows show, by the rule in LumenCore rather than by a constant here.
    private var whiteBalanceDisplay: WhiteBalanceEngine.AsShotDisplay {
        WhiteBalanceEngine.displayed(temp: recipe.develop.raw.temp,
                                     tint: recipe.develop.raw.tint,
                                     asShot: asShotNeutral ?? .reference)
    }

    private var whiteBalanceSection: some View {
        DevelopSection("White Balance", isModified: isWhiteBalanceModified,
                       onReset: { applyAsShot() }) {
            whiteBalanceRows
        }
    }

    private var whiteBalanceRows: some View {
        let display = whiteBalanceDisplay
        // THE AS-SHOT NEUTRAL, NOT THE DISPLAYED VALUE, and the difference is the whole
        // of a defect that made the app's two most-used rows the only two that could
        // never report themselves modified.
        //
        // Both rows used to pass `display.temperature` / `display.tint` as BOTH the
        // binding's stand-in and the `defaultValue`. `WhiteBalanceEngine.displayed`
        // returns `temp ?? kelvin`, so the moment an override exists the two are the
        // same number by construction — `value == defaultValue`, identically, for every
        // value. Drag Temp from 3200 K to 7800 K and `isModified` stays false: the label
        // and readout stay secondary, the deviation underline these two rows carry is
        // gated on `isModified` so it never draws, Tint's neutral tick sits at the
        // thumb's own position and is permanently hidden under it, and the crossing
        // haptic can never fire because the detent equals where you started.
        //
        // The neutral is what "unchanged" means here, and it is what `onReset` restores.
        let neutral = asShotNeutral ?? .reference
        // While the neutral is unknown the rows have nothing honest to stand in, so they
        // do not accept a drag. The window is one hop onto the render actor and it only
        // opens on a photo whose recipe carries no override — the case where a drag
        // would otherwise write a fabricated Kelvin and change the picture.
        let unknown = asShotNeutral == nil && display.isAsShot

        return VStack(alignment: .leading, spacing: Lumen.rowGap) {
            presetRow
            // The Kelvin axis is perceptually even in MIREDS, not in Kelvin, which
            // is why every camera UI steps in them underneath and why this
            // package's own eyedropper searches in them. The slider was linear in
            // Kelvin, so the top 72.9% of its travel carried 4.4% of its effect
            // and the first fifth carried 93.3% — the owner reported it as
            // "nothing even changes above like 15,000", which was an accurate
            // reading of the control. `.reciprocal` spends the fifths
            // 21.4 / 33.6 / 18.8 / 15.6 / 10.5 instead. The range is unchanged:
            // 2000–50000 K is the documented span and matches the field, and what
            // was wrong was never its width but where its travel went.
            LumenSlider(title: "Temp",
                        value: binder.value(\.develop.raw.temp, "wb.temp",
                                            orAuto: display.temperature),
                        range: 2000...50000,
                        hardRange: 2000...50000,
                        scale: .reciprocal,
                        defaultValue: neutral.kelvin,
                        step: 10, decimals: 0, bipolar: true,
                        // Blue below neutral, amber above, placed in Kelvin so the
                        // grey stop lands where the mired axis actually puts 5500 K
                        // (about two thirds along, not the middle). docs/28 Phase 2.
                        trackStops: Lumen.temperatureStops,
                        help: "Sets the light the picture is balanced for, in Kelvin "
                            + "— drag right of the as-shot tick to warm it, left to "
                            + "cool. Travel is spaced in mireds, so a move counts the "
                            + "same everywhere on the scale. Reset is as shot.",
                        // Double-clicking the label CLEARS the override rather than
                        // pinning the displayed number. `raw.temp` is optional and
                        // nil means as-shot; pinning a number there flips the
                        // section to "Custom" and freezes this photograph's neutral
                        // into a recipe that may be copied onto another.
                        onReset: { applyAsShot() })
            LumenSlider(title: "Tint",
                        value: binder.value(\.develop.raw.tint, "wb.tint",
                                            orAuto: display.tint),
                        range: -150...150,
                        hardRange: -300...300,
                        defaultValue: neutral.tint,
                        // THE AS-SHOT LANDMARK GETS DRAWN. `bipolar` is what gates the
                        // default tick, and Tint already had it; Temp did not, which is
                        // why the one row whose neutral moves per photograph was the one
                        // row with nothing on its track saying where that neutral is.
                        step: 1, decimals: 0,
                        trackStops: Lumen.tintStops,
                        help: "Balances the green–magenta axis the Kelvin scale "
                            + "cannot reach: positive is magenta, negative green — "
                            + "the fix for fluorescent and mixed light. Reset is as "
                            + "shot.",
                        onReset: { applyAsShot() })
            // Tint honesty (docs/23 M2): the engine bounds the magenta half so
            // the adaptation cannot invert the picture, and on a warm frame the
            // slider's last stretch is deliberately inert past that bound. The
            // engine has said so through `effectiveTint` since the guard landed;
            // this is the first place the PHOTOGRAPHER hears it — without it the
            // stretch reads as a broken control (the Density lesson: a correct
            // gate that looks like a dead slider).
            //
            // This one STAYS while Density's sentence goes, and the difference is
            // that this carries a number. Density's line explained a state you could
            // already see; this reports the value the render is actually using, which
            // no amount of drawing the slider differently can say. It is also absent
            // on every ordinary frame — `boundedTintCaption` returns nil while the
            // slider and the render agree, so daylight editing never grows a caption.
            if let bounded = boundedTintCaption(display: display) {
                Text(bounded)
                    .font(.lumenCaption)
                    .foregroundStyle(Lumen.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(unknown)
        .help(asShotHelp(unknown: unknown))
    }

    /// The inline line under Tint when the shown magenta exceeds what the current
    /// temperature can physically mean. Nil while the slider and the render agree,
    /// so daylight editing never grows a caption.
    private func boundedTintCaption(
        display: WhiteBalanceEngine.AsShotDisplay) -> String? {
        let shown = display.tint
        guard shown > 0 else { return nil }
        let effective = ColorTemperature.clampedTint(kelvin: display.temperature,
                                                     tint: shown)
        guard effective < shown - 0.5 else { return nil }
        return "Magenta is bounded by physics at +\(Int(effective.rounded())) for "
            + "\(Int(display.temperature.rounded())) K — the render uses that value."
    }

    /// Says which neutral the render is adapting from, because "Temp 5500" means
    /// nothing without it — the same reasoning as DetailPanel's ISO badge.
    private func asShotHelp(unknown: Bool) -> String {
        guard !unknown else {
            return "Reading the file's as-shot neutral — the sliders open once it is "
                + "known, so the first drag cannot move the picture."
        }
        guard let neutral = asShotNeutral else {
            return "This file records no camera neutral, so Temp and Tint are relative "
                + "to how it was delivered."
        }
        return "Shot at \(Int(neutral.kelvin.rounded())) K, tint "
            + "\(Int(neutral.tint.rounded()))"
    }

    private var presetRow: some View {
        HStack(spacing: 6) {
            // `LumenMenu`, not `Menu`: this row sits four inches from the photograph
            // and an `NSPopUpButton` put a blue-tinted chevron well there, which is a
            // Law 7 violation AppKit was committing on our behalf. The list is ours
            // now, and it says two things the old one could not — a glyph for the light
            // that was in the room, and in the annotation column the Kelvin the row
            // will actually write. "Tungsten" tells a photographer nothing about where
            // Temp lands; "2850 K" beside it tells them exactly.
            LumenMenu(title: presetName,
                      help: "White balance preset — any manual move reads as Custom") {
                LumenMenuItem(title: "As Shot", symbol: "camera",
                              detail: asShotDetail,
                              isSelected: presetName == "As Shot") { applyAsShot() }
                // There is no Auto entry, and its absence is the whole design. It was
                // here, disabled, with the reason written into its own label — a menu
                // item whose only job was to announce that it does not work. A menu
                // missing an entry teaches nothing; a menu apologising teaches that the
                // app is unfinished. It comes back when scene statistics do.
                LumenMenuDivider()
                ForEach(wbIlluminants) { illuminant in
                    LumenMenuItem(title: illuminant.name,
                                  symbol: illuminant.symbol,
                                  detail: "\(Int(illuminant.kelvin.rounded())) K",
                                  isSelected: presetName == illuminant.name) {
                        applyIlluminant(illuminant)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                // Pressing it again disarms rather than stacking a second pick.
                if state.pickTarget == .neutral {
                    state.cancelPick()
                } else {
                    state.beginPick(.neutral)
                }
            } label: {
                Image(systemName: "eyedropper")
                    .font(.lumenGlyphBody)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Lumen.controlBackground)
                    .foregroundStyle(Lumen.primaryText)
                    .clipShape(RoundedRectangle(cornerRadius: Lumen.radiusChip))
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

    /// What the As Shot row shows in the annotation column: the neutral the file was
    /// made with, when the decode has answered with one.
    ///
    /// Nil rather than a guess while `asShotNeutral` is nil, for the same reason the
    /// Temp and Tint rows stand down until it is known — this row used to be the place
    /// a 5500 came from, and a number in a menu is read as a promise about what the
    /// row will write.
    private var asShotDetail: String? {
        guard let neutral = asShotNeutral else { return nil }
        return "\(Int(neutral.kelvin.rounded())) K"
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
            toneRows
        }
    }

    /// The six sliders and Contrast's pivot, without a header of their own — the
    /// accordion's Tone row draws one, and the tab's section wraps these in another.
    private var toneRows: some View {
        VStack(alignment: .leading, spacing: Lumen.rowGap) {
            // TWO RAMPS IN THIS BLOCK, AND ONLY TWO. The owner asked for "a dark to
            // light gradient on stuff like the exposure slider or contrast stuff", which
            // overturns the refusal recorded in docs/28 Part 7 item 1 — see the
            // `Lumen.exposureStops` comment for why a grey ramp costs Law 7 less than a
            // coloured one does.
            LumenSlider(title: "Exposure",
                        value: binder.value(\.develop.tone.exposure, "tone.exposure"),
                        range: -5...5, hardRange: -10...10, defaultValue: 0,
                        step: 0.01, decimals: 2,
                        trackStops: Lumen.exposureStops,
                        help: "Overall brightness as true scene gain, in stops: +1 "
                            + "doubles the light, exactly like opening the aperture a "
                            + "stop. Set it first — every other tonal control works "
                            + "around it.")
            LumenSlider(title: "Contrast",
                        value: binder.value(\.develop.tone.contrast, "tone.contrast"),
                        range: -100...100, hardRange: nil, defaultValue: 0,
                        step: 1, decimals: 0,
                        trackStops: Lumen.contrastStops,
                        help: "Steepens or flattens the picture around the Pivot "
                            + "below — midtones spread apart or gather while the ends "
                            + "of the scale stay pinned, so it cannot clip a "
                            + "highlight.")
            // Under Contrast, not behind a chevron of its own. The pivot is the thing
            // Lightroom hides — its Contrast is a fixed S-curve anchored near L≈50 and
            // never documented, ours is a slope around a number the photographer can
            // move — and hiding our version in a fold that holds one row spent a whole
            // disclosure to conceal the one thing we have that they do not.
            LumenSlider(title: "Pivot",
                        value: binder.value(\.develop.tone.contrastPivot,
                                            "tone.contrastPivot"),
                        range: -4...4, hardRange: nil, defaultValue: 0,
                        step: 0.01, decimals: 2,
                        help: "Where Contrast hinges, in stops from mid-grey — the "
                            + "tone it holds still. Raise it to anchor the brights "
                            + "and let contrast work the shadows; lower it for the "
                            + "reverse.")
            // AND THE OTHER FIVE STAY PLAIN, which is a decision rather than an
            // omission, so here is both sides of it.
            //
            // For ramping them: they are all tonal, they sit in one block, and a panel
            // where two of seven rows are ramped looks like somebody stopped halfway.
            // Consistency is a real argument and this is it.
            //
            // Against, and it wins twice over. First, it would not be true. Exposure's
            // axis IS lightness; Highlights, Shadows, Whites and Blacks each act on ONE
            // ZONE, so a full-track dark-to-light ramp on Shadows would claim the
            // control runs from black to white when what it runs from is "leave the
            // shadows" to "lift them". That is the track lying about the instrument, and
            // the axis exception exists precisely to license tracks that tell the truth.
            // Second, density is what kills the signal: two ramps in a block read as
            // meaningful, seven read as a texture, and then Exposure's ramp — the one
            // that is exact — has been spent on decorating its neighbours.
            //
            // Pivot is the honest near-miss and worth naming, because it is a stronger
            // candidate than Contrast on the truth test: it says at WHAT LIGHTNESS the
            // contrast hinge sits, which is a lightness axis exactly. It is left plain
            // because the owner named two controls and this would be a third, and
            // because Contrast reading as the headline with its modifier plain is a
            // legible arrangement. It is one entry in a table if he wants it.
            LumenSlider(title: "Highlights",
                        value: binder.value(\.develop.tone.highlights, "tone.highlights"),
                        range: -100...100, hardRange: nil, defaultValue: 0,
                        step: 1, decimals: 0,
                        help: "Darkens or lifts the bright zone alone — pull it down "
                            + "to bring a blown sky back. Mid-grey and below never "
                            + "move, so it can never fight Shadows.")
            LumenSlider(title: "Shadows",
                        value: binder.value(\.develop.tone.shadows, "tone.shadows"),
                        range: -100...100, hardRange: nil, defaultValue: 0,
                        step: 1, decimals: 0,
                        help: "Lifts or darkens the dark zone alone, through an "
                            + "edge-aware mask that will not halo a backlit edge. "
                            + "Mid-grey and above never move.")
            LumenSlider(title: "Whites",
                        value: binder.value(\.develop.tone.whites, "tone.whites"),
                        range: -100...100, hardRange: nil, defaultValue: 0,
                        step: 1, decimals: 0,
                        help: "Sets the white clipping point — where scene brights "
                            + "start rendering as pure white. Pull it down to hold "
                            + "texture in the brightest tones, push it up to let "
                            + "speculars clip.")
            LumenSlider(title: "Blacks",
                        value: binder.value(\.develop.tone.blacks, "tone.blacks"),
                        range: -100...100, hardRange: nil, defaultValue: 0,
                        step: 1, decimals: 0,
                        help: "Sets the black clipping point — how deep a shadow goes "
                            + "before it renders as pure black. Push it up to open "
                            + "the deepest shadows, pull it down to crush them.")
        }
    }

    // MARK: Presence

    private var presenceSection: some View {
        DevelopSection("Presence", isModified: isPresenceModified,
                       onReset: { resetPresence() }) {
            presenceRows
        }
    }

    /// Texture, Clarity and Dehaze bare, for the same reason as `toneRows`.
    private var presenceRows: some View {
        VStack(alignment: .leading, spacing: Lumen.rowGap) {
            LumenSlider(title: "Texture",
                        value: binder.value(\.develop.detail.texture, "detail.texture"),
                        range: -100...100, hardRange: nil, defaultValue: 0,
                        step: 1, decimals: 0,
                        help: "Boosts or smooths mid-sized detail — pores, bark, "
                            + "weave — while leaving hard edges and soft bokeh "
                            + "alone. Negative is the gentle skin smoother.")
            // THE TOOLTIP IS A MEASUREMENT, which is why it is worth its words. The
            // halo-free property belongs to the local Laplacian, which runs in
            // `ReferenceRenderer` and renders no pixel anybody sees; the GPU ships a
            // single guided band, and beside a clean 3 EV step it rims — Clarity by
            // 0.127 EV at +100 against the Laplacian's 0.0049, positive Texture by
            // 0.267 EV. Two earlier versions of this text promised a cached
            // decomposition nobody had written and a halo that is not avoided, and a
            // note is a promise to the person reading it: each one cost the reader
            // their trust in every other word on the panel.
            LumenSlider(title: "Clarity",
                        value: binder.value(\.develop.detail.clarity, "detail.clarity"),
                        range: -100...100, hardRange: nil, defaultValue: 0,
                        step: 1, decimals: 0,
                        help: "Local contrast, weighted toward the midtones — punch "
                            + "that fades off before the extremes. Pushed hard it "
                            + "rims a clean edge, most past about +50.")
            LumenSlider(title: "Dehaze",
                        value: binder.value(\.develop.detail.dehaze, "detail.dehaze"),
                        range: -100...100, hardRange: nil, defaultValue: 0,
                        step: 1, decimals: 0,
                        help: "Estimates the atmospheric veil and removes it, "
                            + "restoring contrast and colour to flat, hazy distance. "
                            + "Negative lays haze back down for atmosphere.")
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

    /// Titled "Saturation", not "Colour", and that is the header the tab shows too.
    ///
    /// Two headings reading "Colour" would name two different jobs: this is Vibrance and
    /// Saturation, global punch, and `WorkspaceSection.color` is Grade's Mixer / Point
    /// Colour / B&W surface. Under `only:` this one sits INSIDE Presence, so the two
    /// would also have been one workspace apart on screen. "Saturation" is what the two
    /// rows are, so the header stops being a category and starts being a name.
    private var saturationSection: some View {
        DevelopSection("Saturation", isModified: recipe.develop.color != ColorAdjust(),
                       onReset: { binder.edit("color.reset") {
                           $0.develop.color = ColorAdjust()
                       } }) {
            saturationRows
        }
    }

    /// Vibrance, Saturation, Density and Protect Skin, flat.
    ///
    /// The last two used to sit behind an "Advanced" chevron. Two rows do not pay for a
    /// fold: the chevron cost a header, a click and a second level of hierarchy to hide
    /// forty-four points of panel, and it hid them from the photographer who had just
    /// pushed Saturation and was one row away from the dial that shapes the push.
    ///
    /// DENSITY IS NOT DRAWN UNTIL IT IS LIVE, which is the design that retires a
    /// sentence. Density blends Saturation's additive push against its subtractive one,
    /// and a pull has no push to blend — the engine guards it on `satAmount > 0`, and
    /// the predicate is `ColorAdjust.densityIsLive` in LumenCore, next to the field,
    /// with a test tying it to that guard.
    ///
    /// Three drawings of that gate have now been tried. Live across the whole range
    /// while doing nothing: worse than dead, because it looked like it was working, and
    /// session A duly reported it as "doesn't seem to be able to be moved". Disabled
    /// with the reason in a tooltip: a correct gate reading as a broken control, because
    /// the explanation sat behind a hover delay. Disabled with the reason printed under
    /// it: honest, and eleven of those sentences are what "so much wording" means
    /// (docs/30 §2.2) — a disabled control does owe the reason to the same glance that
    /// finds it disabled, and a sentence is not what a glance reads.
    ///
    /// So it arrives instead, under the control that made it live, at the moment it
    /// does. That says everything the sentence said and one thing it never did: what
    /// Density depends on. Nothing is hidden that could have been used — before the
    /// crossing there is no push for it to act on — and it is strictly more findable
    /// than it was yesterday, when the fold above shipped closed and no amount of
    /// Saturation opened it.
    private var saturationRows: some View {
        let densityIsLive = recipe.develop.color.densityIsLive
        return VStack(alignment: .leading, spacing: Lumen.rowGap) {
            LumenSlider(title: "Vibrance",
                        value: binder.value(\.develop.color.vibrance, "color.vibrance"),
                        range: -100...100, hardRange: nil, defaultValue: 0,
                        step: 1, decimals: 0,
                        help: "Saturation weighted toward the muted colours — what is "
                            + "already rich resists, and skin is protected — so it is "
                            + "the safer everyday boost.")
            LumenSlider(title: "Saturation",
                        value: binder.value(\.develop.color.saturation, "color.saturation"),
                        range: -100...100, hardRange: nil, defaultValue: 0,
                        step: 1, decimals: 0,
                        help: "Scales every colour's intensity while holding its "
                            + "perceived brightness; −100 is true black and white. "
                            + "Pushes compress as colours near full saturation, "
                            + "instead of clipping.")
            if densityIsLive {
                // The live half of what this row used to say in a `.help` modifier —
                // on the `help:` parameter now, so the NAME answers the hover. The
                // other half — "raise Saturation above zero and this comes live" —
                // is what the row's own arrival says.
                LumenSlider(title: "Density",
                            value: binder.value(\.develop.color.density, "color.density"),
                            range: 0...100, hardRange: nil, defaultValue: 50,
                            step: 1, decimals: 0, bipolar: true,
                            help: "How much of a Saturation push is subtractive — "
                                + "colours deepening as they saturate, the way film "
                                + "dyes do, instead of brightening.")
                    // The same transition a section body uses, because to a
                    // photographer this is the same event.
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            LumenSlider(title: "Protect Skin",
                        value: binder.value(\.develop.color.protectSkin,
                                            "color.protectSkin"),
                        range: 0...100, hardRange: nil, defaultValue: 70,
                        step: 1, decimals: 0, bipolar: true,
                        help: "How firmly skin hues are shielded from Vibrance and "
                            + "Saturation pushes, so a colour move does not turn a "
                            + "complexion. A pull to −100 still reaches true black "
                            + "and white.")
        }
        // Declared against the value rather than wrapped around the write: the write is
        // a drag sample inside `RecipeBinder`, which no panel reaches. Same curve as
        // `PanelLayout.commit`, so a row appearing moves the way a section opening does.
        .animation(.smooth(duration: 0.22), value: densityIsLive)
    }
}

#endif
