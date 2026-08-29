// KeyGrammar.swift
// The keyboard grammar as data: what the Help sheet prints, and what the parity test
// compares the sources against.
//
// `Keymap.swift` used to say, of its own reference, that it is "data, so the Help sheet
// cannot drift from the dispatcher". It had already drifted. Of the nineteen chords the
// app attaches, NINE were in neither the dispatcher nor the reference: ⌘B target album,
// ⌘K keyword, ⌘G and ⇧⌘G stacks, ⇧⌘I ingest, ⇧⌘A Auto Tone, ⇧⌘R reset settings,
// ⌘\ clear filter — and ⌘/, the shortcut that opens the reference, missing from the
// reference it opens. Being data is not a mechanism. A mechanism is something that
// fails.
//
// Nine, not the seven the audit found by reading: the audit counted ⌘G and ⇧⌘G as one
// line and did not notice ⌘/ at all. That two-count difference is the argument for this
// file in one sentence — the scan below produced the exact list, by file, in a second.
//
// WHAT IS ENFORCED MECHANICALLY, by `KeyGrammarTests` reading the Swift sources:
//
//   1. every `.keyboardShortcut("k", modifiers: […])` in Sources/LumenApp is declared
//      here, with the same key and the same modifiers, and every binding declared here
//      is attached somewhere in Sources/LumenApp. Both directions: a shortcut with no
//      entry fails, and an entry promising a shortcut nobody attaches fails too;
//   2. every bare character `KeyDispatcher`'s switch claims is in `dispatchedKeys`, and
//      every character in `dispatchedKeys` is claimed by that switch. Set equality, so
//      a key added without a reference entry fails;
//   3. a `.keyboardShortcut` whose key is not a literal cannot be read by a scanner, so
//      the file it sits in must be named in `filesWithComputedShortcuts` with a reason.
//      The escape hatch is data too, and it cannot grow silently.
//
// WHAT IS NOT, stated so a clean run is not read as more than it is. The scan proves a
// key is DECLARED, never that the entry's prose describes what the key does; "R — crop"
// would still pass if R opened the export sheet. The special-key branch — the arrows,
// Esc, Delete — arrives as key codes rather than characters and is not covered by (2);
// those entries are maintained by hand. And nothing here reaches the menu bar: docs/12's
// law is that the menu is GENERATED from this table, which would need every
// `.keyboardShortcut` call site to read its binding from here rather than repeat it.
// That is a larger change than this, and until it happens (1) is what stands in for it.

import Foundation

/// One chord: a key plus the modifiers held with it.
public struct KeyBinding: Hashable, Sendable {

    public let key: String
    public let command: Bool
    public let shift: Bool
    public let option: Bool
    public let control: Bool

    public init(_ key: String, command: Bool = false, shift: Bool = false,
                option: Bool = false, control: Bool = false) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    /// Apple's modifier order, ⌃⌥⇧⌘, so the sheet reads the way every other Mac app's
    /// menus do.
    public var display: String {
        var text = ""
        if control { text += "⌃" }
        if option { text += "⌥" }
        if shift { text += "⇧" }
        if command { text += "⌘" }
        return text + key.uppercased()
    }
}

public enum KeyGrammar {

    /// One line of the Help sheet.
    public struct KeyRow: Sendable, Hashable {
        /// What the sheet prints in the key column.
        public let keys: String
        /// What the sheet prints beside it.
        public let action: String
        /// Set when this line corresponds to a SwiftUI `.keyboardShortcut` the parity
        /// scan has to find in the sources. Nil for the bare-key grammar, which the
        /// dispatcher claims instead and which `dispatchedKeys` covers.
        public let binding: KeyBinding?

        public init(keys: String, action: String, binding: KeyBinding? = nil) {
            self.keys = keys
            self.action = action
            self.binding = binding
        }

        /// A line whose key column IS its binding's rendering, so a chord cannot be
        /// printed one way and attached another.
        public init(_ binding: KeyBinding, _ action: String) {
            self.keys = binding.display
            self.action = action
            self.binding = binding
        }
    }

    public struct KeyGroup: Sendable, Hashable {
        public let title: String
        public let rows: [KeyRow]

        public init(title: String, rows: [KeyRow]) {
            self.title = title
            self.rows = rows
        }
    }

    public static let groups: [KeyGroup] = [
        KeyGroup(title: "Views", rows: [
            KeyRow(keys: "G", action: "Grid"),
            KeyRow(keys: "E", action: "Loupe"),
            KeyRow(keys: "C", action: "Compare two"),
            KeyRow(keys: "N", action: "Survey selection"),
            KeyRow(keys: "Space", action: "Hold for loupe from the grid; fit ↔ 1:1 under "
                  + "the cursor in the loupe"),
            KeyRow(keys: "Esc", action: "Back to the grid"),
        ]),
        KeyGroup(title: "Culling", rows: [
            KeyRow(keys: "P", action: "Pick"),
            KeyRow(keys: "X", action: "Reject"),
            KeyRow(keys: "U", action: "Unflag"),
            KeyRow(keys: "⌫", action: "Reject"),
            KeyRow(keys: "1–5", action: "Rating"),
            KeyRow(keys: "0", action: "Clear rating"),
            KeyRow(keys: "6–9", action: "Red / yellow / green / blue label"),
            KeyRow(keys: "-", action: "Purple label (outside the loupe)"),
            KeyRow(keys: "A", action: "Toggle auto-advance"),
            KeyRow(keys: "← →", action: "Previous / next photo; in Compare and Survey, "
                  + "the next frame of the comparison"),
            KeyRow(keys: "↑ ↓", action: "Previous / next row"),
        ]),
        KeyGroup(title: "Develop", rows: [
            KeyRow(keys: "B", action: "Basic panel"),
            KeyRow(keys: "D", action: "Detail panel"),
            KeyRow(keys: "L", action: "Look panel"),
            KeyRow(keys: "M", action: "Masks"),
            KeyRow(keys: "O", action: "Show the selected mask's overlay"),
            KeyRow(keys: "⇧O", action: "Cycle the overlay colour: red, green, white, black"),
            KeyRow(keys: "⌥O", action: "Cycle the six overlay modes"),
            KeyRow(keys: "'", action: "Invert the selected mask component"),
            KeyRow(keys: "R", action: "Crop tool on the image; again to leave it"),
            // Neither of these is a `.keyboardShortcut` the scan can pair with an entry.
            // R R is two presses of a key the dispatcher already claims, told apart by
            // the interval between them (`CropTool.noteArming`); Return is attached in
            // `CropPanel.swift` as a `KeyEquivalent` rather than a string literal, which
            // is why that file is named in `filesWithComputedShortcuts` below.
            KeyRow(keys: "R R", action: "Reset the crop and stay in the tool"),
            KeyRow(keys: "Return", action: "Commit the crop and put the tool away"),
            KeyRow(keys: "⇧S", action: "Soft proof through the destination space"),
            KeyRow(keys: "\\", action: "Before / after, full frame"),
            KeyRow(keys: "Y", action: "Before / after, side by side"),
            KeyRow(keys: "⇧Y", action: "Before / after, split with a divider"),
            KeyRow(keys: "⌥Y", action: "Before / after, top and bottom"),
            KeyRow(keys: "H", action: "Histogram"),
            // The develop histogram bins the rendered picture. ⇧H is the other
            // instrument: scene-linear statistics measured on the decode, before every
            // Lumen stage and before the display transform, with per-channel clipped
            // percentages. It is not the sensor's mosaic and the panel says so.
            KeyRow(keys: "⇧H", action: "Scene-linear clipping panel"),
            KeyRow(keys: "S", action: "Scopes"),
            // `,` and `.` with ⌃ / ⌥ / ⇧ step the printer lights, one point per press.
            // They are SwiftUI shortcuts on the panel's steppers rather than dispatcher
            // keys, and their key is computed at the call site — see
            // `filesWithComputedShortcuts`.
            KeyRow(keys: ", .", action: "Printer lights: step the master down / up"),
            KeyRow(keys: "⌃⌥⇧ , .", action: "Step the red / green / blue trim"),
        ]),
        KeyGroup(title: "View controls", rows: [
            KeyRow(keys: "Z", action: "Zoom 1:1 / fit, under the cursor"),
            KeyRow(keys: "+ = −", action: "Zoom in / out"),
            // Two features, one pair of keys, split by what is on screen — the rule is
            // `InspectionHolds` and this line is what the sheet prints of it. In the
            // grid the keys size the cells, exactly as they always did; where one
            // photograph is large they are the momentary inspections of docs/10 §10.5,
            // which release on key-up and never touch the recipe.
            KeyRow(keys: "[ ]", action: "In the grid: thumbnail size. In the loupe, "
                  + "Compare and Survey: hold for shadow boost / highlight inspect"),
            KeyRow(keys: "F", action: "Filmstrip"),
        ]),
        // Every one of these is a `.keyboardShortcut` on a SwiftUI button or menu item,
        // and every one is checked against the sources. Seven of them were in neither
        // this list nor the dispatcher until the scan went looking.
        KeyGroup(title: "Menu commands", rows: [
            KeyRow(KeyBinding("s", command: true, option: true),
                   "Show / hide the sources sidebar"),
            KeyRow(KeyBinding("1", command: true), "Cull workspace"),
            KeyRow(KeyBinding("2", command: true), "Develop workspace"),
            KeyRow(KeyBinding("3", command: true), "Crop workspace"),
            KeyRow(KeyBinding("4", command: true), "Grade workspace"),
            KeyRow(KeyBinding("5", command: true), "Deliver workspace"),
            KeyRow(KeyBinding("o", command: true), "Open folder"),
            KeyRow(KeyBinding("i", command: true, shift: true), "Ingest from a card"),
            KeyRow(KeyBinding("z", command: true), "Undo"),
            KeyRow(KeyBinding("z", command: true, shift: true), "Redo"),
            KeyRow(KeyBinding("c", command: true), "Copy settings"),
            KeyRow(KeyBinding("v", command: true), "Paste settings"),
            KeyRow(KeyBinding("c", command: true, option: true), "Copy Look"),
            KeyRow(KeyBinding("v", command: true, option: true), "Paste Look"),
            KeyRow(KeyBinding("r", command: true, shift: true), "Reset settings"),
            KeyRow(KeyBinding("a", command: true), "Select all"),
            KeyRow(KeyBinding("d", command: true), "Select none"),
            KeyRow(KeyBinding("a", command: true, shift: true), "Auto Tone"),
            KeyRow(KeyBinding("e", command: true), "Export"),
            KeyRow(KeyBinding("b", command: true), "Add the selection to the target album"),
            KeyRow(KeyBinding("k", command: true), "Go to a control"),
            KeyRow(KeyBinding("k", command: true, shift: true),
                   "Keyword the selection"),
            KeyRow(KeyBinding("g", command: true), "Stack the selection"),
            KeyRow(KeyBinding("g", command: true, shift: true), "Unstack"),
            KeyRow(KeyBinding("\\", command: true), "Clear the filter"),
            KeyRow(KeyBinding("/", command: true), "This reference"),
            KeyRow(KeyBinding("l", command: true, option: true),
                   "Show / hide the latency HUD (Debug)"),
        ]),
    ]

    /// Every chord the table promises. The parity scan compares this against the
    /// `.keyboardShortcut` calls it finds in Sources/LumenApp, in both directions.
    public static var declaredBindings: Set<KeyBinding> {
        Set(groups.flatMap(\.rows).compactMap(\.binding))
    }

    /// Every bare character `KeyDispatcher`'s character switch claims.
    ///
    /// Declared rather than derived because the switch is code and this is data; the
    /// test asserts they are the same set, which is the only way "the reference cannot
    /// drift from the dispatcher" is a fact rather than an intention.
    public static let dispatchedKeys: Set<String> = [
        // Views
        "g", "e", "c", "n", " ",
        // Flags, ratings, labels
        "p", "x", "u", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "-",
        // Editing and panels
        "\\", "y", "r", "m", "o", "'", "b", "l", "d", "h", "s", "a", "f",
        // Zoom and thumbnail size
        "z", "=", "+", "[", "]",
    ]

    /// Files allowed to attach a `.keyboardShortcut` whose key is computed rather than
    /// written as a literal, with the reason. A scanner cannot read those, so they are
    /// listed here — an escape hatch that is itself data, and that a new file cannot
    /// join without this table changing.
    public static let filesWithComputedShortcuts: [String: String] = [
        "LookPanel.swift":
            "The printer-light steppers take their key and modifiers as parameters, so "
            + "one row type serves the master and the three colour trims. The four "
            + "chords are listed under Develop.",
        "CropPanel.swift":
            "Return commits the crop (docs/09). It is written as the `KeyEquivalent` "
            + "`.return` rather than a string, because a bare carriage return in a "
            + "source file is not a literal a scanner can read back. Listed under "
            + "Develop.",
    ]
}
