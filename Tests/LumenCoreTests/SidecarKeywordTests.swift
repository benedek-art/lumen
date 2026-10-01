// SidecarKeywordTests.swift
// Keywords travel in the sidecar's `dc:subject`, in both directions.
//
// docs/15 §15.1 lists keywords among what a lost catalog recovers from sidecars, and
// §15.5 names `dc:subject` as a field Lumen writes. Neither was true: keywords lived
// only in the catalog, and a Lightroom-keyworded folder arrived with none of them.
//
// The bag is shared with every other tool that keywords a photograph, so the rules
// here are about not taking anything from it that Lumen did not put there.

import XCTest
@testable import LumenCore

final class SidecarKeywordTests: XCTestCase {

    /// Lightroom's shape: attribute-form simple properties, `dc:subject` as a Bag in
    /// its own Description, and a namespace binding on that Description only.
    private let lightroom = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""
        xmlns:xmp="http://ns.adobe.com/xap/1.0/"
        xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
        xmp:Rating="3"
        crs:Exposure2012="+0.35">
      </rdf:Description>
      <rdf:Description rdf:about=""
        xmlns:dc="http://purl.org/dc/elements/1.1/">
       <dc:subject>
        <rdf:Bag>
         <rdf:li>harbour</rdf:li>
         <rdf:li>dawn</rdf:li>
        </rdf:Bag>
       </dc:subject>
      </rdf:Description>
     </rdf:RDF>
    </x:xmpmeta>
    """

    // MARK: - Reading

    func testLightroomKeywordsAreRead() throws {
        let content = try XCTUnwrap(XMPSidecar.parse(lightroom))
        XCTAssertEqual(content.keywords, ["harbour", "dawn"])
        XCTAssertEqual(content.rating, 3, "reading the bag cost the rating")
    }

    /// A sidecar that says nothing BUT keywords is still a sidecar with something in
    /// it: `parse` returns nil for "no fields found", and nil is how the scan learns
    /// there is nothing to recover.
    func testASidecarWithOnlyKeywordsParses() throws {
        let only = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF
          xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
         <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:subject><rdf:Bag><rdf:li>  fog </rdf:li><rdf:li></rdf:li></rdf:Bag></dc:subject>
         </rdf:Description></rdf:RDF></x:xmpmeta>
        """
        let content = try XCTUnwrap(XMPSidecar.parse(only))
        XCTAssertEqual(content.keywords, ["fog"], "whitespace kept or an empty item read")
    }

    func testNoSubjectIsNilNotEmpty() throws {
        let content = try XCTUnwrap(XMPSidecar.parse(XMPSidecar.serialize(
            SidecarContent(rating: 2))))
        XCTAssertNil(content.keywords)
    }

    // MARK: - Writing

    /// The flush, end to end: parse the file, reseed the queued edit onto it, splice.
    func testAKeywordEditKeepsTheOtherToolsKeywordsAndEverythingElse() throws {
        var queued = SidecarContent(rating: 3)
        queued.keywordEdit = SidecarKeywordEdit(added: ["Iceland"], removed: ["dawn"])
        let fresh = try XCTUnwrap(XMPSidecar.parse(lightroom))
        let content = XMPSidecar.reseed(queued, fields: [.keywords], onto: fresh)
        let merged = try XCTUnwrap(XMPSidecar.update(lightroom, with: content))

        let after = try XCTUnwrap(XMPSidecar.parse(merged))
        XCTAssertEqual(after.keywords, ["harbour", "Iceland"],
                       "the removal did not land, the addition did not, or the other "
                       + "tool's keyword went")
        XCTAssertEqual(after.rating, 3)
        XCTAssertTrue(merged.contains("crs:Exposure2012=\"+0.35\""),
                      "a keyword write damaged the develop settings beside it")
        XCTAssertEqual(merged.components(separatedBy: "<dc:subject>").count - 1, 1,
                       "the document now asserts two keyword bags")

        // Idempotent: the same edit again writes the same bytes.
        let again = try XCTUnwrap(XMPSidecar.update(merged, with: XMPSidecar.reseed(
            queued, fields: [.keywords], onto: after)))
        XCTAssertEqual(again, merged)
    }

    /// The bag belongs to whoever wrote it until Lumen has something to say about
    /// keywords. A rating keystroke on a Lightroom sidecar must not rewrite it — not
    /// even into an equivalent spelling.
    func testAWriteThatStatesNoKeywordsLeavesTheBagByteForByte() throws {
        let fresh = try XCTUnwrap(XMPSidecar.parse(lightroom))
        XCTAssertNotNil(fresh.keywords, "precondition: the copy carries the bag")
        let content = XMPSidecar.reseed(SidecarContent(rating: 5), fields: [.rating],
                                        onto: fresh)
        let merged = try XCTUnwrap(XMPSidecar.update(lightroom, with: content))
        let start = try XCTUnwrap(lightroom.range(of: "   <dc:subject>")).lowerBound
        let end = try XCTUnwrap(lightroom.range(of: "</dc:subject>")).upperBound
        let bag = String(lightroom[start..<end])
        XCTAssertTrue(merged.contains(bag), "a rating write rewrote the keyword bag:\n\(merged)")
    }

    /// A keyword another tool added between the keystroke and the flush survives,
    /// because the delta is applied to the file as it is at flush time.
    func testAKeywordAddedElsewhereDuringTheDebounceSurvives() throws {
        var queued = SidecarContent()
        queued.keywords = ["harbour", "dawn"]   // the stale copy taken at the keystroke
        queued.keywordEdit = SidecarKeywordEdit(added: ["boats"])
        var fresh = try XCTUnwrap(XMPSidecar.parse(lightroom))
        fresh.keywords = ["harbour", "dawn", "gulls"]
        let out = XMPSidecar.reseed(queued, fields: [.keywords], onto: fresh)
        XCTAssertEqual(out.keywords, ["harbour", "dawn", "gulls", "boats"])
    }

    /// Removing the last keyword removes the bag; Lumen writes no empty element.
    func testRemovingTheLastKeywordRemovesTheBag() throws {
        var queued = SidecarContent()
        queued.keywordEdit = SidecarKeywordEdit(removed: ["harbour", "dawn"])
        let fresh = try XCTUnwrap(XMPSidecar.parse(lightroom))
        let content = XMPSidecar.reseed(queued, fields: [.keywords], onto: fresh)
        let merged = try XCTUnwrap(XMPSidecar.update(lightroom, with: content))
        XCTAssertFalse(merged.contains("dc:subject"), merged)
        XCTAssertNil(XMPSidecar.parse(merged)?.keywords)
    }

    /// A foreign document that never bound `dc:` gets the binding, or the spliced bag
    /// is unreadable to every parser — Lumen's own on the next launch included.
    func testTheDublinCoreNamespaceIsDeclaredWhenMissing() throws {
        let bare = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF
          xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
         <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/"
           xmp:Rating="1"/>
        </rdf:RDF></x:xmpmeta>
        """
        var queued = SidecarContent(rating: 1)
        queued.keywordEdit = SidecarKeywordEdit(added: ["moss & stone"])
        let fresh = try XCTUnwrap(XMPSidecar.parse(bare))
        let content = XMPSidecar.reseed(queued, fields: [.keywords], onto: fresh)
        let merged = try XCTUnwrap(XMPSidecar.update(bare, with: content))
        XCTAssertTrue(merged.contains("xmlns:dc=\"http://purl.org/dc/elements/1.1/\""))
        let after = try XCTUnwrap(XMPSidecar.parse(merged))
        XCTAssertTrue(after.parsedCleanly, merged)
        XCTAssertEqual(after.keywords, ["moss & stone"], "an ampersand was not escaped")
    }

    func testAFreshSidecarCarriesItsKeywords() throws {
        var content = SidecarContent(rating: 4)
        content.keywords = ["fjord", "ferry"]
        let text = XMPSidecar.serialize(content)
        let back = try XCTUnwrap(XMPSidecar.parse(text))
        XCTAssertTrue(back.parsedCleanly)
        XCTAssertEqual(back.keywords, ["fjord", "ferry"])
    }

    // MARK: - The edit

    func testEditsComposeInTimeOrder() {
        var edit = SidecarKeywordEdit(added: ["a"])
        edit = edit.then(SidecarKeywordEdit(removed: ["a"]))
        XCTAssertEqual(edit.added, [])
        XCTAssertEqual(edit.removed, ["a"], "add then remove is a removal")
        edit = edit.then(SidecarKeywordEdit(added: ["a"]))
        XCTAssertEqual(edit.added, ["a"], "remove then add is an addition")
        XCTAssertEqual(edit.removed, [])
        XCTAssertEqual(edit.apply(to: ["b", "a", " b "]), ["b", "a"],
                       "duplicates were not folded or the existing order was lost")
    }

    // MARK: - The scan's import

    func testTheScanImportsOnlyWhatTheCatalogLacks() {
        XCTAssertEqual(SidecarKeywordImport.missing(fromCatalog: ["dawn"],
                                                    sidecar: ["harbour", "dawn", " harbour"]),
                       ["harbour"])
        XCTAssertEqual(SidecarKeywordImport.missing(fromCatalog: ["dawn"], sidecar: nil), [])
    }
}
