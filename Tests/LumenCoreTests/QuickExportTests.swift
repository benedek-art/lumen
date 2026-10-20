// QuickExportTests.swift
// `QuickExport` decides what ⌥⇧⌘E (Export with Previous) does and what "Show Last Export
// in Finder" selects; `LastExport` is what the app remembers between them.

import XCTest
@testable import LumenCore

final class QuickExportTests: XCTestCase {

    /// The stock recipes with only the named indices checked.
    private func recipes(checked: Set<Int>) -> [ExportRecipe] {
        ExportRecipe.defaults.enumerated().map { index, recipe in
            var copy = recipe
            copy.enabled = checked.contains(index)
            return copy
        }
    }

    private func last(directory: String = "/Deliveries/Match", ids: [String]) -> LastExport {
        LastExport(directoryPath: directory, recipeIDs: ids, recipeNames: ids,
                   deliveredCount: 3, revealPaths: [directory + "/a.jpg"],
                   finishedAt: Date(timeIntervalSince1970: 1_000))
    }

    // MARK: - Plan

    func testRunsToTheRememberedFolderWithNoDialog() {
        let list = recipes(checked: [0])
        let plan = QuickExport.plan(last: last(ids: [list[0].id]), recipes: list,
                                    targetCount: 240, isExporting: false,
                                    directoryExists: { _ in true })
        guard case .run(let directory, let message) = plan else {
            return XCTFail("expected a run, got \(plan)")
        }
        XCTAssertEqual(directory, "/Deliveries/Match")
        XCTAssertTrue(message.contains("240 photos"), message)
        XCTAssertTrue(message.contains("“Match”"), message)
        XCTAssertTrue(message.contains("1 recipe"), message)
        XCTAssertFalse(message.contains("changed"), message)
    }

    func testSaysWhenTheCheckedRecipesChangedSinceLastTime() {
        let list = recipes(checked: [0, 1])
        let plan = QuickExport.plan(last: last(ids: [list[0].id]), recipes: list,
                                    targetCount: 1, isExporting: false,
                                    directoryExists: { _ in true })
        guard case .run(_, let message) = plan else { return XCTFail("\(plan)") }
        XCTAssertTrue(message.contains("1 photo "), message)
        XCTAssertTrue(message.contains("2 recipes"), message)
        XCTAssertTrue(message.contains("changed since the last export"), message)
    }

    func testRecipeOrderIsNotAChange() {
        let list = recipes(checked: [0, 1])
        let plan = QuickExport.plan(last: last(ids: [list[1].id, list[0].id]), recipes: list,
                                    targetCount: 2, isExporting: false,
                                    directoryExists: { _ in true })
        guard case .run(_, let message) = plan else { return XCTFail("\(plan)") }
        XCTAssertFalse(message.contains("changed"), message)
    }

    func testNoPreviousExportFallsBackToTheSheet() {
        let plan = QuickExport.plan(last: nil, recipes: recipes(checked: [0]),
                                    targetCount: 5, isExporting: false,
                                    directoryExists: { _ in true })
        guard case .openSheet = plan else { return XCTFail("\(plan)") }
    }

    func testAMissingFolderFallsBackToTheSheetAndNamesIt() {
        let list = recipes(checked: [0])
        let plan = QuickExport.plan(last: last(directory: "/Volumes/Card/Out", ids: [list[0].id]),
                                    recipes: list, targetCount: 5, isExporting: false,
                                    directoryExists: { _ in false })
        guard case .openSheet(let message) = plan else { return XCTFail("\(plan)") }
        XCTAssertTrue(message.contains("“Out”"), message)
    }

    func testNoCheckedRecipeFallsBackToTheSheet() {
        let plan = QuickExport.plan(last: last(ids: ["x"]), recipes: recipes(checked: []),
                                    targetCount: 5, isExporting: false,
                                    directoryExists: { _ in true })
        guard case .openSheet = plan else { return XCTFail("\(plan)") }
    }

    func testRefusesWhileExportingAndWithNothingSelected() {
        let list = recipes(checked: [0])
        let memory = last(ids: [list[0].id])
        // A running batch wins over everything: a second run would share no `claimed`
        // set with the first.
        XCTAssertEqual(
            QuickExport.plan(last: memory, recipes: list, targetCount: 5, isExporting: true,
                             directoryExists: { _ in true }),
            .refuse(message: "An export is already running — ⌘E shows its progress"))
        XCTAssertEqual(
            QuickExport.plan(last: memory, recipes: list, targetCount: 0, isExporting: false,
                             directoryExists: { _ in true }),
            .refuse(message: "Select photos to export"))
    }

    // MARK: - What a run delivered

    private func report(_ outcomes: [(OperationFileRecord.Outcome, String?)]) -> OperationReport {
        let source = URL(fileURLWithPath: "/Shoot/DSC0001.ARW")
        let records = outcomes.enumerated().map { index, entry in
            OperationFileRecord(id: index, source: source, label: "Web",
                                outcome: entry.0,
                                actualDestination: entry.1.map { URL(fileURLWithPath: $0) })
        }
        return OperationReport(kind: .export, records: records)
    }

    func testOnlyDeliveredFilesAreRemembered() {
        let run = report([(.delivered, "/Out/a.jpg"), (.skipped, nil), (.failed, nil),
                          (.delivered, "/Out/b.jpg"), (.delivered, "/Out/a.jpg")])
        XCTAssertEqual(QuickExport.deliveredPaths(in: run), ["/Out/a.jpg", "/Out/b.jpg"])

        let memory = LastExport(directory: "/Out", recipes: recipes(checked: [0]), report: run)
        XCTAssertEqual(memory.deliveredCount, 2)
        XCTAssertEqual(memory.revealPaths, ["/Out/a.jpg", "/Out/b.jpg"])
        XCTAssertEqual(memory.recipeIDs.count, ExportRecipe.defaults.count)
    }

    // MARK: - Reveal

    func testRevealSelectsFilesThenFoldersThenTheExportFolder() {
        XCTAssertEqual(QuickExport.revealTargets(deliveredPaths: ["/Out/a.jpg", "/Out/a.jpg"],
                                                 directoryPath: "/Out"), ["/Out/a.jpg"])
        let many = (0..<5).map { "/Out/Web/\($0).jpg" } + (0..<5).map { "/Out/IG/\($0).jpg" }
        XCTAssertEqual(QuickExport.revealTargets(deliveredPaths: many, directoryPath: "/Out",
                                                 limit: 4), ["/Out/Web", "/Out/IG"])
        XCTAssertEqual(QuickExport.revealTargets(deliveredPaths: [], directoryPath: "/Out"),
                       ["/Out"])
        XCTAssertEqual(QuickExport.revealTargets(deliveredPaths: [], directoryPath: nil), [])
    }

    func testRevealSkipsWhatIsGoneAndFallsBackToTheFolder() {
        let memory = LastExport(directoryPath: "/Out", recipeIDs: [], recipeNames: [],
                                deliveredCount: 2, revealPaths: ["/Out/a.jpg", "/Out/b.jpg"],
                                finishedAt: Date())
        XCTAssertEqual(QuickExport.existingRevealTargets(memory, exists: { $0 != "/Out/a.jpg" }),
                       ["/Out/b.jpg"])
        XCTAssertEqual(QuickExport.existingRevealTargets(memory, exists: { $0 == "/Out" }),
                       ["/Out"])
        XCTAssertEqual(QuickExport.existingRevealTargets(memory, exists: { _ in false }), [])
    }

    // MARK: - Storage

    func testRoundTripsAndToleratesGarbage() throws {
        let memory = last(ids: ["web", "ig"])
        let data = try XCTUnwrap(memory.encoded())
        XCTAssertEqual(LastExport.decode(data), memory)
        XCTAssertNil(LastExport.decode(nil))
        XCTAssertNil(LastExport.decode(Data("not json".utf8)))
    }
}
