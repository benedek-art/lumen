#if os(macOS)
import Foundation
import XCTest
import LumenCore
@testable import LumenApp

/// Keywords through the real service: a Lightroom-keyworded sidecar is read into the
/// catalog on open, a keyword typed in Lumen reaches the sidecar beside the other
/// tool's, and a catalog rebuilt from nothing but the folder gets them all back.
final class SidecarKeywordRoundTripTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-keyword-sidecar-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testKeywordsSurviveLosingTheCatalog() async throws {
        let root = try scratch()
        let photos = root.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let nef = photos.appendingPathComponent("frame.NEF")
        try Data([1, 2, 3]).write(to: nef)
        let lightroom = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF
          xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
         <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/"
           xmlns:dc="http://purl.org/dc/elements/1.1/" xmp:Rating="2">
          <dc:subject><rdf:Bag><rdf:li>harbour</rdf:li></rdf:Bag></dc:subject>
         </rdf:Description></rdf:RDF></x:xmpmeta>
        """
        let sidecar = photos.appendingPathComponent("frame.xmp")
        try Data(lightroom.utf8).write(to: sidecar)
        CatalogService.forgetSiblings()

        let first = try CatalogService(directory: root.appendingPathComponent("catalog"))
        let id = try XCTUnwrap(first.registerAndLoad(folder: photos, files: [nef])[nef]?.catalogID)
        let imported = await first.keywords(photoID: id)
        XCTAssertEqual(imported, ["harbour"], "the sidecar's keyword was not read on open")

        await first.addKeyword("gulls", targets: [(id: id, url: nef)])
        first.close()   // flushes the sidecar queue

        let written = try XCTUnwrap(XMPSidecar.parse(try Data(contentsOf: sidecar)))
        XCTAssertEqual(written.keywords, ["harbour", "gulls"],
                       "the Lumen keyword did not reach the sidecar, or Lightroom's left it")
        XCTAssertEqual(written.rating, 2)

        // The catalog is gone; the folder is all there is.
        let rebuilt = try CatalogService(directory: root.appendingPathComponent("fresh"))
        defer { rebuilt.close() }
        let again = try XCTUnwrap(rebuilt.registerAndLoad(folder: photos, files: [nef])[nef]?.catalogID)
        let recovered = await rebuilt.keywords(photoID: again)
        XCTAssertEqual(Set(recovered), ["harbour", "gulls"])
    }

    func testRemovingAKeywordRemovesItFromTheSidecar() async throws {
        let root = try scratch()
        let jpg = root.appendingPathComponent("frame.JPG")
        try Data([9, 9, 9]).write(to: jpg)
        CatalogService.forgetSiblings()
        let service = try CatalogService(directory: root.appendingPathComponent("catalog"))
        let id = try XCTUnwrap(service.registerAndLoad(folder: root, files: [jpg])[jpg]?.catalogID)
        await service.addKeyword("fog", targets: [(id: id, url: jpg)])
        await service.addKeyword("pier", targets: [(id: id, url: jpg)])
        await service.removeKeyword("fog", targets: [(id: id, url: jpg)])
        service.close()
        let written = try XCTUnwrap(XMPSidecar.parse(
            try Data(contentsOf: CatalogService.sidecarURL(for: jpg))))
        XCTAssertEqual(written.keywords, ["pier"])
    }
    func testRemovingOneBranchKeepsSharedLeaf() async throws {
        let root = try scratch()
        let photo = root.appendingPathComponent("shared.JPG")
        try Data([1]).write(to: photo)
        let service = try CatalogService(directory: root.appendingPathComponent("catalog"))
        let id = try XCTUnwrap(service.registerAndLoad(folder: root, files: [photo])[photo]?.catalogID)
        await service.addKeyword("People > Alex", targets: [(id, photo)])
        await service.addKeyword("Places > Alex", targets: [(id, photo)])
        await service.removeKeyword("People > Alex", targets: [(id, photo)])
        service.close()
        let content = try XCTUnwrap(XMPSidecar.parse(Data(contentsOf: CatalogService.sidecarURL(for: photo))))
        XCTAssertEqual(content.keywords, ["Alex"])
    }

    func testFailedRemovalReplaysBeforeImportWithoutLosingForeignAddition() async throws {
        let root = try scratch()
        let photo = root.appendingPathComponent("remove.JPG")
        try Data([1]).write(to: photo)
        let catalog = root.appendingPathComponent("catalog")
        let first = try CatalogService(directory: catalog)
        let id = try XCTUnwrap(first.registerAndLoad(folder: root, files: [photo])[photo]?.catalogID)
        await first.addKeyword("Dawn", targets: [(id, photo)])
        first.flushSidecars()
        let path = CatalogService.sidecarURL(for: photo)
        let original = try Data(contentsOf: path)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        await first.removeKeyword("Dawn", targets: [(id, photo)])
        XCTAssertEqual(first.close(), ["remove.JPG.xmp"])
        try FileManager.default.removeItem(at: path)
        var foreign = try XCTUnwrap(XMPSidecar.parse(original))
        foreign.keywords = ["Dawn", "External"]
        try Data(XMPSidecar.serialize(foreign).utf8).write(to: path)
        let second = try CatalogService(directory: catalog)
        _ = second.registerAndLoad(folder: root, files: [photo])
        let recovered = await second.keywords(photoID: id)
        XCTAssertEqual(recovered, ["External"])
        second.close()
        XCTAssertEqual(XMPSidecar.parse(try Data(contentsOf: path))?.keywords, ["External"])
    }

    func testFailedNestedAdditionReplaysAsLeaf() async throws {
        let root = try scratch()
        let photo = root.appendingPathComponent("nested.JPG")
        try Data([1]).write(to: photo)
        let path = photo.appendingPathExtension("xmp")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let catalog = root.appendingPathComponent("catalog")
        let first = try CatalogService(directory: catalog)
        let id = try XCTUnwrap(first.registerAndLoad(folder: root, files: [photo])[photo]?.catalogID)
        await first.addKeyword("Places > Iceland", targets: [(id, photo)])
        XCTAssertEqual(first.close(), ["nested.JPG.xmp"])
        try FileManager.default.removeItem(at: path)
        let second = try CatalogService(directory: catalog)
        second.close()
        XCTAssertEqual(XMPSidecar.parse(try Data(contentsOf: path))?.keywords, ["Iceland"])
    }

    private func ownedByNEF() -> SidecarContent {
        var content = SidecarContent()
        content.sourceExtension = "nef"
        return content
    }

    func testRefusedDocumentsRemainOwedAndRecoverWhenRepaired() async throws {
        for bytes in [Data("<broken>".utf8), Data([0xff, 0xfe, 0x41, 0x00]),
                      Data(XMPSidecar.serialize(ownedByNEF()).utf8)] {
            let root = try scratch()
            let photo = root.appendingPathComponent("refused.JPG")
            try Data([1]).write(to: photo)
            let catalog = root.appendingPathComponent("catalog")
            let service = try CatalogService(directory: catalog)
            let id = try XCTUnwrap(service.registerAndLoad(folder: root, files: [photo])[photo]?.catalogID)
            let path = CatalogService.sidecarURL(for: photo)
            try bytes.write(to: path)
            await service.addKeyword("Kept", targets: [(id, photo)])
            var notices: [String] = []
            service.onFailure = { notices.append($0) }
            service.flushSidecars()
            service.flushSidecars()
            XCTAssertEqual(try Data(contentsOf: path), bytes)
            XCTAssertEqual(notices.count, 1)
            XCTAssertEqual(service.close(), ["refused.JPG.xmp"])
            let second = try CatalogService(directory: catalog)
            XCTAssertNotNil(second.unsavedSidecarNotice)
            try Data(XMPSidecar.serialize(SidecarContent()).utf8).write(to: path)
            second.close()
            XCTAssertEqual(XMPSidecar.parse(try Data(contentsOf: path))?.keywords, ["Kept"])
        }
    }

    func testReadFailureNeverReplacesExistingDocumentAndRetriesFreshBytes() async throws {
        let root = try scratch()
        let photo = root.appendingPathComponent("read.JPG")
        try Data([1]).write(to: photo)
        let service = try CatalogService(directory: root.appendingPathComponent("catalog"))
        let id = try XCTUnwrap(service.registerAndLoad(folder: root, files: [photo])[photo]?.catalogID)
        let path = CatalogService.sidecarURL(for: photo)
        var original = SidecarContent()
        original.keywords = ["Foreign"]
        try Data(XMPSidecar.serialize(original).utf8).write(to: path)
        let bytes = try Data(contentsOf: path)
        await service.addKeyword("Lumen", targets: [(id, photo)])
        service.sidecarDataReader = { _ in throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError) }
        service.flushSidecars()
        XCTAssertEqual(try Data(contentsOf: path), bytes)
        service.sidecarDataReader = { try Data(contentsOf: $0) }
        service.flushSidecars()
        XCTAssertEqual(Set(XMPSidecar.parse(try Data(contentsOf: path))?.keywords ?? []), ["Foreign", "Lumen"])
        XCTAssertEqual(service.close(), [])
    }

    func testOutlivedRecoveryDeltaCannotReverseNewerCatalogMembership() async throws {
        let root = try scratch()
        let photo = root.appendingPathComponent("stale.JPG")
        try Data([1]).write(to: photo)
        let catalog = root.appendingPathComponent("catalog")
        let first = try CatalogService(directory: catalog)
        let id = try XCTUnwrap(first.registerAndLoad(folder: root, files: [photo])[photo]?.catalogID)
        await first.addKeyword("Kept", targets: [(id, photo)])
        first.close()
        // The stale removal reached disk before a later re-add was durably queued.
        // The newer catalog membership must restore this now-missing flat leaf.
        try Data(XMPSidecar.serialize(SidecarContent()).utf8)
            .write(to: CatalogService.sidecarURL(for: photo))
        let store = try CatalogStore(path: catalog.appendingPathComponent("lumen.db").path,
            cachePath: catalog.appendingPathComponent("cache.db").path)
        let stale = UnsavedSidecarRecord(photoPath: photo.path, photoID: id, stated: [.keywords],
            keywordEdit: SidecarKeywordEdit(added: ["Gone"], removed: ["Kept"]))
        try store.setMetaValue(UnsavedSidecarRecord.metaKey, UnsavedSidecarRecord.encode([stale]))
        store.close()
        let second = try CatalogService(directory: catalog)
        _ = second.registerAndLoad(folder: root, files: [photo])
        let memberships = await second.keywords(photoID: id)
        XCTAssertEqual(memberships, ["Kept"])
        second.close()
        XCTAssertEqual(XMPSidecar.parse(try Data(contentsOf: CatalogService.sidecarURL(for: photo)))?.keywords, ["Kept"])
    }

    func testFailedFlushRetainsOlderFieldsWhenNewerEditArrivesDuringRead() async throws {
        let root = try scratch()
        let photo = root.appendingPathComponent("overlap.JPG")
        try Data([1]).write(to: photo)
        let service = try CatalogService(directory: root.appendingPathComponent("catalog"))
        let id = try XCTUnwrap(service.registerAndLoad(folder: root, files: [photo])[photo]?.catalogID)
        let path = CatalogService.sidecarURL(for: photo)
        try Data(XMPSidecar.serialize(SidecarContent()).utf8).write(to: path)
        await service.addKeyword("OlderKeyword", targets: [(id, photo)])
        var older = PhotoItem(id: photo)
        older.catalogID = id
        older.rating = 2
        service.saveCullingState(older, labelChanged: false)
        _ = service.registerAndLoad(folder: root, files: [photo])
        service.sidecarDataReader = { _ in
            // The production queue normally serializes these operations, but a flush
            // can also run at an explicit barrier. Force the newer queue entry to land
            // before the old batch reports its failure.
            var item = PhotoItem(id: photo)
            item.catalogID = id
            item.rating = 5
            service.saveCullingState(item, labelChanged: false)
            _ = service.registerAndLoad(folder: root, files: [photo])
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        }
        service.flushSidecars()
        service.sidecarDataReader = { try Data(contentsOf: $0) }
        service.flushSidecars()
        service.close()
        let content = try XCTUnwrap(XMPSidecar.parse(Data(contentsOf: path)))
        XCTAssertEqual(content.rating, 5)
        XCTAssertEqual(content.keywords, ["OlderKeyword"])
    }

    func testExportKeywordSnapshotUsesLeavesAndPropagatesReadFailures() async throws {
        let root = try scratch()
        let photo = root.appendingPathComponent("snapshot.JPG")
        try Data([1]).write(to: photo)
        let service = try CatalogService(directory: root.appendingPathComponent("catalog"))
        let id = try XCTUnwrap(service.registerAndLoad(folder: root, files: [photo])[photo]?.catalogID)
        await service.addKeyword("Places > Alex", targets: [(id, photo)])
        await service.addKeyword("People > Alex", targets: [(id, photo)])
        let words = try await service.exportKeywords(photoID: id)
        XCTAssertEqual(words, ["Alex"])
        do {
            _ = try await service.exportKeywords(photoID: Int64.max)
            XCTFail("a missing catalog photo must refuse the metadata snapshot")
        } catch {}
        service.close()
        do {
            _ = try await service.exportKeywords(photoID: id)
            XCTFail("an unavailable catalog must refuse the metadata snapshot")
        } catch {
            // An export must not silently substitute an empty list on failure.
        }
    }

}
#endif
