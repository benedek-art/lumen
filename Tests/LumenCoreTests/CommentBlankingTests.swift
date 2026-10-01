import XCTest

/// The instrument behind every source-scanning test, tested itself. Each case here is
/// one the naive copies got wrong (or a property the scans silently depend on), so a
/// regression in `blankingComments(in:)` goes red here rather than turning some other
/// suite's absence assertion into one that cannot fail.
final class CommentBlankingTests: XCTestCase {

    /// The shape of the naive stripper this replaced, kept ONLY so the cases below can
    /// show the difference they pin — it is not used by any scan.
    private func naive(_ source: String) -> String {
        var out = ""
        var i = source.startIndex
        var block = false
        while i < source.endIndex {
            let rest = source[i...]
            if block {
                if rest.hasPrefix("*/") { block = false; i = source.index(i, offsetBy: 2) }
                else { i = source.index(after: i) }
                continue
            }
            if rest.hasPrefix("/*") { block = true; i = source.index(i, offsetBy: 2); continue }
            if rest.hasPrefix("//") {
                while i < source.endIndex, source[i] != "\n" { i = source.index(after: i) }
                continue
            }
            out.append(source[i]); i = source.index(after: i)
        }
        return out
    }

    /// Same length, same newlines, and every changed Character became a space.
    private func assertOffsetsSurvive(_ raw: String, _ out: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let a = Array(raw), b = Array(out)
        XCTAssertEqual(a.count, b.count, "stripping changed the length", file: file, line: line)
        guard a.count == b.count else { return }
        // One report, at the first offending offset, rather than one per character.
        if let k = a.indices.first(where: { a[$0] != b[$0] && (b[$0] != " " || a[$0].isNewline) }) {
            XCTFail("offset \(k): \(a[k]) became \(b[k]); only a non-newline may become a space",
                    file: file, line: line)
        }
    }

    func testAURLInAStringIsCodeAndTheTrailingCommentIsBlanked() {
        let raw = "let u = URL(string: \"https://example.com/x\")! // the feed\nlet after = 1\n"
        let out = blankingComments(in: raw)
        XCTAssertTrue(out.contains("URL(string: \"https://example.com/x\")!"))
        XCTAssertFalse(out.contains("the feed"))
        XCTAssertTrue(out.contains("let after = 1"))
        assertOffsetsSurvive(raw, out)
        // The defect being retired: the naive walk cuts the literal at `//`.
        XCTAssertFalse(naive(raw).contains("example.com"))
    }

    func testAQuoteInsideACommentDoesNotOpenAString() {
        let raw = "// don't \"quote\" me\nlet path = \"a//b\" /* c \" d */ + x\n"
        let out = blankingComments(in: raw)
        XCTAssertTrue(out.contains("let path = \"a//b\""))
        XCTAssertTrue(out.contains("+ x"))
        XCTAssertFalse(out.contains("quote"))
        XCTAssertFalse(out.contains(" c "))
        assertOffsetsSurvive(raw, out)
    }

    func testBlockCommentsNestAndKeepTheirLines() {
        let raw = "a /* one /* two */ still\ncomment */ b\n"
        let out = blankingComments(in: raw)
        XCTAssertEqual(out, "a " + String(repeating: " ", count: 22) + "\n"
                       + String(repeating: " ", count: 10) + " b\n")
        assertOffsetsSurvive(raw, out)
    }

    func testMultiLineRawAndInterpolatedLiteralsAreCopiedThrough() {
        let raw = """
            let k = \"\"\"
                return x; // shader text, not a comment
                \"\"\"
            let r = #"raw "quoted" // kept"# // gone
            let s = "a \\(f("//", g /* inner */)) b // kept too" // gone
            let e = "esc \\" // still inside" // gone

            """
        let out = blankingComments(in: raw)
        XCTAssertTrue(out.contains("return x; // shader text, not a comment"))
        XCTAssertTrue(out.contains(##"#"raw "quoted" // kept"#"##))
        XCTAssertTrue(out.contains(#"f("//", g "# + String(repeating: " ", count: 11)
                                   + #")) b // kept too""#),
                      "interpolation is code: its literal is kept, its comment blanked")
        XCTAssertTrue(out.contains(#""esc \" // still inside""#))
        XCTAssertFalse(out.contains("gone"))
        XCTAssertFalse(out.contains("inner"))
        assertOffsetsSurvive(raw, out)
    }

    func testAnUnterminatedQuoteStopsAtItsLine() {
        let raw = "let bad = \"open\n// real comment\nlet ok = 2\n"
        let out = blankingComments(in: raw)
        XCTAssertFalse(out.contains("real comment"))
        XCTAssertTrue(out.contains("let ok = 2"))
        assertOffsetsSurvive(raw, out)
    }

    /// The App target's copy must be this one: targets cannot share a source file, and a
    /// copy that drifted would quietly reintroduce exactly what this file retires.
    func testTheAppTargetCopyIsIdentical() throws {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let core = try String(contentsOf: here.appendingPathComponent("CommentBlanking.swift"),
                              encoding: .utf8)
        let app = try String(contentsOf: here.deletingLastPathComponent()
            .appendingPathComponent("LumenAppTests/CommentBlanking.swift"), encoding: .utf8)
        XCTAssertEqual(core, app)
    }

    /// No test file may grow a private stripper again. A file that blanks comments for
    /// a scan calls the shared one; this names any string-blind walk that reappears.
    func testNoTestFileCarriesItsOwnStringBlindStripper() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent()
        let fm = FileManager.default
        var offenders: [String] = []
        for target in ["LumenCoreTests", "LumenAppTests", "LumenPipelineTests"] {
            let dir = tests.appendingPathComponent(target)
            guard let walk = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walk where url.pathExtension == "swift" {
                if url.lastPathComponent == "CommentBlanking.swift"
                    || url.lastPathComponent == "CommentBlankingTests.swift" { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                // The naive walk's signature: it opens a block comment on `/*` and has
                // no branch for a quote anywhere near it.
                if text.contains("rest.hasPrefix(\"/*\") {") && text.contains("rest.hasPrefix(\"//\")")
                    && !text.contains("\"\\\"\"") {
                    offenders.append("\(target)/\(url.lastPathComponent)")
                }
            }
        }
        XCTAssertEqual(offenders, [], "use blankingComments(in:) instead")
    }
}
