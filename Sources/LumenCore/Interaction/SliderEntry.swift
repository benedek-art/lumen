// SliderEntry.swift
// What a photographer can type into a slider's readout.
//
// docs/12 §12.13's D45 lists arithmetic entry among the slider contract's deliberate
// omissions, and docs/28 Phase 6 claims it: "+0.3 on eight hundred frames" is a real
// verb, and re-deriving the target number in your head before typing it is not.
//
// THE GRAMMAR, and the trap it is shaped around:
//
//     40        →  the value becomes 40
//     -40       →  the value becomes −40
//     += 0.3    →  0.3 more than it was
//     -= 0.2    →  0.2 less
//     * 2       →  twice what it was            (`*= 2` also accepted)
//     / 2       →  half                          (`/= 2` also accepted)
//
// Figma's convention — a leading `+` or `-` is relative — is the better-known one and it
// is deliberately NOT used here. Figma's numeric fields are mostly non-negative
// dimensions; Lumen's are Exposure at ±5, the tone sliders at ±100 and Tint at ±150, so
// typing a negative absolute is routine. The readout pre-fills with the current value
// and the field selects it, so "replace it all with -40" is the ordinary way to set
// −40 — and under Figma's grammar that would silently mean "subtract 40 from 30" and
// land on −10. A control that quietly does something else with a number a photographer
// typed is worse than one that cannot do arithmetic at all.
//
// `*` and `/` need no `=` because no number begins with them. `+` and `-` do.

import Foundation

/// The parsed meaning of what was typed into a readout.
public enum SliderEntry: Equatable, Sendable {

    /// Replace the value.
    case absolute(Double)
    /// Add to it. Subtraction is a negative addend, and division is a reciprocal
    /// multiply, so there are three cases rather than five that would have to agree
    /// with each other about which way a sign or a quotient points.
    case add(Double)
    /// Multiply it.
    case multiply(Double)

    /// Parse a readout's contents, or nil if they are not something this control can use.
    ///
    /// Nil rather than a fallback on purpose. `Double("nan")`, `Double("inf")` and
    /// `Double("1e999")` all parse, and a clamp does NOT filter them — `max(NaN, lo)` is
    /// NaN, because every comparison against NaN is false. A NaN reaching the recipe is
    /// not a bad render, it is data loss: `JSONEncoder` refuses non-conforming floats, so
    /// the canonical JSON collapses to "{}" and that is what reaches the sidecar, erasing
    /// the photograph's edit from the copy that exists to survive losing the catalog.
    public static func parse(_ text: String) -> SliderEntry? {
        let s = text.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }

        // Longest first, so `+=` is never read as a bare `+` with a stray `=` after it.
        // The typographic × and ÷ are accepted because macOS users get them from the
        // keyboard viewer and being strict about it buys nothing.
        let adds = ["+=": 1.0, "-=": -1.0]
        for (token, sign) in adds where s.hasPrefix(token) {
            guard let n = decimal(after: token, in: s) else { return nil }
            return .add(sign * n)
        }

        let times = ["*=", "×=", "*", "×"]
        for token in times where s.hasPrefix(token) {
            guard let n = decimal(after: token, in: s) else { return nil }
            return .multiply(n)
        }

        let over = ["/=", "÷=", "/", "÷"]
        for token in over where s.hasPrefix(token) {
            // Refused rather than resolved: the reciprocal of zero is infinite, and this
            // type exists precisely so that nothing non-finite can reach a recipe.
            guard let n = decimal(after: token, in: s), n != 0 else { return nil }
            let reciprocal = 1 / n
            guard reciprocal.isFinite else { return nil }
            return .multiply(reciprocal)
        }

        if s.hasPrefix("=") {
            guard let n = decimal(after: "=", in: s) else { return nil }
            return .absolute(n)
        }

        guard let n = decimal(s) else { return nil }
        return .absolute(n)
    }

    private static func decimal(after token: String, in s: String) -> Double? {
        decimal(String(s.dropFirst(token.count)).trimmingCharacters(in: .whitespaces))
    }

    /// A decimal numeral and nothing else.
    ///
    /// `Double(_:)` also accepts "nan", "inf", "infinity" and hex floats like "0x1p3",
    /// so the characters are checked before the conversion rather than the value being
    /// checked after it — "nan" would otherwise parse and then have to be caught by an
    /// `isFinite` test that is easy to forget at the next call site.
    private static func decimal(_ s: String) -> Double? {
        guard !s.isEmpty else { return nil }
        for c in s where !(c.isNumber || c == "." || c == "-" || c == "+"
                           || c == "e" || c == "E") {
            return nil
        }
        guard let v = Double(s), v.isFinite else { return nil }
        return v
    }

    /// What this entry makes of a value that currently reads `current`.
    ///
    /// Not clamped and not snapped: where a value may sit and how it rounds are
    /// `SliderTrack`'s answers, and a second copy of that arithmetic here is exactly how
    /// the two would come to disagree.
    public func applied(to current: Double) -> Double? {
        guard current.isFinite else { return nil }
        let result: Double
        switch self {
        case .absolute(let v): result = v
        case .add(let v): result = current + v
        case .multiply(let v): result = current * v
        }
        return result.isFinite ? result : nil
    }

    /// Parse and apply in one step — what a readout's commit actually wants.
    public static func value(of text: String, current: Double) -> Double? {
        parse(text)?.applied(to: current)
    }
}
