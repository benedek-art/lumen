// LumenControls.swift
// The control kit every panel is built from, and the single place the slider contract
// (D45) is implemented. A slider that behaves differently in one panel is a bug the
// user feels before they can name it, so there is exactly one slider in this app.
//
// The contract, in one place. This list is what the file DOES, and it is worth saying
// why that needs stating: it used to open with "←/→ nudge by one step; ⇧ multiplies by
// 10; ⌥ divides by 10", and this file contains no key handling of any kind. The keymap
// owns the arrows, where they move the photo selection. It also claimed the number
// field scrubs, and the number field takes a click and lets you type.
//
//   · drag the track — grab the thumb and it follows the cursor; press the track and
//     the value jumps there once, then follows from there
//   · click the number and type a value
//   · double-click the label or the track resets to the default (or to whatever
//     `onReset` means for a row whose neutral is "auto")
//   · the range is SOFT — dragging pins at the soft limit, typing accepts the hard one
//   · a control that is not at its default shows it, so "what did I change?" is
//     answerable at a glance rather than by memory
//
// WHY THERE IS NO KEYBOARD NUDGE, rather than a promise of one. Arrow keys already mean
// "previous / next photo", claimed by `KeyDispatcher`'s NSEvent monitor, which sits in
// FRONT of the responder chain — so a focused slider would never see an arrow at all.
// Making the nudge work needs three decisions, none of which is this file's to make
// alone: the slider has to become focusable, so there must be a visible focus ring in a
// chrome that is deliberately zero-chroma and near-featureless; the dispatcher has to
// learn to hand the arrows back when a slider holds focus, the way it already does for
// a focused text field and for the zoomed loupe's pan; and there has to be a way to put
// focus on a slider and take it off again, or the arrows stop paging photographs and
// the photographer cannot tell why. Until those exist, the honest thing is that the
// nudge is not offered. The rest of the D45 contract that is still missing — arithmetic
// entry, scrubby-drag on the readout, ⌥-scroll, ⌘-double-click to auto, ⇧⌥-drag to the
// hard limit, haptic detents — is audit UX-04's parity half and is likewise absent
// rather than advertised.
//
// Chrome is zero-chroma by law (docs/00 Law 7): nothing in this file introduces a hue
// that could bias a colour judgement about the photograph.

#if os(macOS)

import LumenCore
import SwiftUI

// MARK: - Theme

enum Lumen {
    static let panelBackground = Color(nsColor: NSColor(white: 0.14, alpha: 1))
    static let controlBackground = Color(nsColor: NSColor(white: 0.20, alpha: 1))
    static let trackColor = Color(nsColor: NSColor(white: 0.32, alpha: 1))
    static let fillColor = Color(nsColor: NSColor(white: 0.62, alpha: 1))
    static let viewerBackground = Color(nsColor: NSColor(white: 0.16, alpha: 1))
    static let separator = Color(nsColor: NSColor(white: 0.26, alpha: 1))
    static let primaryText = Color(nsColor: NSColor(white: 0.88, alpha: 1))
    static let secondaryText = Color(nsColor: NSColor(white: 0.58, alpha: 1))
    /// The one accent, used only for state that must be noticed (modified markers,
    /// active tool). Deliberately desaturated so it never competes with the photo.
    static let accent = Color(nsColor: NSColor(red: 0.45, green: 0.58, blue: 0.72, alpha: 1))

    static let rowHeight: CGFloat = 22
    static let panelWidth: CGFloat = 320
    static let labelWidth: CGFloat = 78
    static let valueWidth: CGFloat = 52
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
    var wand: (() -> Void)?
    var onEditingChanged: ((Bool) -> Void)?

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
    @State private var isEditingText = false
    @State private var textValue = ""
    @FocusState private var textFocused: Bool

    private var effectiveHardRange: ClosedRange<Double> { hardRange ?? range }
    private var isModified: Bool { abs(value - defaultValue) > step / 1000 }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(isModified ? Lumen.primaryText : Lumen.secondaryText)
                .frame(width: Lumen.labelWidth, alignment: .leading)
                .lineLimit(1)
                .onTapGesture(count: 2) { reset() }
                .help("\(title) — double-click to reset")

            track

            valueField

            if let wand {
                Button(action: wand) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Lumen.secondaryText)
                .help("Set \(title) automatically")
            }
        }
        .frame(height: Lumen.rowHeight)
    }

    // How close to the thumb counts as grabbing it rather than pressing the track is
    // `SliderDrag.thumbGrabRadius`, in LumenCore. It is not restated here as a second
    // constant: two numbers that have to agree and can drift apart is the shape most of
    // this file's history has had.

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
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Lumen.trackColor)
                    .frame(height: 3)
                // Fill from the default toward the value: the eye reads the deviation,
                // not the absolute position. Where the fill STARTS is the lower of the
                // two, always — what decides it is where the default sits, not whether
                // the range straddles zero. Consulting `bipolar` here collapsed to
                // `min(fraction, fraction)` on every unipolar slider, which drew the
                // bar starting at the thumb and running away from the default instead
                // of toward it.
                Capsule()
                    .fill(Lumen.fillColor.opacity(isModified ? 0.9 : 0.5))
                    .frame(width: max(abs(fraction - zeroFraction) * width, 1), height: 3)
                    .offset(x: min(fraction, zeroFraction) * width)
                // The neutral mark. Sits under the thumb so the thumb covers it when
                // the control is at its default, which is exactly when you do not
                // need to be told where the default is.
                if bipolar && zeroFraction > 0.001 && zeroFraction < 0.999 {
                    Rectangle()
                        .fill(Lumen.separator)
                        .frame(width: 1, height: 7)
                        .offset(x: zeroFraction * width - 0.5)
                }
                Circle()
                    .fill(Lumen.primaryText)
                    .frame(width: isDragging ? 11 : 9, height: isDragging ? 11 : 9)
                    .offset(x: fraction * width - (isDragging ? 5.5 : 4.5))
                    .shadow(radius: isDragging ? 2 : 0)
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
                            let thumbX = fraction * Double(width)
                            if SliderDrag.grabsThumb(
                                pressX: Double(drag.startLocation.x), thumbX: thumbX) {
                                dragStartValue = value
                            } else {
                                dragStartValue = geometryOfDrag.valueAtPress(
                                    x: Double(drag.startLocation.x))
                                value = dragStartValue
                            }
                            onEditingChanged?(true)
                        }
                        let travelled = Double(drag.location.x - drag.startLocation.x)
                        let moved = geometryOfDrag.value(from: dragStartValue,
                                                         travelled: travelled)
                        if moved != value { value = moved }
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
                        if isDragging {
                            let travelled = Double(drag.location.x - drag.startLocation.x)
                            let settled = SliderDrag.endedValue(track: geometryOfDrag,
                                                                from: dragStartValue,
                                                                travelled: travelled)
                            if settled != value { value = settled }
                        }
                        isDragging = false
                        onEditingChanged?(false)
                    }
            )
            .onTapGesture(count: 2) { reset() }
        }
        .frame(height: Lumen.rowHeight)
    }

    private var valueField: some View {
        Group {
            if isEditingText {
                TextField("", text: $textValue)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .focused($textFocused)
                    .onSubmit { commitText() }
                    .onExitCommand { isEditingText = false }
            } else {
                Text(formatted)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(isModified ? Lumen.primaryText : Lumen.secondaryText)
                    .onTapGesture {
                        textValue = formatted
                        isEditingText = true
                        textFocused = true
                    }
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
        value = defaultValue
        onEditingChanged?(false)
    }

    private func commitText() {
        isEditingText = false
        // `Double("nan")`, `Double("inf")` and `Double("1e999")` all parse, and the
        // clamp below does NOT filter them: `max(NaN, lo)` is NaN, because every
        // comparison against NaN is false. A NaN reaching the recipe is not a bad
        // render, it is data loss — `JSONEncoder` refuses non-conforming floats, so
        // the canonical JSON collapses to "{}" and that is what gets written to the
        // sidecar, erasing the photo's edit from the copy that exists to survive
        // losing the catalog.
        guard let parsed = Double(textValue.trimmingCharacters(in: .whitespaces)),
              parsed.isFinite else { return }
        // Typing reaches the hard limit; dragging does not. That asymmetry is what
        // makes soft limits helpful instead of restrictive.
        onEditingChanged?(true)
        value = min(max(parsed, effectiveHardRange.lowerBound),
                    effectiveHardRange.upperBound)
        onEditingChanged?(false)
    }
}

// MARK: - Section header

struct LumenSectionHeader: View {
    let title: String
    var isExpanded: Binding<Bool>?
    var isModified: Bool = false
    var onReset: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            if let isExpanded {
                Button {
                    isExpanded.wrappedValue.toggle()
                } label: {
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Lumen.secondaryText)
            }
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Lumen.secondaryText)
            if isModified {
                Circle()
                    .fill(Lumen.accent)
                    .frame(width: 4, height: 4)
            }
            Spacer()
            if let onReset, isModified {
                Button("Reset", action: onReset)
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(Lumen.secondaryText)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            if let isExpanded { isExpanded.wrappedValue.toggle() }
        }
    }
}

// MARK: - Segmented picker

struct LumenSegmented<T: Hashable>: View {
    let options: [(value: T, label: String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.system(size: 10))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .background(selection == option.value
                                    ? Lumen.fillColor.opacity(0.35) : Lumen.controlBackground)
                        .foregroundStyle(selection == option.value
                                         ? Lumen.primaryText : Lumen.secondaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Colour wheel

/// A grading wheel: hue as angle, saturation as radius, with a separate luminance
/// bar under it. The pivot pickers that make Lumen's wheels different from LR's live
/// in the panel, not here — this is only the puck.
struct LumenColorWheel: View {
    let title: String
    @Binding var hue: Double        // 0…360
    @Binding var sat: Double        // 0…1
    @Binding var lum: Double        // −1…+1
    var onEditingChanged: ((Bool) -> Void)?

    private let diameter: CGFloat = 68

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
                    .opacity(0.75)
                Circle()
                    .strokeBorder(Lumen.separator, lineWidth: 1)
                puck
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        onEditingChanged?(true)
                        let dx = drag.location.x - diameter / 2
                        let dy = drag.location.y - diameter / 2
                        let r = min((dx * dx + dy * dy).squareRoot() / (diameter / 2), 1)
                        hue = (atan2(Double(dy), Double(dx)) * 180 / .pi + 360)
                            .truncatingRemainder(dividingBy: 360)
                        sat = Double(r)
                    }
                    .onEnded { _ in onEditingChanged?(false) }
            )
            .onTapGesture(count: 2) {
                onEditingChanged?(true)
                sat = 0
                lum = 0
                onEditingChanged?(false)
            }

            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(Lumen.secondaryText)

            LumenSlider(title: "", value: $lum, range: -1...1, defaultValue: 0,
                        step: 0.01, decimals: 2, onEditingChanged: onEditingChanged)
                .frame(width: diameter + 40)
        }
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
    static let wheelColors: [Color] = (0..<13).map {
        Color(hue: Double($0) / 12, saturation: 0.55, brightness: 0.8)
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
                .font(.system(size: 11))
                .foregroundStyle(Lumen.primaryText)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .frame(height: Lumen.rowHeight)
        .help(help ?? "")
    }
}

struct LumenBadge: View {
    let text: String
    var emphasized: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(emphasized ? Lumen.accent.opacity(0.8) : Color.black.opacity(0.55))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

#endif
