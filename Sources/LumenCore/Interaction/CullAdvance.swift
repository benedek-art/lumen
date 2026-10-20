// CullAdvance.swift
// When a cull keystroke moves the cursor on, and which key a Shift-held press means.
//
// docs/10-spec-library.md: "Shift+key always advances even when off", and Caps Lock is
// honoured the same way — Lightroom's habit. Auto-advance (A) is the standing setting;
// Shift (or Caps Lock) is a one-press override that can only ADD an advance, never take
// one away.
//
// The second half exists because `charactersIgnoringModifiers` keeps Shift: ⇧1 arrives
// as "!" on a US layout, so the dispatcher asks AppKit for the unshifted character and
// this rule decides whether that character is a decision key. Only decision keys are
// remapped — ⇧= is "+", the zoom key, and must stay "+".

import Foundation

public enum CullAdvance {

    /// The bare keys that record a decision: flags, ratings, the four digit labels, and
    /// `-` for purple.
    public static let decisionKeys: Set<Character> = [
        "p", "x", "u", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "-",
    ]

    /// Whether a decision should move the cursor to the next frame.
    ///
    /// A multi-selection never advances, forced or not: the keystroke applied to the
    /// whole selection, and moving a single cursor out of it would drop that selection.
    public static func shouldAdvance(autoAdvance: Bool, forced: Bool,
                                     selectionCount: Int) -> Bool {
        (autoAdvance || forced) && selectionCount <= 1
    }

    /// Whether a press is a forced advance: Shift or Caps Lock held on a decision key.
    public static func isForced(key: Character, shift: Bool, capsLock: Bool) -> Bool {
        (shift || capsLock) && decisionKeys.contains(key)
    }

    /// The key a press should be dispatched as.
    ///
    /// `typed` is the lowercased character the event reports with Shift still applied;
    /// `unshifted` is the same key with no modifiers. With Shift held and an unshifted
    /// character that is a decision key, the decision key wins ("!" becomes "1"). Every
    /// other press is dispatched as typed.
    public static func dispatchKey(typed: Character, unshifted: Character?,
                                   shift: Bool) -> Character {
        guard shift, let unshifted, decisionKeys.contains(unshifted) else { return typed }
        return unshifted
    }

    /// Whether a key-repeat of `key` may act. Decision keys toggle, so repeating them is
    /// only navigation when each press also moves on; otherwise holding P flips
    /// pick/unpick at the repeat rate. `-` stays out, as it was before Shift existed.
    public static func allowsRepeat(key: Character, autoAdvance: Bool, forced: Bool) -> Bool {
        guard "pxu0123456789".contains(key) else { return false }
        return autoAdvance || forced
    }
}
