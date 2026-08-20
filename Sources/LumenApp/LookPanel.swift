// LookPanel.swift
// The Look panel: grading wheels over VISIBLE zones, printer lights, primaries, the
// display transform and the Film Lab.
//
// This panel is deliberately not Develop. Everything in it is the portable layer (D4):
// one grade applies to eight hundred frames as a selection gesture, while each frame
// keeps its own white balance, exposure and denoise. The panel says that in a caption
// instead of assuming the user remembers which column they are in.
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

    @State private var wheelsExpanded: Bool = true
    /// Closed by default: the four wheels are the first-second surface, and the grid is
    /// for the second pass. It is a disclosure of the grade, not a second grading tool
    /// (D3) — which is why it lives inside `wheelsSection` rather than beside it.
    @State private var balanceExpanded: Bool = false
    @State private var printerExpanded: Bool = true
    @State private var primariesExpanded: Bool = false
    @State private var transformExpanded: Bool = true
    @State private var transformAdvanced: Bool = false
    @State private var filmExpanded: Bool = true

    /// The normalized tonal axis the pivots live on spans black anchor → white anchor,
    /// i.e. −9 EV … +5 EV (ZoneWindows' defaults). Balance is denominated in EV, so the
    /// handle geometry needs the span to convert.
    static let axisSpanEV: Double = 14.0

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                lookBanner
                wheelsSection
                Divider()
                printerLightsSection
                Divider()
                primariesSection
                Divider()
                transformSection
                Divider()
                filmLabSection
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 18)
        }
        .background(Lumen.panelBackground)
    }

    /// The one visual difference between this column and Develop: a tinted band with an
    /// accent rule down its edge, and one line of prose saying what that means.
    private var lookBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(Lumen.accent)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    LumenBadge(text: "LOOK", emphasized: true)
                    Text("travels with Copy Look")
                        .font(.system(size: 10))
                        .foregroundStyle(Lumen.secondaryText)
                }
                Text("Grade, printer lights, primaries, film stock and the display "
                     + "transform apply to every frame you paste them onto. Exposure, "
                     + "white balance and detail stay in Develop, per frame.")
                    .font(.system(size: 10))
                    .foregroundStyle(Lumen.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(Lumen.accent.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(.top, 8)
        .padding(.bottom, 4)
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
                               onReset: { state.updateRecipe { $0.look.wheels = GradingWheels() } })

            if wheelsExpanded {
                ZoneWeightStrip(pivots: pivots,
                                blending: wheels.blending,
                                balance: wheels.balance,
                                onPivotChanged: { index, position in
                                    movePivot(index, to: position)
                                })

                caption("Shadows, midtones and highlights, drawn. Drag a pivot to say "
                        + "where a zone starts — the wheels below grade exactly what "
                        + "the strip shows.")

                HStack(alignment: .top, spacing: 6) {
                    wheel("Shadows", path: \GradingWheels.shadows)
                    wheel("Midtones", path: \GradingWheels.mid)
                }
                HStack(alignment: .top, spacing: 6) {
                    wheel("Highlights", path: \GradingWheels.high)
                    wheel("Global", path: \GradingWheels.global)
                }

                LumenSlider(title: "Blending",
                            value: bindLook(\Look.wheels.blending, key: "wheels.blending"),
                            range: 0...100, defaultValue: 50, step: 1, decimals: 0,
                            bipolar: false)
                LumenSlider(title: "Balance",
                            value: bindLook(\Look.wheels.balance, key: "wheels.balance"),
                            range: -100...100, defaultValue: 0, step: 1, decimals: 0)

                caption("Blending widens the crossfades, Balance slides both pivots. "
                        + "Wheel tints are constant-luminance; the bar under each wheel "
                        + "is the zone's own lightness.")

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

                caption("Master moves, across the whole frame: the hue rotation holds "
                        + "lightness and chroma, and Vibrance spends itself on the "
                        + "colours that have least.")

                balanceAxis("Chroma", \Look.wheels.colorBalance.chroma, "cb.chroma")
                caption("Colourfulness at constant lightness and hue.")

                balanceAxis("Saturation", \Look.wheels.colorBalance.saturation,
                            "cb.saturation")
                caption("The colourfulness/lightness ratio, at constant H-K corrected "
                        + "brightness — the move that does not make a pushed blue read "
                        + "as if it dimmed.")

                balanceAxis("Brilliance", \Look.wheels.colorBalance.brilliance,
                            "cb.brilliance")
                if LookPanel.brillianceIsPushed(grid.brilliance) {
                    // A soft warning, not a clamp. darktable's own documentation calls
                    // past ±20 artifact territory, and the honest thing is to say so
                    // while still letting the slider go there.
                    Text("Brilliance past ±20 is artifact territory — highlights start "
                         + "to flatten and shadows to plug.")
                        .font(.system(size: 10))
                        .foregroundStyle(Lumen.accent)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 4)
                } else {
                    caption("H-K corrected brightness at constant ratio: exposure-like, "
                            + "perceptually scaled.")
                }

                caption("The grid grades the same three zones the strip above draws, "
                        + "measured on this stage's input — so opening this disclosure "
                        + "never moves the zones the wheels are already working in.")
            }
        }
    }

    /// One axis of the grid: Global on top, then the three zones, in the same order the
    /// wheels are laid out so the two halves of the panel read the same way.
    private func balanceAxis(_ title: String,
                             _ axis: WritableKeyPath<Look, ColorBalanceAxis>,
                             _ key: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Lumen.secondaryText)
                .padding(.top, 4)
            LumenSlider(title: "Global",
                        value: bindLook(axis.appending(path: \ColorBalanceAxis.global),
                                        key: key + ".global"),
                        range: -100...100, defaultValue: 0, step: 1, decimals: 0)
            LumenSlider(title: "Shadows",
                        value: bindLook(axis.appending(path: \ColorBalanceAxis.shadows),
                                        key: key + ".shadows"),
                        range: -100...100, defaultValue: 0, step: 1, decimals: 0)
            LumenSlider(title: "Midtones",
                        value: bindLook(axis.appending(path: \ColorBalanceAxis.mid),
                                        key: key + ".mid"),
                        range: -100...100, defaultValue: 0, step: 1, decimals: 0)
            LumenSlider(title: "Highlights",
                        value: bindLook(axis.appending(path: \ColorBalanceAxis.high),
                                        key: key + ".high"),
                        range: -100...100, defaultValue: 0, step: 1, decimals: 0)
        }
    }

    /// Whether any Brilliance field is far enough out to earn the warning line.
    static func brillianceIsPushed(_ axis: ColorBalanceAxis) -> Bool {
        let limit: Double = 20
        return abs(axis.global) > limit || abs(axis.shadows) > limit
            || abs(axis.mid) > limit || abs(axis.high) > limit
    }

    private func wheel(_ title: String, path: WritableKeyPath<GradingWheels, Wheel>) -> some View {
        LumenColorWheel(title: title,
                        hue: bindWheel(path, \Wheel.hue, key: "wheel.\(title).hue"),
                        sat: bindWheel(path, \Wheel.sat, key: "wheel.\(title).sat"),
                        lum: bindWheel(path, \Wheel.lum, key: "wheel.\(title).lum"))
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
                               onReset: { state.updateRecipe { $0.look.printerLights = PrinterLights() } })

            if printerExpanded {
                // `,` and `.` step the master; the same pair with ⌃ / ⌥ / ⇧ steps one
                // channel. The real interface here is the keyboard, watching the image.
                printerRow("Master", "master", lights.master, masterLimit, [])
                printerRow("Red / Cyan", "r", lights.r, trimLimit, .control)
                printerRow("Green / Mag", "g", lights.g, trimLimit, .option)
                printerRow("Blue / Yellow", "b", lights.b, trimLimit, .shift)

                caption("One point is one twelfth of a stop, exactly — twelve points is "
                        + "2×, with no hidden negative gamma. \u{201C}+3R, −2 master\u{201D} "
                        + "is a fact you can say out loud, repeat on the next frame and "
                        + "count your way back out of.")
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
                               onReset: { state.updateRecipe { $0.look.primaries = Primaries() } })

            if primariesExpanded {
                bipolarSlider("Red Hue", \Look.primaries.rHue, "prim.rHue")
                bipolarSlider("Red Purity", \Look.primaries.rPurity, "prim.rPurity")
                bipolarSlider("Green Hue", \Look.primaries.gHue, "prim.gHue")
                bipolarSlider("Green Purity", \Look.primaries.gPurity, "prim.gPurity")
                bipolarSlider("Blue Hue", \Look.primaries.bHue, "prim.bHue")
                bipolarSlider("Blue Purity", \Look.primaries.bPurity, "prim.bPurity")
                bipolarSlider("Shadow Tint", \Look.primaries.tintHue, "prim.tintHue")
                bipolarSlider("Tint Purity", \Look.primaries.tintPurity, "prim.tintPurity")

                caption("Redefines what red, green and blue mean for this image. The "
                        + "mixer targets pixels that look blue; a primary moves every "
                        + "pixel containing blue — global, smooth, and unable to "
                        + "posterize. Greys are preserved by construction.")
            }
        }
    }

    // MARK: - Display transform

    private var transformSection: some View {
        let render = state.currentRecipe.look.render
        let base = DisplayTransformParams.preset(named: render.preset)
        let overridden = render.contrast != nil || render.skew != nil
            || render.huePreservation != nil || render.blackTarget != nil

        return VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Display Transform",
                               isExpanded: $transformExpanded,
                               isModified: render != RenderParams(),
                               onReset: { state.updateRecipe { $0.look.render = RenderParams() } })

            if transformExpanded {
                pickerRow("Preset") {
                    Picker("", selection: presetBinding) {
                        ForEach(DisplayTransformParams.presetNames, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                }

                LumenSectionHeader(title: "Transform detail",
                                   isExpanded: $transformAdvanced,
                                   isModified: overridden,
                                   onReset: { clearTransformOverrides() })

                if transformAdvanced {
                    LumenSlider(title: "Contrast",
                                value: renderBinding("render.contrast",
                                                     get: { $0.contrast },
                                                     fallback: base.contrast,
                                                     set: { $0.contrast = $1 }),
                                range: 0.1...10, defaultValue: base.contrast,
                                step: 0.05, decimals: 2, bipolar: false,
                                onReset: { clearTransformOverride(\.contrast) })
                    LumenSlider(title: "Skew",
                                value: renderBinding("render.skew",
                                                     get: { $0.skew },
                                                     fallback: base.skew,
                                                     set: { $0.skew = $1 }),
                                range: -1...1, defaultValue: base.skew,
                                step: 0.01, decimals: 2,
                                onReset: { clearTransformOverride(\.skew) })
                    LumenSlider(title: "Hue keep",
                                value: renderBinding("render.hue",
                                                     get: { $0.huePreservation },
                                                     fallback: base.huePreservation,
                                                     set: { $0.huePreservation = $1 }),
                                range: 0...100, defaultValue: base.huePreservation,
                                step: 1, decimals: 0, bipolar: false,
                                onReset: { clearTransformOverride(\.huePreservation) })
                    LumenSlider(title: "Black target",
                                value: renderBinding("render.black",
                                                     get: { $0.blackTarget },
                                                     fallback: base.blackTarget,
                                                     set: { $0.blackTarget = $1 }),
                                range: 0...15, defaultValue: base.blackTarget,
                                step: 0.01, decimals: 2, bipolar: false,
                                onReset: { clearTransformOverride(\.blackTarget) })

                    caption("Untouched, these follow the preset — so a retuned preset "
                            + "reaches every recipe that only said its name. Move one "
                            + "and it pins itself to this image forever.")
                }
            }
        }
    }

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
    /// following a retuned preset, which is the exact behaviour the caption below the
    /// group promises you get by NOT touching it.
    private func clearTransformOverride(
        _ field: WritableKeyPath<RenderParams, Double?>) {
        state.updateRecipe { recipe in
            recipe.look.render[keyPath: field] = nil
        }
    }

    private func clearTransformOverrides() {
        state.updateRecipe { recipe in
            recipe.look.render.contrast = nil
            recipe.look.render.skew = nil
            recipe.look.render.huePreservation = nil
            recipe.look.render.blackTarget = nil
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

    private var filmLabSection: some View {
        let film = state.currentRecipe.look.filmLab
        let stock = film.flatMap { FilmStock.named($0.stock) }

        return VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Film Lab",
                               isExpanded: $filmExpanded,
                               isModified: film != nil,
                               onReset: { state.updateRecipe { $0.look.filmLab = nil } })

            if filmExpanded {
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

                    pickerRow("Print size") {
                        Picker("", selection: printSizeBinding) {
                            Text("Long edge").tag("")
                            ForEach(LookPanel.printSizes, id: \.self) { size in
                                Text(size + "″").tag(size)
                            }
                        }
                    }

                    if let stock {
                        caption(LookPanel.stockCaption(stock))
                    } else {
                        caption("\u{201C}\(film.stock)\u{201D} is not a stock this build "
                                + "ships — the render falls back to the neutral "
                                + "transform rather than to a different look.")
                    }
                } else {
                    caption("A stock replaces the display transform rather than stacking "
                            + "on top of it — one picture-formation stage, parameterized. "
                            + "Exposure moves stay film-like because the curve lives in "
                            + "log-exposure.")
                }
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

    private var printSizeBinding: Binding<String> {
        Binding(
            get: { state.currentRecipe.look.filmLab?.printSize ?? "" },
            set: { size in
                state.updateRecipe { recipe in
                    guard var film = recipe.look.filmLab else { return }
                    film.printSize = size.isEmpty ? nil : size
                    recipe.look.filmLab = film
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
    private func bipolarSlider(_ title: String,
                               _ path: WritableKeyPath<Look, Double>,
                               _ key: String) -> some View {
        LumenSlider(title: title, value: bindLook(path, key: key),
                    range: -100...100, defaultValue: 0, step: 1, decimals: 0)
    }

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

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(Lumen.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 4)
    }

    static let printSizes: [String] = ["5x7", "8x10", "11x14", "16x20", "20x30"]

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

    /// No `film` parameter any more: the only thing it carried was the print
    /// size, and the caption stopped naming that when it turned out the print
    /// size cannot change the picture.
    static func stockCaption(_ stock: FilmStock) -> String {
        var text = stock.name
        if let print = stock.printName {
            text += " → " + print
        } else {
            text += " (transparency)"
        }
        // What is true: the grain's pixel footprint follows the GATE and the render's
        // pixel count. The print size cancels out of the enlargement and the print's
        // pixel density, which is the anchoring working correctly — but the caption
        // used to name the chosen size as though changing it changed the picture, and
        // it cannot. Saying so is better than a number that updates and does nothing.
        text += String(format: ". Grain follows the %.1f mm gate and the render size; "
                           + "the print size cancels out.", stock.gateLongEdgeMM)
        return text
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
                    let start = dragOrigin ?? position
                    if dragOrigin == nil { dragOrigin = start }
                    let moved = start + Double(drag.translation.width / width)
                    onPivotChanged(index, Num.saturate(moved))
                }
                .onEnded { _ in dragOrigin = nil }
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
                .font(.system(size: 11))
                .foregroundStyle(points == 0 ? Lumen.secondaryText : Lumen.primaryText)
                .frame(width: Lumen.labelWidth, alignment: .leading)
                .lineLimit(1)
                .onTapGesture(count: 2) { onReset() }
                .help("\(title) — double-click to reset")

            Button {
                onStep(-1)
            } label: {
                Image(systemName: "minus.circle").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(points <= -limit ? Lumen.secondaryText : Lumen.primaryText)
            .disabled(points <= -limit)
            .keyboardShortcut(decrement, modifiers: modifiers)
            .help("One point down (1/12 stop)")

            Text(String(format: "%+d", points))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(points == 0 ? Lumen.secondaryText : Lumen.primaryText)
                .frame(width: 32, alignment: .trailing)

            Button {
                onStep(1)
            } label: {
                Image(systemName: "plus.circle").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(points >= limit ? Lumen.secondaryText : Lumen.primaryText)
            .disabled(points >= limit)
            .keyboardShortcut(increment, modifiers: modifiers)
            .help("One point up (1/12 stop)")

            Text(String(format: "%+.2f EV", Double(points) / GradeEngine.pointsPerStop))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Lumen.secondaryText)

            Spacer(minLength: 0)
        }
        .frame(height: Lumen.rowHeight)
    }
}

#endif
