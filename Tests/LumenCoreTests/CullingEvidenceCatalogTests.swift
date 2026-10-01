// CullingEvidenceCatalogTests.swift
// The culling pass's storage (cache migration 3) and the evidence chips that read it.
//
// The chips' SQL predicates existed before any of this (`softFocus`, `closedEyes`), with
// no writer behind them and no route from the filter bar to them. These tests hold the
// three things that make them real: the columns arrive by a forward migration on a cache
// that already has rows, the writer and reader agree, and the filter grammar compiles to
// predicates that return the right photographs from a real catalog.

import XCTest
@testable import LumenCore

#if canImport(SQLite3)

final class CullingEvidenceCatalogTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-cull-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var lumenPath: String { directory.appendingPathComponent("lumen.db").path }
    private var cachePath: String { directory.appendingPathComponent("cache.db").path }

    private func makeStore() throws -> CatalogStore {
        try CatalogStore(path: lumenPath, cachePath: cachePath)
    }

    private func seed(_ store: CatalogStore, count: Int) throws -> (Int64, [Int64]) {
        let folderID = try store.registerFolder(path: "/Volumes/Shoots/2026-10-01")
        let files = (0..<count).map {
            ScannedFile(filename: String(format: "DSC%04d.ARW", $0),
                        fileSize: Int64(40_000_000 + $0),
                        fileMTime: 1_700_000_000, ext: "arw")
        }
        _ = try store.scan(folderID: folderID, files: files, at: CatalogStore.now())
        let ids = try files.map {
            try XCTUnwrap(store.photo(folderID: folderID, filename: $0.filename)?.id)
        }
        return (folderID, ids)
    }

    private func score(_ id: Int64, _ sharpness: Double?, hash: UInt64? = 0) -> FrameScoreRow {
        FrameScoreRow(photoID: id, sharpness: sharpness, noise: 0.004,
                      perceptualHash: hash, analysedLongEdge: 1024)
    }

    // MARK: - The migration

    /// A cache.db written by the previous build (version 2), holding a frame_score row,
    /// opens under this build at version 3 with the row intact, the new columns present
    /// and NULL, and the two indexes created.
    func testAVersionTwoCacheMigratesForwardKeepingItsRows() throws {
        // Build the version-2 cache exactly as the previous build did: the base DDL and
        // every migration up to 2.
        let old = try SQLiteDatabase(path: cachePath)
        try old.execute(CatalogSchema.cacheDDL)
        for migration in CatalogStore.cacheMigrations where migration.version <= 2 {
            try old.execute(migration.sql)
        }
        try old.setUserVersion(2)
        try old.run("""
        INSERT INTO frame_score (photo_id, sharpness, junk, analyzer_rev, computed_at)
        VALUES (1, 0.7, 1, 1, 1700000000);
        """)
        old.close()

        let store = try makeStore()
        let (_, ids) = try seed(store, count: 1)
        XCTAssertEqual(ids, [1], "the seeded photo must be the row the old cache scored")
        let row = try XCTUnwrap(store.frameScore(photoID: 1),
                                "the migration lost a row the old build wrote")
        XCTAssertEqual(row.sharpness, 0.7)
        XCTAssertNil(row.perceptualHash)
        XCTAssertNil(row.burstID)
        XCTAssertNil(row.analysedLongEdge)
        store.close()

        let raw = try SQLiteDatabase(path: cachePath)
        defer { raw.close() }
        XCTAssertEqual(try raw.userVersion(), 3)
        XCTAssertEqual(try raw.scalarInt("SELECT junk FROM frame_score WHERE photo_id = 1;"), 1,
                       "another detector's evidence must survive the migration")
        for index in ["frame_score_sharpness", "frame_score_burst"] {
            XCTAssertNotNil(try raw.scalarText(
                "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = '\(index)';"),
                "\(index) is missing")
        }
    }

    func testAFreshCacheIsAtTheLatestVersion() throws {
        let store = try makeStore()
        store.close()
        let raw = try SQLiteDatabase(path: cachePath)
        defer { raw.close() }
        XCTAssertEqual(try raw.userVersion(),
                       CatalogStore.cacheMigrations.map(\.version).max())
        XCTAssertEqual(try raw.userVersion(), 3)
    }

    /// The sort and the chip stay index-backed (§15.2).
    func testTheBurstChipIsIndexBacked() throws {
        let store = try makeStore()
        defer { store.close() }
        _ = try seed(store, count: 3)
        var query = PhotoQuery()
        query.burstState = .inBurst
        let plan = try store.queryPlan(for: query).joined(separator: " | ")
        XCTAssertTrue(plan.contains("SEARCH f USING INTEGER PRIMARY KEY"), plan)
        XCTAssertFalse(plan.contains("SCAN f ") || plan.contains("SCAN cache.frame_score"),
                       "the burst chip scans frame_score: \(plan)")
    }

    // MARK: - Writer and reader

    func testAFrameScoreRoundTripsIncludingAHashWithItsTopBitSet() throws {
        let store = try makeStore()
        defer { store.close() }
        let (_, ids) = try seed(store, count: 1)
        let hash: UInt64 = 0xF00D_0000_DEAD_BEEF   // negative as an Int64
        try store.recordFrameScore(FrameScoreRow(photoID: ids[0], sharpness: 0.62,
                                                 noise: 0.003, perceptualHash: hash,
                                                 analysedLongEdge: 900),
                                   at: 1_700_000_123)
        let row = try XCTUnwrap(store.frameScore(photoID: ids[0]))
        XCTAssertEqual(row.sharpness, 0.62)
        XCTAssertEqual(row.noise, 0.003)
        XCTAssertEqual(row.perceptualHash, hash)
        XCTAssertEqual(row.analysedLongEdge, 900)
        XCTAssertEqual(row.analyzerRevision, SharpnessScorer.analyzerRevision)
        XCTAssertEqual(row.computedAt, 1_700_000_123)
    }

    /// Re-measuring one frame must not ungroup it: the burst id is the folder's, written
    /// by the grouping pass, and a single-frame write has no business erasing it.
    func testReMeasuringAFrameKeepsItsBurst() throws {
        let store = try makeStore()
        defer { store.close() }
        let (folderID, ids) = try seed(store, count: 2)
        for id in ids { try store.recordFrameScore(score(id, 0.5)) }
        try store.replaceBursts([BurstGroup(members: ids, ranked: ids.reversed())],
                                folderID: folderID)
        try store.recordFrameScore(score(ids[0], 0.9))
        let row = try XCTUnwrap(store.frameScore(photoID: ids[0]))
        XCTAssertEqual(row.sharpness, 0.9)
        XCTAssertEqual(row.burstID, ids[0])
        XCTAssertEqual(row.burstRank, 2)
    }

    func testTheBacklogIsEveryFrameWithoutARowAtThisRevision() throws {
        let store = try makeStore()
        defer { store.close() }
        let (folderID, ids) = try seed(store, count: 3)
        XCTAssertEqual(try store.photosMissingFrameScore(folderID: folderID), ids)

        try store.recordFrameScore(score(ids[0], 0.5))
        var stale = score(ids[1], 0.5)
        stale.analyzerRevision = SharpnessScorer.analyzerRevision - 1
        try store.recordFrameScore(stale)
        XCTAssertEqual(try store.photosMissingFrameScore(folderID: folderID),
                       [ids[1], ids[2]],
                       "a row at another revision is a recompute, not an answer")
        XCTAssertEqual(try store.photosMissingFrameScore(folderID: folderID,
                                                         afterID: ids[1]), [ids[2]])
    }

    /// Regrouping is whole: a frame that is no longer in any burst loses its id.
    func testReplacingBurstsClearsTheOldGrouping() throws {
        let store = try makeStore()
        defer { store.close() }
        let (folderID, ids) = try seed(store, count: 4)
        for id in ids { try store.recordFrameScore(score(id, 0.5)) }
        try store.replaceBursts([BurstGroup(members: Array(ids[0...2]),
                                            ranked: Array(ids[0...2]))], folderID: folderID)
        try store.replaceBursts([BurstGroup(members: [ids[2], ids[3]],
                                            ranked: [ids[3], ids[2]])], folderID: folderID)
        XCTAssertNil(try store.frameScore(photoID: ids[0])?.burstID)
        XCTAssertNil(try store.frameScore(photoID: ids[1])?.burstID)
        XCTAssertEqual(try store.frameScore(photoID: ids[2])?.burstID, ids[2])
        XCTAssertEqual(try store.frameScore(photoID: ids[2])?.burstRank, 2)
        XCTAssertEqual(try store.frameScore(photoID: ids[3])?.burstRank, 1)
    }

    /// A file replaced on disk is a different picture; its evidence goes with it.
    func testAChangedFileLosesItsCullingEvidence() throws {
        let store = try makeStore()
        defer { store.close() }
        let (folderID, ids) = try seed(store, count: 1)
        try store.recordFrameScore(score(ids[0], 0.8))
        try store.recordFaces([FaceEvidenceRow(rect: NormalizedRect(x: 0.4, y: 0.3, width: 0.1,
                                                                    height: 0.1),
                                               eyesOpen: 0.9, focus: 0.7)],
                              photoID: ids[0])
        _ = try store.scan(folderID: folderID,
                           files: [ScannedFile(filename: "DSC0000.ARW", fileSize: 41_000_000,
                                               fileMTime: 1_700_000_500, ext: "arw")],
                           at: CatalogStore.now())
        XCTAssertNil(try store.frameScore(photoID: ids[0]),
                     "the old file's sharpness score survived its replacement")
        XCTAssertTrue(try store.faces(photoID: ids[0]).isEmpty)
        XCTAssertEqual(try store.photosMissingFrameScore(folderID: folderID), ids)
    }

    func testBurstCandidatesCarryTimeCameraAndHash() throws {
        let store = try makeStore()
        defer { store.close() }
        let (folderID, ids) = try seed(store, count: 2)
        try store.setMetadata(PhotoMetadata(captureAt: 1_700_000_000, captureSubsec: 250_000,
                                            camera: "Sony A1", cameraSerial: "123"),
                              photoID: ids[0])
        try store.recordFrameScore(score(ids[0], 0.4, hash: 0xABCD))
        let candidates = try store.burstCandidates(folderID: folderID)
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].captureTime, 1_700_000_000.25)
        XCTAssertEqual(candidates[0].camera, "123", "the body's serial separates two bodies")
        XCTAssertEqual(candidates[0].hash, 0xABCD)
        XCTAssertEqual(candidates[0].sharpness, 0.4)
        XCTAssertNil(candidates[1].captureTime)
        XCTAssertNil(candidates[1].hash, "an unmeasured frame has no hash, not hash 0")
    }

    // MARK: - The chips, through the grammar, against the catalog

    private func filenames(_ store: CatalogStore, _ filter: LibraryFilter,
                           folderID: Int64, sort: PhotoQuery.SortKey = .filename,
                           ascending: Bool = true) throws -> [String] {
        try store.photos(matching: filter.query(sortKey: sort, ascending: ascending,
                                                albumID: nil),
                         folderID: folderID).map(\.filename)
    }

    /// Five frames: sharp, soft, unscored, soft-in-a-burst, sharp-in-a-burst-with-a-blink.
    private func evidenceFixture(_ store: CatalogStore) throws -> Int64 {
        let (folderID, ids) = try seed(store, count: 5)
        try store.recordFrameScore(score(ids[0], 0.85))
        try store.recordFrameScore(score(ids[1], 0.12))
        // ids[2] never measured.
        try store.recordFrameScore(score(ids[3], 0.20))
        try store.recordFrameScore(score(ids[4], 0.70))
        try store.replaceBursts([BurstGroup(members: [ids[3], ids[4]],
                                            ranked: [ids[4], ids[3]])], folderID: folderID)
        let rect = NormalizedRect(x: 0.4, y: 0.3, width: 0.1, height: 0.1)
        try store.recordFaces([FaceEvidenceRow(rect: rect, eyesOpen: 0.05, focus: 0.7),
                               FaceEvidenceRow(rect: rect, eyesOpen: 0.95, focus: 0.7)],
                              photoID: ids[4])
        try store.recordFaces([FaceEvidenceRow(rect: rect, eyesOpen: 0.9, focus: 0.8)],
                              photoID: ids[0])
        try store.recordFaces([FaceEvidenceRow(rect: rect, eyesOpen: nil, focus: nil)],
                              photoID: ids[1])
        return folderID
    }

    func testSoftFocusIsTheMeasuredSoftFramesAndNeverTheUnmeasuredOnes() throws {
        let store = try makeStore()
        defer { store.close() }
        let folderID = try evidenceFixture(store)
        var filter = LibraryFilter()
        filter.softFocus = true
        XCTAssertEqual(try filenames(store, filter, folderID: folderID),
                       ["DSC0001.ARW", "DSC0003.ARW"],
                       "not measured must never read as measured soft")
    }

    func testClosedEyesIsAnyFaceReadingClosedAndNeverAFaceWithNoReading() throws {
        let store = try makeStore()
        defer { store.close() }
        let folderID = try evidenceFixture(store)
        var filter = LibraryFilter()
        filter.closedEyes = true
        XCTAssertEqual(try filenames(store, filter, folderID: folderID), ["DSC0004.ARW"])
    }

    func testTheBurstChipSplitsTheFolderInTwo() throws {
        let store = try makeStore()
        defer { store.close() }
        let folderID = try evidenceFixture(store)
        var filter = LibraryFilter()
        filter.burst = .inBurst
        let inside = try filenames(store, filter, folderID: folderID)
        XCTAssertEqual(inside, ["DSC0003.ARW", "DSC0004.ARW"])
        filter.burst = .notInBurst
        let outside = try filenames(store, filter, folderID: folderID)
        XCTAssertEqual(outside, ["DSC0000.ARW", "DSC0001.ARW", "DSC0002.ARW"],
                       "an unmeasured frame is not in a burst")
        XCTAssertEqual(Set(inside).union(outside).count, 5)
    }

    /// The evidence chips obey the bar's one rule like every other criterion: AND across
    /// criteria, OR under Match: Any.
    func testEvidenceChipsJoinLikeEveryOtherCriterion() throws {
        let store = try makeStore()
        defer { store.close() }
        let folderID = try evidenceFixture(store)
        var filter = LibraryFilter()
        filter.softFocus = true
        filter.burst = .inBurst
        XCTAssertEqual(try filenames(store, filter, folderID: folderID), ["DSC0003.ARW"])
        filter.matchAny = true
        XCTAssertEqual(try filenames(store, filter, folderID: folderID),
                       ["DSC0001.ARW", "DSC0003.ARW", "DSC0004.ARW"])
    }

    /// The sort the menu offers: sharpest first, unscored last in BOTH directions.
    func testTheSharpnessSortOrdersByScoreWithUnscoredLast() throws {
        let store = try makeStore()
        defer { store.close() }
        let folderID = try evidenceFixture(store)
        let filter = LibraryFilter()
        XCTAssertEqual(try filenames(store, filter, folderID: folderID, sort: .sharpness,
                                     ascending: false),
                       ["DSC0000.ARW", "DSC0004.ARW", "DSC0003.ARW", "DSC0001.ARW",
                        "DSC0002.ARW"])
        XCTAssertEqual(try filenames(store, filter, folderID: folderID, sort: .sharpness,
                                     ascending: true),
                       ["DSC0001.ARW", "DSC0003.ARW", "DSC0004.ARW", "DSC0000.ARW",
                        "DSC0002.ARW"])
    }

    /// The pass end to end over the catalog: candidates out, grouper, groups back in.
    func testGroupingFromTheCatalogRoundTrips() throws {
        let store = try makeStore()
        defer { store.close() }
        let (folderID, ids) = try seed(store, count: 4)
        let times: [Int64] = [100, 100, 101, 200]
        for (i, id) in ids.enumerated() {
            try store.setMetadata(PhotoMetadata(captureAt: 1_700_000_000 + times[i],
                                                captureSubsec: i * 100_000,
                                                camera: "Z9"), photoID: id)
            try store.recordFrameScore(score(id, [0.3, 0.8, 0.5, 0.9][i], hash: 0xFF00))
        }
        let groups = BurstGrouper.group(try store.burstCandidates(folderID: folderID))
        try store.replaceBursts(groups, folderID: folderID)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(try store.frameScore(photoID: ids[1])?.burstRank, 1)
        XCTAssertEqual(try store.frameScore(photoID: ids[2])?.burstRank, 2)
        XCTAssertEqual(try store.frameScore(photoID: ids[0])?.burstRank, 3)
        XCTAssertNil(try store.frameScore(photoID: ids[3])?.burstID,
                     "a frame 99 s later is not in the burst")
    }

    /// The pass writes evidence tables only: grouping never touches the photographer's
    /// flags or stacks (D37).
    func testThePassWritesNoFlagAndNoStack() throws {
        let store = try makeStore()
        defer { store.close() }
        let folderID = try evidenceFixture(store)
        let rows = try store.photos(folderID: folderID)
        XCTAssertTrue(rows.allSatisfy { $0.flag == .unflagged })
        XCTAssertTrue(try rows.allSatisfy { try store.stack(containing: $0.id) == nil })
    }
}

#endif
