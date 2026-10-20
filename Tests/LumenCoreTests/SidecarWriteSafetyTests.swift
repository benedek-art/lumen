// SidecarWriteSafetyTests.swift
// A sidecar write must change what it states and nothing else — not a recipe the read
// never reached, not a rating spelled as a real number, not a field a newer build
// wrote, and a keyword it removes must stay removed.

import XCTest
@testable import LumenCore

final class SidecarWriteSafetyTests: XCTestCase {

    // MARK: - Damage above the first field

    /// A raw `<` in the root's attributes is fatal to XMLParser before any field is
    /// reached, so `parse` reports "no fields" (nil) — and the flush's `parsedCleanly`
    /// interlock, which only runs on a non-nil parse, never fired. `XMPMerge` works on
    /// the text, so it spliced into the document regardless and stripped every
    /// `lumen:` element the read never saw.
    private let damagedAboveFirstField = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Smith < Sons XMP 1.0">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""
        xmlns:xmp="http://ns.adobe.com/xap/1.0/"
        xmlns:dc="http://purl.org/dc/elements/1.1/"
        xmlns:lumen="http://lumenapp.dev/xmp/1.0/">
       <xmp:Rating>4</xmp:Rating>
       <dc:subject><rdf:Bag><rdf:li>harbour</rdf:li></rdf:Bag></dc:subject>
       <lumen:pipelineVersion>3</lumen:pipelineVersion>
       <lumen:recipe>{"exposure":1.5}</lumen:recipe>
       <lumen:strokes>AAAA</lumen:strokes>
      </rdf:Description>
     </rdf:RDF>
    </x:xmpmeta>
    """

    func testADocumentDamagedAboveItsFirstFieldIsNotSplicedInto() {
        // `parse`'s nil contract is pinned elsewhere (garbage is "no sidecar"); the
        // refusal has to come from the writer.
        XCTAssertNil(XMPSidecar.parse(damagedAboveFirstField))
        XCTAssertNil(XMPSidecar.update(damagedAboveFirstField, with: SidecarContent(rating: 2)),
                     "a rating write deleted the recipe and strokes of a damaged sidecar")
        var keyword = SidecarContent()
        keyword.keywordEdit = SidecarKeywordEdit(added: ["fjord"])
        XCTAssertNil(XMPSidecar.update(damagedAboveFirstField, with: keyword),
                     "a keyword write replaced the bag of a damaged sidecar")
        // An unescaped `&` there: Darwin's parser stops dead (nil), libxml2 may read
        // on with an error. Either way the document is not whole and is not written.
        let ampersand = damagedAboveFirstField
            .replacingOccurrences(of: "Smith < Sons", with: "Smith & Sons")
        XCTAssertNotEqual(XMPSidecar.parse(ampersand)?.parsedCleanly, true)
        XCTAssertNil(XMPSidecar.update(ampersand, with: SidecarContent(rating: 2)))
    }

    /// The same damage further down was already refused through `parsedCleanly`; the
    /// writer refusing it too keeps the two cases one rule.
    func testADocumentDamagedBelowItsFirstFieldIsNotSplicedIntoEither() throws {
        let doc = damagedAboveFirstField
            .replacingOccurrences(of: "Smith < Sons", with: "Smith Sons")
            .replacingOccurrences(of: "<lumen:strokes>AAAA</lumen:strokes>",
                                  with: "<lumen:strokes>A <A</lumen:strokes>")
        XCTAssertEqual(XMPSidecar.parse(doc)?.parsedCleanly, false)
        XCTAssertNil(XMPSidecar.update(doc, with: SidecarContent(rating: 2)))
    }

    /// Control: a whole document — Lumen's own, or a foreign one with no Lumen fields
    /// at all, which `parse` also reports as nil — is still writable.
    func testAWholeDocumentIsStillWritable() throws {
        let own = XMPSidecar.serialize(SidecarContent(rating: 4, recipeJSON: "{}"))
        let merged = try XCTUnwrap(XMPSidecar.update(own, with: SidecarContent(rating: 2)))
        XCTAssertEqual(XMPSidecar.parse(merged)?.rating, 2)
        let foreign = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Smith &amp; Sons XMP 1.0">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:tiff="http://ns.adobe.com/tiff/1.0/"
            tiff:Make="Nikon"/>
         </rdf:RDF>
        </x:xmpmeta>
        """
        XCTAssertNil(XMPSidecar.parse(foreign))
        let written = try XCTUnwrap(XMPSidecar.update(foreign, with: SidecarContent(rating: 2)))
        XCTAssertEqual(XMPSidecar.parse(written)?.rating, 2)
        XCTAssertTrue(written.contains("tiff:Make=\"Nikon\""))
    }

    // MARK: - Real-valued ratings

    /// XMP types `xmp:Rating` as a Closed Choice of Real; "4.0" is a legal spelling.
    func testARealValuedRatingIsReadAndSurvivesAKeywordWrite() throws {
        let doc = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
         <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/"
           xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
           xmp:Rating="4.0" crs:Exposure2012="+0.35"/>
        </rdf:RDF></x:xmpmeta>
        """
        let fresh = try XCTUnwrap(XMPSidecar.parse(doc))
        XCTAssertEqual(fresh.rating, 4)
        var queued = SidecarContent()
        queued.keywordEdit = SidecarKeywordEdit(added: ["fjord"])
        let merged = try XCTUnwrap(XMPSidecar.update(doc, with:
            XMPSidecar.reseed(queued, fields: [.keywords], onto: fresh)))
        XCTAssertEqual(XMPSidecar.parse(merged)?.rating, 4)
        XCTAssertFalse(merged.contains("<xmp:Rating>0</xmp:Rating>"),
                       "a keyword write overwrote four stars with zero")
        XCTAssertTrue(merged.contains("crs:Exposure2012=\"+0.35\""))

        let rejected = try XCTUnwrap(XMPSidecar.parse(
            doc.replacingOccurrences(of: "\"4.0\"", with: "\"-1.0\"")))
        XCTAssertEqual(rejected.flag, .reject)
        XCTAssertEqual(rejected.rating, 0)
        XCTAssertEqual(XMPSidecar.parse(
            doc.replacingOccurrences(of: "\"4.0\"", with: "\"9.0\""))?.rating, 5)
        XCTAssertEqual(XMPSidecar.parse(
            doc.replacingOccurrences(of: "\"4.0\"", with: "\"nan\""))?.rating, 0)
    }

    // MARK: - A newer build's lumen: fields

    func testANewerBuildsUnknownLumenFieldsSurviveARating() throws {
        let c = SidecarContent(rating: 3, pipelineVersion: 99, recipeJSON: "{}")
        var doc = XMPSidecar.serialize(c)
        doc = doc.replacingOccurrences(of: "   <lumen:recipe>",
            with: "   <lumen:snapshots>keep-me</lumen:snapshots>\n   <lumen:recipe>")
        doc = doc.replacingOccurrences(of: "<rdf:Description rdf:about=\"\"",
            with: "<rdf:Description rdf:about=\"\" lumen:newThing=\"x\"")
        let fresh = try XCTUnwrap(XMPSidecar.parse(doc))
        XCTAssertTrue(fresh.parsedCleanly)
        let fields = XMPSidecar.writableFields([.rating], documentVersion: fresh.pipelineVersion)
        let out = XMPSidecar.reseed(SidecarContent(rating: 5), fields: fields, onto: fresh)
        let merged = try XCTUnwrap(XMPSidecar.update(doc, with: out))
        XCTAssertEqual(XMPSidecar.parse(merged)?.rating, 5)
        XCTAssertEqual(XMPSidecar.parse(merged)?.recipeJSON, "{}")
        XCTAssertTrue(merged.contains("<lumen:snapshots>keep-me</lumen:snapshots>"),
                      "an older build deleted a newer build's element")
        XCTAssertTrue(merged.contains("lumen:newThing=\"x\""),
                      "an older build deleted a newer build's attribute")
        XCTAssertEqual(XMPSidecar.update(merged, with: out), merged)
    }

    /// Narrowing ownership must not stop a KNOWN field from being cleared.
    func testAKnownLumenFieldIsStillClearedWhenNotRestated() throws {
        let doc = XMPSidecar.serialize(SidecarContent(rating: 3, flag: .pick, recipeJSON: "{}",
                                                      strokesPayload: "AAAA"))
        let merged = try XCTUnwrap(XMPSidecar.update(doc, with: SidecarContent(rating: 3)))
        XCTAssertFalse(merged.contains("lumen:flag"))
        XCTAssertFalse(merged.contains("lumen:recipe>"))
        XCTAssertFalse(merged.contains("lumen:strokes"))
        XCTAssertEqual(merged.components(separatedBy: "<lumen:pipelineVersion>").count - 1, 1)
    }

    // MARK: - Removing a keyword whose sidecar spelling is not its leaf

    /// "A>B" in a sidecar imports as the hierarchy A > B, leaf "B"; removing it sends
    /// "B", which has to take "A>B" out of the bag or the next scan re-imports it.
    func testRemovingAHierarchicalKeywordTakesItsSidecarSpellingWithIt() {
        let edit = SidecarKeywordEdit.removal(before: ["A > B", "dawn"], after: ["dawn"],
                                              synonyms: { _ in [] })
        XCTAssertEqual(edit.apply(to: ["A>B", "dawn"]), ["dawn"])
        XCTAssertEqual(edit.apply(to: ["A > B", "dawn"]), ["dawn"])
    }

    /// Lightroom exports synonyms into `dc:subject`; "NYC" imports as "New York".
    func testRemovingAKeywordTakesItsSynonymsOutOfTheSidecar() {
        let edit = SidecarKeywordEdit.removal(
            before: ["New York", "dawn"], after: ["dawn"],
            synonyms: { $0 == "New York" ? ["NYC"] : [] })
        XCTAssertEqual(edit.apply(to: ["NYC", "dawn"]), ["dawn"])
    }

    /// A leaf still on the photo through another branch is not removed from the bag.
    func testALeafStillPresentElsewhereIsKept() {
        let edit = SidecarKeywordEdit.removal(before: ["A > B", "X > B"], after: ["X > B"],
                                              synonyms: { _ in [] })
        XCTAssertEqual(edit.apply(to: ["B"]), ["B"])
    }
}

#if canImport(SQLite3)

/// The same, end to end through the catalog: import, remove, re-scan.
final class SidecarKeywordRemovalCatalogTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-kw-removal-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testARemovedKeywordImportedFromASidecarSpellingStaysRemoved() throws {
        let store = try CatalogStore(path: directory.appendingPathComponent("lumen.db").path,
                                     cachePath: directory.appendingPathComponent("cache.db").path)
        let folderID = try store.registerFolder(path: "/Volumes/Shoots/nyc")
        let file = ScannedFile(filename: "DSCF0001.RAF", fileSize: 50_000_000,
                               fileMTime: 1_700_000_000, ext: "raf")
        _ = try store.scan(folderID: folderID, files: [file], at: CatalogStore.now())
        let id = try XCTUnwrap(try store.photo(folderID: folderID, filename: file.filename)?.id)
        _ = try store.addKeyword("New York", photoIDs: [])
        XCTAssertTrue(try store.addSynonym("NYC", toKeyword: "New York"))

        for (word, shown) in [("A>B", "A > B"), ("NYC", "New York")] {
            var sidecar = [word]
            func scan() throws {
                for w in SidecarKeywordImport.missing(
                    fromCatalog: try store.keywords(photoID: id).map(KeywordPath.leaf),
                    sidecar: sidecar) {
                    _ = try store.addKeyword(w, photoIDs: [id])
                }
            }
            try scan()
            XCTAssertEqual(try store.keywords(photoID: id), [shown])
            // As CatalogService.removeKeyword builds the delta.
            let before = try store.keywords(photoID: id)
            try store.removeKeyword(shown, photoIDs: [id])
            let after = try store.keywords(photoID: id)
            sidecar = try SidecarKeywordEdit.removal(before: before, after: after,
                                                     synonyms: store.synonyms(ofKeyword:))
                .apply(to: sidecar)
            XCTAssertEqual(sidecar, [], word)
            try scan()
            XCTAssertEqual(try store.keywords(photoID: id), [], "\(word) came back")
        }
    }
}

#endif
