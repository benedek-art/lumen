// RejectMarkerTests.swift
// Lightroom's reject survives being opened in Lumen.
//
// `xmp:Rating` = −1 is the reserved reject marker: Lightroom, Bridge and everything that
// follows them write it, and it is the only thing the file says about a rejected frame.
// Lumen clamped it to 0 on the way in — so the photograph arrived unrated and unflagged
// — and then wrote `<xmp:Rating>0</xmp:Rating>` back over the stripped original on the
// first culling keystroke. The marker was gone from the file, and nothing had told the
// photographer that a shoot he had already culled elsewhere had been un-culled here.

import XCTest
@testable import LumenCore

final class RejectMarkerTests: XCTestCase {

    private func sidecar(rating: String, flag: String? = nil) -> String {
        let flagLine = flag.map { "   <lumen:flag>\($0)</lumen:flag>\n" } ?? ""
        return """
        <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:lumen="http://lumen.app/ns/1.0/">
           <xmp:Rating>\(rating)</xmp:Rating>
        \(flagLine)  </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }

    /// The read half: a reject arrives as a reject.
    func testAMinusOneRatingIsReadAsAReject() throws {
        let parsed = try XCTUnwrap(XMPSidecar.parse(sidecar(rating: "-1")))
        XCTAssertEqual(parsed.flag, .reject,
                       "-1 is XMP's reserved reject marker; clamping it to 0 lost the "
                       + "only thing the file said about this photograph")
        XCTAssertEqual(parsed.rating, 0, "a reject is not also a zero-star rating")
    }

    /// End to end, and the property that actually matters: the decision survives.
    ///
    /// It survives on Lumen's own axis, not by writing −1 back.
    /// `SidecarAndIngestTests.testFlagAndRatingSurviveEachOther` pins the reason —
    /// `lumen:flag` exists so a photograph can be four stars AND rejected, which
    /// Lightroom's convention cannot express because it spends the rating field on the
    /// reject. An earlier version of this fix did write −1 back and destroyed the stars;
    /// the existing contract caught it.
    func testARejectSurvivesAReadAndAWrite() throws {
        let parsed = try XCTUnwrap(XMPSidecar.parse(sidecar(rating: "-1")))
        let written = XMPSidecar.fieldLines(parsed)
        XCTAssertTrue(written.contains("<lumen:flag>reject</lumen:flag>"),
                      "the reject must survive the round trip somewhere — it is the only "
                      + "thing the incoming file said about this photograph")
        XCTAssertFalse(written.contains("<xmp:Rating>-1</xmp:Rating>"),
                       "and not in the rating field, which belongs to the stars")
    }

    /// A rejected frame that also has stars keeps both — the contract the −1
    /// convention cannot honour, and the reason Lumen does not adopt it on write.
    func testARejectedFrameKeepsItsStars() {
        var content = SidecarContent()
        content.flag = .reject
        content.rating = 4
        let written = XMPSidecar.fieldLines(content)
        XCTAssertTrue(written.contains("<xmp:Rating>4</xmp:Rating>"))
        XCTAssertTrue(written.contains("<lumen:flag>reject</lumen:flag>"))
    }

    /// This build's own word outranks another tool's convention, and field order in the
    /// document must not decide which one wins.
    func testAnExplicitLumenFlagIsNotOverwrittenByTheMarker() throws {
        let parsed = try XCTUnwrap(XMPSidecar.parse(sidecar(rating: "-1", flag: "pick")))
        XCTAssertEqual(parsed.flag, .pick)
    }

    /// Ordinary ratings are untouched, and a hostile one still cannot reach the grid.
    func testOrdinaryRatingsAreUnchanged() throws {
        XCTAssertEqual(try XCTUnwrap(XMPSidecar.parse(sidecar(rating: "3"))).rating, 3)
        XCTAssertEqual(try XCTUnwrap(XMPSidecar.parse(sidecar(rating: "0"))).rating, 0)
        XCTAssertEqual(try XCTUnwrap(XMPSidecar.parse(sidecar(rating: "999"))).rating, 5,
                       "a foreign file must not be able to draw 999 stars")
        var three = SidecarContent()
        three.rating = 3
        XCTAssertTrue(XMPSidecar.fieldLines(three).contains("<xmp:Rating>3</xmp:Rating>"))
    }
}
