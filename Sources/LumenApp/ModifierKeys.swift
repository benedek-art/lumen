// ModifierKeys.swift
// ⌥ as an observable fact, so a view that changes with it is told when it changes.
//
// The mask panel turns Add and Subtract into one Intersect while ⌥ is down, and it read
// that from `NSEvent.modifierFlags` — a synchronous poll. A poll is only as fresh as the
// last body evaluation, and nothing re-evaluated the panel when a modifier changed: the
// app had no `flagsChanged` monitor at all. So holding ⌥ over the panel left the button
// reading "Add" with Subtract beside it until something unrelated re-bodied the view
// (audit F4-03). The panel still polls for the VALUE, which is the truth at the moment
// the body runs; this object is the invalidation the poll never had.

#if os(macOS)

import AppKit

/// Deliberately not `@MainActor`-isolated so `shared` can be referenced from a plain
/// property initializer, like `MaskBrushStore`. Written only from the main-thread event
/// monitor `Keymap.install` registers.
final class ModifierKeys: ObservableObject {
    static let shared = ModifierKeys()

    @Published private(set) var optionHeld = false

    /// Fed every `flagsChanged` event. Publishes only on a change of ⌥, so ⇧ and ⌘
    /// going up and down do not re-body every observer.
    func update(_ flags: NSEvent.ModifierFlags) {
        let held = flags.contains(.option)
        if held != optionHeld { optionHeld = held }
    }
}

#endif
