// KeywordHierarchyTests.swift
// Keyword hierarchy and synonyms (catalog migration 4), and the migration itself run
// against catalogs written by older builds.

import XCTest
@testable import LumenCore

final class KeywordPathTests: XCTestCase {
    func testPathsParseRootFirstAndOddEntriesStayLiteral() {
        XCTAssertEqual(KeywordPath.parse(" Places > Iceland >Reykjavik "),
                       ["Places", "Iceland", "Reykjavik"])
        XCTAssertEqual(KeywordPath.parse("dawn"), ["dawn"])
        XCTAssertEqual(KeywordPath.parse("a >> b"), ["a >> b"],
                       "an empty component was guessed into a hierarchy")
        XCTAssertEqual(KeywordPath.parse("f/2.8 >"), ["f/2.8 >"])
        XCTAssertEqual(KeywordPath.parse("   "), [])
        XCTAssertEqual(KeywordPath.display(["Places", "Iceland"]), "Places > Iceland")
        XCTAssertEqual(KeywordPath.leaf("Places > Iceland"), "Iceland")
    }
}

#if canImport(SQLite3)

final class KeywordHierarchyTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-keywords-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private var path: String { directory.appendingPathComponent("lumen.db").path }
    private var cachePath: String { directory.appendingPathComponent("cache.db").path }

    private func seed(_ store: CatalogStore, count: Int) throws -> (Int64, [Int64]) {
        let folderID = try store.registerFolder(path: "/Volumes/Shoots/iceland")
        let files = (0..<count).map {
            ScannedFile(filename: String(format: "DSCF%04d.RAF", $0),
                        fileSize: Int64(50_000_000 + $0), fileMTime: 1_700_000_000, ext: "raf")
        }
        _ = try store.scan(folderID: folderID, files: files, at: CatalogStore.now())
        let ids = try files.compactMap { try store.photo(folderID: folderID, filename: $0.filename)?.id }
        return (folderID, ids)
    }

    private func ids(_ store: CatalogStore, folderID: Int64,
                     _ shape: (inout PhotoQuery) -> Void) throws -> [Int64] {
        var q = PhotoQuery()
        q.sortKey = .filename
        shape(&q)
        return try store.photos(matching: q, folderID: folderID).map(\.id)
    }

    // MARK: - Hierarchy

    func testAHierarchyIsFiledShownFilteredAndSearched() throws {
        let store = try CatalogStore(path: path, cachePath: cachePath)
        defer { store.close() }
        let (folderID, p) = try seed(store, count: 4)
        try store.addKeyword("Places > Iceland > Reykjavik", photoIDs: [p[0]])
        // A bare name that exists in the tree tags THAT keyword, not a new root.
        try store.addKeyword("Iceland", photoIDs: [p[1]])
        try store.addKeyword("dawn", photoIDs: [p[2]])

        XCTAssertEqual(try store.keywords(photoID: p[0]), ["Places > Iceland > Reykjavik"])
        XCTAssertEqual(try store.keywords(photoID: p[1]), ["Places > Iceland"],
                       "a bare name grew a second keyword instead of finding the filed one")
        XCTAssertEqual(try store.allKeywords().map(\.value),
                       ["Places", "Places > Iceland", "Places > Iceland > Reykjavik", "dawn"])

        // The chip on a parent includes what is filed under it.
        XCTAssertEqual(try ids(store, folderID: folderID) { $0.keywords = ["Iceland"] },
                       [p[0], p[1]])
        XCTAssertEqual(try ids(store, folderID: folderID) { $0.keywords = ["Reykjavik"] },
                       [p[0]])
        XCTAssertEqual(try ids(store, folderID: folderID) { $0.keywords = ["Places"] },
                       [p[0], p[1]])

        // Text search reaches ancestors too, on the index and on the fallback.
        XCTAssertEqual(try ids(store, folderID: folderID) { $0.text = "Places" }, [p[0], p[1]])
        if store.isTextIndexAvailable {
            try store.debugExecute("DROP TABLE cache.photo_fts;")
            try store.addKeyword("dusk", photoIDs: [p[3]])   // trips the index off
            XCTAssertFalse(store.isTextIndexAvailable)
            XCTAssertEqual(try ids(store, folderID: folderID) { $0.text = "Places" },
                           [p[0], p[1]], "the LIKE fallback does not reach ancestors")
        }

        // Removal by the path the sidebar shows is exact.
        try store.removeKeyword("Places > Iceland", photoIDs: [p[0], p[1]])
        XCTAssertEqual(try store.keywords(photoID: p[1]), [])
        XCTAssertEqual(try store.keywords(photoID: p[0]), ["Places > Iceland > Reykjavik"],
                       "removing the parent took the child off a photo tagged only with "
                       + "the child")
    }

    func testTheSameNameUnderTwoParentsIsTwoKeywords() throws {
        let store = try CatalogStore(path: path, cachePath: cachePath)
        defer { store.close() }
        let (_, p) = try seed(store, count: 2)
        try store.addKeyword("Birds > Gulls", photoIDs: [p[0]])
        try store.addKeyword("Teams > Gulls", photoIDs: [p[1]])
        XCTAssertEqual(try store.keywords(photoID: p[0]), ["Birds > Gulls"])
        XCTAssertEqual(try store.keywords(photoID: p[1]), ["Teams > Gulls"])
        // And the identity index refuses a true duplicate.
        XCTAssertThrowsError(try store.debugExecute("""
        INSERT INTO keyword (parent_id, name)
        SELECT parent_id, name FROM keyword WHERE name = 'Gulls' LIMIT 1;
        """))
    }

    // MARK: - Synonyms

    func testASynonymFindsTagsAndFiltersAsItsKeyword() throws {
        let store = try CatalogStore(path: path, cachePath: cachePath)
        defer { store.close() }
        let (folderID, p) = try seed(store, count: 3)
        try store.addKeyword("Places > Iceland > Reykjavik", photoIDs: [p[0]])
        try store.addKeyword("Places > Iceland", photoIDs: [p[1]])

        XCTAssertTrue(try store.addSynonym("Lydveldid", toKeyword: "Places > Iceland"))
        XCTAssertFalse(try store.addSynonym("Iceland", toKeyword: "Places > Iceland"),
                       "a keyword's own name was stored as its synonym")
        XCTAssertFalse(try store.addSynonym("x", toKeyword: "Nowhere > Else"))
        XCTAssertEqual(try store.synonyms(ofKeyword: "Places > Iceland"), ["Lydveldid"])

        // Existing photographs become findable by it: they were re-indexed.
        XCTAssertEqual(try ids(store, folderID: folderID) { $0.text = "Lydveldid" },
                       [p[0], p[1]])
        XCTAssertEqual(try ids(store, folderID: folderID) { $0.keywords = ["Lydveldid"] },
                       [p[0], p[1]])
        // Typing the synonym tags the keyword.
        try store.addKeyword("Lydveldid", photoIDs: [p[2]])
        XCTAssertEqual(try store.keywords(photoID: p[2]), ["Places > Iceland"])
        XCTAssertFalse(try store.allKeywords().map(\.value).contains("Lydveldid"),
                       "the synonym became a keyword of its own")

        try store.removeSynonym("Lydveldid", fromKeyword: "Places > Iceland")
        XCTAssertEqual(try ids(store, folderID: folderID) { $0.text = "Lydveldid" }, [])
    }

    // MARK: - The migration, from catalogs older builds wrote

    /// A catalog at `version`, built from the base DDL and the migrations that existed
    /// then — the same statements those builds ran — with keyword rows that break the
    /// identity migration 4 introduces.
    private func writeOldCatalog(version: Int) throws -> (photos: [Int64], keywords: [Int64]) {
        let raw = try SQLiteDatabase(path: path)
        defer { raw.close() }
        try raw.execute(CatalogSchema.lumenDDL)
        try raw.setUserVersion(CatalogSchema.schemaVersion)
        for migration in CatalogStore.migrations where migration.version <= version {
            try raw.execute(migration.sql)
            try raw.setUserVersion(migration.version)
        }
        try raw.execute("""
        INSERT INTO folder (id, path) VALUES (1, '/Volumes/Old');
        INSERT INTO photo (id, folder_id, filename, file_size, file_mtime)
          VALUES (1, 1, 'a.NEF', 1, 1), (2, 1, 'b.NEF', 2, 1), (3, 1, 'c.NEF', 3, 1);
        INSERT INTO keyword (id, parent_id, name) VALUES
          (10, NULL, 'dawn'), (11, NULL, 'dawn'), (12, NULL, 'Dawn'),
          (20, NULL, 'Places'), (21, NULL, 'Places'),
          (30, 20, 'Iceland'), (31, 21, 'Iceland');
        INSERT INTO photo_keyword (photo_id, keyword_id) VALUES
          (1, 10), (1, 11), (2, 11), (3, 12), (1, 31), (2, 30);
        """)
        XCTAssertEqual(try raw.userVersion(), version)
        return ([1, 2, 3], [10, 11, 12])
    }

    private func assertMigrated(file: StaticString = #filePath, line: UInt = #line) throws {
        let store = try CatalogStore(path: path, cachePath: cachePath)
        XCTAssertEqual(try store.keywords(photoID: 1), ["Places > Iceland", "dawn"],
                       "photo 1 kept a duplicate or lost a keyword", file: file, line: line)
        XCTAssertEqual(try store.keywords(photoID: 2), ["Places > Iceland", "dawn"],
                       file: file, line: line)
        XCTAssertEqual(try store.keywords(photoID: 3), ["Dawn"],
                       "a different spelling was folded into another keyword",
                       file: file, line: line)
        XCTAssertEqual(try store.allKeywords(),
                       [FacetValue(value: "Dawn", count: 1),
                        FacetValue(value: "Places", count: 0),
                        FacetValue(value: "Places > Iceland", count: 2),
                        FacetValue(value: "dawn", count: 2)], file: file, line: line)
        // The new features work on the migrated catalog.
        XCTAssertTrue(try store.addSynonym("Island", toKeyword: "Places > Iceland"),
                      file: file, line: line)
        store.close()

        let raw = try SQLiteDatabase(path: path)
        defer { raw.close() }
        XCTAssertEqual(try raw.userVersion(), CatalogStore.latestSchemaVersion,
                       file: file, line: line)
        XCTAssertNotNil(try raw.scalarText(
            "SELECT sql FROM sqlite_master WHERE name = 'keyword_identity';"),
                        file: file, line: line)
        XCTAssertEqual(try raw.scalarInt("PRAGMA foreign_key_check;"), nil,
                       "the fold left a dangling reference", file: file, line: line)
    }

    func testAVersion3CatalogMigratesAndFoldsDuplicateKeywords() throws {
        _ = try writeOldCatalog(version: 3)
        try assertMigrated()
    }

    func testAVersion1CatalogMigratesAllTheWay() throws {
        _ = try writeOldCatalog(version: 1)
        try assertMigrated()
    }

    /// Reopening a migrated catalog does nothing, and nothing changes.
    func testTheMigrationRunsOnce() throws {
        _ = try writeOldCatalog(version: 3)
        try assertMigrated()
        let store = try CatalogStore(path: path, cachePath: cachePath)
        XCTAssertEqual(try store.keywords(photoID: 1), ["Places > Iceland", "dawn"])
        store.close()
    }
}

#endif
