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

    struct Step {
        let before: [URL: Recipe]
        let after: [URL: Recipe]
        let coalescingKey: String?
        let label: String
    }

    /// Deep history is cheap (a recipe is a few kilobytes) but not free, and nobody
    /// undoes past a few hundred steps.
    static let limit = 400

    /// A drag that pauses longer than this starts a new undo step, so "nudge, think,
    /// nudge again" gives you two steps to walk back through.
    static let coalescingWindow: TimeInterval = 1.2

    @Published private(set) var steps: [Step] = []
    @Published private(set) var position = 0     // index of the next step to redo

    private var lastEditTime = Date.distantPast

    var canUndo: Bool { position > 0 }
    var canRedo: Bool { position < steps.count }

    var undoLabel: String? { canUndo ? steps[position - 1].label : nil }
    var redoLabel: String? { canRedo ? steps[position].label : nil }

    func record(before: [URL: Recipe], after: [URL: Recipe],
                coalescingKey: String?, label: String? = nil) {
        let now = Date()
        defer { lastEditTime = now }

        if let key = coalescingKey, canUndo,
           steps[position - 1].coalescingKey == key,
           now.timeIntervalSince(lastEditTime) < Self.coalescingWindow {
            // Extend the open step: keep its original `before`, take the new `after`.
            let open = steps[position - 1]
            var merged = open.after
            for (url, recipe) in after { merged[url] = recipe }
            steps[position - 1] = Step(before: open.before, after: merged,
                                       coalescingKey: key, label: open.label)
            return
        }

        if position < steps.count {
            steps.removeSubrange(position...)
        }
        steps.append(Step(before: before, after: after, coalescingKey: coalescingKey,
                          label: label ?? coalescingKey ?? "Edit"))
        if steps.count > Self.limit {
            steps.removeFirst(steps.count - Self.limit)
        }
        position = steps.count
    }

    func undo() -> [URL: Recipe]? {
        guard canUndo else { return nil }
        position -= 1
        lastEditTime = .distantPast      // never coalesce across an undo
        return steps[position].before
    }

    func redo() -> [URL: Recipe]? {
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
