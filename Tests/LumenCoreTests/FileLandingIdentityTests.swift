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
}
