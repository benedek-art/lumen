// PreviewCacheTests.swift
// The disk preview cache's rules, and the `cache.preview` bookkeeping underneath them.
//
// These are the tests that did not exist while README goal #1 — "next photo in under
// 50 ms from a pre-decoded cache" — sat at zero. Every function this file exercises was
// already written and already correct-looking; `recordPreview`, `preview`,
// `touchPreview`, `invalidatePreviews` and `pruneCache` had no caller and no assertion
// of any kind, so nothing in the repository could tell whether the cache the schema
// describes was a cache or a table.
//
// The policy half is deliberately in LumenCore rather than beside the ImageIO calls
// that use it: LumenApp has no test target and does not compile on the development
// machine, and a rule that cannot be run is a rule nobody can hold to account.

import XCTest
@testable import LumenCore

final class PreviewCachePolicyTests: XCTestCase {

    // MARK: - The ladder is docs/15 §15.6's ladder

    func testTheRungsAreTheOnesTheCatalogDocumentSpecifies() {
        // thumb 256 / grid 1024 / fit 2560 / 1:1 full res. The code shipped
        // 256/512/1024/2048, which appears in no document, and nothing noticed because
        // nothing on disk was keyed by it.
        XCTAssertEqual(ThumbnailLadder.pixels(for: .thumb), 256)
        XCTAssertEqual(ThumbnailLadder.pixels(for: .grid), 1024)
        XCTAssertEqual(ThumbnailLadder.pixels(for: .fit), 2560)
    }

    func testTheOneToOneRungIsNotBuiltAndNothingPretendsOtherwise() {
        // Level 3 is full resolution, stored as tiles by §15.6, and there is no tiling
        // scheme here. The honest form of "unbuilt" is a rung with no size: nothing can
        // request it, nothing can record it, and no path can be built for it.
        XCTAssertNil(ThumbnailLadder.pixels(for: .oneToOne))
        XCTAssertFalse(ThumbnailLadder.levels.contains { ThumbnailLadder.level(for: $0) == .oneToOne },
                       "a bucket resolves to the unbuilt rung")
        for size in [1, 256, 1024, 2560, 6000, 45_000] {
            XCTAssertNotEqual(ThumbnailLadder.level(for: ThumbnailLadder.bucket(for: size)),
                              .oneToOne)
        }
        XCTAssertNil(PreviewCache.rowForDecode(photoID: 1, pixels: 99_999,
                                               currentFingerprint: "", source: .embedded,
                                               path: "p", bytes: 1))
        // And a request for it is a decode, never a claim to have it.
        XCTAssertEqual(PreviewCache.decide(request: .oneToOne, fingerprint: "",
                                           stored: [row(level: .oneToOne)]),
                       .decode)
    }

    func testEveryBucketIsARungAndEveryRungIsABucket() {
        XCTAssertEqual(ThumbnailLadder.levels, [256, 1024, 2560])
        XCTAssertEqual(ThumbnailLadder.levels.sorted(), ThumbnailLadder.levels,
                       "bucket(for:) walks the list in order and needs it ascending")
        XCTAssertEqual(Set(ThumbnailLadder.levels).count, ThumbnailLadder.levels.count)
        for size in 1...3000 {
            let bucket = ThumbnailLadder.bucket(for: size)
            guard let level = ThumbnailLadder.level(for: bucket) else {
                return XCTFail("\(size) snapped to \(bucket), which is not a stored rung")
            }
            XCTAssertEqual(ThumbnailLadder.pixels(for: level), bucket)
        }
    }

    // MARK: - Freshness

    func testAMatchingFingerprintIsCurrentAtEveryRung() {
        for level in PreviewLevel.allCases {
            XCTAssertEqual(PreviewCache.freshness(of: row(level: level, fp: "xxh64:aa"),
                                                  against: "xxh64:aa"),
                           .current)
        }
    }

    func testAnEditDoesNotInvalidateTheBrowseRungs() {
        // docs/15 §15.6: the preview cache serves browsing, not the develop loop. A
        // grid cell that re-rendered the moment a slider moved would be the "Lightroom
        // changed my photos" jump, in the middle of a cull pass.
        for level in [PreviewLevel.thumb, .grid] {
            XCTAssertEqual(PreviewCache.freshness(of: row(level: level, fp: ""),
                                                  against: "xxh64:beef"),
                           .browsable)
            XCTAssertTrue(PreviewCache.isBrowseRung(level))
        }
    }

    func testAnEditDoesInvalidateTheRungsThatClaimToShowTheCurrentRender() {
        for level in [PreviewLevel.fit, .oneToOne] {
            XCTAssertEqual(PreviewCache.freshness(of: row(level: level, fp: "xxh64:old",
                                                          source: .lumen),
                                                  against: "xxh64:new"),
                           .stale)
            XCTAssertFalse(PreviewCache.isBrowseRung(level))
        }
    }

    func testTheCamerasOwnRenderStaysServableAfterAnEdit() {
        // Only a LUMEN row claims to depict a recipe. An embedded fit is the badged
        // first step of docs/10 §10.1's embedded → draft → full progression, and calling
        // it stale would re-extract a full-size embedded JPEG on every loupe entry after
        // the first edit — at the one rung where the 50 ms goal is measured.
        for level in PreviewLevel.allCases {
            XCTAssertEqual(PreviewCache.freshness(of: row(level: level, fp: "",
                                                          source: .embedded),
                                                  against: "xxh64:new"),
                           .browsable)
        }
    }

    func testTheBrowseRungSplitAgreesWithWhatInvalidatePreviewsDeletes() {
        // `invalidatePreviews` deletes `level >= 2`. If the two ever disagree, one half
        // deletes a payload the other half is still serving.
        for level in PreviewLevel.allCases {
            XCTAssertEqual(PreviewCache.isBrowseRung(level),
                           level.rawValue < PreviewLevel.fit.rawValue)
        }
    }

    // MARK: - Which rung answers a request

    func testAnExactRungAnswersItsOwnRequest() {
        let stored = row(level: .grid, fp: "xxh64:aa", path: "previews/ab/g.heic")
        XCTAssertEqual(PreviewCache.decide(request: .grid, fingerprint: "xxh64:aa",
                                           stored: [stored]),
                       .serve(stored))
    }

    func testASmallerRungIsNeverAnAnswer() {
        // Serving 256 pixels to a 1024 request fills the cell, reports a hit, and
        // produces a contact sheet four times softer than the code believes. Nothing
        // downstream can detect it.
        let thumb = row(level: .thumb, fp: "xxh64:aa")
        XCTAssertEqual(PreviewCache.decide(request: .grid, fingerprint: "xxh64:aa",
                                           stored: [thumb]),
                       .decode)
        XCTAssertEqual(PreviewCache.decide(request: .fit, fingerprint: "xxh64:aa",
                                           stored: [thumb, row(level: .grid, fp: "xxh64:aa")]),
                       .decode)
    }

    func testALargerRungAnswersWhenTheExactOneIsMissing() {
        let fit = row(level: .fit, fp: "xxh64:aa", path: "previews/cd/f.heic")
        XCTAssertEqual(PreviewCache.decide(request: .grid, fingerprint: "xxh64:aa",
                                           stored: [fit]),
                       .serve(fit))
        // …and it is read down to the size that was asked for, not to its own size:
        // a grid cell must not put a 2560 entry in a memory LRU budgeted for 1024s.
        XCTAssertEqual(PreviewCache.readPixels(request: .grid, served: fit), 1024)
        XCTAssertEqual(PreviewCache.readPixels(request: .fit, served: fit), 2560)
    }

    func testTheHandoffPrefersLumensRenderOverTheCamerasAtTheSameRung() {
        // Two rows at one rung is what cache migration 2 rebuilt the table for: the
        // embedded and the Lumen render coexist while the swap docs/10 §10.1 describes
        // is pending. Once Lumen's render of the current recipe exists it is the one to
        // show, and leaving that to SQLite's row order would make the handoff happen at
        // random.
        let camera = row(level: .grid, fp: "", source: .embedded,
                         path: "previews/ab/camera.heic")
        let lumen = row(level: .grid, fp: "xxh64:new", source: .lumen,
                        path: "previews/cd/lumen.heic")
        XCTAssertEqual(PreviewCache.decide(request: .grid, fingerprint: "xxh64:new",
                                           stored: [camera, lumen]),
                       .serve(lumen))
        XCTAssertEqual(PreviewCache.decide(request: .grid, fingerprint: "xxh64:new",
                                           stored: [lumen, camera]),
                       .serve(lumen),
                       "the answer changed when the rows arrived in the other order")
    }

    func testTheSmallestServableRungWins() {
        // After an edit the stored grid is the as-shot render the cull is being done
        // against, and the stored fit may be the new one. Preferring the exact rung is
        // what stops the contact sheet jumping to the new rendering mid-pass.
        let grid = row(level: .grid, fp: "", path: "previews/ab/g.heic")
        let fit = row(level: .fit, fp: "xxh64:new", path: "previews/cd/f.heic")
        XCTAssertEqual(PreviewCache.decide(request: .grid, fingerprint: "xxh64:new",
                                           stored: [fit, grid]),
                       .serve(grid))
    }

    func testAStaleFitIsNeverServedHoweverManyPixelsItHas() {
        let fit = row(level: .fit, fp: "xxh64:old", source: .lumen)
        XCTAssertEqual(PreviewCache.decide(request: .fit, fingerprint: "xxh64:new",
                                           stored: [fit]),
                       .decode)
        XCTAssertEqual(PreviewCache.decide(request: .grid, fingerprint: "xxh64:new",
                                           stored: [fit]),
                       .decode)
    }

    func testAnEmptyCacheIsADecode() {
        XCTAssertEqual(PreviewCache.decide(request: .thumb, fingerprint: "",
                                           stored: []),
                       .decode)
    }

    // MARK: - What a finished decode records

    func testADecodeAtARungRecordsThatRung() {
        let recorded = PreviewCache.rowForDecode(photoID: 42, pixels: 1024,
                                                 currentFingerprint: "xxh64:aa",
                                                 source: .lumen,
                                                 path: "previews/ab/x.heic",
                                                 bytes: 90_000)
        XCTAssertEqual(recorded?.level, .grid)
        XCTAssertEqual(recorded?.photoID, 42)
        XCTAssertEqual(recorded?.recipeFP, "xxh64:aa")
        XCTAssertEqual(recorded?.source, .lumen)
        XCTAssertEqual(recorded?.bytes, 90_000)
    }

    func testACameraRenderIsNeverFiledUnderTheUsersRecipe() {
        // The pixels of an embedded extraction contain none of the user's edits. Filed
        // under the current fingerprint they would come back as `.current`, and the user
        // would be grading against a picture missing their own last twenty moves.
        XCTAssertEqual(PreviewCache.recordingFingerprint(source: .embedded,
                                                         current: "xxh64:new"), "")
        XCTAssertEqual(PreviewCache.recordingFingerprint(source: .lumen,
                                                         current: "xxh64:new"),
                       "xxh64:new")
        let row = PreviewCache.rowForDecode(photoID: 1, pixels: 2560,
                                            currentFingerprint: "xxh64:new",
                                            source: .embedded, path: "p", bytes: 1)
        XCTAssertEqual(row?.recipeFP, "")
        XCTAssertEqual(PreviewCache.freshness(of: row!, against: "xxh64:new"),
                       .browsable,
                       "an as-shot camera render came back as the current render")
    }

    func testADecodeAtASizeThatIsNotARungRecordsNothing() {
        // The key says which rung; the file is whatever the decoder produced. A 512-px
        // decode filed under the 1024 rung is a lie the next reader cannot detect, so
        // the answer is no row at all.
        for pixels in [1, 255, 512, 1023, 1600, 2559, 4096] {
            XCTAssertNil(PreviewCache.rowForDecode(photoID: 1, pixels: pixels,
                                                   currentFingerprint: "",
                                                   source: .embedded,
                                                   path: "p", bytes: 1),
                         "\(pixels) is not a rung and must not be recorded as one")
        }
    }

    func testTheSourceIsCarriedThroughBecauseTheHonestyBadgeReadsIt() {
        // `preview.source` is what tells the user whether they are looking at the
        // camera's rendering or Lumen's (docs/10 §10.1). It was dead because nothing
        // ever wrote a row.
        XCTAssertEqual(PreviewCache.rowForDecode(photoID: 1, pixels: 256,
                                                 currentFingerprint: "",
                                                 source: .lumen, path: "p",
                                                 bytes: 1)?.source,
                       .lumen)
        XCTAssertEqual(PreviewCache.rowForDecode(photoID: 1, pixels: 256,
                                                 currentFingerprint: "",
                                                 source: .embedded, path: "p",
                                                 bytes: 1)?.source,
                       .embedded)
    }

    // MARK: - Where a payload lives

    func testThePayloadPathIsShardedTwoHexCharactersDeep() {
        let path = PreviewCache.payloadPath(photoID: 7, level: .grid,
                                            recipeFP: "xxh64:aa", ext: "heic")
        let parts = path.split(separator: "/").map(String.init)
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0], PreviewCache.directoryName)
        XCTAssertEqual(parts[1].count, 2)
        XCTAssertTrue(parts[1].allSatisfy { $0.isHexDigit && !$0.isUppercase },
                      "shard \(parts[1]) is not lowercase hex")
        XCTAssertTrue(path.hasSuffix(".heic"))
        XCTAssertEqual(PreviewCache.shardDirectory(for: path),
                       "\(PreviewCache.directoryName)/\(parts[1])")
    }

    func testEveryPartOfTheCacheKeyReachesThePath() {
        // A path that dropped any one of the three would let two rows name one file,
        // and the second `recordPreview` would overwrite the first photo's pixels with
        // the second's while both rows still claimed to be valid.
        let base = PreviewCache.payloadPath(photoID: 7, level: .grid,
                                            recipeFP: "xxh64:aa", ext: "heic")
        let others = [
            PreviewCache.payloadPath(photoID: 8, level: .grid,
                                     recipeFP: "xxh64:aa", ext: "heic"),
            PreviewCache.payloadPath(photoID: 7, level: .fit,
                                     recipeFP: "xxh64:aa", ext: "heic"),
            PreviewCache.payloadPath(photoID: 7, level: .grid,
                                     recipeFP: "xxh64:bb", ext: "heic"),
        ]
        for other in others {
            XCTAssertNotEqual(base, other)
        }
        XCTAssertEqual(base, PreviewCache.payloadPath(photoID: 7, level: .grid,
                                                      recipeFP: "xxh64:aa", ext: "heic"),
                       "the same key must name the same file on the next launch")
    }

    func testTheShardsFillEvenly() {
        // Sharded on a hash rather than on the photo id, so a folder imported in one
        // pass does not put every one of its previews in the same directory.
        var occupied: Set<String> = []
        for id in 0..<4096 {
            let path = PreviewCache.payloadPath(photoID: Int64(id), level: .thumb,
                                                recipeFP: "", ext: "heic")
            if let shard = PreviewCache.shardDirectory(for: path) { occupied.insert(shard) }
        }
        XCTAssertGreaterThan(occupied.count, 200,
                             "4096 consecutive ids landed in only \(occupied.count) "
                                 + "shards of a possible 256")
    }

    func testTheExtensionIsTheCallersBecauseTheEncoderMayFallBack() {
        // HEIC is the documented format; a machine whose encoder refuses it writes JPEG
        // rather than nothing, and the row has to name the file that actually exists.
        XCTAssertTrue(PreviewCache.payloadPath(photoID: 1, level: .thumb,
                                               recipeFP: "", ext: "jpg")
            .hasSuffix(".jpg"))
    }

    // MARK: - Back pressure on the encode queue

    func testAnEmptyEncodeQueueAdmitsAFrameHoweverLarge() {
        // A body whose one frame weighs more than the whole budget must still be
        // cacheable, or the cache would be silently empty for exactly the cameras whose
        // files cost the most to decode.
        XCTAssertTrue(PreviewCache.admitsWrite(pendingBytes: 0,
                                               imageBytes: 4 * PreviewCache.pendingWriteBudgetBytes))
    }

    func testTheEncodeQueueRefusesWhatWouldPushItOverBudget() {
        // Eight decode workers in front of one encoder: without this the queue grows
        // without limit and every waiting image stays in memory, which turns the first
        // pass over a card — the operation this cache exists for — into a crash.
        let budget = 1_000
        XCTAssertTrue(PreviewCache.admitsWrite(pendingBytes: 400, imageBytes: 600,
                                               budget: budget))
        XCTAssertFalse(PreviewCache.admitsWrite(pendingBytes: 400, imageBytes: 601,
                                                budget: budget))
        XCTAssertFalse(PreviewCache.admitsWrite(pendingBytes: budget, imageBytes: 1,
                                                budget: budget))
    }

    // MARK: - Budget

    func testTheBudgetIsAFifthOfFreeSpaceInsideTheDocumentedClamp() {
        let gb: Int64 = 1_000_000_000
        XCTAssertEqual(PreviewCache.budgetBytes(freeBytes: 250 * gb), 50 * gb)
        // Clamped up at the bottom of the range…
        XCTAssertEqual(PreviewCache.budgetBytes(freeBytes: 100 * gb), 20 * gb)
        XCTAssertEqual(PreviewCache.budgetBytes(freeBytes: 40 * gb),
                       PreviewCache.minimumBudgetBytes)
        // …and down at the top: 20% of a 4 TB drive is 800 GB of previews.
        XCTAssertEqual(PreviewCache.budgetBytes(freeBytes: 4_000 * gb),
                       PreviewCache.maximumBudgetBytes)
    }

    func testTheBudgetNeverExceedsWhatIsActuallyFree() {
        // The doc's 10 GB floor is a floor on the budget, not permission to fill the
        // disk: on a nearly full boot volume "clamped up to 10 GB" authorizes a cache
        // larger than the space it has to live in.
        let gb: Int64 = 1_000_000_000
        for free in [1, 2, 5, 6, 9] {
            XCTAssertEqual(PreviewCache.budgetBytes(freeBytes: Int64(free) * gb),
                           Int64(free) * gb)
        }
        XCTAssertEqual(PreviewCache.budgetBytes(freeBytes: 0), 0)
        XCTAssertEqual(PreviewCache.budgetBytes(freeBytes: -1), 0)
    }

    // MARK: - Helper

    private func row(level: PreviewLevel, fp: String = "",
                     source: PreviewSource = .lumen,
                     path: String = "previews/00/x.heic",
                     bytes: Int64 = 1) -> PreviewRow {
        PreviewRow(photoID: 1, level: level, recipeFP: fp, source: source,
                   path: path, bytes: bytes)
    }
}

#if canImport(SQLite3)

/// The `cache.preview` bookkeeping itself, against a real SQLite file.
///
/// Every function here was written, migrated (cache migration 2 rebuilt the table for
/// exactly this key) and never once executed outside a schema test. A cache that has
/// never been made to evict anything is a table with an eviction function in it.
final class PreviewCacheStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-previews-" + UUID().uuidString,
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeStore() throws -> CatalogStore {
        try CatalogStore(path: directory.appendingPathComponent("lumen.db").path,
                         cachePath: directory.appendingPathComponent("cache.db").path)
    }

    private func record(_ store: CatalogStore, photo: Int64, level: PreviewLevel,
                        fp: String = "", source: PreviewSource = .embedded,
                        bytes: Int64, usedAt: Int64) throws {
        let path = PreviewCache.payloadPath(photoID: photo, level: level,
                                            recipeFP: fp, ext: "heic")
        try store.recordPreview(PreviewRow(photoID: photo, level: level, recipeFP: fp,
                                           source: source, path: path, bytes: bytes,
                                           createdAt: usedAt, lastUsedAt: usedAt))
    }

    // MARK: - Round trip

    func testARecordedPreviewIsStillThereOnTheNextLaunch() throws {
        // The whole point of the disk cache: a relaunch must not re-decode every
        // embedded JPEG in the folder.
        let first = try makeStore()
        try record(first, photo: 1, level: .grid, source: .embedded,
                   bytes: 120_000, usedAt: 1_700_000_000)
        first.close()

        let second = try makeStore()
        let row = try second.preview(photoID: 1, level: .grid)
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.bytes, 120_000)
        XCTAssertEqual(row?.source, .embedded)
        XCTAssertEqual(row?.path, PreviewCache.payloadPath(photoID: 1, level: .grid,
                                                           recipeFP: "", ext: "heic"))
        second.close()
    }

    func testRecordingTheSameKeyTwiceReplacesRatherThanDuplicates() throws {
        let store = try makeStore()
        try record(store, photo: 1, level: .grid, bytes: 100, usedAt: 10)
        try record(store, photo: 1, level: .grid, source: .lumen, bytes: 500, usedAt: 20)
        let rows = try store.previews(photoID: 1)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.bytes, 500)
        // The camera-render handoff: a Lumen render replaces the embedded one under the
        // same key, and the badge is supposed to read this field.
        XCTAssertEqual(rows.first?.source, .lumen)
        XCTAssertEqual(try store.previewCacheBytes(), 500)
        store.close()
    }

    func testTwoRecipesOfOnePhotoAreTwoRowsAtTheSameRung() throws {
        // Cache migration 2 exists for this: one row per (photo, level) could not hold
        // the embedded and the Lumen render at once, which is the swap docs/10 §10.1
        // describes.
        let store = try makeStore()
        try record(store, photo: 1, level: .fit, fp: "", bytes: 10, usedAt: 1)
        try record(store, photo: 1, level: .fit, fp: "xxh64:aa", bytes: 20, usedAt: 2)
        XCTAssertEqual(try store.previews(photoID: 1).count, 2)
        XCTAssertEqual(try store.preview(photoID: 1, level: .fit, recipeFP: "")?.bytes, 10)
        XCTAssertEqual(try store.preview(photoID: 1, level: .fit,
                                         recipeFP: "xxh64:aa")?.bytes, 20)
        store.close()
    }

    func testTouchingAPreviewMovesItsLRUStamp() throws {
        let store = try makeStore()
        try record(store, photo: 1, level: .grid, bytes: 10, usedAt: 100)
        try store.touchPreview(photoID: 1, level: .grid, at: 999)
        XCTAssertEqual(try store.preview(photoID: 1, level: .grid)?.lastUsedAt, 999)
        // Creation stays put — eviction is by last use, and a cache that re-dated
        // creation on every serve could not tell an old preview from a new one.
        XCTAssertEqual(try store.preview(photoID: 1, level: .grid)?.createdAt, 100)
        store.close()
    }

    // MARK: - Invalidation

    func testAnEditStalesTheFitAndLeavesTheBrowseRungsAlone() throws {
        let store = try makeStore()
        for level in PreviewLevel.allCases {
            try record(store, photo: 1, level: level, fp: "xxh64:old",
                       bytes: 10, usedAt: 1)
        }
        let stale = try store.invalidatePreviews(photoID: 1, keeping: "xxh64:new")
        XCTAssertEqual(Set(stale.map(\.level)), [.fit, .oneToOne])
        // Returned, not merely deleted: the caller has to unlink the payload files, and
        // a delete that told nobody would leak them forever.
        for row in stale {
            XCTAssertFalse(row.path.isEmpty)
        }
        let left = try store.previews(photoID: 1)
        XCTAssertEqual(Set(left.map(\.level)), [.thumb, .grid])
        store.close()
    }

    func testTheCurrentRecipesFitSurvivesItsOwnInvalidation() throws {
        let store = try makeStore()
        try record(store, photo: 1, level: .fit, fp: "xxh64:new", bytes: 10, usedAt: 1)
        XCTAssertTrue(try store.invalidatePreviews(photoID: 1,
                                                   keeping: "xxh64:new").isEmpty)
        XCTAssertNotNil(try store.preview(photoID: 1, level: .fit,
                                          recipeFP: "xxh64:new"))
        store.close()
    }

    // MARK: - Eviction

    func testACacheInsideItsBudgetEvictsNothing() throws {
        let store = try makeStore()
        try record(store, photo: 1, level: .fit, bytes: 500, usedAt: 1)
        XCTAssertTrue(try store.pruneCache(maxBytes: 1_000).isEmpty)
        XCTAssertEqual(try store.previewCacheBytes(), 500)
        store.close()
    }

    func testThumbnailsAreNeverEvicted() throws {
        // docs/15 §15.6: level 0 is permanent — 3–6 GB per 100k photos and worth every
        // byte, because a thumb miss is a grey contact sheet.
        let store = try makeStore()
        for id in 1...20 {
            try record(store, photo: Int64(id), level: .thumb, bytes: 1_000,
                       usedAt: Int64(id))
        }
        let evicted = try store.pruneCache(maxBytes: 0)
        XCTAssertTrue(evicted.isEmpty,
                      "prune evicted \(evicted.count) permanent thumbnails")
        XCTAssertEqual(try store.previewCacheBytes(), 20_000)
        store.close()
    }

    func testEvictionOrderIsOneToOneThenFitThenGrid() throws {
        let store = try makeStore()
        try record(store, photo: 1, level: .thumb, bytes: 1_000, usedAt: 1)
        try record(store, photo: 1, level: .grid, bytes: 1_000, usedAt: 1)
        try record(store, photo: 1, level: .fit, bytes: 1_000, usedAt: 1)
        try record(store, photo: 1, level: .oneToOne, bytes: 1_000, usedAt: 1)

        // Reclaim one row's worth at a time: the most expensive rung to keep goes first.
        XCTAssertEqual(try store.pruneCache(maxBytes: 3_000).map(\.level), [.oneToOne])
        XCTAssertEqual(try store.pruneCache(maxBytes: 2_000).map(\.level), [.fit])
        XCTAssertEqual(try store.pruneCache(maxBytes: 1_000).map(\.level), [.grid])
        XCTAssertEqual(Set(try store.previews(photoID: 1).map(\.level)), [.thumb])
        store.close()
    }

    func testWithinARungTheLeastRecentlyViewedGoesFirst() throws {
        let store = try makeStore()
        for id in 1...5 {
            try record(store, photo: Int64(id), level: .fit, bytes: 1_000,
                       usedAt: Int64(100 + id))
        }
        // 5,000 stored against a 2,000 budget: three rows have to go, the three oldest.
        let evicted = try store.pruneCache(maxBytes: 2_000)
        XCTAssertEqual(evicted.map(\.photoID), [1, 2, 3])
        XCTAssertEqual(Set(try store.previews(photoID: 4).map(\.level)), [.fit])
        XCTAssertEqual(Set(try store.previews(photoID: 5).map(\.level)), [.fit])
        store.close()
    }

    func testEvictionReturnsThePathsSoThePayloadsCanBeUnlinked() throws {
        // Bookkeeping only: this layer deletes rows and the caller deletes files. If the
        // rows went without the paths coming back, the cache would shrink in the
        // database and never on disk — the budget would be fiction.
        let store = try makeStore()
        let path = PreviewCache.payloadPath(photoID: 9, level: .fit,
                                            recipeFP: "xxh64:aa", ext: "heic")
        try store.recordPreview(PreviewRow(photoID: 9, level: .fit, recipeFP: "xxh64:aa",
                                           source: .lumen, path: path, bytes: 4_000,
                                           createdAt: 1, lastUsedAt: 1))
        let evicted = try store.pruneCache(maxBytes: 0)
        XCTAssertEqual(evicted.map(\.path), [path])
        XCTAssertEqual(try store.previewCacheBytes(), 0)
        store.close()
    }

    // MARK: - The rules and the store, together

    func testTheLookupPolicyAnswersFromWhatTheStoreActuallyReturns() throws {
        // The two halves joined: rows out of SQLite, decision out of LumenCore. This is
        // the shape the loader runs — everything except the ImageIO call.
        let store = try makeStore()
        try record(store, photo: 3, level: .thumb, fp: "", bytes: 8_000, usedAt: 1)
        try record(store, photo: 3, level: .grid, fp: "", bytes: 80_000, usedAt: 1)

        let stored = try store.previews(photoID: 3)
        let thumb = try XCTUnwrap(stored.first { $0.level == .thumb })
        XCTAssertEqual(PreviewCache.decide(request: .thumb, fingerprint: "",
                                           stored: stored),
                       .serve(thumb))
        // Nothing at fit yet, and grid is too small to stand in for it.
        XCTAssertEqual(PreviewCache.decide(request: .fit, fingerprint: "",
                                           stored: stored),
                       .decode)

        // The user edits. The cull keeps its grid cells; the loupe does not get handed a
        // picture of the old recipe.
        _ = try store.invalidatePreviews(photoID: 3, keeping: "xxh64:new")
        let after = try store.previews(photoID: 3)
        let grid = try XCTUnwrap(after.first { $0.level == .grid })
        XCTAssertEqual(PreviewCache.decide(request: .grid, fingerprint: "xxh64:new",
                                           stored: after),
                       .serve(grid))
        XCTAssertEqual(PreviewCache.decide(request: .fit, fingerprint: "xxh64:new",
                                           stored: after),
                       .decode)
        store.close()
    }
}

#endif
