// CurveEditorView.swift
// The tone curve editor (D10, docs/04 §7): one square graph, six curves behind a
// selector, and the luminance histogram of the frame underneath so the curve is placed
// against the picture rather than against a memory of it.
//
// Three rules this file exists to enforce:
//   · The graph is the model, not a picture of it. The curve drawn is
//     `CurveStack.master(_:)` / `lumaCurve(_:)` / `channelCurve(_:channel:)` — the same
//     evaluation the pipeline bakes into its LUT — so the editor cannot drift from the
//     render.
//   · Every edit lands through `AppState.updateRecipe(coalescingKey:)`, keyed by the
//     curve AND THE POINT being edited, so dragging one control point is one undo step
//     and moving a second one is a second step.
//   · NONE OF THE EDITING ARITHMETIC LIVES HERE. Which point a press took hold of,
//     where that point may go, whether it may be deleted, and what the readout says
//     are all `CurveEditing` in LumenCore, because this file is inside
//     `#if os(macOS)` and nothing under that flag can be tested. What is left below is
//     drawing and gestures — the two things a test could not check anyway.
//
// Parametric mode swaps the control points for the four region sliders and the three
// movable splits, because those are what a parametric curve actually is: bounded
// crossfades over four regions whose boundaries the user places (docs/04 §7.1).

#if os(macOS)

import AppKit
import CoreGraphics
import Foundation
import LumenCore
import SwiftUI

// MARK: - Plot point

// A control point is `[x, y]` and a curve is `[[Double]]`, which is the wire form and
// the form `CurveEditing` states every rule in. There WAS a `CurvePoint` struct here,
// wrapping the same two numbers, and every gesture converted into it and back out of it
// on the way to the recipe — two conversions per mouse event whose only product was a
// second definition of "sanitized" living where no test could reach it.

/// One parametric region, as the graph draws it: the span the splits mark out for it,
/// the slider that owns it, and how far along the axis that slider actually reaches.
///
/// `reach` is `weight × envelope` — the exact product `CurveStack.bakeParametric`
/// multiplies the slider by — normalized to its own peak so it can be drawn at full
/// height. Drawing it is the point: it swells at the region's centre and falls to
/// nothing at both ends of the axis, which is the picture of why four sliders named
/// after tones cannot move black or white however hard they are pushed.
private struct ParametricRegion {
    let title: String
    let lower: Double
    let upper: Double
    let reach: [Double]
}

// MARK: - Curve editor

struct CurveEditorView: View {

    @EnvironmentObject var state: AppState
    /// This surface shows the edit, so it observes the edit signal —
    /// `AppState.recipes` is deliberately not published (see `EditRevision`).
    @EnvironmentObject var edits: EditRevision

    /// Which curve this editor edits.
    ///
    /// The mask case is why this exists: a mask's point curve is the same tool on the
    /// same axis (docs/08 §8.4 — one of the two things Lightroom still has no local
    /// answer for), and giving the mask panel a second, simpler curve widget would be
    /// two editors that could disagree about what the pipeline applies.
    enum Target: Equatable, Hashable {
        case global
        case mask(String)      // the mask's id
    }

    /// The frame's histogram, drawn under the curve. Still optional — nothing may have
    /// been rendered yet, and nil simply draws no backdrop — but NO LONGER DEFAULTED.
    private let histogram: Histogram?
    private let target: Target

    /// `histogram` HAS NO DEFAULT, and its removal is a bug fix rather than a tidy-up.
    ///
    /// It was `histogram: Histogram? = nil`, and the mask panel's call site omitted the
    /// argument entirely — so for months a mask's tone curve was drawn over an empty
    /// square while the develop column's was drawn over the picture's own distribution.
    /// Nothing announced it: the failure of an optional backdrop is a backdrop that is
    /// simply not there, which looks exactly like a curve editor that never had one.
    /// Seeing which tones the hand is moving is the entire reason a graph has a histogram
    /// behind it, and the default is what made losing it silent.
    ///
    /// Required, the same omission is a compile error at every call site — including the
    /// next surface that mounts this editor, which is the one this change is really for.
    /// `nil` is still a legitimate thing to pass (nothing rendered yet); what is no longer
    /// possible is passing it by accident.
    init(histogram: Histogram?, target: Target = .global) {
        self.histogram = histogram
        self.target = target
    }

    /// The six curves, in the order the panel shows them.
    enum CurveChannel: String, CaseIterable, Hashable {
        case parametric
        case point
        case red
        case green
        case blue
        case luma

        var shortLabel: String {
            switch self {
            case .parametric: return "Param"
            case .point: return "Point"
            case .red: return "R"
            case .green: return "G"
            case .blue: return "B"
            case .luma: return "Luma"
            }
        }

        var displayName: String {
            switch self {
            case .parametric: return "Parametric"
            case .point: return "Point curve"
            case .red: return "Red channel"
            case .green: return "Green channel"
            case .blue: return "Blue channel"
            case .luma: return "Luma curve"
            }
        }

        var tint: Color {
            switch self {
            case .red: return Color(red: 0.90, green: 0.28, blue: 0.28)
            case .green: return Color(red: 0.30, green: 0.82, blue: 0.36)
            case .blue: return Color(red: 0.40, green: 0.58, blue: 0.95)
            default: return Lumen.primaryText
            }
        }
    }

    @State private var channel: CurveChannel = .parametric
    @State private var dragPointIndex: Int? = nil
    @State private var dragSplitIndex: Int? = nil
    @State private var dragBegan: Bool = false
    /// The gesture-in-flight signal every slider fires (docs/23 audit queue item 5):
    /// a curve-point drag writes the recipe per event and paid per-event persistence.
    @Environment(\.sliderGestureChanged) private var sliderGestureChanged
    /// Set when the press was an ⌥-click delete: the rest of that drag does nothing.
    @State private var dragConsumed: Bool = false
    @State private var hoverLocation: CGPoint? = nil
    @State private var plotSize: CGSize = CGSize(width: 1, height: 1)
    /// Which region slider the pointer is on, and which one a drag is holding.
    ///
    /// Two states rather than one because they end at different moments: the pointer
    /// leaves the row long before the hand lets go of a slider it is still dragging,
    /// and the band must not go dark underneath a value that is still moving.
    @State private var hoverRegion: Int? = nil
    @State private var dragRegion: Int? = nil
    /// Where inside the handle the press landed, so a grabbed split does not jump to sit
    /// under the pointer the instant it is taken hold of. A press is only ever within
    /// `hitRadius` of the split, so the jump is small — but it is the same jump
    /// `nearestSplitIndex` had to stop making at full plot width, and eight points of it
    /// is no more wanted than three hundred.
    @State private var splitGrabOffset: CGFloat = 0

    private static let sampleCount: Int = 128
    /// The press radius, in the plot's own points. The drawn dot is radius 3, so the
    /// target is more than twice the ink — stated apart on purpose, and converted to
    /// `CurveEditing`'s fractions at the one place that knows the plot's size.
    private static let hitRadius: CGFloat = 8
    /// Deep enough for a 10-point triangle to sit under the plot without touching it.
    private static let railHeight: CGFloat = 12
    /// The four regions in the order the maths reads them — dark to light, which is
    /// `[shadows, darks, lights, highlights]` in `CurveStack.bakeParametric`. The
    /// sliders are listed light to dark, as every tone panel in the field lists them,
    /// so the two orders are deliberately opposite and each site says which it is on.
    private static let regionTitles: [String] = ["Shadows", "Darks", "Lights", "Highlights"]
    private static let reachSamples: Int = 96
    /// `.lumenCaption`'s own size, held as a number because the width measurement below
    /// needs an `NSFont` and a SwiftUI `Font` cannot be asked for its point size.
    ///
    /// It was 9 — under the app's own stated floor ("10 is the floor", LumenType.swift),
    /// and invisible to the ratchet that enforces it because the floor is checked as the
    /// literal `.system(size: 9`, which a named constant is not.
    private static let regionLabelSize: CGFloat = 10
    /// Measured once, and off the same face `.lumenCaption` resolves to. A `Canvas`
    /// redraws on every mouse move over the plot, and text metrics do not change
    /// between frames.
    private static let regionLabelWidths: [CGFloat] = regionTitles.map {
        NSAttributedString(
            string: $0,
            attributes: [.font: NSFont.systemFont(ofSize: regionLabelSize)]).size().width
    }

    private var recipe: Recipe { state.currentRecipe }

    // MARK: The curve this editor is pointed at

    /// The stored curve, or an untouched one. A mask stores `nil` until it is edited,
    /// so that a mask with no curve costs the render nothing — `LocalCurve` reports
    /// identity on nil and the second tap is skipped entirely.
    private var curveSet: CurveSet { CurveEditorView.curveSet(in: recipe, target: target) }

    static func curveSet(in recipe: Recipe, target: Target) -> CurveSet {
        switch target {
        case .global:
            return recipe.develop.curve
        case .mask(let id):
            return recipe.masks.first(where: { $0.id == id })?.adjust.curve ?? CurveSet()
        }
    }

    /// Write a curve edit back, one undo step per coalescing key.
    ///
    /// A mask curve returned to its default is stored as nil rather than as a
    /// default-valued `CurveSet`: the difference is invisible in the render — the
    /// second tap skips an identity curve — and visible in the panel, where
    /// "modified" has to mean modified.
    private func editCurve(_ key: String, _ body: @escaping (inout CurveSet) -> Void) {
        CurveEditorView.edit(state, target: target, key: key, body)
    }

    static func edit(_ state: AppState, target: Target, key: String,
                     _ body: @escaping (inout CurveSet) -> Void) {
        state.updateRecipe(coalescingKey: key) { document in
            switch target {
            case .global:
                body(&document.develop.curve)
            case .mask(let id):
                guard let index = document.masks.firstIndex(where: { $0.id == id })
                else { return }
                var set = document.masks[index].adjust.curve ?? CurveSet()
                body(&set)
                document.masks[index].adjust.curve = (set == CurveSet()) ? nil : set
            }
        }
    }

    private func curveValue(_ path: WritableKeyPath<CurveSet, Double>,
                            _ key: String) -> Binding<Double> {
        let state: AppState = self.state
        let target: Target = self.target
        return Binding(
            get: { CurveEditorView.curveSet(in: state.currentRecipe,
                                            target: target)[keyPath: path] },
            set: { v in
                CurveEditorView.edit(state, target: target, key: key) {
                    $0[keyPath: path] = v
                }
            })
    }

    private func curveFlag(_ path: WritableKeyPath<CurveSet, Bool>,
                           _ key: String) -> Binding<Bool> {
        let state: AppState = self.state
        let target: Target = self.target
        return Binding(
            get: { CurveEditorView.curveSet(in: state.currentRecipe,
                                            target: target)[keyPath: path] },
            set: { v in
                CurveEditorView.edit(state, target: target, key: key) {
                    $0[keyPath: path] = v
                }
            })
    }

    /// Distinct undo keys per target, so dragging a mask's curve cannot coalesce with
    /// a drag of the global one.
    private var keyPrefix: String {
        switch target {
        case .global: return "curve."
        case .mask(let id): return "mask.curve.\(id)."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LumenSegmented(options: channelOptions, selection: $channel)
                .help("Which curve to edit: the four parametric region sliders, the "
                      + "master point curve, one RGB channel, or luma alone. Param "
                      + "and Point draw the same master trace, because the render "
                      + "applies them composed.")
            // The rail belongs to the plot's bottom edge, not to the column's rhythm,
            // so it is spaced against the graph rather than against the readout.
            VStack(spacing: 2) {
                plot
                if channel == .parametric { splitRail }
            }
            readoutLine
            if channel == .parametric {
                parametricControls
            } else {
                pointControls
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Lumen.panelBackground)
        .foregroundStyle(Lumen.primaryText)
    }

    private var channelOptions: [(value: CurveChannel, label: String)] {
        CurveChannel.allCases.map { (value: $0, label: $0.shortLabel) }
    }

    // MARK: The graph

    private var plot: some View {
        GeometryReader { geometry in
            let size: CGSize = geometry.size
            let backdrop: [Double] = histogram?.normalized(.luma) ?? []
            let samples: [Double] = curveSamples
            let controls: [[Double]] = channel == .parametric ? [] : currentPoints
            let regions: [ParametricRegion] = channel == .parametric
                ? CurveEditorView.regions(splits: currentSplits) : []
            let highlight: Int? = channel == .parametric ? highlightRegion : nil
            let tint: Color = channel.tint

            ZStack {
                Canvas { context, canvasSize in
                    CurveEditorView.draw(context: &context, size: canvasSize,
                                         backdrop: backdrop, samples: samples,
                                         controls: controls, regions: regions,
                                         highlight: highlight, tint: tint)
                }
            }
            .contentShape(Rectangle())
            .gesture(plotGesture(size: size))
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point): hoverLocation = point
                case .ended: hoverLocation = nil
                }
            }
            .onAppear { plotSize = size }
            .onChange(of: size) { _, newValue in plotSize = newValue }
            .contextMenu { contextItems }
        }
        .background(Color.black.opacity(0.55))
        // THE SMALLEST RADIUS IN THE SCALE, and the only surface in the app that argues
        // for one. A tone curve's identity line runs corner to corner and its two control
        // points LIVE at the corners, so every point of radius here clips data rather
        // than chrome — a card radius of 14 would round the black point and the white
        // point off the graph. Six is enough to stop it reading as a square hole beside
        // the section card it sits in, and little enough that the endpoints survive.
        .clipShape(RoundedRectangle(cornerRadius: Lumen.radiusChip, style: .continuous))
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .help(plotHelp)
    }

    /// What the graph does under the pointer — at the pointer, which is where the hand
    /// already is when the question gets asked.
    ///
    /// Both of these were `DevelopNote` paragraphs under the sliders. A non-prominent
    /// note draws nothing now (docs/30 §2.2), so they were strings built on every body
    /// pass for no reader at all; this is the only half of that change that was still
    /// missing.
    private var plotHelp: String {
        if channel == .parametric {
            return "Each shaded band belongs to one of the four sliders below, and the "
                + "triangles under the graph set where the bands meet. The regions "
                + "crossfade rather than cut, and every setting is solved to keep the "
                + "curve's slope above a floor — so these four cannot posterize, invert, "
                + "or move black or white."
        }
        return "Click to add a point, drag to move it, ⌥-click or right-click to delete "
            + "it. Dragging a point out of the graph deletes it."
    }

    /// The three splits, on a rail of their own under the plot.
    ///
    /// They shipped as 8×8 squares on the plot's bottom edge — inside the same rectangle
    /// where a Point-tab click adds a control point, with no rail and no separation — so
    /// the one control that says "these four regions are yours to place" read as trim on
    /// the graph's border. docs/04 §7.1 has always specified triangles; a rail is what
    /// makes them look like something to take hold of.
    private var splitRail: some View {
        GeometryReader { geometry in
            let size: CGSize = geometry.size
            let splits: [Double] = currentSplits
            let active: Int? = dragSplitIndex

            Canvas { context, canvasSize in
                CurveEditorView.drawSplitRail(context: &context, size: canvasSize,
                                              splits: splits, active: active)
            }
            .contentShape(Rectangle())
            .gesture(railGesture(size: size))
        }
        .frame(height: CurveEditorView.railHeight)
        .help("Drag a triangle to move the boundary between two regions. Double-click "
              + "one to put it back where it started.")
    }

    @ViewBuilder
    private var contextItems: some View {
        if channel != .parametric {
            // Disabled over an ANCHOR as well as over empty graph. The item used to
            // be enabled wherever a point was under the pointer, and the two ends are
            // not deletable — so a right-click on the black point offered Delete Point
            // and then did nothing, which is the one failure mode worse than the menu
            // item not being there.
            Button("Delete Point") { deleteNearestPoint() }
                .disabled(!hoveredPointIsDeletable)
            Button("Flatten \(channel.displayName)") { flattenCurrentCurve() }
        } else {
            Button("Reset Splits") { writeSplits(CurveEditing.defaultSplits) }
            Button("Reset Regions") { resetParametricRegions() }
        }
    }

    // MARK: Readout

    private var readoutLine: some View {
        HStack(spacing: 6) {
            Text(readoutText)
                .font(.lumenCaptionNumeric)
                .foregroundStyle(Lumen.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 4)
            if channel != .parametric {
                Text("\(currentPoints.count) pts")
                    .font(.lumenCaption)
                    .foregroundStyle(Lumen.secondaryText)
                    .lineLimit(1)
            }
            resetButton
        }
        .frame(height: 14)
    }

    /// THE WAY BACK, ON THE SURFACE.
    ///
    /// Flatten and Reset Splits existed only in the plot's context menu, so the answer to
    /// "put it back" was a right-click on a graph whose left-click adds a point — an
    /// affordance nothing announces, in an editor where the ways to make an unwanted
    /// change are a single click and a single drag. Every other section in the column
    /// carries its reset in its header; this one is inside a section it does not own, so
    /// it carries its own, on the row that is already about the curve's state.
    ///
    /// Disabled at the default rather than hidden: a control that appears when you are
    /// least expecting it moves the row it is in, and this row holds a number the hand is
    /// reading while it drags.
    private var resetButton: some View {
        // Branched into a local rather than written as a multi-line ternary in the
        // argument list, which is this repository's ground rule for the one shape
        // `check-swift-surface.py` is known to mis-read (docs/32 ground rule 4).
        let hint: String
        if channel == .parametric {
            hint = "Put the four region sliders and the three splits back to their "
                + "defaults."
        } else {
            hint = "Flatten \(channel.displayName) — every point of this curve goes, "
                + "and the other five curves are untouched."
        }
        return Button(action: resetCurrentCurve) {
            Image(systemName: "arrow.uturn.backward")
                .font(.lumenGlyphCaption)
                // The glyph's own bounds are no hit target — the same measurement the
                // printer rows and this panel's eyedroppers were fixed by.
                .frame(width: 20, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(canReset ? Lumen.primaryText : Lumen.secondaryText)
        .disabled(!canReset)
        .lumenClickCursor()
        .help(hint)
    }

    /// Whether there is anything to go back FROM, asked of the curve on screen.
    private var canReset: Bool {
        if channel == .parametric { return curveSet.parametric != ParametricCurve() }
        return !CurveEditing.isIdentity(currentPoints)
    }

    private func resetCurrentCurve() {
        if channel == .parametric {
            resetParametricRegions()
        } else {
            flattenCurrentCurve()
        }
    }

    /// In/out in percent of the encoded axis — the coordinate display docs/04 §7.1 asks
    /// for. The absolute 0–255 form belongs to the histogram's readout-space picker and
    /// arrives with it.
    ///
    /// THE POINT BEING DRAGGED WINS, which is the half that was missing: the readout
    /// tracked `hoverLocation` alone, and a hover is not what a hand is doing while it
    /// holds a control point. What it reported during a drag was the curve's value under
    /// the pointer — close to the point's own coordinates, equal to them only when the
    /// drag happened to be dead on the trace, and undefined the moment the pointer left
    /// the plot. So the one number a photographer places a point BY was never actually
    /// shown while the point was being placed.
    private var readoutText: String {
        if channel != .parametric, let index = dragPointIndex {
            let points: [[Double]] = currentPoints
            if points.indices.contains(index), points[index].count >= 2 {
                return CurveEditing.readout(input: points[index][0] * 100,
                                            output: points[index][1] * 100)
            }
        }
        if channel == .parametric, let index = dragSplitIndex {
            let splits: [Double] = currentSplits
            if splits.indices.contains(index) {
                return CurveEditing.splitReadout(index: index, position: splits[index])
            }
        }
        guard let location = hoverLocation, plotSize.width > 1, plotSize.height > 1 else {
            return channel.displayName
        }
        let x: Double = CurveEditing.clamp01(Double(location.x / plotSize.width))
        return CurveEditing.readout(input: x * 100,
                                    output: CurveEditing.clamp01(evaluate(x)) * 100)
    }

    // MARK: Parametric controls

    private var parametricControls: some View {
        // Light to dark, which is the opposite of the region indices — see
        // `regionTitles`. The order of the rows is not being changed to match it: every
        // tone panel in the field puts highlights at the top, and the whole point of the
        // shading is that a row no longer has to be read positionally at all.
        VStack(alignment: .leading, spacing: 2) {
            parametricSlider("Highlights", region: 3, \.parametric.highlights,
                             "parametric.highlights",
                             help: "Raises or lowers the lightest of the four bands on "
                                 + "the graph, above the third split. Both ends of the "
                                 + "curve are pinned, so this cannot move white itself.")
            parametricSlider("Lights", region: 2, \.parametric.lights,
                             "parametric.lights",
                             help: "Raises or lowers the band between the second and "
                                 + "third splits.")
            parametricSlider("Darks", region: 1, \.parametric.darks,
                             "parametric.darks",
                             help: "Raises or lowers the band between the first and "
                                 + "second splits.")
            parametricSlider("Shadows", region: 0, \.parametric.shadows,
                             "parametric.shadows",
                             help: "Raises or lowers the darkest of the four bands, "
                                 + "below the first split. Both ends of the curve are "
                                 + "pinned, so this cannot move black itself.")
        }
    }

    /// One region slider, wired to its own band on the graph.
    ///
    /// The band lighting up under the pointer is the whole explanation of this control.
    /// Four numbers named after tones say nothing about WHERE on the axis they act, and
    /// the three handles that decide it are anonymous; a tooltip can describe that and a
    /// highlight can show it. This is what makes the parametric curve teachable in
    /// Lightroom, and it is the same reasoning that moved the panels' prose onto
    /// `help:`, one step further along.
    private func parametricSlider(_ title: String, region: Int,
                                  _ path: WritableKeyPath<CurveSet, Double>,
                                  _ key: String, help: String) -> some View {
        LumenSlider(title: title,
                    value: curveValue(path, keyPrefix + key),
                    range: -100...100, hardRange: nil, defaultValue: 0,
                    step: 1, decimals: 0,
                    help: help,
                    onEditingChanged: { editing in dragRegion = editing ? region : nil })
            .onHover { inside in
                if inside {
                    hoverRegion = region
                } else if hoverRegion == region {
                    // Guarded: the pointer entering the next row fires that row's
                    // enter before this row's exit, and an unguarded clear would blank
                    // the band the pointer has just arrived on.
                    hoverRegion = nil
                }
            }
    }

    /// A drag outlives the hover that started it — the pointer leaves the row long
    /// before the hand lets go — so the drag wins.
    private var highlightRegion: Int? { dragRegion ?? hoverRegion }

    private var pointControls: some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenToggleRow(title: "Preserve Luminance",
                           isOn: curveFlag(\.preserveLuminance,
                                           keyPrefix + "preserveLuminance"),
                           help: "Curve the luminance and carry the chroma ratios, so a "
                               + "contrast curve is not also a saturation boost (D10).")
        }
    }

    // MARK: Curve evaluation

    private var stack: CurveStack { CurveStack(curveSet) }

    /// The one evaluation the graph draws, matched to the selected curve. Parametric
    /// and Point both show the master curve, because the master *is* the parametric
    /// composed with the points — showing one without the other would be a lie about
    /// what the pipeline applies.
    private func evaluate(_ x: Double) -> Double {
        let curve: CurveStack = stack
        switch channel {
        case .parametric, .point: return curve.master(x)
        case .red: return curve.channelCurve(x, channel: 0)
        case .green: return curve.channelCurve(x, channel: 1)
        case .blue: return curve.channelCurve(x, channel: 2)
        case .luma: return curve.lumaCurve(x)
        }
    }

    private var curveSamples: [Double] {
        let curve: CurveStack = stack
        let n: Int = Swift.max(2, CurveEditorView.sampleCount)
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let x: Double = Double(i) / Double(n - 1)
            let y: Double
            switch channel {
            case .parametric, .point: y = curve.master(x)
            case .red: y = curve.channelCurve(x, channel: 0)
            case .green: y = curve.channelCurve(x, channel: 1)
            case .blue: y = curve.channelCurve(x, channel: 2)
            case .luma: y = curve.lumaCurve(x)
            }
            out[i] = CurveEditing.clamp01(y)
        }
        return out
    }

    // MARK: Recipe access

    /// Which of the five point curves the selector is on, as a key path INTO the curve
    /// set rather than into the recipe — the same editor now serves the global curve
    /// and any mask's, and only `curveSet`/`editCurve` know which.
    private var pointsKeyPath: WritableKeyPath<CurveSet, [[Double]]?>? {
        switch channel {
        case .parametric: return nil
        case .point: return \CurveSet.point
        case .red: return \CurveSet.r
        case .green: return \CurveSet.g
        case .blue: return \CurveSet.b
        case .luma: return \CurveSet.luma
        }
    }

    private var currentPoints: [[Double]] {
        guard let keyPath = pointsKeyPath else { return [] }
        return CurveEditing.sanitized(curveSet[keyPath: keyPath])
    }

    /// Write a point list back under one coalescing key.
    ///
    /// An identity curve is stored as nil so it costs the render nothing — the same rule
    /// `editCurve` applies one level up for a mask's whole `CurveSet`.
    private func commitPoints(_ points: [[Double]], key: String) {
        guard let keyPath = pointsKeyPath, points.count >= 2 else { return }
        let identity: Bool = CurveEditing.isIdentity(points)
        editCurve(key) { set in
            set[keyPath: keyPath] = identity ? nil : points
        }
    }

    /// The key ONE POINT's drag records under (K-038).
    ///
    /// It used to be `curve.<channel>` for every point of a curve, and
    /// `HistoryCoalescing` folds two edits sharing a key, a photo set and a 1.2 s window
    /// into one step — so placing a point and then moving a different one, two decisions
    /// seconds apart, was a single undo entry and ⌘Z took both away. A drag holds one
    /// index for its whole life, so one drag is still one step; that is what makes the
    /// index the right identity here rather than the channel.
    private func pointKey(_ index: Int) -> String {
        CurveEditing.pointCoalescingKey(prefix: keyPrefix, channel: channel.rawValue,
                                        index: index)
    }

    private func flattenCurrentCurve() {
        guard let keyPath = pointsKeyPath else { return }
        editCurve(keyPrefix + "flatten." + channel.rawValue) { set in
            set[keyPath: keyPath] = nil
        }
    }

    private var currentSplits: [Double] {
        CurveEditing.sanitizedSplits(curveSet.parametric.splits)
    }

    private func writeSplits(_ splits: [Double]) {
        let clean: [Double] = CurveEditing.sanitizedSplits(splits)
        editCurve(keyPrefix + "parametric.splits") { $0.parametric.splits = clean }
    }

    private func resetParametricRegions() {
        editCurve(keyPrefix + "parametric.reset") { $0.parametric = ParametricCurve() }
    }

    // MARK: Gesture

    private func plotGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                sliderGestureChanged(true)
                if !dragBegan {
                    dragBegan = true
                    beginDrag(at: value.startLocation, size: size)
                }
                guard !dragConsumed else { return }
                updateDrag(to: value.location, size: size)
            }
            .onEnded { value in
                if !dragConsumed { endDrag(at: value.location, size: size) }
                finishDrag()
            }
    }

    /// The rail's own gesture, sharing the plot's drag state because one mouse cannot
    /// be in both at once — and because the split being dragged has to be the same fact
    /// on both surfaces, which is what draws the lit triangle.
    private func railGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !dragBegan {
                    dragBegan = true
                    sliderGestureChanged(true)
                    beginSplitDrag(at: value.startLocation, size: size)
                }
                guard !dragConsumed, let index = dragSplitIndex else { return }
                moveSplit(index, toX: value.location.x, size: size)
            }
            .onEnded { _ in finishDrag() }
    }

    private func finishDrag() {
        dragBegan = false
        dragConsumed = false
        dragPointIndex = nil
        dragSplitIndex = nil
        splitGrabOffset = 0
        sliderGestureChanged(false)
    }

    private func beginDrag(at location: CGPoint, size: CGSize) {
        guard size.width > 1, size.height > 1 else { dragConsumed = true; return }
        if channel == .parametric {
            beginSplitDrag(at: location, size: size)
            return
        }
        let points: [[Double]] = currentPoints
        if let hit = nearestPointIndex(to: location, size: size) {
            if NSEvent.modifierFlags.contains(.option) {
                deletePoint(at: hit)
                dragConsumed = true
                return
            }
            dragPointIndex = hit
            return
        }
        // A click on empty graph adds a point and keeps dragging it, which is the same
        // gesture as placing one and adjusting it in one motion — so the placement and
        // the adjustment share a key and stay ONE undo step.
        let x: Double = CurveEditing.clamp01(Double(location.x / size.width))
        let y: Double = CurveEditing.clamp01(1 - Double(location.y / size.height))
        let updated: [[Double]] = CurveEditing.sanitized(
            CurveStack.settingPoint(points, x: x, y: y))
        let placed: Int? = CurveEditing.nearestIndexByX(updated, x: x)
        commitPoints(updated, key: pointKey(placed ?? 0))
        dragPointIndex = placed
    }

    /// Take hold of the split under the press, or — on the second click of a
    /// double-click — put that one back. docs/04 §7.1 specifies both.
    ///
    /// The click count is read at press rather than through an `onTapGesture(count: 2)`
    /// because a minimumDistance-0 drag claims every press and a tap gesture behind one
    /// never fires; LumenControls' slider track and the mixer ring both had to learn
    /// this the same way.
    private func beginSplitDrag(at location: CGPoint, size: CGSize) {
        guard let index = nearestSplitIndex(to: location, size: size) else {
            dragConsumed = true
            return
        }
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
            var splits: [Double] = currentSplits
            guard index < splits.count, index < CurveEditing.defaultSplits.count
            else { dragConsumed = true; return }
            splits[index] = CurveEditing.defaultSplits[index]
            writeSplits(splits)
            dragConsumed = true
            return
        }
        dragSplitIndex = index
        splitGrabOffset = location.x - CGFloat(currentSplits[index]) * size.width
    }

    /// 10–90%, per docs/04 §7.1: a split pinned to either end would leave a region with
    /// no axis under it and nothing for its slider to do. The bound is
    /// `CurveEditing.clampedSplit`, which is the same one `sanitizedSplits` repairs to —
    /// two copies of it is how the sanitiser came to breach its own ceiling.
    private func moveSplit(_ index: Int, toX locationX: CGFloat, size: CGSize) {
        guard size.width > 1 else { return }
        var splits: [Double] = currentSplits
        guard index >= 0, index < splits.count else { return }
        let x: Double = Double((locationX - splitGrabOffset) / size.width)
        splits[index] = CurveEditing.clampedSplit(x)
        writeSplits(splits)
    }

    private func updateDrag(to location: CGPoint, size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        let x: Double = CurveEditing.clamp01(Double(location.x / size.width))
        let y: Double = CurveEditing.clamp01(1 - Double(location.y / size.height))

        if channel == .parametric {
            guard let index = dragSplitIndex else { return }
            moveSplit(index, toX: location.x, size: size)
            return
        }

        guard let index = dragPointIndex else { return }
        let points: [[Double]] = currentPoints
        guard points.indices.contains(index) else { return }
        // `moved` clamps x inside the neighbours' window, so the array stays strictly
        // increasing and the index this drag is holding stays the point the hand grabbed.
        commitPoints(CurveEditing.moved(points, index: index, toX: x, toY: y),
                     key: pointKey(index))
    }

    /// Releasing well outside the graph deletes the point (docs/04 §7, from ART).
    ///
    /// It cannot take an anchor with it: `deletePoint` refuses those, so pulling the
    /// black point down and left — which is a thing photographers do to a curve on
    /// purpose — leaves it where the drag last put it instead of removing it.
    private func endDrag(at location: CGPoint, size: CGSize) {
        guard channel != .parametric, let index = dragPointIndex else { return }
        guard size.width > 1, size.height > 1 else { return }
        let escaped: Bool = CurveEditing.escapes(
            x: Double(location.x / size.width),
            y: Double(location.y / size.height),
            marginX: Double(CurveEditorView.hitRadius / size.width),
            marginY: Double(CurveEditorView.hitRadius / size.height))
        if escaped { deletePoint(at: index) }
    }

    // MARK: Point editing

    /// The point under a press, with a target bigger than the ink.
    ///
    /// The tolerance goes to `CurveEditing` as a FRACTION of the plot in each axis, which
    /// is the same circle in points that `hitRadius` names — the plot is square
    /// (`aspectRatio(1)`), so the two fractions describe one radius.
    private func nearestPointIndex(to location: CGPoint?, size: CGSize) -> Int? {
        guard channel != .parametric, let location else { return nil }
        guard size.width > 1, size.height > 1 else { return nil }
        return CurveEditing.hitIndex(
            currentPoints,
            x: Double(location.x / size.width),
            y: 1 - Double(location.y / size.height),
            toleranceX: Double(CurveEditorView.hitRadius / size.width),
            toleranceY: Double(CurveEditorView.hitRadius / size.height))
    }

    /// The split within `hitRadius` of the press, or none — the same radius, and the
    /// same rule, as `nearestPointIndex`.
    ///
    /// It used to seed `bestDistance` with the plot's whole width, which made "nearest"
    /// unconditional: ANY press anywhere in the Param graph grabbed a split, and since
    /// the gesture fires once at press with `location == startLocation`, that split
    /// jumped to the click point before the hand had moved. Exploring the graph with the
    /// mouse silently changed the picture — the worst property a control can have while
    /// someone is trying to work out what it is.
    private func nearestSplitIndex(to location: CGPoint, size: CGSize) -> Int? {
        guard size.width > 1 else { return nil }
        let splits: [Double] = currentSplits
        var best: Int? = nil
        var bestDistance: CGFloat = CurveEditorView.hitRadius
        for i in 0..<splits.count {
            let px: CGFloat = CGFloat(splits[i]) * size.width
            let distance: CGFloat = abs(px - location.x)
            if distance <= bestDistance {
                bestDistance = distance
                best = i
            }
        }
        return best
    }

    /// Whether the point under the pointer is one the two-anchor rule permits removing.
    private var hoveredPointIsDeletable: Bool {
        guard let index = nearestPointIndex(to: hoverLocation, size: plotSize)
        else { return false }
        return CurveEditing.isDeletable(index: index, count: currentPoints.count)
    }

    private func deleteNearestPoint() {
        guard let index = nearestPointIndex(to: hoverLocation, size: plotSize) else { return }
        deletePoint(at: index)
    }

    /// THE TWO ANCHORS ARE NOT DELETABLE, which is what `CurveEditing.deleting` decides.
    ///
    /// The rule here was "a curve needs two points", so the FIRST and LAST were removable
    /// the moment a third existed — by ⌥-click, by the context menu, and by dragging one
    /// out of the graph, which is reachable simply by pulling the black point down and to
    /// the left. `MonotoneCubic` then extends flat below the new first x: every shadow
    /// under it renders one identical value, a posterized block the graph draws as a
    /// horizontal line, and nothing but Flatten undoes it — which throws away every other
    /// point the photographer placed.
    ///
    /// A distinct key from `pointKey`, so a delete is its own undo step rather than
    /// folding into the drag that preceded it.
    private func deletePoint(at index: Int) {
        guard let remaining = CurveEditing.deleting(currentPoints, at: index) else { return }
        commitPoints(remaining,
                     key: keyPrefix + "delete." + channel.rawValue + ".\(index)")
    }

    // MARK: Drawing

    private static func draw(context: inout GraphicsContext,
                             size: CGSize,
                             backdrop: [Double],
                             samples: [Double],
                             controls: [[Double]],
                             regions: [ParametricRegion],
                             highlight: Int?,
                             tint: Color) {
        guard size.width > 1, size.height > 1 else { return }

        // The frame's luminance histogram, underneath everything: the curve is judged
        // against the picture's distribution, not against an empty square.
        if backdrop.count > 1 {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            let count: Int = backdrop.count
            let step: Int = Swift.max(1, count / Swift.max(1, Int(size.width)))
            var i: Int = 0
            while i < count {
                var peak: Double = 0
                var j: Int = i
                let end: Int = Swift.min(i + step, count)
                while j < end {
                    let v: Double = backdrop[j]
                    if v.isFinite && v > peak { peak = v }
                    j += 1
                }
                let x: CGFloat = size.width * CGFloat(i) / CGFloat(count - 1)
                let y: CGFloat = size.height - CGFloat(clamp01(peak)) * size.height
                path.addLine(to: CGPoint(x: x, y: y))
                i += step
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            context.fill(path, with: .color(Lumen.fillColor.opacity(0.18)))
        }

        // THE FOUR REGIONS, NAMED, BEHIND THE CURVE. Four sliders called Highlights,
        // Lights, Darks and Shadows over a blank square say nothing about which part of
        // the axis each one owns, and three anonymous handles decide it. A band with the
        // slider's own name written in it answers both at once, without a word of prose
        // and without the photographer having to ask.
        for r in 0..<regions.count {
            let region: ParametricRegion = regions[r]
            let x0: CGFloat = size.width * CGFloat(clamp01(region.lower))
            let x1: CGFloat = size.width * CGFloat(clamp01(region.upper))
            let band = CGRect(x: x0, y: 0, width: Swift.max(0, x1 - x0), height: size.height)
            let lit: Bool = r == highlight
            // Alternating, so four regions read as four without spending four hues on a
            // zero-chroma panel; the lit one takes the accent because it is answering.
            let fill: Color = lit
                ? Lumen.accent.opacity(0.13)
                : Lumen.fillColor.opacity(r % 2 == 0 ? 0.07 : 0.02)
            context.fill(Path(band), with: .color(fill))

            // Dropped rather than truncated when the splits leave no room: "Highl…"
            // over a 20-point band is worse than the band alone, and the slider's own
            // tooltip still names it.
            let labelWidth: CGFloat = r < regionLabelWidths.count
                ? regionLabelWidths[r] : .infinity
            if labelWidth + 8 <= band.width {
                context.draw(Text(region.title)
                                .font(.lumenCaption)
                                .foregroundStyle(lit ? Lumen.primaryText
                                                     : Lumen.secondaryText),
                             at: CGPoint(x: band.midX, y: 9), anchor: .center)
            }
        }

        // The boundaries themselves, which are the splits — drawn from the regions so
        // the line and the band it divides can never disagree.
        for r in 0..<Swift.max(0, regions.count - 1) {
            let x: CGFloat = size.width * CGFloat(clamp01(regions[r].upper))
            var edge = Path()
            edge.move(to: CGPoint(x: x, y: 0))
            edge.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(edge, with: .color(Lumen.accent.opacity(0.45)), lineWidth: 1)
        }

        // Quarter grid and the identity diagonal.
        var grid = Path()
        var line: Int = 1
        while line < 4 {
            let t: CGFloat = CGFloat(line) / 4
            grid.move(to: CGPoint(x: size.width * t, y: 0))
            grid.addLine(to: CGPoint(x: size.width * t, y: size.height))
            grid.move(to: CGPoint(x: 0, y: size.height * t))
            grid.addLine(to: CGPoint(x: size.width, y: size.height * t))
            line += 1
        }
        context.stroke(grid, with: .color(Lumen.separator.opacity(0.45)), lineWidth: 0.5)

        var diagonal = Path()
        diagonal.move(to: CGPoint(x: 0, y: size.height))
        diagonal.addLine(to: CGPoint(x: size.width, y: 0))
        context.stroke(diagonal, with: .color(Lumen.separator),
                       style: StrokeStyle(lineWidth: 0.75, dash: [3, 3]))

        // WHAT THE LIT SLIDER ACTUALLY REACHES, drawn as the shape it is rather than
        // as the rectangle it is named after. The regions crossfade, so the band's edge
        // is not a wall — a Darks move bleeds well into Shadows and Lights — and the
        // endpoint envelope takes the whole thing to zero at both ends of the axis.
        // That second fact is the answer to the question this control provokes most
        // often, "why did nothing happen to my blacks", and it is far easier to see
        // than to read.
        if let highlight, highlight >= 0, highlight < regions.count {
            let reach: [Double] = regions[highlight].reach
            if reach.count > 1 {
                var profile = Path()
                profile.move(to: CGPoint(x: 0, y: size.height))
                for i in 0..<reach.count {
                    let x: CGFloat = size.width * CGFloat(i) / CGFloat(reach.count - 1)
                    let y: CGFloat = size.height - CGFloat(clamp01(reach[i])) * size.height
                    profile.addLine(to: CGPoint(x: x, y: y))
                }
                profile.addLine(to: CGPoint(x: size.width, y: size.height))
                profile.closeSubpath()
                context.fill(profile, with: .color(Lumen.accent.opacity(0.14)))
                context.stroke(profile, with: .color(Lumen.accent.opacity(0.55)),
                               lineWidth: 1)
            }
        }

        // The curve itself.
        if samples.count > 1 {
            var path = Path()
            for i in 0..<samples.count {
                let x: CGFloat = size.width * CGFloat(i) / CGFloat(samples.count - 1)
                let y: CGFloat = size.height - CGFloat(clamp01(samples[i])) * size.height
                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            context.stroke(path, with: .color(tint), lineWidth: 1.5)
        }

        // Control points last, so they are never hidden by the trace they define.
        for point in controls where point.count >= 2 {
            let cx: CGFloat = size.width * CGFloat(clamp01(point[0]))
            let cy: CGFloat = size.height - CGFloat(clamp01(point[1])) * size.height
            let rect = CGRect(x: cx - 3, y: cy - 3, width: 6, height: 6)
            context.fill(Path(ellipseIn: rect), with: .color(Lumen.panelBackground))
            context.stroke(Path(ellipseIn: rect), with: .color(tint), lineWidth: 1.5)
        }
    }

    /// Three triangles on a rail, each pointing up at the boundary it sets.
    private static func drawSplitRail(context: inout GraphicsContext,
                                      size: CGSize,
                                      splits: [Double],
                                      active: Int?) {
        guard size.width > 1, size.height > 1 else { return }

        var rail = Path()
        rail.move(to: CGPoint(x: 0, y: 0.5))
        rail.addLine(to: CGPoint(x: size.width, y: 0.5))
        context.stroke(rail, with: .color(Lumen.separator), lineWidth: 1)

        let half: CGFloat = 5
        let depth: CGFloat = Swift.min(8, size.height - 2)
        for i in 0..<splits.count {
            let x: CGFloat = size.width * CGFloat(clamp01(splits[i]))
            var triangle = Path()
            triangle.move(to: CGPoint(x: x, y: 1))
            triangle.addLine(to: CGPoint(x: x - half, y: 1 + depth))
            triangle.addLine(to: CGPoint(x: x + half, y: 1 + depth))
            triangle.closeSubpath()
            context.fill(triangle,
                         with: .color(i == active ? Lumen.primaryText : Lumen.accent))
            // Outlined in the panel's own colour so two splits dragged together still
            // read as two handles rather than as one wide one.
            context.stroke(triangle, with: .color(Lumen.panelBackground), lineWidth: 0.5)
        }
    }

    // MARK: - Regions

    /// The four regions the splits carve out, in the maths' own dark-to-light order.
    ///
    /// `reach` is rebuilt here rather than read off `CurveStack`, and deliberately so:
    /// the bake's own `parametricBumps` samples a 1025-point grid because a slope solve
    /// needs one, which is ten times the work a 300-point-wide graph can show. What is
    /// copied is the FORMULA — `ZoneWeights.crossfade` over `regionCentres`, times the
    /// same `4x(1−x)` envelope — so the shape drawn is the shape applied.
    private static func regions(splits: [Double]) -> [ParametricRegion] {
        let clean: [Double] = CurveEditing.sanitizedSplits(splits)
        let bounds: [Double] = [0] + clean + [1]
        let centres: [Double] = CurveStack.regionCentres(clean)
        let n: Int = Swift.max(2, reachSamples)

        var out: [ParametricRegion] = []
        out.reserveCapacity(4)
        for r in 0..<4 {
            var reach = [Double](repeating: 0, count: n)
            var peak: Double = 0
            for i in 0..<n {
                let x: Double = Double(i) / Double(n - 1)
                let (lower, weight) = ZoneWeights.crossfade(x: x, pivots: centres)
                // A raised-cosine crossfade only ever touches two regions, so this one
                // carries the weight, the remainder, or nothing.
                let share: Double = lower == r ? weight : (lower + 1 == r ? 1 - weight : 0)
                let value: Double = share * 4 * x * (1 - x)
                reach[i] = value
                peak = Swift.max(peak, value)
            }
            // Normalized to its own peak so every band's shape is legible at full
            // height. The regions are not the same width — the middle two are half the
            // outer two at the default splits — so drawing them to a common scale would
            // make Darks and Lights look like weaker controls than they are.
            if peak > 1e-12 {
                for i in 0..<n { reach[i] /= peak }
            }
            out.append(ParametricRegion(title: regionTitles[r],
                                        lower: bounds[r], upper: bounds[r + 1],
                                        reach: reach))
        }
        return out
    }

    // MARK: Sanitizing

    /// The drawing code's shorthand for `CurveEditing.clamp01`.
    ///
    /// Every other sanitiser that used to live here — the point list, the splits, the
    /// nearest-x lookup, the readout's formatter — is in `CurveEditing` now, and this
    /// one is a forward rather than a fifth copy. A NaN reaching a `Path` is a drawing
    /// that silently disappears, which is why the guard exists at all.
    private static func clamp01(_ v: Double) -> Double { CurveEditing.clamp01(v) }
}

#endif
