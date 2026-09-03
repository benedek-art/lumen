// HistogramView.swift
// The Develop histogram (D12, docs/04 §8): four traces on the readout space's tonal
// axis, the two channel-diagnostic clipping triangles, and the five draggable zones
// that turn the graph into an input device rather than a picture of one.
//
// Three rules this file exists to enforce:
//   · The view never measures anything. It draws the `Histogram` it is handed, and nil
//     is a legitimate value — nothing has been rendered yet — which draws an empty
//     frame and never a crash.
//   · Per-frame cost is proportional to the number of bins, never to pixels. Each trace
//     is one polyline with at most one vertex per horizontal point, decimated by max so
//     a one-bin spike survives the decimation instead of disappearing at small sizes.
//   · The headline percentages and the corner triangles are ONE computation. They were
//     two — a luma-channel number beside an R/G/B-coloured triangle — and the pair
//     disagreed on every single-channel clip. Both now come from
//     `ScopeReadout.clipping`, which owns the threshold and the worst-of-R/G/B rule.
//   · Dragging a zone scrubs the six-slider tone panel through
//     `AppState.updateRecipe(coalescingKey:)`, so one drag is one undo step and the
//     graph and the panel can never disagree about what a slider is worth. The middle
//     zone is Exposure, not "Mids" — the histogram drives the tone panel (docs/04 §8.1).
//
// THE READOUT SPACE IS NOT A CONTROL ANY MORE, it is a property of the readout.
//
// It was a three-segment picker under the graph — `Working % | sRGB 255 | Output 255` —
// and it printed the current space TWICE, four points apart: once as the selected
// segment and once as the label at the right of the readout line directly above it. Two
// consumers use the setting (this view and the loupe's sample pill), and neither is
// touched in a normal edit; a photographer picks a space once and never returns. So it
// held nineteen points of permanent chrome under the one instrument in this column that
// wanted the height, to say a thing already written four points above it.
//
// So the label became the control: click it to cycle, right-click the graph to choose.
// The space the bins were actually binned in still travels with the value
// (`Histogram.transform.space`), and until the render coordinator accepts a requested
// space the label says so when the two disagree — which is the one thing here that must
// never be hidden behind a menu, and is not.

#if os(macOS)

import AppKit
import CoreGraphics
import Foundation
import LumenCore
import SwiftUI

// MARK: - Trace

/// One channel's drawable form: normalized bin heights plus how it is painted.
/// R/G/B are additive so overlaps read as the secondary they are; luma is a line on
/// top, because a filled luma trace would bury the channels underneath it.
private struct HistogramTrace {
    let color: Color
    let values: [Double]
    let additive: Bool
}

// MARK: - Histogram view

struct HistogramView: View {

    @EnvironmentObject var state: AppState
    /// This surface shows the edit, so it observes the edit signal —
    /// `AppState.recipes` is deliberately not published (see `EditRevision`).
    @EnvironmentObject var edits: EditRevision

    private let histogram: Histogram?

    init(histogram: Histogram?) {
        self.histogram = histogram
    }

    @State private var hoverAxis: Double? = nil
    @State private var dragZone: Histogram.ZoneSlider? = nil
    /// The gesture-in-flight signal every slider fires (docs/23 audit queue item 5):
    /// scrubbing a histogram zone is a tone drag and paid per-event persistence.
    @Environment(\.sliderGestureChanged) private var sliderGestureChanged
    @State private var dragStartValue: Double = 0
    /// The end whose overlay this view switched on while the pointer hovered its
    /// triangle, so leaving the triangle can put the overlay back the way it was.
    @State private var peekedMode: ClippingOverlay.Mode? = nil

    /// 132, up from 104, and most of it was paid for rather than taken.
    ///
    /// The block stood 155 points tall and the graph was 104 of them: a third of the
    /// instrument was chrome, and most of that third was the readout-space picker
    /// underneath. Retiring the picker returned 23 points and they went straight into
    /// the graph, which now has 77% of the block instead of 67%. The block itself grows
    /// by 17 — the readout line is taller at the type scale's size — and that is the
    /// honest cost.
    ///
    /// It is worth paying because a histogram is read for the SHAPE of a distribution,
    /// and shape is what a short graph destroys: at 104 points a two-stop difference in
    /// where the shadows sit is a few pixels of hill, which is the difference between an
    /// instrument and a decoration.
    private static let graphHeight: CGFloat = 132
    private static let triangleSize: CGFloat = 11

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            graph
            readoutLine
            // WHAT IT IS A HISTOGRAM OF, and only when that is not the plain answer.
            //
            // The instrument has two feeds that measure two different pictures — the
            // frame on screen with its soft proof in it, or a render commissioned
            // without one — and it printed neither. A permanent caption for the ordinary
            // case would be chrome; `Provenance.note` is nil there, so this row does not
            // exist unless something a photographer would be surprised by is true.
            if let note = state.scopes?.provenance?.note {
                Text(note)
                    .font(.lumenCaption)
                    .foregroundStyle(Lumen.secondaryText)
                    .lineLimit(1)
                    .help(measurementStatement)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .foregroundStyle(Lumen.primaryText)
        // The same card the accordion's sections wear, so the instrument reads as one of
        // the column's areas rather than as something painted onto the chrome above it.
        .lumenSurface(radius: Lumen.radiusCard, elevation: .flush, fill: Lumen.panel)
    }

    // MARK: Graph

    private var graph: some View {
        GeometryReader { geometry in
            let size: CGSize = geometry.size
            let traces: [HistogramTrace] = HistogramView.traces(for: histogram)
            let zones: [Histogram.Zone] = self.zones
            let highlighted: Histogram.ZoneSlider? = dragZone ?? hoverZone
            let axis: Double? = hoverAxis

            ZStack(alignment: .topLeading) {
                Canvas { context, canvasSize in
                    HistogramView.draw(context: &context, size: canvasSize,
                                       traces: traces, zones: zones,
                                       highlighted: highlighted, hoverAxis: axis)
                }
                if histogram == nil {
                    Text("No histogram yet")
                        .font(.lumenCaption)
                        .foregroundStyle(Lumen.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                clippingTriangle(end: .low)
                    .padding(3)
                clippingTriangle(end: .high)
                    .padding(3)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .gesture(zoneDrag(width: size.width))
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point):
                    hoverAxis = size.width > 1
                        ? HistogramView.clamp01(Double(point.x / size.width))
                        : nil
                case .ended:
                    hoverAxis = nil
                }
            }
        }
        .frame(height: HistogramView.graphHeight)
        // A WELL WITH A LIP, and a floor that is not one flat wash.
        //
        // It was `Color.black.opacity(0.55)` behind a bare 4pt clip: a rectangle of paint
        // with no edge at all, which is the exact defect `LumenSurface.swift` was written
        // about. The fill now falls off downward the way the inside of a recess does, and
        // `lumenWell` adds the carved lip — dark along the top where the light does not
        // reach, faintly lit along the bottom where it lands. Both together are what say
        // "the graph is cut INTO the panel"; either alone reads as a drawn box.
        .background(
            LinearGradient(colors: [Color.black.opacity(0.62),
                                    Color.black.opacity(0.46)],
                           startPoint: .top, endPoint: .bottom))
        .lumenWell(radius: Lumen.radiusControl)
        // The graph is a five-zone horizontal scrubber and said so nowhere. `.help()` on
        // a 300x132 surface is a one-second tooltip; the cursor answers in 100ms, and it
        // is how Resolve, Capture One and Photoshop all advertise the same gesture.
        .lumenScrubCursor()
        // THE SPACE PICKER, demoted. An inline `Picker` in a context menu draws the
        // checkmark itself, so the current space stays visible where it is chosen without
        // this view printing it a third time.
        //
        // AND IT IS THE ONE PICKER IN THE APP THAT STAYED A SYSTEM ONE, when every
        // pull-down the owner could see became a `LumenMenu`. A right-click menu has no
        // content view SwiftUI can style — it is an `NSMenu`, summoned by a gesture, and
        // `.pickerStyle(.inline)` inside one draws rows rather than the bezelled popup
        // that was the complaint. Nothing here is a control anybody looks at: the
        // visible way to change the readout space is the readout label below, which
        // cycles on click and says so in its tooltip. So this stays a context menu, and
        // the choice keeps the visible control it already had rather than gaining a
        // second one twenty points away.
        .contextMenu {
            Picker("Readout space", selection: $state.readoutSpace) {
                ForEach(ReadoutSpace.allCases, id: \.self) { space in
                    Text(HistogramView.shortLabel(space)).tag(space)
                }
            }
            .pickerStyle(.inline)
        }
        // The instrument's own specification, where an instrument's specification goes:
        // which image was binned, on which axis, how the clipping percentages were
        // arrived at, what the luma trace is weighted by, and what the vertical is. Not
        // one of those was written anywhere in the app before this line.
        .help(measurementStatement)
    }

    /// The full sentence behind the graph, assembled from the measurement's own record
    /// rather than from what this view assumes about its feed.
    private var measurementStatement: String {
        guard let histogram else { return "No measurement yet." }
        let provenance: ScopeReadout.Provenance = state.scopes?.provenance
            ?? ScopeReadout.Provenance(frame: .viewerFrame, proofed: false,
                                       instrumentPaint: false, exactCounts: false)
        return provenance.statement(readout: histogram.transform.space)
            + " Luma trace: " + ScopeReadout.lumaLabel(histogram.transform) + ". "
            + ScopeReadout.verticalScaleNote
    }

    // MARK: Readout line

    private var readoutLine: some View {
        HStack(spacing: 6) {
            Text(primaryReadout)
                // The subject of this block, not an annotation on it: `lumenNumericStrong`
                // is the scale's entry for exactly this — "the histogram's clipping
                // percentages". Tabular figures, so a number does not jitter sideways as
                // the pointer sweeps the graph and it counts.
                .font(.lumenNumericStrong)
                .foregroundStyle(Lumen.primaryText)
                .lineLimit(1)
                // The instrument keeps its width; the space label gives ground first.
                .layoutPriority(1)
            Spacer(minLength: 4)
            // CLICK TO CYCLE. This label already printed the readout space; with the
            // segmented picker gone it is the only place that does, so making it the
            // control costs no chrome at all and puts the switch on the words it changes.
            // Three spaces cycle faster than a menu opens; the menu on the graph is there
            // for going straight to one.
            Button {
                state.readoutSpace = HistogramView.next(after: state.readoutSpace)
            } label: {
                Text(secondaryReadout)
                    .font(.lumenCaption)
                    .foregroundStyle(Lumen.secondaryText)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .lumenHoverable(radius: Lumen.radiusChip)
            .lumenClickCursor()
            .help("Readout space — click to cycle, or right-click the graph to choose")
        }
        .frame(height: 20)
    }

    /// The next space in declaration order, wrapping.
    private static func next(after space: ReadoutSpace) -> ReadoutSpace {
        let all: [ReadoutSpace] = ReadoutSpace.allCases
        guard let index = all.firstIndex(of: space) else { return all[0] }
        return all[(index + 1) % all.count]
    }

    /// The short name, which is what a readout line has room for.
    ///
    /// `ReadoutSpace.label` spells the space out in full — "Working (Rec.2020 linear,
    /// %)" — because it is written for a place where an unlabeled number would be a
    /// defect. Here the axis it belongs to is on screen, so the long form buys nothing
    /// and costs the clipping percentages beside it their width.
    static func shortLabel(_ space: ReadoutSpace) -> String {
        switch space {
        case .working: return "Working %"
        case .srgb255: return "sRGB 255"
        case .outputProfile: return "Output 255"
        }
    }

    /// What the pointer is over: the zone it would scrub, or the clipping summary when
    /// the pointer is elsewhere.
    private var primaryReadout: String {
        guard let histogram else { return "—" }
        if let slider = dragZone ?? hoverZone,
           let zone = zones.first(where: { $0.slider == slider }) {
            let share: Double = histogram.fraction(in: zone, channel: .luma) * 100
            let value: Double = HistogramView.toneValue(slider, in: state.currentRecipe)
            return slider.displayName + "  " + HistogramView.format(value, decimals: sliderDecimals(slider))
                + "   " + HistogramView.format(share, decimals: 1) + "% of pixels"
        }
        if let axis = hoverAxis {
            return "Level " + HistogramView.format(
                HistogramView.level(atAxis: axis, in: state.readoutSpace), decimals: 1)
        }
        // THE SAME NUMBERS THE TRIANGLES ARE PAINTED FROM (W2/H2-08).
        //
        // This line used to read the LUMA channel while the triangle four points away
        // read R/G/B. Luma clips only when essentially all three channels are at the
        // ceiling — `Histogram.compute` bins `w·(r,g,b)` into channel 3 — so every
        // single-channel clip there is (sunset, sodium light, a red dress) painted the
        // triangle red beside a number that said `0.00% white`. `ScopeReadout
        // .clipHeadline` and `clippingStrength`/`clippingColor` below now come out of
        // one function over one `Histogram`, so the two cannot say different things.
        return ScopeReadout.clipHeadline(histogram)
    }

    /// The number to print for a hover position on the histogram's axis.
    ///
    /// The axis is ALWAYS sRGB-encoded — `ScopeData` bins with `.srgb255` whatever the
    /// picker says — so `axis * fullScale` is only right when full scale is 255. For
    /// "Working %" it printed the encoded value as a percentage: a mid-grey pixel read
    /// 46.1 here while the loupe's readout pill said 18.0% for the same pixel, a factor
    /// of 2.6 apart in the shadows, from one shared setting driving two instruments.
    ///
    /// The conversion is the same one `ImageSampler.readout` does, for the same reason:
    /// two readouts of one quantity must not be two different quantities.
    static func level(atAxis axis: Double, in space: ReadoutSpace) -> Double {
        switch space {
        case .srgb255, .outputProfile:
            return axis * space.fullScale
        case .working:
            let encoded = RGB(gray: Num.saturate(axis))
            let linear = TransferFunction.srgb.decode(encoded)
            let working = RGBColorSpace.srgb.matrix(to: .rec2020).apply(linear)
            return working.g * 100
        }
    }

    private var secondaryReadout: String {
        guard let histogram else { return HistogramView.shortLabel(state.readoutSpace) }
        if histogram.transform.space != state.readoutSpace {
            return "binned in "
                + HistogramView.shortLabel(histogram.transform.space)
        }
        return HistogramView.shortLabel(state.readoutSpace)
    }

    // MARK: Zones

    private var zones: [Histogram.Zone] {
        // The histogram's OWN pivots, not `develop.zones.pivots`.
        //
        // These five zones are named after the six-slider register — Blacks, Shadows,
        // Exposure, Highlights, Whites — and dragging in one scrubs that tone slider.
        // The Zones panel's pivots describe something else entirely: five different
        // zones, on the normalized SCENE-EV axis, driving per-zone exposures. Feeding
        // them in here conflated two registers and put the windows on the wrong axis
        // as well — the histogram's axis is display-encoded, so a pivot at 0.5 scene EV
        // was drawn where the display value is 0.5, which is about two stops away.
        // Moving a zone pivot in the Zones panel silently moved where the histogram
        // thought "Blacks" was.
        //
        // Fixed positions on the histogram's own axis are what the drag needs, and the
        // Zones panel draws its register on the correct axis itself.
        Histogram.zoneBoundaries()
    }

    private var hoverZone: Histogram.ZoneSlider? {
        guard let axis = hoverAxis else { return nil }
        return HistogramView.zone(at: axis, in: zones)?.slider
    }

    private static func zone(at axis: Double, in zones: [Histogram.Zone]) -> Histogram.Zone? {
        guard !zones.isEmpty else { return nil }
        let x: Double = clamp01(axis)
        for zone in zones where zone.contains(x) { return zone }
        return zones[zones.count - 1]
    }

    /// The drag: horizontal travel across the whole graph is worth one `scrubSpan` of
    /// the zone's slider, picked up from the value the slider had when the drag started
    /// so the gesture is absolute rather than accumulating rounding error.
    private func zoneDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard width > 1 else { return }
                if dragZone == nil {
                    let startAxis: Double = HistogramView.clamp01(Double(value.startLocation.x / width))
                    guard let zone = HistogramView.zone(at: startAxis, in: zones) else { return }
                    dragZone = zone.slider
                    dragStartValue = HistogramView.toneValue(zone.slider, in: state.currentRecipe)
                }
                guard let slider = dragZone else { return }
                sliderGestureChanged(true)
                let travel: Double = Double(value.translation.width / width)
                setTone(slider, dragStartValue + travel * HistogramView.scrubSpan(slider))
            }
            .onEnded { _ in
                dragZone = nil
                sliderGestureChanged(false)
            }
    }

    private static func scrubSpan(_ slider: Histogram.ZoneSlider) -> Double {
        slider == .exposure ? 4 : 200
    }

    private func sliderDecimals(_ slider: Histogram.ZoneSlider) -> Int {
        slider == .exposure ? 2 : 0
    }

    private static func toneValue(_ slider: Histogram.ZoneSlider, in recipe: Recipe) -> Double {
        switch slider {
        case .blacks: return recipe.develop.tone.blacks
        case .shadows: return recipe.develop.tone.shadows
        case .exposure: return recipe.develop.tone.exposure
        case .highlights: return recipe.develop.tone.highlights
        case .whites: return recipe.develop.tone.whites
        }
    }

    private func setTone(_ slider: Histogram.ZoneSlider, _ value: Double) {
        guard value.isFinite else { return }
        let limit: Double = slider == .exposure ? 5 : 100
        let clamped: Double = Swift.min(Swift.max(value, -limit), limit)
        state.updateRecipe(coalescingKey: "histogram.zone." + slider.rawValue) { recipe in
            switch slider {
            case .blacks: recipe.develop.tone.blacks = clamped
            case .shadows: recipe.develop.tone.shadows = clamped
            case .exposure: recipe.develop.tone.exposure = clamped
            case .highlights: recipe.develop.tone.highlights = clamped
            case .whites: recipe.develop.tone.whites = clamped
            }
        }
    }

    // MARK: Clipping triangles

    /// Channel-diagnostic by construction: the fill is `ClippingOverlay.colour(mask:)`
    /// of the channels actually clipping at this end, so "the reds are gone" and
    /// "everything is gone" are different pictures. Hover peeks the overlay, click
    /// locks it, and a locked triangle wears an outline.
    private func clippingTriangle(end: Histogram.End) -> some View {
        let mode: ClippingOverlay.Mode = end == .low ? .blacks : .whites
        let locked: Bool = state.clippingOverlay == mode
        let strength: Double = clippingStrength(end: end)
        let fill: Color = clippingColor(end: end).opacity(0.25 + 0.75 * strength)

        return Button {
            toggleOverlay(mode)
        } label: {
            ClipTriangle(pointsLeft: end == .low)
                .fill(fill)
                .overlay(
                    ClipTriangle(pointsLeft: end == .low)
                        .stroke(locked ? Lumen.primaryText : Color.clear, lineWidth: 1)
                )
                .frame(width: HistogramView.triangleSize, height: HistogramView.triangleSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Inside the graph's scrub cursor, so the pointing hand replaces it over the
        // triangle and the scrub cursor comes back on the way out — `NSCursor` is
        // push/pop, so the two nest rather than fight.
        .lumenClickCursor()
        .onHover { inside in
            if inside {
                if state.clippingOverlay == nil {
                    peekedMode = mode
                    state.clippingOverlay = mode
                }
            } else if peekedMode == mode {
                peekedMode = nil
                if state.clippingOverlay == mode { state.clippingOverlay = nil }
            }
        }
        .help(clippingHelp(end: end, locked: locked))
    }

    private func toggleOverlay(_ mode: ClippingOverlay.Mode) {
        peekedMode = nil
        state.clippingOverlay = state.clippingOverlay == mode ? nil : mode
    }

    /// The triangle's brightness and its colour, from ONE report over the histogram the
    /// graph above is drawing. `ScopeReadout.clipping` owns the threshold, the worst-of-
    /// R/G/B rule and the ramp; three expressions in two files used to own a third each.
    private func clipReport(end: Histogram.End) -> ScopeReadout.ClipReport? {
        guard let histogram else { return nil }
        return ScopeReadout.clipping(histogram, end: end)
    }

    private func clippingStrength(end: Histogram.End) -> Double {
        clipReport(end: end)?.strength ?? 0
    }

    private func clippingColor(end: Histogram.End) -> Color {
        guard let report = clipReport(end: end),
              let rgb = ClippingOverlay.colour(mask: report.mask, allChannels: RGB.one)
        else { return Lumen.trackColor }
        return Color(red: HistogramView.clamp01(rgb.r),
                     green: HistogramView.clamp01(rgb.g),
                     blue: HistogramView.clamp01(rgb.b))
    }

    private func clippingHelp(end: Histogram.End, locked: Bool) -> String {
        let name: String = end == .low ? "Shadow clipping" : "Highlight clipping"
        guard let histogram else { return name }
        let r: String = ScopeReadout.percentString(histogram.clippedPercent(.red, end: end))
        let g: String = ScopeReadout.percentString(histogram.clippedPercent(.green, end: end))
        let b: String = ScopeReadout.percentString(histogram.clippedPercent(.blue, end: end))
        return name + " — R " + r + "%, G " + g + "%, B " + b + "%. "
            + (locked ? "Click to unlock the overlay." : "Click to lock the overlay on.")
    }

    // MARK: Drawing

    private static func traces(for histogram: Histogram?) -> [HistogramTrace] {
        guard let histogram else { return [] }
        return [
            HistogramTrace(color: Color(red: 0.90, green: 0.28, blue: 0.28),
                           values: histogram.normalized(.red), additive: true),
            HistogramTrace(color: Color(red: 0.30, green: 0.82, blue: 0.36),
                           values: histogram.normalized(.green), additive: true),
            HistogramTrace(color: Color(red: 0.32, green: 0.52, blue: 0.92),
                           values: histogram.normalized(.blue), additive: true),
            HistogramTrace(color: Lumen.primaryText,
                           values: histogram.normalized(.luma), additive: false),
        ]
    }

    private static func draw(context: inout GraphicsContext,
                             size: CGSize,
                             traces: [HistogramTrace],
                             zones: [Histogram.Zone],
                             highlighted: Histogram.ZoneSlider?,
                             hoverAxis: Double?) {
        guard size.width > 1, size.height > 1 else { return }

        var grid = Path()
        var line: Int = 1
        while line < 4 {
            let x: CGFloat = size.width * CGFloat(line) / 4
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
            line += 1
        }
        context.stroke(grid, with: .color(Lumen.separator.opacity(0.45)), lineWidth: 0.5)

        // R/G/B first, added together: overlaps read as the secondary they actually are.
        //
        // GRADIENT UNDER A CRISP EDGE, which is the whole of "can we make the histogram a
        // bit more premium". A flat 0.55 fill has one value everywhere, so the boundary
        // between the trace and the well is the same strength as the trace's own mass and
        // the eye gets no help finding the curve — three of them overlapping is a slab of
        // colour. Fading the fill downward puts the light where the information is (the
        // envelope) and lets it fall away toward the baseline, and a one-pixel stroke on
        // top of it makes the curve itself the sharpest thing in the frame. Lightroom and
        // Capture One both draw exactly this, and it is the difference between a chart and
        // an instrument.
        //
        // Both under `.plusLighter`, so the strokes add where channels coincide the same
        // way the fills do — a neutral highlight still resolves to white rather than to
        // three stacked outlines.
        context.blendMode = .plusLighter
        for trace in traces where trace.additive {
            let line: Path = linePath(trace.values, size: size)
            context.fill(closedArea(line, size: size),
                         with: .linearGradient(
                            Gradient(colors: [trace.color.opacity(0.60),
                                              trace.color.opacity(0.10)]),
                            startPoint: CGPoint(x: 0, y: 0),
                            endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(trace.color.opacity(0.85)), lineWidth: 1)
        }
        context.blendMode = .normal
        // Luma stays a line and gains a hair of weight, because it is the trace being
        // read when a photographer asks "is this exposed" and it now has three brighter
        // envelopes to stay on top of.
        for trace in traces where !trace.additive {
            let path: Path = linePath(trace.values, size: size)
            context.stroke(path, with: .color(trace.color.opacity(0.9)), lineWidth: 1.25)
        }

        // Zones on top: the hit regions are the drawing, so what you can grab is what
        // you can see.
        for zone in zones {
            let x0: CGFloat = size.width * CGFloat(clamp01(zone.lower))
            let x1: CGFloat = size.width * CGFloat(clamp01(zone.upper))
            if zone.slider == highlighted {
                let rect = CGRect(x: x0, y: 0, width: Swift.max(x1 - x0, 0), height: size.height)
                context.fill(Path(rect), with: .color(Color.white.opacity(0.10)))
            }
            if zone.upper < 1 {
                var edge = Path()
                edge.move(to: CGPoint(x: x1, y: 0))
                edge.addLine(to: CGPoint(x: x1, y: size.height))
                context.stroke(edge, with: .color(Lumen.separator.opacity(0.75)), lineWidth: 0.5)
            }
            let pivotX: CGFloat = size.width * CGFloat(clamp01(zone.pivot))
            var tick = Path()
            tick.move(to: CGPoint(x: pivotX, y: size.height - 5))
            tick.addLine(to: CGPoint(x: pivotX, y: size.height))
            context.stroke(tick, with: .color(Lumen.secondaryText.opacity(0.9)), lineWidth: 1)
        }

        if let hoverAxis {
            let x: CGFloat = size.width * CGFloat(clamp01(hoverAxis))
            var cursor = Path()
            cursor.move(to: CGPoint(x: x, y: 0))
            cursor.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(cursor, with: .color(Lumen.primaryText.opacity(0.35)), lineWidth: 0.5)
        }
    }

    /// Decimation stride: at most one vertex per horizontal point, so a 4096-bin
    /// histogram costs the same to draw as a 256-bin one.
    private static func stride(_ count: Int, width: CGFloat) -> Int {
        let points: Int = Swift.max(1, Int(width))
        return Swift.max(1, count / points)
    }

    private static func linePath(_ values: [Double], size: CGSize) -> Path {
        var path = Path()
        let n: Int = values.count
        guard n > 1, size.width > 0, size.height > 0 else { return path }
        let step: Int = stride(n, width: size.width)
        var i: Int = 0
        var started: Bool = false
        while i < n {
            var peak: Double = 0
            var j: Int = i
            let end: Int = Swift.min(i + step, n)
            while j < end {
                let v: Double = values[j]
                if v.isFinite && v > peak { peak = v }
                j += 1
            }
            let x: CGFloat = size.width * CGFloat(i) / CGFloat(n - 1)
            let y: CGFloat = size.height - CGFloat(clamp01(peak)) * size.height
            if started {
                path.addLine(to: CGPoint(x: x, y: y))
            } else {
                path.move(to: CGPoint(x: x, y: y))
                started = true
            }
            i += step
        }
        return path
    }

    /// The envelope closed down to the baseline, so it can be filled.
    ///
    /// Takes the line rather than the values: each additive trace now draws BOTH a fill
    /// and a stroke, and building the polyline twice would double the only per-frame cost
    /// this view has.
    private static func closedArea(_ line: Path, size: CGSize) -> Path {
        var path = line
        guard !path.isEmpty, size.width > 0, size.height > 0 else { return path }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.closeSubpath()
        return path
    }

    // MARK: Small helpers

    private static func clamp01(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        return Swift.min(Swift.max(v, 0), 1)
    }

    private static func format(_ v: Double, decimals: Int) -> String {
        guard v.isFinite else { return "—" }
        return String(format: "%.\(Swift.max(0, decimals))f", v)
    }
}

// MARK: - Triangle

/// The corner triangle: a right triangle pointing at the end of the scale it reports.
private struct ClipTriangle: Shape {
    let pointsLeft: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0 else { return path }
        if pointsLeft {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}

#endif
