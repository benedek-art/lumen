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
}
#endif
