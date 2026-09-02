// DesignSystemTests.swift
// The design system's rules, checked as text — because the views cannot be built here.
//
// `Sources/LumenApp` is `#if os(macOS)`, compiles on one CI lane, and no test in the
// package can construct a view. `WorkspaceEntryTests`, `KeyGrammarTests` and
// `CanvasEditScopeTests` already read the app's source as text for the same reason, and
// this file does it for the rules the U1 landing established. Each is a RATCHET or a
// PROHIBITION — a count that may only fall, or a modifier that may not appear on a
// particular control — because those are the two shapes of design rule that erode one
// call site at a time, invisibly, until the audit that finds 198 raw font sizes.
//
// The numbers here are the measured state at landing. Lowering one is welcome and
// expected; the assertion is that nobody raises it back.

import XCTest
@testable import LumenCore

final class DesignSystemTests: XCTestCase {

    private static var appRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // LumenCoreTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // <package>
            .appendingPathComponent("Sources/LumenApp")
    }

    /// Every Swift file in the app target, comments blanked, as (name, text).
    private static var sources: [(name: String, text: String)] = {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: appRoot.path) else { return [] }
        return names.filter { $0.hasSuffix(".swift") }.sorted().compactMap { name in
            let url = appRoot.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return (name, withoutComments(text))
        }
    }()

    /// The same comment walk `CanvasEditScopeTests` uses: `//` and `/* */` blanked,
    /// string bodies kept, newlines preserved so line numbers survive.
    private static func withoutComments(_ text: String) -> String {
        var out = Array(text)
        var i = 0
        let n = out.count
        func blank(_ from: Int, _ to: Int) {
            for k in from..<to where out[k] != "\n" { out[k] = " " }
        }
        while i < n {
            let c = out[i]
            let next: Character? = i + 1 < n ? out[i + 1] : nil
            if c == "/" && next == "/" {
                var j = i
                while j < n && out[j] != "\n" { j += 1 }
                blank(i, j); i = j
            } else if c == "/" && next == "*" {
                var j = i + 2
                while j + 1 < n && !(out[j] == "*" && out[j + 1] == "/") { j += 1 }
                let end = Swift.min(j + 2, n)
                blank(i, end); i = end
            } else if c == "\"" {
                var j = i + 1
                while j < n {
                    if out[j] == "\\" { j += 2; continue }
                    if out[j] == "\"" { j += 1; break }
                    if out[j] == "\n" { break }
                    j += 1
                }
                i = Swift.min(j, n)
            } else {
                i += 1
            }
        }
        return String(out)
    }

    private func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private func total(_ needle: String) -> Int {
        Self.sources.reduce(0) { $0 + count(needle, in: $1.text) }
    }

    private func source(_ name: String) -> String {
        guard let s = Self.sources.first(where: { $0.name == name })?.text else {
            XCTFail("\(name) not found under Sources/LumenApp — if it moved, move this "
                    + "scan with it rather than deleting it")
            return ""
        }
        return s
    }

    // MARK: - Prohibitions

    /// THE SLIDER ROW DOES NOT LIGHT UP UNDER THE POINTER. The owner asked for this
    /// twice and `LumenFocus.swift` holds his words; the design mockup that followed
    /// would have put it back, and was corrected. This is the assertion that stops a
    /// third round.
    ///
    /// Scoped to the `LumenSlider` body rather than the file, because the toggle row in
    /// the same file is a button and keeps its hover on purpose.
    func testTheSliderRowHasNoHoverFill() {
        let text = source("LumenControls.swift")
        guard let start = text.range(of: "struct LumenSlider: View"),
              let end = text.range(of: "struct LumenSectionHeader", range: start.upperBound..<text.endIndex)
        else { XCTFail("LumenSlider or LumenSectionHeader not found — rename here too"); return }
        let slider = String(text[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(slider.isEmpty)
        XCTAssertEqual(count("lumenHoverable(", in: slider), 0,
                       "a hover fill is back on the slider row — the owner: \"I would "
                       + "remove a bunch of the hover effects, like hovering over the "
                       + "white balance or the temperature or tint\"")
        XCTAssertEqual(count("lumenInteractive(", in: slider), 0,
                       "same rule, by the other name")
        XCTAssertEqual(count("lumenFocusRing(", in: slider), 0,
                       "an accent ring is back on the slider row — the owner: \"it gets "
                       + "a blue border around it, which I don't want\". Rows use "
                       + "lumenFocusSurface.")
    }

    /// Section headers are mixed case through `.lumenHeading`. The caps label survives
    /// only as a small tertiary group marker, at one size.
    func testSectionHeadersUseTheHeadingTokenAndCapsHaveOneSize() {
        XCTAssertGreaterThan(total(".lumenHeading"), 0,
                             "the heading token has no call sites again — it shipped "
                             + "that way once, with 53 headers in tracked capitals")
        var sized: [String] = []
        for (name, text) in Self.sources {
            for line in text.split(separator: "\n") where line.contains("LumenCapsLabel(") {
                if line.contains("size:") { sized.append("\(name): \(line.trimmingCharacters(in: .whitespaces))") }
            }
        }
        XCTAssertTrue(sized.isEmpty,
                      "LumenCapsLabel is fragmenting into sizes again — it was built to "
                      + "end five caps styles and then grew three of its own:\n"
                      + sized.joined(separator: "\n"))
    }

    /// Nothing in the app paints an `NSCursor` outside the one balanced modifier.
    func testEveryCursorPushGoesThroughTheBalancedModifier() {
        var raw: [String] = []
        for (name, text) in Self.sources where name != "LumenHover.swift" {
            if text.contains(".push()") && text.contains("NSCursor") {
                for line in text.split(separator: "\n") where line.contains("NSCursor") && line.contains(".push()") {
                    raw.append("\(name): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertTrue(raw.isEmpty,
                      "an NSCursor push outside LumenHover.swift — those leak the cursor "
                      + "stack in three ordinary ways; use lumenScrubCursor / "
                      + "lumenClickCursor / lumenPickCursor:\n" + raw.joined(separator: "\n"))
    }

    /// ONE ROW PITCH. The column had three — 26, 30 and 34 by G1's measurement — and
    /// none of them was a number anyone had chosen. The row's height and its air are
    /// tokens; the gap between rows became one in U2, because it was written at
    /// thirty-six call sites and that is how it came to be three numbers.
    ///
    /// The assertion is that no owned panel writes its own: a literal `spacing:` on a
    /// row stack is exactly how the third pitch arrived.
    func testTheOwnedPanelsDoNotWriteTheirOwnRowPitch() {
        let owned = ["BasicPanel.swift", "ZonesPanel.swift", "DetailPanel.swift",
                     "EffectsPanel.swift", "LookPanel.swift", "ColorPanel.swift",
                     "CropPanel.swift"]
        var literal: [String] = []
        for name in owned {
            for (offset, line) in source(name)
                .split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains("VStack(alignment: .leading, spacing: ") {
                let rest = line.components(separatedBy: "spacing: ")[1]
                if let first = rest.first, first.isNumber {
                    literal.append("\(name):\(offset + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertTrue(literal.isEmpty,
                      "a panel is writing its own row pitch again — use Lumen.rowGap:\n"
                      + literal.joined(separator: "\n"))
    }

    /// And the section heading is drawn once. `WorkspaceSection.frame.title` is "Crop"
    /// and `CropSection`'s own heading was "Crop", so the accordion printed it twice one
    /// row apart, each with a chevron, a modified dot and a Reset of different scope.
    /// Every panel the column routes a section to must take `only:` and honour it.
    func testAPanelTheColumnHeadsDoesNotDrawItsOwnHeadingToo() {
        let effects = source("EffectsPanel.swift")
        XCTAssertFalse(effects.isEmpty)
        for call in ["CropSection("] {
            guard let range = effects.range(of: call) else {
                XCTFail("\(call) not found in EffectsPanel.swift — if it moved, move "
                        + "this scan with it")
                continue
            }
            let site = String(effects[range.lowerBound...].prefix(60))
            XCTAssertTrue(site.contains("only:"),
                          "\(call) is constructed without `only:`, so it draws its own "
                          + "heading under the one the column already drew: \(site)")
        }
    }

    /// ONE EMPTY STATE. The app had five, written five ways — four mark sizes (26, 30,
    /// 34, 40), three text treatments and four stack spacings, for one idea.
    ///
    /// This is the failure `DesignSystemTests` could not previously see: every one of
    /// those five spelled its tokens correctly. What repeated was a SHAPE, and a shape
    /// has no name to grep for until somebody gives it one. `LumenEmptyState` is the
    /// name; the check is that the display mark — the 40 pt symbol that says "this
    /// surface has nothing on it" — is drawn in exactly one file.
    func testTheDisplayMarkIsDrawnInOnePlace() {
        var sites: [String] = []
        for (name, text) in Self.sources where name != "LumenEmptyState.swift" {
            guard name != "LumenType.swift" else { continue }   // the token's own definition
            for (offset, line) in text.split(separator: "\n",
                                             omittingEmptySubsequences: false).enumerated()
            where line.contains("lumenGlyphDisplay") {
                sites.append("\(name):\(offset + 1): "
                             + line.trimmingCharacters(in: .whitespaces))
            }
        }
        XCTAssertTrue(sites.isEmpty,
                      "a surface is drawing its own empty state again — use "
                          + "LumenEmptyState, which is the shape all five of them were "
                          + "reaching for:\n" + sites.joined(separator: "\n"))
    }

    // MARK: - Ratchets

    /// Raw `.system(size:)` calls. 199 after U1, 166 after U2's migration of the ten
    /// owned panels, 84 after U3's shell, **35** after U5 separated the two scales and gave the empty states one shape.
    ///
    /// That last drop is where the number stopped being about laziness. Most of what
    /// survived U3 was not text at all: `.font(.system(size: 40))` on an `Image` sets a
    /// GLYPH's drawn extent, and a glyph answers to the box it sits in, not to the
    /// reading distance of the prose around it. Held on one scale the two argue — a
    /// 12 pt row icon and 12 pt body copy are the same number for unrelated reasons —
    /// so `lumenGlyph*` is a second, four-step scale and the type tokens are for type.
    /// The rest were three genuine gaps: 10 semibold (`lumenCaptionStrong`), the lead
    /// line of a surface that has taken over the window (`lumenLead`), and a sheet's
    /// title (`lumenTitle`).
    ///
    /// What is left is mostly honest: a `design:` that varies with a flag, a size held
    /// in a variable, and the four state marks at 26 / 30 / 34 / 40 — which want one
    /// decision made with all four on screen, not a batch rename.
    func testRawFontSizesOnlyEverDecrease() {
        let n = total(".system(size:")
        XCTAssertLessThanOrEqual(n, 35,
                                 "\(n) raw .system(size:) calls in Sources/LumenApp, up "
                                 + "from 35 — use .lumenHeading / .lumenBody / "
                                 + ".lumenCaption / .lumenNumeric / .lumenCaptionStrong "
                                 + "/ .lumenLead / .lumenTitle for TEXT, and "
                                 + ".lumenGlyph* for a glyph")
    }

    /// AND A GLYPH SIZE IS NOT A TYPE TOKEN. The separation only holds while nobody
    /// reaches across it: an `Image` wearing `.lumenBody` is the two scales rejoining,
    /// and it is invisible in review because it renders fine.
    func testAnImageDoesNotTakeATextToken() {
        let textTokens = ["lumenHeading", "lumenBody", "lumenBodyStrong", "lumenCaption",
                          "lumenCaptionStrong", "lumenNumeric", "lumenCaptionNumeric",
                          "lumenNumericStrong", "lumenLead", "lumenTitle"]
        var offenders: [String] = []
        for (name, text) in Self.sources {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (offset, line) in lines.enumerated() where line.contains(".font(.lumen") {
                // The glyph is on the line above in every shape this app writes:
                // `Image(systemName: …)` then `.font(…)`.
                let previous = offset > 0 ? String(lines[offset - 1]) : ""
                guard previous.contains("Image(systemName:") else { continue }
                for token in textTokens where line.contains(".font(.\(token))") {
                    offenders.append("\(name):\(offset + 1): \(token) on a glyph — "
                                     + previous.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "a text token is sizing an SF Symbol, which puts the two scales "
                          + "back on one number:\n" + offenders.joined(separator: "\n"))
    }

    /// THE FLOOR IS THE FLOOR. The app set 10 pt as its own minimum, shipped 46 sites
    /// under it, and never enforced it. There are none left, so this is no longer a
    /// ratchet — it is zero, and the first site to reappear fails.
    func testNothingIsDrawnBelowTheTenPointFloor() {
        var offenders: [String] = []
        for (name, text) in Self.sources {
            for (offset, line) in text.split(separator: "\n",
                                             omittingEmptySubsequences: false).enumerated()
            where line.contains(".system(size: 9") || line.contains(".system(size: 8") {
                offenders.append("\(name):\(offset + 1): "
                                 + line.trimmingCharacters(in: .whitespaces))
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "text below the app's own 10 pt floor:\n"
                      + offenders.joined(separator: "\n"))
    }

    /// Raw corner radii off the 6 / 9 / 14 ladder. 34 at U1's landing, 22 after U2,
    /// **1** now — and the one that is left argues for itself in a comment
    /// (`LumenBehaviourGlyph`, a drawn miniature whose box is about eight points, where
    /// `radiusChip` is a capsule).
    ///
    /// The 21 that went were two different mistakes wearing one shape. The controls —
    /// the filter bar's buttons, the ingest and export sheets' fields and wells, the
    /// mask panel's rows and tiles — were on Aqua's 3/4/5 and are now on the ladder.
    /// The small drawn indicators were on 2, 2.5 and 3 chosen by four different hands
    /// for one decision, and are now on `Lumen.swatchRadius(_:)`: a quarter of the short
    /// side, which is what `radiusChip` already is on the control it was sized for.
    func testRawCornerRadiiOnlyEverDecrease() {
        var n = 0
        for (_, text) in Self.sources {
            for line in text.split(separator: "\n") where line.contains("cornerRadius:") {
                // A literal number after the label, as opposed to a `Lumen.radius…` token.
                if let r = line.range(of: "cornerRadius:") {
                    let rest = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                    if let first = rest.first, first.isNumber { n += 1 }
                }
            }
        }
        XCTAssertLessThanOrEqual(n, 1,
                                 "\(n) numeric cornerRadius literals, up from 1 — use "
                                 + "Lumen.radiusChip / radiusControl / radiusCard for a "
                                 + "surface, Lumen.swatchRadius(shortSide) for a small "
                                 + "drawn indicator")
    }

    /// Hand-rolled dark overlays. The HUD material exists so these fall to zero.
    func testHandRolledHUDFillsOnlyEverDecrease() {
        let n = total("Color.black.opacity(0.5") + total("Color.black.opacity(0.6") + total("Color.black.opacity(0.7")
        XCTAssertLessThanOrEqual(n, 15,
                                 "\(n) hand-rolled black overlays, up from 19 — use "
                                 + "lumenHUD() or Lumen.hudFill")
    }
}
