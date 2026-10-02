import XCTest
@testable import LumenCore

final class AuditSafetyTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-audit-safety-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testAlreadyPresentStillChecksThePlannedByteCount() throws {
        let root = try scratch()
        let source = root.appendingPathComponent("source.RAF")
        let destination = root.appendingPathComponent("destination.RAF")
        let prefix = Data(repeating: 7, count: 100)
        try prefix.write(to: source)
        try prefix.write(to: destination)
        let plan = IngestPlan(copies: [IngestPlannedCopy(source: source, byteCount: 5000,
            destinations: [IngestPlannedDestination(url: destination, role: .primary)])])
        let report = VerifiedCopyDriver().run(plan)
        XCTAssertFalse(report.allVerified, "REL-03: identical truncations are not the planned original")
        XCTAssertEqual(report.alreadyPresent.count, 0)
        XCTAssertEqual(try Data(contentsOf: destination), prefix, "Do not destroy the existing partial file")
    }

    /// REL-02's ownership tag is the only LumenCore half of that repair, and nothing on
    /// the Linux lane exercised it: write, splice, re-seed and read it back.
    func testSidecarOwnershipSurvivesSerializeSpliceAndReseed() throws {
        let written = XMPSidecar.serialize(SidecarContent(rating: 2, writeStamp: "2026-10-01T00:00:00Z",
                                                          sourceExtension: "dng"))
        XCTAssertEqual(XMPSidecar.parse(written)?.sourceExtension, "dng")
        var fresh = try XCTUnwrap(XMPSidecar.parse(written))
        // A batch that states its own owner replaces the old one exactly once.
        let restated = XMPSidecar.reseed(SidecarContent(rating: 3, sourceExtension: "nef"),
                                         fields: [.rating], onto: fresh)
        let spliced = try XCTUnwrap(XMPSidecar.update(written, with: restated))
        XCTAssertEqual(XMPSidecar.parse(spliced)?.sourceExtension, "nef")
        XCTAssertEqual(spliced.components(separatedBy: "<lumen:sourceExtension>").count, 2)
        // A batch silent on ownership keeps the document's.
        fresh.sourceExtension = "dng"
        XCTAssertEqual(XMPSidecar.reseed(SidecarContent(rating: 4), fields: [.rating],
                                         onto: fresh).sourceExtension, "dng")
        // Case written by another tool still compares as an extension.
        let upper = written.replacingOccurrences(of: ">dng<", with: ">DNG<")
        XCTAssertEqual(XMPSidecar.parse(upper)?.sourceExtension, "dng")
    }

    #if canImport(SQLite3)
    func testPartialScanCannotRelocateAnUnseenTwinOrRemoveAlbumMembership() throws {
        let root = try scratch()
        let store = try CatalogStore(path: root.appendingPathComponent("lumen.db").path)
        defer { store.close() }
        let folder = try store.registerFolder(path: root.path)
        let a = ScannedFile(filename: "a.ARW", fileSize: 100, fileMTime: 1, quickSig: "same-bytes", ext: "arw")
        let b = ScannedFile(filename: "b.ARW", fileSize: 100, fileMTime: 1, quickSig: "same-bytes", ext: "arw")
        _ = try store.scan(folderID: folder, files: [a], at: 100)
        let original = try XCTUnwrap(store.photo(folderID: folder, filename: a.filename))
        let album = try store.createCollection(name: "Keep")
        try store.addToCollection(album, photoIDs: [original.id])
        _ = try store.scan(folderID: folder, files: [], at: 200, completeListing: false)
        _ = try store.scan(folderID: folder, files: [b], at: 201, completeListing: false)
        let rows = try store.photos(folderID: folder, includeMissing: false)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(try store.photo(folderID: folder, filename: a.filename)?.id, original.id)
        XCTAssertNotEqual(try store.photo(folderID: folder, filename: b.filename)?.id, original.id)
        var query = PhotoQuery(); query.albumID = album; query.includeMissing = false
        XCTAssertEqual(try store.photos(matching: query).map(\.id), [original.id])
        _ = try store.scan(folderID: folder, files: [b], at: 300)
        XCTAssertEqual(try store.photos(folderID: folder, includeMissing: false).count, 1)
        query.includeMissing = true
        XCTAssertEqual(try store.photos(matching: query).map(\.id), [original.id], "Even true missing state preserves album identity")
    }

    func testRecoverySkipsLegacySnapshotWithMissingBrushPayload() throws {
        let root = try scratch()
        let path = root.appendingPathComponent("lumen.db").path
        let backups = root.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let store = try CatalogStore(path: path, cachePath: root.appendingPathComponent("cache.db").path)
        let folder = try store.registerFolder(path: root.path)
        let id = try store.upsertPhoto(PhotoRow(folderID: folder, filename: "frame.jpg", rating: 1))
        let old = backups.appendingPathComponent("lumen-2026-09-20T12-00-00Z.db")
        try store.backup(to: old.path)
        var brush = MaskComponent(op: .add, kind: .brush)
        brush.strokesRef = "blob:xxh64:0123456789abcdef"
        var recipe = Recipe()
        recipe.masks = [Mask(id: "missing-paint", name: "Paint", components: [brush])]
        try store.saveRecipe(recipe, photoID: id, isCurrent: true)
        try store.setRating(5, photoID: id)
        try store.backup(to: backups.appendingPathComponent("lumen-2026-09-21T12-00-00Z.db").path)
        store.close()
        try Data("damaged isolated catalog".utf8).write(to: URL(fileURLWithPath: path))
        let result = CatalogStore.recoverIfNeeded(path: path, backupDirectory: backups.path)
        guard case .restored(let chosen, _) = result.outcome else { return XCTFail("Expected older complete snapshot") }
        XCTAssertEqual(chosen, old.path, "A database without its brush is not a usable snapshot")
    }

    /// A newer snapshot whose brush exists only as damaged bytes, plus an older complete
    /// one. Builds a real content-addressed payload so the hash check is what decides.
    private func brushSnapshots(backupBytes: (Data) -> Data) throws
        -> (path: String, backups: URL, old: URL, newer: URL, live: URL, payload: Data) {
        let root = try scratch()
        let path = root.appendingPathComponent("lumen.db").path
        let backups = root.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let blobs = try BlobStore(directory: root.appendingPathComponent("blobs"))
        let set = BrushStrokeSet(strokes: [BrushStroke(points: [BrushPoint(x: 0.2, y: 0.4),
                                                                BrushPoint(x: 0.7, y: 0.5)])])
        let ref = try blobs.store(set)
        let live = try XCTUnwrap(blobs.url(for: ref))
        let payload = try Data(contentsOf: live)
        let store = try CatalogStore(path: path, cachePath: root.appendingPathComponent("cache.db").path)
        let folder = try store.registerFolder(path: root.path)
        let id = try store.upsertPhoto(PhotoRow(folderID: folder, filename: "frame.jpg", rating: 1))
        let old = backups.appendingPathComponent("lumen-2026-09-20T12-00-00Z.db")
        try store.backup(to: old.path)
        var brush = MaskComponent(op: .add, kind: .brush)
        brush.strokesRef = ref
        var recipe = Recipe()
        recipe.masks = [Mask(id: "paint", name: "Paint", components: [brush])]
        try store.saveRecipe(recipe, photoID: id, isCurrent: true)
        let newer = backups.appendingPathComponent("lumen-2026-09-21T12-00-00Z.db")
        try store.backup(to: newer.path)
        store.close()
        let newerBlobs = newer.deletingPathExtension().appendingPathExtension("blobs")
        try FileManager.default.createDirectory(at: newerBlobs, withIntermediateDirectories: true)
        try backupBytes(payload).write(to: newerBlobs.appendingPathComponent(live.lastPathComponent))
        // The live copy is lost along with the database.
        try FileManager.default.removeItem(at: live)
        try Data("damaged isolated catalog".utf8).write(to: URL(fileURLWithPath: path))
        return (path, backups, old, newer, live, payload)
    }

    func testRecoveryRejectsSnapshotWhoseOnlyBrushCopyIsCorrupt() throws {
        let fixture = try brushSnapshots { _ in Data("not the painting".utf8) }
        let result = CatalogStore.recoverIfNeeded(path: fixture.path, backupDirectory: fixture.backups.path)
        guard case .restored(let chosen, _) = result.outcome else { return XCTFail("Expected older complete snapshot") }
        XCTAssertEqual(chosen, fixture.old.path, "Bytes that do not hash to the reference are not the brush")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.live.path),
                       "Damaged backup bytes must not be published as the live brush")
    }

    func testRecoveryRestoresTheLiveBrushFromTheChosenSnapshot() throws {
        let fixture = try brushSnapshots { $0 }
        let result = CatalogStore.recoverIfNeeded(path: fixture.path, backupDirectory: fixture.backups.path)
        guard case .restored(let chosen, _) = result.outcome else { return XCTFail("Expected newest snapshot") }
        XCTAssertEqual(chosen, fixture.newer.path)
        XCTAssertEqual(try Data(contentsOf: fixture.live), fixture.payload,
                       "The restored catalog's painting must exist where the live store reads it")
    }

    /// The same two snapshots, but the newer one's recipe carries a creative LUT (or a
    /// painted heal) instead of a brush mask. The cube is stored in the same BlobStore,
    /// so the recovery pass has to hold it to the same standard as the strokes: a
    /// restore whose LUT is missing or damaged renders every graded photograph without
    /// its look, because `CreativeLUTStage` resolves to nil on a ref it cannot read.
    private func payloadSnapshots(payload: Data, recipeFor: (String) -> Recipe,
                                  backupBytes: ((Data) -> Data)?,
                                  livePayload: Data? = nil) throws
        -> (path: String, backups: URL, old: URL, newer: URL, live: URL, payload: Data) {
        let root = try scratch()
        let path = root.appendingPathComponent("lumen.db").path
        let backups = root.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let blobs = try BlobStore(directory: root.appendingPathComponent("blobs"))
        let ref = try blobs.store(payload)
        let live = try XCTUnwrap(blobs.url(for: ref))
        let store = try CatalogStore(path: path, cachePath: root.appendingPathComponent("cache.db").path)
        let folder = try store.registerFolder(path: root.path)
        let id = try store.upsertPhoto(PhotoRow(folderID: folder, filename: "frame.jpg", rating: 1))
        let old = backups.appendingPathComponent("lumen-2026-09-20T12-00-00Z.db")
        try store.backup(to: old.path)
        try store.saveRecipe(recipeFor(ref), photoID: id, isCurrent: true)
        let newer = backups.appendingPathComponent("lumen-2026-09-21T12-00-00Z.db")
        try store.backup(to: newer.path)
        store.close()
        if let backupBytes {
            let newerBlobs = newer.deletingPathExtension().appendingPathExtension("blobs")
            try FileManager.default.createDirectory(at: newerBlobs, withIntermediateDirectories: true)
            try backupBytes(payload).write(to: newerBlobs.appendingPathComponent(live.lastPathComponent))
        }
        if let livePayload {
            try livePayload.write(to: live)
        } else {
            try FileManager.default.removeItem(at: live)
        }
        try Data("damaged isolated catalog".utf8).write(to: URL(fileURLWithPath: path))
        return (path, backups, old, newer, live, payload)
    }

    private static let cubeBytes = Data("""
        LUT_3D_SIZE 2
        1.0 0.0 0.0
        0.0 0.0 0.0
        1.0 1.0 0.0
        0.0 1.0 0.0
        1.0 0.0 1.0
        0.0 0.0 1.0
        1.0 1.0 1.0
        0.0 1.0 1.0
        """.utf8)

    private func lutRecipe(_ ref: String) -> Recipe {
        var recipe = Recipe()
        recipe.look.lut = LUTReference(ref: ref, name: "Look", tap: .display, amount: 100)
        return recipe
    }

    func testRecoveryRejectsSnapshotWhoseCreativeLUTIsMissing() throws {
        let fixture = try payloadSnapshots(payload: Self.cubeBytes, recipeFor: lutRecipe,
                                           backupBytes: nil)
        let result = CatalogStore.recoverIfNeeded(path: fixture.path, backupDirectory: fixture.backups.path)
        guard case .restored(let chosen, _) = result.outcome else { return XCTFail("Expected older complete snapshot") }
        XCTAssertEqual(chosen, fixture.old.path,
                       "A snapshot whose LUT exists nowhere restores graded photographs without their look")
    }

    func testRecoveryRejectsSnapshotWhoseOnlyLUTCopyIsCorrupt() throws {
        let fixture = try payloadSnapshots(payload: Self.cubeBytes, recipeFor: lutRecipe,
                                           backupBytes: { _ in Data("LUT_3D_SIZE 2\n".utf8) })
        let result = CatalogStore.recoverIfNeeded(path: fixture.path, backupDirectory: fixture.backups.path)
        guard case .restored(let chosen, _) = result.outcome else { return XCTFail("Expected older complete snapshot") }
        XCTAssertEqual(chosen, fixture.old.path, "Bytes that do not hash to the LUT's ref are not the LUT")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.live.path),
                       "Damaged backup bytes must not be published as the live LUT")
    }

    /// The bulk `BlobStore.restore` never overwrites, so a live cube that is present but
    /// damaged would survive it. The recovery pass is what replaces it, and it keeps the
    /// damaged bytes aside rather than discarding them.
    func testRecoveryRepairsADamagedLiveLUTFromTheChosenSnapshot() throws {
        let damaged = Data("not the cube".utf8)
        let fixture = try payloadSnapshots(payload: Self.cubeBytes, recipeFor: lutRecipe,
                                           backupBytes: { $0 }, livePayload: damaged)
        let result = CatalogStore.recoverIfNeeded(path: fixture.path, backupDirectory: fixture.backups.path)
        guard case .restored(let chosen, _) = result.outcome else { return XCTFail("Expected newest snapshot") }
        XCTAssertEqual(chosen, fixture.newer.path)
        XCTAssertEqual(try Data(contentsOf: fixture.live), fixture.payload,
                       "The restored catalog's LUT must be the cube its ref names")
        let aside = try FileManager.default.contentsOfDirectory(
            atPath: fixture.live.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(fixture.live.lastPathComponent + ".damaged-") }
        XCTAssertEqual(aside.count, 1, "the damaged live bytes were discarded: \(aside)")
    }

    /// A LUT ref that is not a blob address names nothing in the store; it must not
    /// condemn an otherwise complete snapshot.
    func testRecoveryIgnoresALUTRefThatIsNotABlobAddress() throws {
        let fixture = try payloadSnapshots(payload: Self.cubeBytes,
                                           recipeFor: { _ in self.lutRecipe("bundled.teal") },
                                           backupBytes: nil)
        let result = CatalogStore.recoverIfNeeded(path: fixture.path, backupDirectory: fixture.backups.path)
        guard case .restored(let chosen, _) = result.outcome else { return XCTFail("Expected newest snapshot") }
        XCTAssertEqual(chosen, fixture.newer.path)
    }

    /// Painted heal (`develop.heal.strokesRef`) shares the brush's blob shelf and must
    /// be held to the same standard.
    func testRecoveryRejectsSnapshotWhoseHealStrokesAreMissing() throws {
        let set = BrushStrokeSet(strokes: [BrushStroke(points: [BrushPoint(x: 0.3, y: 0.3),
                                                                BrushPoint(x: 0.6, y: 0.6)])])
        let fixture = try payloadSnapshots(payload: try set.encode(), recipeFor: { ref in
            var recipe = Recipe()
            recipe.develop.heal = Heal(strokesRef: ref, count: 1)
            return recipe
        }, backupBytes: nil)
        let result = CatalogStore.recoverIfNeeded(path: fixture.path, backupDirectory: fixture.backups.path)
        guard case .restored(let chosen, _) = result.outcome else { return XCTFail("Expected older complete snapshot") }
        XCTAssertEqual(chosen, fixture.old.path, "A snapshot whose heal strokes exist nowhere is not complete")
    }

    func testReadOnlyIntegrityProbeCannotCreateMissingBackups() throws {
        let path = try scratch().appendingPathComponent("missing.db").path
        XCTAssertFalse(CatalogStore.probeQuickCheck(path: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertThrowsError(try SQLiteDatabase(path: path, readOnly: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testExtendedSQLiteResultsRetainTheirCorruptionClassification() {
        // SQLite result codes: CORRUPT=11, BUSY=5, IOERR=10; low byte is primary.
        let corruptCodes: [Int32] = [11, 11 | (1 << 8), 26]
        for code in corruptCodes {
            XCTAssertTrue(SQLiteError.step(code: code, message: "test", sql: "").indicatesCorruptDatabase)
        }
        let operationalCodes: [Int32] = [5, 5 | (2 << 8), 10, 10 | (3 << 8), 14]
        for code in operationalCodes {
            XCTAssertFalse(SQLiteError.step(code: code, message: "test", sql: "").indicatesCorruptDatabase)
        }
    }

    func testBusyCatalogIsNotReplacedByAnOlderBackup() throws {
        let root = try scratch()
        let db = root.appendingPathComponent("lumen.db").path
        let cache = root.appendingPathComponent("cache.db").path
        let backups = root.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let store = try CatalogStore(path: db, cachePath: cache)
        let folder = try store.registerFolder(path: root.path)
        let id = try store.upsertPhoto(PhotoRow(folderID: folder, filename: "frame.jpg", rating: 1))
        try store.backup(to: backups.appendingPathComponent("lumen-2026-09-21.db").path)
        try store.setRating(5, photoID: id)
        store.close()
        let lock = try SQLiteDatabase(path: db)
        defer { lock.close() }
        try lock.execute("PRAGMA locking_mode=EXCLUSIVE; BEGIN EXCLUSIVE;")
        let recovery = CatalogStore.recoverIfNeeded(path: db, backupDirectory: backups.path)
        try lock.execute("ROLLBACK;")
        lock.close()
        if case .restored = recovery.outcome { XCTFail("REL-01: BUSY is not corruption") }
        XCTAssertFalse(recovery.isDamaged)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.contains(".damaged-") })
        let reopened = try CatalogStore(path: db, cachePath: cache)
        defer { reopened.close() }
        XCTAssertEqual(try reopened.photo(id: id)?.rating, 5)
    }
    #endif
}
