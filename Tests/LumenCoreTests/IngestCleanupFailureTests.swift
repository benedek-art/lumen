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

private struct ReadbackReplacesDestination: IngestReadback {
    var unreadable: Bool
    var matching = false
    func digest(of url: URL, chunkSize: Int) throws -> IngestDigest {
        let originalDigest = try IngestFileDigest.digest(of: url, chunkSize: chunkSize)
        try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("original"))
        try Data("unrelated replacement".utf8).write(to: url)
        if unreadable { throw CocoaError(.fileReadUnknown) }
        return matching ? originalDigest : try IngestFileDigest.digest(of: url, chunkSize: chunkSize)
    }
}

private struct MatchingReadbackMutatesDestination: IngestReadback {
    var useSymlink: Bool
    func digest(of url: URL, chunkSize: Int) throws -> IngestDigest {
        let digest = try IngestFileDigest.digest(of: url, chunkSize: chunkSize)
        if useSymlink {
            let original = url.appendingPathExtension("original")
            try FileManager.default.moveItem(at: url, to: original)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: original)
        } else {
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.write(contentsOf: Data([99]))
        }
        return digest
    }
}

final class IngestCleanupFailureTests: XCTestCase {
    func testMatchingDigestCannotCertifyInPlaceWriteOrReplacementSymlink() throws {
        for useSymlink in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-copy-generation-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("source.JPG")
            let landed = root.appendingPathComponent("copy.JPG")
            let bytes = Data(repeating: 42, count: 2048)
            try bytes.write(to: source)
            let plan = IngestPlan(copies: [IngestPlannedCopy(source: source, byteCount: Int64(bytes.count),
                destinations: [IngestPlannedDestination(url: landed, role: .primary)])])
            let result = VerifiedCopyDriver(readback: MatchingReadbackMutatesDestination(useSymlink: useSymlink)).run(plan)
            XCTAssertFalse(result.allVerified)
            XCTAssertEqual(result.framesVerified, 0)
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            let failure = try XCTUnwrap(result.failures.first?.failure)
            XCTAssertTrue(failure.message.contains("file generation could not be verified"), failure.message)
            XCTAssertTrue(FileManager.default.fileExists(atPath: landed.path))
            if useSymlink {
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: landed.path),
                               landed.appendingPathExtension("original").path)
                XCTAssertEqual(try Data(contentsOf: landed), bytes)
            } else {
                var changed = bytes
                changed[0] = 99
                XCTAssertEqual(try Data(contentsOf: landed), changed)
            }
        }
    }

    func testReadbackReplacementIsNeverRemovedOrCalledOurRetainedCopy() throws {
        for (unreadable, matching) in [(false, false), (true, false), (false, true)] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-copy-replacement-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("source.JPG")
            let landed = root.appendingPathComponent("copy.JPG")
            let bytes = Data(repeating: 42, count: 2048)
            try bytes.write(to: source)
            let plan = IngestPlan(copies: [IngestPlannedCopy(source: source, byteCount: Int64(bytes.count),
                destinations: [IngestPlannedDestination(url: landed, role: .primary)])])
            let result = VerifiedCopyDriver(readback: ReadbackReplacesDestination(unreadable: unreadable, matching: matching)).run(plan)
            XCTAssertFalse(result.allVerified)
            XCTAssertEqual(try? Data(contentsOf: landed), Data("unrelated replacement".utf8))
            XCTAssertEqual(try Data(contentsOf: landed.appendingPathExtension("original")), bytes)
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            let failure = try XCTUnwrap(result.failures.first?.failure)
            XCTAssertTrue(failure.message.contains("ownership changed"), failure.message)
            XCTAssertFalse(failure.message.contains("unverified file remains"))
            var durable = OperationReport(kind: .ingest, records: [])
            durable.finishIngest(result, sources: [source])
            XCTAssertNil(durable.records.first?.actualDestination)
            XCTAssertTrue(durable.records.first?.detail?.contains("ownership changed") == true)
        }
    }

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
