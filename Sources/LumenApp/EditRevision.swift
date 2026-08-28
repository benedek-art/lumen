// EditRevision.swift
// The signal that the photograph's edit changed, as an observable of its own — so that
// moving a slider re-renders the surfaces that show the edit and nothing else.
//
// WHY, and what it is worth.
//
// `AppState.recipes` used to be `@Published`. It is one property out of sixty on an
// object that `LumenApp` holds as a `@StateObject` and that ~26 view structs hold as an
// `@EnvironmentObject` — and `ObservableObject` has no per-property granularity: a
// write to ANY published property fires one `objectWillChange`, and every observer
// re-evaluates its body regardless of which property moved. So `updateRecipe`, called
// once per mouse event for the whole length of a slider drag, invalidated:
//
//   · the filmstrip, whose `ForEach` walks every photograph in the folder,
//   · the grid, the sidebar, the filter bar, the status bar,
//   · the keymap host,
//   · `ContentView` and the split view around all of it,
//   · and `LumenApp`'s `Scene` body — the entire menu bar (see `CommandState`).
//
// None of those show the edit. Every one of them was rebuilt to display a number they
// do not read, on the main actor, between two mouse events.
//
// That is not merely wasted work, and this is the part worth being precise about,
// because it is what makes the failure look the way the owner describes it. Once the
// main actor cannot finish a whole-window pass inside the gap between two mouse-moved
// events, AppKit COALESCES the ones it has not delivered. From that point the app is no
// longer just drawing fewer frames than the hand produced — it is no longer SEEING the
// positions in between. The slider's own thumb, the number beside it and the picture
// all advance in the same coarse steps, because all three are downstream of the same
// dropped events. That is why the report is "every single slider in the app" and never
// one control in particular: it is not a property of any slider, it is a property of
// the broadcast they share.
//
// So the recipe dictionary is no longer published. It is ordinary state on `AppState`,
// and THIS object is what says it moved. The twelve views that show an edit observe it;
// nothing else does.
//
// THE RULE FOR ANYONE ADDING A VIEW: if it reads `state.currentRecipe`,
// `state.recipe(for:)` or `state.strokeSets(for:)`, it must also declare
// `@EnvironmentObject var edits: EditRevision`, or it will render once and then never
// again notice an edit. That is the cost of this design and it is the reason the rule is
// stated here rather than left to be discovered. The alternative — `@Observable`, which
// tracks reads per property and needs no rule — is the migration this is a step toward,
// not a substitute for.

#if os(macOS)

import Foundation

/// Bumped whenever any photograph's recipe changes. Carries no data: the recipes
/// themselves stay on `AppState`, where every existing reader already finds them, and
/// this is only the invalidation those readers were getting from `@Published` before.
@MainActor
final class EditRevision: ObservableObject {

    /// Monotonic. Its value is never read for meaning — a view observes the object, not
    /// the number — but it exists rather than a bare `objectWillChange.send()` so that
    /// the change is a state change SwiftUI can see, and so a `.task(id:)` or an
    /// `.onChange(of:)` can name it if one ever needs to.
    @Published private(set) var value: Int = 0

    func bump() { value &+= 1 }
}

#endif
