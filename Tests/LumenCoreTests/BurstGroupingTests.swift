// BurstGroupingTests.swift
// Stacking bursts by capture time (docs/10 §10.2): the rule, and the catalog command
// that must never touch a stack the photographer made.

import XCTest
@testable import LumenCore

final class BurstGroupingTests: XCTestCase {

    private func frame(_ id: Int64, _ seconds: Double, _ body: String? = "A") -> BurstFrame {
        BurstFrame(id: id, captureMicros: Int64(seconds * 1_000_000), body: body)
    }

    func testAChainOfCloseFramesIsOneBurstAndAGapEndsIt() {
        let frames = [frame(1, 0), frame(2, 0.1), frame(3, 2.1), frame(4, 4.0),
                      frame(5, 6.01), frame(6, 20), frame(7, 21.5)]
        // 1-2-3-4 chain (each step <= 2 s though the burst spans 4 s); 5 is 2.01 s after
        // 4; 6-7 are a pair.
        XCTAssertEqual(BurstGrouping.groups(frames), [[1, 2, 3, 4], [6, 7]])
        XCTAssertEqual(BurstGrouping.groups(frames, maxGap: 0.5), [[1, 2]])
    }

    func testExactlyTheGapStillJoins() {
        XCTAssertEqual(BurstGrouping.groups([frame(1, 10), frame(2, 12)]), [[1, 2]])
    }

    /// Two shooters firing in the same seconds are two bursts, interleaved on the clock.
    func testBodiesAreGroupedSeparately() {
        let frames = [frame(1, 0, "A"), frame(2, 0.5, "B"), frame(3, 1.0, "A"),
                      frame(4, 1.5, "B"), frame(5, 30, "A")]
        XCTAssertEqual(BurstGrouping.groups(frames), [[1, 3], [2, 4]])
    }

    func testFramesWithoutATimeAreNeverGroupedAndOrderIsStable() {
        let frames = [frame(3, 5), BurstFrame(id: 9, captureMicros: nil, body: "A"),
                      frame(1, 5), frame(2, 5.5)]
        XCTAssertEqual(BurstGrouping.groups(frames), [[1, 3, 2]],
                       "ties on time must order by id, and an untimed frame stays out")
        let fromColumns = BurstFrame(id: 1, captureAt: 100, captureSubsec: 250_000, body: nil)
        XCTAssertEqual(fromColumns.captureMicros, 100_250_000)
    }
}

#if canImport(SQLite3)

final class BurstStackingCatalogTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-bursts-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testBurstsStackOnceAndAManualStackIsNeverTouched() throws {
        let store = try CatalogStore(path: directory.appendingPathComponent("lumen.db").path,
                                     cachePath: directory.appendingPathComponent("cache.db").path)
        defer { store.close() }
        let folderID = try store.registerFolder(path: "/Volumes/Card/DCIM")
        let files = (0..<7).map {
            ScannedFile(filename: String(format: "IMG_%04d.CR3", $0),
                        fileSize: Int64(25_000_000 + $0), fileMTime: 1_700_000_000, ext: "cr3")
        }
        _ = try store.scan(folderID: folderID, files: files, at: CatalogStore.now())
        let p = try files.compactMap { try store.photo(folderID: folderID, filename: $0.filename)?.id }
        // Seconds: 0, 1, 1.5 | 10, 11 (manually stacked) | 30 | no time
        let times: [(Int64?, Int?)] = [(1000, 0), (1001, 0), (1001, 500_000),
                                        (1010, 0), (1011, 0), (1030, 0), (nil, nil)]
        try store.setMetadata(zip(p, times).map { id, t in
            (photoID: id, metadata: PhotoMetadata(captureAt: t.0, captureSubsec: t.1,
                                                  camera: "R5"))
        })
        let manual = try store.createStack(origin: "manual", photoIDs: [p[4], p[3]],
                                           pickPhotoID: p[4])

        let made = try store.stackBursts(folderID: folderID)
        XCTAssertEqual(made.count, 1, "the manually stacked pair was regrouped, or a "
                       + "lone frame became a stack")
        let burst = try XCTUnwrap(made.first)
        XCTAssertEqual(try store.stackMembers(stackID: burst), [p[0], p[1], p[2]])
        XCTAssertEqual(try store.stack(containing: p[0])?.origin, "burst-auto")
        XCTAssertEqual(try store.stack(containing: p[0])?.pickPhotoID, p[0])

        let kept = try XCTUnwrap(store.stack(containing: p[3]))
        XCTAssertEqual(kept.id, manual)
        XCTAssertEqual(kept.pickPhotoID, p[4], "the manual stack's pick moved")
        XCTAssertEqual(try store.stackMembers(stackID: manual), [p[4], p[3]])

        XCTAssertEqual(try store.stackBursts(folderID: folderID), [],
                       "running it twice made stacks again")
    }
}

#endif
