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
                              coalescingKey: coalescingKey, label: label ?? "Edit",
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

#endif
