// XMPEscapeRoundTripTests.swift
// Free text written into a sidecar must read back as the same text, or as `sanitize` of
// it when XML 1.0 cannot carry a character at all. Two cases used to break this:
// - a raw CR, which every XML reader normalizes to LF (XML 1.0 §2.11);
// - U+FFFE and U+FFFF, which are not XML Chars (§2.2), so the document stopped
//   parsing at that element and a recipe after it was lost.

import XCTest
@testable import LumenCore

final class XMPEscapeRoundTripTests: XCTestCase {

    /// What XML 1.0 can carry: tab, LF, CR and every scalar from U+0020 up, minus the
    /// two non-characters. The other C0 controls have no legal form, not even escaped.
    private func sanitize(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A, 0x0D: out.append(scalar)
            case 0xFFFE, 0xFFFF: continue
            case let v where v >= 0x20: out.append(scalar)
            default: continue
            }
        }
        return String(out)
    }

    /// Writes `s` into the label, a keyword and the write stamp, reads the document
    /// back, and checks each field. The keyword is wrapped in letters because the
    /// reader trims a keyword's surrounding whitespace on purpose.
    private func assertRoundTrips(_ s: String, file: StaticString = #filePath,
                                  line: UInt = #line) {
        let keyword = "k" + s + "k"
        var content = SidecarContent(rating: 3, label: s, writeStamp: s)
        content.keywords = [keyword]
        let xml = XMPSidecar.serialize(content)
        guard let read = XMPSidecar.parse(xml) else {
            return XCTFail("no fields read back for \(s.debugDescription)",
                           file: file, line: line)
        }
        XCTAssertTrue(read.parsedCleanly, "the document for \(s.debugDescription) "
                          + "did not parse cleanly", file: file, line: line)
        XCTAssertEqual(read.label, sanitize(s), file: file, line: line)
        XCTAssertEqual(read.writeStamp, sanitize(s), file: file, line: line)
        XCTAssertEqual(read.keywords, [sanitize(keyword)], file: file, line: line)
    }

    func testEachAwkwardCharacterRoundTrips() {
        for s in ["a\rb", "a\r\nb", "x\u{FFFE}y", "x\u{FFFF}y", "&\u{0301}", "]]>",
                  "<\"&>", "\u{0085}\u{2028}", "\u{1F600}\t\n", "a\u{01}b\u{1F}c"] {
            assertRoundTrips(s)
        }
    }

    /// The recipe is the element a bad character costs most in: it carries the mask
    /// names as JSON, and JSONEncoder writes U+FFFE as it is.
    func testANonCharacterInAMaskNameDoesNotCostTheRecipe() throws {
        var recipe = Recipe()
        recipe.develop.tone.exposure = 0.5
        recipe.masks = [Mask(id: "m1", name: "m\u{FFFE}")]
        let json = try CanonicalJSON.canonicalRecipeJSON(recipe)
        let read = try XCTUnwrap(XMPSidecar.parse(XMPSidecar.serialize(
            SidecarContent(recipeJSON: json, strokesPayload: "QUJD"))))
        XCTAssertTrue(read.parsedCleanly)
        XCTAssertEqual(read.strokesPayload, "QUJD", "the elements after the recipe were lost")
        let decoded = try CanonicalJSON.decodeRecipe(
            from: Data(try XCTUnwrap(read.recipeJSON).utf8))
        XCTAssertEqual(decoded.masks.first?.name, "m")
        XCTAssertEqual(decoded.develop.tone.exposure, 0.5)
    }

    /// 500 seeded strings over a pool of the characters above plus plain ones.
    func testRandomStringsRoundTrip() {
        let pool: [Unicode.Scalar] = [
            "a", "Z", "0", " ", "\t", "\n", "\r", "&", "<", ">", "\"", "'", "]",
            "\u{00}", "\u{08}", "\u{1F}", "\u{7F}", "\u{0085}", "\u{0301}", "\u{2028}",
            "\u{FEFF}", "\u{FFFD}", "\u{FFFE}", "\u{FFFF}", "\u{1F600}", "\u{10FFFF}",
        ]
        var state: UInt64 = 0x5EED_1234_ABCD_0001
        func next() -> Int {
            // Knuth's MMIX LCG; the high bits are the well-mixed ones.
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(truncatingIfNeeded: state >> 33)
        }
        for _ in 0..<500 {
            var view = String.UnicodeScalarView()
            for _ in 0..<(next() % 13) { view.append(pool[next() % pool.count]) }
            assertRoundTrips(String(view))
        }
    }
}
