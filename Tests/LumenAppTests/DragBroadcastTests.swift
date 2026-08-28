// What a slider drag BROADCASTS, as a count.
//
// The owner's report — "every single slider is still going and updating little by
// little … that is for every slider in the app" — is a description of the main actor
// losing a race, and the thing it loses the race to is not rendering. `AppState` is one
// `ObservableObject` with sixty `@Published` properties, held by `LumenApp` as a
// `@StateObject` and by ~26 view structs as an `@EnvironmentObject`, and
// `ObservableObject` has no per-property granularity: any published write invalidates
// every observer. `updateRecipe` runs once per mouse event for the whole length of a
// drag, and it used to publish TWICE per event — the recipe write itself, and a
// `history.objectWillChange` forward that existed so the Edit menu's undo label could
// stay current. Each of those rebuilt the window and the entire menu bar.
//
// The consequence is worse than wasted work. Once a whole-window pass no longer fits
// between two mouse-moved events, AppKit coalesces the events it has not delivered, so
// the app stops SEEING positions rather than merely drawing fewer of them — and the
// thumb, the number and the picture all advance in the same coarse steps. That is why
// the complaint is about every slider at once: it is a property of the broadcast they
// share, not of any control.
//
// These tests count publishes. They are cheap, they run on the app layer's own target,
// and they fail the moment somebody puts a per-event write back on the shared object.
#if os(macOS)
import Combine
import XCTest
@testable import LumenApp
@testable import LumenCore

@MainActor
final class DragBroadcastTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    /// One photograph's edit, as `updateRecipe` records it.
    private func step(_ exposure: Double) -> [URL: HistoryStack.PhotoEdit] {
        var recipe = Recipe()
        recipe.develop.tone.exposure = exposure
        return [URL(fileURLWithPath: "/roll/a.arw"):
                    HistoryStack.PhotoEdit(recipe: recipe)]
    }

    /// A drag is 48 mouse events and ONE undo step. The menu bar should hear about it
    /// once — when the step opens and "Undo" becomes available — and not again, because
    /// nothing it displays moves while a hand is on a slider: the label reads "Edit"
    /// from the first event to the last.
    ///
    /// Before `CommandState`, a blanket `history.objectWillChange` → `AppState`
    /// forward turned each of those 48 coalescing writes into a full invalidation of
    /// the window and of `LumenApp`'s `Scene` — seven menus and twenty-five items,
    /// rebuilt per mouse event.
    func testACoalescedDragTellsTheMenuBarOnceNotOncePerEvent() {
        let history = HistoryStack()
        let commands = CommandState()
        history.onChange = { [weak history] in
            guard let history else { return }
            commands.refresh(undoLabel: history.undoLabel,
                             redoLabel: history.redoLabel,
                             hasCatalog: true, hasSelection: true,
                             showLatencyHUD: false)
        }

        // Seed the two facts that are not about history, so the count below is about
        // the drag and not about a catalog appearing.
        commands.refresh(undoLabel: nil, redoLabel: nil, hasCatalog: true,
                         hasSelection: true, showLatencyHUD: false)

        var publishes = 0
        commands.objectWillChange.sink { _ in publishes += 1 }.store(in: &cancellables)

        for event in 0..<48 {
            history.record(before: step(0), after: step(Double(event) / 48),
                           coalescingKey: "tone.exposure")
        }

        XCTAssertEqual(history.steps.count, 1,
                       "the fixture must actually be one coalesced drag")
        XCTAssertEqual(publishes, 1,
                       "48 mouse events folding into one undo step may cost the menu "
                           + "bar one rebuild — the one where Undo became available — "
                           + "and not 48")
    }

    /// The guard that makes the above true is equality, not luck: `@Published` performs
    /// no equality check of its own, so an unguarded assignment of an unchanged value
    /// publishes. `CommandState.refresh` is called from the per-event path, so a
    /// missing guard there would put the cost straight back.
    func testRefreshingCommandStateWithUnchangedFactsIsSilent() {
        let commands = CommandState()
        commands.refresh(undoLabel: "Edit", redoLabel: nil, hasCatalog: true,
                         hasSelection: true, showLatencyHUD: false)

        var publishes = 0
        commands.objectWillChange.sink { _ in publishes += 1 }.store(in: &cancellables)

        for _ in 0..<48 {
            commands.refresh(undoLabel: "Edit", redoLabel: nil, hasCatalog: true,
                             hasSelection: true, showLatencyHUD: false)
        }
        XCTAssertEqual(publishes, 0, "nothing moved, so nothing may be published")

        commands.refresh(undoLabel: "Edit", redoLabel: nil, hasCatalog: true,
                         hasSelection: false, showLatencyHUD: false)
        XCTAssertEqual(publishes, 1, "a fact that DID move must still be published")
        XCTAssertFalse(commands.hasSelection)
    }

    /// The signal exists at all: a view that shows the edit has something to observe
    /// now that `AppState.recipes` does not publish.
    func testTheEditSignalPublishesOncePerEdit() {
        let edits = EditRevision()
        var publishes = 0
        edits.objectWillChange.sink { _ in publishes += 1 }.store(in: &cancellables)

        for _ in 0..<48 { edits.bump() }

        XCTAssertEqual(publishes, 48,
                       "every edit must reach the surfaces that draw the photograph — "
                           + "this half is not an optimisation")
    }

    /// History's own mutations must still be heard, or the fix trades a slow menu for a
    /// wrong one. This is the failure the forward was originally added to prevent, and
    /// it is the one a replacement is most likely to reintroduce.
    func testEveryHistoryMutationSignals() {
        let history = HistoryStack()
        var signals = 0
        history.onChange = { signals += 1 }

        history.record(before: step(0), after: step(1), coalescingKey: nil)
        XCTAssertGreaterThan(signals, 0, "recording a step must signal")

        signals = 0
        _ = history.undo()
        XCTAssertGreaterThan(signals, 0, "undo must signal — the menu item's label and "
                                + "enablement both change")

        signals = 0
        _ = history.redo()
        XCTAssertGreaterThan(signals, 0, "redo must signal")

        signals = 0
        history.clear()
        XCTAssertGreaterThan(signals, 0, "clearing on a folder switch must signal")
    }

    /// THE OBSERVER MUST NEVER SEE HALF A MUTATION, and this is not a tidiness point.
    ///
    /// `steps` and `position` are two halves of one value, and every derived member
    /// reads both — `canUndo` is `position > 0` while `undoLabel` subscripts
    /// `steps[position - 1]`. A callback hung off each property's `didSet` fires
    /// between them, where the pair is inconsistent, and it is wrong in two ways at
    /// once. `record`'s append grows `steps` before advancing `position`, so `canRedo`
    /// goes spuriously true and the Edit menu flickers a Redo item that never existed.
    /// `clear()` empties `steps` before zeroing `position`, so `undoLabel` subscripts
    /// an empty array — an out-of-range CRASH on the first folder switch after any
    /// edit, which is what this test found.
    ///
    /// Reading both labels inside the callback is the assertion: an inconsistent stack
    /// traps rather than returning something merely wrong.
    func testTheObserverNeverSeesHalfAMutation() {
        let history = HistoryStack()
        // Plain strings, not optionals: `seen.last?.undo` on a tuple whose member is
        // itself `String?` is a DOUBLE optional, and `?? "not nil"` against it reads as
        // a nil check while actually testing whether the array is empty. The first
        // version of this test did exactly that and reported the wrong thing.
        // `—` stands in for nil, the way the menu would render it.
        var seen: [(undo: String, redo: String)] = []
        // Captured strongly, and released at the end. A `[weak]` capture here is the
        // only structural difference from `testEveryHistoryMutationSignals`, which
        // passes, and a test that disagrees with its neighbour about whether a callback
        // fired should not be the one holding the weak reference.
        history.onChange = {
            seen.append((history.undoLabel ?? "—", history.redoLabel ?? "—"))
        }
        defer { history.onChange = nil }

        for i in 0..<3 {
            history.record(before: step(0), after: step(Double(i)), coalescingKey: nil)
        }
        XCTAssertEqual(history.steps.count, 3, "the fixture must be three steps")
        XCTAssertEqual(seen.count, 3, "one signal per recorded step, not two")
        XCTAssertFalse(seen.contains { $0.redo != "—" },
                       "recording a step leaves nothing to redo; a signal reporting "
                           + "one was fired between the two halves of the mutation")

        seen.removeAll()
        _ = history.undo()
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.last?.redo, "Edit",
                       "after an undo there is always something to redo")

        seen.removeAll()
        _ = history.redo()
        XCTAssertEqual(seen.count, 1)

        // The crash, if it is back: `clear` empties the array while `position` still
        // points into it, and `undoLabel` subscripts `steps[position - 1]`.
        seen.removeAll()
        history.clear()
        XCTAssertEqual(seen.count, 1, "clearing is one mutation, so one signal")
        XCTAssertEqual(seen.last?.undo, "—")
        XCTAssertEqual(seen.last?.redo, "—")
    }

    /// And the labels the menu draws are right at the moment the signal arrives — a
    /// callback that fires BEFORE the mutation would leave the Edit menu one step
    /// behind, which is the same defect wearing different clothes.
    func testTheSignalArrivesAfterTheMutationNotBefore() {
        let history = HistoryStack()
        var labelWhenSignalled: String??
        history.onChange = { [weak history] in labelWhenSignalled = history?.undoLabel }

        history.record(before: step(0), after: step(1), coalescingKey: nil)

        XCTAssertEqual(labelWhenSignalled ?? nil, "Edit",
                       "the receiver must see the stack as it is AFTER the change")
    }
}
#endif
