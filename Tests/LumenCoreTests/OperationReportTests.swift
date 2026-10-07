import Foundation
import XCTest
@testable import LumenCore

final class OperationReportTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-operation-reports-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func report(_ kind: OperationReport.Kind = .export, at date: Date = Date()) -> OperationReport {
        OperationReport(kind: kind, startedAt: date, records: [
            OperationFileRecord(id: 0, source: URL(fileURLWithPath: "/Photos/a.JPG"), label: "Web",
                                plannedDestination: URL(fileURLWithPath: "/Delivery/a.jpg")),
            OperationFileRecord(id: 1, source: URL(fileURLWithPath: "/Photos/b.JPG"), label: "Web")])
    }

    func testRelaunchKeepsConfirmedDestinationAndMarksUnsettledWorkUnknown() async throws {
        let root = try scratch()
        let store = OperationReportStore(directory: root)
        var run = report()
        run.settle(OperationFileRecord(id: 0, source: URL(fileURLWithPath: "/Photos/a.JPG"), label: "Web",
            outcome: .delivered, actualDestination: URL(fileURLWithPath: "/Delivery/a-1.jpg")))
        try await store.save(run)
        let reopened = OperationReportStore(directory: root)
        let archive = try await reopened.load()
        let loaded = try XCTUnwrap(archive.reports.first?.report)
        XCTAssertEqual(loaded.state, .interrupted)
        XCTAssertEqual(loaded.records[0].actualDestination, "/Delivery/a-1.jpg")
        XCTAssertEqual(loaded.records[1].outcome, .unknown)
        XCTAssertNil(loaded.records[1].actualDestination)
        XCTAssertNil(loaded.finishedAt)
    }

    func testIndependentOperationIDsAndStaleCheckpointCannotClobberFinishedEvidence() async throws {
        let root = try scratch()
        let store = OperationReportStore(directory: root)
        var first = report()
        var second = report(.ingest)
        let stale = first
        first.finish(.cancelled)
        second.finish(.completed)
        async let savedFirst = store.save(first)
        async let savedSecond = store.save(second)
        _ = try await (savedFirst, savedSecond)
        let staleSaved = try await store.save(stale)
        XCTAssertFalse(staleSaved)
        let loaded = try await store.load()
        XCTAssertEqual(Set(loaded.reports.map { $0.report.id }), [first.id, second.id])
        XCTAssertEqual(loaded.reports.first { $0.report.id == first.id }?.report.state, .cancelled)
    }

    func testMalformedAndUnknownSchemaAreWarnedAndNeverOverwrittenOrPruned() async throws {
        let root = try scratch()
        let store = OperationReportStore(directory: root, completedLimit: 1)
        var malformed = report()
        let badPath = await store.file(for: malformed.id)
        let bad = Data("not JSON".utf8)
        try bad.write(to: badPath)
        malformed.finish(.completed)
        do { try await store.save(malformed); XCTFail("must not overwrite malformed report") } catch {}
        var future = report()
        let futurePath = await store.file(for: future.id)
        let futureBytes = Data("{\"schemaVersion\":99,\"privateUnknownFields\":\"keep\"}".utf8)
        try futureBytes.write(to: futurePath)
        future.finish(.completed)
        do { try await store.save(future); XCTFail("must not overwrite newer report") } catch {}
        var ordinary = report()
        ordinary.finish(.completed)
        try await store.save(ordinary)
        let archive = try await store.load()
        XCTAssertEqual(archive.warnings.count, 2)
        XCTAssertEqual(try Data(contentsOf: badPath), bad)
        XCTAssertEqual(try Data(contentsOf: futurePath), futureBytes)
    }

    func testCompletedRetentionPreservesUnfinishedEvidence() async throws {
        let root = try scratch()
        let store = OperationReportStore(directory: root, completedLimit: 2)
        let interrupted = report(at: Date(timeIntervalSince1970: 0))
        try await store.save(interrupted)
        for time in 1...4 {
            var completed = report(at: Date(timeIntervalSince1970: Double(time)))
            completed.finish(.completed)
            try await store.save(completed)
        }
        let archive = try await store.load()
        XCTAssertEqual(archive.reports.count, 3)
        XCTAssertNotNil(archive.reports.first { $0.report.id == interrupted.id })
        XCTAssertEqual(archive.reports.filter { $0.report.state == .completed }.count, 2)
    }

    func testWriteFailureDoesNotChangeDeliveredOutcomeOrClaimPersistedFile() async throws {
        let root = try scratch()
        let blocked = root.appendingPathComponent("reports")
        try Data([1]).write(to: blocked)
        let store = OperationReportStore(directory: blocked)
        var run = report()
        run.settle(OperationFileRecord(id: 0, source: URL(fileURLWithPath: "/Photos/a.JPG"), label: "Web",
            outcome: .delivered, actualDestination: URL(fileURLWithPath: "/Delivery/a.jpg")))
        run.finish(.completed)
        do { try await store.save(run); XCTFail("directory is a file; save must fail") } catch {}
        XCTAssertEqual(run.records[0].outcome, .delivered)
        let path = await store.file(for: run.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testCoalescedCheckpointAndForcedFinalPreserveEverySettledOutcome() async throws {
        let root = try scratch()
        let store = OperationReportStore(directory: root)
        var run = report()
        let now = Date(timeIntervalSince1970: 100)
        try await store.save(run, now: now)
        run.settle(OperationFileRecord(id: 0, source: URL(fileURLWithPath: "/Photos/a.JPG"), label: "Web", outcome: .skipped))
        let checkpoint = try await store.save(run, force: false, now: now)
        XCTAssertFalse(checkpoint)
        run.finish(.cancelled)
        let final = try await store.save(run, now: now)
        XCTAssertTrue(final)
        let loaded = try await store.load()
        XCTAssertEqual(loaded.reports.first?.report.records.map(\.outcome), [.skipped, .notAttempted])
    }

    func testIngestResultsKeepVerificationAndActualRenamedPathsDistinct() {
        let source = URL(fileURLWithPath: "/Card/a.RAF")
        let planned = URL(fileURLWithPath: "/Shoot/a.RAF")
        let actual = URL(fileURLWithPath: "/Shoot/a-1.RAF")
        let backup = URL(fileURLWithPath: "/Backup/a.RAF")
        let digest = IngestDigest(hex: "ignored-in-report", byteCount: 1)
        let result = IngestReport(results: [
            IngestFileResult(source: source, plannedDestination: planned, destination: actual, role: .primary, outcome: .copied(digest)),
            IngestFileResult(source: source, plannedDestination: backup, destination: backup, role: .backup,
                outcome: .failed(.verificationMismatch(expected: digest, found: digest)))
        ], refusals: [], wasCancelled: true, filesAttempted: 1, filesPlanned: 2, bytesCopied: 1)
        var run = report(.ingest)
        run.finishIngest(result, sources: [source, URL(fileURLWithPath: "/Card/b.RAF")])
        XCTAssertEqual(run.state, .cancelled)
        XCTAssertEqual(run.records.map(\.outcome), [.copied, .failed, .notAttempted])
        XCTAssertEqual(run.records[0].actualDestination, actual.path)
        XCTAssertTrue(run.records[0].renamed)
        XCTAssertNil(run.records[1].actualDestination)
        XCTAssertFalse(run.records[1].detail?.contains("ignored-in-report") == true)
    }
    func testInvalidOutgoingReportIsRefusedBeforeCreatingUnreadableEvidence() async throws {
        let root = try scratch()
        let store = OperationReportStore(directory: root)
        var invalid = report()
        invalid.records.append(invalid.records[0])
        do { try await store.save(invalid); XCTFail("duplicate IDs must be refused") } catch {}
        invalid.records.removeLast()
        invalid.revision = -1
        do { try await store.save(invalid); XCTFail("negative revision must be refused") } catch {}
        let file = await store.file(for: invalid.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testCancelledIngestRetainsMissingBackupRoleForPartlySettledSource() {
        let source = URL(fileURLWithPath: "/Card/a.RAF")
        let actual = URL(fileURLWithPath: "/Primary/a.RAF")
        let digest = IngestDigest(hex: "not-recorded", byteCount: 1)
        let result = IngestReport(results: [
            IngestFileResult(source: source, plannedDestination: actual, destination: actual,
                role: .primary, outcome: .verified(digest))
        ], refusals: [], wasCancelled: true, filesAttempted: 0, filesPlanned: 1, bytesCopied: 1)
        var run = report(.ingest)
        run.finishIngest(result, sources: [source], expectedRoles: [.primary, .backup])
        XCTAssertEqual(run.records.map(\.outcome), [.verified, .notAttempted])
        XCTAssertEqual(run.records[1].label, "backup")
        XCTAssertNil(run.records[1].actualDestination)
        XCTAssertNil(run.records[1].plannedDestination)
        XCTAssertTrue(run.summary.contains("1 not attempted"))
    }

}
