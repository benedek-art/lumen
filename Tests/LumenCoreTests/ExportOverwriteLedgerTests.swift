// ExportOverwriteLedgerTests.swift
// Overwrite replaces only a file Lumen exported, never an original outside the batch.

import XCTest
@testable import LumenCore

final class ExportOverwriteLedgerTests: XCTestCase {

    private let folder = URL(fileURLWithPath: "/Deliveries")
    private func file(_ name: String) -> URL { folder.appendingPathComponent(name) }

    /// A file Lumen did not write (another catalogued photo outside the batch, or
    /// anything else) at the wanted name: Overwrite renames past it.
    func testOverwriteRefusesAFileLumenDidNotExport() {
        let wanted = file("IMG_0001.jpg")
        let onDisk: Set<URL> = [wanted]
        let before = ExportRecipe.placement(for: wanted, policy: .overwrite,
                                            claimedThisRun: { _ in false },
                                            existsOnDisk: { onDisk.contains($0) })
        XCTAssertEqual(before, .write(wanted, replacing: true), "the unguarded answer")
        let guarded = ExportRecipe.placement(for: wanted, policy: .overwrite,
                                             claimedThisRun: { _ in false },
                                             existsOnDisk: { onDisk.contains($0) },
                                             isLumenExport: { _ in false })
        XCTAssertEqual(guarded, .write(file("IMG_0001-1.jpg"), replacing: false))
    }

    func testOverwriteRefusesACataloguedOriginalEvenIfLogged() {
        let wanted = file("IMG_0002.jpg")
        let catalogued: Set<String> = [ExportRecipe.pathKey(wanted)]
        let placement = ExportRecipe.placement(
            for: wanted, policy: .overwrite, claimedThisRun: { _ in false },
            existsOnDisk: { $0 == wanted },
            isOriginal: { catalogued.contains(ExportRecipe.pathKey($0)) },
            isLumenExport: { _ in true })
        XCTAssertEqual(placement, .write(file("IMG_0002-1.jpg"), replacing: false))
    }

    func testOverwriteStillReplacesItsOwnLoggedExport() {
        let wanted = file("IMG_0003.jpg")
        let stray = file("IMG_0003-1.jpg")
        let logged: Set<String> = [ExportRecipe.pathKey(wanted)]
        let onDisk: Set<URL> = [wanted, stray]
        let isLogged: (URL) -> Bool = { logged.contains(ExportRecipe.pathKey($0)) }
        XCTAssertEqual(ExportRecipe.placement(for: wanted, policy: .overwrite,
                                              claimedThisRun: { _ in false },
                                              existsOnDisk: { onDisk.contains($0) },
                                              isLumenExport: isLogged),
                       .write(wanted, replacing: true))
        // A second frame wanting the same name this run steps past the stray file too.
        XCTAssertEqual(ExportRecipe.placement(for: wanted, policy: .overwrite,
                                              claimedThisRun: { $0 == wanted },
                                              existsOnDisk: { onDisk.contains($0) },
                                              isLumenExport: isLogged),
                       .write(file("IMG_0003-2.jpg"), replacing: false))
    }

    func testPathKeyFoldsCaseAndNormalisation() {
        XCTAssertEqual(ExportRecipe.pathKey(URL(fileURLWithPath: "/a/./Caf\u{E9}.JPG")),
                       ExportRecipe.pathKey(URL(fileURLWithPath: "/a/cafe\u{301}.jpg")))
    }
}
