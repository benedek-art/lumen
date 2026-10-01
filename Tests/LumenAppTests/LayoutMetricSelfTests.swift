// Tests for the measuring instrument, not for the panel.
//
// `LayoutMetricTests` measures the app. Nothing measures `LayoutMetricSupport`, and it
// is the file every number in that suite is divided by: a wrong constant there does not
// produce a failure, it produces a confident, wrong table. Three of the four checks
// below were written after a real drift was found in the tree, not as insurance:
//
//   1. `PanelChain.maskPanelWidth` said 272 while `MaskFloatingPanel.width` said 290.
//      The existing pin catches it as a MISSING STRING, which names the file but not the
//      arithmetic; this catches it as an inequality between the model and the constant
//      itself, which is the thing that has to agree.
//   2. `SliderInventory.callSiteCount` is a COUNT. A count cannot notice a commit that
//      adds one slider and deletes another, and it cannot notice a call site the table
//      never covered — `LookPanel`'s look-apply `Amount` was shipped and unmeasured with
//      the count reading exactly right. Titles, not totals, are what close that.
//   3. `glyphLabelBudget` is `labelWidth − inRowWidth − 4`, and the suite proves it
//      equals 56 by recomputing its own expression. That checks two constants and not
//      the expression: change the app's `− 4` to `− 8` and the assertion still passes.
//   4. Anti-vacuity, for the filters the suite asserts over. `report(_:of:_:)` returns
//      early on an empty failure list, so a filter that stops matching is a silent green.

#if os(macOS)
import AppKit
import XCTest
@testable import LumenApp

@MainActor
final class LayoutMetricSelfTests: XCTestCase {

    // MARK: - The chain against the constants themselves

    /// The hosts whose width is a stored constant, compared to that constant rather than
    /// to a string containing it.
    func testTheModelledHostWidthsEqualTheConstantsTheyStandFor() {
        XCTAssertEqual(PanelChain.maskPanelWidth, MaskFloatingPanel.width,
                       "PanelChain.maskPanelWidth is \(PanelChain.maskPanelWidth) and the "
                       + "panel is \(MaskFloatingPanel.width) wide. Every maskDetail and "
                       + "maskComponent row in the census is out by "
                       + "\(MaskFloatingPanel.width - PanelChain.maskPanelWidth) pt of "
                       + "track, in the direction that makes the panel look worse than it is.")
        XCTAssertEqual(PanelChain.maskDetailLeading, MaskPanel.detailIndent,
                       "the mask detail indent is read from MaskPanel.detailIndent")
        XCTAssertEqual(PanelChain.sliderChrome,
                       Lumen.labelWidth + 2 * PanelChain.rowGap + Lumen.valueWidth)
        XCTAssertEqual(PanelChain.untitledSliderChrome,
                       PanelChain.rowGap + Lumen.valueWidth)
    }

    /// The glyph budget's EXPRESSION, not just its value.
    ///
    /// `LumenControls.swift` writes the label frame as a subtraction. The suite writes
    /// the same subtraction again and asserts the answer is 56, which cannot tell the
    /// two subtractions apart if one of them changes.
    func testTheGlyphBudgetIsTheExpressionTheRowActuallyBuilds() throws {
        let controls = try LayoutSource.flattened("Sources/LumenApp/LumenControls.swift")
        XCTAssertTrue(
            controls.contains("Lumen.labelWidth - LumenBehaviourGlyph.inRowWidth - 4"),
            "the label frame for a glyph-bearing row is no longer "
            + "`labelWidth − inRowWidth − 4`; PanelChain.glyphLabelBudget is a copy of "
            + "that expression and has to be re-derived before the 56 pt claim means "
            + "anything")
        XCTAssertEqual(PanelChain.glyphLabelBudget,
                       Lumen.labelWidth - LumenBehaviourGlyph.inRowWidth - 4)
    }

    // MARK: - The tripwire, by name rather than by total

    /// Every literal slider title in the sources appears in the inventory for that file.
    ///
    /// This is the check the count cannot make. `callSiteCount` compares two integers, so
    /// a commit that adds one row and removes another leaves it green, and a row that was
    /// never in the table at all leaves it green forever.
    ///
    /// Only call sites written as `LumenSlider(title: "…")` are covered — the ones built
    /// through a helper (`MaskPanel.adjustSlider`, `LookPanel.bipolarSlider`,
    /// `CurveEditorView.parametricSlider`, the zone register) pass their title in, and
    /// this scan cannot resolve them. That is a stated limit, not a silent one: the
    /// literal sites are the majority and they are the ones a panel adds rows at.
    func testEveryLiterallyTitledSliderInTheSourcesIsInTheInventory() throws {
        let dir = LayoutSource.root.appendingPathComponent("Sources/LumenApp")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        var missing: [String] = []
        var scanned = 0

        for name in names.sorted() where name.hasSuffix(".swift") {
            let text = try String(contentsOf: dir.appendingPathComponent(name),
                                  encoding: .utf8)
            let known = Set(SliderInventory.all
                .filter { $0.site.contains(name) }
                .map(\.title))
            for (number, line) in text.components(separatedBy: "\n").enumerated() {
                guard let title = Self.literalTitle(in: line) else { continue }
                scanned += 1
                guard !known.contains(title) else { continue }
                missing.append("\"\(title)\" — \(name):\(number + 1)")
            }
        }

        XCTAssertGreaterThan(scanned, 0,
                             "no literally-titled call site was found at all; the scan is "
                             + "matching nothing and this test proves nothing")
        XCTAssertTrue(missing.isEmpty,
                      "\(missing.count) shipped slider(s) carry a title no row in "
                      + "`SliderInventory.all` claims for that file, so they are measured "
                      + "by nothing. The call-site COUNT cannot see this — it is right at "
                      + "\(SliderInventory.callSiteCount) with these rows missing:\n  "
                      + missing.joined(separator: "\n  "))
    }

    /// `LumenSlider(title: "X"` on one line, or nothing.
    private static func literalTitle(in line: String) -> String? {
        guard let call = line.range(of: "LumenSlider(title: \"") else { return nil }
        let rest = line[call.upperBound...]
        guard let close = rest.firstIndex(of: "\"") else { return nil }
        let title = String(rest[rest.startIndex..<close])
        return title.isEmpty ? nil : title
    }

    /// Each `site:` names a file that exists and a line inside it.
    ///
    /// A failure message is only useful if the row it names can be opened. Several of
    /// these drifted by a fixed offset per file when panels grew, which does not move a
    /// measurement but does send a reader to the wrong control.
    func testEveryInventorySiteNamesALineThatExists() throws {
        var broken: [String] = []
        var lineCounts: [String: Int] = [:]
        for row in SliderInventory.all {
            // "File.swift:123" or "File.swift:123 (Other.swift:456)" — the leading pair.
            let head = row.site.split(separator: " ").first.map(String.init) ?? row.site
            let parts = head.split(separator: ":")
            guard parts.count == 2, let line = Int(parts[1]) else {
                broken.append("\(row.title): unparseable site `\(row.site)`")
                continue
            }
            let file = String(parts[0])
            if lineCounts[file] == nil {
                let path = LayoutSource.root
                    .appendingPathComponent("Sources/LumenApp/\(file)")
                guard let text = try? String(contentsOf: path, encoding: .utf8) else {
                    broken.append("\(row.title): no such file `\(file)`")
                    continue
                }
                lineCounts[file] = text.components(separatedBy: "\n").count
            }
            if let count = lineCounts[file], line > count {
                broken.append("\(row.title) — \(row.site): \(file) has \(count) lines")
            }
        }
        XCTAssertTrue(broken.isEmpty,
                      "inventory rows name lines that do not exist:\n  "
                      + broken.joined(separator: "\n  "))
    }

    // MARK: - Anti-vacuity

    /// The filters the metric suite asserts over, each proved non-empty here rather than
    /// at four separate call sites — an assertion over nothing passes, and `report` is
    /// written to return early exactly when there is nothing to say.
    func testNoSubsetTheMetricSuiteAssertsOverIsEmpty() {
        XCTAssertFalse(SliderInventory.all.isEmpty)
        XCTAssertFalse(SliderInventory.all.filter(\.hasGlyph).isEmpty,
                       "the 56 pt budget check would pass vacuously")
        XCTAssertFalse(SliderInventory.all.filter(\.indented).isEmpty,
                       "the subordinated-row check would pass vacuously")
        XCTAssertFalse(SliderInventory.all.filter { $0.title.isEmpty }.isEmpty,
                       "the untitled-chrome path would never be exercised")
        XCTAssertFalse(SliderInventory.all.filter { !$0.hasGlyph && !$0.title.isEmpty }
                        .isEmpty,
                       "the plain-label check would pass vacuously")
        XCTAssertFalse(PanelChain.Host.allCases.filter(\.rowsAreTitled).isEmpty)
        for host in PanelChain.Host.allCases {
            XCTAssertFalse(SliderInventory.all.filter { $0.host == host }.isEmpty,
                           "no row is recorded in \(host.rawValue), so every claim about "
                           + "that host is a claim about an empty set")
        }
    }

    /// EVERY CITATION IN THE INVENTORY LANDS ON THE ROW IT NAMES.
    ///
    /// `SliderSpec.site` says why it exists in its own doc-comment — "`File.swift:line` of
    /// the call site, so a failure names the row to fix" — and until this test nothing
    /// checked one. A `site` is not read by any arithmetic: it is printed in a failure
    /// message, so a citation that has drifted still measures a real geometry and every
    /// lane stays green while the message sends a reader to the wrong line.
    ///
    /// They had drifted, and not by a little. When this was first run, **87 of the 143
    /// rows** pointed at something that is not a slider — the panels had grown by four
    /// hundred lines in places, and the table's line numbers stayed where they were.
    /// `MaskPanel`'s Exposure row named line 1724, which is the middle of a help string
    /// about the brush; `CurveEditorView`'s four parametric rows named a `resetButton` and
    /// three doc-comment lines; the two colour-wheel bars named `LumenControls.swift:1943`,
    /// which had moved to 1988.
    ///
    /// What it checks, and the reason it is not stricter: the cited line, or one either
    /// side of it, must CONSTRUCT a slider — `LumenSlider(`, one of the panels' own
    /// `…Slider(` builders, or `LumenColorWheel(` for the two bars. One line of slack,
    /// because a call and its title argument are commonly split across two lines and a
    /// zero-slack rule would fail on formatting. Then, where the call spells a LITERAL
    /// title, it must be this row's title — which is what turns "lands on a slider" into
    /// "lands on THIS slider", and is what would have caught the one bad repair made
    /// while fixing the 87 (a brush row and a mask-refine row swapped citations, because
    /// the first repair keyed its lookup by the old string and two rows shared one).
    ///
    /// Rows whose title is computed — the mixer band names, the zone register, the
    /// helper-built mask rows — spell no literal at the call, so only the first half
    /// applies to them. That is a real gap and it is a small one: a computed-title row
    /// still has to land on a slider construction.
    func testEveryCitationInTheInventoryLandsOnTheRowItNames() throws {
        var wrong: [String] = []
        var cache: [String: [String]] = [:]
        func lines(_ file: String) throws -> [String] {
            if let hit = cache[file] { return hit }
            let text = try LayoutSource.read("Sources/LumenApp/\(file)")
            let split = text.components(separatedBy: "\n")
            cache[file] = split
            return split
        }
        /// `File.swift:123`, of which a `site` may carry more than one — the wheel bars
        /// name the control-kit line AND the panel that mounts it.
        func citations(in site: String) -> [(file: String, line: Int)] {
            var found: [(String, Int)] = []
            for token in site.components(separatedBy: CharacterSet(charactersIn: " ()")) {
                let parts = token.components(separatedBy: ":")
                guard parts.count == 2, parts[0].hasSuffix(".swift"),
                      let line = Int(parts[1]) else { continue }
                found.append((parts[0], line))
            }
            return found
        }

        for row in SliderInventory.all {
            let sites = citations(in: row.site)
            XCTAssertFalse(sites.isEmpty,
                           "\(row.title.isEmpty ? "(untitled)" : row.title) has a site "
                               + "string no reader can follow: \"\(row.site)\"")
            for (file, line) in sites {
                let text = try lines(file)
                let landed = [line, line - 1, line + 1].first { candidate in
                    guard candidate >= 1, candidate <= text.count else { return false }
                    let source = text[candidate - 1]
                    return source.contains("Slider(") || source.contains("LumenColorWheel(")
                }
                guard let landed else {
                    let at = (line >= 1 && line <= text.count)
                        ? text[line - 1].trimmingCharacters(in: .whitespaces) : "past EOF"
                    wrong.append("\(row.title.isEmpty ? "(untitled)" : row.title) — "
                                 + "\(file):\(line) is not a slider call: \(at.prefix(60))")
                    continue
                }
                // The literal title, when the call spells one.
                let window = text[(landed - 1)..<min(landed + 1, text.count)]
                    .joined(separator: " ")
                guard let call = window.range(of: "Slider(")
                        ?? window.range(of: "LumenColorWheel(") else { continue }
                var rest = window[call.upperBound...]
                    .trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("title:") {
                    rest = String(rest.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                }
                guard rest.hasPrefix("\""), !row.title.isEmpty else { continue }
                let body = rest.dropFirst()
                guard let end = body.firstIndex(of: "\"") else { continue }
                let spelled = String(body[..<end])
                if spelled != row.title {
                    wrong.append("\(row.title) — \(file):\(line) is the call site of "
                                 + "\"\(spelled)\", which is a different row")
                }
            }
        }
        XCTAssertTrue(wrong.isEmpty,
                      "\(wrong.count) of \(SliderInventory.all.count) rows cite a line "
                          + "that is not their call site. Every number this suite prints "
                          + "about them is still right; the address it prints them with "
                          + "is not:\n  " + wrong.joined(separator: "\n  "))
    }

    /// The face these widths are taken in is the one the app draws, and not a fallback.
    ///
    /// Everything in the metric suite is a width in points of the system face. If the
    /// runner resolves something else — a stripped image, a substituted family — the
    /// arithmetic still runs and still prints numbers, and nothing above would notice.
    /// The existing instrument check proves the metrics are non-zero and monotone, which
    /// a substitute face would also satisfy.
    func testTheFaceBeingMeasuredIsTheSystemFace() {
        XCTAssertEqual(LayoutFont.numeric.familyName, LayoutFont.body.familyName,
                       "the tabular face is not the same family as the body face, so a "
                       + "readout and the label beside it are being measured in two "
                       + "different typefaces")
        // A digit at 11 pt in this family is a little over half its point size. Wide
        // bounds on purpose: this is a check that a face with plausible metrics resolved,
        // not a golden width that would have to be re-baselined on every OS.
        let digit = TextMetric.width("0", LayoutFont.numeric)
        XCTAssertGreaterThan(digit, 4.0,
                             "a digit measuring \(digit) pt at 11 pt is not a text face")
        XCTAssertLessThan(digit, 9.0,
                          "a digit measuring \(digit) pt at 11 pt is not a text face")
    }
}
#endif
