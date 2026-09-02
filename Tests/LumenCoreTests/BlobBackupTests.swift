// BlobBackupTests.swift
// The brush strokes are in the backup (K-018).
//
// `CatalogStore.backup` is `VACUUM main INTO` — it snapshots the catalog database and
// nothing else. The brush paintings do not live there; they live in the blob store
// beside it, content-addressed. So a backup captured every recipe intact, each one
// referencing a `strokesRef` whose bytes were never copied, and a restore gave back a
// library in which every brush mask rasterized to nothing.
//
// The sidecar is not the second copy either: it carries strokes only up to its size cap,
// so a heavily painted frame had its work in exactly one place in the world.

import XCTest
@testable import LumenCore

final class BlobBackupTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-blobs-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func store(_ name: String) throws -> BlobStore {
        try BlobStore(directory: root.appendingPathComponent(name, isDirectory: true))
    }

    private func painting(_ x: Double) -> BrushStrokeSet {
        var stroke = BrushStroke(size: 0.25, feather: 50, flow: 100, density: 100)
        stroke.points = [BrushPoint(x: x, y: 0.5)]
        return BrushStrokeSet(strokes: [stroke])
    }

    // MARK: - The defect

    /// A catalog restored without its payloads is a library of empty masks.
    func testAPaintingSurvivesABackupAndRestoreIntoAFreshStore() throws {
        let live = try store("live")
        let ref = try live.store(painting(0.25))
        XCTAssertNotNil(live.strokeSet(for: ref))

        let backup = root.appendingPathComponent("lumen-20260902.blobs", isDirectory: true)
        XCTAssertEqual(try live.backUp(to: backup), 1)

        // What a restore actually looks like: a new machine, or a blob directory the
        // catalog snapshot arrived without.
        let fresh = try store("fresh")
        XCTAssertNil(fresh.strokeSet(for: ref), "the fixture must start empty")
        XCTAssertEqual(try fresh.restore(from: backup), 1)
        XCTAssertEqual(fresh.strokeSet(for: ref)?.strokes.first?.points.first?.x, 0.25,
                       "the brush painting did not come back with the catalog")
    }

    // MARK: - What must NOT change

    /// Content addressing makes a repeat backup cheap: a payload already there is
    /// already correct, so nothing is copied twice and nothing is overwritten.
    func testASecondBackupCopiesOnlyWhatIsNew() throws {
        let live = try store("live")
        _ = try live.store(painting(0.1))
        let backup = root.appendingPathComponent("b.blobs", isDirectory: true)
        XCTAssertEqual(try live.backUp(to: backup), 1)
        XCTAssertEqual(try live.backUp(to: backup), 0, "it copied the same payload twice")
        _ = try live.store(painting(0.9))
        XCTAssertEqual(try live.backUp(to: backup), 1, "a new payload was not picked up")
    }

    /// A RESTORE MUST NOT OVERWRITE LIVE WORK. A payload the live store already holds
    /// is, by content addressing, the same bytes — and anything the live store has that
    /// the backup does not is newer, so the restore has no business touching it.
    func testARestoreLeavesNewerLiveWorkAlone() throws {
        let live = try store("live")
        let old = try live.store(painting(0.1))
        let backup = root.appendingPathComponent("b.blobs", isDirectory: true)
        _ = try live.backUp(to: backup)

        let newer = try live.store(painting(0.9))     // painted after the backup
        XCTAssertEqual(try live.restore(from: backup), 0,
                       "the restore copied over payloads that were already present")
        XCTAssertNotNil(live.strokeSet(for: old))
        XCTAssertNotNil(live.strokeSet(for: newer),
                        "a painting made after the backup was destroyed by the restore")
    }

    /// A backup directory that is not there is not an error — a catalog restored from
    /// a snapshot taken before this fix has no payload directory beside it, and that
    /// must open rather than throw.
    func testRestoringFromAnAbsentBackupIsSilentlyNothing() throws {
        let live = try store("live")
        XCTAssertEqual(
            try live.restore(from: root.appendingPathComponent("nope.blobs")), 0)
    }

    /// Only payloads. A stray file in either directory is not copied, because the
    /// blob store's contract is that everything in it is content-addressed.
    func testOnlyPayloadsAreCopied() throws {
        let live = try store("live")
        _ = try live.store(painting(0.5))
        try Data("not a blob".utf8).write(
            to: live.directory.appendingPathComponent("README.txt"))
        let backup = root.appendingPathComponent("b.blobs", isDirectory: true)
        XCTAssertEqual(try live.backUp(to: backup), 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: backup.appendingPathComponent("README.txt").path))
    }
}
