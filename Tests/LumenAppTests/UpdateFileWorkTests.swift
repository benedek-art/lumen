#if os(macOS)
import Foundation
import CryptoKit
import XCTest
@testable import LumenApp

final class UpdateFileWorkTests: XCTestCase {
    private struct ExpectedFailure: Error {}

    @MainActor
    func testFailedRelaunchNeverTerminatesTheRunningProcess() async {
        var terminated = false
        do {
            try await UpdateRelaunch.perform(open: { throw ExpectedFailure() },
                                            terminate: { terminated = true })
            XCTFail("Launch error must reach the installed-but-not-relaunched UI")
        } catch { XCTAssertTrue(error is ExpectedFailure) }
        XCTAssertFalse(terminated)
    }

    @MainActor
    func testSuccessfulRelaunchTerminatesOnlyAfterLaunchCompletes() async throws {
        var launched = false
        var terminated = false
        try await UpdateRelaunch.perform(open: { launched = true }, terminate: {
            XCTAssertTrue(launched)
            terminated = true
        })
        XCTAssertTrue(terminated)
    }

    @MainActor
    func testExtractionScratchIsRemovedAfterSuccessAndFailure() async throws {
        for fail in [false, true] {
            var scratch: URL?
            do {
                try await UpdateFileWork.withScratch { work in
                    scratch = work
                    try Data("extracted bundle".utf8).write(to: work.appendingPathComponent("test"))
                    if fail { throw ExpectedFailure() }
                }
                XCTAssertFalse(fail)
            } catch { XCTAssertTrue(fail && error is ExpectedFailure) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(scratch).path))
        }
    }

    func testStreamingDigestAcceptsExpectedBytesAndRefusesSizeOrHashMismatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("download.zip")
        // More than two chunks, including a partial final chunk.
        let data = Data(repeating: 0x5a, count: 2_100_123)
        try data.write(to: archive)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try await UpdateFileWork.verifyDownload(archive, expectedSize: data.count, digest: digest)
        for (size, hash) in [(data.count + 1, digest), (data.count, String(repeating: "0", count: 64))] {
            do {
                try await UpdateFileWork.verifyDownload(archive, expectedSize: size, digest: hash)
                XCTFail("Corrupt input accepted")
            } catch { XCTAssertTrue(error is UpdateFileWork.Failure) }
        }
        XCTAssertEqual(try Data(contentsOf: archive), data, "Verification must not modify the download")
    }

    func testSuccessfulReplacementPublishesIncomingBundleAndRemovesStaging() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("Current.app")
        let incoming = root.appendingPathComponent("Incoming.app")
        for bundle in [current, incoming] {
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        }
        try Data("old".utf8).write(to: current.appendingPathComponent("marker"))
        try Data("new".utf8).write(to: incoming.appendingPathComponent("marker"))
        try await UpdateFileWork.replaceBundle(incoming, current: current)
        XCTAssertEqual(try Data(contentsOf: current.appendingPathComponent("marker")), Data("new".utf8))
        XCTAssertEqual(try Data(contentsOf: incoming.appendingPathComponent("marker")), Data("new".utf8))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)),
                       Set(["Current.app", "Incoming.app"]))
    }

    func testStagingFailurePreservesCurrentBundleAndCleansStagingPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("Current.app")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        let marker = current.appendingPathComponent("original")
        try Data("current".utf8).write(to: marker)
        do {
            try await UpdateFileWork.replaceBundle(root.appendingPathComponent("missing.app"), current: current)
            XCTFail("Missing incoming bundle accepted")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: marker), Data("current".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["Current.app"])
    }
}
#endif
