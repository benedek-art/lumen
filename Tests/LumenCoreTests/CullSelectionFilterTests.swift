// CullSelectionFilterTests.swift
// The culling selection verbs, the filter shortcuts with ⌘L's memory, the burst pick
// and the Shift-forces-advance rule — and the source pins that the app reaches them.

import XCTest
@testable import LumenCore

private struct SelectableFrame: LibraryFilterable, Identifiable {
    let id: Int
    var flag: PhotoFlag = .unflagged
    var rating: Int = 0
    var label: ColorLabel? = nil
    var isRaw: Bool = true
    var filename: String { "DSC\(id).ARW" }
}

final class CullSelectionTests: XCTestCase {

    private let roll: [SelectableFrame] = [
        SelectableFrame(id: 1, flag: .pick, rating: 3),
        SelectableFrame(id: 2, flag: .reject),
        SelectableFrame(id: 3, flag: .unflagged, rating: 5),
        SelectableFrame(id: 4, flag: .pick, rating: 1),
        SelectableFrame(id: 5, flag: .unflagged),
    ]

    func testSelectByFlag() {
        XCTAssertEqual(CullSelection.apply(.picks, to: roll, selection: []), [1, 4])
        XCTAssertEqual(CullSelection.apply(.rejects, to: roll, selection: [1]), [2])
        XCTAssertEqual(CullSelection.apply(.unflagged, to: roll, selection: []), [3, 5])
    }

    func testSelectByRatingIsAtLeastAndClamped() {
        XCTAssertEqual(CullSelection.apply(.ratedAtLeast(3), to: roll, selection: []), [1, 3])
        XCTAssertEqual(CullSelection.apply(.ratedAtLeast(1), to: roll, selection: []), [1, 3, 4])
        // 0 would select everything, which is Select All's job; it clamps to 1.
        XCTAssertEqual(CullSelection.apply(.ratedAtLeast(0), to: roll, selection: []), [1, 3, 4])
        XCTAssertEqual(CullSelection.apply(.ratedAtLeast(9), to: roll, selection: []), [3])
    }

    func testInvertIsShownMinusSelectedAndDropsHiddenMembers() {
        // 99 is selected but not shown: the filter hides it, so it leaves the selection.
        XCTAssertEqual(CullSelection.apply(.invert, to: roll, selection: [1, 2, 99]), [3, 4, 5])
        XCTAssertEqual(CullSelection.apply(.invert, to: roll, selection: []), [1, 2, 3, 4, 5])
        XCTAssertEqual(CullSelection.apply(.invert, to: roll, selection: [1, 2, 3, 4, 5]), [])
    }

    func testDeselectUnpickedKeepsOnlySelectedPicks() {
        XCTAssertEqual(CullSelection.apply(.deselectUnpicked, to: roll,
                                           selection: [1, 2, 3]), [1])
        XCTAssertEqual(CullSelection.apply(.deselectUnpicked, to: roll, selection: []), [])
    }

    func testSummarySaysTheCountAndWhyWhenEmpty() {
        XCTAssertEqual(CullSelection.summary(.picks, selected: 2, shown: 5), "Selected 2 picks")
        XCTAssertEqual(CullSelection.summary(.picks, selected: 1, shown: 5), "Selected 1 pick")
        XCTAssertEqual(CullSelection.summary(.rejects, selected: 0, shown: 300),
                       "No rejects among the 300 shown")
        XCTAssertEqual(CullSelection.summary(.ratedAtLeast(4), selected: 3, shown: 9),
                       "Selected 3 photos rated 4★ or more")
        XCTAssertEqual(CullSelection.summary(.invert, selected: 0, shown: 9),
                       "Selection inverted — nothing left selected")
    }
}

final class FilterShortcutTests: XCTestCase {

    func testFlagShortcutsToggleOnlyTheFlagCriterion() {
        var filter = LibraryFilter()
        filter.minRating = 2
        filter.text = "goal"
        let picks = FilterShortcut.picksOnly.toggled(in: filter)
        XCTAssertEqual(picks.flags, [.pick])
        XCTAssertEqual(picks.minRating, 2)
        XCTAssertEqual(picks.text, "goal")
        XCTAssertTrue(FilterShortcut.picksOnly.isOn(in: picks))

        // The same chord again takes it off; a different flag replaces it.
        XCTAssertEqual(FilterShortcut.picksOnly.toggled(in: picks).flags, [])
        XCTAssertEqual(FilterShortcut.unflaggedOnly.toggled(in: picks).flags, [.unflagged])
        XCTAssertEqual(FilterShortcut.rejectedOnly.toggled(in: picks).flags, [.reject])
    }

    func testAMultiFlagFilterIsReplacedNotCleared() {
        var filter = LibraryFilter()
        filter.flags = [.pick, .unflagged]
        XCTAssertEqual(FilterShortcut.picksOnly.toggled(in: filter).flags, [.pick])
    }

    func testRatingShortcutsToggleMinRating() {
        let three = FilterShortcut.ratedAtLeast(3).toggled(in: LibraryFilter())
        XCTAssertEqual(three.minRating, 3)
        XCTAssertTrue(FilterShortcut.ratedAtLeast(3).isOn(in: three))
        XCTAssertEqual(FilterShortcut.ratedAtLeast(3).toggled(in: three).minRating, 0)
        XCTAssertEqual(FilterShortcut.ratedAtLeast(5).toggled(in: three).minRating, 5)
        XCTAssertEqual(FilterShortcut.ratedAtLeast(8).toggled(in: three).minRating, 5)
    }

    func testToggleMemoryTurnsOffAndRestoresTheSameFilter() {
        var memory = FilterToggleMemory()
        var filter = LibraryFilter()
        filter.flags = [.pick]
        filter.minRating = 2
        filter.matchAny = true

        let (off, first) = memory.toggle(filter)
        XCTAssertEqual(first, .turnedOff)
        XCTAssertFalse(off.isActive)
        XCTAssertTrue(off.matchAny, "the All/Any join is not a criterion and stays")

        let (on, second) = memory.toggle(off)
        XCTAssertEqual(second, .turnedOn)
        XCTAssertEqual(on, filter)
        XCTAssertNil(memory.stashed)
    }

    func testToggleMemoryNeverOverwritesAFilterSetWhileOff() {
        var memory = FilterToggleMemory()
        var filter = LibraryFilter()
        filter.flags = [.pick]
        _ = memory.toggle(filter)

        // A new criterion lit while filters were off: ⌘L turns THAT off and stashes it,
        // rather than restoring the old one over it.
        var fresh = LibraryFilter()
        fresh.minRating = 4
        let (off, outcome) = memory.toggle(fresh)
        XCTAssertEqual(outcome, .turnedOff)
        XCTAssertFalse(off.isActive)
        XCTAssertEqual(memory.stashed, fresh)
    }

    func testNothingToRestore() {
        var memory = FilterToggleMemory()
        let (same, outcome) = memory.toggle(LibraryFilter())
        XCTAssertEqual(outcome, .nothingToRestore)
        XCTAssertEqual(same, LibraryFilter())
    }
}

final class BurstPickTests: XCTestCase {

    private func frame(_ id: String, burst: Int64?, rank: Int?, sharp: Double? = nil,
                       flag: PhotoFlag = .unflagged) -> BurstPickFrame<String> {
        BurstPickFrame(id: id, burstID: burst, burstRank: rank, sharpness: sharp, flag: flag)
    }

    func testPicksTheRankOneFrameOfEachBurst() {
        let plan = BurstPick.plan([
            frame("a1", burst: 1, rank: 2), frame("a2", burst: 1, rank: 1),
            frame("a3", burst: 1, rank: 3),
            frame("solo", burst: nil, rank: nil),
            frame("b1", burst: 2, rank: 1), frame("b2", burst: 2, rank: 2),
        ])
        XCTAssertEqual(plan.picks, ["a2", "b1"])
        XCTAssertEqual(plan.rest, ["a1", "a3", "b2"])
        XCTAssertEqual(plan.bursts, 2)
        XCTAssertEqual(plan.alreadyDecided, 0)
    }

    func testRejectsOnlyWhenAsked() {
        let plan = BurstPick.plan([frame("a1", burst: 1, rank: 1), frame("a2", burst: 1, rank: 2)])
        XCTAssertEqual(plan.decisions(rejectRest: false), ["a1": .pick])
        XCTAssertEqual(plan.decisions(rejectRest: true), ["a1": .pick, "a2": .reject])
    }

    func testASingleFrameInScopeIsNotABurstDecision() {
        // One frame of a burst in the selection, or a burst of one: nothing to choose.
        let plan = BurstPick.plan([frame("a2", burst: 1, rank: 2), frame("x", burst: 7, rank: 1)])
        XCTAssertTrue(plan.picks.isEmpty)
        XCTAssertEqual(plan.bursts, 0)
    }

    func testAPartialSelectionStillHasABest() {
        // The rank-1 frame is outside the selection; the best of what is in it wins.
        let plan = BurstPick.plan([frame("a2", burst: 1, rank: 2), frame("a3", burst: 1, rank: 3)])
        XCTAssertEqual(plan.picks, ["a2"])
    }

    func testTiesFallToSharpnessThenOrder() {
        let bySharpness = BurstPick.plan([
            frame("a", burst: 1, rank: 1, sharp: 0.4), frame("b", burst: 1, rank: 1, sharp: 0.9),
        ])
        XCTAssertEqual(bySharpness.picks, ["b"])
        let byOrder = BurstPick.plan([
            frame("a", burst: 1, rank: nil, sharp: nil), frame("b", burst: 1, rank: nil, sharp: nil),
        ])
        XCTAssertEqual(byOrder.picks, ["a"])
        let rankBeatsMissing = BurstPick.plan([
            frame("a", burst: 1, rank: nil, sharp: 0.99), frame("b", burst: 1, rank: 4, sharp: 0.1),
        ])
        XCTAssertEqual(rankBeatsMissing.picks, ["b"])
    }

    func testDecidedBurstsAreLeftAlone() {
        let plan = BurstPick.plan([
            // Already has a pick (not the sharpest): the photographer chose.
            frame("a1", burst: 1, rank: 1), frame("a2", burst: 1, rank: 2, flag: .pick),
            // The sharpest was rejected by hand: no second-guessing it.
            frame("b1", burst: 2, rank: 1, flag: .reject), frame("b2", burst: 2, rank: 2),
            // Undecided, with one frame already rejected: it is not rejected again.
            frame("c1", burst: 3, rank: 1), frame("c2", burst: 3, rank: 2, flag: .reject),
            frame("c3", burst: 3, rank: 3),
        ])
        XCTAssertEqual(plan.picks, ["c1"])
        XCTAssertEqual(plan.rest, ["c3"])
        XCTAssertEqual(plan.bursts, 3)
        XCTAssertEqual(plan.alreadyDecided, 2)
    }

    func testConfirmationStatesTheCount() {
        let plan = BurstPick.plan([
            frame("a1", burst: 1, rank: 1), frame("a2", burst: 1, rank: 2),
            frame("b1", burst: 2, rank: 1, flag: .reject), frame("b2", burst: 2, rank: 2),
        ])
        let text = BurstPick.confirmation(plan)
        XCTAssertTrue(text.hasPrefix("Flags the sharpest frame Pick in 1 burst."), text)
        XCTAssertTrue(text.contains("1 burst already has a decision"), text)
    }

    func testEvidenceCarriesTheBurstSoRanksCanBeGrouped() {
        let rows = [
            FrameScoreRow(photoID: 10, sharpness: 0.8, noise: nil, perceptualHash: nil,
                          analysedLongEdge: nil, burstID: 5, burstRank: 1),
            FrameScoreRow(photoID: 11, sharpness: 0.3, noise: nil, perceptualHash: nil,
                          analysedLongEdge: nil, burstID: 5, burstRank: 2),
            FrameScoreRow(photoID: 12, sharpness: 0.9, noise: nil, perceptualHash: nil,
                          analysedLongEdge: nil),
        ]
        let attention = CullingAttention.evidence(scores: rows, closedEyes: [])
        XCTAssertEqual(attention[10]?.burstID, 5)
        XCTAssertEqual(attention[11]?.burstID, 5)
        XCTAssertEqual(attention[11]?.burstRank, 2)
        XCTAssertNotNil(attention[12])
        XCTAssertNil(attention[12]?.burstID)
    }
}

final class CullAdvanceTests: XCTestCase {

    func testShiftForcesAnAdvanceOnlyOnASingleCursor() {
        XCTAssertFalse(CullAdvance.shouldAdvance(autoAdvance: false, forced: false, selectionCount: 1))
        XCTAssertTrue(CullAdvance.shouldAdvance(autoAdvance: false, forced: true, selectionCount: 1))
        XCTAssertTrue(CullAdvance.shouldAdvance(autoAdvance: true, forced: false, selectionCount: 0))
        XCTAssertFalse(CullAdvance.shouldAdvance(autoAdvance: true, forced: true, selectionCount: 12),
                       "a multi-selection never advances: it would drop the selection")
    }

    func testForcedIsShiftOrCapsLockOnADecisionKey() {
        XCTAssertTrue(CullAdvance.isForced(key: "p", shift: true, capsLock: false))
        XCTAssertTrue(CullAdvance.isForced(key: "3", shift: false, capsLock: true))
        XCTAssertTrue(CullAdvance.isForced(key: "-", shift: true, capsLock: false))
        XCTAssertFalse(CullAdvance.isForced(key: "p", shift: false, capsLock: false))
        XCTAssertFalse(CullAdvance.isForced(key: "o", shift: true, capsLock: false),
                       "⇧O cycles the overlay colour; it is not a decision")
    }

    func testShiftedDigitsDispatchAsTheDigit() {
        XCTAssertEqual(CullAdvance.dispatchKey(typed: "!", unshifted: "1", shift: true), "1")
        XCTAssertEqual(CullAdvance.dispatchKey(typed: "_", unshifted: "-", shift: true), "-")
        XCTAssertEqual(CullAdvance.dispatchKey(typed: "p", unshifted: "p", shift: true), "p")
        // ⇧= is the zoom key "+"; "=" is not a decision key, so it is left alone.
        XCTAssertEqual(CullAdvance.dispatchKey(typed: "+", unshifted: "=", shift: true), "+")
        XCTAssertEqual(CullAdvance.dispatchKey(typed: "{", unshifted: "[", shift: true), "{")
        XCTAssertEqual(CullAdvance.dispatchKey(typed: "!", unshifted: "1", shift: false), "!")
        XCTAssertEqual(CullAdvance.dispatchKey(typed: "!", unshifted: nil, shift: true), "!")
    }

    func testRepeatIsNavigationOnlyWhenEachPressMovesOn() {
        XCTAssertTrue(CullAdvance.allowsRepeat(key: "p", autoAdvance: true, forced: false))
        XCTAssertTrue(CullAdvance.allowsRepeat(key: "4", autoAdvance: false, forced: true))
        XCTAssertFalse(CullAdvance.allowsRepeat(key: "p", autoAdvance: false, forced: false))
        XCTAssertFalse(CullAdvance.allowsRepeat(key: "g", autoAdvance: true, forced: true))
        XCTAssertFalse(CullAdvance.allowsRepeat(key: "-", autoAdvance: true, forced: true))
    }

    func testDecisionKeysAreDispatcherKeys() {
        let keys = Set(CullAdvance.decisionKeys.map { String($0) })
        XCTAssertTrue(keys.isSubset(of: KeyGrammar.dispatchedKeys))
    }
}

/// The app target does not compile here, so these read its sources as text: the verbs
/// above are only worth testing if the menu bar and the dispatcher reach them.
final class CullSelectionSourcePins: XCTestCase {

    private func appSource(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/LumenApp")
        return try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    func testTheSceneInstallsTheCullCommands() throws {
        let app = try appSource("LumenApp.swift")
        XCTAssertTrue(app.contains("CullCommands(state: state, commands: state.commands)"))
    }

    func testTheDispatcherRoutesShiftThroughTheRule() throws {
        let keymap = try appSource("Keymap.swift")
        XCTAssertTrue(keymap.contains("CullAdvance.dispatchKey("))
        XCTAssertTrue(keymap.contains("CullAdvance.allowsRepeat("))
        for call in ["setFlag(.pick, forceAdvance: forced)",
                     "setFlag(.reject, forceAdvance: forced)",
                     "setFlag(.unflagged, forceAdvance: forced)",
                     "setRating(value, forceAdvance: forced)"] {
            XCTAssertTrue(keymap.contains(call), "the dispatcher no longer passes \(call)")
        }
    }

    func testTheAdvanceGuardIsTheRule() throws {
        let state = try appSource("AppState.swift")
        XCTAssertTrue(state.contains(
            "CullAdvance.shouldAdvance(autoAdvance: autoAdvance, forced: forced"))
    }

    func testTheBurstPickAsksBeforeWriting() throws {
        let verbs = try appSource("AppStateCullSelection.swift")
        guard let start = verbs.range(of: "func pickSharpestInEachBurst()"),
              let modal = verbs.range(of: "runModal()",
                                      range: start.upperBound..<verbs.endIndex),
              let write = verbs.range(of: "mutateCulling(",
                                      range: start.upperBound..<verbs.endIndex)
        else { return XCTFail("the burst pick's confirmation or its write moved") }
        XCTAssertLessThan(modal.lowerBound, write.lowerBound,
                          "the burst pick writes flags before the photographer confirms")
    }
}
