// CullingEncodingTests.swift
// Every on-disk spelling of a cull decision, pinned against the code that wrote it before.
//
// LumenApp used to carry its own `PhotoFlag` (`rejected = -1, none = 0, picked = 1`) and
// its own six-case `ColorLabel: Int` (`none = 0, red, yellow, green, blue, purple`), and
// `CatalogService` translated: `coreFlag`/`appFlag` to the catalog, `sidecarFlag` /
// `appFlag(SidecarFlag)` to the sidecar, and `appLabel`/`coreLabel` for labels, where the
// sidecar and the catalog both stored `displayName.lowercased()`. Those enums and
// functions are gone; one `PhotoFlag` and one `ColorLabel` remain, with unlabelled as nil.
//
// That is only safe if nothing a photographer already has on disk reads differently. The
// tables below are copied from the deleted code as LITERALS — not derived from the types
// under test — so a renamed case or a re-spelled raw value fails here instead of quietly
// re-keying a catalog's picks or a sidecar's labels.

import XCTest
@testable import LumenCore

final class CullingEncodingTests: XCTestCase {

    // MARK: - The flag

    /// (old app case, its Int raw value — which the catalog column stores — and the
    /// `lumen:flag` word `CatalogService.sidecarFlag` wrote for it.)
    private static let oldFlags: [(name: String, catalog: Int, sidecar: String)] = [
        ("rejected", -1, "reject"),
        ("none", 0, "none"),
        ("picked", 1, "pick"),
    ]

    func testEveryOldCatalogFlagValueDecodesToTheSameDecision() {
        let expected: [Int: PhotoFlag] = [-1: .reject, 0: .unflagged, 1: .pick]
        for old in Self.oldFlags {
            let flag = PhotoFlag(rawValue: old.catalog)
            XCTAssertEqual(flag, expected[old.catalog], "catalog value \(old.catalog)")
            XCTAssertEqual(flag?.rawValue, old.catalog,
                           "\(old.name) must write back the integer it was read from")
        }
        XCTAssertEqual(PhotoFlag.allCases.count, Self.oldFlags.count,
                       "no flag case may appear that the catalog has no integer for")
    }

    func testTheSidecarFlagWordRoundTripsForEveryDecision() {
        for old in Self.oldFlags {
            guard let flag = PhotoFlag(rawValue: old.catalog) else {
                return XCTFail("catalog value \(old.catalog) no longer decodes")
            }
            let written = SidecarFlag(flag)
            XCTAssertEqual(written.rawValue, old.sidecar,
                           "\(old.name) must write the same `lumen:flag` word as before")
            XCTAssertEqual(PhotoFlag(written), flag, "\(old.name) must read back as itself")
            guard let read = SidecarFlag(rawValue: old.sidecar) else {
                return XCTFail("`\(old.sidecar)` is no longer a sidecar flag word")
            }
            XCTAssertEqual(PhotoFlag(read), flag,
                           "a sidecar an older build wrote must read the same decision")
        }
    }

    // MARK: - The label

    /// (old app case, its Int raw value — the old sort key — and the name the catalog
    /// column and `xmp:Label` stored: `displayName.lowercased()`, nil for `.none`.)
    private static let oldLabels: [(name: String, slot: Int, stored: String?)] = [
        ("none", 0, nil),
        ("red", 1, "red"),
        ("yellow", 2, "yellow"),
        ("green", 3, "green"),
        ("blue", 4, "blue"),
        ("purple", 5, "purple"),
    ]

    func testEveryOldStoredLabelNameReadsAndWritesBackByteIdentically() {
        for old in Self.oldLabels {
            let label = ColorLabel(storedName: old.stored)
            XCTAssertEqual(label?.rawValue, old.stored,
                           "\(old.name): the name written back must be the name stored")
            // `slot` was the old app enum's raw value, which is what the memory-path
            // label sort compared. The new sort keys on `metaSlot` with nil as 0.
            XCTAssertEqual(label?.metaSlot ?? 0, old.slot,
                           "\(old.name) must keep its place in the label sort")
        }
        XCTAssertEqual(ColorLabel.allCases.count, Self.oldLabels.count - 1,
                       "five colours; unlabelled is nil, not a sixth case")
    }

    /// `appLabel` lowercased before it compared, because a sidecar another tool wrote
    /// may capitalise. And anything that is not one of the five — including the old
    /// enum's own "none" — was unlabelled to the grid.
    func testForeignAndUnknownSidecarSpellingsReadAsTheOldMappingDid() {
        XCTAssertEqual(ColorLabel(storedName: "Green"), .green)
        XCTAssertEqual(ColorLabel(storedName: "PURPLE"), .purple)
        XCTAssertNil(ColorLabel(storedName: nil))
        XCTAssertNil(ColorLabel(storedName: ""))
        XCTAssertNil(ColorLabel(storedName: "none"))
        XCTAssertNil(ColorLabel(storedName: "None"))
        XCTAssertNil(ColorLabel(storedName: "To Print"))
        XCTAssertNil(ColorLabel(storedName: "orange"))
    }

    func testTheDisplayNamesAreTheOldAppSpellings() {
        XCTAssertEqual(ColorLabel.allCases.map(\.displayName),
                       ["Red", "Yellow", "Green", "Blue", "Purple"])
        XCTAssertEqual([PhotoFlag.pick, .reject, .unflagged].map(\.displayName),
                       ["Picked", "Rejected", "Unflagged"])
    }

    // MARK: - Through the real sidecar bytes

    /// The whole trip a cull decision makes to disk and back: written by
    /// `XMPSidecar.serialize`, parsed by `XMPSidecar.parse`, decoded by the functions
    /// that replaced `appFlag`/`appLabel`. And the bytes in between carry exactly the
    /// words an older build wrote.
    func testEveryDecisionSurvivesASidecarRoundTripInTheOldSpelling() throws {
        for flag in PhotoFlag.allCases {
            for label in [nil] + ColorLabel.allCases.map(Optional.some) {
                let content = SidecarContent(rating: 3, flag: SidecarFlag(flag),
                                             label: label?.rawValue)
                let xml = XMPSidecar.serialize(content)
                let old = try XCTUnwrap(Self.oldFlags.first { $0.catalog == flag.rawValue })
                if flag == .unflagged {
                    XCTAssertFalse(xml.contains("<lumen:flag>"),
                                   "an unflagged photo writes no flag, as before")
                } else {
                    XCTAssertTrue(xml.contains("<lumen:flag>\(old.sidecar)</lumen:flag>"),
                                  "\(flag) must write `\(old.sidecar)`")
                }
                if let label {
                    XCTAssertTrue(xml.contains("<xmp:Label>\(label.rawValue)</xmp:Label>"))
                } else {
                    XCTAssertFalse(xml.contains("<xmp:Label>"))
                }

                let parsed = try XCTUnwrap(XMPSidecar.parse(xml), "\(flag) \(String(describing: label))")
                XCTAssertEqual(PhotoFlag(parsed.flag), flag)
                XCTAssertEqual(ColorLabel(storedName: parsed.label), label)
            }
        }
    }

    // MARK: - Through the real catalog column

    #if canImport(SQLite3)
    func testEveryDecisionSurvivesTheCatalogColumnInTheOldSpelling() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-culling-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(path: directory.appendingPathComponent("lumen.db").path,
                                     cachePath: directory.appendingPathComponent("cache.db").path)
        let folderID = try store.registerFolder(path: "/Volumes/Shoots/culling")
        let file = ScannedFile(filename: "DSC0001.ARW", fileSize: 40_000_000,
                               fileMTime: 1_700_000_000, ext: "arw")
        _ = try store.scan(folderID: folderID, files: [file], at: CatalogStore.now())
        let id = try XCTUnwrap(store.photo(folderID: folderID, filename: file.filename)?.id)

        for flag in PhotoFlag.allCases {
            for old in Self.oldLabels {
                let label = ColorLabel(storedName: old.stored)
                try store.setFlag(flag, photoID: id)
                try store.setLabel(label, photoID: id)
                let row = try XCTUnwrap(store.photo(folderID: folderID, filename: file.filename))
                XCTAssertEqual(row.flag, flag)
                XCTAssertEqual(row.label, old.stored,
                               "the column must hold the name an older build stored")
                XCTAssertEqual(ColorLabel(storedName: row.label), label)
            }
        }
    }
    #endif
}
