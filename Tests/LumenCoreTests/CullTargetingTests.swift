// CullTargetingTests.swift
// Which photos a cull key changes, per view, and where auto-advance goes. Pins the
// pure rule in `CullTargeting`, and (as text, since LumenApp does not build here) that
// the app's cull path actually consults it.

import XCTest
@testable import LumenCore

final class CullTargetingTests: XCTestCase {

    private static let six = ["a", "b", "c", "d", "e", "f"]

    // MARK: Targets

    func testTheGridDecidesAboutTheWholeSelection() {
        XCTAssertEqual(CullTargeting.scope(on: .grid), .selection)
        XCTAssertEqual(CullTargeting.targets(on: .grid, selection: Self.six, active: "c"), Self.six)
    }

    func testTheGridWithOnePhotoDecidesAboutTheCursor() {
        XCTAssertEqual(CullTargeting.targets(on: .grid, selection: ["c"], active: "c"), ["c"])
        XCTAssertEqual(CullTargeting.targets(on: .grid, selection: [], active: "c"), ["c"])
        XCTAssertEqual(CullTargeting.targets(on: .grid, selection: [String](), active: nil), [])
    }

    /// The defect: X in a six-frame survey rejected all six.
    func testLoupeCompareAndSurveyDecideAboutTheActiveFrameOnly() {
        for surface in [CullTargeting.Surface.loupe, .compare, .survey] {
            XCTAssertEqual(CullTargeting.scope(on: surface), .activeOnly, "\(surface)")
            XCTAssertEqual(CullTargeting.targets(on: surface, selection: Self.six, active: "d"),
                           ["d"], "\(surface)")
            XCTAssertEqual(CullTargeting.targets(on: surface, selection: ["d"], active: "d"),
                           ["d"], "\(surface)")
        }
    }

    func testNoCursorOutsideTheGridChangesNothingRatherThanBroadcasting() {
        for surface in [CullTargeting.Surface.loupe, .compare, .survey] {
            XCTAssertEqual(CullTargeting.targets(on: surface, selection: Self.six, active: nil),
                           [], "\(surface)")
        }
    }

    /// ⌘-click deselects a frame and leaves the cursor on it; × in a survey removes the
    /// highlighted frame and leaves the cursor there too. X must not reject it unseen.
    func testACursorOffTheComparisonChangesNothing() {
        let shown = ["a", "b", "c"]
        for surface in [CullTargeting.Surface.compare, .survey] {
            XCTAssertEqual(CullTargeting.targets(on: surface, selection: shown, active: "z",
                                                 shown: shown), [], "\(surface)")
            XCTAssertEqual(CullTargeting.targets(on: surface, selection: shown, active: "b",
                                                 shown: shown), ["b"], "\(surface)")
        }
        // The loupe always shows its cursor; the grid is the selection.
        XCTAssertEqual(CullTargeting.targets(on: .loupe, selection: shown, active: "z",
                                             shown: shown), ["z"])
        XCTAssertEqual(CullTargeting.targets(on: .grid, selection: shown, active: "z",
                                             shown: shown), shown)
    }

    func testTheExtensionPassesTheComparisonAsShown() throws {
        let code = try appSource("AppStateCullTargets.swift")
        XCTAssertTrue(code.contains("shown: shown"),
                      "Compare and Survey would rate a cursor that is off screen")
    }

    func testOnlyCompareAndSurveyAreComparing() {
        XCTAssertEqual(CullTargeting.Surface.allCases.filter(\.isComparing),
                       [.compare, .survey])
    }

    // MARK: Advance

    func testAutoAdvanceOffNeverMoves() {
        for surface in CullTargeting.Surface.allCases {
            XCTAssertEqual(CullTargeting.advance(on: surface, autoAdvance: false,
                                                 selectionCount: 1, comparisonCursor: 0,
                                                 comparisonCount: 2), .stay)
            XCTAssertEqual(CullTargeting.advance(on: surface, autoAdvance: false,
                                                 selectionCount: 6, comparisonCursor: 0,
                                                 comparisonCount: 6), .stay)
        }
    }

    func testOnePhotoAdvancesThroughTheRollEverywhere() {
        // Including the one-photo 2-up, where the pair is the cursor and its neighbour
        // and both should move on together.
        for surface in CullTargeting.Surface.allCases {
            XCTAssertEqual(CullTargeting.advance(on: surface, autoAdvance: true,
                                                 selectionCount: 1, comparisonCursor: 0,
                                                 comparisonCount: 2), .nextInRoll)
            XCTAssertEqual(CullTargeting.advance(on: surface, autoAdvance: true,
                                                 selectionCount: 0, comparisonCursor: nil,
                                                 comparisonCount: 0), .nextInRoll)
        }
    }

    func testAComparisonAdvancesInsideItselfAndStopsAtItsEnd() {
        for surface in [CullTargeting.Surface.compare, .survey] {
            XCTAssertEqual(CullTargeting.advance(on: surface, autoAdvance: true,
                                                 selectionCount: 6, comparisonCursor: 2,
                                                 comparisonCount: 6),
                           .withinComparison(index: 3))
            XCTAssertEqual(CullTargeting.advance(on: surface, autoAdvance: true,
                                                 selectionCount: 6, comparisonCursor: 5,
                                                 comparisonCount: 6), .stay,
                           "a held key at the last frame stops, as the arrows do")
            XCTAssertEqual(CullTargeting.advance(on: surface, autoAdvance: true,
                                                 selectionCount: 6, comparisonCursor: nil,
                                                 comparisonCount: 6), .stay)
            XCTAssertEqual(CullTargeting.advance(on: surface, autoAdvance: true,
                                                 selectionCount: 6, comparisonCursor: -1,
                                                 comparisonCount: 6), .stay)
        }
    }

    /// Stepping the roll would rebuild a multi-selection as one photo.
    func testAMultiSelectionOutsideAComparisonDoesNotAdvance() {
        for surface in [CullTargeting.Surface.grid, .loupe] {
            XCTAssertEqual(CullTargeting.advance(on: surface, autoAdvance: true,
                                                 selectionCount: 6, comparisonCursor: 2,
                                                 comparisonCount: 6), .stay)
        }
    }

    // MARK: Badge words

    func testTheSummaryNamesFlagRatingAndLabel() {
        XCTAssertEqual(CullMarks.summary(flag: .pick, rating: 3, label: .red),
                       "Picked, 3 stars, Red label")
        XCTAssertEqual(CullMarks.summary(flag: .unflagged, rating: 0, label: nil),
                       "Unflagged, no rating")
        XCTAssertEqual(CullMarks.summary(flag: .reject, rating: 1, label: nil),
                       "Rejected, 1 star")
        XCTAssertEqual(CullMarks.summary(flag: .pick, rating: 9, label: .blue,
                                         labelName: "Keeper"),
                       "Picked, 5 stars, Keeper label")
        XCTAssertEqual(CullMarks.summary(flag: .pick, rating: -2, label: nil),
                       "Picked, no rating")
    }

    func testClickingTheCurrentStarClearsIt() {
        XCTAssertEqual(CullMarks.starHelp(index: 3, rating: 3), "Clear the rating")
        XCTAssertEqual(CullMarks.starHelp(index: 4, rating: 3), "Rate 4")
    }

    // MARK: The app consults the rule

    private func appSource(_ file: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/LumenApp/\(file)"),
                              encoding: .utf8)
        // Comments blanked, so prose cannot satisfy a check after the code is reverted.
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let r = line.range(of: "//") else { return String(line) }
                return String(line[..<r.lowerBound])
            }
            .joined(separator: "\n")
    }

    private func body(of signature: String, in code: String) -> String? {
        guard let start = code.range(of: signature) else { return nil }
        guard let open = code[start.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < code.endIndex {
            let c = code[index]
            if c == "{" { depth += 1 }
            if c == "}" {
                depth -= 1
                if depth == 0 { return String(code[open...index]) }
            }
            index = code.index(after: index)
        }
        return nil
    }

    func testTheCullPathTargetsThroughTheRuleNotEditTargets() throws {
        let code = try appSource("AppState.swift")
        guard let mutate = body(of: "private func mutateTargets(", in: code),
              let advance = body(of: "private func advanceIfNeeded(", in: code) else {
            return XCTFail("mutateTargets or advanceIfNeeded moved")
        }
        XCTAssertTrue(mutate.contains("cullTargetIDs"),
                      "the cull keys no longer ask CullTargeting what to change")
        XCTAssertFalse(mutate.contains("editTargets"),
                       "the cull keys write to editTargets again — X in a survey rejects "
                           + "every frame on screen")
        XCTAssertTrue(advance.contains("advanceHandledByCullRule()"),
                      "auto-advance no longer steps inside the comparison")
    }

    func testTheExtensionFeedsTheRule() throws {
        let code = try appSource("AppStateCullTargets.swift")
        XCTAssertTrue(code.contains("CullTargeting.targets("))
        XCTAssertTrue(code.contains("CullTargeting.advance("))
    }

    func testCompareAndSurveyPanesDrawTheBadgeStrip() throws {
        let code = try appSource("CompareView.swift")
        XCTAssertEqual(code.components(separatedBy: "CullBadgeStrip(photo: photo)").count - 1,
                       2, "ComparePane and SurveyCell each draw one strip")
    }
}
