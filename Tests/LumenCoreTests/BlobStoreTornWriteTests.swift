// BlobStoreTornWriteTests.swift
// A torn blob is not a permanent blob.
//
// `store(_:)` writes beside and renames, so it never leaves a half-written payload
// under its final name. `restore(from:)` and `backUp(to:)` used to `copyItem` straight
// onto `xxh64-<digest>.blob`, and every path that could have repaired the result —
// a later restore, a store of the very same bytes — checked only that the file
// existed. So a copy killed halfway left a prefix that hashed to nothing, sitting
// under a name that promised a painting, for good.

import XCTest
@testable import LumenCore

final class BlobStoreTornWriteTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-torn-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private let payload = Data((0..<4096).map { UInt8($0 & 0xff) })

    /// What a killed `copyItem` leaves: the right name, the first hundred bytes.
    private func tear(_ url: URL) throws {
        try payload.prefix(100).write(to: url)
    }

    private func files(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    func testARestoreRepairsATornLivePayloadFromAnIntactBackup() throws {
        let liveDir = root.appendingPathComponent("live", isDirectory: true)
        let backup = root.appendingPathComponent("b.blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let ref = BrushStrokeSet.blobRef(for: payload)
        let url = try XCTUnwrap(try BlobStore(directory: liveDir).url(for: ref))
        try payload.write(to: backup.appendingPathComponent(url.lastPathComponent))
        try tear(url)

        XCTAssertEqual(try BlobStore(directory: liveDir).restore(from: backup), 1,
                       "the restore skipped a live payload that does not hash to its name")
        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertEqual(try BlobStore(directory: liveDir).data(for: ref), payload)
        XCTAssertEqual(try files(in: liveDir), [url.lastPathComponent],
                       "the restore left a temporary file behind")
    }

    func testStoringTheSameBytesRepairsATornPayload() throws {
        let liveDir = root.appendingPathComponent("live", isDirectory: true)
        let ref = BrushStrokeSet.blobRef(for: payload)
        let url = try XCTUnwrap(try BlobStore(directory: liveDir).url(for: ref))
        try tear(url)

        XCTAssertEqual(try BlobStore(directory: liveDir).store(payload), ref)
        XCTAssertEqual(try Data(contentsOf: url), payload,
                       "storing the full payload left the torn file in place")
        XCTAssertEqual(try files(in: liveDir), [url.lastPathComponent])
    }

    func testABackUpRepairsATornBackupCopy() throws {
        let live = try BlobStore(directory: root.appendingPathComponent("live", isDirectory: true))
        let ref = try live.store(payload)
        let name = try XCTUnwrap(live.url(for: ref)).lastPathComponent
        let backup = root.appendingPathComponent("b.blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try tear(backup.appendingPathComponent(name))

        XCTAssertEqual(try live.backUp(to: backup), 1,
                       "the backup skipped a copy that does not hash to its name")
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent(name)), payload)
        XCTAssertEqual(try files(in: backup), [name])
    }

    /// The other direction: a torn file in the backup must not be published into the
    /// live store as if it were the payload.
    func testARestoreDoesNotPublishATornBackupCopy() throws {
        let liveDir = root.appendingPathComponent("live", isDirectory: true)
        let backup = root.appendingPathComponent("b.blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let ref = BrushStrokeSet.blobRef(for: payload)
        let name = try XCTUnwrap(BlobStore.filename(for: ref))
        try tear(backup.appendingPathComponent(name))

        XCTAssertEqual(try BlobStore(directory: liveDir).restore(from: backup), 0)
        XCTAssertEqual(try files(in: liveDir), [])
    }
}
