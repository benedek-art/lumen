// MaskOverlayRule.swift
// When the red goes up, and what takes it down. One state machine, one writer.
//
// The overlay used to have nine writers of one published variable in `AppState`, with
// precedence expressed by the order the methods happened to run in, a 1400 ms flash
// timer racing a 120 ms hover timer, and a guard struct beside them that only some of
// the writers consulted. The defect the owner reported ("it shows me the red ... and it
// never goes away, even if I'm exposing it") was the plainest possible failure of that
// shape: `setMaskOverlaySuppressed`, the one rule that hid the overlay during an
// adjustment, had lost its only call site, and `addMask` kept the overlay up "until the
// first adjustment", which therefore never came.
//
// Now `AppState` sends EVENTS here and reads ONE answer, `visibleID`, back. Nothing
// else writes the overlay. Every rule is a line of `send`, and every line has a test in
// `MaskOverlayMachineTests` that walks the owner's own scenarios.
//
// The rule, which is Lightroom Classic's:
//
//   · A mask shows its overlay when it is created or selected, and while you work on
//     its SELECTION (paint, drag a gradient, refine the edge, invert it).
//   · The first ADJUSTMENT (any slider that moves pixels rather than the selection)
//     takes it down. While a slider is held, nothing shows, even a pinned overlay.
//   · After that it comes back only by Show Overlay / `O` (the pin, which also returns
//     on release of every later drag), by hovering a row, or by selecting a mask again.

/// What kind of change an edit was, as far as the overlay is concerned.
public enum MaskOverlayEdit: Equatable, Sendable {
    /// Pixels moved by something other than a mask's selection: develop or look fields,
    /// mask groups, a mask's adjustments, Strength or blend. The overlay is in the way.
    case adjustment
    /// A mask's selection changed: its components (strokes, gradients, parameters),
    /// its invert or its edge. The overlay is the only place that is visible.
    case selection(String)

    /// Classify one edit. Nil for edits that are neither (rename, reorder, enable,
    /// add or delete), which leave the overlay exactly as it was.
    ///
    /// Adjustment wins over selection when one write does both, because the pixels
    /// being judged are the ones the overlay would cover.
    public static func classify(old: Recipe, new: Recipe) -> MaskOverlayEdit? {
        var rest = old
        rest.masks = new.masks
        rest.maskGroups = new.maskGroups
        if rest != new { return .adjustment }
        // A group's Strength moves pixels; its name and its fold do not.
        let groupStrength = Dictionary(old.maskGroups.map { ($0.id, $0.amount) },
                                       uniquingKeysWith: { first, _ in first })
        if new.maskGroups.contains(where: { g in
            groupStrength[g.id].map { $0 != g.amount } ?? false
        }) {
            return .adjustment
        }
        let before = Dictionary(old.masks.map { ($0.id, $0) },
                                uniquingKeysWith: { first, _ in first })
        var selected: String?
        for mask in new.masks {
            guard let was = before[mask.id] else { continue }
            if was.adjust != mask.adjust || was.amount != mask.amount
                || was.blend != mask.blend {
                return .adjustment
            }
            if was.components != mask.components || was.invert != mask.invert
                || was.refine != mask.refine {
                selected = mask.id
            }
        }
        return selected.map(MaskOverlayEdit.selection)
    }
}

/// The overlay's whole state, and the one rule that turns it into a mask id.
public struct MaskOverlayMachine: Equatable, Sendable {

    public enum Event: Equatable, Sendable {
        /// A mask was just made, and is selected.
        case created(String)
        /// The photographer selected a mask (row, rail, on-image pin, duplicate).
        case selected(String)
        /// The pointer has dwelt on a mask's row long enough to mean it.
        case hoverBegan(String)
        case hoverEnded
        /// The first movement of a slider or wheel gesture, and its release.
        case gestureBegan
        case gestureEnded
        /// An edit landed. See `MaskOverlayEdit`.
        case edited(MaskOverlayEdit)
        /// An Edge row was pressed: selection work on `id`, before any value moves.
        case selectionWork(String)
        /// `O`, or the Overlay button. `selected` is the mask the panel points at.
        case toggle(selected: String?)
        /// Keep this mask's overlay up (Show Overlay on).
        case pin(String)
        /// Show Overlay off, and everything ambient with it.
        case unpin
        /// These are the masks that exist now; forget any other id.
        case masksPresent(Set<String>)
        /// A different photograph. Mask ids are per-photograph.
        case reset
    }

    /// Show Overlay. A decision, which survives drags and returns on their release.
    public private(set) var pinned = false
    /// Which mask the pin shows. Follows selection, like Lightroom's checkbox.
    public private(set) var pinnedID: String?
    /// The mask just created, selected, or having its selection edited.
    public private(set) var litID: String?
    /// The row under the pointer.
    public private(set) var hoverID: String?
    /// A slider or wheel is held.
    public private(set) var inGesture = false
    /// An adjustment moved during this gesture: nothing shows until release.
    public private(set) var suppressed = false

    public init() {}

    /// The mask whose overlay is on screen, if any. The only output.
    public var visibleID: String? {
        if suppressed { return nil }
        if let hoverID { return hoverID }
        return pinned ? pinnedID : litID
    }

    public mutating func send(_ event: Event) {
        switch event {
        case .created(let id), .selected(let id):
            litID = id
            hoverID = nil
            if pinned { pinnedID = id }

        case .hoverBegan(let id):
            // Not during a drag: a red wash arriving over the pixels being judged is the
            // exact thing the drag rule exists to prevent.
            guard !suppressed else { return }
            hoverID = id

        case .hoverEnded:
            hoverID = nil

        case .gestureBegan:
            inGesture = true

        case .gestureEnded:
            inGesture = false
            suppressed = false

        case .edited(.adjustment):
            // THE RULE THE OWNER WAS MISSING. The lit phase ends, the hover preview
            // ends, and for the rest of a held gesture nothing draws, pin included.
            litID = nil
            hoverID = nil
            if inGesture { suppressed = true }

        case .edited(.selection(let id)), .selectionWork(let id):
            // Painting, dragging a gradient, refining an edge: the overlay is the only
            // view of what is being made, so it shows, mid-gesture or not.
            litID = id
            suppressed = false
            if pinned { pinnedID = id }

        case .toggle(let selected):
            if visibleID != nil {
                // OFF MEANS OFF: the pin, the lit mask and the hover all go, so nothing
                // puts the red straight back on the next pointer exit.
                pinned = false
                pinnedID = nil
                litID = nil
                hoverID = nil
            } else if let selected {
                pinned = true
                pinnedID = selected
                suppressed = false
            }

        case .pin(let id):
            pinned = true
            pinnedID = id
            hoverID = nil

        case .unpin:
            pinned = false
            pinnedID = nil
            litID = nil
            hoverID = nil

        case .masksPresent(let ids):
            if let p = pinnedID, !ids.contains(p) { pinned = false; pinnedID = nil }
            if let l = litID, !ids.contains(l) { litID = nil }
            if let h = hoverID, !ids.contains(h) { hoverID = nil }

        case .reset:
            self = MaskOverlayMachine()
        }
    }

    /// `send`, returning self, for tests and one-line call sites.
    public func sending(_ events: Event...) -> MaskOverlayMachine {
        var copy = self
        for e in events { copy.send(e) }
        return copy
    }
}
