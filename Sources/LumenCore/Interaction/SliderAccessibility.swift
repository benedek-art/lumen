// SliderAccessibility.swift
// What a custom editing slider says to VoiceOver, and what one accessibility increment
// does to it.
//
// UX-03. `LumenSlider` is drawn from shapes and gestures, so the accessibility tree saw
// none of it as a control: a section read as one run of static text — "Tone Exposure
// 0.00 Contrast 0 …" — with no per-control element, no value and no way to adjust it.
// The arrow-key nudge exists, but it needs keyboard focus on a row VoiceOver could not
// land on. The row now exposes one adjustable element per slider; the rules for its
// name, its spoken value and its step live here, where they can be tested without a
// Mac.

import Foundation

public enum SliderAccessibility {

    public enum Direction: Sendable, Equatable {
        case increment
        case decrement
    }

    /// The name VoiceOver reads. The row's own title — the words on screen, which are
    /// also what `ControlIndex` files the control under — or, for a row drawn with no
    /// title (the colour wheels' lightness bar), the name its caller supplies. Never
    /// empty: an unnamed adjustable element is announced as "slider", which is the
    /// failure this exists to end.
    public static func label(title: String, name: String?) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let given = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return given.isEmpty ? "Adjustment" : given
    }

    /// The value VoiceOver reads: the readout's own digits, so what is heard is what is
    /// shown. One difference, and it is deliberate: a value that rounds to zero loses
    /// its sign — the readout's `%f` prints a tiny negative as "-0.00", and "minus zero"
    /// is noise to a listener.
    public static func value(_ value: Double, decimals: Int) -> String {
        guard value.isFinite else { return "—" }
        let places = Swift.min(Swift.max(decimals, 0), 6)
        let text = String(format: "%.\(places)f", value)
        if text.hasPrefix("-"), Double(text) == 0 { return String(text.dropFirst()) }
        return text
    }

    /// One accessibility increment or decrement: exactly ONE of the control's own steps,
    /// clamped to its soft range like a drag — `SliderTrack.nudged`, the same arithmetic
    /// the arrow keys use. Never the ⇧-ten the keyboard path reads off the modifier
    /// state, because an assistive action does not carry a modifier and must not pick
    /// one up from whatever happens to be held.
    public static func adjusted(_ value: Double, _ direction: Direction,
                                track: SliderTrack) -> Double {
        track.nudged(value, steps: direction == .increment ? 1 : -1)
    }

    // MARK: The colour wheel

    /// The colour wheel's puck is two values in one place, so it is spoken as both:
    /// "hue 210°, strength 35%". Hue is the angle the puck sits at; strength is its
    /// distance from the centre, which is what the wheel's saturation means.
    public static func wheelValue(hue: Double, saturation: Double) -> String {
        let h = hue.isFinite ? Int((hue.truncatingRemainder(dividingBy: 360) + 360)
                                       .truncatingRemainder(dividingBy: 360).rounded()) % 360
                             : 0
        let s = saturation.isFinite ? Int((Swift.min(Swift.max(saturation, 0), 1) * 100)
                                              .rounded()) : 0
        return "hue \(h)°, strength \(s)%"
    }

    /// The adjustable axis of the wheel is its strength — the one that reads as "more"
    /// and "less" — in steps of 1 %, clamped to the disc.
    public static let wheelStrengthStep: Double = 0.01

    public static func adjustedWheelStrength(_ saturation: Double,
                                             _ direction: Direction) -> Double {
        let base = saturation.isFinite ? saturation : 0
        let moved = base + (direction == .increment ? wheelStrengthStep : -wheelStrengthStep)
        // Snapped to the step, so repeated actions do not accumulate float dust.
        let snapped = (moved / wheelStrengthStep).rounded() * wheelStrengthStep
        return Swift.min(Swift.max(snapped, 0), 1)
    }

    /// Hue turns in 5° steps, wrapping — offered as a named action beside the
    /// adjustable strength, since one element can only carry one increment axis.
    public static let wheelHueStep: Double = 5

    public static func rotatedWheelHue(_ hue: Double, by steps: Int) -> Double {
        let base = hue.isFinite ? hue : 0
        let next = (base + Double(steps) * wheelHueStep).truncatingRemainder(dividingBy: 360)
        return next < 0 ? next + 360 : next
    }
}
