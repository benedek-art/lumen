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
    //
    // `AppState.mixerAllBands` is NOT read here any more. The "All bands" segment that
    // set it is gone (see `mixerHeaderRow`), and a panel that went on honouring a flag
    // nothing on screen can show or clear would be a hidden mode.
    private var selectedBand: Int { state.mixerBand }
    @State private var selectedSwatch: Int = 0
    // Folds inside the section, not the section itself: the accordion decides whether
    // Colour is open, these three decide whether the rows under one of its headers are.
    @State private var mixerExpanded: Bool = true
    /// The row an eyedropper pick landed on while Hue, Saturation or Luminance is showing
    /// — see `mixerSection`'s `onChange`. Nil until a pick, and cleared by a view switch.
    @State private var pickedRow: Int? = nil
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
    private var innerRhythm: CGFloat { only == nil ? Lumen.subsectionGap : Lumen.foldGap }

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
                mixerHeaderRow(bands, reshaped: reshaped)
                mixerBody(bands, arcs, index)
                evenOutHues
            }
        }
        // WHERE A PICK LANDS, IN THE VIEWS THAT HAVE NO SWATCHES (E1). The eyedropper
        // resolves on `AppState` and writes `mixerBand`; in Band view the ring on the
        // swatch is the answer. In Hue, Saturation and Luminance the eight rows are
        // all on screen and none of them is "selected", so the row the pick chose
        // wears the focus surface until the view changes. Nothing but a pick writes
        // `mixerBand` while those views show — the swatches that also write it are
        // only drawn in Band view — so this does not fire on any other gesture.
        .onChange(of: state.mixerBand) { _, band in
            if state.mixerAdjust != .band { pickedRow = band }
        }
        .onChange(of: state.mixerAdjust) { _, _ in
            pickedRow = nil
        }
    }

    /// The eyedropper and the Adjust control, on one row.
    ///
    /// PICKER FIRST (docs/28 Phase 5). Before this row, using the mixer began with a
    /// question the panel would not answer: which of the eight bands owns the colour you
    /// want to change? A photographer knows the sky and the skin; nobody knows which arc
    /// of hue they fall in, and guessing wrong means sliders that appear to do nothing.
    /// `ColorEngine.dominantBand` is the argmax of the same membership vector the pixel
    /// loop uses, so the engine can answer it.
    ///
    /// THE SEGMENTS ARE LIGHTROOM'S, and "All bands" is not one of them any more. It
    /// was a rigid group offset — every band's Hue, Saturation or Luminance moved by the
    /// same amount — sitting where Lightroom puts a VIEW of all the sliders, and it
    /// dimmed the swatches so they read as disabled (audit UI-5). Moving every band's
    /// hue together is a global hue rotation, every band's saturation together is the
    /// Presence Saturation row, and the question "what did I do to all of them" is now
    /// answered by the Hue, Saturation and Luminance views. The dots on the segments
    /// say which of them carries an edit, the way the grading zones' segments do.
    private func mixerHeaderRow(_ bands: [MixerBand], reshaped: Bool) -> some View {
        var marked: Set<AppState.MixerAdjust> = []
        if bands.contains(where: { $0.hue != 0 }) { marked.insert(.hue) }
        if bands.contains(where: { $0.sat != 0 }) { marked.insert(.saturation) }
        if bands.contains(where: { $0.lum != 0 }) { marked.insert(.luminance) }
        // Band view is the only place a reshaped arc can be seen, so it is the segment
        // that says one exists.
        if reshaped { marked.insert(.band) }

        return HStack(spacing: 6) {
            mixerPickButton
            // The rest of the row, not a fixed width: the column is draggable, and four
            // segments in the narrowest column still get a 64 pt share each
            // (`LayoutMetricTests.testEverySegmentedControlsLabelsFitTheirShare`).
            LumenSegmented(options: ColorPanel.adjustOptions,
                           selection: Binding(get: { state.mixerAdjust },
                                              set: { state.mixerAdjust = $0 }),
                           marked: marked)
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 2)
    }

    /// The four views, in Lightroom's order.
    static let adjustOptions: [(value: AppState.MixerAdjust, label: String)] = [
        (value: .hue, label: "Hue"),
        (value: .saturation, label: "Saturation"),
        (value: .luminance, label: "Luminance"),
        (value: .band, label: "Band"),
    ]

    /// The mixer's eyedropper, icon-only and drawn exactly as Point Colour's is — the
    /// same glyph, the same 24 pt by row-height target, the same armed paint — because
    /// two eyedroppers one section apart that look different read as two different
    /// tools. Armed, pressing it again disarms rather than stacking a second pick, the
    /// contract every picker in the app keeps.
    ///
    /// It replaces `pickBandButton` here (that one still reads "Pick a colour" in text,
    /// and is Point Colour's lane's to retire; see docs/quality/lanes/WS-31/NEEDS.md).
    private var mixerPickButton: some View {
        let armed = state.pickTarget == .mixerBand
        let help: String
        if armed {
            help = "Click a colour in the photograph — or click here again to cancel the pick"
        } else {
            help = "Pick a colour: click this, then click the photograph, and the band "
                + "grading that colour is selected"
        }
        return Button {
            if armed {
                state.cancelPick()
            } else {
                state.beginPick(.mixerBand)
            }
        } label: {
            Image(systemName: "eyedropper")
                .font(.lumenGlyphCaptionStrong)
                .frame(width: 24, height: Lumen.rowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(armed ? Lumen.accent : Lumen.primaryText)
        .background(
            RoundedRectangle(cornerRadius: Lumen.radiusChip, style: .continuous)
                .fill(armed ? Lumen.fillColor.opacity(0.35) : Color.clear))
        // Dead with no photograph: the pick resolves only on the loupe's frame. An
        // ARMED button stays live, because pressing it is the cancel.
        .disabled(!armed && state.primarySelection == nil)
        .lumenClickCursor()
        .help(help)
    }

    /// Band view, or one attribute across all eight bands.
    @ViewBuilder
    private func mixerBody(_ bands: [MixerBand], _ arcs: [ColorEngine.BandArc],
                           _ index: Int) -> some View {
        switch state.mixerAdjust {
        case .band:
            bandView(bands, arcs, index)
        case .hue:
            attributeRows(.hue)
        case .saturation:
            attributeRows(.sat)
        case .luminance:
            attributeRows(.lum)
        }
    }

    /// LIGHTROOM'S HSL TABS: one attribute, eight rows, each in its band's colours.
    ///
    /// The rows are ordinary slider rows at the panel's ordinary pitch, so a label, a
    /// track and a readout here line up with Point Colour's below — the mixer is not a
    /// denser instrument than the rest of the column.
    private func attributeRows(_ component: MixerComponent) -> some View {
        VStack(alignment: .leading, spacing: Lumen.rowGap) {
            ForEach(Array(0..<ColorEngine.bandCount), id: \.self) { band in
                LumenSlider(title: ColorPanel.bandName(band),
                            value: mixerBinding(component, band: band),
                            range: -100...100, defaultValue: 0, step: 1, decimals: 0,
                            trackStops: ColorPanel.trackStops(component, band),
                            help: ColorPanel.rowHelp(component, band),
                            // Eight names that are the rows' index, not their state:
                            // dimmed at rest, seven of eight read as disabled.
                            labelAtFullStrength: true)
                    .lumenFocusSurface(focused: pickedRow == band)
            }
        }
    }

    /// One band's three sliders under a row of the eight bands — Lightroom's Colour
    /// mode — with the band's reach folded away beneath them.
    private func bandView(_ bands: [MixerBand], _ arcs: [ColorEngine.BandArc],
                          _ index: Int) -> some View {
        VStack(alignment: .leading, spacing: Lumen.rowGap) {
            bandSwatches(bands, index)

            // The name, because a swatch is a colour and the photographer is choosing a
            // word as often as a colour ("the oranges"); it is also the only place the
            // name was ever said without a hover. A group label in the house style —
            // the same treatment as Colour Balance's axis names — so it reads as the
            // heading of the three rows under it.
            LumenCapsLabel(text: ColorPanel.bandName(index))
                .padding(.top, 2)

            // The tracks carry the band's own colours, so the track also says what the
            // row's scope is: this band, and the way a Hue move turns it.
            LumenSlider(title: "Hue", value: mixerBinding(.hue, band: index),
                        range: -100...100, defaultValue: 0, step: 1, decimals: 0,
                        trackStops: ColorPanel.trackStops(.hue, index),
                        help: ColorPanel.rowHelp(.hue, nil))
            LumenSlider(title: "Saturation", value: mixerBinding(.sat, band: index),
                        range: -100...100, defaultValue: 0, step: 1, decimals: 0,
                        trackStops: ColorPanel.trackStops(.sat, index),
                        help: ColorPanel.rowHelp(.sat, nil))
            LumenSlider(title: "Luminance", value: mixerBinding(.lum, band: index),
                        range: -100...100, defaultValue: 0, step: 1, decimals: 0,
                        trackStops: ColorPanel.trackStops(.lum, index),
                        help: ColorPanel.rowHelp(.lum, nil))

            bandRange(arcs, index)
        }
    }

    /// The help on a band row, in the words the row is labelled with. `band` nil is the
    /// Band view's rows, whose band is already named in the label above them.
    private static func rowHelp(_ component: MixerComponent, _ band: Int?) -> String {
        let subject: String
        if let band {
            subject = ColorPanel.bandName(band).lowercased() + "s"
        } else {
            subject = "this band's colours"
        }
        switch component {
        case .hue:
            return "Turns \(subject) toward a neighbouring band — the track shows "
                + "which way."
        case .sat:
            return "Strengthens or mutes \(subject); −100 takes them to grey."
        case .lum:
            return "Lightens or darkens \(subject) without draining them — a darkened "
                + "sky stays blue."
        }
    }

    /// "Even out hues", under a group label that says its scope.
    ///
    /// Not inside the band block above, and named for what it is. There is one
    /// `Mixer.uniformity` on the wire and the engine applies it to all eight bands, each
    /// converging on its own core arc — so selecting Blue and dragging this also pulls
    /// skin toward Orange. Reading it as per-band is a wrong edit, not an ugly one.
    ///
    /// It used to be marked by a rule, then by eight points of bare space when the
    /// panels lost their rules (U2), with a note that if space did not carry the change
    /// of scope "the upgrade is to NAME the scope with a group marker rather than to
    /// bring the line back". The audit found that it did not (UI-8), so this is that
    /// upgrade: the house group label, the one Colour Balance's axes wear.
    private var evenOutHues: some View {
        VStack(alignment: .leading, spacing: Lumen.rowGap) {
            // "Every band", not "All bands": that was the removed group-offset
            // mode's name, and reusing it here would bring the confusion back.
            LumenCapsLabel(text: "Every band")
                // 12 over, 4 under — the group-label rhythm LookPanel argues: enough
                // above to read as a new group, little enough below that the row still
                // belongs to it.
                .padding(.top, 12)
                .padding(.bottom, 4)
            // "Even out hues", not "Uniformity". The coalescing key stays
            // `mixer.uniformity` and so does the wire field; this is the label doing
            // the caption's job.
            LumenSlider(title: "Even out hues",
                        value: bind("mixer.uniformity",
                                    get: { $0.develop.mixer.uniformity },
                                    set: { $0.develop.mixer.uniformity = $1 }),
                        range: 0...100, defaultValue: 0, step: 1, decimals: 0,
                        bipolar: false,
                        // AI-08, interim: the engine evaluates this per pixel
                        // (S9 is a colour table, so it cannot see a neighbourhood),
                        // and the help says what that costs until a spatial local
                        // mean reaches the stage. Measured: at 100, inputs at
                        // 24°/29°/34° inside one band all leave at 29°.
                        help: "Gathers scattered hues in toward each band's own "
                            + "centre — calms mottled colour like patchy skin or a "
                            + "streaky sky. Works on all eight bands at once, "
                            + "whatever is selected above. For now it works pixel "
                            + "by pixel, not on the neighbourhood: at 100 the hues "
                            + "inside a band all land on one, so fine colour "
                            + "texture flattens along with the blotches.")
        }
    }

    // MARK: - Ring handles (D13: visible, draggable range + feather)

    /// Write one dragged handle back into the band's wire geometry.
    ///
    /// DEGREES ON SCREEN, WIRE UNITS ON DISK, AND THE ENGINE CONVERTS BETWEEN THEM. The
    /// wire's `core`/`feather` are relative to each band's own default (22.5 / 15 mean
    /// "this band's default on this side", WS-31 E-4), because the bands are no longer
    /// 45° apart and one absolute default cannot fit all eight. So the drag reads the
    /// arc the ring is drawing (`ColorEngine.bandArcs`), moves one side of it IN
    /// DEGREES, clamps in degrees to the engine's limits, and writes the result back
    /// through `ColorEngine.wireHandles` — the inverse of `bandArcs`, so the arc the
    /// render resolves is the arc the hand left. Writing degrees straight into the wire,
    /// as this did when wire and degrees were the same number, would now scale every
    /// handle by the band's default and throw it somewhere the pointer is not.
    ///
    /// The centre never moves — it is the wire format's identity for the band. Dragging
    /// the two inner handles to the same side is how you re-centre the band on a colour,
    /// and `ColorEngine.BandArc.coreCentre` is what reads that back out for Uniformity.
    /// `bandArcs` re-applies the per-side minimum reach on the way back in, by widening
    /// the feather, so a core dragged narrow cannot open a hole in the partition.
    private func moveHandle(_ band: Int, _ handle: MixerArcHandle, to degrees: Double) {
        state.updateRecipe(coalescingKey: "mixer.arc.\(band).\(handle.rawValue)") { recipe in
            var bands = ColorPanel.normalizedBands(recipe.develop.mixer.bands)
            let arcs = ColorEngine.bandArcs(bands)
            guard bands.indices.contains(band), arcs.indices.contains(band) else { return }
            let moved = ColorPanel.draggedArc(arcs[band], handle, to: degrees)
            let wire = ColorEngine.wireHandles(for: moved, band: band)
            bands[band].core = wire.core
            bands[band].feather = wire.feather
            recipe.develop.mixer.bands = bands
        }
    }

    /// One handle of `arc` moved to the absolute hue `degrees`, every side in degrees and
    /// clamped to the engine's handle limits. Static and pure, so the arithmetic the ring
    /// writes with is one expression that can be read apart from the gesture.
    static func draggedArc(_ arc: ColorEngine.BandArc, _ handle: MixerArcHandle,
                           to degrees: Double) -> ColorEngine.BandArc {
        let delta = Num.hueDelta(arc.centre, degrees)     // signed, (−180, 180]
        let coreLo = ColorEngine.bandCoreMinDegrees
        let coreHi = ColorEngine.bandCoreMaxDegrees
        let featherLo = ColorEngine.bandFeatherMinDegrees
        let featherHi = ColorEngine.bandFeatherMaxDegrees
        var coreBelow = arc.coreBelow
        var coreAbove = arc.coreAbove
        var featherBelow = arc.featherBelow
        var featherAbove = arc.featherAbove
        switch handle {
        case .coreStart:
            coreBelow = Num.clamp(-delta, coreLo, coreHi)
        case .coreEnd:
            coreAbove = Num.clamp(delta, coreLo, coreHi)
        case .featherStart:
            featherBelow = Num.clamp(-delta - coreBelow, featherLo, featherHi)
        case .featherEnd:
            featherAbove = Num.clamp(delta - coreAbove, featherLo, featherHi)
        }
        return ColorEngine.BandArc(centre: arc.centre,
                                   coreBelow: coreBelow, coreAbove: coreAbove,
                                   featherBelow: featherBelow, featherAbove: featherAbove)
    }

    /// Back to the band's default arc, leaving its three sliders alone. The wire
    /// defaults ARE "this band's default" under the relative wire (E-4), and `bandArcs`
    /// resolves them exactly to `canonicalArcs[band]`, so the Band range dot clears.
    private func resetArc(_ band: Int) {
        state.updateRecipe { recipe in
            var bands = ColorPanel.normalizedBands(recipe.develop.mixer.bands)
            guard bands.indices.contains(band) else { return }
            bands[band].core = MixerBand.defaultCore
            bands[band].feather = MixerBand.defaultFeather
            recipe.develop.mixer.bands = bands
        }
    }

    /// THE BAND RANGE DISCLOSURE: a fold row, and behind it the ring, the ribbon and a
    /// sentence. Closed by default (audit UI-3): the ring and the ribbon took about
    /// 165 pt above the three sliders that do the work, giving an advanced edit the
    /// primary position. They are still one click away and still draw the engine's own
    /// geometry when they are open.
    private func bandRange(_ arcs: [ColorEngine.BandArc], _ index: Int) -> some View {
        let reshaped = arcs.indices.contains(index)
            && ColorEngine.canonicalArcs.indices.contains(index)
            && arcs[index] != ColorEngine.canonicalArcs[index]
        let anyReshaped = arcs != ColorEngine.canonicalArcs
        return VStack(alignment: .leading, spacing: Lumen.rowGap) {
            bandRangeHeader(index, reshaped: reshaped, anyReshaped: anyReshaped)
            if state.mixerRangeExpanded {
                bandReach(arcs, index)
            }
        }
    }

    /// The fold row. A plain chevron and a body-size name rather than a
    /// `LumenSectionHeader`: this is a fold inside a fold, and a third heading at the
    /// heading size would shout as loudly as "Colour Mixer" above it.
    private func bandRangeHeader(_ index: Int, reshaped: Bool,
                                 anyReshaped: Bool) -> some View {
        HStack(spacing: 4) {
            Button {
                withAnimation(Lumen.motionFold) { state.mixerRangeExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.lumenGlyphCaptionStrong)
                        .rotationEffect(.degrees(state.mixerRangeExpanded ? 90 : 0))
                        .frame(width: 20, height: 20)
                    Text("Band range")
                        .font(.lumenBody)
                        .lineLimit(1)
                    // The modified mark every fold header wears, for ANY band's reach
                    // — a reshaped arc is otherwise invisible with the fold closed.
                    if anyReshaped {
                        Circle()
                            .fill(Lumen.accent)
                            .frame(width: 4, height: 4)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: Lumen.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Lumen.secondaryText)
            // Named for VoiceOver; without it the chevron's symbol name is read into the
            // label. (The snapshot suite does not click this: SwiftUI did not surface
            // it to `press:`'s accessibility walk, so the suite sets
            // `AppState.mixerRangeExpanded` instead.)
            .accessibilityLabel("Band range")
            .lumenClickCursor()
            .help(state.mixerRangeExpanded
                  ? "Hide the ring that shapes which hues this band reaches"
                  : "Show the ring that shapes which hues this band reaches")

            if reshaped {
                Button("Reset") { resetArc(index) }
                    .buttonStyle(.plain)
                    .font(.lumenCaption)
                    .foregroundStyle(Lumen.secondaryText)
                    .lumenClickCursor()
                    .help("Put \(ColorPanel.bandName(index))'s range back, keeping its "
                          + "three sliders")
            }
        }
    }

    /// Ring, ribbon and the sentence under them — the three views that answer "what does
    /// this band reach", grouped so the three can never be shown without each other.
    private func bandReach(_ arcs: [ColorEngine.BandArc], _ index: Int) -> some View {
        VStack(alignment: .leading, spacing: Lumen.rowGap) {
            MixerHueRing(arcs: arcs,
                         selected: index,
                         onHandleMoved: { handle, degrees in
                             moveHandle(index, handle, to: degrees)
                         },
                         onResetArc: { resetArc(index) })

            MixerBandRibbon(weights: ColorPanel.ribbon(arcs),
                            colors: ColorPanel.bandSwatchColors,
                            selected: index)

            // WORDS, NOT ANGLES (audit UI-4). This said "Red — centred on 29.2° in
            // OKLCh, core −22°/+22°, feather 15°/15°": four numbers in a colour model
            // the photographer never chose, for handles that are already on screen. The
            // ring shows the reach; the sentence only has to say how to change it.
            Text("Drag the ends of the bright arc to change which hues "
                 + "\(ColorPanel.bandName(index)) takes in, and the dim tails to "
                 + "change how softly it lets go. Double-click the ring to put it back.")
                .font(.lumenCaption)
                .foregroundStyle(Lumen.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 2)
        }
    }

    /// EIGHT ROUND SWATCHES, IN THE ENGINE'S COLOURS (audit UI-1, UI-5).
    ///
    /// NOT BUTTONS, and that is the fix rather than a regression. A `.plain` button
    /// still paints its own pressed state over the label, and on a strip of full-bleed
    /// colour chips that read as a flash with no padding — the owner named it: "when I
    /// press on them, they highlight… it doesn't have any padding so it looks kind of
    /// weird" (docs/32 Stream D item 2). A tap gesture selects identically and draws
    /// nothing; the selection RING is the state, and the pointing hand is what says the
    /// swatches are click targets.
    ///
    /// The ring stands OFF the swatch by a point of panel, so it reads at 1x on every
    /// band colour — a ring drawn on the swatch's own edge vanished on Yellow. The edited
    /// mark is the accent dot every modified header and segment wears, under the swatch
    /// rather than on it: on the colour it was a 3 px speck nobody could find.
    private func bandSwatches(_ bands: [MixerBand], _ index: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(0..<ColorEngine.bandCount), id: \.self) { band in
                let touched = band < bands.count
                    && (bands[band].hue != 0 || bands[band].sat != 0 || bands[band].lum != 0)
                bandSwatch(band, selected: band == index, touched: touched)
            }
        }
        .padding(.vertical, 2)
    }

    /// One swatch: the colour, the selection ring around it, the edited dot under it.
    private func bandSwatch(_ band: Int, selected: Bool, touched: Bool) -> some View {
        let name = ColorPanel.bandName(band)
        let help: String
        if touched {
            help = "\(name) — edited. Click to show its sliders."
        } else {
            help = "\(name) — click to show its sliders."
        }
        return VStack(spacing: 3) {
            ZStack {
                Circle()
                    .fill(ColorPanel.swatch(band))
                    .frame(width: ColorPanel.swatchDiameter,
                           height: ColorPanel.swatchDiameter)
                Circle()
                    .strokeBorder(Lumen.primaryText, lineWidth: 2)
                    .frame(width: ColorPanel.swatchDiameter + 6,
                           height: ColorPanel.swatchDiameter + 6)
                    .opacity(selected ? 1 : 0)
            }
            Circle()
                .fill(Lumen.accent)
                .frame(width: 5, height: 5)
                .opacity(touched ? 1 : 0)
        }
        // An equal share of the row each, so the eight spread to the column's width
        // at any width rather than bunching at the leading edge.
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { state.mixerBand = band }
        .lumenClickCursor()
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(name))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 20 pt: the ring's 26 pt outer edge, eight across, fits the narrowest column's
    /// 36 pt share with air either side.
    static let swatchDiameter: CGFloat = 20

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
                    // Dead with no photograph, like the mixer's pill below (B3-09): the
                    // pick resolves only on the loupe's photograph, so arming it with
                    // none left "Click the colour to work on." on screen with nothing
                    // to click. An ARMED button stays live — pressing it is the cancel.
                    .disabled(!pickIsArmed && (swatches.count >= ColorPanel.maxSwatches
                                               || state.primarySelection == nil))
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
                    // The three move rows carry the SWATCH's own colour on their
                    // tracks — the same colour-axis exception the Mixer's three rows
                    // use (docs/00 Law 7), and for the same reason: the track says
                    // which way the row moves this colour before it is touched. Built
                    // from the sample alone, so a drag on any of them does not
                    // rebuild its own track.
                    let swatch = swatches[index]
                    let stops = ColorPanel.pointTrackStops(swatch)
                    LumenSlider(title: "Hue", value: pointBinding(index, .hue),
                                range: -60...60, defaultValue: 0, step: 1, decimals: 0,
                                trackStops: stops.hue,
                                help: "Turns the picked colour toward a neighbouring "
                                    + "hue, up to 60° either way — only pixels near the "
                                    + "swatch follow.")
                    LumenSlider(title: "Saturation", value: pointBinding(index, .sat),
                                range: -100...100, defaultValue: 0, step: 1, decimals: 0,
                                trackStops: stops.saturation,
                                help: "Strengthens or mutes just the picked colour — "
                                    + "the rest of the photograph is untouched.")
                    LumenSlider(title: "Luminance", value: pointBinding(index, .lum),
                                range: -100...100, defaultValue: 0, step: 1, decimals: 0,
                                trackStops: stops.luminance,
                                help: "Lightens or darkens the picked colour without "
                                    + "washing it out.")
                    LumenSlider(title: "Range", value: pointBinding(index, .range),
                                range: 0...100, defaultValue: 50, step: 1, decimals: 0,
                                bipolar: false,
                                help: "How far around the picked colour the edit "
                                    + "reaches — low is surgical, high feathers into "
                                    + "the neighbours. The strip below shows what is "
                                    + "selected.")
                    // WHAT IS SELECTED, DRAWN. Lightroom hides this behind a "visualize"
                    // toggle on the photograph; here it is always on, as three strips
                    // through the picked colour — round the wheel, from grey to vivid,
                    // from dark to light — each painted at the strength the swatch
                    // applies there. It reads the engine's own weight, so it cannot
                    // disagree with the render.
                    PointSelectionStrip(swatch: swatch)
                    // Lightroom's Range refinements, under the master and subordinate
                    // to it: each multiplies the master's reach on its own axis, half
                    // at 0 and double at 100, and its strip above widens or narrows
                    // with it.
                    LumenSlider(title: "Hue range", value: pointBinding(index, .hueRange),
                                range: 0...100, defaultValue: 50, step: 1, decimals: 0,
                                bipolar: false, indented: true,
                                help: "How far round the wheel the selection reaches, "
                                    + "on top of Range — the top strip.")
                    LumenSlider(title: "Sat range", value: pointBinding(index, .satRange),
                                range: 0...100, defaultValue: 50, step: 1, decimals: 0,
                                bipolar: false, indented: true,
                                help: "How much paler or more vivid a colour can be and "
                                    + "still be selected — the middle strip.")
                    LumenSlider(title: "Lum range", value: pointBinding(index, .lumRange),
                                range: 0...100, defaultValue: 50, step: 1, decimals: 0,
                                bipolar: false, indented: true,
                                help: "How much darker or lighter a colour can be and "
                                    + "still be selected — the bottom strip.")
                    LumenSlider(title: "Variance", value: pointBinding(index, .variance),
                                range: -100...100, defaultValue: 0, step: 1, decimals: 0,
                                // Per pixel, like Even out hues. Lightness is left
                                // alone (WS-32): on the flat path converging it took
                                // pore texture with it.
                                help: "Negative gathers the selected colours in toward "
                                    + "the swatch's hue and colourfulness, evening out "
                                    + "blotchy skin or a patchy sky; positive spreads "
                                    + "them apart. It works pixel by pixel, so at −100 fine "
                                    + "colour variation evens out with the blotches — "
                                    + "lightness, and with it texture, is never "
                                    + "touched; positive amplifies colour variation, "
                                    + "noise included.")
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
        // BEFORE AND AFTER, as Lightroom's swatch shows them: the picked colour on the
        // left, the colour it now renders as on the right — so a row of chips says
        // what each swatch is doing without selecting it.
        let before = ColorPanel.chipColor(color)
        let after = ColorPanel.shiftedChipColor(color) ?? before
        return HStack(spacing: 0) {
            Rectangle().fill(before)
            Rectangle().fill(after)
        }
            .frame(width: 22, height: 16)
            .clipShape(RoundedRectangle(cornerRadius: Lumen.radiusChip, style: .continuous))
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
        guard state.currentRecipe.develop.pointColors.count < ColorPanel.maxSwatches,
              state.primarySelection != nil
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
                                    + "The classic moves: drop Azure for a dramatic "
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

    /// One band's Hue, Saturation or Luminance, clamped to ±100.
    ///
    /// THE GROUP MOVE WENT WITH THE "ALL BANDS" SEGMENT. This binding used to have a
    /// second mode that read the mean of all eight and moved them as a rigid set through
    /// `GroupMove` (B3-01, whose rule and tests stay in LumenCore). With the Hue,
    /// Saturation and Luminance views drawing every band's row, each row is one band
    /// again, and so is every write. The coalescing key is the one the per-band rows
    /// always used, so a drag is still one undo step.
    private func mixerBinding(_ component: MixerComponent, band: Int) -> Binding<Double> {
        Binding(
            get: {
                let bands = ColorPanel.normalizedBands(state.currentRecipe.develop.mixer.bands)
                let i = min(max(band, 0), bands.count - 1)
                return component.value(bands[i])
            },
            set: { newValue in
                state.updateRecipe(coalescingKey: "mixer.\(component.rawValue).\(band)") { recipe in
                    var bands = ColorPanel.normalizedBands(recipe.develop.mixer.bands)
                    let i = min(max(band, 0), bands.count - 1)
                    component.write(&bands[i], Num.clamp(newValue, -100, 100))
                    recipe.develop.mixer.bands = bands
                }
            })
    }

    private enum PointComponent: String {
        case hue, sat, lum, range, variance, hueRange, satRange, lumRange

        func value(_ p: PointColor) -> Double {
            switch self {
            case .hue: return p.shift.h
            case .sat: return p.shift.s
            case .lum: return p.shift.l
            case .range: return p.range
            case .variance: return p.variance
            case .hueRange: return p.hueRange ?? 50
            case .satRange: return p.satRange ?? 50
            case .lumRange: return p.lumRange ?? 50
            }
        }

        func write(_ p: inout PointColor, _ v: Double) {
            // A refinement back at 50 is stored as ABSENT, which is what 50 means: a
            // reset leaves the swatch byte-identical to one never refined.
            let refined: Double? = v == 50 ? nil : Num.clamp(v, 0, 100)
            switch self {
            case .hue: p.shift.h = Num.clamp(v, -60, 60)
            case .sat: p.shift.s = Num.clamp(v, -100, 100)
            case .lum: p.shift.l = Num.clamp(v, -100, 100)
            case .range: p.range = Num.clamp(v, 0, 100)
            case .variance: p.variance = Num.clamp(v, -100, 100)
            case .hueRange: p.hueRange = refined
            case .satRange: p.satRange = refined
            case .lumRange: p.lumRange = refined
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
    // The Band range sentence never went through here: it is a raw `Text` in
    // `bandReach`, shown only with the ring it explains.

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

    static func swatch(_ index: Int) -> Color {
        guard bandSwatchColors.indices.contains(index) else { return Lumen.controlBackground }
        return bandSwatchColors[index]
    }

    // MARK: Band colours, derived from the engine's centres (audit UI-1)

    // THE SWATCH IS THE BAND'S CENTRE, DRAWN. These were eight hand-picked sRGB
    // triples, chosen as reference colours rather than as the centres, on the argument
    // that the swatch labelled Orange has to look orange. Measured against the
    // centres they sat 14–21° off: the fourth chip was foliage green and split 51/49
    // between two bands, so a photographer matching the chip to the sky or the leaves picked the wrong one. The
    // band IS its centre hue — that is what the engine selects with — so the colour is
    // computed from `ColorEngine.bandHueCentres` and follows them wherever they move.
    //
    // Hue is exact and lightness and chroma are chosen per hue, because one fixed
    // OKLCh lightness cannot paint all eight well: at the L where blue is rich, yellow is
    // olive. So each hue is drawn mostly at its own sRGB cusp (the lightness where that
    // hue reaches its most colourful) — 85% of the way there from a dark anchor — at 95%
    // of the chroma the display has at that lightness, capped so no band shouts. The
    // cusp weight is what makes Yellow read yellow rather than mustard (its cusp is near
    // white) and the dark anchor is what keeps Red deep rather than coral; an even blend
    // toward a mid-panel lightness, which this was, gave both of those away (verify R1). Getting into gamut is done
    // by REDUCING CHROMA, never by clipping channels — a per-channel clip moves hue,
    // which is the one property these colours exist to hold.
    //
    // All of it is STATIC — computed once, never in a `body` from recipe values. A track
    // whose colour depended on the recipe would make every mixer row a reader of the
    // edit signal, and a Hue drag rebuilds its panel on every mouse event. The arcs are
    // editable but the centres are not; the ribbon is where live geometry is drawn, and
    // these say which band you are in.

    /// How far each band's display lightness sits toward its own cusp (the rest is
    /// `paintLightnessAnchor`).
    static let paintCuspWeight: Double = 0.85
    /// Where every band's display lightness is pulled toward from its cusp.
    static let paintLightnessAnchor: Double = 0.45
    /// The most chroma any band colour is drawn with.
    static let paintChromaCap: Double = 0.22
    /// The share of the display's chroma at that lightness a band colour takes.
    static let paintChromaShare: Double = 0.95

    /// An OKLCh colour in display-linear sRGB, through the working space the engine
    /// measures hue in — the same route `Lumen.hueColor` takes.
    static func displayLinear(_ lch: OKLCh) -> RGB {
        Lumen.workingToSRGB.apply(OKLabTransform.working.toRGB(lch))
    }

    static func isDisplayable(_ c: RGB) -> Bool {
        let lo = -1e-6
        let hi = 1 + 1e-6
        return c.r >= lo && c.r <= hi && c.g >= lo && c.g <= hi && c.b >= lo && c.b <= hi
    }

    /// The most chroma sRGB can show at this lightness and hue, by bisection.
    static func maxChroma(L: Double, h: Double) -> Double {
        var lo = 0.0
        var hi = 0.4
        for _ in 0..<18 {
            let mid = (lo + hi) / 2
            if isDisplayable(displayLinear(OKLCh(L: L, C: mid, h: h))) {
                lo = mid
            } else {
                hi = mid
            }
        }
        return lo
    }

    /// The lightness at which this hue is most colourful on an sRGB display.
    static func cuspLightness(h: Double) -> Double {
        var bestL = 0.6
        var bestC = -1.0
        var L = 0.30
        while L <= 0.98 {
            let c = maxChroma(L: L, h: h)
            if c > bestC {
                bestC = c
                bestL = L
            }
            L += 0.02
        }
        return bestL
    }

    /// The colour a hue is painted with in this panel. See the block comment above.
    static func paint(h: Double) -> OKLCh {
        let L = paintCuspWeight * cuspLightness(h: h)
            + (1 - paintCuspWeight) * paintLightnessAnchor
        let C = min(paintChromaCap, paintChromaShare * maxChroma(L: L, h: h))
        return OKLCh(L: L, C: C, h: h)
    }

    /// An OKLCh colour as a SwiftUI colour, brought into gamut by chroma alone.
    static func color(_ lch: OKLCh) -> Color {
        var c = lch
        if !isDisplayable(displayLinear(c)) { c.C = maxChroma(L: c.L, h: c.h) }
        let linear = displayLinear(c)
        let encoded = TransferFunction.srgb.encode(RGB(Num.saturate(linear.r),
                                                       Num.saturate(linear.g),
                                                       Num.saturate(linear.b)))
        return Color(red: Num.saturate(encoded.r),
                     green: Num.saturate(encoded.g),
                     blue: Num.saturate(encoded.b))
    }

    /// Each band's centre, painted.
    static let bandPaints: [OKLCh] = ColorEngine.bandHueCentres.map { paint(h: $0) }

    static let bandSwatchColors: [Color] = bandPaints.map { color($0) }

    // MARK: Coloured tracks for the band rows (docs/28 Phase 2)

    // Law 7's colour-axis exception (docs/00, amended 2026-08-29) covers exactly these
    // three: Hue, Saturation and Luminance in the mixer are axes whose units ARE colour,
    // so the track can say what the row does before the row is touched.
    //
    // Each track is several stops computed in OKLCh rather than three stops blended in
    // sRGB: a gradient between two sRGB colours drifts in hue on the way, and a track
    // is read at every point along it, its midpoint most of all.

    /// Stops at −100, −50, 0, +50, +100 — enough that sRGB's blend between them stays
    /// within a degree or two of the OKLCh path.
    static let trackValues: [Double] = [-100, -50, 0, 50, 100]

    /// The hue span the row turns between — toward the neighbour below, this band, toward
    /// the neighbour above, each point painted at its own hue. The ring wraps, so Red's
    /// lower neighbour is Magenta. The ends are the neighbours' own colours: the track
    /// says which way the row turns, not how far (±100 stops short of the neighbour).
    static let mixerHueStops: [[LumenTrackStop]] = bandPaints.indices.map { i -> [LumenTrackStop] in
        let centres = ColorEngine.bandHueCentres
        let n = centres.count
        let below = Num.hueDelta(centres[i], centres[(i + n - 1) % n])   // negative
        let above = Num.hueDelta(centres[i], centres[(i + 1) % n])       // positive
        return trackValues.map { v -> LumenTrackStop in
            let span = v < 0 ? -below : above
            let h = Num.wrapHue(centres[i] + span * v / 100)
            return LumenTrackStop(value: v, color: color(paint(h: h)))
        }
    }

    /// Grey to vivid, at the band's own hue and lightness: −100 is the grey the band
    /// goes to, 0 sits at half the band's chroma, +100 is the band's full colour.
    static let mixerSaturationStops: [[LumenTrackStop]] = bandPaints.map { p -> [LumenTrackStop] in
        trackValues.map { v -> LumenTrackStop in
            LumenTrackStop(value: v,
                           color: color(OKLCh(L: p.L, C: p.C * (v + 100) / 200, h: p.h)))
        }
    }

    /// Dark to light, at the band's own hue. Lightness, not a multiply toward black: a
    /// multiplied yellow goes olive long before it goes dark, which is the hue shift the
    /// engine's Luminance exists not to make.
    static let mixerLuminanceStops: [[LumenTrackStop]] = bandPaints.map { p -> [LumenTrackStop] in
        trackValues.map { v -> LumenTrackStop in
            let L = min(0.95, max(0.2, p.L + (v < 0 ? 0.32 : 0.2) * v / 100))
            return LumenTrackStop(value: v, color: color(OKLCh(L: L, C: p.C, h: p.h)))
        }
    }

    /// The stops for one band's row in one attribute. The bounds check is not defensive
    /// noise: the tables are sized from the engine's centre list and the index comes
    /// from `ColorEngine.bandCount`, two constants that agree today and are declared
    /// apart.
    private static func trackStops(_ component: MixerComponent,
                                   _ band: Int) -> [LumenTrackStop]? {
        let table: [[LumenTrackStop]]
        switch component {
        case .hue: table = mixerHueStops
        case .sat: table = mixerSaturationStops
        case .lum: table = mixerLuminanceStops
        }
        guard table.indices.contains(band) else { return nil }
        return table[band]
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

    /// `ribbonWeights`, remembered against the arcs it was computed from (B3-04).
    ///
    /// Still a function of the live arcs — a handle move is a new key and recomputes —
    /// but the panel re-bodies on EVERY mouse event of ANY slider drag in the column
    /// (`EditRevision`), and the arcs move only when a ring handle does. Without this an
    /// Exposure drag with the Colour section open paid 97 membership evaluations per
    /// event to redraw a ribbon that had not changed.
    static let ribbonMemo = LastValueMemo<[ColorEngine.BandArc], [[Double]]>()

    static func ribbon(_ arcs: [ColorEngine.BandArc]) -> [[Double]] {
        ribbonMemo.value(for: arcs, compute: ribbonWeights)
    }

    /// Two finite values from a wire array that a decoded file could have made anything.
    static func pair(_ values: [Double], _ fallback: [Double]) -> [Double] {
        var out = fallback
        for i in 0..<2 where i < values.count && values[i].isFinite { out[i] = values[i] }
        return out
    }

    /// The ring's wedge colours, computed once, in the same paint as the swatches.
    ///
    /// The ring was drawn at one fixed L 0.72 / C 0.16 through `Lumen.hueColor`, so its
    /// colours did not match the swatches above it (audit UI-2): the yellow on the ring
    /// was not the yellow of the Yellow chip. Painting every wedge with `paint(h:)` makes
    /// the swatch row a sample of the ring. A hundred and eighty conversions with a
    /// gamut search each is real work, so it is done once — the hue circle is a constant.
    static let ringColors: [Color] = (0..<MixerHueRing.steps).map { step in
        let a0 = Double(step) / Double(MixerHueRing.steps) * 360
        let a1 = Double(step + 1) / Double(MixerHueRing.steps) * 360
        return ColorPanel.color(ColorPanel.paint(h: (a0 + a1) / 2))
    }

    /// A chip for a sampled swatch. The sample is scene-linear working RGB, so it gets
    /// a rough encode before it is shown — otherwise every swatch reads as too dark.
    static func chipColor(_ point: PointColor) -> Color {
        guard point.sample.count >= 3 else { return Lumen.controlBackground }
        return pointDisplayColor(RGB(point.sample[0], point.sample[1], point.sample[2]))
    }

    /// The swatch's sample after its own Hue, Saturation and Luminance — the right
    /// half of its chip. Nil when the swatch has moved nothing.
    static func shiftedChipColor(_ point: PointColor) -> Color? {
        guard point.sample.count >= 3, point.shift != HSLShift() else { return nil }
        var probe = point
        probe.variance = 0
        let sample = RGB(point.sample[0], point.sample[1], point.sample[2])
        let engine = ColorEngine(mixer: Mixer(), pointColors: [probe], color: ColorAdjust(),
                                 primaries: Primaries(), bw: nil, bandMeanHues: nil)
        return pointDisplayColor(engine.apply(sample))
    }

    /// A colour-stage value (linear Rec.2020, scene-referred) as the panel can paint
    /// it: through the real Rec.2020 → sRGB matrix and the sRGB curve. The chip used
    /// to raise the Rec.2020 values to 1/2.2 as if they were sRGB, which drew every
    /// picked colour greyer than it is — the wider primaries read as duller ones.
    static func pointDisplayColor(_ c: RGB) -> Color {
        let s = rec2020ToSRGB.apply(c)
        func encode(_ v: Double) -> Double {
            let x = Num.saturate(v)
            return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        }
        return Color(red: encode(s.r), green: encode(s.g), blue: encode(s.b))
    }

    private static let rec2020ToSRGB: Mat3 = RGBColorSpace.rec2020.matrix(to: .srgb)

    /// Track colours for the swatch's three move rows, from its sample: Hue turns it
    /// ±60° (the row's own travel), Saturation runs grey → sample → twice as vivid,
    /// Luminance darker → sample → lighter.
    static func pointTrackStops(_ point: PointColor)
        -> (hue: [LumenTrackStop]?, saturation: [LumenTrackStop]?, luminance: [LumenTrackStop]?) {
        guard point.sample.count >= 3 else { return (nil, nil, nil) }
        let space = OKLabTransform.working
        let t = space.toLCh(RGB(point.sample[0], point.sample[1], point.sample[2]))
        guard t.L.isFinite, t.C.isFinite else { return (nil, nil, nil) }
        func paint(_ L: Double, _ C: Double, _ h: Double) -> Color {
            pointDisplayColor(space.toRGB(OKLCh(L: Num.clamp(L, 0.05, 0.97),
                                                C: max(C, 0), h: Num.wrapHue(h))))
        }
        let hue = [LumenTrackStop(value: -60, color: paint(t.L, t.C, t.h - 60)),
                   LumenTrackStop(value: 0, color: paint(t.L, t.C, t.h)),
                   LumenTrackStop(value: 60, color: paint(t.L, t.C, t.h + 60))]
        let saturation = [LumenTrackStop(value: -100, color: paint(t.L, 0, t.h)),
                          LumenTrackStop(value: 0, color: paint(t.L, t.C, t.h)),
                          LumenTrackStop(value: 100, color: paint(t.L, 2 * t.C, t.h))]
        let luminance = [LumenTrackStop(value: -100, color: paint(t.L - 0.3, t.C, t.h)),
                         LumenTrackStop(value: 0, color: paint(t.L, t.C, t.h)),
                         LumenTrackStop(value: 100, color: paint(t.L + 0.3, t.C, t.h))]
        return (hue, saturation, luminance)
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
    /// Where the pointer was, and where the grabbed handle TRULY sat, when the press took
    /// hold — so the drag moves the handle by the pointer's travel rather than to the
    /// pointer. The ring may draw a handle away from its true degrees (see `displayArc`);
    /// writing the pointer's own angle would make the first move jump by that offset.
    @State private var grabPointer: Double = 0
    @State private var grabDegrees: Double = 0
    /// The gesture-in-flight signal every slider fires (docs/23 audit queue item 5).
    @Environment(\.sliderGestureChanged) private var sliderGestureChanged

    var body: some View {
        let arcList = arcs
        let index = selected
        let showHandles = arcList.indices.contains(index)
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
                // DRAWN at a legible spread, not at the true degrees, whenever the true
                // arc is too short to see (`displayArc`): the uneven bands' default
                // cores are 3.5–7° a side, which put the two core handles on top of
                // each other and hid the bright arc the caption tells you to drag.
                let truth = arcList[index]
                let arc = MixerHueRing.displayArc(truth, radius: Double(arcRadius))

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
                target.move(to: MixerHueRing.point(centre, arcRadius - 4, truth.coreCentre))
                target.addLine(to: MixerHueRing.point(centre, arcRadius + 4, truth.coreCentre))
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
                        //
                        // Against the arc AS DRAWN (`displayArc`), so a press lands on
                        // the handle the eye is aiming at.
                        let handle: MixerArcHandle
                        if let held = grabbed {
                            handle = held
                        } else {
                            let shown = MixerHueRing.displayArc(
                                arcList[index],
                                radius: Double(MixerHueRing.arcRadius(box: box)))
                            guard let taken = MixerHueRing.grab(at: drag.startLocation,
                                                                box: box,
                                                                arc: shown)
                            else { return }
                            grabbed = taken
                            handle = taken
                            grabPointer = Num.wrapHue(
                                atan2(Double(drag.startLocation.y - box / 2),
                                      Double(drag.startLocation.x - box / 2)) * 180 / .pi)
                            grabDegrees = MixerHueRing.degrees(of: taken, in: arcList[index])
                        }
                        // A PRESS IS NOT A MOVE (B3-05). `minimumDistance: 0` delivers
                        // the press itself as a change, and the first click of a
                        // double-click has `clickCount` 1 — so it moved the grabbed
                        // handle to the clicked angle, the second click reset the arc,
                        // and one ⌘Z landed on an arc nobody made. Nothing is written
                        // until the pointer has actually travelled.
                        guard drag.translation.width != 0 || drag.translation.height != 0
                        else { return }
                        sliderGestureChanged(true)
                        let dx = Double(drag.location.x - box / 2)
                        let dy = Double(drag.location.y - box / 2)
                        // Still needed for the REST of the drag: the press is out in
                        // the annulus, but the pointer is free to cross the centre.
                        guard dx != 0 || dy != 0 else { return }
                        // TRUE degrees: the handle's true position at the press plus
                        // how far the pointer has turned since. Where the ring draws
                        // the handle at its true angle this is exactly the pointer's
                        // angle, as before; where `displayArc` spread it, the drag
                        // starts from where the handle really is instead of jumping.
                        let pointer = Num.wrapHue(atan2(dy, dx) * 180 / .pi)
                        let angle = Num.wrapHue(grabDegrees
                                                + Num.hueDelta(grabPointer, pointer))
                        onHandleMoved(handle, angle)
                    }
                    .onEnded { _ in
                        grabbed = nil
                        pressWasReset = false
                        sliderGestureChanged(false)
                    }
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
        // In the words the caption under the ribbon uses: the bright arc is what the
        // band fully takes, the dim tails are how softly it lets go.
        .help("Drag the ends of the bright arc to set which hues this band takes in, "
              + "and the dim tails to set how softly it lets go. Double-click to put "
              + "the range back.")
    }

    /// The least separation, in points along the arc, between the two core handles'
    /// centres as DRAWN — enough for two 8 pt dots with a visible bright segment between
    /// them (verify R2: at the uneven bands' default cores, 3.5–7° a side, they touched).
    static let minCoreSeparation: Double = 18
    /// The least separation, in points, between a core handle and its feather handle.
    static let minFeatherSeparation: Double = 14

    /// The arc as the ring DRAWS it and hit-tests it: the true arc, except that a core
    /// shorter than `minCoreSeparation` is spread symmetrically about its true core
    /// centre to that length, and each feather handle is kept at its true outer angle
    /// unless that would put it within `minFeatherSeparation` of its core handle. A
    /// display transform only — the recipe, the render and the drag's writes all use the
    /// true arc; the drag moves a handle by the pointer's travel from its true position.
    /// Static and pure, so the separation is arithmetic a test can read.
    static func displayArc(_ arc: ColorEngine.BandArc,
                           radius: Double) -> ColorEngine.BandArc {
        guard radius > 0 else { return arc }
        let degreesPerPoint = 180 / (Double.pi * radius)
        let minCore = minCoreSeparation * degreesPerPoint
        let minTail = minFeatherSeparation * degreesPerPoint
        var below = arc.coreBelow
        var above = arc.coreAbove
        if below + above < minCore {
            // The core centre's offset from the band centre stays where it truly is.
            let mid = (above - below) / 2
            below = minCore / 2 - mid
            above = minCore / 2 + mid
        }
        let featherBelow = Swift.max(arc.coreBelow + arc.featherBelow - below, minTail)
        let featherAbove = Swift.max(arc.coreAbove + arc.featherAbove - above, minTail)
        return ColorEngine.BandArc(centre: arc.centre,
                                   coreBelow: below, coreAbove: above,
                                   featherBelow: featherBelow, featherAbove: featherAbove)
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

// MARK: - Point Colour selection strip

/// What a Point Colour swatch selects, drawn on three axes through its sample: round the
/// wheel (±90°), grey to vivid, dark to light. Each strip is the axis's colours painted
/// at the strength the swatch applies to them — full where it is fully selected, a
/// faint ghost where it is not — with a tick at the sample. The weights are
/// `ColorEngine.pointSelectionStrip`'s, which reads the render's own selection, so the
/// picture moves with Range and the three refinements exactly as the photograph does.
struct PointSelectionStrip: View {
    let swatch: PointColor

    var body: some View {
        let rows = ColorEngine.PointAxis.allCases.map {
            ColorEngine.pointSelectionStrip(swatch, axis: $0, steps: 48)
        }
        let painted: [[Color]] = rows.map { row in row.colours.map(ColorPanel.pointDisplayColor) }
        let weights: [[Double]] = rows.map(\.weights)
        let ticks: [Double] = rows.map(\.samplePosition)

        return Canvas { context, size in
            let gap: CGFloat = 2
            let rowHeight = (size.height - gap * 2) / 3
            guard rowHeight > 1, size.width > 0 else { return }
            for (r, colours) in painted.enumerated() {
                let n = colours.count
                guard n > 1 else { continue }
                let top = CGFloat(r) * (rowHeight + gap)
                let cell = size.width / CGFloat(n)
                for i in 0..<n {
                    let w = min(max(weights[r][i], 0), 1)
                    let rect = CGRect(x: CGFloat(i) * cell, y: top,
                                      width: cell + 0.5, height: rowHeight)
                    // Squared, so the falloff reads as a falloff and the unselected
                    // stretch sinks to a ghost: at 0.16 + 0.84·w (the first snapshot)
                    // the whole strip read as selected.
                    context.fill(Path(rect), with: .color(colours[i].opacity(0.07 + 0.93 * w * w)))
                }
                let x = size.width * CGFloat(ticks[r])
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: top))
                tick.addLine(to: CGPoint(x: x, y: top + rowHeight))
                context.stroke(tick, with: .color(Lumen.primaryText.opacity(0.9)), lineWidth: 1)
            }
        }
        .frame(height: 30)
        .background(Lumen.controlBackground)
        .clipShape(RoundedRectangle(cornerRadius: Lumen.radiusControl, style: .continuous))
        .help("What this swatch selects — round the wheel, grey to vivid, dark to "
              + "light — painted at the strength the edit applies there. The tick is "
              + "the picked colour.")
        .accessibilityLabel("Point colour selection")
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

    var body: some View {
        let samples = weights
        let palette = colors
        let highlighted = selected

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
                let emphasised = band == highlighted
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
