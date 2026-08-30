// LumenControls.swift
// The control kit every panel is built from, and the single place the slider contract
// (D45) is implemented. A slider that behaves differently in one panel is a bug the
// user feels before they can name it, so there is exactly one slider in this app.
//
// The contract, in one place. This list is what the file DOES, and it is worth saying
// why that needs stating: it used to open with "←/→ nudge by one step; ⇧ multiplies by
// 10; ⌥ divides by 10", and this file contains no key handling of any kind. The keymap
// owns the arrows, where they move the photo selection.
//
//   · drag the track — grab the thumb and it follows the cursor; press the track and
//     the value jumps there once, then follows from there
//   · ⇧ while dragging makes it fine, at any point, without the thumb jumping
//   · drag the NUMBER to scrub it — three track-widths of travel per full range, so the
//     readout is the precision instrument and the track is the coarse one
//   · click the number and type a value, or type arithmetic: `+= 0.3`, `-= 0.2`,
//     `* 2`, `/ 2`. A bare number is absolute, negative ones included
//   · double-click the label or the track resets to the default (or to whatever
//     `onReset` means for a row whose neutral is "auto")
//   · the range is SOFT — dragging pins at the soft limit, typing accepts the hard one
//   · a control that is not at its default shows it, so "what did I change?" is
//     answerable at a glance rather than by memory
//   · a haptic tick when the value CROSSES its default, on trackpads that have one
//   · click the row to focus it, then ←/→ nudge by one step and ⇧←/⇧→ by ten;
//     Escape drops the focus
//   · ⌥-scroll over the row nudges it without focusing it first — one step per wheel
//     click, ten with ⇧, and a plain scroll still scrolls the panel
//
// THE NUDGE NEEDED THREE THINGS, and it is worth saying which, because the reason it
// was absent for so long was never the arithmetic. Arrow keys already mean "previous /
// next photo", claimed by `KeyDispatcher`'s NSEvent monitor, which sits in FRONT of the
// responder chain — so a focused slider would never have seen one.
//
//   1. The row is focusable, with the system ring turned off and the row's own SURFACE
//      carrying the state instead (`LumenFocus.swift`): macOS's blue halo is sized for
//      standard AppKit controls and reads as a bug on a groove in a zero-chroma panel —
//      and so did the accent ring this app drew in its place, which fired on mouse-down
//      and put a blue border around every slider the moment it was touched.
//   2. The dispatcher stands down while a slider holds focus, by exactly the mechanism
//      it already uses for the zoomed loupe's pan — returning nil hands the key to the
//      responder chain. Without it `onKeyPress` below is unreachable code.
//   3. Focus is releasable, and Escape has to reach the slider to release it, which is
//      a second yield in the same dispatcher. Press Escape again with nothing focused
//      and it still means the grid.
//
// Still absent rather than advertised: ⌘-double-click to auto, ⇧⌥-drag to the hard
// limit, and hold-to-sweep on the arrows (see `nudge`).
//
// The arithmetic behind the drag, the typing, the detent and the wheel all lives in
// LumenCore — `SliderTrack`, `FineDrag`, `SliderEntry`, `SliderDrag.crossesDetent`,
// `ScrollNudge` — because `LumenApp` compiles only on macOS and a rule that cannot be
// tested is a rule that drifts. This file is the presentation of those, and it should
// stay that thin.
//
// Chrome is zero-chroma by law (docs/00 Law 7): nothing in this file introduces a hue
// that could bias a colour judgement about the photograph.

#if os(macOS)

import AppKit
import LumenCore
import SwiftUI

// MARK: - Theme

enum Lumen {
    // The elevation ladder (design audit, docs/25). The old theme was two grays and
    // a pile of hairlines — panels at signal 0.14 ≈ 1.7% reflectance, an order of
    // magnitude below the 18–25% zone Law 7 (docs/00) and D46 (docs/12 §12.7)
    // prescribe so the surround does not push edits dark and over-cooked. Depth now
    // comes from surface value: the photo sits in the CALMEST (darkest) field,
    // panels sit at the Law 7 floor, wells carve DOWN, controls step UP. Every
    // value zero-chroma, per the same law.

    /// The photo's field — loupe, grid, compare surround. Darkest region, so
    /// nothing in the window is calmer than the photograph's own home.
    static let surroundCanvas = Color(nsColor: NSColor(white: 0.165, alpha: 1))
    /// Status bar, filmstrip — the window's base plane.
    static let windowBase = Color(nsColor: NSColor(white: 0.18, alpha: 1))
    /// Sidebar, develop column, filter bar.
    static let panel = Color(nsColor: NSColor(white: 0.20, alpha: 1))
    /// Carved-down surfaces: histogram well, text fields, slider grooves,
    /// chip-group wells. Depth goes down, not lines.
    static let insetWell = Color(nsColor: NSColor(white: 0.145, alpha: 1))
    /// Buttons and chips at rest / hovered / selected-pressed.
    static let controlSurface = Color(nsColor: NSColor(white: 0.24, alpha: 1))
    static let controlHover = Color(nsColor: NSColor(white: 0.27, alpha: 1))
    static let controlActive = Color(nsColor: NSColor(white: 0.31, alpha: 1))

    static let primaryText = Color(nsColor: NSColor(white: 0.92, alpha: 1))
    static let secondaryText = Color(nsColor: NSColor(white: 0.66, alpha: 1))
    static let tertiaryText = Color(nsColor: NSColor(white: 0.50, alpha: 1))

    /// The slider fill's two states, separated for real (~4:1 between them against
    /// the groove): reading "what did I change" down a panel is the modified
    /// state's whole job, and the audit measured the old opacity pair at ≈1.8:1.
    static let sliderFillRest = Color(nsColor: NSColor(white: 0.42, alpha: 1))
    static let sliderFillModified = Color(nsColor: NSColor(white: 0.72, alpha: 1))

    /// The one accent, used only for state that must be noticed (modified markers,
    /// active tool). Deliberately desaturated so it never competes with the photo.
    static let accent = Color(nsColor: NSColor(red: 0.45, green: 0.58, blue: 0.72, alpha: 1))

    // Legacy names, aliased onto the ladder so the migration can land call site by
    // call site instead of as one unreviewable repaint. New code uses the ladder.
    static let panelBackground = panel
    static let controlBackground = controlSurface
    static let viewerBackground = surroundCanvas
    static let trackColor = Color(nsColor: NSColor(white: 0.34, alpha: 1))
    static let fillColor = Color(nsColor: NSColor(white: 0.62, alpha: 1))
    static let separator = Color(nsColor: NSColor(white: 0.30, alpha: 1))

    // MARK: Tracks that carry their own axis (Law 7's axis exception)

    // Law 7 (docs/00) holds: the chrome is zero-chroma so nothing in the window can
    // bias a colour judgement about the photograph. docs/28 Phase 2 amends it in
    // exactly one place — a control's TRACK may carry chroma if and only if that
    // control's axis IS a colour direction, at no larger a scale than the groove.
    //
    // The rule that makes the exception safe is that it is narrow. Colour every track
    // and none of them reads; colour only the axes that are themselves colour, and
    // every such track becomes self-teaching.
    //
    // THE TONAL REFUSAL IS OVERTURNED, by the person it was protecting. This comment
    // used to say that no tonal control gets stops: Adobe and Capture One both refuse
    // them, and a ramp beside a photograph being judged for exposure is the precise
    // contamination Law 7 exists to prevent. docs/28 Part 7 item 1 recorded that as a
    // call taken on the owner's behalf while he was away — "still his to overrule …
    // one entry in a table". He has since asked for it directly and by name, so it is
    // one entry in a table.
    //
    // And it engages a WEAKER clause than Temp's, which is why the overturn is cheap.
    // The amendment is about CHROMA; a grey ramp introduces none. `exposureStops` is
    // zero-chroma end to end, so it can bias a brightness judgement but not a colour
    // one — and the ends stop short of black and white so the biggest thing a tonal
    // track can do to the surround stays smaller than the histogram already does.
    // Law 7 in docs/00 still names Exposure and Contrast as not permitted; that
    // sentence is now behind the code and wants the amendment docs/00 §3 prescribes.
    //
    // Every table is a static constant, never computed in a `body` from recipe values:
    // a track's colour must not become a reason for a view to observe the edit signal.

    /// Blue below neutral, amber above it, anchored in KELVIN rather than in track
    /// position — see `LumenTrackStop`. What the anchors buy is that the grey stop
    /// lands exactly where the mired axis puts 5500 K, which is about 66% along a
    /// 2000–50000 K track and NOT its midpoint. Stating stops positionally would have
    /// put neutral in the middle, where the track's own arithmetic says 3000 K is.
    ///
    /// The direction is the one every raw editor uses and it is worth saying why, since
    /// it looks backwards: the slider answers "what colour was the light?", so telling
    /// it the light was cool (high K) warms the picture. Right is therefore yellow.
    static let temperatureStops: [LumenTrackStop] = [
        LumenTrackStop(value: 2000, color: Color(red: 0.36, green: 0.50, blue: 0.80)),
        LumenTrackStop(value: 3400, color: Color(red: 0.52, green: 0.62, blue: 0.84)),
        LumenTrackStop(value: 5500, color: Color(red: 0.72, green: 0.72, blue: 0.72)),
        LumenTrackStop(value: 9000, color: Color(red: 0.86, green: 0.78, blue: 0.54)),
        LumenTrackStop(value: 50000, color: Color(red: 0.88, green: 0.72, blue: 0.34)),
    ]

    /// Green to magenta through neutral — the other half of the white balance, and the
    /// axis perpendicular to Temp's. Linear, so the stops sit where they read.
    static let tintStops: [LumenTrackStop] = [
        LumenTrackStop(value: -150, color: Color(red: 0.42, green: 0.72, blue: 0.48)),
        LumenTrackStop(value: 0, color: Color(red: 0.72, green: 0.72, blue: 0.72)),
        LumenTrackStop(value: 150, color: Color(red: 0.76, green: 0.48, blue: 0.78)),
    ]

    /// Dark to light for the bar under each grading wheel, whose range is −1…+1.
    ///
    /// Zero chroma, so this one does not engage the amendment's colour clause at all —
    /// it is a value ramp on a value axis, inside a colour instrument. It stops short of
    /// black and white because a track that reaches the panel's own extremes stops
    /// reading as a track.
    static let wheelLightnessStops: [LumenTrackStop] = [
        LumenTrackStop(value: -1, color: Color(nsColor: NSColor(white: 0.10, alpha: 1))),
        LumenTrackStop(value: 0, color: Color(nsColor: NSColor(white: 0.45, alpha: 1))),
        LumenTrackStop(value: 1, color: Color(nsColor: NSColor(white: 0.88, alpha: 1))),
    ]

    /// Dark to light across Exposure's −5…+5 EV, and the literal case for the
    /// exception: this control's axis IS lightness, so the ramp is not decoration on
    /// the track, it is what the control does, drawn on the thing that does it.
    ///
    /// The ends are 0.11 and 0.82 rather than black and white for the reason
    /// `wheelLightnessStops` gives — a track that reaches the panel's own extremes
    /// stops reading as a track — and for Law 7's: a ramp that cannot bias a colour
    /// judgement can still bias a brightness one, and 180 points of near-white a
    /// hand's width from the photograph is exactly the surround the law is about.
    ///
    /// The middle stop is not redundant. It pins the ramp's own mid-grey to the
    /// control's zero, so the track says "neutral is here" in the same place the tick
    /// does instead of wherever two-stop interpolation happens to put it.
    static let exposureStops: [LumenTrackStop] = [
        LumenTrackStop(value: -5, color: Color(nsColor: NSColor(white: 0.11, alpha: 1))),
        LumenTrackStop(value: 0, color: Color(nsColor: NSColor(white: 0.45, alpha: 1))),
        LumenTrackStop(value: 5, color: Color(nsColor: NSColor(white: 0.82, alpha: 1))),
    ]

    /// The same ramp for Contrast at about half the span, and the shallowness is the
    /// honest part rather than a taste one.
    ///
    /// Exposure's axis is lightness exactly. Contrast's is SLOPE: pushing it right does
    /// not make the picture lighter, it lifts what is above the pivot and drops what is
    /// below, so a dark-to-light ramp is right about the highlights and backwards about
    /// the shadows. One horizontal row of colour cannot say "further apart" — that
    /// needs two values at one x — so this is the nearest true statement the mechanism
    /// can make, at a span that reads as a sibling of the exact ramp rather than as a
    /// second claim to be one. Owner-requested by name alongside Exposure; recorded as
    /// a judgement so the next reader knows it was taken and not missed.
    static let contrastStops: [LumenTrackStop] = [
        LumenTrackStop(value: -100, color: Color(nsColor: NSColor(white: 0.27, alpha: 1))),
        LumenTrackStop(value: 0, color: Color(nsColor: NSColor(white: 0.45, alpha: 1))),
        LumenTrackStop(value: 100, color: Color(nsColor: NSColor(white: 0.66, alpha: 1))),
    ]

    static let rowHeight: CGFloat = 22
    /// THE DEFAULT WIDTH, not the only one — the column is draggable and this is where
    /// it starts.
    ///
    /// 380 rather than 320 because the arithmetic says so. A row spends
    /// `labelWidth + valueWidth + two 6pt gaps` on text no matter how wide the column
    /// is, so every point added to the panel is a point added to the TRACK. At 320 a
    /// ±100 control had 0.90 points of travel per unit — under the ~1.0 at which a
    /// one-pixel tremor stops costing a whole unit, and below Lightroom's narrowest
    /// state. At 380 it is 1.24, past Lightroom's default and next to Capture One's.
    ///
    /// The owner asked for the drag directly: "what if I can have a click and drag? So
    /// if I wanted a specific size, I can click or drag the right side pop-up window
    /// either out more or in more, and the only thing that changes there is the size of
    /// the sliders." That last clause is exactly what happens, and it is a property of
    /// the row's layout rather than a thing anyone had to build.
    static let defaultPanelWidth: CGFloat = 380
    static let minimumPanelWidth: CGFloat = 320
    static let maximumPanelWidth: CGFloat = 520

    /// Kept as the compile-time default for anything that needs a width before a view
    /// exists. Live layout reads `AppState.developPanelWidth`.
    static let panelWidth: CGFloat = defaultPanelWidth
    /// THE CHROME WAS WIDER THAN THE INSTRUMENT, and that is the whole finding.
    ///
    /// At 94 + 52 this row spent 146 points telling you what the slider is called and
    /// what it says, against 142 points of actual control. Fifty-one percent of the
    /// primary instrument of a photo editor was text about the instrument.
    ///
    /// What 142 points cost, measured (docs/30 §2.3): on a ±100 control, 0.71 pt per
    /// unit — one device pixel of pointer travel is 0.70 units, and since `resolve`
    /// snaps to the step there is no stable middle, so **58 of the 201 integer values
    /// could not be landed on by dragging at all.** On Exposure the declared 0.01 EV
    /// step worked out to 0.284 of a device pixel: the track could not express the
    /// resolution its own readout was advertising. The owner reported it as "limited to
    /// being able to touch it up slightly." He was describing arithmetic.
    ///
    /// 86 fits every name that exists — the four denoise labels that forced 94
    /// (`Luminance Contrast` and friends) measure under 84 at 11 pt SF Pro, and 94 was
    /// rounded up from a measurement rather than measured. 44 fits `-5.00`, the longest
    /// readout, with room. With the column's padding at 8 that is 180 pt of track:
    /// **0.90 pt per unit, up 27%**, and 143 of the 201 values become 181 of them.
    ///
    /// It is still short of the 1.0 that would make a ±100 control genuinely precise —
    /// that needs the resizable column in docs/30 Phase D, which takes it past
    /// Lightroom's default. This is the half available without touching layout.
    ///
    /// `SliderDragTests` re-proves the drag's properties parametrically from 100 to
    /// 400 pt of track, so nothing here is pinned to a width.
    static let labelWidth: CGFloat = 86
    static let valueWidth: CGFloat = 44
}

// MARK: - Coloured track stop

/// One stop on a coloured track, anchored to a VALUE rather than to a position.
///
/// The distinction is the whole point. `LumenSlider` owns the value→position map, and
/// for Temp that map is the mired axis, not Kelvin — so a stop stated as "2000 K is
/// blue" places itself correctly, while a stop stated as "the left end is blue" would
/// have to duplicate `SliderTrack`'s arithmetic at the call site and would drift the
/// first time a range moved. The track converts through the same `fraction(of:)` that
/// decides where the thumb is drawn, so the gradient and the thumb cannot disagree.
struct LumenTrackStop {
    let value: Double
    let color: Color
}

// MARK: - Slider

struct LumenSlider: View {
    let title: String
    @Binding var value: Double
    /// Where dragging pins.
    var range: ClosedRange<Double>
    /// Where typing is still accepted. Defaults to `range`.
    var hardRange: ClosedRange<Double>?
    /// How position maps to value along the track. Linear for every control but Temp,
    /// whose Kelvin axis spends 72.9% of its travel on 4.4% of its effect until it is
    /// put on the mired axis `SliderScale.reciprocal` describes.
    var scale: SliderScale = .linear
    var defaultValue: Double = 0
    var step: Double = 1
    var decimals: Int = 0
    /// This control has a meaningful neutral somewhere other than an end, so the
    /// track carries a tick there and you can find your way back to it by eye.
    ///
    /// It no longer decides where the fill starts. That is derived from
    /// `defaultValue` for every control, bipolar or not — the fill reads as a
    /// deviation from neutral in both cases, and a flag was never what distinguished
    /// them.
    var bipolar: Bool = true
    /// Non-nil turns the groove into the control's own axis — see the
    /// `Lumen.temperatureStops` comment for which controls may have one and why almost
    /// none of them may.
    ///
    /// It SUPPRESSES the deviation fill, which is not a side effect but the point: the
    /// fill paints a solid grey capsule from the default to the value, and on a ramped
    /// row it would paint over exactly the information the gradient exists to show —
    /// worst of all on a grey ramp, where fill and track are the same substance.
    ///
    /// WHAT IT MUST NOT DO IS DROP THE SIGNAL. The fill is how a panel answers "what
    /// did I change?" in one sweep of the eye, and trading that away for a prettier
    /// track would be a bad bargain made silently. So the deviation moves rather than
    /// disappears: `modifiedUnderline` draws the same span, in the same place along the
    /// track, as a 2 pt rule beneath the groove instead of a capsule inside it. It is
    /// off entirely at the default, because the question it answers is only ever asked
    /// about a control that has moved. The label, the readout and the section's accent
    /// dot still carry it too; they were never enough on their own, which is why the
    /// fill exists.
    var trackStops: [LumenTrackStop]?
    var wand: (() -> Void)?
    /// What this control does, in one clause, for the tooltip.
    ///
    /// The sentences that used to sit under the panels as prose belong here: a
    /// photographer looking at their photograph is not reading, and a photographer who
    /// stops to ask is hovering. Composed into the label's tooltip by `body` so it does
    /// not fight the double-click hint that was already there.
    var help: String?
    var onEditingChanged: ((Bool) -> Void)?
    /// Injected once at the root (ContentView) and fired by EVERY slider in the app —
    /// which is the point: `onEditingChanged` sat unconsumed for the app's whole life
    /// because it needed wiring at ~90 call sites, and the costs of not knowing a drag
    /// was in flight (a SQLite write plus a canonical-JSON fingerprint per photo per
    /// mouse event, a scope timer restarted per event) were being paid everywhere.
    @Environment(\.sliderGestureChanged) private var sliderGestureChanged
    /// Reported so `KeyDispatcher` hands the arrows back while this row holds focus.
    /// Same shape and the same reason as the gesture hook above: this control does not
    /// observe `AppState`, and it must not start.
    @Environment(\.sliderFocusChanged) private var sliderFocusChanged

    /// What double-clicking the label should do, when writing `defaultValue` is not it.
    ///
    /// Several rows are backed by an OPTIONAL where nil means "auto": Temp and Tint
    /// (nil = as shot), the capture-sharpening overrides (nil = measured), and the
    /// display transform's four overrides (nil = follow the preset). For those, writing
    /// the default through the ordinary setter does not clear the override — it PINS
    /// one. Resetting Temp wrote 5500 K, which flips the section from "As Shot" to
    /// "Custom" and changes the picture for any file not shot at 5500 K; resetting a
    /// transform override pins the current preset's value so the row stays marked
    /// modified and stops following a retuned preset. Every one of those panels already
    /// has a correct clear action; the slider's own gesture contradicted them.
    var onReset: (() -> Void)?

    @State private var isDragging = false
    @State private var dragStartValue: Double = 0
    /// The gesture's gearbox: ⇧ makes the drag fine, and this is what stops the thumb
    /// jumping at the moment the modifier changes. See `FineDrag` in LumenCore, where
    /// the arithmetic and its properties are tested.
    @State private var gearbox = FineDrag(startValue: 0)
    /// The readout's own scrub, kept separate from the track's gesture so the two can
    /// never be half-way through each other.
    @State private var isScrubbing = false
    @State private var scrubGearbox = FineDrag(startValue: 0)
    /// The press that began this gesture was the second click of a double-click, so
    /// `reset()` ran and everything else the gesture delivers is ignored.
    @State private var pressWasReset = false
    @State private var isEditingText = false
    @State private var textValue = ""
    @FocusState private var textFocused: Bool
    /// Keyboard focus on the ROW, which is what the arrows nudge. Distinct from
    /// `textFocused`, which is the readout's text field — while that one holds focus the
    /// dispatcher already stands down for every key, because a text field owns them all.
    @FocusState private var rowFocused: Bool

    private var effectiveHardRange: ClosedRange<Double> { hardRange ?? range }
    private var isModified: Bool { abs(value - defaultValue) > step / 1000 }

    /// Read at the moment a sample is handled rather than carried on the gesture.
    ///
    /// `DragGesture.Value` carries no modifier flags on macOS, and `.modifiers(.shift)`
    /// is the wrong tool: it would make a SEPARATE gesture that can only begin while ⇧
    /// is already held, when the whole point of fine-drag is that you press, you drag,
    /// and then you want precision. `NSEvent.modifierFlags` is the current state of the
    /// keyboard, which is exactly the question.
    private static var shiftIsDown: Bool {
        NSEvent.modifierFlags.contains(.shift)
    }

    /// Write a value the gesture produced, ticking if it just passed the control's rest
    /// position.
    ///
    /// Both halves are guarded. The value write is guarded because a mouse event that
    /// does not cross a step must not publish — that is the per-event cost the drag work
    /// exists to keep off this path — and the tick is guarded by `crossesDetent`, which
    /// is a CROSSING rather than a proximity test: "near the default" is true for many
    /// consecutive samples of a slow drag, and a landmark that rumbles is not a landmark.
    ///
    /// `.alignment` is AppKit's own name for this: the feedback a guide gives when
    /// something snaps to it. On a Mac without a Force Touch trackpad the performer is a
    /// silent no-op, which is the right behaviour and needs no check.
    private func commit(_ next: Double) {
        guard next != value else { return }
        if SliderDrag.crossesDetent(from: value, to: next, detent: defaultValue) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment,
                                                             performanceTime: .now)
        }
        value = next
    }

    /// The readout is a second, finer track.
    ///
    /// Three times the develop column's ~142 points, so crossing the whole range by
    /// scrubbing the number is three deliberate hand movements where the track does it
    /// in one — and ⇧ makes it twelve. That is what makes this the precision instrument
    /// and the track the coarse one, which is the division of labour every pro tool with
    /// a scrubby readout has.
    ///
    /// It carries the control's own `scale`, so scrubbing Temp still moves in mireds and
    /// the number does not sprint at one end of the axis and crawl at the other.
    private var scrubTrack: SliderTrack {
        SliderTrack(width: 426,
                    lowerBound: range.lowerBound, upperBound: range.upperBound,
                    step: step, scale: scale)
    }

    var body: some View {
        HStack(spacing: 6) {
            // An untitled row does not reserve the label column, and that is a fix
            // rather than a nicety. The grading wheels' lightness bar is a `LumenSlider`
            // with an empty title inside a 108-point column: reserving 94 for a label
            // with nothing in it, plus 52 for the readout and two 6-point gaps, asked
            // for 158 points of a 108-point row and left the track squeezed to nothing.
            // The caption under the wheels has been promising that "the bar under each
            // wheel is the zone's own lightness" over a bar too narrow to read. Double
            // click still resets it — the track's own gesture does that.
            if !title.isEmpty {
                Text(title)
                    .font(.lumenBody)
                    .foregroundStyle(isModified ? Lumen.primaryText : Lumen.secondaryText)
                    .frame(width: Lumen.labelWidth, alignment: .leading)
                    .lineLimit(1)
                    // SHRINK RATHER THAN TRUNCATE. The 86pt column was measured against
                    // 11pt labels and the type scale moved them to 12, which puts the
                    // longest name in the app — "Luminance Contrast", in Noise Reduction
                    // — a few points over. A truncated label is the defect this column
                    // was widened to 94 to avoid in the first place: two different
                    // controls reading "Luminance D…" and "Luminance C…", indistinguishable
                    // without a hover. A name that renders 8% smaller on four rows out of
                    // ninety-two is a far cheaper price than eight points of track on all
                    // of them, and it degrades gracefully if a longer name is ever added.
                    .minimumScaleFactor(0.86)
                    .onTapGesture(count: 2) { reset() }
                    // COMPOSED, not layered. The row carries a `.help` too, and an outer
                    // `.help` is SHADOWED wherever an inner one covers — so hovering a
                    // slider's NAME, which is the most natural place to point when
                    // asking "what is this", was showing only the reset hint. That
                    // matters more than it sounds: docs/30's plan retires fifty-nine
                    // prose rows by moving their text onto exactly this tooltip, and the
                    // strategy would have silently failed over a third of the row.
                    .help(help.map { "\(title) — \($0)\n\nDouble-click to reset" }
                          ?? "\(title) — double-click to reset")
            }

            track

            valueField

            if let wand {
                Button(action: wand) {
                    Image(systemName: "wand.and.stars")
                        .font(.lumenCaption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Lumen.secondaryText)
                .lumenClickCursor()
                .help("Set \(title) automatically")
            }
        }
        .frame(height: Lumen.rowHeight)
        // AIR AROUND THE ROW, and it belongs to the row rather than to each of the
        // fourteen stacks that hold one.
        //
        // The owner: "everything is super back to back to back, so I definitely give a
        // little bit more spacing in between sliders as well as components." Every
        // panel stacks its rows at `spacing: 2`, so raising the gap where it is written
        // means fourteen files agreeing, and a fifteenth panel would arrive tight. Two
        // points inside the hover fill and one outside it is the whole change: a 26pt
        // target instead of 22, a 4pt gutter between adjacent fills instead of 2, and
        // the pitch up from 24 to 30. The groove, the thumb and the two text columns are
        // untouched — this is space around the instrument, not a resizing of it.
        .padding(.vertical, 2)
        // THE ROW ANSWERS THE KEYBOARD, and — since the owner's third review — no longer
        // answers the pointer.
        //
        // It gained a hover fill in the second pass because it had no pointer state of
        // any kind, and lost it again in the third: "I would remove a bunch of the hover
        // effects, like hovering over the white balance or the temperature or tint." A
        // groove with a thumb in it already says what it is, and eleven rows lighting up
        // in sequence as the pointer crosses the panel is motion beside a colour
        // decision. `LumenFocus.swift` holds the full argument.
        //
        // Focus keeps the surface, because focus has nothing else to show it — and it is
        // there instead of the accent ring the owner reported on sight: the ring fired on
        // mouse-DOWN, so every drag of every slider began with a blue border.
        .lumenFocusSurface(focused: rowFocused)
        .padding(.vertical, 1)
        // KEYBOARD NUDGE (docs/28 Phase 7), and the three things it needed.
        //
        // One: the row is focusable, with the system's own ring turned off. macOS draws
        // a blue halo sized for standard AppKit controls, and on a 4-point groove in a
        // zero-chroma panel that reads as a bug rather than as state; the surface above
        // carries the state instead.
        //
        // Two: the dispatcher has to stand down. Its NSEvent monitor sits in FRONT of
        // the responder chain, so without `sliderFocusChanged` telling it a slider holds
        // focus, `onKeyPress` below would never be reached — the arrow would page to the
        // next photograph and the focused control would sit there looking broken. The
        // report goes through the environment rather than through `AppState`, because
        // this control does not observe `AppState` and must not start.
        //
        // Three: focus has to be releasable. Escape drops it, and so does clicking
        // anything else; the surface fill is what makes the state visible in the
        // meantime.
        .focusable()
        .focusEffectDisabled()
        .focused($rowFocused)
        .onChange(of: rowFocused) { _, focused in
            sliderFocusChanged(focused)
        }
        .onDisappear {
            // A panel switch removes the row without the focus ever changing, so the
            // count would never come back down and the arrows would stop paging
            // photographs for the rest of the session. `noteSliderFocus` floors at zero,
            // so reporting a blur that already happened is harmless.
            if rowFocused { sliderFocusChanged(false) }
        }
        .onKeyPress(.leftArrow) { nudge(-1) }
        .onKeyPress(.rightArrow) { nudge(1) }
        .onKeyPress(.escape) {
            rowFocused = false
            return .handled
        }
        // ⌥-SCROLL (docs/28 Phase 6 item 26), which is the same nudge without the focus.
        // Placed on the whole row, not on the track, because the thing being aimed at is
        // "the slider under the pointer" and the label and the readout are part of it.
        // The gate that stops it eating the develop column's own scrolling is in
        // `LumenScrollNudge.swift`; everything about it that a Mac is not needed to run
        // is `ScrollNudge` in LumenCore.
        .lumenOptionScrollNudge { wheelNudge($0) }
    }

    /// One arrow press, ten under ⇧.
    ///
    /// The arithmetic is `SliderTrack.nudged` in LumenCore, where it is tested: one step
    /// per press, clamped to the SOFT range like a drag and unlike typing, and always
    /// landing on the step. ⇧ multiplies the COUNT rather than switching to another
    /// quantum, so ten presses and one shifted press are the same number.
    ///
    /// KEY REPEAT IS NOT CLAIMED, and that is deliberate for now: `onKeyPress` defaults
    /// to the `.down` phase, so holding an arrow nudges once. It makes the gesture
    /// bracket below correct and prompt — one press is one undo step and the deferred
    /// per-photo write lands on release, like a drag's. Adding `phases: [.down, .repeat]`
    /// would give hold-to-sweep and would have to stop bracketing per press, leaning on
    /// `AppState`'s 8-second silence watchdog to land the write instead; that is a real
    /// trade (a longer window in which a crash loses the edit) and belongs with an owner
    /// who has said he wants to hold the key.
    ///
    /// Returns `.handled` even when the value did not move, because it did not move for
    /// a reason — the control is at the end of its range — and letting the key fall
    /// through would page to the next photograph out from under a focused slider.
    private func nudge(_ direction: Int) -> KeyPress.Result {
        let steps = direction * (Self.shiftIsDown ? 10 : 1)
        // `scrubTrack` for its BOUNDS, STEP and SCALE. A nudge is denominated in steps
        // and never divides by width, so which width that track carries is irrelevant
        // here; building a third `SliderTrack` to say so would be one more place for the
        // range and the step to drift apart.
        let next = scrubTrack.nudged(value, steps: steps)
        guard next != value, next.isFinite else { return .handled }
        onEditingChanged?(true)
        sliderGestureChanged(true)
        commit(next)
        onEditingChanged?(false)
        sliderGestureChanged(false)
        return .handled
    }

    /// One wheel click, ten under ⇧ — the arrows, without having to focus the row first.
    ///
    /// The magnitude is `SliderTrack.nudged` again, deliberately, so there is one answer
    /// in the app to "how much is one deliberate tick of this control worth" and it is
    /// the same whether it arrives from a key or from a wheel. `ScrollNudge` in LumenCore
    /// is what turns a trackpad's continuous points into those clicks, and its header
    /// states the trade in the constant.
    ///
    /// THE TWO GESTURE HOOKS PART COMPANY HERE, and this is the only place in the file
    /// where they do. `onEditingChanged` brackets one edit, and a tick IS one complete
    /// edit, so it closes like a key press's. `sliderGestureChanged` is the DEFERRAL, and
    /// it is deliberately left open: a wheel has no release to close it with — the exact
    /// sentence docs/28 item 26 was blocked on — so closing it per tick would make every
    /// tick a SQLite write plus four whole-recipe JSON codings for the fingerprint, plus
    /// a scope re-bin, which is the entire cost the deferral exists to avoid. Repeated
    /// `true` refreshes `AppState.lastGestureEventAt` rather than re-latching, and the
    /// 8-second silence watchdog lands the write once, after the scrolling stops.
    ///
    /// THE OWNER FOUND EIGHT SECONDS LONG — the previous note here ended "it is the
    /// change to make first if the owner finds eight seconds long", and his fourth
    /// round found it exactly: a wheel-scrubbed Shadows left a 1277 px draft standing
    /// on a zoomed loupe for the whole watchdog window, which reads as "the blur
    /// never goes away". So the row closes its own gesture after half a second of
    /// wheel silence: one task per row that is actually being scrolled (allocated on
    /// use, not ninety timers idling), cancelled and re-armed per tick, closing
    /// through the same `sliderGestureChanged(false)` a drag's release uses — which
    /// lands the deferred catalog write, the scope re-bin and the settle at once.
    /// The 8-second watchdog stays as the crash-safety net behind it, and the
    /// known cost is narrow: begin a DRAG somewhere within the half second and the
    /// stale closer flushes once mid-gesture; the drag's next event re-latches, and
    /// one early settle is the whole price.
    private func wheelNudge(_ clicks: Int) {
        let next = scrubTrack.nudged(value, steps: clicks * (Self.shiftIsDown ? 10 : 1))
        guard next != value, next.isFinite else { return }
        onEditingChanged?(true)
        sliderGestureChanged(true)
        commit(next)
        onEditingChanged?(false)
        wheelSettleCloser?.cancel()
        wheelSettleCloser = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            sliderGestureChanged(false)
        }
    }

    /// The half-second wheel-silence closer above. `@State` so a re-body cannot leak
    /// an armed task, and per-row so only rows actually being scrolled ever hold one.
    @State private var wheelSettleCloser: Task<Void, Never>?

    // How close to the thumb counts as grabbing it rather than pressing the track is
    // `SliderDrag.thumbGrabRadius`, in LumenCore. It is not restated here as a second
    // constant: two numbers that have to agree and can drift apart is the shape most of
    // this file's history has had. It is 11 pt and stays there — a grab radius wider
    // than the thumb is forgiveness, and the thumb just got smaller.

    // GROOVE 5, THUMB 9 — a correction, not a first attempt.
    //
    // 4 and 10 shipped, read as a thin line with a dot on it, and went to 6 and 12. That
    // overshot in the other direction: the owner's words were "a little bit too thick"
    // and "I don't like the super circular sliders". 5 and 9 is what he picked when the
    // options were put side by side, and it is the proportion the complaint describes —
    // the handle is 1.8 times the groove rather than 2.5, so it reads as a knob set into
    // a channel instead of a bead threaded onto a wire. The row is 22 pt, so nothing
    // here is fighting for space; this is all proportion.
    //
    // Named rather than inlined for one reason. The thumb's offset must be exactly half
    // its diameter or the drawn handle sits off the value it reports — a silent,
    // pixel-scale lie in the one place this app cannot afford one — and that used to be
    // two literals a reader had to check against each other by eye.
    private static let grooveHeight: CGFloat = 5
    private static let thumbDiameter: CGFloat = 9
    private static let thumbDraggingDiameter: CGFloat = 11
    /// Tall enough to clear the groove's lip at both ends, short enough that the thumb
    /// covers it whole when the control is sitting on its default.
    private static let neutralMarkHeight: CGFloat = 8

    /// The groove, whichever substance fills it, finished as a WELL: a hard shadow
    /// under the near lip and a trace of light on the far one.
    ///
    /// This is `lumenWell()` from LumenSurface, which was written as exactly this idea
    /// generalised — but that one is built on `RoundedRectangle`, and a continuous
    /// rounded rectangle at radius = half its height is visibly flatter at the caps than
    /// a capsule. At 5 pt tall the stroke would part company with the fill at both ends,
    /// so the groove keeps its own capsule and the two agree by construction.
    ///
    /// A 1 pt line, not the soft wash the coloured tracks used to carry alone. A wash
    /// shades a surface; an edge is what tells the eye where the surface stops, and the
    /// groove had no edge at all — which is the whole finding of LumenSurface's header,
    /// applied to the control it says the idea came from.
    private func carvedGroove<Content: View>(_ filled: Content) -> some View {
        filled
            .overlay(
                Capsule().strokeBorder(
                    LinearGradient(colors: [Color.black.opacity(0.5),
                                            Color.white.opacity(0.07)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1))
            .frame(height: Self.grooveHeight)
    }

    /// The deviation, drawn where a gradient track cannot spare the room — see
    /// `trackStops`. Same span and same anchoring as the fill, so the two states of the
    /// app say "you changed this much, from here" in the same shape.
    private func modifiedUnderline(fraction: Double,
                                   zeroFraction: Double,
                                   width: CGFloat) -> some View {
        Capsule()
            .fill(Lumen.sliderFillModified)
            // A floor of 2, not 1: a one-point stub under a 5 pt groove reads as a
            // rendering artefact rather than as a mark, and this only draws at all when
            // the control has moved.
            .frame(width: max(abs(fraction - zeroFraction) * width, 2), height: 2)
            .offset(x: min(fraction, zeroFraction) * width, y: 4.5)
    }

    private var track: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            // The drag's arithmetic, as the value `SliderDragTests` checks rather than
            // as expressions inlined into a gesture closure in a target with no tests.
            let geometryOfDrag = SliderTrack(width: Double(width),
                                             lowerBound: range.lowerBound,
                                             upperBound: range.upperBound,
                                             step: step,
                                             scale: scale)
            // Where the thumb is DRAWN comes from the same object that decides what a
            // drag is worth. These were two separate expressions, both linear, and
            // agreeing only because nothing was non-linear yet; a mired track would
            // have drawn the thumb somewhere the drag would not have put it.
            let fraction = geometryOfDrag.fraction(of: value)
            let zeroFraction = geometryOfDrag.fraction(of: defaultValue)
            let thumb = isDragging ? Self.thumbDraggingDiameter : Self.thumbDiameter
            ZStack(alignment: .leading) {
                if let trackStops {
                    // The groove IS the information on these rows. Stops are placed by
                    // the same `fraction(of:)` that decides where the thumb is drawn, so
                    // a mired-axis Temp track puts its neutral where the control puts
                    // 5500 K rather than at the halfway mark.
                    carvedGroove(
                        Capsule()
                            .fill(LinearGradient(
                                stops: trackStops.map {
                                    Gradient.Stop(color: $0.color,
                                                  location: geometryOfDrag.fraction(of: $0.value))
                                },
                                startPoint: .leading, endPoint: .trailing))
                            // Body shading, now that `carvedGroove` draws the lip. It is
                            // lighter than the 0.30 this used to carry alone, because a
                            // wash strong enough to stand in for an edge was muddying
                            // the top third of every stop it fell on — most visibly on
                            // the exposure ramp, whose dark end it pushed to near black.
                            .overlay(Capsule().fill(LinearGradient(
                                colors: [Color.black.opacity(0.18), Color.black.opacity(0)],
                                startPoint: .top, endPoint: .bottom))))
                } else {
                    // The groove CARVES DOWN into the panel (a well, not a painted-on
                    // stripe): the darker top edge is the light coming from above, the
                    // same depth cue the histogram well already used.
                    //
                    // Three stops rather than two, and the middle one is where the depth
                    // is. A straight ramp top to bottom shades a tube; a dark band held
                    // tight against the top edge and released by 45% of the way down is
                    // a shadow CAST by the lip, which is what a channel milled into a
                    // surface actually looks like.
                    carvedGroove(
                        Capsule()
                            .fill(LinearGradient(
                                stops: [Gradient.Stop(
                                            color: Color(nsColor: NSColor(white: 0.075, alpha: 1)),
                                            location: 0),
                                        Gradient.Stop(
                                            color: Color(nsColor: NSColor(white: 0.128, alpha: 1)),
                                            location: 0.45),
                                        Gradient.Stop(color: Lumen.insetWell, location: 1)],
                                startPoint: .top, endPoint: .bottom)))
                }
                // Fill from the default toward the value: the eye reads the deviation,
                // not the absolute position. Where the fill STARTS is the lower of the
                // two, always — what decides it is where the default sits, not whether
                // the range straddles zero. Consulting `bipolar` here collapsed to
                // `min(fraction, fraction)` on every unipolar slider, which drew the
                // bar starting at the thumb and running away from the default instead
                // of toward it.
                //
                // The modified state now SEPARATES for real: the audit measured the
                // old 0.5→0.9 opacity change at ≈1.8:1 against the track — invisible,
                // in the one place a develop tool must answer "what did I change?"
                // at a glance.
                //
                // Not drawn at all on a ramped track — it moves under the groove
                // instead of vanishing. See `trackStops`.
                if trackStops == nil {
                    Capsule()
                        .fill(isModified ? Lumen.sliderFillModified : Lumen.sliderFillRest)
                        // A SHEEN, not a second colour. The two fill greys carry the
                        // measured 4:1 rest/modified separation and nothing here is
                        // allowed to disturb it, so the form is added as a symmetric
                        // light-over-dark pass that leaves the mean where it was: the
                        // bar stops reading as a flat swatch dropped in the groove and
                        // starts reading as something round sitting in it.
                        .overlay(Capsule().fill(LinearGradient(
                            colors: [Color.white.opacity(0.16), Color.black.opacity(0.16)],
                            startPoint: .top, endPoint: .bottom)))
                        .frame(width: max(abs(fraction - zeroFraction) * width, 1),
                               height: Self.grooveHeight)
                        .offset(x: min(fraction, zeroFraction) * width)
                } else if isModified {
                    modifiedUnderline(fraction: fraction,
                                      zeroFraction: zeroFraction,
                                      width: width)
                }
                // The neutral mark. Sits under the thumb so the thumb covers it when
                // the control is at its default, which is exactly when you do not
                // need to be told where the default is.
                if bipolar && zeroFraction > 0.001 && zeroFraction < 0.999 {
                    if trackStops == nil {
                        Rectangle()
                            .fill(Lumen.separator)
                            .frame(width: 1, height: Self.neutralMarkHeight)
                            .offset(x: zeroFraction * width - 0.5)
                    } else {
                        // A 0.30-grey line vanishes against a saturated stop, and which
                        // stop it lands on depends on the photograph's as-shot neutral —
                        // so the mark carries its own contrast instead of assuming the
                        // background: a dark halo under a light line reads on the green
                        // end and the magenta end alike.
                        Rectangle()
                            .fill(Color.black.opacity(0.45))
                            .frame(width: 3, height: Self.neutralMarkHeight)
                            .offset(x: zeroFraction * width - 1.5)
                        Rectangle()
                            .fill(Color.white.opacity(0.85))
                            .frame(width: 1, height: Self.neutralMarkHeight)
                            .offset(x: zeroFraction * width - 0.5)
                    }
                }
                // The handle. Sizes and the reason for them are with the constants;
                // what is here is that it is LIT rather than filled.
                //
                // A flat disc of one grey is a token on a board — you cannot tell which
                // way is up, so nothing about it says "grip me". Bright along the top,
                // falling to 0.78 at the bottom, with a rim that is a highlight where
                // the light lands and a dark edge where it does not, and the same disc
                // reads as a machined knob standing off the panel. That was the owner's
                // "make the sliders a bit more lively", answered in the one element he
                // actually pushes.
                //
                // The offset is half the diameter, and it is derived from the diameter
                // rather than written beside it — the two must not be able to disagree.
                Circle()
                    .fill(LinearGradient(
                        colors: [Color(nsColor: NSColor(white: 0.99, alpha: 1)),
                                 Color(nsColor: NSColor(white: 0.78, alpha: 1))],
                        startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(0.55),
                                                Color.black.opacity(0.22)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.5))
                    .frame(width: thumb, height: thumb)
                    .offset(x: fraction * width - thumb / 2)
                    .shadow(color: .black.opacity(0.5), radius: isDragging ? 3 : 1.5, y: 0.5)
            }
            .frame(height: Lumen.rowHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        // RELATIVE from where the drag began, not absolute from the
                        // cursor. Absolute positioning means the value snaps to
                        // wherever you touch the track, so there is no such thing as
                        // picking up the thumb — every adjustment starts by throwing
                        // the value somewhere else, and a small correction near the end
                        // of a slider is impossible because the last few pixels are the
                        // last few percent. `dragStartValue` was already being captured
                        // here and then never read, which is the shape of an intention
                        // that did not land.
                        //
                        // Grab the thumb and it moves with the cursor. Press the track
                        // and the value jumps there once, then moves with the cursor
                        // from there — the jump is what makes a click on the track do
                        // something, and anchoring afterwards is what stops it fighting
                        // you for the rest of the gesture.
                        if !isDragging {
                            isDragging = true
                            // The second press of a double-click resets — read off the
                            // AppKit event, because a TapGesture(count: 2) behind a
                            // minimumDistance-0 drag never fires: the drag claims the
                            // press first, and the first click has already jumped the
                            // value to the press point. The owner double-clicked a
                            // track, watched nothing reset, and was right. Through
                            // `reset()`, not `value = defaultValue`: the optional-backed
                            // rows clear their override in `onReset`, and writing the
                            // default PINS one (the header's Temp-wrote-5500K story).
                            // The rest of this gesture is inert — a reset is not the
                            // start of a drag.
                            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                                pressWasReset = true
                                reset()
                                return
                            }
                            let thumbX = fraction * Double(width)
                            if SliderDrag.grabsThumb(
                                pressX: Double(drag.startLocation.x), thumbX: thumbX) {
                                dragStartValue = value
                            } else {
                                dragStartValue = geometryOfDrag.valueAtPress(
                                    x: Double(drag.startLocation.x))
                                value = dragStartValue
                            }
                            // The gesture's gearbox, opened at the press. Coarse it is
                            // arithmetically identical to the old direct call — see
                            // `FineDragTests` — so this is not a new drag model, it is
                            // the same one with an anchor that ⇧ can move.
                            gearbox = FineDrag(startValue: dragStartValue,
                                               fine: Self.shiftIsDown)
                            onEditingChanged?(true)
                            sliderGestureChanged(true)
                        }
                        if pressWasReset { return }
                        let travelled = Double(drag.location.x - drag.startLocation.x)
                        // ⇧ read off the live AppKit modifier flags rather than from the
                        // gesture, because SwiftUI's `DragGesture.Value` carries no
                        // modifiers on macOS and `.modifiers(.shift)` would make this a
                        // DIFFERENT gesture that only starts while ⇧ is held — which is
                        // the opposite of what fine-drag is for. You press, you drag, and
                        // THEN you want precision.
                        //
                        // `resolving`, not the mutating form: a `@State` write is a view
                        // invalidation, so storing the gearbox every event would publish
                        // on every event of every drag — including the majority that do
                        // not move the value because the pointer has not crossed a step.
                        // Both writes below are guarded for the same reason.
                        let out = gearbox.resolving(track: geometryOfDrag,
                                                    travelled: travelled,
                                                    fine: Self.shiftIsDown)
                        if let changed = out.changedGear { gearbox = changed }
                        commit(out.value)
                    }
                    .onEnded { drag in
                        // THE RELEASE IS A SAMPLE, and it is the last one.
                        //
                        // This used to set a flag and throw the location away, which
                        // made what a gesture was worth depend on whether a motion
                        // event happened to beat the mouse-up. A relative drag reads
                        // the pointer's current offset from the press, so dropping the
                        // interior of a gesture is harmless — but dropping its END is
                        // not, and the end is exactly what gets dropped when the main
                        // actor is behind: AppKit coalesces the queued motion events
                        // and the button comes up before the survivor is delivered.
                        // Reading the release closes it: drag to 100 and the control
                        // reads 100, however much of the gesture the app missed.
                        if pressWasReset {
                            // `reset()` already ran and closed its own edit events;
                            // this release belongs to no drag.
                            pressWasReset = false
                            isDragging = false
                            return
                        }
                        if isDragging {
                            let travelled = Double(drag.location.x - drag.startLocation.x)
                            // Through the same gearbox as every motion sample, because a
                            // release IS a motion sample. Resolving it against
                            // `dragStartValue` directly would throw away every rebase ⇧
                            // made during the gesture and land the drag where a coarse
                            // one would have — the exact class of bug the release-is-a-
                            // sample rule exists to prevent, arriving from the other end.
                            let settled = gearbox.resolving(track: geometryOfDrag,
                                                            travelled: travelled,
                                                            fine: Self.shiftIsDown).value
                            commit(settled)
                        }
                        isDragging = false
                        onEditingChanged?(false)
                        sliderGestureChanged(false)
                    }
            )
            // No `.onTapGesture(count: 2)` here any more: behind a minimumDistance-0
            // drag it never fired (the drag claims the press), which is how "double-
            // click to reset" shipped as a promise the track did not keep. The reset
            // lives inside the drag's own press handling above, where the click count
            // is actually visible.
        }
        .frame(height: Lumen.rowHeight)
    }

    private var valueField: some View {
        Group {
            if isEditingText {
                TextField("", text: $textValue)
                    .textFieldStyle(.plain)
                    .font(.lumenNumeric)
                    .multilineTextAlignment(.trailing)
                    .focused($textFocused)
                    .onSubmit { commitText() }
                    .onExitCommand { isEditingText = false }
            } else {
                // TABULAR FIGURES ON SF PRO, not SF Mono. The app mixed two typefaces
                // at 23 sites — a second family, a different x-height, inches from the
                // label beside it — to buy a property `.monospacedDigit()` gives on the
                // body face: a fixed digit advance so a scrubbed number does not jitter
                // as it counts. `.contentTransition(.numericText())` is the other half:
                // the value now counts rather than snapping, which is the difference
                // between a readout and an instrument.
                Text(formatted)
                    .font(isScrubbing ? .lumenNumericStrong : .lumenNumeric)
                    .contentTransition(.numericText())
                    .foregroundStyle(isModified ? Lumen.primaryText : Lumen.secondaryText)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        textValue = formatted
                        isEditingText = true
                        textFocused = true
                    }
                    // THE CURSOR IS THE ADVERTISEMENT. This readout is the app's
                    // PRECISION instrument — 2.13 points per unit against the track's
                    // 0.71, three times finer — and its only disclosure was a tooltip
                    // after a one-second hover delay. Meanwhile it is a 44x22 target
                    // against the coarse track's 180x22, so the app gave the blunt tool
                    // four times the hit area of the fine one and told nobody the fine
                    // one existed. Every other tool in this category — Figma, Resolve,
                    // After Effects, Photoshop, Capture One — says it with the cursor.
                    .lumenScrubCursor()
                    // SCRUB THE NUMBER (docs/28 Phase 6). `minimumDistance: 3` is what
                    // keeps tap-to-type alive: a press that does not travel three points
                    // is never claimed by this gesture, so the tap above still fires and
                    // the field still opens. At zero the drag would swallow every click
                    // and typing a value would become impossible.
                    .gesture(
                        DragGesture(minimumDistance: 3)
                            .onChanged { drag in
                                if !isScrubbing {
                                    isScrubbing = true
                                    scrubGearbox = FineDrag(startValue: value,
                                                            fine: Self.shiftIsDown)
                                    onEditingChanged?(true)
                                    sliderGestureChanged(true)
                                }
                                let travelled = Double(drag.location.x
                                                       - drag.startLocation.x)
                                let out = scrubGearbox.resolving(
                                    track: scrubTrack, travelled: travelled,
                                    fine: Self.shiftIsDown)
                                if let changed = out.changedGear { scrubGearbox = changed }
                                commit(out.value)
                            }
                            .onEnded { drag in
                                guard isScrubbing else { return }
                                // A release is a sample here for the same reason it is
                                // one on the track: the last motion event is exactly
                                // what gets dropped when the main actor is behind.
                                let travelled = Double(drag.location.x
                                                       - drag.startLocation.x)
                                commit(scrubGearbox.resolving(
                                    track: scrubTrack, travelled: travelled,
                                    fine: Self.shiftIsDown).value)
                                isScrubbing = false
                                onEditingChanged?(false)
                                sliderGestureChanged(false)
                            }
                    )
                    .help("Drag to adjust, click to type — ⇧ for fine")
            }
        }
        .frame(width: Lumen.valueWidth, alignment: .trailing)
    }

    private var formatted: String {
        String(format: "%.\(decimals)f", value)
    }

    // There is deliberately no `clamp` here any more either, for the same reason:
    // where a value sits on the track is `SliderTrack.fraction(of:)`, which clamps in
    // position space because that is the only space a non-linear axis can be pinned in.
    //
    // There is deliberately no `snap` here any more. The clamp-then-snap the drag
    // applies is `SliderTrack.resolve`, in LumenCore, where it is tested — and a second
    // copy of it sitting in this file is how the two would come to round differently
    // without anything being able to notice.

    private func reset() {
        if let onReset {
            onReset()
            return
        }
        onEditingChanged?(true)
        sliderGestureChanged(true)
        value = defaultValue
        onEditingChanged?(false)
        sliderGestureChanged(false)
    }

    private func commitText() {
        isEditingText = false
        // Through `SliderEntry` in LumenCore, which is where the grammar and its refusals
        // are tested. It accepts arithmetic — `+= 0.3`, `-= 0.2`, `* 2`, `/ 2` (docs/28
        // Phase 6, claiming one of D45's deliberate omissions) — and a bare number is
        // still absolute, INCLUDING a negative one: the readout pre-fills and selects, so
        // replacing it with "-40" is how a photographer sets −40 on a ±100 control, and
        // Figma's leading-minus-is-relative grammar would have made that a silent −10.
        //
        // It also refuses what `Double(_:)` would happily hand over. `Double("nan")`,
        // `Double("inf")` and `Double("1e999")` all parse, and the clamp below does NOT
        // filter them: `max(NaN, lo)` is NaN, because every comparison against NaN is
        // false. A NaN reaching the recipe is not a bad render, it is data loss —
        // `JSONEncoder` refuses non-conforming floats, so the canonical JSON collapses to
        // "{}" and that is what gets written to the sidecar, erasing the photo's edit
        // from the copy that exists to survive losing the catalog.
        guard let parsed = SliderEntry.value(of: textValue, current: value) else { return }
        // Typing reaches the hard limit; dragging does not. That asymmetry is what
        // makes soft limits helpful instead of restrictive.
        onEditingChanged?(true)
        sliderGestureChanged(true)
        value = min(max(parsed, effectiveHardRange.lowerBound),
                    effectiveHardRange.upperBound)
        onEditingChanged?(false)
        sliderGestureChanged(false)
    }
}

// MARK: - Section header

struct LumenSectionHeader: View {
    let title: String

    /// An SF Symbol drawn between the chevron and the title, or nil for a header that
    /// does not have one.
    ///
    /// **The default is nil and has to stay nil.** There are 38 `LumenSectionHeader(…)`
    /// call sites in eight files today — the export sheet's eight, the mask panel's
    /// nine, the ingest sheet's four — and almost none of them names a
    /// `WorkspaceSection`, because most are not sections in that sense at all: "Format",
    /// "Naming", "Verify", "Watermark". Making this required would have been a
    /// thirty-eight-site edit to put icons on six headers, and thirty-seven of those
    /// sites would have had to invent a glyph for a heading that does not want one.
    ///
    /// Declared second because that is where it reads — the glyph belongs to the title
    /// it sits beside. The position is otherwise free: the memberwise initialiser takes
    /// its arguments in declaration order and every existing site already passes them
    /// that way, so a defaulted parameter inserted anywhere in this list still compiles
    /// at all of them.
    ///
    /// Only the workspace accordion passes it (`WorkspaceSectionView`), and that is the
    /// intent rather than a first instalment: a glyph per section is a fact about
    /// `WorkspaceSection`, which is where the table lives (`DevelopColumn.swift`), and a
    /// header a sheet composes by hand has no such fact to draw.
    var symbol: String? = nil

    var isExpanded: Binding<Bool>?
    var isModified: Bool = false
    var onReset: (() -> Void)?
    /// What this header's Reset CLEARS, for the hover — because "Reset" alone is not
    /// an answer when a section holds two decisions. The Crop header's Reset clears
    /// crop, angle and flip together while Original in the ratio menu brings only the
    /// frame back; a photographer deciding which to press is exactly who is hovering.
    /// Nil for the sections where Reset's scope is the obvious one.
    var resetHelp: String? = nil
    /// The space that says "a new section begins here" — and it is what replaced the
    /// hairline that used to say it.
    ///
    /// Design audit §1.1: the pre-Yosemite AppKit read comes from partitioning flat grey
    /// with 1-pixel rules. Lightroom, Capture One and Darkroom all delineate by surface
    /// value and space, and keep lines for instruments. So the `Divider()` between every
    /// pair of sections in Colour, Look and Masks is gone and this padding is the
    /// boundary instead.
    ///
    /// 20 pt is a section boundary. A disclosure nested INSIDE a section passes 10: it
    /// is a fold, not a border, and giving it the full rhythm would make a sub-heading
    /// louder than the heading above it.
    ///
    /// It was 16, and 16 was not enough on its own — "everything is super back to back
    /// to back … I get a fatigue when I scroll down because everything is so close
    /// together." Space is now one of three levers rather than the only one: the
    /// workspace accordion wraps each section in a card and passes **0** here, because a
    /// card's own edge and the gap between cards say "new area" far louder than any
    /// amount of blank panel could. This value is what the hand-composed headers inside
    /// those cards — Colour's, Look's, the mask editor's — still use to separate
    /// themselves from each other.
    var topRhythm: CGFloat = 20

    /// TAKES THE CLICK INSTEAD OF THE BINDING, and reports whether ⌥ was down.
    ///
    /// A `Binding<Bool>` can express "this section is open" and cannot express what an
    /// accordion needs, which is that opening one section closes its siblings unless a
    /// modifier says otherwise. That rule is `SectionExpansion.afterClick` in LumenCore,
    /// it operates on the whole expanded SET, and no per-section binding can reach it.
    ///
    /// So when this is present the header reports the click and lets the caller decide;
    /// `isExpanded` then only draws the chevron and may be a constant. Absent, the
    /// binding toggles itself exactly as before — which is what the 44 existing call
    /// sites do and why this is an addition rather than a change.
    ///
    /// The flag is read from `NSEvent.modifierFlags` at click time rather than carried
    /// in, the same way `LumenSlider` reads ⇧ for its fine drag: SwiftUI's tap gestures
    /// do not report modifiers, and threading a monitor through every header to learn
    /// one bit would cost more than reading it costs.
    /// The flag is the MODIFIER, not a policy. It said `keepingOthersOpen`, which made
    /// this header assert what ⌥ means for an accordion it knows nothing about — and
    /// when that policy inverted, the name became a lie in a file that had no reason to
    /// care. A header reports what the hand did; the column decides what it meant.
    var onToggle: ((_ optionHeld: Bool) -> Void)?

    private static var optionIsDown: Bool {
        NSEvent.modifierFlags.contains(.option)
    }

    /// Row-local, so a pointer crossing one header invalidates one header. Hover state
    /// never goes anywhere observable — see `CommandState` for what a per-event publish
    /// costs a drag.
    @State private var hovering = false

    /// Whether a click on this header means anything. False for a header that is only
    /// a group label — no chevron, no accordion callback — in which case the hover fill
    /// and the pointing hand stay off: the pointer treatment is the row's claim to be a
    /// control, and this row is not one. Reset still fades in on hover regardless,
    /// because the Reset BUTTON is a control whichever kind of header carries it.
    private var isInteractive: Bool { isExpanded != nil || onToggle != nil }

    var body: some View {
        HStack(spacing: 4) {
            if let isExpanded {
                Button {
                    toggle()
                } label: {
                    // ONE GLYPH, ROTATED — not two glyphs swapped.
                    //
                    // "The animation for the open and close for the chevrons are not
                    // great", and this is the half of it that was not an animation at
                    // all: `chevron.down` and `chevron.right` are different symbols, so
                    // every `withAnimation` around the accordion had nothing to
                    // interpolate and the arrow simply cut from one to the other while
                    // the section beneath it moved. Rotating a single chevron gives the
                    // enclosing animation a continuous property to carry, so the hinge
                    // now turns at the speed the drawer opens.
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                        // An 11x10 target was the smallest in the app — under half the
                        // 24pt minimum in both dimensions. It survived only because the
                        // whole header row also toggles, which is a fat target with the
                        // wrong owner. This changes nothing that is drawn.
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Lumen.secondaryText)
            }
            // THE GLYPH, IN A FIXED BOX SO THE TITLES CANNOT WANDER.
            //
            // The owner: "giving the curves item a curve emoticon, and stuff like that,
            // or overall just livening the app up a little bit more." The section names
            // its own symbol (`WorkspaceSection.symbolName`, in `DevelopColumn.swift`);
            // this is the half that draws it.
            //
            // Sixteen points wide whatever the glyph measures, because SF Symbols are
            // not a fixed-width family — `crop` is nearly square and the Curve section's
            // `point.topleft.down.to.point.bottomright.curvepath` is half again as wide
            // — and six headers stacked down a column with their titles each starting at
            // a different x is a ragged left edge. The eye reads that as sloppiness long
            // before it reads it as icons, which would make the decoration cost more
            // than it bought. No clip, deliberately: a glyph a hair wider than its box
            // spills into the four points of spacing rather than losing a stroke.
            //
            // Eleven point regular in `secondaryText`, one step under the title's twelve
            // point semibold caps in `primaryText`. A symbol drawn at the heading's own
            // weight and colour stops annotating the heading and starts reading as its
            // first character.
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(Lumen.secondaryText)
                    .frame(width: 16)
            }
            // The header now outranks the rows it governs (design audit §1.2: the
            // highest-level element in the panel was the smallest text in it).
            // A HEADING, NOT TEXTURE. It was 11pt semibold in `secondaryText` — the
            // identical colour to the rows beneath it and one weight-step away, with no
            // rule, no fill and no container. Six of those stacked is a table of
            // contents, which is exactly what the owner reported seeing. `primaryText`
            // takes it from 5.33:1 to 10.56:1 against the panel and buys a real
            // hierarchy step for nothing.
            //
            // Through `LumenCapsLabel` rather than hand-rolled, because that type exists
            // precisely to stop a sixth 12pt-semibold-0.7-tracking caps style being
            // invented next to the five it replaced (`LumenType.swift`).
            LumenCapsLabel(text: title, size: 12, color: Lumen.primaryText)
            if isModified {
                Circle()
                    .fill(Lumen.accent)
                    .frame(width: 5, height: 5)
            }
            Spacer()
            if let onReset, isModified {
                // Reset appears on hover (design audit step 3, and Lightroom's own
                // behaviour). A develop panel can hold a dozen modified sections and a
                // permanent "Reset" on each one is a dozen words of chrome competing
                // with the values they sit beside — while the accent dot already answers
                // "which sections did I touch?" from across the panel.
                //
                // Opacity rather than an `if`, deliberately: inserting the button on
                // hover would reflow the header under the pointer that summoned it, and
                // a control that moves when you approach it is worse than a loud one.
                Button("Reset", action: onReset)
                    .buttonStyle(.plain)
                    .font(.lumenCaption)
                    .foregroundStyle(Lumen.secondaryText)
                    .opacity(hovering ? 1 : 0)
                    .animation(.easeOut(duration: 0.1), value: hovering)
                    // An empty string is SwiftUI's own "no tooltip", so the nil case
                    // costs nothing and the modifier does not need a branch.
                    .help(resetHelp ?? "")
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        // THE HEADER ANSWERS THE POINTER TOO, on the state it already tracked.
        //
        // `hovering` has existed here since Reset started fading in on it; the row was
        // simply not drawing anything with it. A second `onHover` stacked on top would
        // have been two sources of one truth, and `lumenHoverable()` cannot be used at
        // all — it paints BEHIND its content, and this header is about to be handed a
        // filled card to sit in.
        //
        // Inside the fill, not outside: `topRhythm` is the space BEFORE the section, so
        // including it would draw a pill twenty points taller than the words in it,
        // hanging above the header like a dropped shadow.
        //
        // THE FILL STAYS AND ITS CORNER MOVED, both for reasons this pass created.
        //
        // It stays because the slider rows gave theirs up on the owner's third review —
        // "I would remove a bunch of the hover effects, like hovering over the white
        // balance or the temperature or tint" — which leaves this row as the only thing
        // inside an open section that lights up under the pointer. That is not an
        // inconsistency waiting to be tidied away; it is the only thing inside an open
        // section that is CLICKABLE. A header that collapses its section on click and
        // answers the pointer with nothing is the affordance gap the whole hover pass
        // was written to close.
        //
        // But being the only fill in the card means the shape has to read as a control
        // the instant it appears, and `radiusChip` no longer does. That token's own note
        // sizes it against a chip 16 points tall; this row is 28 wherever it carries a
        // chevron — a 20-point target with four points of padding above and below —
        // which is exactly the 28-point tab `Lumen.radiusTab` was originally sized
        // against, and that one rounds to 12. Six points on a 28-point row inside a
        // card whose corner is now 14 reads as a rectangle that appeared rather than
        // as a button that lit.
        // …AND ONLY WHEN THE HEADER IS A CONTROL. A header with no chevron and no
        // `onToggle` — the B&W header while the treatment is off, the flattened Display
        // Transform group — does nothing on click, and a label that lights up while
        // doing nothing is the exact affordance lie the owner's hover cull named
        // ("section-ish labels that are not clickable"). `hovering` itself still
        // tracks, because Reset fades in on it either way.
        .background(
            RoundedRectangle(cornerRadius: Lumen.radiusControl, style: .continuous)
                .fill(hovering && isInteractive ? Lumen.controlHover : Color.clear))
        // The four points come straight back out. The fill wants to bleed past the words
        // so it reads as a row rather than as a label with a box drawn round it, but the
        // TITLE has to stay on the same left edge as the slider names beneath it — a
        // heading that sits four points right of its own contents is the kind of drift
        // nobody reports and everybody sees.
        .padding(.horizontal, -4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { toggle() }
        // One cursor region for the whole header rather than one on the chevron: the
        // row and the arrow do the same thing, so the pointing hand should not appear
        // over 20 points of a 300-point target. Gated the same way the hover fill is —
        // a pointing hand over a label that answers no click is a promise broken.
        .lumenClickCursor(isInteractive)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .padding(.top, topRhythm)
    }

    /// One path for the chevron and the row, so the two can never disagree about what a
    /// click means — which they would the moment only one of them learned about
    /// `onToggle`.
    private func toggle() {
        if let onToggle {
            onToggle(Self.optionIsDown)
            return
        }
        isExpanded?.wrappedValue.toggle()
    }
}

// MARK: - Segmented picker

struct LumenSegmented<T: Hashable>: View {
    let options: [(value: T, label: String)]
    @Binding var selection: T
    /// Values whose segment carries something — drawn as the accent dot, the same mark
    /// a modified section header wears.
    ///
    /// A segmented control that shows one thing at a time hides the other three, and
    /// "what did I change?" is the question this app is built to answer down a whole
    /// panel at a glance. Without the dots, four grading wheels behind one control mean
    /// four clicks to find out whether you touched the shadows.
    var marked: Set<T> = []

    /// Which segment the pointer is over. Row-local and never observable, for the reason
    /// `LumenHoverModifier` states — a pointer crossing a panel must not publish.
    @State private var hovered: T?

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button {
                    selection = option.value
                } label: {
                    HStack(spacing: 3) {
                        Text(option.label)
                            .font(.lumenCaption)
                        if marked.contains(option.value) {
                            Circle()
                                .fill(Lumen.accent)
                                .frame(width: 4, height: 4)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(selectionChip(for: option.value))
                    .foregroundStyle(labelColor(for: option.value))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside {
                        hovered = option.value
                    } else if hovered == option.value {
                        hovered = nil
                    }
                }
                .lumenClickCursor()
            }
        }
        // The interior is ONE carved well, and only the chosen segment stands up out of
        // it as a chip. The previous form filled every segment edge to edge — a rest
        // fill, a hover fill and a selection fill all running flush to the well's lip —
        // which is the "highlights with no padding" the owner named on exactly this
        // control (docs/32 Stream D item 2). The hover fill is gone outright, removal
        // being his stated preference; hover now answers in the label's colour and the
        // pointing hand, which move no surface. The selection fill stays — it is state,
        // not a hover — and it wears the chip inset instead of the full bleed.
        .background(Lumen.insetWell)
        // A WELL, not a clip. `lumenWell` does the same rounding and adds the carved lip
        // — dark along the top edge, faintly lit along the bottom — which is what tells
        // the eye that the segments sit DOWN in the panel rather than being three
        // rectangles that happen to be adjacent (`LumenSurface.swift`).
        .lumenWell(radius: Lumen.radiusChip)
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    /// The selected segment's chip: inset two points on every side so the fill reads as
    /// an object sitting IN the well rather than a slab of it changing colour. The
    /// radius steps down with the inset the same way `LumenSwitch`'s thumb does, so the
    /// chip's corner stays concentric with the well's.
    private func selectionChip(for value: T) -> some View {
        RoundedRectangle(cornerRadius: Lumen.radiusChip - 2, style: .continuous)
            .fill(selection == value ? Lumen.fillColor.opacity(0.35) : Color.clear)
            .padding(2)
    }

    /// Hover lives here now — the one channel left that moves no surface. Selection
    /// outranks it only in that the chip is already carrying the state.
    private func labelColor(for value: T) -> Color {
        if selection == value || hovered == value { return Lumen.primaryText }
        return Lumen.secondaryText
    }
}

// MARK: - Colour wheel

/// A grading wheel: hue as angle, saturation as radius, with a separate luminance
/// bar under it. The pivot pickers that make Lumen's wheels different from LR's live
/// in the panel, not here — this is only the puck.
struct LumenColorWheel: View {
    /// Empty draws no caption — which is what the grade's single large wheel wants,
    /// since the segmented control above it already names the zone.
    let title: String
    @Binding var hue: Double        // 0…360
    @Binding var sat: Double        // 0…1
    @Binding var lum: Double        // −1…+1
    /// 68 is the four-up size. The grade's single wheel asks for 150: a puck is placed
    /// by eye at a radius, and half the radius is half the precision for the same hand
    /// movement — four wheels this small was the reason grading felt fiddly rather than
    /// the reason it felt complete.
    var diameter: CGFloat = 68
    /// Centre the lightness bar on the wheel's axis and caption it "Luminance".
    ///
    /// The grade's single large wheel turns this on: the owner could not tell what the
    /// bar was, and an untitled `LumenSlider` has no label to hang a tooltip on — the
    /// bar shipped with no way to ask. Centring costs a counterweight equal to the
    /// readout column on the leading side, which a 150-point wheel can pay and the mask
    /// panel's 68-point two-up cannot (two captioned bars would overrun the column), so
    /// the compact callers keep the old form by default.
    var captionedBar: Bool = false
    var onEditingChanged: ((Bool) -> Void)?
    /// Injected once at the root (ContentView) and fired by EVERY slider in the app —
    /// which is the point: `onEditingChanged` sat unconsumed for the app's whole life
    /// because it needed wiring at ~90 call sites, and the costs of not knowing a drag
    /// was in flight (a SQLite write plus a canonical-JSON fingerprint per photo per
    /// mouse event, a scope timer restarted per event) were being paid everywhere.
    @Environment(\.sliderGestureChanged) private var sliderGestureChanged

    /// Same double-click story as `LumenSlider`'s track: a TapGesture(count: 2)
    /// behind a minimumDistance-0 drag never fires, so the reset reads the click
    /// count off the AppKit event at press time instead.
    @State private var dragActive = false
    @State private var pressWasReset = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(AngularGradient(colors: Self.wheelColors, center: .center))
                    .overlay(
                        RadialGradient(colors: [Color(white: 0.5), .clear],
                                       center: .center, startRadius: 0,
                                       endRadius: diameter / 2)
                    )
                    // 0.85, up from 0.75 in the same pass that richened `wheelColors`:
                    // the wash toward the panel grey was the other half of "pastel",
                    // and a saturation raise under a quarter-strength grey veil would
                    // have been half an answer. Not 1.0 — the wheel still sits beside
                    // the photograph, and some restraint is what keeps the Law 7
                    // exception an exception.
                    .opacity(0.85)
                // A LIT RIM, not a drawn outline. `LumenSurface` makes the argument in
                // full: a uniform 1px line reads as pre-Yosemite chrome, while a stroke
                // that is bright along the top and near-invisible along the bottom reads
                // as an edge under a light from above. A circle cannot take
                // `lumenSurface()` — it would clip to a rectangle — so it borrows the
                // gradient.
                Circle()
                    .strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(0.14),
                                                Color.white.opacity(0.04)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
                puck
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !dragActive {
                            dragActive = true
                            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                                pressWasReset = true
                                onEditingChanged?(true)
                                sliderGestureChanged(true)
                                sat = 0
                                lum = 0
                                onEditingChanged?(false)
                                sliderGestureChanged(false)
                            }
                        }
                        if pressWasReset { return }
                        onEditingChanged?(true)
                        sliderGestureChanged(true)
                        let dx = drag.location.x - diameter / 2
                        let dy = drag.location.y - diameter / 2
                        let r = min((dx * dx + dy * dy).squareRoot() / (diameter / 2), 1)
                        hue = (atan2(Double(dy), Double(dx)) * 180 / .pi + 360)
                            .truncatingRemainder(dividingBy: 360)
                        sat = Double(r)
                    }
                    .onEnded { _ in
                        dragActive = false
                        if pressWasReset {
                            pressWasReset = false
                            return
                        }
                        onEditingChanged?(false)
                        sliderGestureChanged(false)
                    }
            )

            if !title.isEmpty {
                Text(title)
                    .font(.lumenCaption)
                    .foregroundStyle(Lumen.secondaryText)
            }

            if captionedBar {
                // CENTRED ON THE WHEEL, NOT ON THE ROW. An untitled slider is a track
                // plus a 44-point readout, so the groove's midpoint sits 25 points left
                // of the row's — under a 150-point wheel that read as a bar hanging off
                // one shoulder. The leading padding is the readout's exact counterweight
                // (valueWidth + the row's 6-point gap), which puts the groove's centre
                // on the wheel's centre by construction rather than by eye.
                lightnessBar
                    .padding(.leading, Lumen.valueWidth + 6)
                    .frame(width: diameter + 2 * (Lumen.valueWidth + 6))
                // The caption the owner asked this bar for: he could not tell what it
                // was, and the empty title means the slider itself has no label to
                // carry a tooltip. The caption is the label, and the tooltip rides it.
                Text("Luminance")
                    .font(.lumenCaption)
                    .foregroundStyle(Lumen.secondaryText)
                    .help("Luminance — the zone's own brightness, up to half a stop "
                          + "each way, holding its colour rather than washing it out. "
                          + "Drag the bar, or double-click it to reset.")
            } else {
                lightnessBar
                    .frame(width: diameter + 40)
            }
        }
    }

    /// The lightness bar, one definition for both framings above.
    private var lightnessBar: some View {
        LumenSlider(title: "", value: $lum, range: -1...1, defaultValue: 0,
                    step: 0.01, decimals: 2,
                    // Dark to light — the one VALUE ramp the Law 7 amendment
                    // permits, and worth separating from the exposure ramp it
                    // refuses. This bar is the L of an H/S/L triple, inside a
                    // bordered colour instrument, 50 points wide; Exposure is a full
                    // row in a column of tonal sliders beside the photograph being
                    // judged for exposure. Lightroom draws exactly this distinction
                    // and so does Resolve. It also makes the caption under these
                    // wheels true — it has been claiming "the bar under each wheel
                    // is the zone's own lightness" over an undifferentiated grey.
                    trackStops: Lumen.wheelLightnessStops,
                    onEditingChanged: onEditingChanged)
    }

    private var puck: some View {
        let r = CGFloat(sat) * diameter / 2
        let a = CGFloat(hue * .pi / 180)
        return Circle()
            .strokeBorder(Color.white, lineWidth: 1.5)
            .background(Circle().fill(Color.black.opacity(0.25)))
            .frame(width: 9, height: 9)
            .offset(x: r * cos(a), y: r * sin(a))
    }

    /// The wheel's own colours are the one deliberate exception to zero-chroma
    /// chrome: a grading wheel that cannot show hue is not a grading wheel.
    ///
    /// Saturation 0.72, up from the 0.55 that shipped: the owner called the wheels
    /// pastel, and Law 7's stated exception is exactly this instrument — richer is
    /// allowed, garish is not (docs/32 Stream D item 4). Brightness stays at 0.8, and
    /// the raise is on one axis on purpose: pushing both is how a wheel goes from
    /// instrument to neon. The mixer's hue ring took the matching step in its own
    /// colour system (`ColorPanel.hueColor`), so the two colour instruments read as
    /// siblings rather than one rich and one washed.
    static let wheelColors: [Color] = (0..<13).map {
        Color(hue: Double($0) / 12, saturation: 0.72, brightness: 0.8)
    }
}

// MARK: - Small helpers

struct LumenToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var help: String?

    var body: some View {
        HStack {
            Text(title)
                .font(.lumenBody)
                .foregroundStyle(Lumen.primaryText)
            Spacer()
            // DRAWN, not AppKit's. `.toggleStyle(.switch)` fills its capsule with the
            // system accent — blue on a default install — and this row appears 26 times
            // across eight panels, most of them in the develop column inches from the
            // photograph. docs/00 Law 7 forbids exactly that, and the app's own accent
            // policy says "marker scale, never area". `LumenSwitch` fills it with
            // `sliderFillModified` instead, which is already this app's word for "you
            // changed this" — so an ON switch and a moved slider now say the same thing
            // the same way.
            LumenSwitch(isOn: $isOn)
        }
        .frame(height: Lumen.rowHeight)
        // The same 2-in / 1-out air as a slider row, so a toggle dropped between two
        // sliders keeps the column's pitch instead of pinching it.
        .padding(.vertical, 2)
        // THE WHOLE ROW IS THE SWITCH. A mini `Toggle` is a 26-point target at the far
        // end of a 300-point row whose left half is a label naming what it does, and
        // hitting it meant crossing the panel. Every list row in macOS that carries a
        // switch toggles on the row; this one did not, and the label was the one part a
        // photographer would naturally aim at.
        //
        // The tap goes on the HStack rather than on a `Button` wrapper so the switch
        // keeps its own gesture: a click that lands on the switch is handled by the
        // switch and never reaches here, which is what stops the two cancelling.
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
        .lumenHoverable()
        .lumenClickCursor()
        .padding(.vertical, 1)
        .help(help ?? "")
    }
}

struct LumenBadge: View {
    let text: String
    var emphasized: Bool = false

    var body: some View {
        Text(text)
            // 10, not 9. `LumenType` sets 10 as the floor and this was one of the
            // forty-six sites underneath it.
            .font(.lumenCaption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(.white)
            // A chip is a small object, and an object has an edge. `lumenSurface` gives
            // it the lit top the flat `clipShape` never had, at `.flush` because a badge
            // sits ON the row it annotates rather than above it.
            .lumenSurface(radius: Lumen.radiusChip,
                          elevation: .flush,
                          fill: emphasized ? Lumen.accent.opacity(0.8)
                                           : Color.black.opacity(0.55))
    }
}

#endif
