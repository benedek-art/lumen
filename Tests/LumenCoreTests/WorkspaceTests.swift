// WorkspaceTests.swift
// Whether the develop column's four workspaces can be described wrongly and still look
// right.
//
// The class of bug this file exists to prevent is silent divergence between three
// statements of one arrangement: docs/12 §12.1's canonical panel order, docs/28 §5.1's
// workspace membership, and the code that draws the column. The tab strip being replaced
// had that divergence and it was invisible — Zones was a tab and docs/12 called it a
// disclosure under Tone, Masks was a tab and docs/12 called it a dock — because nothing
// compared them. Every wrong arrangement here still renders: a rail that puts colour
// before tone is still a rail.
//
// So most of what follows is properties rather than examples — every section in exactly
// one workspace, canonical order re-derived from the ranks rather than assumed, solo
// checked over all sixty-four subsets of Develop's stack — plus one test that reads
// docs/28's own table and fails when the model and the document stop agreeing.
//
// THE SIMPLE/FULL REGISTER IS GONE, and about a third of this file went with it —
// rewritten, not silently weakened. docs/12 §12.12 specified it, it shipped, and the
// owner ruled against it in the fourth pass (docs/32): "I don't know why we have show
// fewer sections. That's kind of unnecessary, as well as the one hidden section
// active." The tests that pinned the register's filtering, its honesty badge and its
// round trip are replaced by the one property that now holds instead: every workspace
// always draws every section it holds (`testEveryWorkspaceAlwaysDrawsAllOfItsSections`).

import XCTest
@testable import LumenCore

final class WorkspaceTests: XCTestCase {

    // MARK: Membership is a partition

    func testEverySectionBelongsToExactlyOneWorkspace() {
        var seen: [WorkspaceSection: [Workspace]] = [:]
        for workspace in Workspace.allCases {
            for section in workspace.sections {
                seen[section, default: []].append(workspace)
            }
        }
        for section in WorkspaceSection.allCases {
            XCTAssertEqual(seen[section]?.count, 1,
                           "\(section.rawValue) is in \(seen[section] ?? []), and a "
                               + "section reachable from two workspaces is a section the "
                               + "user has to be told twice about")
        }
    }

    func testTheFourWorkspacesBetweenThemHoldEverySection() {
        let union = Workspace.allCases.flatMap(\.sections)
        XCTAssertEqual(Set(union), Set(WorkspaceSection.allCases),
                       "a section in no workspace is a control with no way to reach it")
        XCTAssertEqual(union.count, WorkspaceSection.allCases.count)
    }

    func testTheSectionCountsAreTheOnesDocs28Specifies() {
        XCTAssertEqual(Workspace.cull.sections.count, 0)
        XCTAssertEqual(Workspace.develop.sections.count, 5)
        // Crop holds two: the frame and the lens. They were one section until the
        // split, which was a correctness fix — a single Reset cleared both.
        XCTAssertEqual(Workspace.crop.sections.count, 2)
        XCTAssertEqual(Workspace.grade.sections.count, 5)
        XCTAssertEqual(Workspace.deliver.sections.count, 2)
    }

    func testEachWorkspaceHoldsTheSectionsDocs28Names() {
        XCTAssertEqual(Workspace.develop.sections,
                       [.whiteBalance, .tone, .curve, .presence, .detail])
        XCTAssertEqual(Workspace.crop.sections, [.frame, .optics])
        XCTAssertEqual(Workspace.grade.sections,
                       [.looks, .color, .grading, .filmLab, .effects])
        XCTAssertEqual(Workspace.deliver.sections, [.softProof, .exportRecipes])
    }

    func testContainsAgreesWithTheSectionLists() {
        for workspace in Workspace.allCases {
            for section in WorkspaceSection.allCases {
                XCTAssertEqual(workspace.contains(section),
                               workspace.sections.contains(section),
                               "\(workspace.rawValue) / \(section.rawValue)")
            }
        }
    }

    // MARK: Canonical order

    func testNoTwoSectionsClaimTheSameRankInTheCanonicalTable() {
        let ranks = WorkspaceSection.allCases.map(\.canonicalRank)
        XCTAssertEqual(Set(ranks).count, ranks.count,
                       "two sections at one rank means the order is not a total order "
                           + "and the rail's arrangement depends on the sort's stability")
    }

    func testTheDeclarationOrderIsTheCanonicalOrder() {
        // Not decoration: `allCases` is what anything iterating the sections gets, and a
        // case appended in the wrong place would order that iteration by accident.
        let ranks = WorkspaceSection.allCases.map(\.canonicalRank)
        XCTAssertEqual(ranks, ranks.sorted())
    }

    func testEveryWorkspaceListsItsSectionsInCanonicalOrder() {
        for workspace in Workspace.allCases {
            let ranks = workspace.sections.map(\.canonicalRank)
            XCTAssertEqual(ranks, ranks.sorted(),
                           "\(workspace.rawValue) presents its sections out of docs/12 "
                               + "§12.1's order")
        }
    }

    func testTheOneRemainingGapInTheRankingIsStillAGap() {
        // 3 and 12 were both left vacant — Render and B&W, folded away by docs/28 §5.1 —
        // and pinned so that closing one would be a deliberate act with a failing test
        // in front of it. **Rank 3 has now been spent**, deliberately, on Crop's own
        // Frame section: exactly the "a section that had not been designed yet" case the
        // gap was reserved for. That is the mechanism working, not being worked around.
        //
        // 12 stays vacant, and stays pinned.
        let ranks = Set(WorkspaceSection.allCases.map(\.canonicalRank))
        XCTAssertTrue(ranks.contains(3), "rank 3 is Frame, spent as the reservation intended")
        XCTAssertFalse(ranks.contains(12), "rank 12 is B&W, which folds into Colour")
        XCTAssertEqual(ranks.min(), 1)
        XCTAssertEqual(ranks.max(), 15)
    }

    // MARK: Masking takes the column over; it is not a section, and not a workspace

    /// STILL TRUE, and it is asserting something different now.
    ///
    /// It used to mean "masking is a dock, available everywhere, so it belongs to no
    /// workspace". It now means "masking REPLACES the sections rather than joining
    /// them": a `WorkspaceSection` is one accordion row of a workspace's column, and the
    /// mask editor is the whole column instead of that workspace's rows. A case here
    /// would put the mask list inside the very stack it displaces.
    ///
    /// The other half of the argument is in the model rather than in this list.
    /// `LocalAdjust` carries twenty scalars plus a local point curve and local grading
    /// wheels, so a mask's adjustments are a copy of the globals — a Masks section
    /// stacked under Tone would offer Tone twice, twenty rows apart, meaning two
    /// different things.
    func testMasksIsNotASectionOfAnyWorkspace() {
        for section in WorkspaceSection.allCases {
            XCTAssertFalse(section.rawValue.lowercased().contains("mask"))
            XCTAssertFalse(section.title.lowercased().contains("mask"),
                           "masking replaces a workspace's sections rather than joining "
                               + "them (WorkspaceLayout.isMasking); a section here would "
                               + "sit inside the stack it displaces")
        }
    }

    /// Nor is it a sixth `Workspace`, and this is the half a reader will want a reason
    /// for.
    ///
    /// Two reasons. The mechanical one: `LumenApp`'s View menu puts the workspaces in a
    /// `Group`, which is at its ten-child builder limit now that Crop is the fifth — a
    /// sixth case would not compile, and finding that out from a builder overload error
    /// is not how a design decision should be discovered. The real one: a workspace is a
    /// destination the switcher always offers and you can always be in, and masking is
    /// somewhere you go FROM one of them and come back to. `workspace` keeps holding
    /// where you were the whole time you are masking, which a sixth case could not do.
    func testMaskingIsNotAWorkspaceEither() {
        XCTAssertEqual(Workspace.allCases.count, 5)
        for workspace in Workspace.allCases {
            XCTAssertFalse(workspace.rawValue.lowercased().contains("mask"))
        }
        var layout = WorkspaceLayout(workspace: .grade, isMasking: true)
        XCTAssertEqual(layout.workspace, .grade,
                       "the workspace underneath is what the way out returns to, so "
                           + "masking must never overwrite it")
        layout.isMasking = false
        XCTAssertEqual(layout.workspace, .grade)
    }

    /// THE TRIPWIRE, REWIRED. This asserted that masking survives every workspace
    /// switch, which was right while masking was a dock beside the sections: the dock
    /// stayed out while you moved between workspaces underneath it.
    ///
    /// A takeover is on the same axis as the workspaces, so naming one is naming what
    /// the column shows — including "not the mask editor". And while masking there is no
    /// switcher on screen to name a workspace with: the only callers left are ⌘1–⌘5 and
    /// the View menu, so a switch that changed a workspace nobody could see and left the
    /// mask editor in place would be a key that appears dead — the failure
    /// `PanelLayout.reveal` exists to avoid.
    func testNamingAWorkspaceIsHowYouLeaveMasking() {
        for from in Workspace.allCases {
            for to in Workspace.allCases {
                var layout = WorkspaceLayout(workspace: from, isMasking: true)
                layout.select(to)
                XCTAssertFalse(layout.isMasking,
                               "\(from.rawValue) → \(to.rawValue) asked for a workspace "
                                   + "and got the mask editor")
                XCTAssertEqual(layout.workspace, to)
            }
        }
    }

    /// And the return trip is exact, which is what makes masking a detour rather than a
    /// place you have to rebuild the column after visiting.
    func testLeavingMaskingRestoresTheColumnItTookOver() {
        let before = WorkspaceLayout(workspace: .grade,
                                     expanded: [.tone, .grading, .filmLab])
        var layout = before
        layout.isMasking = true
        XCTAssertEqual(layout.expanded, before.expanded,
                       "entering masking must not close anything — the sections are not "
                           + "gone, they are behind")
        XCTAssertEqual(layout.visibleSections, before.visibleSections)
        layout.isMasking = false
        XCTAssertEqual(layout, before)
    }

    // MARK: The register is gone

    /// THE TRIPWIRE, REWRITTEN. This section of the file used to pin the Simple/Full
    /// register — its default, its filtering, its honesty badge and its non-destructive
    /// round trip. The owner retired the register in the fourth pass (docs/32): "I
    /// don't know why we have show fewer sections. That's kind of unnecessary, as well
    /// as the one hidden section active." What replaces all of it is one stronger
    /// property, pinned here so the register cannot quietly grow back as a filter on
    /// `visibleSections`: a workspace ALWAYS draws every section it holds, in canonical
    /// order, with nothing counted as concealed. Depth still folds — at the section's
    /// own chevron, which is the disclosure a photographer can see.
    func testEveryWorkspaceAlwaysDrawsAllOfItsSections() {
        for workspace in Workspace.allCases {
            let layout = WorkspaceLayout(workspace: workspace)
            XCTAssertEqual(layout.visibleSections, workspace.sections,
                           "\(workspace.rawValue) filters what it draws — the register "
                               + "was deleted deliberately and must not grow back")
        }
    }

    /// docs/12 §12.12's bargain — depth is visibly reachable, the FCPX 2011 revolt is
    /// the named failure — now holds with no control at all: every section's header is
    /// always on screen in its workspace.
    func testEverySectionIsReachableWithoutAPreference() {
        for section in WorkspaceSection.allCases {
            XCTAssertTrue(
                WorkspaceLayout(workspace: section.workspace).visibleSections
                    .contains(section),
                "\(section.rawValue) is not drawn by its own workspace")
        }
    }

    func testTheAppOpensInDevelop() {
        XCTAssertEqual(Workspace.initial, .develop)
        XCTAssertEqual(WorkspaceLayout().workspace, .develop)
        XCTAssertEqual(WorkspaceLayout.initial.workspace, .develop)
    }

    // MARK: Solo

    func testAPlainClickNeverLeavesTwoSectionsOfOneStackOpen() {
        // The property solo exists for, and the one docs/28 §5.5 leans on: per-event cost
        // is proportional to the slider rows in scope, so two open sections of a
        // six-section stack is the regression the IA change would otherwise ship.
        let stack = Workspace.develop.sections
        for start in Self.subsets(of: stack) {
            for clicked in stack {
                let after = SectionExpansion.afterClick(on: clicked, expanded: start,
                                                        keepingOthersOpen: false)
                XCTAssertLessThanOrEqual(after.intersection(Set(stack)).count, 1,
                                         "clicking \(clicked.rawValue) on "
                                             + "\(start.map(\.rawValue).sorted())")
            }
        }
    }

    func testAPlainClickForgetsWhicheverOtherSectionsWereOpen() {
        // Solo as a constant function: from any arrangement that is not already this
        // section alone, one plain click gives the same answer. That is the sense in
        // which the gesture is idempotent — a second click on a *different* section
        // cannot depend on the first one's leftovers.
        let stack = Workspace.develop.sections
        for clicked in stack {
            var answers: Set<Set<WorkspaceSection>> = []
            for start in Self.subsets(of: stack) where start != [clicked] {
                answers.insert(SectionExpansion.afterClick(on: clicked, expanded: start,
                                                           keepingOthersOpen: false))
            }
            XCTAssertEqual(answers, [[clicked]],
                           "\(clicked.rawValue) does not solo from every arrangement")
        }
    }

    func testClickingTheOnlyOpenSectionClosesIt() {
        XCTAssertEqual(SectionExpansion.afterClick(on: .tone, expanded: [.tone],
                                                   keepingOthersOpen: false),
                       [])
    }

    func testClickingOneOfSeveralOpenSectionsSolosItRatherThanClosingIt() {
        // The alternative — a pure toggle — would leave Curve open, and then the plain
        // click is not the gesture that gets you back to one panel.
        XCTAssertEqual(SectionExpansion.afterClick(on: .tone, expanded: [.tone, .curve],
                                                   keepingOthersOpen: false),
                       [.tone])
    }

    func testASoloedSectionOpensAgainOnTheThirdClick() {
        var expanded: Set<WorkspaceSection> = [.curve, .detail]
        expanded = SectionExpansion.afterClick(on: .tone, expanded: expanded,
                                               keepingOthersOpen: false)
        XCTAssertEqual(expanded, [.tone])
        expanded = SectionExpansion.afterClick(on: .tone, expanded: expanded,
                                               keepingOthersOpen: false)
        XCTAssertEqual(expanded, [])
        expanded = SectionExpansion.afterClick(on: .tone, expanded: expanded,
                                               keepingOthersOpen: false)
        XCTAssertEqual(expanded, [.tone])
    }

    func testSoloClearsOnlyTheClickedSectionsOwnWorkspace() {
        // What buys per-workspace memory: leave Develop with Tone open, grade, come back
        // to Tone open. Clearing the whole set would make every workspace switch a small
        // amnesia with no gesture that restores it.
        let after = SectionExpansion.afterClick(on: .looks,
                                                expanded: [.tone, .grading, .softProof],
                                                keepingOthersOpen: false)
        XCTAssertEqual(after, [.tone, .looks, .softProof])
    }

    func testHoldingTheModifierChangesExactlyOneSectionsState() {
        let stack = Workspace.develop.sections
        for start in Self.subsets(of: stack) {
            for clicked in stack {
                let after = SectionExpansion.afterClick(on: clicked, expanded: start,
                                                        keepingOthersOpen: true)
                XCTAssertEqual(after.symmetricDifference(start), [clicked])
                XCTAssertEqual(after.contains(clicked), !start.contains(clicked))
            }
        }
    }

    func testTwoModifiedClicksOnOneSectionAreARoundTrip() {
        let stack = Workspace.develop.sections
        for start in Self.subsets(of: stack) {
            for clicked in stack {
                let once = SectionExpansion.afterClick(on: clicked, expanded: start,
                                                       keepingOthersOpen: true)
                let twice = SectionExpansion.afterClick(on: clicked, expanded: once,
                                                        keepingOthersOpen: true)
                XCTAssertEqual(twice, start)
            }
        }
    }

    func testTheModifierIsWhatKeepsSeveralSectionsOpen() {
        var expanded: Set<WorkspaceSection> = []
        for section in Workspace.develop.sections {
            expanded = SectionExpansion.afterClick(on: section, expanded: expanded,
                                                   keepingOthersOpen: true)
        }
        XCTAssertEqual(expanded, Set(Workspace.develop.sections))
    }

    // MARK: The layout as a whole

    func testALayoutDrawsOnlyTheSectionsOfItsOwnWorkspace() {
        let everything = Set(WorkspaceSection.allCases)
        for workspace in Workspace.allCases {
            let layout = WorkspaceLayout(workspace: workspace, expanded: everything)
            XCTAssertEqual(layout.expandedSections, workspace.sections,
                           workspace.rawValue)
        }
    }

    /// The arrangement is remembered even while it is not drawn: an expanded entry for
    /// another workspace survives, invisible, until its workspace is current again.
    func testAnotherWorkspacesExpandedSectionIsRememberedNotDrawn() {
        let layout = WorkspaceLayout(workspace: .develop, expanded: [.tone, .grading])
        XCTAssertEqual(layout.expandedSections, [.tone])
        XCTAssertTrue(layout.expanded.contains(.grading),
                      "the arrangement is remembered even while it is not drawn")
    }

    func testClickingASectionOfAnotherWorkspaceDoesNothing() {
        var layout = WorkspaceLayout(workspace: .develop, expanded: [.tone])
        layout.click(.grading)
        XCTAssertEqual(layout.expanded, [.tone])
    }

    /// Masking is the one exception, and it is deliberate — see
    /// `testNamingAWorkspaceIsHowYouLeaveMasking`. This layout is not masking, so the
    /// round trip here is the plain one.
    func testSwitchingWorkspaceChangesNothingButTheWorkspace() {
        var layout = WorkspaceLayout(workspace: .develop,
                                     expanded: [.tone, .grading])
        let before = layout
        layout.select(.grade)
        XCTAssertEqual(layout.expanded, before.expanded)
        XCTAssertEqual(layout.expandedSections, [.grading])
        layout.select(.develop)
        XCTAssertEqual(layout, before, "the round trip must be exact, or a workspace is "
                           + "a place you cannot return to")
    }

    /// THE OPENING STATE IS A FIRST PASS'S THREE SECTIONS — White Balance, Tone,
    /// Presence — open, with the deeper two folded at their own chevrons.
    ///
    /// The set is what the retired Simple register used to draw for Develop, kept as
    /// the opening arrangement: a column that opens with nothing unfolded reads as
    /// mostly empty, and the fix for that should not be a photographer clicking before
    /// they can start. Nothing is hidden any more — Curve's and Detail's headers are on
    /// screen — so this pins an opening arrangement, not a filter.
    func testTheLayoutStartsWithTheFirstPassSectionsOpenInDevelop() {
        let layout = WorkspaceLayout.initial
        XCTAssertEqual(layout.workspace, .develop)
        XCTAssertEqual(layout.expandedSections, [.whiteBalance, .tone, .presence])
        XCTAssertEqual(layout.visibleSections, Workspace.develop.sections,
                       "every section's header is on the opening screen, folded or not")
        XCTAssertFalse(layout.isMasking)
        XCTAssertTrue(layout.showsDevelopColumn)
    }

    // MARK: Cull, the workspace with no sections

    func testCullHasNoDevelopColumn() {
        let layout = WorkspaceLayout(workspace: .cull,
                                     expanded: Set(WorkspaceSection.allCases))
        XCTAssertFalse(layout.showsDevelopColumn)
        XCTAssertEqual(layout.visibleSections, [])
        XCTAssertEqual(layout.expandedSections, [])
    }

    func testCullCannotBeClickedIntoHavingASection() {
        var layout = WorkspaceLayout(workspace: .cull)
        for section in WorkspaceSection.allCases {
            layout.click(section)
            layout.click(section, keepingOthersOpen: true)
        }
        XCTAssertEqual(layout.expanded, [])
    }

    func testAWorkspaceWithNoSectionsStillKeepsTheOtherWorkspacesArrangement() {
        var layout = WorkspaceLayout(workspace: .develop, expanded: [.tone])
        layout.select(.cull)
        XCTAssertEqual(layout.expandedSections, [])
        layout.select(.develop)
        XCTAssertEqual(layout.expandedSections, [.tone])
    }

    // MARK: The model against the document

    func testTheWorkspaceTableInDocs28StillDescribesThisModel() {
        // The mechanism, in the sense KeyGrammar means it: docs/28 §5.1's table and this
        // file are one arrangement written twice, and a document is not a mechanism until
        // something reads it. Parses the four bolded rows and compares both the section
        // count and the section names.
        let table = try? String(contentsOf: Self.repositoryRoot
            .appendingPathComponent("docs/28-ui-refresh.md"), encoding: .utf8)
        guard let table else {
            return XCTFail("docs/28-ui-refresh.md is not where this test expects it")
        }

        var rowsRead = 0
        for line in table.split(separator: "\n") where line.hasPrefix("| **") {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count == 6 else { continue }
            let name = cells[1].replacingOccurrences(of: "*", with: "").lowercased()
            guard let workspace = Workspace(rawValue: name) else { continue }
            guard let stated = Int(cells[4]) else { continue }
            rowsRead += 1

            XCTAssertEqual(workspace.sections.count, stated,
                           "docs/28 §5.1 says \(name) holds \(stated) sections")
            guard stated > 0 else { continue }

            // "Tone (Zones inside)" → "Tone": the parentheticals name what folds INTO a
            // section, which is exactly what makes it one section rather than two.
            let named = cells[3].split(separator: "·").map {
                $0.split(separator: "(")[0].trimmingCharacters(in: .whitespaces)
                    .lowercased()
            }
            XCTAssertEqual(named, workspace.sections.map { $0.title.lowercased() },
                           "docs/28 §5.1's \(name) row and this model list different "
                               + "sections, or list them in a different order")
        }
        XCTAssertEqual(rowsRead, 5,
                       "the §5.1 table was reformatted out of this test's reach, which "
                           + "means the model is no longer checked against it")
    }

    // MARK: Support

    /// This file's package root, from its own path — `Bundle.module` carries the
    /// fixtures, and the document is not one.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // LumenCoreTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // <package>
    }

    /// Every subset, so a property is checked against every arrangement rather than the
    /// three a reader thought of. Six sections is sixty-four of them.
    private static func subsets(of sections: [WorkspaceSection]) -> [Set<WorkspaceSection>] {
        precondition(sections.count < 16)
        return (0..<(1 << sections.count)).map { mask in
            Set(sections.enumerated().compactMap { mask & (1 << $0.offset) == 0
                                                       ? nil : $0.element })
        }
    }
}

extension WorkspaceTests {

    /// Masking is reachable from Cull, which its own contract has always claimed and
    /// which was silently false.
    ///
    /// Cull has no sections, `showsDevelopColumn` was `!sections.isEmpty`, and
    /// `ContentView` gates the whole column on it — so pressing `M` in Cull set a flag
    /// that nothing could draw. A page you can enter and cannot see is worse than one
    /// that refuses, because the refusal at least tells you.
    func testMaskingGivesCullAColumnItOtherwiseHasNot() {
        var layout = WorkspaceLayout(workspace: .cull)
        XCTAssertFalse(layout.showsDevelopColumn,
                       "Cull's emptiness is the feature when nothing has taken it over")

        layout.isMasking = true
        XCTAssertTrue(layout.showsDevelopColumn,
                      "the mask editor IS the column while it is up, so a workspace "
                          + "with no sections still has one to give")

        layout.isMasking = false
        XCTAssertFalse(layout.showsDevelopColumn, "and Cull is empty again on the way out")
    }

    /// The clause must not disturb the workspaces that always had a column.
    func testMaskingDoesNotChangeWhetherTheOtherWorkspacesDrawAColumn() {
        for workspace in Workspace.allCases where workspace != .cull {
            var layout = WorkspaceLayout(workspace: workspace)
            XCTAssertTrue(layout.showsDevelopColumn, "\(workspace) draws a column")
            layout.isMasking = true
            XCTAssertTrue(layout.showsDevelopColumn, "\(workspace) still draws one")
        }
    }
}
