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
// before tone is a rail, a Simple register missing Presence looks deliberate, and a
// section counted in the hidden-active badge that "Show all" does not reveal reads as a
// badge.
//
// So most of what follows is properties rather than examples — every section in exactly
// one workspace, canonical order re-derived from the ranks rather than assumed, solo
// checked over all sixty-four subsets of Develop's stack — plus one test that reads
// docs/28's own table and fails when the model and the document stop agreeing.

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
        // Crop holds one SECTION — Lens. The frame itself is not a section: it is drawn
        // on the photograph, and a workspace whose main tool lives on the image is
        // exactly why Crop stopped being a section of Develop.
        XCTAssertEqual(Workspace.crop.sections.count, 1)
        XCTAssertEqual(Workspace.grade.sections.count, 5)
        XCTAssertEqual(Workspace.deliver.sections.count, 2)
    }

    func testEachWorkspaceHoldsTheSectionsDocs28Names() {
        XCTAssertEqual(Workspace.develop.sections,
                       [.whiteBalance, .tone, .curve, .presence, .detail])
        XCTAssertEqual(Workspace.crop.sections, [.optics])
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

    func testTheRegisterNeverReordersWhatItShows() {
        // Hiding is a filter, so the survivors keep their relative order. A register that
        // reordered would move a section under the pointer on the way to another one.
        for workspace in Workspace.allCases {
            for register in DisclosureRegister.allCases {
                let shown = workspace.sections(in: register)
                XCTAssertEqual(shown, workspace.sections.filter(shown.contains),
                               "\(workspace.rawValue) / \(register.rawValue)")
            }
        }
    }

    func testTheGapsInTheRankingAreTheTwoDocs28FoldsAway() {
        // 3 is Render and 12 is B&W. Pinned so that closing a gap — which would look like
        // tidying — is a deliberate act with a failing test in front of it.
        let ranks = Set(WorkspaceSection.allCases.map(\.canonicalRank))
        XCTAssertFalse(ranks.contains(3), "rank 3 is Render, not a section of §5.1's IA")
        XCTAssertFalse(ranks.contains(12), "rank 12 is B&W, which folds into Colour")
        XCTAssertEqual(ranks.min(), 1)
        XCTAssertEqual(ranks.max(), 15)
    }

    // MARK: Masks is not a section

    func testMasksIsNotASectionOfAnyWorkspace() {
        for section in WorkspaceSection.allCases {
            XCTAssertFalse(section.rawValue.lowercased().contains("mask"))
            XCTAssertFalse(section.title.lowercased().contains("mask"),
                           "docs/12 §12.1 lists Masks as docked via a key, not as a panel "
                               + "in the rail; you mask while developing and while "
                               + "grading, so it cannot be a section of either")
        }
    }

    func testTheMaskDockSurvivesEveryWorkspaceSwitch() {
        for from in Workspace.allCases {
            for to in Workspace.allCases {
                var layout = WorkspaceLayout(workspace: from, isMaskDockOpen: true)
                layout.select(to)
                XCTAssertTrue(layout.isMaskDockOpen,
                              "\(from.rawValue) → \(to.rawValue) put the mask list away "
                                  + "mid-edit")
            }
        }
    }

    func testTheMaskDockIsUnaffectedByTheRegister() {
        var layout = WorkspaceLayout(workspace: .develop, isMaskDockOpen: true)
        layout.toggleRegister()
        XCTAssertTrue(layout.isMaskDockOpen)
        layout.toggleRegister()
        XCTAssertTrue(layout.isMaskDockOpen)
    }

    // MARK: The two registers

    func testTheSimpleRegisterIsTheDefault() {
        XCTAssertEqual(DisclosureRegister.initial, .simple)
        XCTAssertEqual(WorkspaceLayout().register, .simple)
        XCTAssertEqual(WorkspaceLayout.initial.register, .simple)
        XCTAssertEqual(Workspace.initial, .develop)
    }

    func testTheSimpleRegisterShowsWhatDocs28Section51Names() {
        XCTAssertEqual(Workspace.develop.sections(in: .simple),
                       [.whiteBalance, .tone, .presence])
        XCTAssertEqual(Workspace.grade.sections(in: .simple), [.looks, .color])
    }

    func testTheFullRegisterHidesNothing() {
        for workspace in Workspace.allCases {
            XCTAssertEqual(workspace.sections(in: .full), workspace.sections)
            XCTAssertEqual(workspace.hiddenSections(in: .full), [])
        }
    }

    func testShownAndHiddenPartitionTheWorkspaceInBothRegisters() {
        for workspace in Workspace.allCases {
            for register in DisclosureRegister.allCases {
                let shown = workspace.sections(in: register)
                let hidden = workspace.hiddenSections(in: register)
                XCTAssertTrue(Set(shown).isDisjoint(with: Set(hidden)),
                              "\(workspace.rawValue) / \(register.rawValue): a section "
                                  + "both drawn and counted as hidden")
                XCTAssertEqual(Set(shown).union(hidden), Set(workspace.sections))
            }
        }
    }

    func testEverySectionIsReachableWithoutAPreference() {
        // docs/12 §12.12's whole bargain is that depth is visibly reachable — the FCPX
        // 2011 revolt is the named failure. One toolbar control has to be enough to see
        // any section, so no section may be hidden in both registers.
        for section in WorkspaceSection.allCases {
            XCTAssertTrue(section.isVisible(in: .full), section.rawValue)
            XCTAssertTrue(section.workspace.sections(in: .full).contains(section))
        }
    }

    func testIsVisibleAgreesWithTheListsTheRegisterProduces() {
        for workspace in Workspace.allCases {
            for register in DisclosureRegister.allCases {
                for section in workspace.sections {
                    XCTAssertEqual(workspace.sections(in: register).contains(section),
                                   section.isVisible(in: register),
                                   "\(section.rawValue) in \(register.rawValue)")
                }
            }
        }
    }

    func testTheRegisterToggleIsItsOwnInverse() {
        for register in DisclosureRegister.allCases {
            XCTAssertEqual(register.toggled.toggled, register)
            XCTAssertNotEqual(register.toggled, register)
        }
    }

    func testShowingAllAndHidingAgainRestoresExactlyTheSameOpenSections() {
        // docs/12 §12.12: switching is "instant and non-destructive". Destructive here
        // would mean clearing the expansion of a section the Simple register hides, so
        // that a look at the full stack costs the user their arrangement.
        var layout = WorkspaceLayout(workspace: .develop, register: .simple,
                                     expanded: [.tone, .curve, .detail])
        let before = layout.expandedSections
        layout.toggleRegister()
        XCTAssertEqual(layout.expandedSections, [.tone, .curve, .detail])
        layout.toggleRegister()
        XCTAssertEqual(layout.expandedSections, before)
        XCTAssertEqual(before, [.tone])
    }

    // MARK: The hidden-active indicator

    func testAHiddenSectionCarryingAnEditIsCounted() {
        let layout = WorkspaceLayout(workspace: .develop, register: .simple)
        // Two, not three: `.optics` moved to Crop and joined the Simple register, so
        // Develop's only Simple-hidden sections are Curve and Detail. A section of
        // another workspace can never be counted here — `hiddenSections(in:)` is
        // workspace-scoped.
        XCTAssertEqual(layout.hiddenActiveCount(nonDefault: [.curve, .detail, .optics]), 2)
        XCTAssertEqual(layout.hiddenActiveIndicator(nonDefault: [.curve, .detail, .optics]),
                       "2 hidden sections active")
    }

    func testASectionOnScreenIsNeverCountedAsHidden() {
        let layout = WorkspaceLayout(workspace: .develop, register: .simple)
        XCTAssertEqual(layout.hiddenActiveCount(nonDefault: [.whiteBalance, .tone,
                                                            .presence]), 0)
        XCTAssertNil(layout.hiddenActiveIndicator(nonDefault: [.tone]))
    }

    func testTheCountIsExactlyWhatShowAllWouldReveal() {
        // The property that makes the badge honest: whatever it claims is hidden must
        // appear when the register flips. A badge reading five beside a click that
        // produces two is worse than no badge.
        let nonDefault: Set<WorkspaceSection> = [.tone, .curve, .optics, .grading]
        for workspace in Workspace.allCases {
            var layout = WorkspaceLayout(workspace: workspace, register: .simple)
            let claimed = Set(layout.hiddenActiveSections(nonDefault: nonDefault))
            let beforeShowAll = Set(layout.visibleSections)
            layout.toggleRegister()
            let revealed = Set(layout.visibleSections).subtracting(beforeShowAll)
            XCTAssertEqual(claimed, revealed.intersection(nonDefault),
                           workspace.rawValue)
        }
    }

    func testTheFullRegisterHasNothingToDisclose() {
        for workspace in Workspace.allCases {
            let layout = WorkspaceLayout(workspace: workspace, register: .full)
            XCTAssertEqual(layout.hiddenActiveCount(
                nonDefault: Set(WorkspaceSection.allCases)), 0)
            XCTAssertNil(layout.hiddenActiveIndicator(
                nonDefault: Set(WorkspaceSection.allCases)))
        }
    }

    func testTheCountCanNeverExceedTheNumberOfSectionsHoldingAnEdit() {
        // Over every subset of every workspace's sections, in both registers. The bound
        // is the one thing a reader of the badge assumes without checking.
        for workspace in Workspace.allCases {
            for register in DisclosureRegister.allCases {
                let layout = WorkspaceLayout(workspace: workspace, register: register)
                for subset in Self.subsets(of: WorkspaceSection.allCases.filter {
                    $0.workspace == workspace
                }) {
                    let count = layout.hiddenActiveCount(nonDefault: subset)
                    XCTAssertLessThanOrEqual(count, subset.count)
                    XCTAssertGreaterThanOrEqual(count, 0)
                }
            }
        }
    }

    func testASectionOfAnotherWorkspaceIsNotCountedHere() {
        // Grading is non-default and invisible from Develop, but it is hidden by a move
        // the user made rather than by a default they never chose, and "Show all" in
        // Develop will not produce it.
        let layout = WorkspaceLayout(workspace: .develop, register: .simple)
        XCTAssertEqual(layout.hiddenActiveCount(nonDefault: [.grading, .filmLab]), 0)
        XCTAssertEqual(layout.hiddenActiveCount(nonDefault: [.grading, .curve]), 1)
    }

    func testTheIndicatorSaysSectionRatherThanSectionsForOne() {
        let layout = WorkspaceLayout(workspace: .develop, register: .simple)
        XCTAssertEqual(layout.hiddenActiveIndicator(nonDefault: [.curve]),
                       "1 hidden section active")
        XCTAssertEqual(layout.hiddenActiveIndicator(nonDefault: [.curve, .detail]),
                       "2 hidden sections active")
    }

    func testTheIndicatorListsItsSectionsInCanonicalOrder() {
        let layout = WorkspaceLayout(workspace: .develop, register: .simple)
        // `.optics` is deliberately in the input and deliberately absent from the
        // output: it belongs to Crop now, and this indicator is workspace-scoped.
        XCTAssertEqual(layout.hiddenActiveSections(nonDefault: [.optics, .curve, .detail]),
                       [.curve, .detail])
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
            let layout = WorkspaceLayout(workspace: workspace, register: .full,
                                         expanded: everything)
            XCTAssertEqual(layout.expandedSections, workspace.sections,
                           workspace.rawValue)
        }
    }

    func testASectionTheRegisterHidesIsNeverDrawnOpen() {
        let layout = WorkspaceLayout(workspace: .develop, register: .simple,
                                     expanded: [.tone, .curve])
        XCTAssertEqual(layout.expandedSections, [.tone])
        XCTAssertTrue(layout.expanded.contains(.curve),
                      "the arrangement is remembered even while it is not drawn")
    }

    func testClickingASectionTheRegisterHidesDoesNothing() {
        // There is no header to click, so the call is a caller bug; honouring it would
        // leave Curve expanded and only visible after a later register toggle.
        var layout = WorkspaceLayout(workspace: .develop, register: .simple,
                                     expanded: [.tone])
        layout.click(.curve)
        XCTAssertEqual(layout.expanded, [.tone])
    }

    func testClickingASectionOfAnotherWorkspaceDoesNothing() {
        var layout = WorkspaceLayout(workspace: .develop, register: .full,
                                     expanded: [.tone])
        layout.click(.grading)
        XCTAssertEqual(layout.expanded, [.tone])
    }

    func testSwitchingWorkspaceChangesNothingButTheWorkspace() {
        var layout = WorkspaceLayout(workspace: .develop, register: .full,
                                     expanded: [.tone, .grading], isMaskDockOpen: true)
        let before = layout
        layout.select(.grade)
        XCTAssertEqual(layout.expanded, before.expanded)
        XCTAssertEqual(layout.register, before.register)
        XCTAssertEqual(layout.isMaskDockOpen, before.isMaskDockOpen)
        XCTAssertEqual(layout.expandedSections, [.grading])
        layout.select(.develop)
        XCTAssertEqual(layout, before, "the round trip must be exact, or a workspace is "
                           + "a place you cannot return to")
    }

    /// THE OPENING STATE IS EVERY SECTION THE SIMPLE REGISTER DRAWS, not one of them.
    ///
    /// It was a single section while a click SOLOED: opening more than one would have
    /// been a state the photographer could not return to, so one was the only honest
    /// answer. A plain click now toggles only what it names — the owner asked for that
    /// within minutes of using the alternative — so the opening state is free to be the
    /// useful one. A column showing one section of six reads as mostly empty, and the
    /// fix for that should not be two clicks before you can start.
    func testTheLayoutStartsWithEverySimpleSectionOpenInDevelop() {
        let layout = WorkspaceLayout.initial
        XCTAssertEqual(layout.workspace, .develop)
        XCTAssertEqual(Set(layout.expandedSections),
                       Set(Workspace.develop.sections.filter(\.isInSimpleRegister)))
        XCTAssertEqual(layout.expandedSections, layout.visibleSections,
                       "nothing the opening column draws should start closed")
        XCTAssertFalse(layout.isMaskDockOpen)
        XCTAssertTrue(layout.showsDevelopColumn)
    }

    // MARK: Cull, the workspace with no sections

    func testCullHasNoDevelopColumnInEitherRegister() {
        for register in DisclosureRegister.allCases {
            let layout = WorkspaceLayout(workspace: .cull, register: register,
                                         expanded: Set(WorkspaceSection.allCases))
            XCTAssertFalse(layout.showsDevelopColumn)
            XCTAssertEqual(layout.visibleSections, [])
            XCTAssertEqual(layout.expandedSections, [])
            XCTAssertEqual(layout.hiddenActiveCount(
                nonDefault: Set(WorkspaceSection.allCases)), 0)
            XCTAssertNil(layout.hiddenActiveIndicator(
                nonDefault: Set(WorkspaceSection.allCases)))
        }
    }

    func testCullCannotBeClickedIntoHavingASection() {
        var layout = WorkspaceLayout(workspace: .cull, register: .full)
        for section in WorkspaceSection.allCases {
            layout.click(section)
            layout.click(section, keepingOthersOpen: true)
        }
        XCTAssertEqual(layout.expanded, [])
    }

    func testAWorkspaceWithNoSectionsStillKeepsTheOtherWorkspacesArrangement() {
        var layout = WorkspaceLayout(workspace: .develop, register: .simple,
                                     expanded: [.tone])
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
