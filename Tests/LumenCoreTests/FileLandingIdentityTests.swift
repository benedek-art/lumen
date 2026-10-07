import Foundation
import XCTest
@testable import LumenCore

final class FileLandingIdentityTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("lumen-landing-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try fm.removeItem(at: root) } }
    private func file(_ name: String) -> URL { root.appendingPathComponent(name) }
    private func write(_ name: String) throws -> URL {
        let url = file(name)
        try Data([1, 3, 7, 11]).write(to: url)
        return url
    }

    func testHardLinksAndSymlinksNameOneExistingFile() throws {
        let original = try write("A.RAF")
        let hard = file("linked.RAF"), symbolic = file("symbolic.RAF")
        try fm.linkItem(at: original, to: hard)
        try fm.createSymbolicLink(at: symbolic, withDestinationURL: original)
        XCTAssertEqual(IngestLocation.fileIdentity(of: original), IngestLocation.fileIdentity(of: hard))
        XCTAssertEqual(IngestLocation.fileIdentity(of: original), IngestLocation.fileIdentity(of: symbolic))
        XCTAssertNotEqual(IngestLocation.fileIdentity(of: original), IngestLocation.fileIdentity(of: try write("distinct.RAF")),
                          "identical bytes are not identical independent files")
    }

    func testCaseAliasUsesTheFilesystemActualIdentity() throws {
        let original = try write("A.RAF"), other = file("a.raf")
        if fm.fileExists(atPath: other.path) {
            XCTAssertEqual(IngestLocation.fileIdentity(of: original), IngestLocation.fileIdentity(of: other))
        } else {
            try Data([1, 3, 7, 11]).write(to: other)
            XCTAssertNotEqual(IngestLocation.fileIdentity(of: original), IngestLocation.fileIdentity(of: other),
                              "case-sensitive filesystems must preserve distinct files")
        }
    }

    func testTwoProvenFramesSharingAHardLinkNeverPermitEject() throws {
        let a = try write("delivered.RAF"), b = file("alias.RAF")
        try fm.linkItem(at: a, to: b)
        let digest = try IngestFileDigest.digest(of: a, chunkSize: 16)
        let results = [
            IngestFileResult(source: file("source-one.RAF"), plannedDestination: a, destination: a,
                             role: .primary, outcome: .alreadyPresent(digest)),
            IngestFileResult(source: file("source-two.RAF"), plannedDestination: b, destination: b,
                             role: .primary, outcome: .alreadyPresent(digest))
        ]
        let report = IngestReport(results: results, refusals: [], wasCancelled: false,
                                  filesAttempted: 2, filesPlanned: 2, bytesCopied: 0)
        XCTAssertTrue(report.twoFramesShareOneFile)
        XCTAssertFalse(report.allVerified)
    }

    func testIdenticalTwinFramesWithAliasedDestinationsGetIndependentLandings() throws {
        let sourceOne = try write("source-one.RAF"), sourceTwo = try write("source-two.RAF")
        let a = try write("existing.RAF"), b = file("alias.RAF")
        try fm.linkItem(at: a, to: b)
        let plan = IngestPlan(copies: [
            IngestPlannedCopy(source: sourceOne, byteCount: 4,
                             destinations: [IngestPlannedDestination(url: a, role: .primary)]),
            IngestPlannedCopy(source: sourceTwo, byteCount: 4,
                             destinations: [IngestPlannedDestination(url: b, role: .primary)])
        ])
        let report = VerifiedCopyDriver(chunkSize: 16).run(plan)
        XCTAssertTrue(report.allVerified)
        XCTAssertEqual(report.results.count, 2)
        let destinations = report.results.map(\.destination)
        XCTAssertNotEqual(IngestLocation.fileIdentity(of: destinations[0]), IngestLocation.fileIdentity(of: destinations[1]))
        for destination in destinations { XCTAssertEqual(try Data(contentsOf: destination), Data([1, 3, 7, 11])) }
        XCTAssertEqual(try Data(contentsOf: a), Data([1, 3, 7, 11]))
    }

    func testSameBatchAliasCannotOverwriteOrSkipEarlierDelivery() throws {
        let delivery = try write("delivered.jpg"), alias = file("alias.jpg")
        try fm.linkItem(at: delivery, to: alias)
        let claimed = Set([IngestLocation.fileIdentity(of: delivery)])
        for policy in ExportCollisionPolicy.allCases {
            let placement = ExportRecipe.placement(for: alias, policy: policy,
                claimedThisRun: { claimed.contains(IngestLocation.fileIdentity(of: $0)) },
                existsOnDisk: { self.fm.fileExists(atPath: $0.path) })
            XCTAssertEqual(placement, .write(file("alias-1.jpg"), replacing: false))
        }
        XCTAssertEqual(try Data(contentsOf: delivery), Data([1, 3, 7, 11]))
    }
    func testOneSourcesHardlinkedPrimaryAndBackupMustLandIndependently() throws {
        let source = try write("source.RAF")
        let primaryFolder = file("primary"), backupFolder = file("backup")
        for directory in [primaryFolder, backupFolder] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let primary = primaryFolder.appendingPathComponent("frame.RAF")
        let backup = backupFolder.appendingPathComponent("frame.RAF")
        try Data(contentsOf: source).write(to: primary)
        try fm.linkItem(at: primary, to: backup)
        let plan = IngestPlan(copies: [IngestPlannedCopy(source: source, byteCount: 4,
            destinations: [IngestPlannedDestination(url: primary, role: .primary),
                           IngestPlannedDestination(url: backup, role: .backup)])])
        let report = VerifiedCopyDriver(chunkSize: 16).run(plan)
        XCTAssertTrue(report.allVerified, report.summary)
        XCTAssertEqual(report.results.count, 2)
        XCTAssertNotEqual(IngestLocation.fileIdentity(of: report.results[0].destination),
                          IngestLocation.fileIdentity(of: report.results[1].destination))
        XCTAssertEqual(try Data(contentsOf: primary), Data([1, 3, 7, 11]))
        XCTAssertEqual(try Data(contentsOf: backup), Data([1, 3, 7, 11]))
        let rerun = VerifiedCopyDriver(chunkSize: 16).run(plan)
        XCTAssertTrue(rerun.allVerified, rerun.summary)
        XCTAssertEqual(rerun.results.map(\.destination), report.results.map(\.destination))
        XCTAssertEqual(rerun.alreadyPresent.count, 2, "The independent prior backup must be reused")
        XCTAssertEqual(rerun.bytesCopied, 0)
    }

    func testAnExistingSourceAliasIsNotCountedAsAnIndependentIngest() throws {
        let source = try write("source.RAF"), linked = file("source-alias.RAF")
        try fm.linkItem(at: source, to: linked)
        for destination in [source, linked] {
            let report = VerifiedCopyDriver(chunkSize: 16).run(IngestPlan(copies: [
                IngestPlannedCopy(source: source, byteCount: 4,
                    destinations: [IngestPlannedDestination(url: destination, role: .primary)])]))
            XCTAssertTrue(report.allVerified, report.summary)
            let landed = try XCTUnwrap(report.results.first?.destination)
            XCTAssertNotEqual(IngestLocation.fileIdentity(of: source), IngestLocation.fileIdentity(of: landed))
            XCTAssertEqual(try Data(contentsOf: source), Data([1, 3, 7, 11]))
            XCTAssertEqual(try Data(contentsOf: landed), Data([1, 3, 7, 11]))
        }
    }

    func testLegacyProvenReportsCannotPermitEjectWithAliasedCopiesOrSource() throws {
        let source = try write("source.RAF"), primary = try write("primary.RAF"), backup = file("backup.RAF")
        try fm.linkItem(at: primary, to: backup)
        let digest = try IngestFileDigest.digest(of: source, chunkSize: 16)
        func result(_ destination: URL, _ role: IngestDestinationRole) -> IngestFileResult {
            IngestFileResult(source: source, plannedDestination: destination, destination: destination,
                             role: role, outcome: .alreadyPresent(digest))
        }
        for results in [[result(primary, .primary), result(backup, .backup)], [result(source, .primary)]] {
            let report = IngestReport(results: results, refusals: [], wasCancelled: false,
                filesAttempted: 1, filesPlanned: 1, bytesCopied: 0)
            XCTAssertFalse(report.allVerified, report.summary)
        }
    }

}
