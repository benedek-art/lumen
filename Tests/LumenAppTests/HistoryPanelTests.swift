// What the history list says, and what the panel that draws it is not allowed to hold.
//
// `HistoryStack` has been a complete undo stack with typed edits for as long as the app
// has had one, and until now the whole user interface over it was two menu items. The
// list is the feature; these are the four claims it has to keep.
//
//   · **A photograph's history is its own.** The stack is global — one `Step` carries
//     `[URL: PhotoEdit]` on both sides, because one keystroke over a multi-selection is
//     one step — so "photo A's history" is a subsequence that has to be derived, and the
//     obvious implementation of a list caches it. A cache keyed by nothing is the exact
//     shape that shows the last photograph's history after an arrow-key press, and it is
//     invisible in review because it is right until you move. `HistoryStack.entries` is
//     pure, and these tests pin it against a stack holding two photographs' work
//     interleaved, which is the arrangement that catches an off-by-one in the filter as
//     well as an outright cache.
//
//   · **A step has a name a photographer would use.** Six call sites in the application
//     pass a `label`; every other step arrives from `updateRecipe` with a coalescing key
//     and none, so a list that printed `Step.label` would be twenty rows reading "Edit".
//     The names come from the coalescing keys, which are dotted merge identities rather
//     than prose, and the rules that turn one into the other are worth testing precisely
//     because they are rules rather than a table anyone reads.
//
//   · **Clicking a row records nothing.** A jump is the menu's own undo and redo,
//     repeated. The alternative reading — a jump is itself an edit — would truncate the
//     redo tail (`record` calls `steps.removeSubrange(position...)`), which is to say
//     looking at where you have been would destroy it.
//
//   · **The panel retains nothing.** Rows are an Int and two Strings, built in `body`
//     and thrown away; the stack's 400-step ring is the only place a recipe lives.
//
// `Sources/LumenApp` is `#if os(macOS)` and no test in this package can construct a
// `View`, so the last two are checked as TEXT — and the comments are stripped first,
// which here is load-bearing rather than a formality. `HistoryPanel.swift` names
// `Recipe`, `PhotoEdit` and `ScrollView` in its own header, arguing about why it does
// not hold or nest one; those are three of the exact strings these scans forbid, so an
// unstripped scan would be satisfied by the prose after the code it describes was
// reverted. That is the trap `SurroundPaintTests` and `EditRevisionRuleTests` were both
// bitten by, and it is why the walk below is copied rather than reinvented.

#if os(macOS)
import XCTest
@testable import LumenApp
@testable import LumenCore

@MainActor
final class HistoryPanelTests: XCTestCase {

    private let a = URL(fileURLWithPath: "/roll/a.arw")
    private let b = URL(fileURLWithPath: "/roll/b.arw")

    /// One recipe step on one photograph, built the way `updateRecipe` builds one.
    private func step(_ url: URL, key: String?,
                      label: String = HistoryStack.unnamedLabel) -> HistoryStack.Step {
        var after = Recipe()
        after.develop.tone.exposure = 0.4
        return HistoryStack.Step(before: [url: HistoryStack.PhotoEdit(recipe: Recipe())],
                                 after: [url: HistoryStack.PhotoEdit(recipe: after)],
                                 coalescingKey: key, label: label, gestureEpoch: nil)
    }

    // MARK: - Whose history is this

    /// THE PIN FOR THE SECOND TRAP. Two photographs edited in one session, alternating,
    /// and each list must hold its own work and only its own.
    func testAPhotographsHistoryListsOnlyItsOwnSteps() {
        let steps = [step(a, key: "tone.exposure"), step(b, key: "tone.contrast"),
                     step(a, key: "look.vignette"), step(b, key: "detail.texture")]

        XCTAssertEqual(HistoryStack.entries(steps: steps, for: a).map(\.title),
                       [HistoryStack.openedTitle, "Exposure", "Vignette"],
                       "photo A's history is showing another photograph's steps — the "
                       + "list has to be derived from the URL every time it is drawn, "
                       + "because the stack is one stack for the whole selection")
        XCTAssertEqual(HistoryStack.entries(steps: steps, for: b).map(\.title),
                       [HistoryStack.openedTitle, "Contrast", "Texture"],
                       "photo B's history is showing another photograph's steps")
    }

    /// A photograph nobody has touched has no rows at all — not a lone base row over an
    /// empty list, which would be a card claiming a history that does not exist.
    func testAnUntouchedPhotographHasNoRows() {
        let steps = [step(b, key: "tone.exposure")]
        XCTAssertTrue(HistoryStack.entries(steps: steps, for: a).isEmpty,
                      "a photograph with no steps in the stack must produce no rows")
    }

    /// A ROW'S POSITION IS A STACK POSITION, not an index into the photograph's own
    /// list, or clicking it would walk the cursor to the wrong place — by exactly the
    /// number of steps the OTHER photographs in the session contributed.
    func testARowRestoresTheStackPositionItsStepProduced() {
        let steps = [step(a, key: "tone.exposure"), step(b, key: "tone.contrast"),
                     step(a, key: "look.vignette")]
        XCTAssertEqual(HistoryStack.entries(steps: steps, for: a).map(\.position),
                       [0, 1, 3],
                       "a row must carry the position the cursor has to reach, which "
                       + "counts every step in the stack and not only this "
                       + "photograph's")
    }

    /// THE CURRENT MARK IS THE LATEST LISTED STEP AT OR BEFORE THE CURSOR, and the
    /// multi-photograph case is why it cannot be an equality test: edit A, then edit B,
    /// and the cursor stands at 2 while A's rows stop at 1. A is showing what its own
    /// last step produced, and a list that marked nothing would say A is nowhere.
    func testTheCurrentRowIsTheLatestListedStepAtOrBeforeTheCursor() {
        let steps = [step(a, key: "tone.exposure"), step(b, key: "tone.contrast"),
                     step(a, key: "look.vignette"), step(b, key: "detail.texture")]
        let rows = HistoryStack.entries(steps: steps, for: a)

        XCTAssertEqual(HistoryStack.currentRow(in: rows, position: 4), 2,
                       "with the cursor past every step, A is showing its own last one")
        XCTAssertEqual(HistoryStack.currentRow(in: rows, position: 2), 1,
                       "the cursor sitting on another photograph's step must still "
                       + "mark the last of THIS photograph's that has been applied")
        XCTAssertEqual(HistoryStack.currentRow(in: rows, position: 0), 0,
                       "wound all the way back, the photograph is as it was opened")
        XCTAssertNil(HistoryStack.currentRow(in: [], position: 0),
                     "no rows, nothing to mark")
    }

    /// A DRAG IS ONE ROW. The stack coalesces — that is what makes ⌘Z one step per
    /// gesture rather than one per mouse event — and the list has to inherit it, or a
    /// two-second slider drag buries the rest of the session under forty-eight rows all
    /// reading "Exposure".
    func testAFortyEightEventDragIsOneRow() {
        let history = HistoryStack()
        for event in 0..<48 {
            var before = Recipe()
            var after = Recipe()
            before.develop.tone.exposure = Double(event) / 48
            after.develop.tone.exposure = Double(event + 1) / 48
            history.record(before: [a: HistoryStack.PhotoEdit(recipe: before)],
                           after: [a: HistoryStack.PhotoEdit(recipe: after)],
                           coalescingKey: "tone.exposure")
        }

        let rows = HistoryStack.entries(steps: history.steps, for: a)
        XCTAssertEqual(rows.map(\.title), [HistoryStack.openedTitle, "Exposure"],
                       "forty-eight events of one gesture must be one step and "
                       + "therefore one row, over the base row")
        XCTAssertEqual(HistoryStack.currentRow(in: rows, position: history.position), 1,
                       "and the list must be standing on it")
    }

    // MARK: - What a step is called

    /// The six steps that carry a label keep it — those strings are already prose and
    /// the Edit menu prints them.
    func testANamedStepKeepsItsName() {
        XCTAssertEqual(HistoryStack.title(label: "Auto Tone",
                                          coalescingKey: "tone.exposure"),
                       "Auto Tone",
                       "a step whose caller named it must not be renamed from its "
                       + "coalescing key")
        XCTAssertEqual(HistoryStack.title(label: HistoryStack.unnamedLabel,
                                          coalescingKey: nil),
                       HistoryStack.unnamedLabel,
                       "an unnamed step with no key has nothing to be named from")
    }

    /// EVERY OTHER STEP IN THE APPLICATION, named from the merge identity it coalesces
    /// under. The keys are the ones the panels actually write.
    func testAnUnnamedStepIsNamedForTheControlItTouched() {
        let expected: [String: String] = [
            "tone.exposure": "Exposure",
            "look.vignetteFeather": "Vignette Feather",
            "wb.temp": "Temperature",
            // A generic leaf borrows the component before it: "Amount" alone names four
            // different sliders in this app.
            "detail.sharpen.amount": "Sharpen Amount",
            "denoise.amount": "Denoise Amount",
            // The identity components go — a mask's id is not vocabulary.
            "mask.c.amount.9F3B-11": "Mask Amount",
            "point.2.hue": "Point Colour Hue",
            // And the qualifier never doubles the word it qualifies.
            "histogram.zone.5": "Zone",
        ]
        for (key, name) in expected.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(
                HistoryStack.title(label: HistoryStack.unnamedLabel,
                                   coalescingKey: key),
                name,
                "the history row for \(key) is not being named in the photographer's "
                + "language. Every step that is not one of the six labelled ones "
                + "arrives with a coalescing key and no label, so a list that fell "
                + "back to the label would read \"Edit\" the whole way down")
        }
    }

    /// A SECTION'S RESET IS NAMED BY THE SECTION, not by a second copy of its name.
    /// `WorkspaceSection.title` spells `.color` "Colour"; a hand-written table here
    /// would have put "Reset Color" one row under a header that says otherwise.
    func testASectionResetIsNamedForTheSectionsOwnTitle() {
        XCTAssertEqual(
            HistoryStack.title(label: HistoryStack.unnamedLabel,
                               coalescingKey: "workspace.color.reset"),
            "Reset " + WorkspaceSection.color.title,
            "the accordion header's Reset must be named by the section it reset, or "
            + "the row and the header spell the same section two different ways")
        XCTAssertEqual(HistoryStack.title(label: HistoryStack.unnamedLabel,
                                          coalescingKey: "tone.reset"),
                       "Reset Tone",
                       "a panel's own reset key is named the same way")
    }

    // MARK: - What a step was worth

    /// A CULLING STEP CARRIES ITS VALUE, and it is the one kind of step that can: the
    /// value is `PhotoEdit.culling`, in the step, with no recipe diff to perform.
    func testACullingStepShowsTheValueItSet() {
        let was = HistoryStack.Culling(flag: .none, rating: 0, label: .none)
        var now = was
        now.rating = 3
        let rated = HistoryStack.Step(before: [a: HistoryStack.PhotoEdit(culling: was)],
                                      after: [a: HistoryStack.PhotoEdit(culling: now)],
                                      coalescingKey: nil, label: "Rating",
                                      gestureEpoch: nil)

        let rows = HistoryStack.entries(steps: [rated], for: a)
        XCTAssertEqual(rows.last?.title, "Rating")
        XCTAssertEqual(rows.last?.detail, "★★★",
                       "a culling row must say what it set — \"Rating\" alone leaves a "
                       + "photographer with three identical rows and no way to tell "
                       + "which star they are going back to")
    }

    /// And a step that moved a whole selection says how many frames it moved, because
    /// undoing it will move all of them back.
    func testAStepOverASelectionSaysHowManyPhotographsItMoved() {
        var after = Recipe()
        after.develop.tone.exposure = 0.4
        let both = HistoryStack.Step(
            before: [a: HistoryStack.PhotoEdit(recipe: Recipe()),
                     b: HistoryStack.PhotoEdit(recipe: Recipe())],
            after: [a: HistoryStack.PhotoEdit(recipe: after),
                    b: HistoryStack.PhotoEdit(recipe: after)],
            coalescingKey: "tone.exposure", label: HistoryStack.unnamedLabel,
            gestureEpoch: nil)

        XCTAssertEqual(HistoryStack.entries(steps: [both], for: a).last?.detail,
                       "2 photos",
                       "a row for a step that moved a selection must say so, or "
                       + "clicking it silently moves photographs that are not on screen")
    }

    // MARK: - What the panel is not allowed to do

    /// CLICKING A ROW IS A PLAIN POSITION MOVE — the menu's own undo and redo, repeated
    /// until the cursor arrives, recording nothing.
    ///
    /// The other reading is not merely a different taste: `record` truncates the redo
    /// tail, so a jump that recorded a step would destroy the steps it jumped over at
    /// the moment the photographer looked at them.
    func testClickingAStepIsAPlainPositionMoveAndRecordsNothing() throws {
        let panel = try Self.strippingComments(Self.appSource("HistoryPanel.swift"))

        XCTAssertTrue(panel.contains("state.undo()") && panel.contains("state.redo()"),
                      "the history panel no longer walks the cursor with AppState.undo "
                      + "and AppState.redo. Those are the only paths that put a step "
                      + "back completely — they persist, re-bin the scopes, refresh the "
                      + "mask overlay and its thumbnails and re-ask for a Vision matte "
                      + "— and a jump written straight into HistoryStack.position has "
                      + "to remember all five")
        XCTAssertFalse(panel.contains(".record("),
                       "the history panel is recording a step. A jump must not be an "
                       + "edit: record() truncates the redo tail, so recording one "
                       + "would delete the steps the photographer just jumped over")
        XCTAssertFalse(panel.contains("updateRecipe("),
                       "the history panel is writing a recipe. Moving the cursor is not "
                       + "an edit, and an edit made here would record a step and "
                       + "truncate the tail behind it")
    }

    /// THE PANEL RETAINS NOTHING — the first trap, and the one that would not show up
    /// until a long session on a heavy frame.
    ///
    /// A row is an Int and two Strings. The moment the panel holds a `Recipe` — a hover
    /// preview cache, a per-photograph dictionary, a snapshot of the step under the
    /// pointer — it is holding a copy of the stack's 400-step ring, which is the one
    /// bound this application has on how much editing history costs.
    func testTheHistoryPanelRetainsNoRecipes() throws {
        let panel = try Self.strippingComments(Self.appSource("HistoryPanel.swift"))

        for held in ["Recipe", "PhotoEdit"] {
            XCTAssertFalse(
                panel.contains(held),
                "HistoryPanel.swift names \(held) in code, which means it is holding "
                + "one. The rows are derived from history.steps and thrown away; the "
                + "stack's own ring is the only place a recipe lives, and a panel that "
                + "keeps a second copy doubles what a thousand-frame session costs")
        }
        XCTAssertFalse(
            panel.contains("[URL:"),
            "HistoryPanel.swift is keeping something keyed by URL. That is the shape "
            + "that shows the previous photograph's history after an arrow-key press: "
            + "the list must be a pure function of the stack and the current "
            + "selection, with nothing cached to go stale")
    }

    /// THE COLUMN IS ONE SCROLL SURFACE. Four panels used to own their own
    /// `ScrollView`, which inside the accordion is a scroll trap — the column stops
    /// scrolling wherever the pointer happens to be — and a list nested in a fixed-height
    /// scroller would rebuild it in the card most likely to be under the pointer.
    func testTheHistoryListDoesNotNestAScrollView() throws {
        let panel = try Self.strippingComments(Self.appSource("HistoryPanel.swift"))
        XCTAssertFalse(panel.contains("ScrollView"),
                       "the history list has its own ScrollView again. The develop "
                       + "column scrolls as one surface (DevelopPanel.scrollColumn); a "
                       + "scroller inside it eats the column's own scrolling wherever "
                       + "the pointer is over this card")
    }

    /// AND THE COLUMN ACTUALLY DRAWS IT. Every assertion above is about a list nobody
    /// can see unless the card is in the accordion, wearing the accordion's card.
    func testTheDevelopColumnDrawsTheHistoryCard() throws {
        let column = try Self.strippingComments(Self.appSource("DevelopColumn.swift"))

        XCTAssertTrue(column.contains("HistoryPanel(history:"),
                      "the develop column no longer draws the history panel, so the "
                      + "stack is back to having two menu items and no surface")
        XCTAssertTrue(column.contains("LumenSectionHeader(title: \"History\""),
                      "the history card is not wearing the column's section header, so "
                      + "it has no chevron, no glyph and none of the accordion's click "
                      + "behaviour")
        XCTAssertTrue(column.contains("@AppStorage(\"develop.history\")"),
                      "the history card's disclosure is not persisted in the column's "
                      + "own defaults namespace, so it forgets whether it was open — "
                      + "the sidebar's four sections settled this shape")
    }

    // MARK: - helpers

    private static func appSource(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // LumenAppTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // <package>
            .appendingPathComponent("Sources/LumenApp")
        return try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    /// Line and block comments out, so no assertion here can be satisfied by prose
    /// about the thing it is looking for. `SurroundPaintTests.strippingComments`,
    /// copied, and see this file's header for why it is not optional here.
    private static func strippingComments(_ source: String) -> String {
        var out = ""
        var index = source.startIndex
        var inBlock = false
        while index < source.endIndex {
            let rest = source[index...]
            if inBlock {
                if rest.hasPrefix("*/") { inBlock = false; index = source.index(index, offsetBy: 2) }
                else { index = source.index(after: index) }
                continue
            }
            if rest.hasPrefix("/*") { inBlock = true; index = source.index(index, offsetBy: 2); continue }
            if rest.hasPrefix("//") {
                while index < source.endIndex, source[index] != "\n" { index = source.index(after: index) }
                continue
            }
            out.append(source[index])
            index = source.index(after: index)
        }
        return out
    }
}
#endif
