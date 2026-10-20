// What `.cube` files a LUT collection actually contains, as opposed to what a parser
// written against the spec expects it to contain.
//
// The Iridas/Resolve `.cube` format is a twenty-year-old de-facto standard with no
// conformance suite, so the files in circulation vary in two ways that have nothing to
// do with the colour data:
//
//   · LINE ENDINGS. Most LUT packs were authored on Windows and end their lines `\r\n`.
//     A parser that splits on `"\n"` and trims `.whitespaces` — space and tab, never a
//     carriage return — leaves a `\r` glued to the last field of every line. `Float(
//     "0.000000\r")` is nil, so the file is rejected wholesale, and even the header
//     fails: `Int("2\r")` is nil too.
//   · FIELD SEPARATORS. Tab-separated triples are common and are just as valid as
//     space-separated ones. A split on a literal `" "` sees one field, not three.
//
// Both are silent: `fromCubeFile` returns nil, which any caller reads as "malformed",
// which is what a user is told about a file every other grading tool opens.
//
// The other half of this file is the half that keeps the fix honest. Widening what a
// parser ACCEPTS is one edit away from widening it into credulity, so the rejections
// are pinned here as tightly as the acceptances: a 1-D cube, a degenerate size, a
// truncated triple, a short file. If a later "be more forgiving" change makes any of
// those parse, that is a cube built out of the wrong numbers rather than a rejection,
// and this file is what says so.
//
// NOTE ON SCOPE: this is the PARSER. The feature — storage by content hash, the two
// render taps, Amount, the render identity and the wire formats — is
// `CreativeLUTTests`, and the GPU half is `LumenPipelineTests/CreativeLUTParityTests`.

import XCTest
@testable import LumenCore

final class CubeParserTests: XCTestCase {

    // MARK: - Fixtures

    /// A well-formed 2×2×2 cube that inverts red and passes green and blue through.
    /// Small enough to write out by hand, and far enough from the identity that a
    /// parser returning `LUT3D.identity()` fails rather than passes.
    ///
    /// Sample order is the format's: red varies fastest, then green, then blue.
    private static let redInvertingBody = [
        "1.000000 0.000000 0.000000",
        "0.000000 0.000000 0.000000",
        "1.000000 1.000000 0.000000",
        "0.000000 1.000000 0.000000",
        "1.000000 0.000000 1.000000",
        "0.000000 0.000000 1.000000",
        "1.000000 1.000000 1.000000",
        "0.000000 1.000000 1.000000",
    ]

    private static let redInvertingLines =
        ["TITLE \"red inverted\"", "LUT_3D_SIZE 2"] + redInvertingBody

    /// The same cube as a Unix file — the control.
    private static var lfCube: String { redInvertingLines.joined(separator: "\n") + "\n" }

    /// The same cube as a Windows file. Nothing about the numbers changed.
    private static var crlfCube: String { redInvertingLines.joined(separator: "\r\n") + "\r\n" }

    /// The same cube with tabs between the fields instead of spaces.
    private static var tabCube: String {
        lfCube.replacingOccurrences(of: " 0.", with: "\t0.")
            .replacingOccurrences(of: " 1.", with: "\t1.")
    }

    /// Both at once, which is the common case: a Windows-authored, tab-separated export.
    private static var crlfTabCube: String {
        crlfCube.replacingOccurrences(of: " 0.", with: "\t0.")
            .replacingOccurrences(of: " 1.", with: "\t1.")
    }

    /// Asserts a parsed cube really is the red-inverting one, not merely non-nil.
    private func assertRedInverting(_ lut: LUT3D?,
                                    _ what: String,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) {
        guard let lut else {
            return XCTFail("\(what) was rejected as malformed", file: file, line: line)
        }
        XCTAssertEqual(lut.size, 2, "\(what): wrong cube size", file: file, line: line)
        XCTAssertEqual(lut.sample(RGB(0, 0, 0)).r, 1, accuracy: 1e-5,
                       "\(what): black did not come back with its red inverted",
                       file: file, line: line)
        XCTAssertEqual(lut.sample(RGB(1, 0, 0)).r, 0, accuracy: 1e-5,
                       "\(what): white red did not come back black",
                       file: file, line: line)
        XCTAssertEqual(lut.sample(RGB(0, 1, 0)).g, 1, accuracy: 1e-5,
                       "\(what): green was not passed through",
                       file: file, line: line)
        XCTAssertGreaterThan(lut.maxAbsDifference(LUT3D.identity(size: 2)), 0.5,
                             "\(what): parsed to something indistinguishable from the "
                                 + "identity cube",
                             file: file, line: line)
    }

    // MARK: - The forms that must now be accepted

    /// The control. If this one fails, the fixture is wrong and every other case in the
    /// file is meaningless.
    func testAUnixCubeParses() {
        assertRedInverting(LUT3D.fromCubeFile(Self.lfCube), "a LF cube")
    }

    /// The defect this file exists for. A `\r\n` file is byte-for-byte the same colour
    /// data; the only difference is the line terminator, and the parser used to reject
    /// every one of them.
    func testAWindowsCubeParsesAndParsesToTheSameCube() {
        assertRedInverting(LUT3D.fromCubeFile(Self.crlfCube), "a CRLF cube")
        // Not merely "also parses": the same numbers, sample for sample. A line-ending
        // fix that dropped or shifted a field would still pass the assertions above.
        XCTAssertEqual(LUT3D.fromCubeFile(Self.crlfCube), LUT3D.fromCubeFile(Self.lfCube),
                       "the same cube saved on Windows and on Unix parsed to two "
                           + "different tables")
    }

    /// Classic-Mac line endings cost nothing extra once the split is on newlines rather
    /// than on one chosen newline, and a stray lone `\r` shows up in hand-edited files.
    func testACarriageReturnOnlyCubeParses() {
        let cr = Self.redInvertingLines.joined(separator: "\r") + "\r"
        assertRedInverting(LUT3D.fromCubeFile(cr), "a CR-only cube")
    }

    func testATabSeparatedCubeParses() {
        assertRedInverting(LUT3D.fromCubeFile(Self.tabCube), "a tab-separated cube")
        XCTAssertEqual(LUT3D.fromCubeFile(Self.tabCube), LUT3D.fromCubeFile(Self.lfCube),
                       "tabs and spaces between the same numbers produced two different "
                           + "tables")
    }

    /// The realistic worst case, and the one a Windows grading tool actually writes.
    func testAWindowsTabSeparatedCubeParses() {
        assertRedInverting(LUT3D.fromCubeFile(Self.crlfTabCube),
                           "a CRLF tab-separated cube")
        XCTAssertEqual(LUT3D.fromCubeFile(Self.crlfTabCube), LUT3D.fromCubeFile(Self.lfCube))
    }

    /// The header keywords fail first and fail differently: `LUT_3D_SIZE 2\r` used to
    /// leave `size` at 0 and the file was rejected before a single value was read. Runs
    /// of blank space between the keyword and its argument are equally legal.
    func testHeadersSurviveCarriageReturnsAndRunsOfWhitespace() {
        let spaced = """
        TITLE   "spaced out"
        LUT_3D_SIZE\t2
        DOMAIN_MIN  0.0\t0.0  0.0
        DOMAIN_MAX\t1.0  1.0\t1.0
        """ + "\n" + Self.redInvertingBody.joined(separator: "\n") + "\n"
        assertRedInverting(LUT3D.fromCubeFile(spaced), "a cube with irregular spacing")
        assertRedInverting(
            LUT3D.fromCubeFile(spaced.replacingOccurrences(of: "\n", with: "\r\n")),
            "a CRLF cube with irregular spacing")
    }

    /// Comments and blank lines are part of the format, and stay part of it on Windows.
    func testCommentsAndBlankLinesAreStillSkippedOnWindows() {
        let commented = "# exported by something\r\n\r\n" + Self.crlfCube
        assertRedInverting(LUT3D.fromCubeFile(commented), "a commented CRLF cube")
    }

    /// A non-unit domain is rescaled rather than refused — and the rescale has to still
    /// happen when the header carrying it ends in `\r\n`, or a Windows file would parse
    /// with its domain silently ignored.
    func testANonUnitDomainIsStillHonouredOnAWindowsFile() {
        let lines = ["TITLE \"double domain\"", "LUT_3D_SIZE 2",
                     "DOMAIN_MIN 0.0 0.0 0.0", "DOMAIN_MAX 2.0 2.0 2.0"]
            + Self.redInvertingBody
        guard let scaled = LUT3D.fromCubeFile(lines.joined(separator: "\r\n") + "\r\n") else {
            return XCTFail("a CRLF cube with a non-unit domain was rejected")
        }
        // Full red sits HALFWAY up a domain that runs to 2, so it reads the middle of
        // the table: red half inverted, not fully. On the unit-domain cube it reads the
        // far corner and comes back 0.
        XCTAssertEqual(scaled.sample(RGB(1, 0, 0)).r, 0.5, accuracy: 1e-4,
                       "DOMAIN_MAX was dropped — the carriage return ate the header")
        XCTAssertNotEqual(scaled, LUT3D.fromCubeFile(Self.lfCube),
                          "a doubled domain and a unit domain produced the same table")
    }

    /// The Adobe spec's DOMAIN is an affine map in FRONT of the lattice: knot i of N sits
    /// at DOMAIN_MIN + i/(N−1)·(DOMAIN_MAX − DOMAIN_MIN). The parser used to honour it by
    /// re-baking — building a second N³ table whose unit-lattice knots each held an
    /// interpolated read of the file's table — so every pixel went through two
    /// interpolations. On a smooth look (a 0.6 power with a cross-channel term, domain
    /// −0.25…1.25, size 9) the second one measured 2.7e-3, the better part of an 8-bit
    /// code, and it lands differently on the GPU's trilinear fetch than on the CPU's
    /// tetrahedral one.
    /// `CreativeLUT.swift` promises the user's cube is "never re-baked into a second
    /// table". The lattice must be the file's own numbers, and a read at c must be ONE
    /// interpolation of them at (c − min)/(max − min).
    func testANonUnitDomainIsAppliedInFrontOfTheFilesOwnLatticeNotRebaked() {
        let n = 9
        var rows: [String] = []
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    let r = Double(ri) / Double(n - 1), g = Double(gi) / Double(n - 1)
                    let b = Double(bi) / Double(n - 1)
                    let lift = 0.15 * (r - g) * b
                    rows.append(String(format: "%.6f %.6f %.6f", pow(r, 0.6) + lift,
                                       pow(g, 0.6) - lift, pow(b, 0.6) + 0.1 * r * g))
                }
            }
        }
        let domain = ["DOMAIN_MIN -0.25 -0.25 -0.25", "DOMAIN_MAX 1.25 1.25 1.25"]
        guard let ranged = LUT3D.fromCubeFile((["LUT_3D_SIZE 9"] + domain + rows)
                                                .joined(separator: "\n")),
              let lattice = LUT3D.fromCubeFile((["LUT_3D_SIZE 9"] + rows)
                                                .joined(separator: "\n")) else {
            return XCTFail("a size-9 cube with a −0.25…1.25 domain was rejected")
        }
        XCTAssertTrue(ranged.data == lattice.data,
                      "the file's lattice was replaced by a re-baked second table")

        var worst = 0.0
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        for _ in 0..<4000 {
            let c = RGB(next(), next(), next())
            let direct = lattice.sample(RGB((c.r + 0.25) / 1.5, (c.g + 0.25) / 1.5,
                                            (c.b + 0.25) / 1.5))
            let read = ranged.sample(c)
            worst = max(worst, abs(read.r - direct.r), abs(read.g - direct.g),
                        abs(read.b - direct.b))
        }
        XCTAssertLessThan(worst, 1e-6,
                          "a non-unit-domain cube read \(worst) away from one interpolation "
                              + "of its own lattice — it was interpolated twice")

        // And the writer carries the domain out again, so a round trip is the same cube.
        XCTAssertEqual(LUT3D.fromCubeFile(ranged.cubeFileContents(title: "ranged")), ranged,
                       "the domain was dropped on the way back out to a .cube file")
    }

    /// Resolve's dialect spells the domain differently. `LUT_3D_INPUT_RANGE lo hi` is
    /// Resolve's (and OpenColorIO's resolve_cube baker's) way of writing what the Adobe
    /// 1.0 spec calls `DOMAIN_MIN lo lo lo` / `DOMAIN_MAX hi hi hi`. The parser used to
    /// read the keyword as the first field of a value row, `Float("LUT_3D_INPUT_RANGE")`
    /// was nil, and a file Resolve itself wrote was refused as "not a cube".
    func testResolvesInputRangeKeywordIsReadAsTheDomain() {
        let unit = ["TITLE \"resolve\"", "LUT_3D_SIZE 2", "LUT_3D_INPUT_RANGE 0.0 1.0"]
            + Self.redInvertingBody
        let unitCube = LUT3D.fromCubeFile(unit.joined(separator: "\r\n") + "\r\n")
        assertRedInverting(unitCube, "a Resolve cube with LUT_3D_INPUT_RANGE 0 1")
        XCTAssertEqual(unitCube, LUT3D.fromCubeFile(Self.lfCube),
                       "a unit input range must parse to exactly the unit-domain table")

        // Not merely skipped: a range that runs to 2 is the same rescale DOMAIN_MAX 2 is.
        let doubled = ["LUT_3D_SIZE 2", "LUT_3D_INPUT_RANGE 0.0 2.0"] + Self.redInvertingBody
        let viaDomain = ["LUT_3D_SIZE 2", "DOMAIN_MIN 0 0 0", "DOMAIN_MAX 2 2 2"]
            + Self.redInvertingBody
        guard let ranged = LUT3D.fromCubeFile(doubled.joined(separator: "\n")) else {
            return XCTFail("a Resolve cube with LUT_3D_INPUT_RANGE 0 2 was rejected")
        }
        XCTAssertEqual(ranged.sample(RGB(1, 0, 0)).r, 0.5, accuracy: 1e-4,
                       "LUT_3D_INPUT_RANGE 0 2 was parsed but its range was ignored")
        XCTAssertEqual(ranged, LUT3D.fromCubeFile(viaDomain.joined(separator: "\n")),
                       "the Resolve and Adobe spellings of the same domain disagreed")
    }

    /// The Adobe spec says a reader ignores keywords it does not know, and producers do
    /// write vendor lines into the header. A keyword is a word, so it cannot be mistaken
    /// for a value row, which starts with a number.
    func testAnUnknownHeaderKeywordIsSkippedNotFatal() {
        let lines = ["TITLE \"vendor\"", "LUT_3D_SIZE 2", "LUT_GENERATOR_VERSION 7 beta"]
            + Self.redInvertingBody
        XCTAssertEqual(LUT3D.fromCubeFile(lines.joined(separator: "\n")),
                       LUT3D.fromCubeFile(Self.lfCube),
                       "an unknown header keyword made the whole cube unreadable")
    }

    // MARK: - The forms that must STILL be rejected

    /// The point of the section: the fix widens the separators the parser tolerates, not
    /// its standards for what counts as a cube.
    func testAOneDimensionalCubeIsStillRefusedByName() {
        XCTAssertNil(LUT3D.fromCubeFile("LUT_1D_SIZE 4\n0 0 0\n1 1 1\n"),
                     "a 1-D cube is a different animal and must be refused, not "
                         + "half-read as a 3-D one")
        XCTAssertNil(LUT3D.fromCubeFile("LUT_1D_SIZE 4\r\n0 0 0\r\n1 1 1\r\n"),
                     "a 1-D cube became acceptable once it arrived with CRLF endings")
        XCTAssertNil(LUT3D.fromCubeFile("LUT_1D_SIZE\t4\n0\t0\t0\n1\t1\t1\n"),
                     "a 1-D cube became acceptable once it arrived tab-separated")
    }

    /// The Resolve keywords whose meaning a 3-D-only reader cannot honour are refused by
    /// name rather than skipped: a 1-D shaper's input range belongs to a table this
    /// parser does not read, and the video-range flags change what every sample means,
    /// so ignoring either would render the file wrong instead of refusing it. A
    /// degenerate input range would divide by zero in the domain rescale.
    func testResolveKeywordsThatChangeTheMeaningAreRefused() {
        let body = Self.redInvertingBody.joined(separator: "\n")
        for header in ["LUT_1D_INPUT_RANGE 0.0 1.0", "LUT_IN_VIDEO_RANGE", "LUT_OUT_VIDEO_RANGE",
                       "LUT_3D_INPUT_RANGE 1.0 1.0", "LUT_3D_INPUT_RANGE 1.0 0.0",
                       "LUT_3D_INPUT_RANGE 0.0", "LUT_3D_INPUT_RANGE low high"] {
            XCTAssertNil(LUT3D.fromCubeFile("LUT_3D_SIZE 2\n\(header)\n" + body),
                         "\(header) was accepted")
        }
    }

    /// A one-entry cube has no cell to interpolate across; `LUT3D` traps on `size < 2`,
    /// so this rejection is what stands between a malformed file and a crash.
    func testADegenerateOrOversizedSizeIsStillRejected() {
        let body = "0.0 0.0 0.0\n"
        XCTAssertNil(LUT3D.fromCubeFile("LUT_3D_SIZE 1\n" + body),
                     "LUT_3D_SIZE 1 is not a cube")
        XCTAssertNil(LUT3D.fromCubeFile("LUT_3D_SIZE 1\r\n" + body),
                     "LUT_3D_SIZE 1 became acceptable with CRLF endings")
        XCTAssertNil(LUT3D.fromCubeFile("LUT_3D_SIZE 0\n" + body))
        XCTAssertNil(LUT3D.fromCubeFile("LUT_3D_SIZE -2\n" + body))
        XCTAssertNil(LUT3D.fromCubeFile("LUT_3D_SIZE 4096\n" + body),
                     "a size that would allocate gigabytes must be refused")
        XCTAssertNil(LUT3D.fromCubeFile("LUT_3D_SIZE two\n" + body),
                     "a non-numeric size must be refused, not read as zero")
    }

    /// A short value line is the failure a trimming bug looks like from the outside, so
    /// it has to keep failing for the reason it really fails.
    func testATruncatedTripleIsStillRejected() {
        XCTAssertNil(LUT3D.fromCubeFile("LUT_3D_SIZE 4\n0.1 0.2\n"),
                     "a two-field value line is not a sample")
        XCTAssertNil(LUT3D.fromCubeFile("LUT_3D_SIZE 4\r\n0.1 0.2\r\n"),
                     "a truncated triple became acceptable with CRLF endings")
        XCTAssertNil(LUT3D.fromCubeFile("LUT_3D_SIZE 4\n0.1\t0.2\n"),
                     "a truncated triple became acceptable tab-separated")
        XCTAssertNil(LUT3D.fromCubeFile("LUT_3D_SIZE 2\n" + Self.redInvertingBody
                        .dropLast().joined(separator: "\n") + "\n0.1 0.2\n"),
                     "a cube whose LAST row is truncated must fail on the row, not be "
                         + "padded out to the right count")
    }

    /// Right shape, wrong count — the file is a fragment, and half a cube is not a cube.
    func testAWrongSampleCountIsStillRejected() {
        let short = ["LUT_3D_SIZE 2"] + Self.redInvertingBody.dropLast()
        XCTAssertNil(LUT3D.fromCubeFile(short.joined(separator: "\r\n") + "\r\n"),
                     "seven samples were accepted as a 2×2×2 cube")
        let long = ["LUT_3D_SIZE 2"] + Self.redInvertingBody + ["0.5 0.5 0.5"]
        XCTAssertNil(LUT3D.fromCubeFile(long.joined(separator: "\r\n") + "\r\n"),
                     "nine samples were accepted as a 2×2×2 cube")
    }

    /// Non-numeric junk must not become a field just because whitespace splitting got
    /// looser, and a header-less body must not be read as one.
    func testJunkIsStillRejected() {
        XCTAssertNil(LUT3D.fromCubeFile("not a lut at all"))
        XCTAssertNil(LUT3D.fromCubeFile("not a lut at all\r\n"),
                     "junk became a cube once it had a carriage return on it")
        XCTAssertNil(LUT3D.fromCubeFile("LUT_3D_SIZE 2\r\nred\tgreen\tblue\r\n"),
                     "three whitespace-separated words are not three floats")
        XCTAssertNil(LUT3D.fromCubeFile(Self.redInvertingBody.joined(separator: "\r\n")),
                     "a body with no LUT_3D_SIZE has no declared size to check against")
        XCTAssertNil(LUT3D.fromCubeFile(""))
        XCTAssertNil(LUT3D.fromCubeFile("\r\n\r\n   \t \r\n"),
                     "a file of nothing but whitespace is not a cube")
    }

    /// Swift's `Float("nan")`, `Float("inf")` and `Float("infinity")` all SUCCEED, so a
    /// parser whose only test of a field is "did it parse as a number" lets a corrupt or
    /// badly exported file put NaN or ±∞ into the table. That is not one bad lattice
    /// point: tetrahedral blending adds `(c100 − c000) · f` even at weight zero, and
    /// NaN · 0 is NaN, so every pixel whose cell touches the entry comes out NaN —
    /// through the amount blend, the grain and the encoder — on CPU and in the GPU's
    /// baked cube alike. The domain headers are numbers read the same way, and a
    /// non-finite or zero-width domain poisons every sample of the rescale instead.
    /// Both are refused like any other malformed file.
    func testANonFiniteSampleOrDomainIsRejectedNotInterpolated() {
        let header = "LUT_3D_SIZE 2\n"
        let valid = Self.redInvertingBody.dropLast()
        for bad in ["0 nan 0", "0 0 inf", "0.5 -inf 0.5", "0 0 infinity", "0 NaN 0",
                    "nan 0 0", "inf 0 0", "-nan 1 1"] {
            XCTAssertNil(LUT3D.fromCubeFile(header + (valid + [bad]).joined(separator: "\n")),
                         "the sample row \"\(bad)\" was accepted into the table")
        }
        // A ninth row that happens to START with nan is still a value row, not a vendor
        // keyword to skip: the file has nine samples where it declares eight.
        XCTAssertNil(LUT3D.fromCubeFile(header + (Self.redInvertingBody + ["nan nan nan"])
                        .joined(separator: "\n")),
                     "a trailing nan row was skipped as a keyword instead of refused")
        let body = Self.redInvertingBody.joined(separator: "\n")
        for domain in ["DOMAIN_MIN nan 0 0", "DOMAIN_MAX 1 inf 1", "DOMAIN_MIN -inf 0 0",
                       "DOMAIN_MAX 0 1 1", "DOMAIN_MIN 1 0 0\nDOMAIN_MAX 0.5 1 1",
                       "LUT_3D_INPUT_RANGE -inf inf", "LUT_3D_INPUT_RANGE 0 inf"] {
            XCTAssertNil(LUT3D.fromCubeFile(header + domain + "\n" + body),
                         "the domain \"\(domain)\" was accepted")
        }
        // The control: the same rows, all finite, still parse.
        assertRedInverting(LUT3D.fromCubeFile(Self.lfCube), "the finite control cube")
    }

    // MARK: - Round trip

    /// The writer and the reader are each other's inverse, including across a hostile
    /// trip through a Windows editor that rewrote every line ending on the way.
    func testAWrittenCubeSurvivesARoundTripThroughWindowsLineEndings() {
        let original = LUT3D(size: 5) { RGB(1 - $0.r, $0.g * $0.g, $0.b) }
        let onDisk = original.cubeFileContents(title: "round trip")
            .replacingOccurrences(of: "\n", with: "\r\n")
        guard let back = LUT3D.fromCubeFile(onDisk) else {
            return XCTFail("a cube this project WROTE was rejected after a Windows editor "
                               + "normalised its line endings")
        }
        XCTAssertEqual(back.size, 5)
        // The file carries six decimals, so the comparison is to that and no further.
        XCTAssertLessThan(back.maxAbsDifference(original), 1e-5,
                          "the round trip changed the numbers")
    }
}
