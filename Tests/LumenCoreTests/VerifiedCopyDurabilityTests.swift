import Foundation
import XCTest
@testable import LumenCore

/// The order things happened in, shared between the driver's seams and the test.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ entry: String) {
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

private struct LoggingReadback: IngestReadback {
    let log: EventLog
    func digest(of url: URL, chunkSize: Int) throws -> IngestDigest {
        log.append("readback")
        return try IngestFileDigest.digest(of: url, chunkSize: chunkSize)
    }
}

private struct FlushFailed: Error, LocalizedError {
    var errorDescription: String? { "the drive went away mid-flush" }
}

/// A copy that only reached the page cache is not a copy a card may be formatted on.
/// A test cannot cut the power, so these observe the flush through the driver's seams.
final class VerifiedCopyDurabilityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-copy-durability-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func onePlan(destinations: Int = 1) throws -> (IngestPlan, [URL]) {
        let source = root.appendingPathComponent("A.ARW")
        let bytes = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 * 7) })
        try bytes.write(to: source)
        let roles: [IngestDestinationRole] = [.primary, .backup]
        let urls = (0..<destinations).map {
            root.appendingPathComponent("out\($0)/A.ARW")
        }
        let plan = IngestPlan(copies: [IngestPlannedCopy(
            source: source, byteCount: Int64(bytes.count),
            destinations: urls.enumerated().map {
                IngestPlannedDestination(url: $0.element, role: roles[$0.offset])
            })])
        return (plan, urls)
    }

    private func leftoverParts(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".part") }
    }

    func testEveryCopyIsFlushedBeforeItIsRenamedAndBeforeItIsVerified() throws {
        let (plan, urls) = try onePlan(destinations: 2)
        let log = EventLog()
        var driver = VerifiedCopyDriver(readback: LoggingReadback(log: log))
        driver.syncFile = { handle in
            // Still the hidden `.part`: no final name exists before its bytes are flushed.
            let landedYet = urls.contains { FileManager.default.fileExists(atPath: $0.path) }
            log.append(landedYet ? "file-after-rename" : "file")
            try IngestDurability.syncFile(handle)
        }
        driver.syncDirectory = { url in
            log.append("dir:" + url.lastPathComponent)
            try IngestDurability.syncDirectory(url)
        }

        let report = driver.run(plan)

        XCTAssertTrue(report.allVerified, report.summary)
        XCTAssertEqual(log.all, ["file", "file",
                                 "dir:out0", "readback",
                                 "dir:out1", "readback"])
    }

    func testFlushIsNotSkippedWhenVerificationIsOff() throws {
        let (plan, _) = try onePlan()
        let log = EventLog()
        var driver = VerifiedCopyDriver(verify: false)
        driver.syncFile = { _ in log.append("file") }
        driver.syncDirectory = { _ in log.append("dir") }

        let report = driver.run(plan)

        XCTAssertEqual(report.failures.count, 0, report.summary)
        XCTAssertEqual(log.all, ["file", "dir"])
    }

    func testAFailedFileFlushIsAFailureNotAVerifiedCopy() throws {
        let (plan, urls) = try onePlan()
        let log = EventLog()
        var driver = VerifiedCopyDriver(readback: LoggingReadback(log: log))
        driver.syncFile = { _ in throw FlushFailed() }

        let report = driver.run(plan)

        XCTAssertFalse(report.allVerified)
        XCTAssertEqual(report.framesVerified, 0)
        let failure = try XCTUnwrap(report.failures.first?.failure)
        XCTAssertTrue(failure.message.contains("the drive went away mid-flush"), failure.message)
        XCTAssertFalse(report.summary.contains("every copy verified"), report.summary)
        // Never renamed into place, never read back, and the `.part` is gone.
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls[0].path))
        XCTAssertEqual(leftoverParts(in: urls[0].deletingLastPathComponent()), [])
        XCTAssertEqual(log.all, [])
    }

    func testAFailedDirectoryFlushIsAFailureAndRemovesTheCopy() throws {
        let (plan, urls) = try onePlan()
        let log = EventLog()
        var driver = VerifiedCopyDriver(readback: LoggingReadback(log: log))
        driver.syncDirectory = { _ in throw FlushFailed() }

        let report = driver.run(plan)

        XCTAssertFalse(report.allVerified)
        XCTAssertEqual(report.framesVerified, 0)
        let failure = try XCTUnwrap(report.failures.first?.failure)
        XCTAssertTrue(failure.message.contains("the drive went away mid-flush"), failure.message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls[0].path))
        XCTAssertEqual(log.all, [])
    }

    func testTheRealFlushesSucceedOnAnOrdinaryVolume() throws {
        let (plan, urls) = try onePlan()
        let report = VerifiedCopyDriver().run(plan)
        XCTAssertTrue(report.allVerified, report.summary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls[0].path))
    }
}
