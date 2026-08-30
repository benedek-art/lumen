// What the develop column's ARRANGEMENT broadcasts, as a count.
//
// docs/28 Phase 4 item 16. The sibling of `DragBroadcastTests`, and it exists for the
// same reason one level up: `activeSection` was a `@Published` on `AppState`, so a tab
// click invalidated the whole window and `LumenApp`'s `Scene` — seven menus with it.
// Four workspaces whose sections collapse individually make that click MORE frequent
// than eight tabs did, not less, so the arrangement moving to its own observable is
// what keeps the IA change from costing what it saves.
//
// Two claims, and they are different claims:
//
//   · A workspace switch costs ONE publish, on an object only the column watches.
//   · A 48-event slider drag costs `PanelLayout` ZERO. Nothing in a drag touches the
//     arrangement, so anything above zero here means something is writing the layout on
//     a path that has no business doing so — which is precisely how the previous
//     defect arrived, through a forward that seemed harmless at the time.
//
// A counting test rather than an assertion about design, because "this does not
// publish" is not a property any type can carry in its signature, and the last time it
// was believed rather than measured it was false for a year.

#if os(macOS)
import Combine
import XCTest
@testable import LumenApp
@testable import LumenCore

@MainActor
final class PanelLayoutBroadcastTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    /// Built with no `UserDefaults`, deliberately: a test must not read or write the
    /// machine's stored panel state, and passing nil is also the only way to be sure a
    /// publish counted here came from the guard rather than from a defaults round trip.
    private func layout(_ value: WorkspaceLayout = .initial) -> PanelLayout {
        PanelLayout(layout: value, defaults: nil)
    }

    func testAWorkspaceSwitchPublishesExactlyOnce() {
        let panel = layout()
        var publishes = 0
        panel.objectWillChange.sink { _ in publishes += 1 }.store(in: &cancellables)

        panel.select(.grade)

        XCTAssertEqual(publishes, 1, "one switch, one invalidation of one column")
        XCTAssertEqual(panel.layout.workspace, .grade)
    }

    /// The common case in a switcher is clicking where you already are, and it must be
    /// free. `@Published` performs no equality check of its own, so this is the guard
    /// being tested and not the language.
    func testSwitchingToTheWorkspaceAlreadyShowingPublishesNothing() {
        let panel = layout(WorkspaceLayout(workspace: .develop))
        var publishes = 0
        panel.objectWillChange.sink { _ in publishes += 1 }.store(in: &cancellables)

        panel.select(.develop)
        panel.select(.develop)
        panel.select(.develop)

        XCTAssertEqual(publishes, 0, "an equal layout is not a change")
    }

    /// A 48-EVENT DRAG COSTS THE ARRANGEMENT NOTHING.
    ///
    /// The drag is simulated the way `DragBroadcastTests` simulates one — as the recipe
    /// writes an editing gesture actually performs — and the assertion is about what
    /// `PanelLayout` heard, which must be nothing at all. If a later change gives the
    /// column a reason to write the layout per event (a scroll-into-view, a "section
    /// containing the focused slider" highlight), this is the test that refuses it.
    func testAFortyEightEventDragNeverTouchesTheArrangement() {
        let panel = layout()
        var publishes = 0
        panel.objectWillChange.sink { _ in publishes += 1 }.store(in: &cancellables)

        let history = HistoryStack()
        for event in 0..<48 {
            var before = Recipe()
            var after = Recipe()
            after.develop.tone.exposure = Double(event) / 48
            before.develop.tone.exposure = 0
            let url = URL(fileURLWithPath: "/roll/a.arw")
            history.record(before: [url: HistoryStack.PhotoEdit(recipe: before)],
                           after: [url: HistoryStack.PhotoEdit(recipe: after)],
                           coalescingKey: "tone.exposure")
        }

        XCTAssertEqual(publishes, 0,
                       "a hand on a slider must not invalidate the column it sits in")
    }

    /// Opening a section is one publish; the solo rule closing its sibling is part of
    /// the same publish rather than a second one, because the whole arrangement is one
    /// value.
    func testOpeningASectionAndSoloingItsSiblingIsOnePublish() {
        let panel = layout(WorkspaceLayout(workspace: .develop, expanded: [.tone]))
        var publishes = 0
        panel.objectWillChange.sink { _ in publishes += 1 }.store(in: &cancellables)

        panel.click(.presence, keepingOthersOpen: false)

        XCTAssertEqual(publishes, 1)
        XCTAssertTrue(panel.layout.expanded.contains(.presence))
        XCTAssertFalse(panel.layout.expanded.contains(.tone),
                       "solo by default — the rule is SectionExpansion's, not this "
                           + "object's")
    }

    /// ⌥ keeps the sibling open, and that is still one value and one publish.
    func testOptionClickKeepsTheSiblingOpenInOnePublish() {
        let panel = layout(WorkspaceLayout(workspace: .develop, expanded: [.tone]))
        var publishes = 0
        panel.objectWillChange.sink { _ in publishes += 1 }.store(in: &cancellables)

        panel.click(.presence, keepingOthersOpen: true)

        XCTAssertEqual(publishes, 1)
        XCTAssertTrue(panel.layout.expanded.isSuperset(of: [.tone, .presence]))
    }

    /// MASKING TAKES THE COLUMN OVER WITHOUT DISTURBING IT, which is what makes the way
    /// back cheap.
    ///
    /// The mask editor draws INSTEAD of the workspace's sections rather than above them,
    /// so it would have been easy to make entering masking collapse the accordion —
    /// nothing is drawing it, after all. It must not: the expanded set is the column a
    /// photographer arranged, and leaving masking has to hand it back unchanged rather
    /// than rebuild it from the opening defaults.
    func testEnteringMaskingDoesNotDisturbTheAccordion() {
        let panel = layout(WorkspaceLayout(workspace: .develop, expanded: [.tone]))
        panel.setMasking(true)
        XCTAssertTrue(panel.layout.isMasking)
        XCTAssertEqual(panel.layout.expanded, [.tone],
                       "the sections are behind the mask editor, not closed by it")
        XCTAssertEqual(panel.layout.workspace, .develop,
                       "the workspace underneath is what the way out returns to")
    }

    /// One publish each way, because entering and leaving are each one value.
    func testEnteringAndLeavingMaskingAreOnePublishEach() {
        let panel = layout(WorkspaceLayout(workspace: .develop, expanded: [.tone]))
        var publishes = 0
        panel.objectWillChange.sink { _ in publishes += 1 }.store(in: &cancellables)

        panel.setMasking(true)
        XCTAssertEqual(publishes, 1)
        panel.setMasking(false)
        XCTAssertEqual(publishes, 2)
        XCTAssertEqual(panel.layout, WorkspaceLayout(workspace: .develop,
                                                     expanded: [.tone]),
                       "the round trip must land back on the same value")
    }

    func testSettingMaskingToWhereItAlreadyIsPublishesNothing() {
        let panel = layout()
        panel.setMasking(false)
        var publishes = 0
        panel.objectWillChange.sink { _ in publishes += 1 }.store(in: &cancellables)
        panel.setMasking(false)
        XCTAssertEqual(publishes, 0)
    }

    /// NAMING A WORKSPACE WHILE MASKING IS ONE PUBLISH, INCLUDING THE ONE YOU ARE IN.
    ///
    /// Masking is on the workspace axis, so ⌘2 while masking means "show me Develop"
    /// even when Develop is already the workspace underneath — the layout really did
    /// change, and the no-op guard must not swallow it. That is the same guard asserted
    /// from the other side in `testSwitchingToTheWorkspaceAlreadyShowingPublishesNothing`.
    func testAWorkspaceKeyLeavesMaskingInOnePublish() {
        let panel = layout(WorkspaceLayout(workspace: .develop, expanded: [.tone],
                                           isMasking: true))
        var publishes = 0
        panel.objectWillChange.sink { _ in publishes += 1 }.store(in: &cancellables)

        panel.select(.develop)

        XCTAssertEqual(publishes, 1, "the workspace did not move but masking did")
        XCTAssertFalse(panel.layout.isMasking)
        XCTAssertEqual(panel.layout.expanded, [.tone])
    }

    /// THE REGISTER'S TESTS USED TO SIT HERE, and this is their replacement rather than
    /// a silent deletion. The Simple/Full register was retired in the fourth pass
    /// (docs/32, the owner's call), so `toggleRegister` no longer exists to count — the
    /// property left to pin is the guard that survives it: a click on a section of
    /// ANOTHER workspace is a caller bug, refused by the model, and a refusal must cost
    /// zero publishes or the guard itself becomes a broadcast.
    func testClickingAnotherWorkspacesSectionIsANoOp() {
        let panel = layout(WorkspaceLayout(workspace: .develop, expanded: [.tone]))
        var publishes = 0
        panel.objectWillChange.sink { _ in publishes += 1 }.store(in: &cancellables)

        panel.click(.grading, keepingOthersOpen: false)

        XCTAssertEqual(publishes, 0)
        XCTAssertFalse(panel.layout.expanded.contains(.grading))
    }

    /// A KEY IS NOT A HEADER CLICK. `D` names Detail from anywhere, so `reveal` has to
    /// change workspace on the way to the section — one value, one publish — where
    /// `click` would have refused a section that is not the current workspace's.
    func testAKeyRevealsASectionFromAnotherWorkspace() {
        let panel = layout(WorkspaceLayout(workspace: .grade))
        var publishes = 0
        panel.objectWillChange.sink { _ in publishes += 1 }.store(in: &cancellables)

        panel.reveal(.detail)

        XCTAssertEqual(publishes, 1, "still one value, still one publish")
        XCTAssertEqual(panel.layout.workspace, .develop,
                       "revealing a section must go to the workspace that owns it")
        XCTAssertTrue(panel.layout.expanded.contains(.detail))
    }

    /// And `reveal` is a jump, so it solos: "take me to Detail" means Detail, not
    /// Detail plus whatever was open.
    func testRevealSolosTheSectionItNames() {
        let panel = layout(WorkspaceLayout(workspace: .develop,
                                           expanded: [.tone, .presence]))
        panel.reveal(.detail)
        XCTAssertEqual(panel.layout.expandedSections, [.detail])
    }
}

extension PanelLayoutBroadcastTests {

    // MARK: - What a header click means

    /// THE DEFAULT THE OWNER ASKED FOR, within minutes of using the other one: "can we
    /// make it so that I can open all of the chevrons at the same time instead of having
    /// to only open one at a time."
    ///
    /// A plain click toggles only the section clicked. Lightroom agrees — its panels
    /// collapse independently and Solo Mode is an opt-in you turn on deliberately. Solo
    /// defends the scroll length of a long column, which is a cost a photographer can
    /// see and judge; paying it by default means every second click undoes the first.
    func testAPlainClickLeavesTheOtherSectionsAlone() {
        let panel = layout(WorkspaceLayout(workspace: .develop, expanded: [.tone]))

        panel.headerClicked(.presence, optionHeld: false)

        XCTAssertEqual(panel.layout.expanded, [.tone, .presence],
                       "opening one section must not close another")
    }

    /// Three in a row, because "all of the chevrons at the same time" is the ask and one
    /// extra section is not it.
    func testEverySectionInAWorkspaceCanBeOpenAtOnce() {
        let panel = layout(WorkspaceLayout(workspace: .develop))
        let sections = Workspace.develop.sections
        for section in sections {
            panel.headerClicked(section, optionHeld: false)
        }
        XCTAssertEqual(panel.layout.expanded, Set(sections),
                       "every section of a workspace must be able to be open together")
    }

    /// A plain click on an OPEN section still closes it — the toggle has to go both
    /// ways, or the accordion becomes one-way and the column only ever grows.
    func testAPlainClickOnAnOpenSectionClosesIt() {
        let panel = layout(WorkspaceLayout(workspace: .develop,
                                           expanded: [.tone, .presence]))
        panel.headerClicked(.tone, optionHeld: false)
        XCTAssertEqual(panel.layout.expanded, [.presence])
    }

    /// ⌥ still solos, because the rule was always able to express both and inverting a
    /// default should not delete a behaviour.
    func testOptionClickStillSolosTheSection() {
        let panel = layout(WorkspaceLayout(workspace: .develop,
                                           expanded: [.tone, .presence, .curve]))
        panel.headerClicked(.curve, optionHeld: true)
        XCTAssertEqual(panel.layout.expanded, [.curve],
                       "⌥ collapses the rest of that workspace's stack")
    }

    /// And soloing is still one publish — the whole arrangement is one value however
    /// many sections it closes.
    func testSoloingSeveralSectionsIsStillOnePublish() {
        let panel = layout(WorkspaceLayout(workspace: .develop,
                                           expanded: [.tone, .presence, .curve]))
        var publishes = 0
        panel.objectWillChange.sink { _ in publishes += 1 }.store(in: &cancellables)
        panel.headerClicked(.detail, optionHeld: true)
        XCTAssertEqual(publishes, 1)
    }
}
#endif
