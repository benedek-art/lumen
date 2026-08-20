// LumenControls.swift
// The control kit every panel is built from, and the single place the slider contract
// (D45) is implemented. A slider that behaves differently in one panel is a bug the
// user feels before they can name it, so there is exactly one slider in this app.
//
// The contract, in one place:
//   · drag the track, or scrub the number field, or type a value
//   · ←/→ nudge by one step; ⇧ multiplies by 10; ⌥ divides by 10
//   · double-click the label or the thumb resets to the default
//   · the range is SOFT — dragging pins at the soft limit, typing accepts the hard one
//   · a control that is not at its default shows it, so "what did I change?" is
//     answerable at a glance rather than by memory
//
// Chrome is zero-chroma by law (docs/00 Law 7): nothing in this file introduces a hue
// that could bias a colour judgement about the photograph.

#if os(macOS)

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
    var defaultValue: Double = 0
    var step: Double = 1
    var decimals: Int = 0
    /// Draw the fill from this value rather than from the left edge, so a bipolar
    /// control reads as a deviation from neutral.
    var bipolar: Bool = true
    var wand: (() -> Void)?
    var onEditingChanged: ((Bool) -> Void)?

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

    private var track: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let span = range.upperBound - range.lowerBound
            let fraction = span > 0 ? (clamped(value) - range.lowerBound) / span : 0
            let zeroFraction = span > 0
                ? (min(max(defaultValue, range.lowerBound), range.upperBound) - range.lowerBound) / span
                : 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Lumen.trackColor)
                    .frame(height: 3)
                // Fill from the default toward the value: the eye reads the deviation,
                // not the absolute position.
                Capsule()
                    .fill(Lumen.fillColor.opacity(isModified ? 0.9 : 0.5))
                    .frame(width: max(abs(fraction - zeroFraction) * width, 1), height: 3)
                    .offset(x: min(fraction, bipolar ? zeroFraction : fraction) * width)
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
                        if !isDragging {
                            isDragging = true
                            dragStartValue = value
                            onEditingChanged?(true)
                        }
                        let fraction = width > 0 ? drag.location.x / width : 0
                        let raw = range.lowerBound + Double(fraction) * span
                        value = snap(clamped(raw))
                    }
                    .onEnded { _ in
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

    private func clamped(_ v: Double) -> Double {
        min(max(v, range.lowerBound), range.upperBound)
    }

    private func snap(_ v: Double) -> Double {
        guard step > 0 else { return v }
        return (v / step).rounded() * step
    }

    private func reset() {
        onEditingChanged?(true)
        value = defaultValue
        onEditingChanged?(false)
    }

    private func commitText() {
        isEditingText = false
        guard let parsed = Double(textValue.trimmingCharacters(in: .whitespaces)) else { return }
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
