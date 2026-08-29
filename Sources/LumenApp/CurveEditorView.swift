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
//     curve being edited, so dragging a control point is one undo step.
//   · Points are edited through `CurveStack.settingPoint(_:x:y:snap:)`, the same helper
//     the target adjustment tool uses, and x is clamped between a point's neighbours so
//     a drag can never reorder the array under its own index.
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

/// A sanitized control point. The wire form is `[[x, y], …]`; anything malformed —
/// short rows, non-finite numbers — is dropped here rather than defended against at
/// every use site.
private struct CurvePoint {
    let x: Double
    let y: Double
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

    /// The frame's histogram, drawn under the curve. Optional because nothing may have
    /// been rendered yet; nil simply draws no backdrop.
    private let histogram: Histogram?
    private let target: Target

    init(histogram: Histogram? = nil, target: Target = .global) {
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

    private static let sampleCount: Int = 128
    private static let hitRadius: CGFloat = 8
    private static let minimumSplitGap: Double = 0.02

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
            plot
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
            let controls: [CurvePoint] = channel == .parametric ? [] : currentPoints
            let splits: [Double] = channel == .parametric ? currentSplits : []
            let tint: Color = channel.tint

            ZStack {
                Canvas { context, canvasSize in
                    CurveEditorView.draw(context: &context, size: canvasSize,
                                         backdrop: backdrop, samples: samples,
                                         controls: controls, splits: splits, tint: tint)
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
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var contextItems: some View {
        if channel != .parametric {
            Button("Delete Point") { deleteNearestPoint() }
                .disabled(nearestPointIndex(to: hoverLocation, size: plotSize) == nil)
            Button("Flatten \(channel.displayName)") { flattenCurrentCurve() }
        } else {
            Button("Reset Splits") { writeSplits([0.25, 0.5, 0.75]) }
            Button("Reset Regions") { resetParametricRegions() }
        }
    }

    // MARK: Readout

    private var readoutLine: some View {
        HStack(spacing: 6) {
            Text(readoutText)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Lumen.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 4)
            if channel != .parametric {
                Text("\(currentPoints.count) pts")
                    .font(.system(size: 10))
                    .foregroundStyle(Lumen.secondaryText)
            }
        }
        .frame(height: 14)
    }

    /// In/out in percent of the encoded axis — the coordinate display docs/04 §7.1 asks
    /// for. The absolute 0–255 form belongs to the histogram's readout-space picker and
    /// arrives with it.
    private var readoutText: String {
        guard let location = hoverLocation, plotSize.width > 1, plotSize.height > 1 else {
            return channel.displayName
        }
        let x: Double = CurveEditorView.clamp01(Double(location.x / plotSize.width))
        let inValue: Double = x * 100
        let outValue: Double = CurveEditorView.clamp01(evaluate(x)) * 100
        return "in " + CurveEditorView.format(inValue) + "%   out "
            + CurveEditorView.format(outValue) + "%"
    }

    // MARK: Parametric controls

    private var parametricControls: some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenSlider(title: "Highlights",
                        value: curveValue(\.parametric.highlights,
                                          keyPrefix + "parametric.highlights"),
                        range: -100...100, hardRange: nil, defaultValue: 0,
                        step: 1, decimals: 0)
            LumenSlider(title: "Lights",
                        value: curveValue(\.parametric.lights,
                                          keyPrefix + "parametric.lights"),
                        range: -100...100, hardRange: nil, defaultValue: 0,
                        step: 1, decimals: 0)
            LumenSlider(title: "Darks",
                        value: curveValue(\.parametric.darks,
                                          keyPrefix + "parametric.darks"),
                        range: -100...100, hardRange: nil, defaultValue: 0,
                        step: 1, decimals: 0)
            LumenSlider(title: "Shadows",
                        value: curveValue(\.parametric.shadows,
                                          keyPrefix + "parametric.shadows"),
                        range: -100...100, hardRange: nil, defaultValue: 0,
                        step: 1, decimals: 0)
            DevelopNote("Drag the three splits along the bottom of the graph to move the "
                        + "region boundaries. The regions crossfade with the same "
                        + "weights the tone zones use, and an envelope pins both ends, "
                        + "so a parametric curve cannot move black or white.")
        }
    }

    private var pointControls: some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenToggleRow(title: "Preserve Luminance",
                           isOn: curveFlag(\.preserveLuminance,
                                           keyPrefix + "preserveLuminance"),
                           help: "Curve the luminance and carry the chroma ratios, so a "
                               + "contrast curve is not also a saturation boost (D10).")
            DevelopNote("Click to add a point, drag to move it, ⌥-click or right-click "
                        + "to delete it. Dragging a point out of the graph deletes it.")
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
            out[i] = CurveEditorView.clamp01(y)
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

    private var currentPoints: [CurvePoint] {
        guard let keyPath = pointsKeyPath else { return [] }
        return CurveEditorView.sanitized(curveSet[keyPath: keyPath])
    }

    private func writePoints(_ points: [CurvePoint]) {
        guard let keyPath = pointsKeyPath, points.count >= 2 else { return }
        let raw: [[Double]] = points.map { [$0.x, $0.y] }
        let identity: Bool = points.count == 2
            && abs(points[0].x) < 1e-9 && abs(points[0].y) < 1e-9
            && abs(points[1].x - 1) < 1e-9 && abs(points[1].y - 1) < 1e-9
        editCurve(keyPrefix + channel.rawValue) { set in
            set[keyPath: keyPath] = identity ? nil : raw
        }
    }

    private func flattenCurrentCurve() {
        guard let keyPath = pointsKeyPath else { return }
        editCurve(keyPrefix + "flatten." + channel.rawValue) { set in
            set[keyPath: keyPath] = nil
        }
    }

    private var currentSplits: [Double] {
        CurveEditorView.sanitizedSplits(curveSet.parametric.splits)
    }

    private func writeSplits(_ splits: [Double]) {
        let clean: [Double] = CurveEditorView.sanitizedSplits(splits)
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
                dragBegan = false
                dragConsumed = false
                dragPointIndex = nil
                dragSplitIndex = nil
                sliderGestureChanged(false)
            }
    }

    private func beginDrag(at location: CGPoint, size: CGSize) {
        guard size.width > 1, size.height > 1 else { dragConsumed = true; return }
        if channel == .parametric {
            dragSplitIndex = nearestSplitIndex(to: location, size: size)
            if dragSplitIndex == nil { dragConsumed = true }
            return
        }
        let points: [CurvePoint] = currentPoints
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
        // gesture as placing one and adjusting it in one motion.
        let x: Double = CurveEditorView.clamp01(Double(location.x / size.width))
        let y: Double = CurveEditorView.clamp01(1 - Double(location.y / size.height))
        let updated: [[Double]] = CurveStack.settingPoint(points.map { [$0.x, $0.y] },
                                                          x: x, y: y)
        let sanitized: [CurvePoint] = CurveEditorView.sanitized(updated)
        writePoints(sanitized)
        dragPointIndex = CurveEditorView.indexOfNearestX(sanitized, x: x)
    }

    private func updateDrag(to location: CGPoint, size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        let x: Double = CurveEditorView.clamp01(Double(location.x / size.width))
        let y: Double = CurveEditorView.clamp01(1 - Double(location.y / size.height))

        if channel == .parametric {
            guard let index = dragSplitIndex else { return }
            var splits: [Double] = currentSplits
            guard index >= 0, index < splits.count else { return }
            splits[index] = Swift.min(Swift.max(x, 0.10), 0.90)
            writeSplits(splits)
            return
        }

        guard let index = dragPointIndex else { return }
        var points: [CurvePoint] = currentPoints
        guard index >= 0, index < points.count else { return }
        // Clamp x inside the neighbours' window: the array stays sorted, so the index
        // this drag is holding stays the point the user grabbed.
        let gap: Double = 0.004
        let lower: Double = index > 0 ? points[index - 1].x + gap : 0
        let upper: Double = index < points.count - 1 ? points[index + 1].x - gap : 1
        let clampedX: Double = upper > lower ? Swift.min(Swift.max(x, lower), upper) : points[index].x
        points[index] = CurvePoint(x: clampedX, y: y)
        writePoints(points)
    }

    private func endDrag(at location: CGPoint, size: CGSize) {
        guard channel != .parametric, let index = dragPointIndex else { return }
        guard size.width > 1, size.height > 1 else { return }
        let outside: Bool = location.x < -CurveEditorView.hitRadius
            || location.y < -CurveEditorView.hitRadius
            || location.x > size.width + CurveEditorView.hitRadius
            || location.y > size.height + CurveEditorView.hitRadius
        if outside { deletePoint(at: index) }
    }

    // MARK: Point editing

    private func nearestPointIndex(to location: CGPoint?, size: CGSize) -> Int? {
        guard channel != .parametric, let location else { return nil }
        guard size.width > 1, size.height > 1 else { return nil }
        let points: [CurvePoint] = currentPoints
        var best: Int? = nil
        var bestDistance: CGFloat = CurveEditorView.hitRadius
        for i in 0..<points.count {
            let px: CGFloat = CGFloat(points[i].x) * size.width
            let py: CGFloat = (1 - CGFloat(points[i].y)) * size.height
            let dx: CGFloat = px - location.x
            let dy: CGFloat = py - location.y
            let distance: CGFloat = (dx * dx + dy * dy).squareRoot()
            if distance <= bestDistance {
                bestDistance = distance
                best = i
            }
        }
        return best
    }

    private func nearestSplitIndex(to location: CGPoint, size: CGSize) -> Int? {
        guard size.width > 1 else { return nil }
        let splits: [Double] = currentSplits
        var best: Int? = nil
        var bestDistance: CGFloat = size.width
        for i in 0..<splits.count {
            let px: CGFloat = CGFloat(splits[i]) * size.width
            let distance: CGFloat = abs(px - location.x)
            if distance < bestDistance {
                bestDistance = distance
                best = i
            }
        }
        return best
    }

    private func deleteNearestPoint() {
        guard let index = nearestPointIndex(to: hoverLocation, size: plotSize) else { return }
        deletePoint(at: index)
    }

    /// A curve needs two points to mean anything, so the last two are not deletable.
    private func deletePoint(at index: Int) {
        var points: [CurvePoint] = currentPoints
        guard points.count > 2, index >= 0, index < points.count else { return }
        points.remove(at: index)
        writePoints(points)
    }

    // MARK: Drawing

    private static func draw(context: inout GraphicsContext,
                             size: CGSize,
                             backdrop: [Double],
                             samples: [Double],
                             controls: [CurvePoint],
                             splits: [Double],
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

        // The four parametric regions and their movable splits.
        if !splits.isEmpty {
            for i in 0..<splits.count {
                let x: CGFloat = size.width * CGFloat(clamp01(splits[i]))
                var edge = Path()
                edge.move(to: CGPoint(x: x, y: 0))
                edge.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(edge, with: .color(Lumen.accent.opacity(0.55)), lineWidth: 1)
                let handle = CGRect(x: x - 4, y: size.height - 8, width: 8, height: 8)
                context.fill(Path(handle), with: .color(Lumen.accent))
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
        for point in controls {
            let cx: CGFloat = size.width * CGFloat(clamp01(point.x))
            let cy: CGFloat = size.height - CGFloat(clamp01(point.y)) * size.height
            let rect = CGRect(x: cx - 3, y: cy - 3, width: 6, height: 6)
            context.fill(Path(ellipseIn: rect), with: .color(Lumen.panelBackground))
            context.stroke(Path(ellipseIn: rect), with: .color(tint), lineWidth: 1.5)
        }
    }

    // MARK: Sanitizing

    private static func sanitized(_ raw: [[Double]]?) -> [CurvePoint] {
        guard let raw, !raw.isEmpty else {
            return [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
        }
        var out: [CurvePoint] = []
        out.reserveCapacity(raw.count)
        for row in raw where row.count >= 2 {
            let x: Double = row[0]
            let y: Double = row[1]
            guard x.isFinite, y.isFinite else { continue }
            out.append(CurvePoint(x: clamp01(x), y: clamp01(y)))
        }
        guard out.count >= 2 else {
            return [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
        }
        out.sort { $0.x < $1.x }
        return out
    }

    private static func sanitizedSplits(_ raw: [Double]) -> [Double] {
        var out: [Double] = raw.count == 3 ? raw : [0.25, 0.5, 0.75]
        for i in 0..<out.count where !out[i].isFinite {
            out[i] = [0.25, 0.5, 0.75][i]
        }
        out.sort()
        for i in 0..<out.count {
            out[i] = Swift.min(Swift.max(out[i], 0.10), 0.90)
        }
        for i in 1..<out.count where out[i] <= out[i - 1] + minimumSplitGap {
            out[i] = Swift.min(0.98, out[i - 1] + minimumSplitGap)
        }
        return out
    }

    private static func indexOfNearestX(_ points: [CurvePoint], x: Double) -> Int? {
        guard !points.isEmpty else { return nil }
        var best: Int = 0
        var bestDistance: Double = abs(points[0].x - x)
        for i in 1..<points.count {
            let distance: Double = abs(points[i].x - x)
            if distance < bestDistance {
                bestDistance = distance
                best = i
            }
        }
        return best
    }

    private static func clamp01(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        return Swift.min(Swift.max(v, 0), 1)
    }

    private static func format(_ v: Double) -> String {
        guard v.isFinite else { return "—" }
        return String(format: "%.1f", v)
    }
}

#endif
