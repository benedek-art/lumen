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
        // `.presence`, not `.curve`: the app opens in the Simple register and Curve is
        // not in it, so clicking Curve is correctly a no-op. Using it here asserted the
        // register's guard by accident and called it a publish count.
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

    /// The mask dock is available in every workspace, so it is not a section and does
    /// not participate in the solo rule — opening it must leave the sections alone.
    func testTheMaskDockDoesNotDisturbTheAccordion() {
        let panel = layout(WorkspaceLayout(workspace: .develop, expanded: [.tone]))
        panel.setMaskDock(open: true)
        XCTAssertTrue(panel.layout.isMaskDockOpen)
        XCTAssertEqual(panel.layout.expanded, [.tone],
                       "the dock is a surface beside the column, not a section in it")
    }

    func testSettingTheMaskDockToWhereItAlreadyIsPublishesNothing() {
        let panel = layout()
        panel.setMaskDock(open: false)
        var publishes = 0
        panel.objectWillChange.sink { _ in publishes += 1 }.store(in: &cancellables)
        panel.setMaskDock(open: false)
        XCTAssertEqual(publishes, 0)
    }

    /// The register is one publish and it changes what is DRAWN, never what applies.
    /// A hidden section keeps its adjustments — that is `DisclosureRegister`'s contract
    /// and this asserts the wrapper does not quietly acquire a different one.
    func testTheRegisterTogglesInOnePublishAndHidesWithoutReverting() {
        let panel = layout(WorkspaceLayout(workspace: .develop,
                                           register: .simple,
                                           expanded: [.tone, .curve]))
        var publishes = 0
        panel.objectWillChange.sink { _ in publishes += 1 }.store(in: &cancellables)

        panel.toggleRegister()

        XCTAssertEqual(publishes, 1)
        XCTAssertEqual(panel.layout.register, .full)
        XCTAssertEqual(panel.layout.expanded, [.tone, .curve],
                       "changing the register must not silently close anything")
    }

    /// THE GUARD THAT MADE THE TWO TESTS ABOVE WRONG, asserted deliberately this time.
    ///
    /// The app opens in the Simple register, which draws six sections; Curve, Detail and
    /// Optics are not among them. `WorkspaceLayout.click` refuses a section the register
    /// is hiding, which is right for a header click — a hidden header cannot be clicked
    /// — and it silently swallowed my first two tests.
    func testClickingASectionTheRegisterHidesIsANoOp() {
        let panel = layout(WorkspaceLayout(workspace: .develop,
                                           register: .simple,
                                           expanded: [.tone]))
        var publishes = 0
        panel.objectWillChange.sink { _ in publishes += 1 }.store(in: &cancellables)

        panel.click(.curve, keepingOthersOpen: false)

        XCTAssertEqual(publishes, 0)
        XCTAssertFalse(panel.layout.expanded.contains(.curve))
    }

    /// A KEY IS NOT A HEADER CLICK, and this is the distinction that bug taught.
    ///
    /// `D` names Detail and `R` names Optics, and neither is in the Simple register the
    /// app opens in — so routed through `click` both keys did nothing at all. A key that
    /// does nothing is worse than a key that does not exist: it teaches that the app is
    /// broken rather than that the feature is missing. `reveal` promotes the register,
    /// because Simple is a default rather than a mode and the photographer has just
    /// demonstrated they want what it was hiding.
    func testAKeyRevealsASectionTheRegisterWasHiding() {
        let panel = layout(WorkspaceLayout(workspace: .grade, register: .simple))
        var publishes = 0
        panel.objectWillChange.sink { _ in publishes += 1 }.store(in: &cancellables)

        panel.reveal(.detail)

        XCTAssertEqual(publishes, 1, "still one value, still one publish")
        XCTAssertEqual(panel.layout.workspace, .develop,
                       "revealing a section must go to the workspace that owns it")
        XCTAssertEqual(panel.layout.register, .full)
        XCTAssertTrue(panel.layout.expanded.contains(.detail))
    }

    /// And it does NOT promote when the section was visible all along — a photographer
    /// who presses B should not silently lose the Simple register they chose.
    func testRevealingAVisibleSectionLeavesTheRegisterAlone() {
        let panel = layout(WorkspaceLayout(workspace: .develop, register: .simple))
        panel.reveal(.tone)
        XCTAssertEqual(panel.layout.register, .simple)
        XCTAssertTrue(panel.layout.expanded.contains(.tone))
    }
}
#endif
