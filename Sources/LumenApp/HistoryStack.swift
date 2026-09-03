// HistoryStack.swift
// Undo as a ring of recipe deltas rather than a log of operations. Because rendering
// is a pure function of the recipe, "undo" is just restoring an earlier value — there
// is no inverse operation to get wrong, and no order-of-edits dependence to reason
// about (docs/14 §1.5).
//
// Coalescing is what makes a slider drag one undo step instead of two hundred: while
// the same control is being dragged, successive edits fold into the open step.

#if os(macOS)

import Foundation
import LumenCore

@MainActor
final class HistoryStack: ObservableObject {

    /// The culling decisions, as one undoable value.
    struct Culling: Equatable {
        var flag: PhotoFlag
        var rating: Int
        var label: ColorLabel
    }

    /// What one step can restore for one photo. Each field is optional because a step
    /// records only what it touched: restoring a rating must not also drag a recipe
    /// back to whatever it was when the star was pressed.
    struct PhotoEdit: Equatable {
        var recipe: Recipe?
        var culling: Culling?

        init(recipe: Recipe? = nil, culling: Culling? = nil) {
            self.recipe = recipe
            self.culling = culling
        }
    }

    struct Step {
        let before: [URL: PhotoEdit]
        let after: [URL: PhotoEdit]
        let coalescingKey: String?
        let label: String
        /// The drag this step was opened during, or nil outside one. Two edits from
        /// the same gesture fold together whatever fields they wrote.
        var gestureEpoch: Int?
    }

    /// Deep history is cheap (a recipe is a few kilobytes) but not free, and nobody
    /// undoes past a few hundred steps.
    static let limit = 400

    /// The label a step wears when its caller named none — which is nearly every step,
    /// because every slider drag arrives through `updateRecipe` with a coalescing key
    /// and no label.
    ///
    /// A NAMED CONSTANT because two places now depend on it. The Edit menu prints
    /// "Undo Edit" for these and always has; the history list cannot, because a column
    /// of twenty rows all reading "Edit" is not a history, it is a tally. So
    /// `HistoryStack.title(label:coalescingKey:)` treats this exact string as "nobody
    /// named this step" and derives a name from the coalescing key instead — and a
    /// literal `"Edit"` written in two files is how that agreement would quietly end.
    static let unnamedLabel = "Edit"

    /// A drag that pauses longer than this starts a new undo step, so "nudge, think,
    /// nudge again" gives you two steps to walk back through.
    static let coalescingWindow: TimeInterval = 1.2

    @Published private(set) var steps: [Step] = [] { didSet { signalChange() } }
    @Published private(set) var position = 0 { didSet { signalChange() } }

    /// Called after any mutation, so `AppState` can bring `CommandState` up to date
    /// without observing this object.
    ///
    /// It replaces a blanket `objectWillChange` forward from here into `AppState` —
    /// which meant that folding one mouse event of a drag into the open undo step
    /// invalidated the entire window and the entire menu bar, so that the Edit menu
    /// could keep a label reading "Edit". See `CommandState` for the whole story.
    ///
    /// Hung off `didSet` on both stored properties rather than called at the end of
    /// each mutating method: there are five of those and a sixth is one refactor away,
    /// and a notification you have to remember to send is one that eventually is not.
    var onChange: (@MainActor () -> Void)?

    /// Suppresses the callback while a mutation is only half done. See `atomically`.
    private var suppressedSignals = 0

    private func signalChange() {
        guard suppressedSignals == 0 else { return }
        onChange?()
    }

    /// Run a mutation that moves BOTH stored properties, so an observer sees it once
    /// and only once it is complete.
    ///
    /// This is not a tidiness measure. `steps` and `position` are two halves of one
    /// value, and every derived member reads both: `canUndo` is `position > 0` while
    /// `undoLabel` subscripts `steps[position - 1]`. Between the two assignments the
    /// pair is inconsistent, and firing the callback there is not merely noisy —
    /// it is wrong, and in two places it is fatal.
    ///
    ///   · `record`'s append path grows `steps` before advancing `position`, so for
    ///     one call `position < steps.count` holds spuriously: `canRedo` goes true and
    ///     the Edit menu flickers a Redo item that never existed, at three publishes
    ///     per drag instead of one. `DragBroadcastTests` counted exactly that, which
    ///     is how this was found.
    ///   · `clear()` empties `steps` before zeroing `position`, so `canUndo` is still
    ///     true against an empty array and `undoLabel` subscripts `steps[position - 1]`
    ///     — an out-of-range crash on the first folder switch after any edit. The
    ///     trim past `limit` in `record` is the same shape, 400 steps later.
    ///
    /// The old `objectWillChange` forward never met either, because SwiftUI coalesces
    /// invalidations to the end of the runloop turn and nothing read the stack DURING
    /// the mutation. A direct callback does, so the atomicity has to be real.
    private func atomically(_ body: () -> Void) {
        suppressedSignals += 1
        body()
        suppressedSignals -= 1
        signalChange()
    }

    private var lastEditTime = Date.distantPast

    var canUndo: Bool { position > 0 }
    var canRedo: Bool { position < steps.count }

    var undoLabel: String? { canUndo ? steps[position - 1].label : nil }
    var redoLabel: String? { canRedo ? steps[position].label : nil }

    /// - Parameter gestureEpoch: the drag this edit belongs to, or nil outside one.
    ///   It is what makes a gesture one undo step even when the control writes several
    ///   fields under several keys — see `HistoryCoalescing.shouldCoalesce`.
    func record(before: [URL: PhotoEdit], after: [URL: PhotoEdit],
                coalescingKey: String?, label: String? = nil,
                gestureEpoch: Int? = nil) {
        let now = Date()
        defer { lastEditTime = now }

        // The rule lives in LumenCore (HistoryCoalescing) where it is tested. The
        // third input — the photo sets must MATCH — is what keeps a drag that spans a
        // photo switch from folding photo B's edit into photo A's open step, where
        // undo would revert the off-screen photo and B's pre-drag state would never
        // have been recorded at all.
        if canUndo,
           HistoryCoalescing.shouldCoalesce(
               openKey: steps[position - 1].coalescingKey,
               openURLs: Set(steps[position - 1].after.keys),
               key: coalescingKey,
               urls: Set(after.keys),
               sinceLastEdit: now.timeIntervalSince(lastEditTime),
               window: Self.coalescingWindow,
               openEpoch: steps[position - 1].gestureEpoch,
               epoch: gestureEpoch) {
            // Extend the open step: keep its original `before`, take the new `after`.
            // Field-wise, so folding a recipe edit into an open step cannot erase a
            // culling change already recorded in it for the same photo.
            let open = steps[position - 1]
            var merged = open.after
            for (url, edit) in after {
                var combined = merged[url] ?? PhotoEdit()
                if let recipe = edit.recipe { combined.recipe = recipe }
                if let culling = edit.culling { combined.culling = culling }
                merged[url] = combined
            }
            // The open step keeps its own key and epoch: it is still the same step,
            // and a wheel drag's second field must not rename it.
            steps[position - 1] = Step(before: open.before, after: merged,
                                       coalescingKey: open.coalescingKey,
                                       label: open.label,
                                       gestureEpoch: open.gestureEpoch)
            return
        }

        // `steps` and `position` are two halves of one value and three statements
        // apart here; an observer that saw the middle would see a Redo item that never
        // existed, and past `limit` an out-of-range subscript. See `atomically`.
        atomically {
            if position < steps.count {
                steps.removeSubrange(position...)
            }
            // A coalescing key is an identity for merging, not prose: falling back to
            // it put "Undo mask.c.amount.9F3B-…" in the Edit menu.
            steps.append(Step(before: before, after: after,
                              coalescingKey: coalescingKey,
                              label: label ?? Self.unnamedLabel,
                              gestureEpoch: gestureEpoch))
            if steps.count > Self.limit {
                steps.removeFirst(steps.count - Self.limit)
            }
            position = steps.count
        }
    }

    func undo() -> [URL: PhotoEdit]? {
        guard canUndo else { return nil }
        position -= 1
        lastEditTime = .distantPast      // never coalesce across an undo
        return steps[position].before
    }

    func redo() -> [URL: PhotoEdit]? {
        guard canRedo else { return nil }
        let step = steps[position]
        position += 1
        lastEditTime = .distantPast
        return step.after
    }

    func clear() {
        // Emptying `steps` while `position` still points into it leaves `canUndo` true
        // against an empty array, and `undoLabel` subscripts `steps[position - 1]`.
        // Unwrapped, this crashed on the first folder switch after any edit.
        atomically {
            steps = []
            position = 0
        }
        lastEditTime = .distantPast
    }

    // MARK: - Snapshots

    struct Snapshot: Identifiable {
        let id = UUID()
        var name: String
        var recipe: Recipe
        var created: Date
    }

    @Published var snapshots: [Snapshot] = []

    func snapshot(_ recipe: Recipe, named name: String) {
        snapshots.append(Snapshot(name: name, recipe: recipe, created: Date()))
    }

    func removeSnapshot(_ id: UUID) {
        snapshots.removeAll { $0.id == id }
    }
}

// MARK: - What the history list draws

// THE STACK IS GLOBAL AND THE LIST IS PER PHOTOGRAPH, and reconciling those two is the
// whole of this extension.
//
// A `Step` is `[URL: PhotoEdit]` on both sides, because one keystroke over a
// multi-selection is one step and `record` is called once for the whole of it. So there
// is no such thing as "photo A's stack" to hand a view — there is one stack, and a
// photograph's history is the SUBSEQUENCE of it that touched that photograph. Deriving
// that here rather than in the view is what makes it testable at all (`LumenApp` builds
// on one lane and no test in this package can construct a `View`), and it is what makes
// the answer change the instant the selection does: the list is a pure function of
// `steps` and a URL, so switching photographs cannot show the last one's history
// because there is nothing cached to be stale. `HistoryPanelTests` pins that directly.
//
// EVERY MEMBER HERE IS PURE AND STATIC. Nothing reads `self`, nothing retains a
// `Recipe`, and an `Entry` is three small values — an Int and two Strings. That is the
// panel's whole retention policy: the stack's own 400-step ring is the only place a
// recipe lives, and the list that draws it holds integers and prose.
extension HistoryStack {

    /// One row of the history list — everything the panel draws for one step, and
    /// nothing else.
    ///
    /// `position` is the STACK POSITION this row restores, not an index into `steps`:
    /// row *n* puts the photograph into the state that step *n* produced, which is
    /// `position == n + 1`, because `position` counts steps applied. It doubles as the
    /// identity because it is unique by construction — one row per step, plus the base
    /// row below the earliest one.
    struct Entry: Identifiable, Equatable {
        let position: Int
        let title: String
        /// A short qualifier under the title's own line — the value a culling step set,
        /// how many photographs the step moved, or both. Nil for the ordinary case,
        /// which is one photograph and one control.
        let detail: String?

        var id: Int { position }
    }

    /// THE BASE ROW. Every photograph's list starts below its first step, so there is
    /// somewhere to click that means "as I found it".
    ///
    /// Not "Original": this stack is the SESSION's — `clear()` empties it on a folder
    /// switch — so the bottom of the list is where the photograph was when the folder
    /// opened, which for an already-edited frame is not its original state at all.
    /// Naming it for what it actually is costs one word and avoids promising a reset
    /// this row does not perform.
    static let openedTitle = "As opened"

    /// One photograph's history, oldest first, as the panel's rows.
    ///
    /// Oldest first because that is the order `steps` is in and the order `position`
    /// counts in; the panel reverses it to draw, which is a presentation decision and
    /// belongs there rather than here.
    static func entries(steps: [Step], for url: URL) -> [Entry] {
        var rows: [Entry] = []
        for (index, step) in steps.enumerated() where step.after[url] != nil {
            // The base row's position is the index of the earliest step that touched
            // this photograph — undo back to there and none of its steps have been
            // applied. It is emitted lazily, so a photograph with no history has no
            // rows at all rather than a lone "As opened" under an empty list.
            if rows.isEmpty {
                rows.append(Entry(position: index, title: openedTitle, detail: nil))
            }
            rows.append(Entry(position: index + 1,
                              title: title(label: step.label,
                                           coalescingKey: step.coalescingKey),
                              detail: detail(step, url: url)))
        }
        return rows
    }

    /// Which row the photograph is showing, as an index into `entries`.
    ///
    /// The LAST row at or before the cursor, not the row whose position equals it — and
    /// the difference is the multi-photograph case rather than an edge case. Edit photo
    /// A, switch to B, edit B: the cursor is at 2 and A's rows stop at 1, so an equality
    /// test would mark nothing current and A's list would claim to be nowhere. A is in
    /// fact showing the state its own last step produced, which is exactly "the latest
    /// listed step at or before the cursor".
    static func currentRow(in entries: [Entry], position: Int) -> Int? {
        guard !entries.isEmpty else { return nil }
        var row = 0
        for (index, entry) in entries.enumerated() where entry.position <= position {
            row = index
        }
        return row
    }

    // MARK: The step's name

    /// The word a photographer would use for what a step did.
    ///
    /// THE PROBLEM THIS SOLVES, measured: six call sites in the whole application pass
    /// a `label` — "Auto Tone", "Paste Settings", "Delete Mask", "Flag", "Rating",
    /// "Label" — and every other step in the app arrives from `updateRecipe` with a
    /// coalescing key and no label at all. The Edit menu can live with that, because it
    /// prints one item; a list cannot, because twenty rows reading "Edit" is a tally
    /// rather than a history and would leave the panel worse than the undo it replaces.
    ///
    /// So a named step keeps its name — those six are already prose — and an unnamed one
    /// is named from the key it coalesces under. The keys are dotted paths written for
    /// merging rather than for reading (`tone.exposure`, `detail.sharpen.amount`,
    /// `mask.c.amount.9F3B-…`), and the rules below turn them into words:
    ///
    ///   · Non-alphabetic components go, because they are identities rather than
    ///     vocabulary — a mask's UUID, a curve point's index, a wheel's band number.
    ///   · A key ending in `reset` is a Reset OF something, and the something is the
    ///     component before it. `workspace.<section>.reset` asks the section itself for
    ///     its title, so "Reset Colour" cannot drift from the header that says "Colour".
    ///   · A generic leaf — Amount, Size, Mode, Profile — is qualified by the component
    ///     before it, because "Amount" alone names four different sliders.
    ///   · A few heads own leaves that mean nothing alone (`mask`, `denoise`, `point`),
    ///     so those qualify every leaf under them.
    ///
    /// It degrades rather than fails: an unrecognised key still yields its own last word
    /// in mixed case, which is always better than the key.
    static func title(label: String, coalescingKey: String?) -> String {
        guard label == unnamedLabel, let coalescingKey else { return label }
        let words = coalescingKey.split(separator: ".").map(String.init)
            .filter { !$0.isEmpty && $0.allSatisfy(\.isLetter) }
        guard let leaf = words.last else { return label }
        if leaf == "reset" { return resetTitle(words) }
        let name = word(leaf)
        guard words.count > 1 else { return name }
        let qualifier = headWord(words[0])
            ?? (genericLeaves.contains(leaf) ? word(words[words.count - 2]) : nil)
        // A qualifier equal to the name it qualifies is `histogram.zone.` reading
        // "Zone Zone". One guard rather than a special case per collision.
        guard let qualifier, qualifier != name else { return name }
        return qualifier + " " + name
    }

    /// "Reset Colour", not "Reset color" and not "Reset".
    private static func resetTitle(_ words: [String]) -> String {
        // The accordion header's Reset is `workspace.<rawValue>.reset`, and the section
        // already holds the word the header printed above the button that was pressed.
        // Asking it is what stops this file owning a second copy of fourteen section
        // names — `WorkspaceSection.title` spells `.color` "Colour" and this would have
        // said "Color" one row under a header that does not.
        if words.count >= 3, words[0] == "workspace",
           let section = WorkspaceSection(rawValue: words[1]) {
            return "Reset " + section.title
        }
        guard words.count >= 2 else { return "Reset" }
        return "Reset " + word(words[words.count - 2])
    }

    /// The heads whose leaves are meaningless on their own, and the word each lends.
    ///
    /// A switch rather than a dictionary for the reason `WorkspaceSection.symbolName`
    /// gives one file over: the default is the interesting branch here — most heads
    /// (`tone`, `wb`, `look`, `color`, `detail`) have leaves that read perfectly alone,
    /// and qualifying those would give the list "Tone Exposure".
    private static func headWord(_ head: String) -> String? {
        switch head {
        case "mask": return "Mask"
        case "maskgroup": return "Mask Group"
        case "denoise": return "Denoise"
        // The zone system, under two heads: the tone section's zone strip writes
        // `zones.…` and the histogram's own zone readout writes `histogram.zone.`.
        case "zones", "histogram": return "Zone"
        case "wheels": return "Grading"
        case "mixer": return "Colour Mixer"
        case "point": return "Point Colour"
        case "printer": return "Printer Light"
        default: return nil
        }
    }

    /// Leaves that name a QUANTITY rather than a control, and so have to borrow the
    /// component before them. `detail.sharpen.amount` and `denoise.amount` are both
    /// "Amount"; only the qualifier tells them apart.
    private static let genericLeaves: Set<String> = [
        "amount", "size", "radius", "detail", "mode", "auto", "profile", "preset",
        "strength", "name", "value", "blend", "opacity", "angle", "feather",
    ]

    /// A camelCase identifier as words — `vignetteFeather` → "Vignette Feather" — with a
    /// short table for the abbreviations that would otherwise arrive as themselves.
    private static func word(_ raw: String) -> String {
        if let known = knownWords[raw] { return known }
        var out = ""
        for (index, character) in raw.enumerated() {
            if character.isUppercase && index > 0 { out.append(" ") }
            out.append(index == 0 ? character.uppercased() : String(character))
        }
        return out
    }

    private static let knownWords: [String: String] = [
        "wb": "White Balance",
        "temp": "Temperature",
        "bw": "Black & White",
        "hsl": "HSL",
    ]

    // MARK: What the step was worth

    /// The qualifier under a row's title: the value a culling step set, the number of
    /// photographs a step moved, or both.
    ///
    /// A recipe step gets no value and that is deliberate. Naming the number a slider
    /// landed on would need a key-to-keypath registry that does not exist — every
    /// binding in the app pairs a `KeyPath` with a coalescing key at its call site and
    /// registers neither — and inventing one here would be a table of forty entries
    /// that rots silently the first time a slider is renamed. A culling step needs no
    /// registry: `PhotoEdit.culling` IS the value, in the step, already.
    private static func detail(_ step: Step, url: URL) -> String? {
        let scope = step.after.count > 1 ? "\(step.after.count) photos" : nil
        guard let value = cullingDetail(before: step.before[url]?.culling,
                                        after: step.after[url]?.culling)
        else { return scope }
        return scope.map { value + " · " + $0 } ?? value
    }

    /// What a culling step SET, read from the two sides rather than from the label.
    ///
    /// `mutateTargets` passes "Flag", "Rating" or "Label", so switching on that string
    /// would work today and would be a third place those three words are written. The
    /// diff answers the same question from the data, and it is the data the row is
    /// describing.
    private static func cullingDetail(before: Culling?, after: Culling?) -> String? {
        guard let after else { return nil }
        if before?.flag != after.flag {
            switch after.flag {
            case .picked: return "Pick"
            case .rejected: return "Reject"
            case .none: return "Unflagged"
            }
        }
        if before?.rating != after.rating {
            return after.rating <= 0 ? "No stars"
                : String(repeating: "★", count: after.rating)
        }
        if before?.label != after.label { return after.label.displayName }
        return nil
    }
}

#endif
