// CatalogPlatformTripwireTests.swift
// Deliberately NOT behind `#if canImport(SQLite3)`. The catalog and about twenty
// suites are; on Linux that check is true only while Sources/CSQLite3/module.modulemap
// finds /usr/include/sqlite3.h. If it stops, they compile out, the throwing stub
// CatalogStore links instead, and `swift test` stays green. This test does not.

import XCTest
@testable import LumenCore

final class CatalogPlatformTripwireTests: XCTestCase {

    func testTheRealCatalogIsCompiledOnThisPlatform() throws {
        #if !canImport(SQLite3)
        XCTFail("SQLite3 module unavailable: CatalogStore is the throwing stub and every "
                + "catalog suite compiled out (install libsqlite3-dev / check "
                + "Sources/CSQLite3/module.modulemap)")
        #endif
        XCTAssertFalse(CatalogStore.migrations.isEmpty,
                       "the stub CatalogStore is linked instead of the real one")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-tripwire-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try CatalogStore(path: dir.appendingPathComponent("lumen.db").path)
        store.close()
    }
}
