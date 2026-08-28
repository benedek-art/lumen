// CommandState.swift
// The four facts the menu bar and the develop footer's undo/redo pair DISPLAY, as an
// observable of their own, so that keeping them current costs a body pass in the menu
// bar rather than a body pass in the whole application.
//
// WHY THIS TYPE EXISTS, precisely.
//
// `HistoryStack` is its own `ObservableObject`, and SwiftUI re-renders a view only for
// the object it observes. The Edit menu reads `state.history`, so without something in
// between, the undo item's enablement refreshed only when a recipe happened to change
// on the same tick — correct by accident, and wrong the first time history moved on its
// own. The fix that shipped was a blanket forward in `AppState.init`:
//
//     historyObserver = history.objectWillChange.sink { [weak self] _ in
//         self?.objectWillChange.send()
//     }
//
// That is a correct answer to the question and an expensive one, because of where
// `history.record` is called from. `AppState.updateRecipe` records a step on EVERY
// mouse event of every slider drag — coalescing folds it into the open step, which
// means REPLACING `steps[position - 1]`, which mutates a `@Published` array, which
// fires `history.objectWillChange`, which the forward turned into
// `AppState.objectWillChange`. And `AppState` is held by `LumenApp` as a `@StateObject`
// and by every panel as an `@EnvironmentObject`, so each of those became a full
// invalidation of the window AND of the `Scene` body — all seven `.commands` menus,
// rebuilt, per mouse event, so that a menu item nobody had opened could keep a label
// that says "Edit" for the whole gesture anyway.
//
// Two publishes per event, then: this one and the recipe write itself. Once the main
// actor cannot finish two whole-window passes inside the gap between two mouse events,
// AppKit coalesces the events it has not delivered — and from that point the app stops
// SEEING positions rather than merely rendering fewer of them. The thumb, the number
// and the picture all move in the same coarse steps, on every slider at once, which is
// exactly the report this work started from.
//
// So the forward is gone and this is what replaces it. It holds only what is drawn,
// every setter is equality-guarded, and nothing on it moves during a drag: a gesture
// coalesces into one history step whose label is "Edit" from the first event to the
// last. `AppState.refreshCommandState()` may therefore be called as often as is
// convenient — it is, on every recorded step — and it publishes about once per gesture.

#if os(macOS)

import Foundation

/// What the menu bar and the develop footer show about state that is otherwise none of
/// their business. Written only by `AppState`; read by `LumenApp`'s commands and by
/// `DevelopPanel`'s footer.
@MainActor
final class CommandState: ObservableObject {

    /// "Undo Exposure" / nil when there is nothing to undo. `canUndo` is deliberately
    /// not a second field: it is exactly `undoLabel != nil`, and two fields that must
    /// agree is the shape that drifts.
    @Published private(set) var undoLabel: String?
    @Published private(set) var redoLabel: String?

    /// Back Up Catalog has something to back up.
    @Published private(set) var hasCatalog: Bool = false

    /// Export has a photograph to export.
    @Published private(set) var hasSelection: Bool = false

    /// The Debug menu's toggle reads its own title from this.
    @Published private(set) var showLatencyHUD: Bool = false

    var canUndo: Bool { undoLabel != nil }
    var canRedo: Bool { redoLabel != nil }

    /// Bring every field up to date, publishing only for the ones that moved.
    ///
    /// The guards are the whole point rather than a micro-optimisation: `@Published`
    /// does no equality check of its own, so an unguarded assignment of an unchanged
    /// value publishes, and this method is called from the per-event path the type
    /// exists to keep off the per-event path.
    func refresh(undoLabel: String?, redoLabel: String?,
                 hasCatalog: Bool, hasSelection: Bool, showLatencyHUD: Bool) {
        if self.undoLabel != undoLabel { self.undoLabel = undoLabel }
        if self.redoLabel != redoLabel { self.redoLabel = redoLabel }
        if self.hasCatalog != hasCatalog { self.hasCatalog = hasCatalog }
        if self.hasSelection != hasSelection { self.hasSelection = hasSelection }
        if self.showLatencyHUD != showLatencyHUD { self.showLatencyHUD = showLatencyHUD }
    }
}

#endif
