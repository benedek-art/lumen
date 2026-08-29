// LookPanel.swift
// The Look panel: grading wheels over VISIBLE zones, printer lights, primaries, the
// display transform and the Film Lab.
//
// This panel is deliberately not Develop. Everything in it is the portable layer (D4):
// one grade applies to eight hundred frames as a selection gesture, while each frame
// keeps its own white balance, exposure and denoise. It used to say that in a tinted
// banner across the top of the column, every time the section opened; it says it now
// where a hand asks — on the Save button that writes one.
//
// The zone strip is the load-bearing difference from Lightroom's colour grading: LrC's
// tonal zones exist but are invisible and fixed, so "why did my shadow tint land in the
// midtones" has no answer on screen. Here the weights are drawn from GradeEngine's own
// windows and the pivots are draggable.

#if os(macOS)

import AppKit
import Foundation
import LumenCore
import SwiftUI

struct LookPanel: View {
    @EnvironmentObject var state: AppState
    /// This surface shows the edit, so it observes the edit signal —
    /// `AppState.recipes` is deliberately not published (see `EditRevision`).
    @EnvironmentObject var edits: EditRevision

    // Folds inside a section, not the sections themselves: the accordion decides
    // whether Grading is open, these decide whether the rows under one of its headers
    // are. See `DevelopDisclosure`, whose job this is.
    @State private var wheelsExpanded: Bool = true
    /// Which zone the single large wheel is grading. View state and nothing else — the
    /// recipe holds all four grades whichever one is on screen.
    @State private var gradeZone: GradeZone = .shadows
    /// Closed by default: the wheel is the first-second surface, and the grid is for
    /// the second pass. It is a disclosure of the grade, not a second grading tool
    /// (D3) — which is why it lives inside `wheelsSection` rather than beside it.
    @State private var balanceExpanded: Bool = false
    @State private var printerExpanded: Bool = true
    @State private var primariesExpanded: Bool = false
    @State private var transformExpanded: Bool = true
    @State private var filmExpanded: Bool = true
    @State private var looksExpanded: Bool = true
    /// The name being typed into the save field. View state, not recipe state: it
    /// belongs to nothing until the photographer presses Save.
    @State private var newLookName: String = ""

    /// nil renders every section this panel owns, which is what the tab did.
    ///
    /// This panel's seven groups are spread over three sections — `.looks`, `.grading`
    /// and `.filmLab` — so the column draws it three times, each time asking for one of
    /// them. See `renders(_:)` for what belongs to which.
    var only: WorkspaceSection?

    /// Spelled out because the synthesised memberwise initialiser is private the moment
    /// any stored property is, and every `@State` fold above is. Without this,
    /// `LookPanel(only:)` would not be callable from the column that draws it.
    init(only: WorkspaceSection? = nil) {
        self.only = only
    }

    /// What this panel's own section headers pass for `LumenSectionHeader.topRhythm`,
    /// which is that parameter's own distinction: 16 is a section boundary, 8 is a fold.
    ///
    /// Under `only:` the column has already printed the section header above them, so a
    /// second full boundary would make each sub-heading shout as loudly as the heading
    /// it sits under. With `only` nil this panel IS the column and they are top-level
    /// sections, which is the 16 they have always had.
    ///
    /// The one disclosure nested deeper — Colour balance — is left alone: it is a fold
    /// inside a section in both framings, so nothing about its rank changed here.
    /// Transform detail, which was the other one, is not a fold any more.
    private var innerRhythm: CGFloat { only == nil ? 16 : 8 }

    /// The normalized tonal axis the pivots live on spans black anchor → white anchor,
    /// i.e. −9 EV … +5 EV (ZoneWindows' defaults). Balance is denominated in EV, so the
    /// handle geometry needs the span to convert.
    static let axisSpanEV: Double = 14.0

    /// The four grades, in the order the tonal axis puts them.
    ///
    /// Global sits last rather than first even though it applies everywhere, because
    /// the strip above reads dark→light and a segment that breaks that order would make
    /// the control stop being a picture of the axis.
    enum GradeZone: String, CaseIterable, Hashable {
        case shadows = "Shadows"
        case mid = "Midtones"
        case high = "Highlights"
        case global = "Global"

        var title: String { rawValue }

        var path: WritableKeyPath<GradingWheels, Wheel> {
            switch self {
            case .shadows: return \GradingWheels.shadows
            case .mid: return \GradingWheels.mid
            case .high: return \GradingWheels.high
            case .global: return \GradingWheels.global
            }
        }
    }

    // MARK: - Body

    var body: some View {
        // No ScrollView, no outer padding, no background. `DevelopPanel.scrollColumn`
        // supplies all three around whatever a section draws, and a second ScrollView
        // inside a scrolling column is a scroll trap: the wheel would stop moving the
        // column wherever the pointer happened to be over these rows, which is most of
        // the column's height.
        VStack(alignment: .leading, spacing: 2) {
            // Six groups, and until now five hairlines between them. The headers carry
            // their own boundary instead (`LumenSectionHeader.topRhythm`, sized by
            // `innerRhythm`) — design audit §1.1, and the rhythm BasicPanel has always
            // had.
            //
            // NOTHING PRECEDES THE FIRST SECTION ANY MORE. An accent-tinted box with a
            // LOOK badge used to open this column and spend thirty-eight words saying
            // what a saved look carries — redrawn every time the section opened, whether
            // or not one had ever been saved, and carrying not one fact about the
            // photograph in front of it. Its deletion is the point (docs/30 Phase A step
            // 4); what it explained is on the tooltip of the button that saves one.
            if renders(.looks) {
                savedLooksSection
            }
            if renders(.grading) {
                wheelsSection
                printerLightsSection
                primariesSection
            }
            // PARKED IN LOOKS, NOT SETTLED THERE. `WorkspaceSection` says outright that
            // the display transform is not in docs/28 §5.1's Develop list and leaves
            // `canonicalRank` 3 free for the day it gets a section of its own. Until
            // then it rides with the look, last, because it is a rendering choice
            // attached to one — and because the alternative, rendering it nowhere,
            // silently deletes a control the tab strip had.
            if renders(.looks) {
                transformSection
            }
            if renders(.filmLab) {
                filmLabSection
            }
        }
    }

    /// Whether the column asked for this section — and true for all of them when it
    /// asked for the whole panel, which is the tab's own behaviour.
    private func renders(_ section: WorkspaceSection) -> Bool {
        only == nil || only == section
    }

    // MARK: - Saved looks

    /// The browser. Deliberately a list of names and nothing more.
    ///
    /// No swatches: a swatch has to be rendered through the pipeline against some
    /// photograph, and which photograph is a question this pass did not answer — an
    /// arbitrary one would be a picture of somebody else's frame presented as a preview
    /// of what this look does to yours. No hover preview either (audit UX-17 wants one
    /// and it needs a ≤100 ms proxy path that does not exist yet). What is here is the
    /// whole of docs/19's sentence and no more: name the look on this frame, and it is
    /// on any photo in any folder afterwards.
    private var savedLooksSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Saved Looks", isExpanded: $looksExpanded,
                               topRhythm: innerRhythm)

            if looksExpanded {
                HStack(spacing: 4) {
                    TextField("Name this look", text: $newLookName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .onSubmit { saveCurrentLook() }
                    Button {
                        saveCurrentLook()
                    } label: {
                        Text("Save")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(canSaveLook ? Lumen.accent : Lumen.secondaryText)
                    .disabled(!canSaveLook)
                    .help("Store this photo's grade, film stock and transform under "
                          + "that name. Its exposure, white balance and crop stay with "
                          + "the photo.")
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(Lumen.controlBackground)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                // An empty list draws nothing at all, deliberately. The field and
                // the Save button above it are the affordance; a sentence announcing
                // that a list is empty is a caption on absence. The paragraph that used
                // to close the list said what the banner said and what Save's tooltip
                // says — three statements of one sentence in one section.
                ForEach(state.savedLooks, id: \.id) { look in
                    savedLookRow(look)
                }
            }
        }
        // On the section that reads the list, not on the panel, which is where it used
        // to sit. A closed accordion section never builds its rows, so a refresh hung
        // off the panel would fire when Grading opened and never when Looks did — and
        // the header stays built whether or not `looksExpanded` is on, so this fires
        // once per appearance either way.
        .onAppear { state.refreshSavedLooks() }
    }

    private func savedLookRow(_ look: LookRow) -> some View {
        HStack(spacing: 6) {
            Button {
                state.applyLook(look)
            } label: {
                Text(look.name)
                    .font(.system(size: 11))
                    .foregroundStyle(Lumen.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Apply \"\(look.name)\" to the selection")

            Button {
                state.deleteLook(look)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(Lumen.secondaryText)
            }
            .buttonStyle(.plain)
            .help("Delete \"\(look.name)\". Photos already graded with it keep their "
                  + "grade.")
        }
        .frame(height: Lumen.rowHeight)
    }

    private var canSaveLook: Bool {
        LookSubset.normalizedName(newLookName) != nil
    }

    private func saveCurrentLook() {
        guard canSaveLook else { return }
        state.saveCurrentLook(named: newLookName)
        newLookName = ""
    }

    // MARK: - Grading wheels

    private var wheelsSection: some View {
        let wheels = state.currentRecipe.look.wheels
        let pivots = LookPanel.normalizedPivots(wheels.pivots)
        let modified = !LookPanel.isNeutral(wheels)

        return VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Colour Grading",
                               isExpanded: $wheelsExpanded,
                               isModified: modified,
                               onReset: { state.updateRecipe { $0.look.wheels = GradingWheels() } },
                               topRhythm: innerRhythm)

            if wheelsExpanded {
                ZoneWeightStrip(pivots: pivots,
                                blending: wheels.blending,
                                balance: wheels.balance,
                                onPivotChanged: { index, position in
                                    movePivot(index, to: position)
                                })

                // ONE wheel at a time, at more than twice the diameter (docs/28 Phase 5).
                //
                // Four 68-point wheels in a 320-point column was the "clunky" the owner
                // named: a puck is placed by eye at a radius, so half the radius is half
                // the precision for the same hand movement, and a 2×2 grid of them gives
                // no cue about which zone you are working — you read four captions and
                // count. Lightroom's grading is the most learnable in the field for
                // exactly this reason: one instrument, one meaning, fixed in place.
                //
                // What showing one at a time costs is the at-a-glance answer to "what
                // did I change?", which this app is built to answer down a whole panel.
                // So the segmented control carries the accent dot per zone — the same
                // mark a modified section header wears — and the answer stays one look
                // rather than four clicks.
                LumenSegmented(options: GradeZone.allCases.map {
                                   (value: $0, label: $0.rawValue)
                               },
                               selection: $gradeZone,
                               marked: touchedZones(wheels))
                wheel(gradeZone.title, path: gradeZone.path, diameter: 150)
                    .frame(maxWidth: .infinity)

                // THE SENTENCE IS ON THE ROW IT IS ABOUT, here and at three more
                // sites in this file. A non-prominent `DevelopNote` draws nothing now,
                // so each of those paragraphs was a string built for no reader; what
                // each said about one control is that control's `help:`, which is what
                // the pointer is already over when the question gets asked.
                LumenSlider(title: "Blending",
                            value: bindLook(\Look.wheels.blending, key: "wheels.blending"),
                            range: 0...100, defaultValue: 50, step: 1, decimals: 0,
                            bipolar: false,
                            help: "Widens the crossfades between the zones the strip "
                                + "above draws.")
                LumenSlider(title: "Balance",
                            value: bindLook(\Look.wheels.balance, key: "wheels.balance"),
                            range: -100...100, defaultValue: 0, step: 1, decimals: 0,
                            help: "Slides both pivots along the tonal axis together.")

                colorBalanceDisclosure
            }
        }
    }

    // MARK: - Colour balance (the advanced grid, D15)

    /// darktable's colour balance rgb, folded into one disclosure of the grade.
    ///
    /// Three axes that a naive HSL model would collapse into a single chroma multiply,
    /// and that read as three intents here because the engine separates them properly:
    /// Chroma is colourfulness at fixed lightness, Saturation is the colourfulness /
    /// lightness RATIO at fixed H-K brightness, Brilliance is H-K brightness at fixed
    /// ratio. What is deliberately NOT on screen is darktable's own leaked internals —
    /// the white fulcrum, the saturation-formula picker, the checkerboard preferences.
    /// There is one formula.
    private var colorBalanceDisclosure: some View {
        let grid = state.currentRecipe.look.wheels.colorBalance

        return VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Colour balance",
                               isExpanded: $balanceExpanded,
                               isModified: !grid.isZero,
                               onReset: {
                                   state.updateRecipe {
                                       $0.look.wheels.colorBalance = ColorBalanceParams()
                                   }
                               })

            if balanceExpanded {
                LumenSlider(title: "Hue shift",
                            value: bindLook(\Look.wheels.colorBalance.hueShift,
                                            key: "cb.hueShift"),
                            range: -180...180, defaultValue: 0, step: 1, decimals: 0)
                LumenSlider(title: "Vibrance",
                            value: bindLook(\Look.wheels.colorBalance.vibrance,
                                            key: "cb.vibrance"),
                            range: -100...100, defaultValue: 0, step: 1, decimals: 0)

                balanceAxis("Chroma", \Look.wheels.colorBalance.chroma, "cb.chroma",
                            note: "Colourfulness at constant lightness and hue.")

                balanceAxis("Saturation", \Look.wheels.colorBalance.saturation,
                            "cb.saturation",
                            note: "The colourfulness/lightness ratio, at constant H-K "
                                + "corrected brightness — the move that does not make a "
                                + "pushed blue read as if it dimmed.")

                // A soft warning, not a clamp. darktable's own documentation calls past
                // ±20 artifact territory, and the honest thing is to say so while still
                // letting the slider go there.
                balanceAxis("Brilliance", \Look.wheels.colorBalance.brilliance,
                            "cb.brilliance",
                            note: LookPanel.brillianceIsPushed(grid.brilliance)
                                ? "Past ±20 is artifact territory — highlights start to "
                                    + "flatten and shadows to plug."
                                : "H-K corrected brightness at constant ratio: "
                                    + "exposure-like, perceptually scaled.",
                            warn: LookPanel.brillianceIsPushed(grid.brilliance))
            }
        }
    }

    /// One axis of the grid: Global on top, then the three zones, in the same order the
    /// wheels are laid out so the two halves of the panel read the same way. The axis
    /// carries its own note so the disclosure's builder stays inside its ten-child limit.
    private func balanceAxis(_ title: String,
                             _ axis: WritableKeyPath<Look, ColorBalanceAxis>,
                             _ key: String,
                             note: String,
                             warn: Bool = false) -> some View {
        // Spelled out with explicit types rather than inline `appending(path:)`:
        // `appending` is overloaded on key-path writability, and letting the result type
        // be inferred through a function argument is exactly where that resolution gets
        // ambiguous. There is no Swift compiler on this side of the build for LumenApp.
        let global: WritableKeyPath<Look, Double> =
            axis.appending(path: \ColorBalanceAxis.global)
        let shadows: WritableKeyPath<Look, Double> =
            axis.appending(path: \ColorBalanceAxis.shadows)
        let mid: WritableKeyPath<Look, Double> =
            axis.appending(path: \ColorBalanceAxis.mid)
        let high: WritableKeyPath<Look, Double> =
            axis.appending(path: \ColorBalanceAxis.high)

        return VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Lumen.secondaryText)
                .padding(.top, 4)
            LumenSlider(title: "Global",
                        value: bindLook(global, key: key + ".global"),
                        range: -100...100, defaultValue: 0, step: 1, decimals: 0)
            LumenSlider(title: "Shadows",
                        value: bindLook(shadows, key: key + ".shadows"),
                        range: -100...100, defaultValue: 0, step: 1, decimals: 0)
            LumenSlider(title: "Midtones",
                        value: bindLook(mid, key: key + ".mid"),
                        range: -100...100, defaultValue: 0, step: 1, decimals: 0)
            LumenSlider(title: "Highlights",
                        value: bindLook(high, key: key + ".high"),
                        range: -100...100, defaultValue: 0, step: 1, decimals: 0)
            Text(note)
                .font(.system(size: 10))
                .foregroundStyle(warn ? Lumen.accent : Lumen.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)
        }
    }

    /// Whether any Brilliance field is far enough out to earn the warning line.
    static func brillianceIsPushed(_ axis: ColorBalanceAxis) -> Bool {
        let limit: Double = 20
        return abs(axis.global) > limit || abs(axis.shadows) > limit
            || abs(axis.mid) > limit || abs(axis.high) > limit
    }

    private func wheel(_ title: String, path: WritableKeyPath<GradingWheels, Wheel>,
                       diameter: CGFloat = 68) -> some View {
        // The caption is empty on the big wheel — the segmented control above already
        // names the zone — but the COALESCING KEYS still carry the title, because they
        // are what makes one drag one undo step and they must not collide between
        // zones. That is why `title` is passed even when nothing draws it.
        LumenColorWheel(title: "",
                        hue: bindWheel(path, \Wheel.hue, key: "wheel.\(title).hue"),
                        sat: bindWheel(path, \Wheel.sat, key: "wheel.\(title).sat"),
                        lum: bindWheel(path, \Wheel.lum, key: "wheel.\(title).lum"),
                        diameter: diameter)
    }

    /// Which zones hold a grade, for the segmented control's dots.
    ///
    /// `sat == 0 && lum == 0` is the same test `isNeutral` uses for the section's own
    /// marker, so a lit dot and a lit section header can never disagree. Hue alone is
    /// deliberately not enough: a hue with no saturation grades nothing, and marking it
    /// would report a change the picture cannot show.
    private func touchedZones(_ wheels: GradingWheels) -> Set<GradeZone> {
        var lit: Set<GradeZone> = []
        for zone in GradeZone.allCases {
            let w = wheels[keyPath: zone.path]
            if w.sat != 0 || w.lum != 0 { lit.insert(zone) }
        }
        return lit
    }

    private func movePivot(_ index: Int, to position: Double) {
        state.updateRecipe(coalescingKey: "wheels.pivot.\(index)") { recipe in
            var pivots = LookPanel.normalizedPivots(recipe.look.wheels.pivots)
            // The handle is dragged where the user sees it — that is the pivot AFTER
            // Balance — so the stored pivot is the handle minus the balance shift.
            let shift = (Num.clamp(recipe.look.wheels.balance, -100, 100) / 100)
                * ZoneWindows.balanceRangeEV / LookPanel.axisSpanEV
            let gap = ZoneWindows.minimumPivotGap
            var value = Num.saturate(position - shift)
            if index == 0 {
                value = min(value, pivots[1] - gap)
                pivots[0] = Num.saturate(value)
            } else {
                value = max(value, pivots[0] + gap)
                pivots[1] = Num.saturate(value)
            }
            recipe.look.wheels.pivots = pivots
        }
    }

    // MARK: - Printer lights

    private var printerLightsSection: some View {
        let lights = state.currentRecipe.look.printerLights
        let modified = lights.master != 0 || lights.r != 0 || lights.g != 0 || lights.b != 0
        let masterLimit = Int(GradeEngine.masterPointLimit)
        let trimLimit = Int(GradeEngine.trimPointLimit)

        return VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Printer Lights",
                               isExpanded: $printerExpanded,
                               isModified: modified,
                               onReset: { state.updateRecipe { $0.look.printerLights = PrinterLights() } },
                               topRhythm: innerRhythm)

            if printerExpanded {
                // `,` and `.` step the master; the same pair with ⌃ / ⌥ / ⇧ steps one
                // channel. The real interface here is the keyboard, watching the image.
                printerRow("Master", "master", lights.master, masterLimit, [])
                printerRow("Red / Cyan", "r", lights.r, trimLimit, .control)
                printerRow("Green / Mag", "g", lights.g, trimLimit, .option)
                printerRow("Blue / Yellow", "b", lights.b, trimLimit, .shift)
            }
        }
    }

    private func printerRow(_ title: String, _ channel: String, _ points: Int,
                            _ limit: Int, _ modifiers: EventModifiers) -> some View {
        PrinterLightRow(title: title, points: points, limit: limit,
                        decrement: KeyEquivalent(","), increment: KeyEquivalent("."),
                        modifiers: modifiers,
                        onStep: { delta in step(channel, by: delta) },
                        onReset: { setPoints(channel, to: 0) })
    }

    private func step(_ channel: String, by delta: Int) {
        state.updateRecipe(coalescingKey: "printer.\(channel)") { recipe in
            LookPanel.applyPoints(&recipe.look.printerLights, channel: channel, delta: delta,
                                  absolute: nil)
        }
    }

    private func setPoints(_ channel: String, to value: Int) {
        state.updateRecipe { recipe in
            LookPanel.applyPoints(&recipe.look.printerLights, channel: channel, delta: 0,
                                  absolute: value)
        }
    }

    static func applyPoints(_ lights: inout PrinterLights, channel: String,
                            delta: Int, absolute: Int?) {
        let masterLimit = Int(GradeEngine.masterPointLimit)
        let trimLimit = Int(GradeEngine.trimPointLimit)
        switch channel {
        case "master":
            let next = absolute ?? (lights.master + delta)
            lights.master = min(max(next, -masterLimit), masterLimit)
        case "r":
            let next = absolute ?? (lights.r + delta)
            lights.r = min(max(next, -trimLimit), trimLimit)
        case "g":
            let next = absolute ?? (lights.g + delta)
            lights.g = min(max(next, -trimLimit), trimLimit)
        case "b":
            let next = absolute ?? (lights.b + delta)
            lights.b = min(max(next, -trimLimit), trimLimit)
        default:
            break
        }
    }

    // MARK: - Primaries

    private var primariesSection: some View {
        let p = state.currentRecipe.look.primaries
        let modified = p != Primaries()

        return VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Primaries",
                               isExpanded: $primariesExpanded,
                               isModified: modified,
                               onReset: { state.updateRecipe { $0.look.primaries = Primaries() } },
                               topRhythm: innerRhythm)

            if primariesExpanded {
                // The paragraph that used to close this group is the tooltip on all
                // eight rows — see `bipolarSlider`, which carries it.
                bipolarSlider("Red Hue", \Look.primaries.rHue, "prim.rHue")
                bipolarSlider("Red Purity", \Look.primaries.rPurity, "prim.rPurity")
                bipolarSlider("Green Hue", \Look.primaries.gHue, "prim.gHue")
                bipolarSlider("Green Purity", \Look.primaries.gPurity, "prim.gPurity")
                bipolarSlider("Blue Hue", \Look.primaries.bHue, "prim.bHue")
                bipolarSlider("Blue Purity", \Look.primaries.bPurity, "prim.bPurity")
                bipolarSlider("Shadow Tint", \Look.primaries.tintHue, "prim.tintHue")
                bipolarSlider("Tint Purity", \Look.primaries.tintPurity, "prim.tintPurity")
            }
        }
    }

    // MARK: - Display transform

    private var transformSection: some View {
        let render = state.currentRecipe.look.render
        let base = DisplayTransformParams.preset(named: render.preset)

        return VStack(alignment: .leading, spacing: 2) {
            // The baseline is the PHOTO's, not the type's: a rendered file starts on
            // the Linear preset, so comparing against RenderParams() marked every
            // untouched JPEG modified — and Reset re-applied the default sigmoid on
            // top of the camera's own curve.
            //
            // THE TITLE NAMES THE STOCK, and that is what replaced sixty-five words. A
            // loaded stock bypasses this stage completely, and three paragraphs in this
            // one file used to say so — the longest of them shouting two words in
            // capitals directly above four controls that were sitting there, visible
            // and inert, saying nothing about it themselves. Six words in the header
            // answer it where the eye already is; the rows below answer it by going
            // dim. Prose was never the only way to be honest about a disabled control.
            //
            // One line, allowed to shrink, because the loaded form is long: uppercased
            // at 12 pt semibold with 0.7 tracking it wants about 344 points and the
            // column offers roughly 271 beside the chevron, less again when a modified
            // section lays out its Reset. A section header that wrapped to two lines
            // would read as a bug rather than as emphasis, and one that truncated would
            // eat the stock's name, which is the whole point of the line.
            LumenSectionHeader(title: transformTitle,
                               isExpanded: $transformExpanded,
                               isModified: render != state.currentStartingRecipe.look.render,
                               onReset: { state.updateRecipe { photo, recipe in
                                   recipe.look.render = AppState.startingRecipe(
                                       for: photo.id, iso: photo.iso).look.render
                               } },
                               topRhythm: innerRhythm)
                .lineLimit(1)
                .minimumScaleFactor(0.65)

            if transformExpanded {
                // Ghosted, not hidden. The values are still the recipe's, they still
                // travel in the sidecar, and they render the moment the stock comes off
                // — but a control the user can drag while it cannot reach a pixel is
                // the defect this section shipped with. Opacity alone, with no fill or
                // second surface behind it: a disabled state drawn as another box would
                // add an object to a column that already has too many.
                transformControls(base: base)
                    .disabled(transformIsInert)
                    .opacity(transformIsInert ? 0.30 : 1)
            }
        }
    }

    /// "Display Transform", or the stock that has taken it over.
    ///
    /// Printed without the `Lumen ` prefix all six stocks carry: it distinguishes
    /// nothing when every one of them has it, and this line has to fit beside a
    /// chevron, a modified dot and a Reset in the width of the column.
    private var transformTitle: String {
        guard let stock = replacingStock else { return "Display Transform" }
        let name = stock.hasPrefix("Lumen ") ? String(stock.dropFirst(6)) : stock
        return "Display Transform · replaced by " + name
    }

    /// The stock standing in for this stage, or nil while the stage is live.
    ///
    /// The three terms are `RenderPlan.init`'s own — a film block, a positive Strength,
    /// and a stock this build actually ships — because they are the exact condition
    /// under which its display closure bypasses `transform` entirely. A recipe naming a
    /// stock we do not have falls back to the neutral transform, and at that point
    /// these controls are live again.
    private var replacingStock: String? {
        guard let film = state.currentRecipe.look.filmLab, film.amount > 0,
              let stock = FilmStock.named(film.stock) else { return nil }
        return stock.name
    }

    private var transformIsInert: Bool { replacingStock != nil }

    @ViewBuilder
    private func transformControls(base: DisplayTransformParams) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            pickerRow("Preset") {
                Picker("", selection: presetBinding) {
                    ForEach(DisplayTransformParams.presetNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
            }

            // ONE FOLD, NOT TWO. Opening Display Transform used to reveal this picker
            // and a second chevron, "Transform detail", over the four rows below it. A
            // fold whose content is a fold is not depth, it is a stutter, and four rows
            // is not enough to hide (docs/30 Phase A step 7). The inner group's own
            // Reset went with its chevron, and nothing is lost by that: each row still
            // clears its override on a double-click, and the section header above
            // returns the whole stage to this photograph's starting point.
            LumenSlider(title: "Contrast",
                        value: renderBinding("render.contrast",
                                             get: { $0.contrast },
                                             fallback: base.contrast,
                                             set: { $0.contrast = $1 }),
                        range: 0.1...10, defaultValue: base.contrast,
                        step: 0.05, decimals: 2, bipolar: false,
                        help: LookPanel.overrideHelp,
                        onReset: { clearTransformOverride(\.contrast) })
            LumenSlider(title: "Skew",
                        value: renderBinding("render.skew",
                                             get: { $0.skew },
                                             fallback: base.skew,
                                             set: { $0.skew = $1 }),
                        range: -1...1, defaultValue: base.skew,
                        step: 0.01, decimals: 2,
                        help: LookPanel.overrideHelp,
                        onReset: { clearTransformOverride(\.skew) })
            LumenSlider(title: "Hue keep",
                        value: renderBinding("render.hue",
                                             get: { $0.huePreservation },
                                             fallback: base.huePreservation,
                                             set: { $0.huePreservation = $1 }),
                        range: 0...100, defaultValue: base.huePreservation,
                        step: 1, decimals: 0, bipolar: false,
                        help: LookPanel.overrideHelp,
                        onReset: { clearTransformOverride(\.huePreservation) })
            LumenSlider(title: "Black target",
                        value: renderBinding("render.black",
                                             get: { $0.blackTarget },
                                             fallback: base.blackTarget,
                                             set: { $0.blackTarget = $1 }),
                        range: 0...15, defaultValue: base.blackTarget,
                        step: 0.01, decimals: 2, bipolar: false,
                        help: LookPanel.overrideHelp,
                        onReset: { clearTransformOverride(\.blackTarget) })
        }
    }

    /// The line that used to close the fold, on each of the four rows it was about.
    private static let overrideHelp =
        "Untouched, this follows the preset, so a retuned preset reaches every recipe "
        + "that only named it. Move it and it pins itself to this image."

    private var presetBinding: Binding<String> {
        Binding(
            get: { state.currentRecipe.look.render.preset },
            set: { name in state.updateRecipe { $0.look.render.preset = name } })
    }

    /// Clear ONE override back to following the preset.
    ///
    /// `LumenSlider`'s double-click reset writes `defaultValue`, and for these four rows
    /// the default is the preset's current value — so resetting pinned that number
    /// instead of clearing the override. The row stayed marked modified and stopped
    /// following a retuned preset, which is the exact behaviour the group's tooltip
    /// promises you get by NOT touching it.
    private func clearTransformOverride(
        _ field: WritableKeyPath<RenderParams, Double?>) {
        state.updateRecipe { recipe in
            recipe.look.render[keyPath: field] = nil
        }
    }

    private func renderBinding(_ key: String,
                               get: @escaping (RenderParams) -> Double?,
                               fallback: Double,
                               set: @escaping (inout RenderParams, Double) -> Void) -> Binding<Double> {
        Binding(
            get: { get(state.currentRecipe.look.render) ?? fallback },
            set: { value in
                state.updateRecipe(coalescingKey: key) { set(&$0.look.render, value) }
            })
    }

    // MARK: - Film Lab

    /// The only header in either panel that collides with its own section's title:
    /// `WorkspaceSection.filmLab.title` is "Film Lab" too. Under `only:` the column has
    /// already printed that word, so printing it again immediately underneath would be
    /// the same heading twice with nothing between them.
    ///
    /// Dropping the header takes `filmExpanded` with it on that path, and that is the
    /// point rather than a side effect: the accordion's header owns whether the section
    /// is open, and a second gate left behind with no chevron to reopen it could only
    /// ever hide these rows for good.
    @ViewBuilder
    private var filmLabSection: some View {
        if only == nil {
            let film = state.currentRecipe.look.filmLab
            VStack(alignment: .leading, spacing: 2) {
                LumenSectionHeader(title: "Film Lab",
                                   isExpanded: $filmExpanded,
                                   isModified: film != nil,
                                   onReset: { state.updateRecipe { $0.look.filmLab = nil } })

                if filmExpanded { filmLabRows }
            }
        } else {
            filmLabRows
        }
    }

    /// One definition of the rows, so the two framings above can never drift apart.
    @ViewBuilder
    private var filmLabRows: some View {
        let film = state.currentRecipe.look.filmLab
        let stock = film.flatMap { FilmStock.named($0.stock) }

        pickerRow("Stock") {
            Picker("", selection: stockBinding) {
                Text("None").tag("")
                ForEach(FilmStock.all, id: \.id) { candidate in
                    Text(candidate.name).tag(candidate.id)
                }
            }
        }

        if let film {
            LumenSlider(title: "Strength",
                        value: bindFilm("film.amount",
                                        get: { $0.amount },
                                        set: { $0.amount = Num.clamp($1, 0, 100) }),
                        range: 0...100, defaultValue: 100, step: 1, decimals: 0,
                        bipolar: false)
            LumenSlider(title: "Film Exposure",
                        value: bindFilm("film.exposure",
                                        get: { $0.exposure },
                                        set: { $0.exposure = Num.clamp($1, -2, 3) }),
                        range: -2...3, defaultValue: 0, step: 0.25, decimals: 2)
            LumenSlider(title: "Push / Pull",
                        value: bindFilm("film.push",
                                        get: { $0.pushPull },
                                        set: { $0.pushPull = Num.clamp($1, -1, 2) }),
                        range: -1...2, defaultValue: 0, step: 0.25, decimals: 2)
            LumenSlider(title: "Halation",
                        value: bindFilm("film.halation",
                                        get: { $0.halation },
                                        set: { $0.halation = Num.clamp($1, 0, 100) }),
                        range: 0...100,
                        defaultValue: stock?.halationDefault ?? 0,
                        step: 1, decimals: 0, bipolar: false)
            // NO PRINT SIZE CONTROL, and no caption apologising for one. A menu of
            // five sizes shipped once, above a sentence explaining that choosing one
            // does nothing; the caption has now gone after the menu, so the reasoning
            // lives here instead of nowhere. `plateScale` reaches pixels through
            // enlargement × the print's pixel density, the print's long edge appears in
            // both factors and cancels exactly, and the proof
            // `testGrainFollowsTheGateAndTheRenderSizeNotThePrintSize` pins that to
            // 1e-12 from 5″ to 30″ — grain follows the GATE and the render's pixel
            // count. `FilmLab.printSize` stays on the wire for the day the gate becomes
            // selectable (35 mm / half-frame / 120, the control docs/05 asked for and
            // the one variable that provably moves grain), which is the other half of
            // that arithmetic.
            LumenSlider(title: "Grain",
                        value: bindFilm("film.grain.amount",
                                        get: { $0.grain.amount },
                                        set: { $0.grain.amount = Num.clamp($1, 0, 100) }),
                        range: 0...100,
                        defaultValue: stock?.grainDefault ?? 0,
                        step: 1, decimals: 0, bipolar: false)
            LumenSlider(title: "Grain size",
                        value: bindFilm("film.grain.size",
                                        get: { $0.grain.size },
                                        set: { $0.grain.size = Num.clamp($1, 0.5, 2.0) }),
                        range: 0.5...2.0, defaultValue: 1.0, step: 0.05, decimals: 2,
                        bipolar: false)

            // What a loaded stock does to the Display Transform is not written here
            // any more. It was written here, and above the transform's own controls,
            // and again where no stock is loaded at all — one fact, three paragraphs,
            // one panel. The Display Transform header now names the stock that replaced
            // it and its rows sit ghosted underneath, which is the same fact in six
            // words at the place the eye is already looking.
            if stock == nil {
                // The one line in this file that must be READ rather than merely
                // available: the recipe names a stock, the picture does not show it,
                // and nothing else on screen says so.
                caption("\u{201C}\(film.stock)\u{201D} is not a stock this build "
                        + "ships — the render falls back to the neutral "
                        + "transform rather than to a different look.",
                        prominent: true)
            }
        }
    }

    private var stockBinding: Binding<String> {
        Binding(
            get: { state.currentRecipe.look.filmLab?.stock ?? "" },
            set: { id in
                state.updateRecipe { recipe in
                    guard !id.isEmpty, let picked = FilmStock.named(id) else {
                        recipe.look.filmLab = nil
                        return
                    }
                    // Picking a card seeds the stock's own defaults; the recipe never
                    // silently keeps the previous stock's halation and grain.
                    recipe.look.filmLab = FilmChain.defaultRecipe(for: picked)
                }
            })
    }

    private func bindFilm(_ key: String,
                          get: @escaping (FilmLab) -> Double,
                          set: @escaping (inout FilmLab, Double) -> Void) -> Binding<Double> {
        Binding(
            get: {
                guard let film = state.currentRecipe.look.filmLab else { return 0 }
                return get(film)
            },
            set: { value in
                state.updateRecipe(coalescingKey: key) { recipe in
                    guard var film = recipe.look.filmLab else { return }
                    set(&film, value)
                    recipe.look.filmLab = film
                }
            })
    }

    // MARK: - Shared bindings and helpers

    /// A label plus a menu, on the same grid as a slider row.
    private func pickerRow<Content: View>(_ title: String,
                                          @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Lumen.secondaryText)
                .frame(width: Lumen.labelWidth, alignment: .leading)
            content()
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
        }
        .frame(height: Lumen.rowHeight)
    }

    /// The −100…+100, default-0 row this panel is mostly made of.
    ///
    /// Every caller is a Primaries row, so the clause those eight rows need is the
    /// default rather than the same long string written eight times. It is the one
    /// question all eight raise — how is this not the mixer — and it used to be a
    /// paragraph under the group. A caller from anywhere else passes its own.
    private func bipolarSlider(_ title: String,
                               _ path: WritableKeyPath<Look, Double>,
                               _ key: String,
                               _ help: String = LookPanel.primariesHelp) -> some View {
        LumenSlider(title: title, value: bindLook(path, key: key),
                    range: -100...100, defaultValue: 0, step: 1, decimals: 0,
                    help: help)
    }

    private static let primariesHelp =
        "Redefines what red, green and blue mean for this image. The mixer targets "
        + "pixels that look blue; a primary moves every pixel containing blue — "
        + "global, smooth, and unable to posterize. Greys are preserved by "
        + "construction."


    private func bindLook(_ path: WritableKeyPath<Look, Double>, key: String) -> Binding<Double> {
        Binding(
            get: { state.currentRecipe.look[keyPath: path] },
            set: { v in state.updateRecipe(coalescingKey: key) { $0.look[keyPath: path] = v } })
    }

    private func bindWheel(_ path: WritableKeyPath<GradingWheels, Wheel>,
                           _ component: WritableKeyPath<Wheel, Double>,
                           key: String) -> Binding<Double> {
        Binding(
            get: { state.currentRecipe.look.wheels[keyPath: path][keyPath: component] },
            set: { v in
                state.updateRecipe(coalescingKey: key) {
                    $0.look.wheels[keyPath: path][keyPath: component] = v
                }
            })
    }

    /// The one paragraph this panel still draws (see `DevelopNote`).
    ///
    /// It carried thirteen of these plus a boxed banner — the heaviest prose load in
    /// the app after Masks, in the tab that also holds thirty-eight sliders. Twelve are
    /// gone: a non-prominent note renders nothing at all now, so each of them was a
    /// string built for nobody, and the clauses worth keeping moved onto the `.help` of
    /// the control they were about. The survivor is honesty work no design can carry —
    /// a recipe naming a film stock this build does not ship.
    private func caption(_ text: String, prominent: Bool = false) -> some View {
        DevelopNote(text, prominent: prominent)
    }

    /// Two pivots, ordered, inside the axis. A decoded file can carry anything.
    static func normalizedPivots(_ pivots: [Double]) -> [Double] {
        let defaults = GradingWheels.defaultPivots
        var a = pivots.count >= 1 && pivots[0].isFinite ? pivots[0] : defaults[0]
        var b = pivots.count >= 2 && pivots[1].isFinite ? pivots[1] : defaults[1]
        if b < a {
            let swapped = a
            a = b
            b = swapped
        }
        a = Num.saturate(a)
        b = Num.saturate(b)
        if b - a < ZoneWindows.minimumPivotGap {
            let centre = (a + b) / 2
            a = Num.saturate(centre - ZoneWindows.minimumPivotGap / 2)
            b = Num.saturate(centre + ZoneWindows.minimumPivotGap / 2)
        }
        return [a, b]
    }

    /// What puts the modified dot on the Colour Grading header. Broader than
    /// `GradingWheels.isNeutral`, which answers "would this change a pixel": moved
    /// pivots change no pixel on their own but are still an edit the user made and
    /// should be able to see and reset.
    static func isNeutral(_ wheels: GradingWheels) -> Bool {
        let list = [wheels.global, wheels.shadows, wheels.mid, wheels.high]
        let untouched = list.allSatisfy { $0.sat == 0 && $0.lum == 0 }
        return untouched && wheels.blending == 50 && wheels.balance == 0
            && wheels.colorBalance.isZero
            && normalizedPivots(wheels.pivots) == normalizedPivots(GradingWheels.defaultPivots)
    }
}

// MARK: - Zone strip

/// The grade's zone weights, drawn from the engine's own windows, with the two pivots
/// as handles. Lightroom has these zones too — it just never shows them, which is why
/// its shadow tint keeps landing somewhere the user did not ask for.
struct ZoneWeightStrip: View {
    let pivots: [Double]
    let blending: Double
    let balance: Double
    let onPivotChanged: (Int, Double) -> Void

    private static let height: CGFloat = 40

    /// Where the handle was when the drag began. Dragging by translation rather than by
    /// absolute location keeps the handle under the pointer without a coordinate space.
    @State private var dragOrigin: Double? = nil
    /// The gesture-in-flight signal every slider fires (docs/23 audit queue item 5).
    @Environment(\.sliderGestureChanged) private var sliderGestureChanged

    var body: some View {
        let pivotPair = pivots
        let softness = blending
        let shift = balance
        let windows = ZoneWindows(pivots: pivotPair, blending: softness, balance: shift)

        return ZStack(alignment: .topLeading) {
            Canvas { context, size in
                let solved = ZoneWindows(pivots: pivotPair, blending: softness, balance: shift)
                guard size.width > 0, size.height > 2 else { return }
                let usable = size.height - 2
                let steps = 72
                let shades: [Double] = [0.34, 0.52, 0.74]

                for zone in 0..<3 {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: size.height))
                    for step in 0...steps {
                        let x = Double(step) / Double(steps)
                        let w = solved.weights(atNormalized: x)
                        let v: Double = zone == 0 ? w.shadows : (zone == 1 ? w.mid : w.high)
                        path.addLine(to: CGPoint(x: size.width * CGFloat(x),
                                                 y: size.height - 1
                                                    - CGFloat(Num.saturate(v)) * usable))
                    }
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.closeSubpath()
                    context.fill(path, with: .color(Color(white: shades[zone]).opacity(0.45)))
                }
            }
            .background(Lumen.controlBackground)
            .clipShape(RoundedRectangle(cornerRadius: 3))

            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    handle(index: 0,
                           position: Num.saturate(windows.shadowPivot),
                           width: geometry.size.width,
                           height: geometry.size.height)
                    handle(index: 1,
                           position: Num.saturate(windows.highlightPivot),
                           width: geometry.size.width,
                           height: geometry.size.height)
                }
            }
        }
        .frame(height: ZoneWeightStrip.height)
        .padding(.vertical, 2)
    }

    private func handle(index: Int, position: Double,
                        width: CGFloat, height: CGFloat) -> some View {
        let x = CGFloat(position) * width
        return ZStack {
            Rectangle()
                .fill(Color.clear)
                .frame(width: 14, height: height)
            Capsule()
                .fill(Lumen.primaryText)
                .frame(width: 3, height: max(height - 4, 1))
                .shadow(radius: 1)
        }
        .contentShape(Rectangle())
        .position(x: x, y: height / 2)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    guard width > 0 else { return }
                    sliderGestureChanged(true)
                    let start = dragOrigin ?? position
                    if dragOrigin == nil { dragOrigin = start }
                    let moved = start + Double(drag.translation.width / width)
                    onPivotChanged(index, Num.saturate(moved))
                }
                .onEnded { _ in
                    dragOrigin = nil
                    sliderGestureChanged(false)
                }
        )
        .help(index == 0 ? "Shadow / midtone pivot" : "Midtone / highlight pivot")
    }
}

// MARK: - Printer light stepper

/// Points, not a slider: the value proposition is discrete, countable, communicable
/// steps you can ride from the keyboard while watching the picture.
struct PrinterLightRow: View {
    let title: String
    let points: Int
    let limit: Int
    let decrement: KeyEquivalent
    let increment: KeyEquivalent
    let modifiers: EventModifiers
    let onStep: (Int) -> Void
    let onReset: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.lumenBody)
                .foregroundStyle(points == 0 ? Lumen.secondaryText : Lumen.primaryText)
                .frame(width: Lumen.labelWidth, alignment: .leading)
                .lineLimit(1)
                .onTapGesture(count: 2) { onReset() }
                .help("\(title) — one point is one twelfth of a stop exactly, so "
                      + "twelve of them is a doubling. Double-click to reset.")

            stepper("minus.circle", enabled: points > -limit, key: decrement,
                    help: "One point down (1/12 stop)") { onStep(-1) }

            // `lumenNumeric` rather than the SF Mono this row used: tabular figures on
            // the same face as the label beside it, which is the only property the
            // second typeface was ever bought for (`LumenType`).
            Text(readout)
                .font(.lumenNumeric)
                .foregroundStyle(points == 0 ? Lumen.secondaryText : Lumen.primaryText)
                .frame(width: 124, alignment: .trailing)

            stepper("plus.circle", enabled: points < limit, key: increment,
                    help: "One point up (1/12 stop)") { onStep(1) }

            Spacer(minLength: 0)
        }
        .frame(height: Lumen.rowHeight)
    }

    /// ONE NUMBER, NOT TWO. This row printed the same value twice — `+0` in 11 pt and
    /// `+0.00 EV` in 10 pt — and a second type size does not make a second fact, it
    /// makes the same fact compete with itself in a 22-point row.
    ///
    /// EV is what the picture answers to, so EV is what is read. The point count rides
    /// in the same string at the same size rather than disappearing, because it is the
    /// unit the keyboard steps in and the one a photographer can say out loud and count
    /// their way back out of on the next frame.
    private var readout: String {
        let ev = String(format: "%+.2f EV", Double(points) / GradeEngine.pointsPerStop)
        return (points >= 0 ? "+" : "") + "\(points) pt · " + ev
    }

    /// ⊖ and ⊕, at a size a hand can hit.
    ///
    /// They were 12×12 pt glyphs with 32 points of nothing between them: the worst
    /// targets in the app, in a row that then spent 78 points on a trailing Spacer
    /// (docs/30 §2.3). This is 24 by the row's full height of hit area around the same
    /// 11 pt glyph, paid for out of that Spacer — the row looks as it did and stops
    /// being missed.
    private func stepper(_ symbol: String, enabled: Bool, key: KeyEquivalent,
                         help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 24, height: Lumen.rowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Lumen.primaryText : Lumen.secondaryText)
        .disabled(!enabled)
        .keyboardShortcut(key, modifiers: modifiers)
        .help(help)
    }
}

#endif
