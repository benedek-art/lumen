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
    ///
    /// Shift counts only when the unshifted key is that decision key. On a layout that
    /// needs Shift to type the digit at all (French AZERTY: ⇧& is "1"), Shift is how
    /// the rating is typed, not a request to move on. `unshifted` nil: Shift counts.
    public static func isForced(key: Character, unshifted: Character?, shift: Bool,
                                capsLock: Bool) -> Bool {
        guard decisionKeys.contains(key) else { return false }
        if capsLock { return true }
        guard shift else { return false }
        return unshifted.map { $0 == key } ?? true
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

    /// Whether a key-repeat of `key` may act. Decision keys toggle, so a repeat is only
    /// allowed when this press will move the cursor on; a repeat that stays (last frame,
    /// multi-selection, end of a comparison, cursor outside the roll) flips the decision
    /// it just made. `-` stays out, as it was before Shift existed.
    ///
    /// - Parameters:
    ///   - advance: `CullTargeting.advance` with Shift counted as auto-advance on.
    ///   - rollCursor: the cursor's index in the shown roll, nil when it is not in it.
    ///   - rollCount: how many photos the roll shows.
    public static func allowsRepeat(key: Character, advance: CullTargeting.Advance,
                                    rollCursor: Int?, rollCount: Int) -> Bool {
        guard "pxu0123456789".contains(key) else { return false }
        switch advance {
        case .stay:
            return false
        case .withinComparison:
            return true
        case .nextInRoll:
            guard let rollCursor, rollCursor >= 0 else { return false }
            return rollCursor + 1 < rollCount
        }
    }
}
