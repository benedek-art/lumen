#if os(macOS)
import Foundation
import XCTest
import LumenCore
@testable import LumenApp

final class AuditSidecarScalingTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-sidecar-scaling-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        CatalogService.forgetSiblings()
        addTeardownBlock {
            CatalogService.forgetSiblings()
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func isRawName(_ name: String) -> Bool {
        PhotoFormats.raw.contains(URL(fileURLWithPath: name).pathExtension.lowercased())
    }

    func testLargeDirectoryClassifiesEachNameOnceAndQueriesDoNotRevisitNames() {
        for count in [100, 1_000, 20_000] {
            let names = (0..<count).map { "frame_\($0).NEF" }
            var classifications = 0
            let start = Date()
            let index = CatalogService.RawSiblingIndex(names: names) { name in
                classifications += 1
                return self.isRawName(name)
            }
            XCTAssertEqual(classifications, count)
            for name in names {
                let photo = URL(fileURLWithPath: "/synthetic-only/" + name)
                // Several sidecar reads per registration, as on the production path.
                for _ in 0..<4 { XCTAssertTrue(index.siblings(of: photo).isEmpty) }
            }
            XCTAssertEqual(classifications, count, "Lookups must never revisit a directory listing")
            print("Sidecar index RAWs=\(count) lookups=\(count * 4) classifications=\(classifications) seconds=\(Date().timeIntervalSince(start))")
        }
    }

    func testIndexPreservesOriginalResolverDecisionsIncludingCaseAndDuplicates() {
        let names = ["a.NEF", "A.dNg", "a.JPG", "a.xmp", "a.NEF.xmp", "a.nef",
                     "b.ARW", "B.CR3", "b.DNG", "c.DNG", "d.NEF", "d.jpeg",
                     "several.dots.NEF", "Several.Dots.dng", "Ångström.NEF", "ångström.DNG",
                     "unrelated.txt", "without-extension"]
        let index = CatalogService.RawSiblingIndex(names: names, isRawName: isRawName)
        for name in names + ["absent.NEF", "b.RAF", "c.JPG"] {
            let photo = URL(fileURLWithPath: "/synthetic-only/" + name)
            let expected = SidecarNaming.rawSiblingExtensions(of: photo, amongNames: names, isRawName: isRawName)
            XCTAssertEqual(index.siblings(of: photo), expected, name)
            XCTAssertEqual(SidecarNaming.url(for: photo, isRaw: isRawName(name), rawSiblingExtensions: index.siblings(of: photo)),
                           SidecarNaming.url(for: photo, isRaw: isRawName(name), rawSiblingExtensions: expected), name)
        }
    }

    func testSameBasenamesInSeparateDirectoriesNeverBecomeSiblings() throws {
        let root = try scratch()
        let day1 = root.appendingPathComponent("day1"), day2 = root.appendingPathComponent("day2")
        try FileManager.default.createDirectory(at: day1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: day2, withIntermediateDirectories: true)
        let nef = day1.appendingPathComponent("frame.NEF"), dng = day2.appendingPathComponent("frame.DNG")
        try Data([1]).write(to: nef); try Data([2]).write(to: dng)
        XCTAssertEqual(CatalogService.sidecarURL(for: nef), day1.appendingPathComponent("frame.xmp"))
        XCTAssertEqual(CatalogService.sidecarURL(for: dng), day2.appendingPathComponent("frame.xmp"))
        let service = try CatalogService(directory: root.appendingPathComponent("catalog"))
        defer { service.close() }
        let rows = service.registerAndLoad(folder: root, files: [nef, dng])
        XCTAssertEqual(rows.count, 2)
        XCTAssertNotEqual(rows[nef]?.catalogID, rows[dng]?.catalogID)
    }

    func testSubsetScanStillSeesUnselectedSiblingAndRescanRefreshesIndex() throws {
        let root = try scratch()
        let photos = root.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let dng = photos.appendingPathComponent("frame.DNG"), nef = photos.appendingPathComponent("frame.NEF")
        try Data([1]).write(to: dng)
        let service = try CatalogService(directory: root.appendingPathComponent("catalog"))
        defer { service.close() }
        _ = service.registerAndLoad(folder: photos, files: [dng], completeListing: false)
        XCTAssertEqual(CatalogService.sidecarURL(for: dng), photos.appendingPathComponent("frame.xmp"))
        try Data([2]).write(to: nef)
        _ = service.registerAndLoad(folder: photos, files: [dng], completeListing: false)
        XCTAssertEqual(CatalogService.sidecarURL(for: dng), dng.appendingPathExtension("xmp"),
                       "Selection is not a directory listing; an unselected native RAW still owns the bare Adobe path")
        try FileManager.default.removeItem(at: nef)
        _ = service.registerAndLoad(folder: photos, files: [dng], completeListing: false)
        XCTAssertEqual(CatalogService.sidecarURL(for: dng), photos.appendingPathComponent("frame.xmp"))
    }

    func testLargeFolderRegistrationRetainsAllRowsAndIndependentRawPairs() throws {
        let root = try scratch()
        let photos = root.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let files = (0..<1_000).map { photos.appendingPathComponent("frame_\($0).NEF") }
        for file in files { try Data([1]).write(to: file) }
        let converted = photos.appendingPathComponent("frame_500.DNG")
        try Data([2]).write(to: converted)
        let service = try CatalogService(directory: root.appendingPathComponent("catalog"))
        defer { service.close() }
        let start = Date()
        let rows = service.registerAndLoad(folder: photos, files: files + [converted])
        print("Sidecar full registration synthetic RAWs=\(rows.count) seconds=\(Date().timeIntervalSince(start))")
        XCTAssertEqual(rows.count, 1_001)
        XCTAssertEqual(Set(rows.values.compactMap(\.catalogID)).count, 1_001)
        XCTAssertEqual(CatalogService.sidecarURL(for: files[500]), photos.appendingPathComponent("frame_500.xmp"))
        XCTAssertEqual(CatalogService.sidecarURL(for: converted), converted.appendingPathExtension("xmp"))
        XCTAssertEqual(CatalogService.sidecarURL(for: files[501]), photos.appendingPathComponent("frame_501.xmp"))
    }
}
#endif
