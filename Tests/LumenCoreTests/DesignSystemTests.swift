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

    // MARK: - Ratchets

    /// Raw `.system(size:)` calls. 199 at landing; the type scale exists so this falls.
    func testRawFontSizesOnlyEverDecrease() {
        let n = total(".system(size:")
        XCTAssertLessThanOrEqual(n, 199,
                                 "\(n) raw .system(size:) calls in Sources/LumenApp, up "
                                 + "from 203 — use .lumenHeading / .lumenBody / "
                                 + ".lumenCaption / .lumenNumeric")
    }

    /// Sub-floor text. The app set 10 pt as its own floor and shipped 37 sites under it.
    func testNinePointTextOnlyEverDecreases() {
        let n = total(".system(size: 9")
        XCTAssertLessThanOrEqual(n, 37,
                                 "\(n) sites at 9 pt, up from 37 — 10 is the floor")
    }

    /// Raw corner radii off the 6 / 9 / 14 ladder. 34 at landing.
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
        XCTAssertLessThanOrEqual(n, 34,
                                 "\(n) numeric cornerRadius literals, up from 34 — use "
                                 + "Lumen.radiusChip / radiusControl / radiusCard")
    }

    /// Hand-rolled dark overlays. The HUD material exists so these fall to zero.
    func testHandRolledHUDFillsOnlyEverDecrease() {
        let n = total("Color.black.opacity(0.5") + total("Color.black.opacity(0.6") + total("Color.black.opacity(0.7")
        XCTAssertLessThanOrEqual(n, 19,
                                 "\(n) hand-rolled black overlays, up from 19 — use "
                                 + "lumenHUD() or Lumen.hudFill")
    }
}
