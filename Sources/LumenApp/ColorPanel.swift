// ColorPanel.swift
// The Colour panel: the 8-band Mixer, Point Colour and the Black & White treatment.
//
// Three things this panel exists to get right:
//   · The band strip DRAWS ColorEngine's own weights rather than a redrawn
//     approximation, so "what does this band actually touch" is answerable by looking.
//     The bands are a smooth partition of unity — there are no wedge edges to see.
//   · Luminance is chroma-preserving (D13). Darkening a blue sky must not desaturate
//     it — stated here, where the people who could break it read, and no longer also
//     captioned under the slider where nobody was reading it.
//   · A control is NAMED for what it does; it is not captioned into meaning something
//     else. "Uniformity" sat under the band selector captioned "converges THIS BAND's
//     hues" and is one global value the engine applies to all eight — so selecting Blue
//     and dragging it also pulled skin toward Orange, and the panel said otherwise.
//     Making it per-band is a wire-format change (`Mixer.uniformity` would become eight
//     fields, and every sidecar and the canonical fixture would move with it). So the
//     row is called "Even out hues" now and carries no caption at all. The convergence
//     target is docs/05's: `measuredBandMeanHues` reaches every rendering plan through
//     `RenderPlan(bandMeanHues:)`, so it converges on the image's own measured hues and
//     falls back to the core-arc midpoint only when the frame measures as grey.
//     Sixty-two words of that used to be on screen, half of them describing a
//     texture-preserving spatial pass the shipping graph does not run. A name is the
//     smallest true thing a control can carry.
//   · Switching to B&W and back loses nothing, and "nothing" now means per photo and
//     across a quit. The Mixer lives in `develop.mixer` and the B&W mix in `look.bw`;
//     the treatment toggle never writes across that line, and it writes `bw.enabled`
//     rather than deleting the slot, so the mix belongs to the photograph. The rule
//     itself is `BlackAndWhite.toggled` in LumenCore, where a test can reach it — this
//     panel used to hold the mix in view state, which leaked it between photos.
//
// Every slider is a LumenSlider: the slider contract (D45) has exactly one
// implementation, and a panel that hand-rolls one is a bug the user feels first.

#if os(macOS)

import AppKit
import Foundation
import LumenCore
import SwiftUI

struct ColorPanel: View {
    @EnvironmentObject var state: AppState
    /// This surface shows the edit, so it observes the edit signal —
    /// `AppState.recipes` is deliberately not published (see `EditRevision`).
    @EnvironmentObject var edits: EditRevision

    // Band selection lives on `AppState`, not here, because the eyedropper resolves on
    // the render actor and has to write its answer somewhere this panel will see it.
    // See `AppState.mixerBand` for what that costs and why it is affordable.
    private var selectedBand: Int { state.mixerBand }
    private var allBands: Bool { state.mixerAllBands }
    @State private var selectedSwatch: Int = 0
    // Folds inside the section, not the section itself: the accordion decides whether
    // Colour is open, these three decide whether the rows under one of its headers are.
    @State private var mixerExpanded: Bool = true
    @State private var pointExpanded: Bool = true
    /// Only ever consulted while the treatment is on — see `blackAndWhiteSection`, where
    /// the header stops offering a chevron once there is nothing behind it to fold.
    @State private var bwExpanded: Bool = true

    /// nil renders every section this panel owns, which is what the tab did.
    ///
    /// Never a filter between the three groups below — `WorkspaceSection.color` holds
    /// all of them, so this is only ever the accordion naming this panel's one section
    /// or naming one it does not own.
    var only: WorkspaceSection?

    /// Spelled out because the synthesised memberwise initialiser is private the moment
    /// any stored property is, and every `@State` fold above is. Without this,
    /// `ColorPanel(only:)` would not be callable from the column that draws it.
    init(only: WorkspaceSection? = nil) {
        self.only = only
    }

    /// What the three headers below pass for `LumenSectionHeader.topRhythm`, which is
    /// that parameter's own distinction: 20 is a section boundary, 10 is a fold.
    ///
    /// Under `only:` the column has already printed the section header above these, so a
    /// second full boundary would make each sub-heading shout as loudly as the heading
    /// it sits under. With `only` nil this panel IS the column and they are top-level
    /// sections, which is the 16 they have always had.
    /// Tracks `LumenSectionHeader.topRhythm`, which moved to 20 for a section boundary
    /// and 10 for a fold when the accordion's sections became cards. These were 16 and 8
    /// and their prose still said so, which is a ratio drifting out of step with the
    /// control it is supposed to match — invisible while both sides pass explicit
    /// values, and exactly the sort of thing that is wrong for a year.
    private var innerRhythm: CGFloat { only == nil ? 20 : 10 }

    // MARK: - Body

    var body: some View {
        // No ScrollView, no outer padding, no background. `DevelopPanel.scrollColumn`
        // supplies all three around whatever a section draws, and a second ScrollView
        // inside a scrolling column is a scroll trap: the wheel would stop moving the
        // column wherever the pointer happened to be over these rows.
        VStack(alignment: .leading, spacing: Lumen.rowGap) {
            if only == nil || only == .color {
                // The rules between these three are gone: each header carries its own
                // boundary now (`LumenSectionHeader.topRhythm`, sized by
                // `innerRhythm`), which is how every reference app separates sections
                // and how BasicPanel already did. Design audit §1.1.
                mixerSection
                pointColorSection
                blackAndWhiteSection
            }
        }
    }

    // MARK: - Mixer

    private var mixerSection: some View {
        let mixer = state.currentRecipe.develop.mixer
        let bands = ColorPanel.normalizedBands(mixer.bands)
        // The engine's own resolved geometry, not the raw wire values: the ring must
        // draw the arc the pixel loop uses, including the min-reach clamp, or a handle
        // dragged past the limit would sit somewhere the render disagrees with.
        let arcs = ColorEngine.bandArcs(bands)
        let touched = bands.contains(where: { $0.hue != 0 || $0.sat != 0 || $0.lum != 0 })
        let reshaped = arcs != ColorEngine.canonicalArcs
        let modified = touched || mixer.uniformity != 0 || reshaped
        let index = min(max(selectedBand, 0), ColorEngine.bandCount - 1)

        return VStack(alignment: .leading, spacing: Lumen.rowGap) {
            LumenSectionHeader(title: "Colour Mixer",
                               isExpanded: $mixerExpanded,
                               isModified: modified,
                               onReset: { state.updateRecipe { $0.develop.mixer = Mixer() } },
                               topRhythm: innerRhythm)

            if mixerExpanded {
                // PICKER FIRST (docs/28 Phase 5). Before this row, using the mixer began
                // with a question the panel would not answer: which of Red, Orange,
                // Yellow, Green, Aqua, Blue, Purple and Magenta owns the colour you want
                // to change? A photographer knows the sky and the skin; nobody knows
                // which 45° arc of OKLCh they fall in, and guessing wrong means three
                // sliders that appear to do nothing. Capture One's most-praised colour
                // idea is that you eyedrop the colour and the band selects itself, and
                // the engine can already answer it — `ColorEngine.dominantBand` is the
                // argmax of the same membership vector the pixel loop uses.
                HStack(spacing: 6) {
                    pickBandButton
                    Spacer(minLength: 8)
                    LumenSegmented(options: [(value: false, label: "Band"),
                                             (value: true, label: "All bands")],
                                   selection: Binding(get: { state.mixerAllBands },
                                                      set: { state.mixerAllBands = $0 }))
                        // `maxWidth`, not `width`: this was sized by eye against a
                        // 300pt content area and the column is draggable now, so a hard
                        // 150 overflows the moment someone narrows it.
                        .frame(maxWidth: 150)
                }
                .padding(.vertical, 2)

                bandSwatches(bands)

                bandReach(arcs, index)

                // The tracks carry the band's own colour, which also makes the track say
                // what the row's SCOPE is: in All bands there is no single band's colour
                // to show, so the three rows go back to the neutral groove and the
                // ordinary deviation fill. See `mixerStops`.
                LumenSlider(title: "Hue", value: mixerBinding(.hue),
                            range: -100...100, defaultValue: 0, step: 1, decimals: 0,
                            trackStops: mixerStops(ColorPanel.mixerHueStops, index),
                            help: "Turns the band's colours toward a neighbour — the "
                                + "track shows which way, and ±100 lands exactly on "
                                + "the next band's hue.")
                LumenSlider(title: "Saturation", value: mixerBinding(.sat),
                            range: -100...100, defaultValue: 0, step: 1, decimals: 0,
                            trackStops: mixerStops(ColorPanel.mixerSaturationStops, index),
                            help: "Strengthens or mutes just this band's colours; "
                                + "−100 takes them to grey.")
                LumenSlider(title: "Luminance", value: mixerBinding(.lum),
                            range: -100...100, defaultValue: 0, step: 1, decimals: 0,
                            trackStops: mixerStops(ColorPanel.mixerLuminanceStops, index),
                            help: "Lightens or darkens this band's colours without "
                                + "draining them — a darkened sky stays blue.")

                // Not inside the band block above, and named for what it is. There is
                // one `Mixer.uniformity` on the wire and the engine applies it to all
                // eight bands, each converging on its own core arc — so selecting Blue
                // and dragging this also pulls skin toward Orange.
                //
                // This rule SURVIVES the hairline cull (design audit §1.1) on purpose:
                // it does not fence two sections — those are spaced apart now — it marks
                // a change of scope inside one, from "the selected band" to "every
                // band". Space alone would read as an ordinary gap between rows, and
                // reading this row as per-band is a wrong edit, not an ugly one. It is
                // now the only thing on screen that marks the change of scope, which is
                // what it was always for.
                // AND THEN IT WENT TOO (U2), with ZonesPanel's twin and for the same
                // reason: it was the last pair of rules in the owned panels, the
                // direction says there are none, and eight points of space where the
                // rows run at two reads as a break without drawing a stroke inches from
                // a photograph. The claim above — that misreading this row as per-band
                // is a wrong edit rather than an ugly one — still holds, and if the
                // space turns out not to carry it, the upgrade is to NAME the scope
                // with a group marker rather than to bring the line back.
                Color.clear.frame(height: 8)

                // "Even out hues", not "Uniformity". The coalescing key stays
                // `mixer.uniformity` and so does the wire field; this is the label doing
                // the caption's job. "Uniformity" is a word out of the format, and it
                // took sixty-two words underneath it to turn back into an instruction —
                // which is the definition of a control that has not been designed yet.
                LumenSlider(title: "Even out hues",
                            value: bind("mixer.uniformity",
                                        get: { $0.develop.mixer.uniformity },
                                        set: { $0.develop.mixer.uniformity = $1 }),
                            range: 0...100, defaultValue: 0, step: 1, decimals: 0,
                            bipolar: false,
                            help: "Gathers scattered hues in toward each band's own "
                                + "centre — calms mottled colour like patchy skin or a "
                                + "streaky sky. Works on all eight bands at once, "
                                + "whatever is selected above.")
            }
        }
    }

    // MARK: - Ring handles (D13: visible, draggable range + feather)

    /// Write one dragged handle back into the band's wire geometry.
    ///
    /// Everything is stored relative to the band's canonical centre, and the centre
    /// itself never moves — it is the wire format's identity for the band. Dragging the
    /// two inner handles to the same side is how you re-centre the band on a colour, and
    /// `ColorEngine.BandArc.coreCentre` is what reads that back out for Uniformity.
    private func moveHandle(_ band: Int, _ handle: MixerArcHandle, to degrees: Double) {
        state.updateRecipe(coalescingKey: "mixer.arc.\(band).\(handle.rawValue)") { recipe in
            var bands = ColorPanel.normalizedBands(recipe.develop.mixer.bands)
            guard bands.indices.contains(band),
                  ColorEngine.bandHueCentres.indices.contains(band) else { return }
            let centre = ColorEngine.bandHueCentres[band]
            let delta = Num.hueDelta(centre, degrees)     // signed, (−180, 180]
            var core = ColorPanel.pair(bands[band].core, MixerBand.defaultCore)
            var feather = ColorPanel.pair(bands[band].feather, MixerBand.defaultFeather)
            let coreLo = ColorEngine.bandCoreMinDegrees
            let coreHi = ColorEngine.bandCoreMaxDegrees
            let featherLo = ColorEngine.bandFeatherMinDegrees
            let featherHi = ColorEngine.bandFeatherMaxDegrees
            switch handle {
            case .coreStart:
                core[0] = Num.clamp(-delta, coreLo, coreHi)
            case .coreEnd:
                core[1] = Num.clamp(delta, coreLo, coreHi)
            case .featherStart:
                feather[0] = Num.clamp(-delta - core[0], featherLo, featherHi)
            case .featherEnd:
                feather[1] = Num.clamp(delta - core[1], featherLo, featherHi)
            }
            bands[band].core = core
            bands[band].feather = feather
            recipe.develop.mixer.bands = bands
        }
    }

    /// Back to the canonical wedge, leaving the band's three sliders alone.
    private func resetArc(_ band: Int) {
        state.updateRecipe { recipe in
            var bands = ColorPanel.normalizedBands(recipe.develop.mixer.bands)
            guard bands.indices.contains(band) else { return }
            bands[band].core = MixerBand.defaultCore
            bands[band].feather = MixerBand.defaultFeather
            recipe.develop.mixer.bands = bands
        }
    }

    /// Ring, ribbon and the sentence under them — the three views that answer "what does
    /// this band reach", grouped so `mixerSection`'s builder stays inside its ten-child
    /// limit and so the three can never be shown without each other.
    private func bandReach(_ arcs: [ColorEngine.BandArc], _ index: Int) -> some View {
        VStack(alignment: .leading, spacing: Lumen.rowGap) {
            MixerHueRing(arcs: arcs,
                         selected: index,
                         allBands: allBands,
                         onHandleMoved: { handle, degrees in
                             moveHandle(index, handle, to: degrees)
                         },
                         onResetArc: { resetArc(index) })

            MixerBandRibbon(weights: ColorPanel.ribbonWeights(arcs),
                            colors: ColorPanel.bandSwatchColors,
                            selected: index,
                            allBands: allBands)

            Text(allBands
                 ? "All bands move together; the spread between them is preserved."
                 : "\(ColorPanel.bandName(index)) — centred on "
                   + String(format: "%.1f°", ColorPanel.bandCentre(index))
                   + " in OKLCh, " + ColorPanel.arcSummary(arcs, index))
                .font(.lumenCaption)
                .foregroundStyle(Lumen.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 2)
        }
    }

    /// NOT BUTTONS ANY MORE, and that is the fix rather than a regression. A `.plain`
    /// button still paints its own pressed state over the label, and on a strip of
    /// full-bleed colour chips that read as a flash with no padding — the owner named
    /// it: "when I press on them, they highlight… it doesn't have any padding so it
    /// looks kind of weird" (docs/32 Stream D item 2, removal preferred). A tap gesture
    /// selects identically and draws nothing; the selection RING is the state, and the
    /// pointing hand is what says the chips are click targets.
    private func bandSwatches(_ bands: [MixerBand]) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(0..<ColorEngine.bandCount), id: \.self) { index in
                let isSelected = !allBands && index == selectedBand
                let touched = index < bands.count
                    && (bands[index].hue != 0 || bands[index].sat != 0 || bands[index].lum != 0)
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: Lumen.radiusChip, style: .continuous)
                        .fill(ColorPanel.swatch(index))
                        .frame(height: 16)
                        .opacity(allBands ? 0.55 : 1)
                        .overlay(
                            RoundedRectangle(cornerRadius: Lumen.radiusChip, style: .continuous)
                                .strokeBorder(isSelected ? Lumen.primaryText : Lumen.separator,
                                              lineWidth: isSelected ? 1.5 : 0.5)
                        )
                    if touched {
                        Circle()
                            .fill(Lumen.primaryText)
                            .frame(width: 3, height: 3)
                            .padding(2)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    state.mixerAllBands = false
                    state.mixerBand = index
                }
                .lumenClickCursor()
                .help(ColorPanel.bandName(index))
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Point colour

    private var pointColorSection: some View {
        let swatches = state.currentRecipe.develop.pointColors
        let index: Int? = swatches.isEmpty
            ? nil : min(max(selectedSwatch, 0), swatches.count - 1)
        // Branched in locals rather than as ternaries in the argument lists below —
        // a multi-line ternary in an argument list is the one shape
        // `check-swift-surface.py` is known to mis-read (docs/32 ground rule 4).
        let pickHelp: String
        if pickIsArmed {
            pickHelp = "Click the colour in the photograph to add it as a swatch — "
                + "or click here again to cancel the pick"
        } else {
            pickHelp = "Add a swatch: pick it from the photo. Click this, then click "
                + "the colour in the photograph (up to \(ColorPanel.maxSwatches))."
        }
        let pickTint: Color
        if pickIsArmed {
            pickTint = Lumen.accent
        } else if swatches.count < ColorPanel.maxSwatches {
            pickTint = Lumen.primaryText
        } else {
            pickTint = Lumen.secondaryText
        }

        return VStack(alignment: .leading, spacing: Lumen.rowGap) {
            LumenSectionHeader(title: "Point Colour",
                               isExpanded: $pointExpanded,
                               isModified: !swatches.isEmpty,
                               onReset: { state.updateRecipe { $0.develop.pointColors = [] } },
                               topRhythm: innerRhythm)

            if pointExpanded {
                HStack(spacing: 4) {
                    // Tap targets, not `Button`s — the same press-flash removal as the
                    // mixer's band strip above, and for the same owner sentence. The
                    // ring is the selection state; the hand is the affordance.
                    ForEach(Array(swatches.indices), id: \.self) { i in
                        swatchChip(i, color: swatches[i], ringed: i == index)
                    }
                    Spacer(minLength: 0)
                    // THE EYEDROPPER IT ALWAYS WAS. This button never appended a
                    // swatch; it arms a pick and the swatch is born from the click on
                    // the photograph — but it wore a bare `+`, so nothing said "now go
                    // click the picture". The glyph now names the gesture, the armed
                    // state shows (fill, accent), and pressing again disarms — the
                    // same contract as the band eyedropper above and the white-balance
                    // picker in BasicPanel.
                    Button(action: addSwatch) {
                        Image(systemName: "eyedropper")
                            .font(.lumenGlyphCaptionStrong)
                            // The glyph's own bounds are no hit target. The printer
                            // rows measured this exact defect (docs/30 §2.3): 24 points
                            // by the row's height, paid for out of the Spacer.
                            .frame(width: 24, height: Lumen.rowHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(pickTint)
                    .background(
                        RoundedRectangle(cornerRadius: Lumen.radiusChip, style: .continuous)
                            .fill(pickIsArmed ? Lumen.fillColor.opacity(0.35) : Color.clear))
                    .disabled(!pickIsArmed && swatches.count >= ColorPanel.maxSwatches)
                    .lumenClickCursor()
                    .help(pickHelp)

                    Button(action: removeSwatch) {
                        Image(systemName: "minus")
                            // 10, the app's own stated floor, which it set and then
                            // never enforced.
                            .font(.lumenGlyphCaptionStrong)
                            // The old hit area was the glyph itself — a bar a couple of
                            // points tall, the least hittable target in the app, which
                            // is most of why this button "did nothing".
                            .frame(width: 24, height: Lumen.rowHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(index == nil ? Lumen.secondaryText : Lumen.primaryText)
                    .disabled(index == nil)
                    .lumenClickCursor()
                    .help("Remove the ringed swatch and its edit")
                }
                .frame(height: Lumen.rowHeight)

                // Nothing when the list is empty. The eyedropper in the row above is
                // the whole message; a sentence defining what a swatch would do is
                // answering a question nobody asks with an empty row in front of them.
                if let index {
                    LumenSlider(title: "Hue", value: pointBinding(index, .hue),
                                range: -60...60, defaultValue: 0, step: 1, decimals: 0,
                                help: "Turns the picked colour toward a neighbouring "
                                    + "hue, up to 60° either way — only pixels near the "
                                    + "swatch follow.")
                    LumenSlider(title: "Saturation", value: pointBinding(index, .sat),
                                range: -100...100, defaultValue: 0, step: 1, decimals: 0,
                                help: "Strengthens or mutes just the picked colour — "
                                    + "the rest of the photograph is untouched.")
                    LumenSlider(title: "Luminance", value: pointBinding(index, .lum),
                                range: -100...100, defaultValue: 0, step: 1, decimals: 0,
                                help: "Lightens or darkens the picked colour without "
                                    + "washing it out.")
                    LumenSlider(title: "Range", value: pointBinding(index, .range),
                                range: 0...100, defaultValue: 50, step: 1, decimals: 0,
                                bipolar: false,
                                help: "How far around the picked colour the edit "
                                    + "reaches — low is surgical, high feathers into "
                                    + "the neighbours.")
                    LumenSlider(title: "Variance", value: pointBinding(index, .variance),
                                range: -100...100, defaultValue: 0, step: 1, decimals: 0,
                                help: "Negative gathers the nearby hues in toward the "
                                    + "swatch, evening them out; positive spreads them "
                                    + "apart.")
                }
            }
        }
        // A NEW SWATCH IS THE SELECTED SWATCH. The eyedropper's pick resolves on
        // `AppState` and appends to the tail — it cannot reach this panel's `@State`,
        // so the ring used to stay on the old chip and the sliders went on editing a
        // swatch the photographer had just moved past. Watching the count is the one
        // signal that reaches here: growth means an arrival (a pick, or an undo giving
        // one back), and the tail is the arrival. Shrinkage is left alone —
        // `removeSwatch` already re-aims the ring, and a photo switch's display path
        // clamps.
        .onChange(of: swatches.count) { old, new in
            if new > old { selectedSwatch = new - 1 }
        }
    }

    /// One swatch chip: the colour, the ring that marks the selection, and — on the
    /// chip the ring is already on — the eyedropper that re-samples it.
    ///
    /// Branched into locals rather than written as ternaries in the argument lists,
    /// which is this file's own ground rule (see `pointColorSection`).
    private func swatchChip(_ i: Int, color: PointColor, ringed: Bool) -> some View {
        let armed = state.pickTarget == .pointColor(index: i)
        let border: Color
        if armed {
            border = Lumen.accent
        } else if ringed {
            border = Lumen.primaryText
        } else {
            border = Lumen.separator
        }
        let borderWidth: CGFloat = (armed || ringed) ? 1.5 : 0.5
        let help: String
        if armed {
            help = "Click the colour in the photograph to re-sample swatch \(i + 1) — "
                + "or click this chip again to cancel the pick."
        } else if ringed {
            help = "Swatch \(i + 1), the one the sliders and the − button act on. "
                + "Click it again to re-pick its colour from the photograph, keeping "
                + "the Hue, Saturation, Luminance, Range and Variance already dialled "
                + "into it."
        } else {
            help = "Swatch \(i + 1) — a colour picked from the photo. "
                + "Click it to edit this one; the ring marks the "
                + "swatch the sliders and the − button act on."
        }
        return RoundedRectangle(cornerRadius: Lumen.radiusChip, style: .continuous)
            .fill(ColorPanel.chipColor(color))
            .frame(width: 22, height: 16)
            .overlay(
                // The armed state has to be visible ON the chip: the ring alone says
                // "selected", and a photographer who cannot see which pick is armed
                // finds out by changing the picture.
                Image(systemName: "eyedropper")
                    .font(.lumenGlyphCaptionStrong)
                    .foregroundStyle(Lumen.accent)
                    .opacity(armed ? 1 : 0)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Lumen.radiusChip, style: .continuous)
                    .strokeBorder(border, lineWidth: borderWidth)
            )
            .contentShape(Rectangle())
            .onTapGesture { tapSwatch(i) }
            .lumenClickCursor()
            .help(help)
    }

    /// A click on a chip. An unringed one SELECTS; the ringed one ARMS A RE-PICK.
    ///
    /// `PickTarget.pointColor(index:)` — "re-sample an existing swatch" — was fully
    /// implemented on both ends and had no producer anywhere in the app, so the only
    /// route to fixing a mis-aimed swatch was − then the eyedropper again: that
    /// appends a fresh swatch at the tail and throws away the five slider values
    /// already dialled into the old one. Eyedropping a shirt and catching the fold
    /// instead of the fabric cost the whole edit.
    ///
    /// The gesture is the chip itself rather than a third button in the row, because
    /// the row is already 264 pt of a 292 pt column at eight swatches (G1's measured
    /// widths) and a 24 pt button would take the last of it. A click on the ringed
    /// chip means nothing today — it re-selects what is already selected — so this
    /// takes a press that is currently inert, not one that already did something.
    ///
    /// Arming, disarming and the armed paint follow the two eyedroppers this panel
    /// already has (`addSwatch`, `pickBandButton`): pressing an armed affordance again
    /// cancels rather than stacking a second pick.
    private func tapSwatch(_ i: Int) {
        // The ring sits on the CLAMPED selection, and `removalTarget` is that clamp —
        // shared rather than restated, because "the chip the ring is on" is one fact
        // and two copies of it drift (which is the defect `removalTarget` exists for).
        let count = state.currentRecipe.develop.pointColors.count
        guard ColorPanel.removalTarget(selected: selectedSwatch, count: count) == i else {
            selectedSwatch = i
            return
        }
        if state.pickTarget == .pointColor(index: i) {
            state.cancelPick()
            return
        }
        state.beginPick(.pointColor(index: i))
    }

    /// Whether the point-colour eyedropper is armed — the button reads its state from
    /// the pick machinery itself, so the two cannot disagree about whose click the
    /// next click on the photograph is.
    private var pickIsArmed: Bool { state.pickTarget == .newPointColor }

    /// Arms a pick rather than appending a grey swatch and hoping.
    ///
    /// Every swatch used to be born `[0.18, 0.18, 0.18]`, and with a neutral target the
    /// chordal hue term is identically zero — so the control was not merely
    /// unconfigured, it was a "low-chroma mid-tones" selector wearing five sliders. The
    /// swatch now comes into existence carrying a colour, so there is no state in which
    /// it looks live and selects nothing.
    ///
    /// Pressing the armed eyedropper again disarms it instead of stacking a second
    /// pick — the contract `pickBandButton` and BasicPanel's white-balance picker
    /// already keep, and the way out for someone who armed it by accident.
    private func addSwatch() {
        if pickIsArmed {
            state.cancelPick()
            return
        }
        guard state.currentRecipe.develop.pointColors.count < ColorPanel.maxSwatches
        else { return }
        state.beginPick(.newPointColor)
    }

    /// The mixer's eyedropper. Armed, it reads as armed — pressing it again disarms
    /// rather than stacking a second pick, which is the same contract the white-balance
    /// picker in BasicPanel already has.
    private var pickBandButton: some View {
        let armed = state.pickTarget == .mixerBand
        return Button {
            if armed {
                state.cancelPick()
            } else {
                state.beginPick(.mixerBand)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "eyedropper")
                    .font(.lumenGlyphCaption)
                Text(armed ? "Click a colour" : "Pick a colour")
                    .font(.lumenCaption)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .foregroundStyle(armed ? Lumen.primaryText : Lumen.secondaryText)
            .background(armed ? Lumen.fillColor.opacity(0.35) : Lumen.controlBackground)
            .clipShape(RoundedRectangle(cornerRadius: Lumen.radiusChip, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(state.primarySelection == nil)
        .help("Click a colour in the photograph and the band grading it selects itself")
    }

    /// Remove the swatch the RING marks, not the one a stale `@State` remembers.
    ///
    /// The defect this replaces (docs/32 Stream D item 3, "the minus button does
    /// nothing"): `selectedSwatch` is view state and photos are not, so after a photo
    /// switch — or after deleting the tail swatch — it can point past the current
    /// list's end. Every reader on screen clamps it (`pointColorSection`'s `index`
    /// drives the ring, the sliders and the button's enabled state), but this function
    /// read it RAW, and the mutation's own bounds guard then turned the click into a
    /// silent no-op: the button looked enabled, the ring marked a chip, and nothing
    /// happened. The clamp is `removalTarget` below — one pure function shared with
    /// the regression test, so the index removed is provably the index displayed.
    private func removeSwatch() {
        guard let target = ColorPanel.removalTarget(
            selected: selectedSwatch,
            count: state.currentRecipe.develop.pointColors.count) else { return }
        state.updateRecipe { recipe in
            // Re-guarded per recipe: a multi-selection edit visits photos whose lists
            // can be shorter than the primary's, and those keep the old skip.
            guard recipe.develop.pointColors.indices.contains(target) else { return }
            recipe.develop.pointColors.remove(at: target)
        }
        selectedSwatch = ColorPanel.selectionAfterRemoval(
            of: target, newCount: state.currentRecipe.develop.pointColors.count)
    }

    /// The index the minus button removes: the displayed (clamped) selection, or nil
    /// when there is nothing to remove. Static and pure so
    /// `PointColorSwatchTests` can pin it without an `AppState`.
    static func removalTarget(selected: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return min(max(selected, 0), count - 1)
    }

    /// Where the ring lands after a removal: the same slot if one moved up into it,
    /// else the new tail, floored at zero for the empty list.
    static func selectionAfterRemoval(of target: Int, newCount: Int) -> Int {
        max(0, min(target, newCount - 1))
    }

    // MARK: - Black & white

    /// THE CHEVRON FOLLOWS THE CONTENT. With the treatment off this section is one
    /// switch, and the disclosure existed to hide that one switch — a full chevron over
    /// a single row, which is why Black & White reads as a third of this panel when it
    /// only becomes one after it is turned on.
    ///
    /// So the switch is always drawn, and the fold appears with the eight bands it would
    /// actually be folding. `LumenSectionHeader` draws no chevron when `isExpanded` is
    /// nil, which says "nothing to fold here" without inventing a second idiom for it —
    /// and no gate can be stranded, because the switch that brings the chevron back sits
    /// outside the one it gates.
    private var blackAndWhiteSection: some View {
        let bw = state.currentRecipe.look.bw
        let isOn = state.currentRecipe.look.blackAndWhiteIsOn
        let fold: Binding<Bool>? = isOn ? $bwExpanded : nil

        return VStack(alignment: .leading, spacing: Lumen.rowGap) {
            LumenSectionHeader(title: "Black & White",
                               isExpanded: fold,
                               isModified: bw != nil,
                               onReset: { state.updateRecipe { $0.look.bw = nil } },
                               topRhythm: innerRhythm)

            LumenToggleRow(title: "Black & white treatment",
                           isOn: Binding(get: { isOn }, set: { setTreatment($0) }),
                           help: "Toggling the treatment keeps both sets of settings "
                               + "with this photo — the mix is stored in its recipe "
                               + "and the colour mixer is not touched. Reset above "
                               + "is what discards the mix.")

            // Off draws the switch and nothing else. Three captions stood here — one
            // naming the eight bands as the mixer's, one promising the mix survives the
            // toggle, and one whose entire content was the word "Off." directly under a
            // switch that was off. The promise is kept by `BlackAndWhite.toggled`
            // writing `bw.enabled` rather than deleting the slot, and by the mixer
            // living in `develop.mixer` where this never reaches; a sentence was never
            // what kept it.
            if isOn, bwExpanded {
                // The help names the band and states the one rule (docs/24 §8: the
                // per-band luminance contribution of the classic channel mixer):
                // what was that colour prints lighter or darker, greys cannot move.
                // The two worked examples are the moves every darkroom text teaches —
                // the red filter's dark sky, the orange filter's open skin.
                ForEach(Array(0..<ColorEngine.bandCount), id: \.self) { i in
                    LumenSlider(title: ColorPanel.bandName(i),
                                value: bwBinding(i),
                                range: -100...100, defaultValue: 0, step: 1, decimals: 0,
                                help: "How bright what was "
                                    + ColorPanel.bandName(i).lowercased()
                                    + " prints in the black-and-white mix — up "
                                    + "lightens it, down darkens it, greys stay put. "
                                    + "The classic moves: drop Blue for a dramatic "
                                    + "sky, lift Red and Orange to open up skin.")
                }
            }
        }
    }

    /// One boolean per photo, and every photo answers with its own mix.
    ///
    /// `updateRecipe` runs this closure once per edit target, so a multi-selection
    /// toggle now gives each frame back what it had. The version this replaced restored
    /// from a stash held on the view, which named no photo: toggling off on one frame
    /// and on again on another wrote the first frame's mix into the second's recipe and
    /// into every frame selected with it.
    private func setTreatment(_ on: Bool) {
        state.updateRecipe { recipe in
            recipe.look.bw = BlackAndWhite.toggled(recipe.look.bw, on: on)
        }
    }

    // MARK: - Bindings

    private enum MixerComponent: String {
        case hue, sat, lum

        func value(_ band: MixerBand) -> Double {
            switch self {
            case .hue: return band.hue
            case .sat: return band.sat
            case .lum: return band.lum
            }
        }

        func write(_ band: inout MixerBand, _ v: Double) {
            switch self {
            case .hue: band.hue = v
            case .sat: band.sat = v
            case .lum: band.lum = v
            }
        }
    }

    /// One slider, two modes. In "all bands" the slider reads the mean and writes the
    /// difference, so a global move keeps whatever spread the user built by hand.
    ///
    /// THE GROUP MOVE IS `GroupMove`, NOT A PER-BAND CLAMP (B3-01). This row clamped each
    /// band into ±100 as it went, which is not the same operation: with bands at
    /// `[+50, −50, 0 …]` the mean is 0, and dragging to +100 asks band 0 for 150 — clipped
    /// to 100 — while every other band moves the full 100. The 100-unit difference the
    /// photographer built between Red and Blue is squeezed to 50 at the rail and does NOT
    /// come back when the drag comes back, under a caption promising in as many words
    /// that "the spread between them is preserved".
    ///
    /// `GroupMove.allowed` stops the SET when the first member reaches the rail, so the
    /// move is a rigid translation: every difference inside the set survives it exactly,
    /// and dragging back restores the set bit for bit. The rule and its properties live
    /// in LumenCore, where they are tested; the panel does not restate them.
    private func mixerBinding(_ component: MixerComponent) -> Binding<Double> {
        Binding(
            get: {
                let bands = ColorPanel.normalizedBands(state.currentRecipe.develop.mixer.bands)
                if allBands {
                    return GroupMove.mean(bands.map { component.value($0) })
                }
                let i = min(max(selectedBand, 0), bands.count - 1)
                return component.value(bands[i])
            },
            set: { newValue in
                let key = "mixer.\(component.rawValue).\(allBands ? -1 : selectedBand)"
                let everything = allBands
                let index = selectedBand
                state.updateRecipe(coalescingKey: key) { recipe in
                    var bands = ColorPanel.normalizedBands(recipe.develop.mixer.bands)
                    if everything {
                        let values = bands.map { component.value($0) }
                        let moved = GroupMove.moved(values,
                                                    by: newValue - GroupMove.mean(values),
                                                    lower: -100, upper: 100)
                        for i in bands.indices where i < moved.count {
                            component.write(&bands[i], moved[i])
                        }
                    } else {
                        let i = min(max(index, 0), bands.count - 1)
                        component.write(&bands[i], Num.clamp(newValue, -100, 100))
                    }
                    recipe.develop.mixer.bands = bands
                }
            })
    }

    private enum PointComponent: String {
        case hue, sat, lum, range, variance

        func value(_ p: PointColor) -> Double {
            switch self {
            case .hue: return p.shift.h
            case .sat: return p.shift.s
            case .lum: return p.shift.l
            case .range: return p.range
            case .variance: return p.variance
            }
        }

        func write(_ p: inout PointColor, _ v: Double) {
            switch self {
            case .hue: p.shift.h = Num.clamp(v, -60, 60)
            case .sat: p.shift.s = Num.clamp(v, -100, 100)
            case .lum: p.shift.l = Num.clamp(v, -100, 100)
            case .range: p.range = Num.clamp(v, 0, 100)
            case .variance: p.variance = Num.clamp(v, -100, 100)
            }
        }
    }

    private func pointBinding(_ index: Int, _ component: PointComponent) -> Binding<Double> {
        Binding(
            get: {
                let list = state.currentRecipe.develop.pointColors
                guard list.indices.contains(index) else { return 0 }
                return component.value(list[index])
            },
            set: { newValue in
                state.updateRecipe(coalescingKey: "point.\(index).\(component.rawValue)") { recipe in
                    guard recipe.develop.pointColors.indices.contains(index) else { return }
                    component.write(&recipe.develop.pointColors[index], newValue)
                }
            })
    }

    private func bwBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: {
                let bands = ColorPanel.normalizedDoubles(state.currentRecipe.look.bw?.bands)
                guard bands.indices.contains(index) else { return 0 }
                return bands[index]
            },
            set: { newValue in
                state.updateRecipe(coalescingKey: "bw.\(index)") { recipe in
                    var bands = ColorPanel.normalizedDoubles(recipe.look.bw?.bands)
                    guard bands.indices.contains(index) else { return }
                    bands[index] = Num.clamp(newValue, -100, 100)
                    // The slider is only reachable while the treatment is on, but the
                    // flag is carried rather than reasserted: a write that assumes a
                    // state instead of preserving it is how the old stash worked.
                    recipe.look.bw = BlackAndWhite(bands: bands,
                                                   enabled: recipe.look.bw?.enabled ?? true)
                }
            })
    }

    private func bind(_ key: String,
                      get: @escaping (Recipe) -> Double,
                      set: @escaping (inout Recipe, Double) -> Void) -> Binding<Double> {
        Binding(
            get: { get(state.currentRecipe) },
            set: { v in state.updateRecipe(coalescingKey: key) { set(&$0, v) } })
    }

    // NO `caption` HELPER, AND NO CAPTIONS. All seven were non-prominent
    // `DevelopNote`s, which render nothing at all since docs/30 Phase A item 3 — seven
    // strings built on every redraw of this panel for a view nobody could see. Five
    // were explanation, one has become a slider's name ("Even out hues"), and one read
    // "Off." underneath a switch that was off.
    //
    // The live band readout ("Red — centred on 29.2° in OKLCh…") never went through
    // here and stays where it is: it is a raw `Text` further up, because it is an
    // instrument rather than teaching, and it changes as you drag.

    // MARK: - Static helpers

    static let maxSwatches: Int = 8

    /// The recipe guarantees eight bands; a decoded file does not. Every read and every
    /// write goes through here, so an eight-slider panel can never index past the end.
    static func normalizedBands(_ bands: [MixerBand]) -> [MixerBand] {
        var out = bands.count > ColorEngine.bandCount
            ? Array(bands.prefix(ColorEngine.bandCount)) : bands
        while out.count < ColorEngine.bandCount { out.append(MixerBand()) }
        return out
    }

    static func normalizedDoubles(_ values: [Double]?) -> [Double] {
        var out = values ?? []
        if out.count > ColorEngine.bandCount { out = Array(out.prefix(ColorEngine.bandCount)) }
        while out.count < ColorEngine.bandCount { out.append(0) }
        return out
    }

    static func bandName(_ index: Int) -> String {
        let names = ColorEngine.bandNames
        guard names.indices.contains(index) else { return "Band \(index + 1)" }
        return names[index]
    }

    static func bandCentre(_ index: Int) -> Double {
        let centres = ColorEngine.bandHueCentres
        guard centres.indices.contains(index) else { return 0 }
        return centres[index]
    }

    /// The stops for one band's row, or nil for a neutral track.
    ///
    /// Nil in All-bands mode on purpose: the row then acts on every band at once, and a
    /// track wearing Blue's colours while the drag also moves skin would be the panel
    /// lying about scope. The bounds check is not defensive noise either — the tables
    /// are sized from the swatch list and the index comes from `ColorEngine.bandCount`,
    /// two constants that agree today and are declared in different modules.
    private func mixerStops(_ table: [[LumenTrackStop]], _ index: Int) -> [LumenTrackStop]? {
        guard !allBands, table.indices.contains(index) else { return nil }
        return table[index]
    }

    static func swatch(_ index: Int) -> Color {
        guard bandSwatchColors.indices.contains(index) else { return Lumen.controlBackground }
        return bandSwatchColors[index]
    }

    /// Reference colours, not the OKLCh centres: the swatch labelled Orange has to look
    /// orange (docs/06 brief §1.1). The centres are what the ribbon plots.
    ///
    /// Held as components rather than as `Color` because the coloured tracks below need
    /// darker, lighter and greyer versions of each band, and a `Color` cannot be taken
    /// apart portably. `bandSwatchColors` derives from this, so there is still exactly
    /// one answer to what Orange looks like.
    static let bandSwatchComponents: [(r: Double, g: Double, b: Double)] = [
        (0.84, 0.24, 0.22),
        (0.86, 0.51, 0.18),
        (0.84, 0.77, 0.24),
        (0.34, 0.69, 0.34),
        (0.26, 0.71, 0.71),
        (0.28, 0.46, 0.84),
        (0.55, 0.35, 0.82),
        (0.82, 0.30, 0.66),
    ]

    static let bandSwatchColors: [Color] = bandSwatchComponents.map {
        Color(red: $0.r, green: $0.g, blue: $0.b)
    }

    // MARK: Coloured tracks for the three band rows (docs/28 Phase 2)

    // Law 7's colour-axis exception (docs/00, amended 2026-08-29) covers exactly these
    // three: Hue, Saturation and Luminance in the mixer are axes whose units ARE colour,
    // so the track can say what the row does before the row is touched. Today all three
    // are the same grey, and which of eight bands owns the colour under the cursor is
    // something the photographer has to already know.
    //
    // All three tables are STATIC — built once from `bandSwatchComponents`, never
    // computed in a `body` from recipe values. A track whose colour depended on the
    // recipe would make every mixer row a reader of the edit signal, and a Hue drag
    // rebuilds its panel on every mouse event.
    //
    // They are reference colours for the same reason the swatches are: the band arcs are
    // editable, so the live centres move, and a track that slid its own colours around
    // under a Hue drag would be an instrument reporting on itself. The ribbon is where
    // live geometry is drawn; these say which band you are in.

    /// The hue span the row shifts between — the neighbour below, this band, the
    /// neighbour above. The ring wraps, so Red's left neighbour is Magenta.
    static let mixerHueStops: [[LumenTrackStop]] = bandSwatchColors.indices.map { i in
        let n = bandSwatchColors.count
        return [LumenTrackStop(value: -100, color: bandSwatchColors[(i + n - 1) % n]),
                LumenTrackStop(value: 0, color: bandSwatchColors[i]),
                LumenTrackStop(value: 100, color: bandSwatchColors[(i + 1) % n])]
    }

    /// Grey to vivid, in this band's own hue.
    static let mixerSaturationStops: [[LumenTrackStop]] = bandSwatchComponents.map { c in
        [LumenTrackStop(value: -100, color: greyed(c, 1.0)),
         LumenTrackStop(value: 0, color: greyed(c, 0.5)),
         LumenTrackStop(value: 100, color: Color(red: c.r, green: c.g, blue: c.b))]
    }

    /// Dark to bright, in this band's own hue.
    static let mixerLuminanceStops: [[LumenTrackStop]] = bandSwatchComponents.map { c in
        [LumenTrackStop(value: -100, color: shaded(c, 0.38)),
         LumenTrackStop(value: 0, color: Color(red: c.r, green: c.g, blue: c.b)),
         LumenTrackStop(value: 100, color: shaded(c, 1.62))]
    }

    /// Toward black below 1, toward white above it. Multiplying past 1 would clip to the
    /// same over-saturated colour for every band, which is why the light half blends
    /// toward white instead.
    private static func shaded(_ c: (r: Double, g: Double, b: Double),
                               _ lightness: Double) -> Color {
        if lightness <= 1 {
            return Color(red: c.r * lightness, green: c.g * lightness, blue: c.b * lightness)
        }
        let t = min(lightness - 1, 1)
        return Color(red: c.r + (1 - c.r) * t,
                     green: c.g + (1 - c.g) * t,
                     blue: c.b + (1 - c.b) * t)
    }

    /// Toward the colour's own luma rather than toward a fixed grey, so a desaturated
    /// yellow stays as bright as the yellow was — which is what "remove the chroma"
    /// means, and what the Luminance row's own caption promises the engine does.
    private static func greyed(_ c: (r: Double, g: Double, b: Double),
                               _ amount: Double) -> Color {
        let y = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
        return Color(red: c.r + (y - c.r) * amount,
                     green: c.g + (y - c.g) * amount,
                     blue: c.b + (y - c.b) * amount)
    }

    static let ribbonSteps: Int = 96

    /// The engine's own membership vectors. The strip is a drawing of the weights the
    /// pixel loop uses — not a picture of what they ought to look like.
    ///
    /// A function of the live arcs, not a cached constant. It was a `static let`
    /// computed once from the canonical geometry, which was correct exactly as long as
    /// the geometry could not be edited; the moment the ring's handles landed, a cached
    /// ribbon would have drawn a band's reach that the render no longer agreed with —
    /// the specific failure this panel's header says it exists to avoid.
    static func ribbonWeights(_ arcs: [ColorEngine.BandArc]) -> [[Double]] {
        var out: [[Double]] = []
        out.reserveCapacity(ColorPanel.ribbonSteps + 1)
        for step in 0...ColorPanel.ribbonSteps {
            let hue = Double(step) / Double(ColorPanel.ribbonSteps) * 360
            out.append(ColorEngine.bandWeights(hue: hue, arcs: arcs))
        }
        return out
    }

    /// Two finite values from a wire array that a decoded file could have made anything.
    static func pair(_ values: [Double], _ fallback: [Double]) -> [Double] {
        var out = fallback
        for i in 0..<2 where i < values.count && values[i].isFinite { out[i] = values[i] }
        return out
    }

    /// The sentence under the ring, in the units the handles are dragged in.
    static func arcSummary(_ arcs: [ColorEngine.BandArc], _ index: Int) -> String {
        guard arcs.indices.contains(index) else { return "feathered into its neighbours." }
        let a = arcs[index]
        return String(format: "core −%.0f°/+%.0f°, feather %.0f°/%.0f°.",
                      a.coreBelow, a.coreAbove, a.featherBelow, a.featherAbove)
    }

    /// A hue's actual colour, for the ring — evaluated through OKLCh and the working
    /// space rather than through SwiftUI's HSB, whose hue angle is a different number
    /// entirely. A ring that put "29°" somewhere other than where the engine's red band
    /// sits would be a diagram of a different tool.
    ///
    /// C 0.16, up from the 0.13 that shipped — the owner flagged the ring alongside the
    /// grading wheels as pastel, and the two took the raise together (docs/32 Stream D
    /// item 4; `LumenColorWheel.wheelColors` is the other half). The ceiling is real:
    /// at L 0.72 the sRGB gamut runs out of chroma near cyan (~200°) at about C 0.122,
    /// so that span was clipping even at 0.13 and now clips to the most saturated cyan
    /// the display has — which is the richest true answer available, and the per-channel
    /// saturate below is what keeps the clip from leaving the gamut rather than the hue.
    static func hueColor(_ degrees: Double, L: Double = 0.72, C: Double = 0.16) -> Color {
        let working = OKLabTransform.working.toRGB(OKLCh(L: L, C: C, h: degrees))
        let display = ColorPanel.workingToSRGB.apply(working)
        let encoded = TransferFunction.srgb.encode(RGB(Num.saturate(display.r),
                                                       Num.saturate(display.g),
                                                       Num.saturate(display.b)))
        return Color(red: Num.saturate(encoded.r),
                     green: Num.saturate(encoded.g),
                     blue: Num.saturate(encoded.b))
    }

    static let workingToSRGB: Mat3 = ColorEngine.workingSpace.matrix(to: .srgb)

    /// The ring's wedge colours, computed once.
    ///
    /// A hundred and eighty OKLab round trips per redraw is real work to repeat on every
    /// frame of a slider drag, and the hue circle is a constant — the same reason
    /// `ribbonWeights` used to be cached before the handles made it a function of the
    /// recipe. This one genuinely is not.
    static let ringColors: [Color] = (0..<MixerHueRing.steps).map { step in
        let a0 = Double(step) / Double(MixerHueRing.steps) * 360
        let a1 = Double(step + 1) / Double(MixerHueRing.steps) * 360
        return ColorPanel.hueColor((a0 + a1) / 2)
    }

    /// A chip for a sampled swatch. The sample is scene-linear working RGB, so it gets
    /// a rough encode before it is shown — otherwise every swatch reads as too dark.
    static func chipColor(_ point: PointColor) -> Color {
        guard point.sample.count >= 3 else { return Lumen.controlBackground }
        let r = Num.saturate(pow(Num.saturate(point.sample[0]), 1.0 / 2.2))
        let g = Num.saturate(pow(Num.saturate(point.sample[1]), 1.0 / 2.2))
        let b = Num.saturate(pow(Num.saturate(point.sample[2]), 1.0 / 2.2))
        return Color(red: r, green: g, blue: b)
    }
}

// MARK: - Hue ring

/// Which of the four handles on the selected band's arc is being dragged.
enum MixerArcHandle: String, Hashable, Sendable {
    case featherStart, coreStart, coreEnd, featherEnd
}

/// The hue ring, with the selected band's core arc and its four draggable handles.
///
/// This is the control docs/05 buys the whole Mixer entry with: Lightroom's band extents
/// are invisible AND fixed, Capture One exposes one global Smoothness, and DxO's
/// ColorWheel — the interaction grammar adopted here on purpose — is the only shipping
/// tool that lets you see and move them. Two inner handles bound the core, two outer
/// ones set the per-side falloff, and the arc drawn is the one `ColorEngine.bandArcs`
/// resolved, clamps included.
struct MixerHueRing: View {
    let arcs: [ColorEngine.BandArc]
    let selected: Int
    let allBands: Bool
    let onHandleMoved: (MixerArcHandle, Double) -> Void
    let onResetArc: () -> Void

    static let diameter: CGFloat = 118
    static let ringWidth: CGFloat = 13
    /// Steps around the ring. 180 is 2° per wedge — below the width of the thinnest
    /// feather anyone can drag, so the colour never reads as stepped.
    static let steps: Int = 180

    /// The radius the arc and its four handles are DRAWN at, for a square box of the
    /// given side. A function rather than a number inlined in the Canvas, because the
    /// hit test below has to ask the same question from outside that closure and a hit
    /// test that recomputes the geometry is a hit test that drifts off the ink.
    static func arcRadius(box: CGFloat) -> CGFloat { box / 2 - 5 }

    /// How far either side of `arcRadius` a press still counts as landing ON the arc.
    ///
    /// The ring is an ANNULUS, so its gate is two radii and not one: a press has to be
    /// far enough out to have left the hollow centre and near enough in to have not
    /// missed the ring entirely. Ten points either side is a 20 pt band around a 2.5 pt
    /// stroke — the same kind of forgiveness `SliderDrag.thumbGrabRadius` buys the
    /// thumb, for the same reason: the ink is a sight, the tolerance is what catches
    /// the hand.
    static let ringGrabBand: Double = 10

    /// Which handle the drag grabbed. Decided once, on the first event: re-deciding on
    /// every event let a fast drag hand the pointer to a neighbouring handle halfway
    /// through, which reads as the arc snapping inside out.
    @State private var grabbed: MixerArcHandle? = nil
    /// The press turned out to be a double-click reset; swallow the rest of the
    /// gesture so the reset is not immediately re-edited by the same press.
    @State private var pressWasReset = false
    /// The gesture-in-flight signal every slider fires (docs/23 audit queue item 5).
    @Environment(\.sliderGestureChanged) private var sliderGestureChanged

    var body: some View {
        let arcList = arcs
        let index = selected
        let showHandles = !allBands && arcList.indices.contains(index)
        let palette = ColorPanel.ringColors

        return ZStack {
            Canvas { context, size in
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                // The arc and its handles live OUTSIDE the colour wheel, in the margin
                // the frame reserves for them — drawn at the wheel's own radius they
                // were clipped by the view bounds and the two upper handles vanished.
                let arcRadius = MixerHueRing.arcRadius(
                    box: Swift.min(size.width, size.height))
                let outer = arcRadius - 6
                let inner = outer - MixerHueRing.ringWidth
                guard inner > 2 else { return }

                // The hue wheel itself, wedge by wedge, in real OKLCh hues.
                for step in palette.indices {
                    let a0 = Double(step) / Double(MixerHueRing.steps) * 360
                    let a1 = Double(step + 1) / Double(MixerHueRing.steps) * 360
                    var wedge = Path()
                    wedge.move(to: MixerHueRing.point(centre, inner, a0))
                    wedge.addLine(to: MixerHueRing.point(centre, outer, a0))
                    wedge.addLine(to: MixerHueRing.point(centre, outer, a1))
                    wedge.addLine(to: MixerHueRing.point(centre, inner, a1))
                    wedge.closeSubpath()
                    context.fill(wedge, with: .color(palette[step]))
                }

                // Every band's centre, as a tick: the eight fixed hues the wire format
                // is denominated in, so a re-centred core is visibly off its own tick.
                for arc in arcList {
                    var tick = Path()
                    tick.move(to: MixerHueRing.point(centre, inner - 3, arc.centre))
                    tick.addLine(to: MixerHueRing.point(centre, inner, arc.centre))
                    context.stroke(tick, with: .color(Lumen.separator), lineWidth: 1)
                }

                guard showHandles, arcList.indices.contains(index) else { return }
                let arc = arcList[index]

                // Core and feather at ONE radius, so they read as a single arc with a
                // bright middle and two dim tails: the core is what the band fully
                // claims and the feather is how it lets go, and the picture should say
                // that they are the same reach measured in two parts.
                context.stroke(MixerHueRing.arcPath(centre, arcRadius,
                                                    from: arc.centre - arc.coreBelow - arc.featherBelow,
                                                    to: arc.centre - arc.coreBelow),
                               with: .color(Lumen.primaryText.opacity(0.30)), lineWidth: 2)
                context.stroke(MixerHueRing.arcPath(centre, arcRadius,
                                                    from: arc.centre + arc.coreAbove,
                                                    to: arc.centre + arc.coreAbove + arc.featherAbove),
                               with: .color(Lumen.primaryText.opacity(0.30)), lineWidth: 2)
                context.stroke(MixerHueRing.arcPath(centre, arcRadius,
                                                    from: arc.centre - arc.coreBelow,
                                                    to: arc.centre + arc.coreAbove),
                               with: .color(Lumen.primaryText), lineWidth: 2.5)

                // Where Uniformity converges: the midpoint of the core arc, which sits
                // off the band's tick as soon as the two inner handles stop matching.
                var target = Path()
                target.move(to: MixerHueRing.point(centre, arcRadius - 4, arc.coreCentre))
                target.addLine(to: MixerHueRing.point(centre, arcRadius + 4, arc.coreCentre))
                context.stroke(target, with: .color(Lumen.accent), lineWidth: 1.5)

                for handle in MixerHueRing.allHandles {
                    let isCore = handle == .coreStart || handle == .coreEnd
                    let p = MixerHueRing.point(centre, arcRadius,
                                               MixerHueRing.degrees(of: handle, in: arc))
                    let r: CGFloat = isCore ? 4 : 3
                    let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r,
                                                     width: r * 2, height: r * 2))
                    context.fill(dot, with: .color(isCore
                                                   ? Lumen.primaryText
                                                   : Lumen.primaryText.opacity(0.55)))
                    context.stroke(dot, with: .color(Lumen.panelBackground), lineWidth: 1)
                }
            }
            .frame(width: MixerHueRing.diameter + 12, height: MixerHueRing.diameter + 12)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard showHandles else { return }
                        // Double-click reset, read the way the slider and the wheel
                        // read it (LumenControls): a minimumDistance-0 drag claims
                        // every press, so an onTapGesture(count: 2) behind it never
                        // fires — and here each click of the attempt also MOVED the
                        // nearest handle to the clicked angle, so following the
                        // ring's own help text silently reshaped the band twice.
                        if !pressWasReset,
                           let event = NSApp.currentEvent, event.clickCount >= 2 {
                            pressWasReset = true
                            grabbed = nil
                            onResetArc()
                            return
                        }
                        if pressWasReset { return }
                        let box = MixerHueRing.diameter + 12
                        // THE HIT TEST, on the PRESS point and only while nothing is
                        // held yet — the same shape `LumenSlider` uses
                        // (`drag.startLocation` into `SliderDrag.grabsThumb`). A press
                        // that grabbed nothing leaves the whole gesture inert: it does
                        // not open a gesture epoch, it writes no recipe, and it cannot
                        // pick a handle up later by wandering over the ring.
                        //
                        // Deliberately AFTER the double-click branch above, so a reset
                        // still lands from anywhere in the box exactly as it does now.
                        let handle: MixerArcHandle
                        if let held = grabbed {
                            handle = held
                        } else {
                            guard let taken = MixerHueRing.grab(at: drag.startLocation,
                                                                box: box,
                                                                arc: arcList[index])
                            else { return }
                            grabbed = taken
                            handle = taken
                        }
                        sliderGestureChanged(true)
                        let dx = Double(drag.location.x - box / 2)
                        let dy = Double(drag.location.y - box / 2)
                        // Still needed for the REST of the drag: the press is out in
                        // the annulus, but the pointer is free to cross the centre.
                        guard dx != 0 || dy != 0 else { return }
                        let angle = Num.wrapHue(atan2(dy, dx) * 180 / .pi)
                        onHandleMoved(handle, angle)
                    }
                    .onEnded { _ in
                        grabbed = nil
                        pressWasReset = false
                        sliderGestureChanged(false)
                    }
            )

            if allBands {
                Text("All bands")
                    .font(.lumenCaption)
                    .foregroundStyle(Lumen.secondaryText)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
        .help(allBands
              ? "Band reach is per band; pick one to shape its arc."
              : "Drag the inner handles for the core range, the outer ones for the "
                + "feather. Double-click to reset the arc.")
    }

    static let allHandles: [MixerArcHandle] =
        [.featherStart, .coreStart, .coreEnd, .featherEnd]

    static func degrees(of handle: MixerArcHandle, in arc: ColorEngine.BandArc) -> Double {
        switch handle {
        case .featherStart: return arc.featherStart
        case .coreStart: return arc.coreStart
        case .coreEnd: return arc.coreEnd
        case .featherEnd: return arc.featherEnd
        }
    }

    /// Whichever of the four is closest, in degrees around the ring.
    /// The parameter is deliberately not called `degrees`: that name is already the
    /// lookup function one line down, and shadowing it makes the call unresolvable.
    static func nearestHandle(to angle: Double,
                              in arc: ColorEngine.BandArc) -> MixerArcHandle {
        var best: MixerArcHandle = .coreStart
        var bestDistance = Double.infinity
        for handle in allHandles {
            let d = abs(Num.hueDelta(MixerHueRing.degrees(of: handle, in: arc), angle))
            if d < bestDistance {
                bestDistance = d
                best = handle
            }
        }
        return best
    }

    /// What a press at `point` took hold of, or nil for a press that took hold of
    /// nothing — the hit test the ring did not have.
    ///
    /// `contentShape(Rectangle())` claims the whole 130 pt box, so without this every
    /// press in it — the hollow middle of the wheel, the four corners outside the
    /// circle — reached `nearestHandle` and threw one end of the selected band's arc
    /// to the clicked angle. A press one point off centre is the worst of them: its
    /// `atan2` is the ratio of two sub-pixel numbers, so the handle went somewhere
    /// arbitrary and the photograph changed with it.
    ///
    /// Two gates, in the order the hand fails them. FIRST the annulus, because the
    /// centre has no meaningful angle at all and asking `atan2` about it is the defect.
    /// THEN the distance along the ring to the nearest handle, measured in points and
    /// against `SliderDrag.grabsThumb` — the same 11 pt the slider's thumb is caught
    /// with, called rather than restated, so the two cannot drift apart.
    ///
    /// Static and pure: no Canvas, no `NSApp`, no view. The whole decision is testable
    /// as arithmetic, which is what the defect deserved and never had.
    static func grab(at point: CGPoint, box: CGFloat,
                     arc: ColorEngine.BandArc) -> MixerArcHandle? {
        let radius = Double(arcRadius(box: box))
        // A box too small to have an annulus has no ring to grab, and the lower bound
        // below is what keeps the centre — the arbitrary-angle case — outside the gate.
        guard radius > ringGrabBand else { return nil }
        let dx = Double(point.x) - Double(box) / 2
        let dy = Double(point.y) - Double(box) / 2
        let pressRadius = (dx * dx + dy * dy).squareRoot()
        guard pressRadius.isFinite,
              pressRadius >= radius - ringGrabBand,
              pressRadius <= radius + ringGrabBand else { return nil }
        let angle = Num.wrapHue(atan2(dy, dx) * 180 / .pi)
        let handle = nearestHandle(to: angle, in: arc)
        // Measured as a DELTA and compared against zero, rather than as two positions
        // along the ring: 359° and 1° are two degrees apart and their arc lengths from
        // the same origin are not.
        let apart = abs(Num.hueDelta(degrees(of: handle, in: arc), angle)) * .pi / 180 * radius
        guard SliderDrag.grabsThumb(pressX: apart, thumbX: 0) else { return nil }
        return handle
    }

    /// Screen point at a hue angle. Same convention as `LumenColorWheel`: hue 0 at three
    /// o'clock, increasing clockwise, because y grows downward.
    static func point(_ centre: CGPoint, _ radius: CGFloat, _ degrees: Double) -> CGPoint {
        let a = degrees * .pi / 180
        return CGPoint(x: centre.x + radius * CGFloat(cos(a)),
                       y: centre.y + radius * CGFloat(sin(a)))
    }

    /// A polyline arc. Sampled rather than `addArc`, so there is no sweep-direction
    /// argument to get backwards and the wrap at 360° needs no special case.
    static func arcPath(_ centre: CGPoint, _ radius: CGFloat,
                        from start: Double, to end: Double) -> Path {
        var path = Path()
        let span = Swift.max(end - start, 0)
        let steps = Swift.max(2, Int(span / 2) + 2)
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let p = point(centre, radius, start + span * t)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }
}

// MARK: - Band ribbon

/// The 8-band partition of unity, drawn. Because the bands overlap smoothly there are
/// no wedge edges to show — which is exactly the point, and why the strip is worth the
/// pixels: the selected band's reach is visible instead of imagined.
struct MixerBandRibbon: View {
    let weights: [[Double]]
    let colors: [Color]
    let selected: Int
    let allBands: Bool

    var body: some View {
        let samples = weights
        let palette = colors
        let highlighted = selected
        let all = allBands

        return Canvas { context, size in
            let count = samples.count
            guard count > 1, size.width > 0, size.height > 2 else { return }
            let usable = size.height - 2

            for band in palette.indices {
                var path = Path()
                var started = false
                for step in 0..<count {
                    let vector = samples[step]
                    guard band < vector.count else { continue }
                    let x = size.width * CGFloat(step) / CGFloat(count - 1)
                    let y = size.height - 1 - CGFloat(min(max(vector[band], 0), 1)) * usable
                    let point = CGPoint(x: x, y: y)
                    if started {
                        path.addLine(to: point)
                    } else {
                        path.move(to: point)
                        started = true
                    }
                }
                guard started else { continue }
                let emphasised = all || band == highlighted
                context.stroke(path,
                               with: .color(palette[band].opacity(emphasised ? 0.95 : 0.30)),
                               lineWidth: emphasised ? 1.6 : 1.0)
            }
        }
        .frame(height: 30)
        .background(Lumen.controlBackground)
        .clipShape(RoundedRectangle(cornerRadius: Lumen.radiusControl, style: .continuous))
        .help("Band membership across the hue circle — the weights the engine uses.")
    }
}

#endif
