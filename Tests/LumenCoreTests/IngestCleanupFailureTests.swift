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

/// Rewrites the landed copy in place (same inode, so the driver still owns it) so the
/// read-back cannot match; no permissions involved.
private struct ReadbackWritesUnverifiedCopy: IngestReadback {
    var unreadable: Bool
    func digest(of url: URL, chunkSize: Int) throws -> IngestDigest {
        try Data("unverified copy".utf8).write(to: url)
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

    /// End to end through POSIX permissions. Root ignores a read-only directory, so a
    /// privileged run skips here before any work; the test below covers the same outcome
    /// on every runner by injecting the removal failure.
    func testFailedReadbackCleanupReportsRetainedUnverifiedCopyAndNeverOffersEject() throws {
        let probe = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-readonly-probe-\(UUID())")
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: probe.path)
        let privileged = FileManager.default.isWritableFile(atPath: probe.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: probe.path)
        try? FileManager.default.removeItem(at: probe)
        try XCTSkipIf(privileged, "running as root: a read-only directory does not stop removal; "
                      + "testCleanupFailureIsReportedWithoutRelyingOnPermissions covers this path")
        for unreadable in [false, true] {
            try assertCleanupFailureIsReported(unreadable: unreadable, label: "readonly") { driver in
                driver.readback = ReadbackMakesDestinationReadOnly(unreadable: unreadable)
            }
        }
    }

    /// The same outcome with the removal failure injected, so it also runs as root.
    func testCleanupFailureIsReportedWithoutRelyingOnPermissions() throws {
        for unreadable in [false, true] {
            try assertCleanupFailureIsReported(unreadable: unreadable, label: "injected") { driver in
                driver.readback = ReadbackWritesUnverifiedCopy(unreadable: unreadable)
                driver.removeItem = { _ in throw CocoaError(.fileWriteNoPermission) }
            }
        }
    }

    private func assertCleanupFailureIsReported(unreadable: Bool, label: String,
                                                line: UInt = #line,
                                                configure: (inout VerifiedCopyDriver) -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-\(label)-copy-\(UUID())")
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
        var driver = VerifiedCopyDriver()
        configure(&driver)
        let result = driver.run(plan)
        let context = "\(label), unreadable: \(unreadable)"
        XCTAssertFalse(result.allVerified, context, line: line)
        XCTAssertEqual(result.framesVerified, 0, context, line: line)
        XCTAssertEqual(result.failures.count, 1, context, line: line)
        let file = try XCTUnwrap(result.failures.first, context, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.destination.path),
                      "fault must retain the failed final copy (\(context))", line: line)
        XCTAssertEqual(try Data(contentsOf: file.destination), Data("unverified copy".utf8), context, line: line)
        XCTAssertEqual(try Data(contentsOf: source), bytes, context, line: line)
        XCTAssertFalse(file.isProven, context, line: line)
        guard case .unverifiedCopyRemains(let reason, let cleanup) = file.failure else {
            return XCTFail("retained unverified file requires the cleanup-failed outcome (\(context))", line: line)
        }
        XCTAssertTrue(reason.contains(unreadable ? "Read-back failed" : "Verification mismatch"), reason, line: line)
        XCTAssertFalse(cleanup.isEmpty, context, line: line)
        let message = try XCTUnwrap(file.failure?.message, context, line: line)
        XCTAssertFalse(message.contains("was deleted"), "cleanup failure must not promise deletion", line: line)
        XCTAssertTrue(message.contains("remains"), message, line: line)
        XCTAssertTrue(message.contains("could not be removed"), message, line: line)
        var durable = OperationReport(kind: .ingest, records: [])
        durable.finishIngest(result, sources: [source])
        let record = try XCTUnwrap(durable.records.first, context, line: line)
        XCTAssertEqual(record.outcome, .failed, context, line: line)
        XCTAssertNil(record.actualDestination, context, line: line)
        XCTAssertEqual(record.attemptedDestination, landed.path, context, line: line)
        XCTAssertTrue(record.detail?.contains("remains") == true, context, line: line)
        XCTAssertFalse(record.detail?.contains("xxh64:") == true, "durable details must not retain image digests", line: line)
    }
}
