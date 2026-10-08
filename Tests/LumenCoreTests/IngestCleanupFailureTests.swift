import Foundation
import XCTest
@testable import LumenCore

private struct ReadbackMakesDestinationReadOnly: IngestReadback {
    var unreadable = false
    func digest(of url: URL, chunkSize: Int) throws -> IngestDigest {
        try Data("unverified copy".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.deletingLastPathComponent().path)
        if unreadable { throw CocoaError(.fileReadUnknown) }
        return try IngestFileDigest.digest(of: url, chunkSize: chunkSize)
    }
}

final class IngestCleanupFailureTests: XCTestCase {
    func testFailedReadbackCleanupReportsRetainedUnverifiedCopyAndNeverOffersEject() throws {
        for unreadable in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-readonly-copy-\(UUID())")
            let destination = root.appendingPathComponent("destination")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
                try? FileManager.default.removeItem(at: root)
            }
            let source = root.appendingPathComponent("source.JPG")
            let bytes = Data(repeating: 42, count: 2048)
            try bytes.write(to: source)
            let landed = destination.appendingPathComponent("copy.JPG")
            let plan = IngestPlan(copies: [IngestPlannedCopy(source: source, byteCount: Int64(bytes.count),
                destinations: [IngestPlannedDestination(url: landed, role: .primary)])])
            let result = VerifiedCopyDriver(readback: ReadbackMakesDestinationReadOnly(unreadable: unreadable)).run(plan)
            try XCTSkipIf(FileManager.default.isWritableFile(atPath: destination.path),
                          "privileged runner bypasses readonly directory permissions")
            XCTAssertFalse(result.allVerified)
            XCTAssertEqual(result.framesVerified, 0)
            XCTAssertEqual(result.failures.count, 1)
            let file = try XCTUnwrap(result.failures.first)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.destination.path), "fault must retain the failed final copy")
            XCTAssertEqual(try Data(contentsOf: file.destination), Data("unverified copy".utf8))
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            XCTAssertFalse(file.isProven)
            guard case .unverifiedCopyRemains(let reason, let cleanup) = file.failure else {
                return XCTFail("retained unverified file requires the cleanup-failed outcome")
            }
            XCTAssertTrue(reason.contains(unreadable ? "Read-back failed" : "Verification mismatch"))
            XCTAssertFalse(cleanup.isEmpty)
            let message = try XCTUnwrap(file.failure?.message)
            XCTAssertFalse(message.contains("was deleted"), "cleanup failure must not promise deletion")
            XCTAssertTrue(message.contains("remains"), message)
            XCTAssertTrue(message.contains("could not be removed"), message)
            var durable = OperationReport(kind: .ingest, records: [])
            durable.finishIngest(result, sources: [source])
            let record = try XCTUnwrap(durable.records.first)
            XCTAssertEqual(record.outcome, .failed)
            XCTAssertNil(record.actualDestination)
            XCTAssertEqual(record.attemptedDestination, landed.path)
            XCTAssertTrue(record.detail?.contains("remains") == true)
            XCTAssertFalse(record.detail?.contains("xxh64:") == true, "durable details must not retain image digests")
        }
    }
}
