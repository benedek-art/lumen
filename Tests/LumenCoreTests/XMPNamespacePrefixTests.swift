// XMPNamespacePrefixTests.swift
// XMP names a property by namespace URI, not by prefix. Photoshop 7/CS/CS2 and
// Bridge 1.x bound http://ns.adobe.com/xap/1.0/ to `xap:`, so a legacy sidecar says
// `xap:Rating="4"` where a modern one says `xmp:Rating="4"` — the same property.
//
// The reader matched the literal `xmp:` names, so such a sidecar parsed to "no fields"
// and its rating and label never reached the catalog. The writer then left `xap:Rating`
// in place, bound the URI a second time as `xmlns:xmp`, and spliced `<xmp:Rating>` beside
// it: one Description asserting the same property twice, which XMP Toolkit rejects and
// every other reader resolves differently.

import XCTest
@testable import LumenCore

final class XMPNamespacePrefixTests: XCTestCase {

    private let attributeForm = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about="" xmlns:xap="http://ns.adobe.com/xap/1.0/" xap:Rating="4" xap:Label="Red" xap:CreateDate="2004-05-01T10:00:00"/>
    </rdf:RDF></x:xmpmeta>
    """

    private let elementForm = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about="" xmlns:xap="http://ns.adobe.com/xap/1.0/">
     <xap:Rating>3</xap:Rating>
     <xap:Label>Blue</xap:Label>
    </rdf:Description>
    </rdf:RDF></x:xmpmeta>
    """

    private func count(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    func testLegacyPrefixAttributeFormIsRead() throws {
        let parsed = try XCTUnwrap(XMPSidecar.parse(attributeForm))
        XCTAssertEqual(parsed.rating, 4)
        XCTAssertEqual(parsed.label, "Red")
    }

    func testLegacyPrefixElementFormIsRead() throws {
        let parsed = try XCTUnwrap(XMPSidecar.parse(elementForm))
        XCTAssertEqual(parsed.rating, 3)
        XCTAssertEqual(parsed.label, "Blue")
    }

    func testLegacyPrefixAttributeFormIsReplacedNotDuplicated() throws {
        var content = try XCTUnwrap(XMPSidecar.parse(attributeForm))
        content.rating = 2
        let out = try XCTUnwrap(XMPSidecar.update(attributeForm, with: content))

        XCTAssertFalse(out.contains("xap:Rating=\"4\""), "rating stated twice under one URI")
        XCTAssertFalse(out.contains("xap:Label=\"Red\""), "label stated twice under one URI")
        XCTAssertEqual(count("Rating>2</", in: out), 1)
        // The existing binding is reused, not doubled.
        XCTAssertFalse(out.contains("xmlns:xmp="), "second prefix bound to the same URI")
        XCTAssertFalse(out.contains("<xmp:"), "element written under an unbound prefix")
        XCTAssertEqual(count("\"http://ns.adobe.com/xap/1.0/\"", in: out), 1)
        // Somebody else's property in the same namespace is untouched.
        XCTAssertTrue(out.contains("xap:CreateDate=\"2004-05-01T10:00:00\""))

        let reread = try XCTUnwrap(XMPSidecar.parse(out))
        XCTAssertEqual(reread.rating, 2)
        XCTAssertEqual(reread.label, "Red")
        XCTAssertTrue(reread.parsedCleanly)
    }

    func testLegacyPrefixElementFormIsReplacedNotDuplicated() throws {
        let out = try XCTUnwrap(XMPSidecar.update(elementForm, with: SidecarContent(rating: 5)))
        XCTAssertFalse(out.contains("<xap:Rating>3"))
        XCTAssertFalse(out.contains("<xap:Label>"), "label not stated by this write")
        XCTAssertEqual(count("Rating>", in: out), 2, "exactly one open and one close tag")
        XCTAssertFalse(out.contains("xmlns:xmp="))
        let reread = try XCTUnwrap(XMPSidecar.parse(out))
        XCTAssertEqual(reread.rating, 5)
        XCTAssertNil(reread.label)
        XCTAssertTrue(reread.parsedCleanly)
        // A second write is a no-op on the bytes: the merge is idempotent here too.
        XCTAssertEqual(XMPSidecar.update(out, with: SidecarContent(rating: 5)), out)
    }

    /// The binding can live on an ancestor rather than on the Description itself.
    func testLegacyPrefixBoundOnRootIsReadAndReused() throws {
        let doc = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:xap="http://ns.adobe.com/xap/1.0/">
        <rdf:Description rdf:about="" xap:Rating="1"/>
        </rdf:RDF></x:xmpmeta>
        """
        XCTAssertEqual(XMPSidecar.parse(doc)?.rating, 1)
        let out = try XCTUnwrap(XMPSidecar.update(doc, with: SidecarContent(rating: 4)))
        XCTAssertFalse(out.contains("xap:Rating=\"1\""))
        XCTAssertFalse(out.contains("xmlns:xmp="))
        XCTAssertEqual(XMPSidecar.parse(out)?.rating, 4)
    }

    /// `xap:` means nothing by itself: a prefix that is NOT bound to the XMP basic URI
    /// is somebody else's namespace and its `Rating` is not ours to read or remove.
    func testSameLocalNameInAnotherNamespaceIsLeftAlone() throws {
        let doc = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:xap="urn:example:other" xap:Rating="9"/>
        </rdf:RDF></x:xmpmeta>
        """
        XCTAssertNil(XMPSidecar.parse(doc))
        let out = try XCTUnwrap(XMPSidecar.update(doc, with: SidecarContent(rating: 2)))
        XCTAssertTrue(out.contains("xap:Rating=\"9\""))
        XCTAssertTrue(out.contains("<xmp:Rating>2</xmp:Rating>"))
        XCTAssertTrue(out.contains("xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\""))
    }
}
