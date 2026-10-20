// RejectSweepTests.swift
// The reject sweep's planning rules: which files travel, which stay, and what they are
// called in `_Rejected`. The executor is macOS-only; these rules are not.

import XCTest
@testable import LumenCore

final class RejectSweepTests: XCTestCase {

    private let shoot = URL(fileURLWithPath: "/Volumes/Card/Soccer", isDirectory: true)

    private func photo(_ name: String, id: Int64, rejected: Bool = true,
                       in folder: URL? = nil) -> RejectSweep.Candidate {
        RejectSweep.Candidate(url: (folder ?? shoot).appendingPathComponent(name),
                              photoID: id, isRejected: rejected)
    }

    /// A listing closure over a hand-built tree: directory path -> names.
    private func listing(_ tree: [String: [String]]) -> (URL) -> [String] {
        { url in tree[url.standardizedFileURL.path] ?? [] }
    }

    private var rejected: String { shoot.appendingPathComponent("_Rejected").path }

    func testOnlyRejectsMoveAndEachTakesItsBareSidecar() {
        let plan = RejectSweep.plan(
            [photo("DSC_0001.ARW", id: 1), photo("DSC_0002.ARW", id: 2, rejected: false)],
            into: .rejectedFolder,
            listing: listing([shoot.path: ["DSC_0001.ARW", "DSC_0001.xmp",
                                           "DSC_0002.ARW", "DSC_0002.xmp"]]))
        XCTAssertEqual(plan.photoIDs, [1])
        XCTAssertEqual(plan.groups.count, 1)
        let moves = plan.groups[0].moves
        XCTAssertEqual(moves.map(\.source.lastPathComponent), ["DSC_0001.ARW", "DSC_0001.xmp"])
        XCTAssertEqual(moves.map { $0.destination?.path },
                       [rejected + "/DSC_0001.ARW", rejected + "/DSC_0001.xmp"])
        XCTAssertEqual(moves.map(\.isSidecar), [false, true])
        XCTAssertFalse(plan.groups[0].renamed)
        XCTAssertTrue(plan.skipped.isEmpty)
    }

    func testQualifiedSidecarsTravelAndABareOneSharedWithAKeeperStays() {
        // RAW+JPEG pair, only the RAW rejected: DSC_7.xmp may be the JPEG's, so it stays;
        // the RAW's own qualified darktable file and DxO file go.
        let plan = RejectSweep.plan(
            [photo("DSC_7.NEF", id: 7), photo("DSC_7.JPG", id: 8, rejected: false)],
            into: .rejectedFolder,
            listing: listing([shoot.path: ["DSC_7.NEF", "DSC_7.JPG", "DSC_7.xmp",
                                           "DSC_7.NEF.xmp", "DSC_7.NEF.dop", "DSC_7.JPG.xmp"]]))
        XCTAssertEqual(plan.groups.count, 1)
        XCTAssertEqual(plan.groups[0].moves.map(\.source.lastPathComponent),
                       ["DSC_7.NEF", "DSC_7.NEF.xmp", "DSC_7.NEF.dop"])
        XCTAssertEqual(plan.keptSidecars.map(\.lastPathComponent), ["DSC_7.xmp"])
    }

    func testAPairRejectedTogetherIsOneGroupWithEverySidecar() {
        let plan = RejectSweep.plan(
            [photo("DSC_7.NEF", id: 7), photo("DSC_7.JPG", id: 8)],
            into: .rejectedFolder,
            listing: listing([shoot.path: ["DSC_7.NEF", "DSC_7.JPG", "DSC_7.xmp", "DSC_7.JPG.xmp"]]))
        XCTAssertEqual(plan.groups.count, 1)
        XCTAssertEqual(plan.photoCount, 2)
        XCTAssertEqual(Set(plan.groups[0].moves.map(\.source.lastPathComponent)),
                       ["DSC_7.NEF", "DSC_7.JPG", "DSC_7.xmp", "DSC_7.JPG.xmp"])
        XCTAssertEqual(plan.groups[0].moves.prefix(2).map(\.isSidecar), [false, false])
        XCTAssertTrue(plan.keptSidecars.isEmpty)
    }

    func testACollisionRenamesTheWholeGroupAndKeepsThePairing() {
        // An existing _Rejected from an earlier sweep already holds a DSC_0001 and a
        // DSC_0001-1 (case differs: APFS compares case-insensitively).
        let plan = RejectSweep.plan(
            [photo("DSC_0001.ARW", id: 1)], into: .rejectedFolder,
            listing: listing([shoot.path: ["DSC_0001.ARW", "DSC_0001.xmp"],
                              rejected: ["dsc_0001.arw", "DSC_0001-1.xmp"]]))
        XCTAssertTrue(plan.groups[0].renamed)
        XCTAssertEqual(plan.groups[0].moves.map { $0.destination?.lastPathComponent },
                       ["DSC_0001-2.ARW", "DSC_0001-2.xmp"])
        XCTAssertEqual(plan.renamedCount, 1)
    }

    func testClaimsAccumulateAcrossGroupsLandingInOneFolder() {
        // X.JPG is taken, so X.JPG becomes X-1.JPG — which is the name the NEXT group
        // (X-1.JPG itself) wanted. It must not be handed out twice.
        let plan = RejectSweep.plan(
            [photo("X.JPG", id: 1), photo("X-1.JPG", id: 2)], into: .rejectedFolder,
            listing: listing([shoot.path: ["X.JPG", "X-1.JPG"], rejected: ["X.JPG"]]))
        XCTAssertEqual(plan.groups.map { $0.moves[0].destination?.lastPathComponent },
                       ["X-1.JPG", "X-1-1.JPG"])
    }

    func testSubfoldersSweepIntoTheirOwnRejectedFolder() {
        let day2 = shoot.appendingPathComponent("day2", isDirectory: true)
        let plan = RejectSweep.plan(
            [photo("DSC_1.ARW", id: 1), photo("DSC_1.ARW", id: 2, in: day2)],
            into: .rejectedFolder,
            listing: listing([shoot.path: ["DSC_1.ARW"], day2.path: ["DSC_1.ARW"]]))
        XCTAssertEqual(plan.groups.count, 2)
        XCTAssertEqual(Set(plan.groups.compactMap { $0.moves.first?.destination?.path }),
                       [rejected + "/DSC_1.ARW", day2.path + "/_Rejected/DSC_1.ARW"])
        XCTAssertFalse(plan.groups.contains { $0.renamed })
    }

    func testFramesAlreadyInRejectedAndMissingOriginalsAreSkippedNotMoved() {
        let inside = shoot.appendingPathComponent("_Rejected", isDirectory: true)
        let plan = RejectSweep.plan(
            [photo("DSC_9.ARW", id: 9, in: inside), photo("GONE.ARW", id: 3),
             photo("DSC_9.ARW", id: 9, in: inside)],
            into: .rejectedFolder,
            listing: listing([inside.path: ["DSC_9.ARW"], shoot.path: []]))
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.skipped.map(\.url.lastPathComponent).sorted(), ["DSC_9.ARW", "GONE.ARW"])
    }

    func testTheTrashPlanHasNoDestinationsAndRenamesNothing() {
        let plan = RejectSweep.plan(
            [photo("DSC_0001.ARW", id: 1)], into: .trash,
            listing: listing([shoot.path: ["DSC_0001.ARW", "DSC_0001.xmp"],
                              rejected: ["DSC_0001.ARW"]]))
        XCTAssertEqual(plan.groups[0].moves.map(\.destination), [nil, nil])
        XCTAssertFalse(plan.groups[0].renamed)
    }

    func testTheScanSkipRuleMatchesTheFolderName() {
        XCTAssertTrue(RejectSweep.isSweepFolderName("_Rejected"))
        XCTAssertTrue(RejectSweep.isSweepFolderName("_rejected"))
        XCTAssertFalse(RejectSweep.isSweepFolderName("Rejected"))
        XCTAssertTrue(RejectSweep.isInsideSweepFolder(
            URL(fileURLWithPath: "/a/_Rejected/x.ARW")))
        XCTAssertFalse(RejectSweep.isInsideSweepFolder(
            URL(fileURLWithPath: "/a/_Rejected.ARW")))
    }

    func testTheConfirmationCountsWhatThePlanMoves() {
        let plan = RejectSweep.plan(
            [photo("DSC_1.ARW", id: 1), photo("DSC_2.ARW", id: 2)], into: .rejectedFolder,
            listing: listing([shoot.path: ["DSC_1.ARW", "DSC_1.xmp", "DSC_2.ARW"],
                              rejected: ["DSC_2.ARW"]]))
        let text = RejectSweep.confirmationMessage(for: plan)
        XCTAssertTrue(text.hasPrefix("2 photos and 1 sidecar move into a _Rejected folder"))
        XCTAssertTrue(text.contains("1 name already taken there get a numbered suffix."))
        XCTAssertTrue(text.contains("Nothing is deleted."))
    }

    func testTheReportHasOneRecordPerFileAndPerSkip() {
        let plan = RejectSweep.plan(
            [photo("DSC_1.ARW", id: 1), photo("DSC_2.ARW", id: 2), photo("GONE.ARW", id: 3)],
            into: .rejectedFolder,
            listing: listing([shoot.path: ["DSC_1.ARW", "DSC_1.xmp", "DSC_2.ARW"]]))
        let landed = plan.groups[0].moves.compactMap(\.destination)
        let records = RejectSweep.records(for: plan, results: [
            RejectSweep.GroupResult(moved: true, landed: landed),
            RejectSweep.GroupResult(moved: false, failure: "Permission denied"),
        ])
        XCTAssertEqual(records.map(\.id), [0, 1, 2, 3])
        XCTAssertEqual(records.map(\.outcome), [.delivered, .delivered, .failed, .skipped])
        XCTAssertEqual(records.map(\.label), ["original", "sidecar", "original", "original"])
        XCTAssertEqual(records[1].actualDestination, rejected + "/DSC_1.xmp")
        XCTAssertNil(records[2].actualDestination)
        XCTAssertEqual(records[2].detail, "Permission denied")

        var report = OperationReport(kind: .rejects, records: records)
        report.finish(.completed)
        XCTAssertEqual(report.summary, "Rejects — Completed: 2 moved, 1 skipped, 1 failed")
    }
}
