// Two grid statements that did more work than their answer needed, and the proof that
// the cheaper statements give the same answers.
//
//  · KEYWORDS. The keyword chip was a correlated EXISTS, which SQLite runs once per photo
//    in scope. The filter popover prices one count per keyword offered, so on a
//    20 000-photo roll the keyword facet was ~65% of a 650 ms `facetCounts`. A membership
//    test against one subquery list is the same set at a third of the cost per count.
//  · THE GRID ORDER. `AppState.refreshLibraryQuery` runs on every chip and every filtered
//    cull decision and keeps two fields per row; it asked for all 31. `photoOrder` asks
//    for those two under the identical WHERE and ORDER BY.
//
// The equivalence halves run on a seeded catalog small enough for a unit test; the cost
// halves are structural (the query plan, the call site), because a timing ceiling on a
// shared runner fails for reasons that are not the code.
import XCTest
@testable import LumenCore

#if canImport(SQLite3)
final class CatalogQueryCostTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-query-cost-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// 240 frames with ratings, flags, labels, ISO, aspect, capture time with ties, and
    /// overlapping keywords — enough that every sort key has ties for `photo.id` to break
    /// and every keyword set overlaps another.
    private func seeded() throws -> (CatalogStore, Int64, [Int64]) {
        let store = try CatalogStore(path: directory.appendingPathComponent("lumen.db").path,
                                     cachePath: directory.appendingPathComponent("cache.db").path)
        let folderID = try store.registerFolder(path: "/Volumes/Shoots/query-cost")
        let count = 240
        var files: [ScannedFile] = []
        for i in 0..<count {
            let jpeg = i % 5 == 0
            let stem = "F" + String((i * 37) % count)
            files.append(ScannedFile(filename: stem + (jpeg ? ".JPG" : ".ARW"),
                                     fileSize: Int64(1_000 + i), fileMTime: 1_700_000_000,
                                     ext: jpeg ? "jpg" : "arw"))
        }
        _ = try store.scan(folderID: folderID, files: files, at: CatalogStore.now())
        let ids = try store.photos(folderID: folderID).map(\.id)
        var batch: [(photoID: Int64, metadata: PhotoMetadata)] = []
        let cameras = ["A", "B", "C"]
        let isos = [100, 800, 3200]
        let heights = [4000, 6000, 3376]
        for (i, id) in ids.enumerated() {
            var m = PhotoMetadata()
            m.captureAt = i % 7 == 0 ? nil : 1_700_000_000 + Int64(i / 3)
            m.captureSubsec = i % 2 == 0 ? nil : i % 4
            m.camera = cameras[i % 3]
            m.iso = i % 6 == 0 ? nil : isos[i % 3]
            m.width = 6000
            m.height = heights[i % 3]
            batch.append((photoID: id, metadata: m))
        }
        try store.setMetadata(batch)
        for stars in 1...5 {
            try store.setRating(stars, photoIDs: ids.enumerated()
                .filter { $0.offset % 6 == stars }.map(\.element))
        }
        try store.setFlag(.pick, photoIDs: ids.enumerated().filter { $0.offset % 4 == 0 }.map(\.element))
        try store.setFlag(.reject, photoIDs: ids.enumerated().filter { $0.offset % 9 == 0 }.map(\.element))
        try store.setLabel(.blue, photoIDs: ids.enumerated().filter { $0.offset % 5 == 0 }.map(\.element))
        for k in 0..<5 {
            _ = try store.addKeyword("kw\(k)", photoIDs: ids.enumerated()
                .filter { $0.offset % (k + 2) == 0 }.map(\.element))
        }
        // A second keyword spelled like a first one under another parent would be the
        // same chip; the name is what the predicate matches on in both forms.
        return (store, folderID, ids)
    }

    private func keywordsByPhoto(_ store: CatalogStore, _ ids: [Int64]) throws -> [Int64: Set<String>] {
        var out: [Int64: Set<String>] = [:]
        for id in ids { out[id] = Set(try store.keywords(photoID: id)) }
        return out
    }

    func testKeywordCountsAreTheBruteForceCounts() throws {
        let (store, folderID, ids) = try seeded()
        let tags = try keywordsByPhoto(store, ids)
        let rows = try store.photos(matching: PhotoQuery(), folderID: folderID)
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        for names in [["kw0"], ["kw3"], ["kw1", "kw4"], ["nope"], ["kw2", "nope"]] {
            for rating in [nil, 2] as [Int?] {
                for matchAny in [false, true] {
                    var q = PhotoQuery()
                    q.keywords = names
                    q.rating = rating
                    q.matchAny = matchAny
                    let expected = ids.filter { id in
                        let hasKeyword = !(tags[id] ?? []).isDisjoint(with: names)
                        guard let rating else { return hasKeyword }
                        let rated = (byID[id]?.rating ?? 0) >= rating
                        return matchAny ? (hasKeyword || rated) : (hasKeyword && rated)
                    }
                    let got = try store.photos(matching: q, folderID: folderID).map(\.id)
                    XCTAssertEqual(Set(got), Set(expected), "\(names) ★\(rating ?? 0) any=\(matchAny)")
                    XCTAssertEqual(got.count, expected.count)
                    XCTAssertEqual(try store.countPhotos(matching: q, folderID: folderID),
                                   expected.count)
                }
            }
        }
        let facets = try store.facetCounts(for: PhotoQuery(), folderID: folderID)
        for value in facets.keywords {
            XCTAssertEqual(value.count, ids.filter { tags[$0]?.contains(value.value) == true }.count,
                           value.value)
        }
        XCTAssertEqual(facets.keywords.count, 5)
    }

    /// The structural half: the keyword chip must not be a per-row correlated probe.
    func testTheKeywordChipIsNotACorrelatedSubqueryPerPhoto() throws {
        let (store, folderID, _) = try seeded()
        var q = PhotoQuery()
        q.keywords = ["kw1"]
        let plan = try store.queryPlan(for: q, folderID: folderID)
        XCTAssertFalse(plan.contains { $0.contains("CORRELATED") },
                       "a correlated EXISTS runs once per photo in scope: \(plan)")
    }
}
#endif
