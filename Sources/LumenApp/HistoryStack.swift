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
    }

    /// Deep history is cheap (a recipe is a few kilobytes) but not free, and nobody
    /// undoes past a few hundred steps.
    static let limit = 400

    /// A drag that pauses longer than this starts a new undo step, so "nudge, think,
    /// nudge again" gives you two steps to walk back through.
    static let coalescingWindow: TimeInterval = 1.2

    @Published private(set) var steps: [Step] = [] { didSet { onChange?() } }
    @Published private(set) var position = 0 { didSet { onChange?() } }

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
    /// and a notification you have to remember to send is one you eventually do not.
    /// It fires more often than strictly needed (`record`'s append path moves both
    /// properties), which is why the receiving end is equality-guarded.
    var onChange: (@MainActor () -> Void)?

    private var lastEditTime = Date.distantPast

    var canUndo: Bool { position > 0 }
    var canRedo: Bool { position < steps.count }

    var undoLabel: String? { canUndo ? steps[position - 1].label : nil }
    var redoLabel: String? { canRedo ? steps[position].label : nil }

    func record(before: [URL: PhotoEdit], after: [URL: PhotoEdit],
                coalescingKey: String?, label: String? = nil) {
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
               window: Self.coalescingWindow),
           let key = coalescingKey {
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
            steps[position - 1] = Step(before: open.before, after: merged,
                                       coalescingKey: key, label: open.label)
            return
        }

        if position < steps.count {
            steps.removeSubrange(position...)
        }
        // A coalescing key is an identity for merging, not prose: falling back to it
        // put "Undo mask.c.amount.9F3B-…" in the Edit menu.
        steps.append(Step(before: before, after: after, coalescingKey: coalescingKey,
                          label: label ?? "Edit"))
        if steps.count > Self.limit {
            steps.removeFirst(steps.count - Self.limit)
        }
        position = steps.count
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
        steps = []
        position = 0
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
