// CaptureSharpenScopeTests.swift
// E2-02 (S1): the "Capture sharpening" toggle was LIVE on JPEG, HEIC and TIFF.
//
// The control moved, wrote `develop.detail.capture.auto` into the recipe and the
// sidecar, lit the section's modified dot and spent an undo step — and changed the
// photograph by not one code value, because the only shipping reader of that field is
// the RAW decoder and a rendered file never goes through it. The comment standing
// directly above the toggle said the section was disabled there. It was not: the file's
// one `.disabled(isRenderedFile)` sat on `captureOverrides`, so the badge row and the
// Amount slider went grey and the switch above them stayed live.
//
// A comment is not a modifier, and that is the whole mechanism of this defect: nothing
// could fail. This file is what could have failed.
//
// WHY IT IS A TEXT SCAN. `Sources/LumenApp` is `#if os(macOS)` and there is no view-tree
// assertion available on the Linux lane, so the claim "this stack carries the disable"
// is asserted by reading the source, exactly as `CanvasEditScopeTests`,
// `DeliveryNameTests` and `KeyGrammarTests` do for the same reason. Where the claim CAN
// be made behaviourally it is: the premise the whole finding rests on — that the toggle
// writes a raw-only field, that flipping it lights the dot — is checked against the real
// types in LumenCore below, not described in a comment.
//
// COMMENTS ARE BLANKED BEFORE EVERY SCAN. Not decoration: the fixed panel discusses
// `.disabled(isRenderedFile)` twice in prose, and an unstripped scan for that string
// would go green on a file with the modifier deleted and the prose left behind — the
// test passing its own substitution proof. String bodies are kept, because one
// assertion here is about a sentence the photographer reads on screen.

import Foundation
import XCTest
@testable import LumenCore

final class CaptureSharpenScopeTests: XCTestCase {

    // MARK: - The premise, in LumenCore, behaviourally

    /// The switch defaults ON, which is why the fix could not stop at `.disabled`.
    ///
    /// `CaptureSharpen()` is `auto: true`, so a merely-disabled row would have left a
    /// switch parked in the ON position on every JPEG in the library — the same claim
    /// the live toggle was making, that a stage is running on this photograph, said
    /// more quietly. That is what `captureToggleBinding` returning `.constant(false)`
    /// is for, and this is the fact that makes it necessary rather than fussy.
    func testTheToggleDefaultsOnSoDisablingAloneWouldLeaveItParkedOn() {
        XCTAssertTrue(CaptureSharpen().auto,
                      "capture sharpening defaults ON; if this ever defaults off, the "
                      + "constant-false binding in DetailPanel.captureToggleBinding is "
                      + "no longer load-bearing and its comment should be revisited")
        XCTAssertEqual(Recipe().develop.detail.capture, CaptureSharpen(),
                       "an untouched recipe starts on the default capture state")
    }

    /// Flipping it is a real edit to the recipe — which is the harm, not a detail.
    ///
    /// `DetailPanel.isCaptureModified` is literally `capture != CaptureSharpen()`, so
    /// the assertion below is the panel's own expression evaluated here. On a rendered
    /// file this lit the dot, wrote the sidecar and spent an undo step for a change no
    /// stage could read.
    func testFlippingTheToggleLightsTheSectionsModifiedDot() {
        var recipe = Recipe()
        recipe.develop.detail.capture.auto = false
        XCTAssertNotEqual(recipe.develop.detail.capture, CaptureSharpen(),
                          "turning the toggle off must differ from the default — this "
                          + "is `isCaptureModified`, and it is why an inert toggle was "
                          + "S1 rather than cosmetic")
    }

    /// And the only thing the field means is a number for the raw decode.
    ///
    /// The mapping itself is `EngineTests`' subject (0…150 → 0…1.5); what is asserted
    /// here is narrower and is E2-02's: `auto` is the ON switch, and what it switches
    /// is a strength that only a RAW decode spends.
    func testTheOnlyThingTheToggleMeansIsAStrengthForTheRawDecode() {
        XCTAssertEqual(CaptureSharpen(auto: true).strengthFraction, 1, accuracy: 1e-12)
        XCTAssertEqual(CaptureSharpen(auto: false).strengthFraction, 0, accuracy: 1e-12)
    }

    // MARK: - The premise, mechanically: "it reaches nothing there"

    /// `RenderedImageSource.decode` reads NOTHING out of the recipe but the scale.
    ///
    /// This is the sentence the panel's comment makes, made falsifiable. If a rendered
    /// decode ever grows a recipe reader, the honest response is to re-open E2-02 and
    /// decide what the capture control means on that path — not to let this file keep
    /// asserting a premise that has quietly stopped being true.
    func testTheRenderedDecodeReadsNothingOutOfTheRecipeButScale() {
        let source = Self.stripped("Sources/LumenPipeline/ImageSource.swift")
        let cls = Self.slice(from: "public final class RenderedImageSource",
                             in: source, of: "ImageSource.swift")
        let decode = Self.slice(from: "public func decode(recipe: Recipe",
                                in: cls, of: "RenderedImageSource", limit: 800)
        XCTAssertTrue(decode.contains("scaleFactor"),
                      "the scan lost RenderedImageSource.decode and would pass on "
                      + "anything")
        XCTAssertFalse(decode.contains("recipe."),
                       "RenderedImageSource.decode now reads the recipe. E2-02's whole "
                       + "premise is that it does not — reopen the finding rather than "
                       + "loosening this line")
    }

    /// And the RAW decode is the one place the field is spent.
    func testTheRawDecodeIsTheSoleShippingReaderOfCaptureStrength() {
        let raw = Self.stripped("Sources/LumenPipeline/AppleRawSource.swift")
        XCTAssertTrue(raw.contains("detail.capture.strengthFraction"),
                      "AppleRawSource is supposed to be the reader of the capture "
                      + "strength; if it moved, this whole finding moves with it")
    }

    // MARK: - The fix

    /// THE FIX ITSELF: the disable is on the stack that holds the toggle.
    ///
    /// Not on `captureOverrides`, where it was, and where it covered everything in the
    /// section except the one control that wrote the recipe.
    func testTheCaptureSectionCarriesTheDisableOnTheStackHoldingTheToggle() {
        let section = Self.captureSection()
        XCTAssertTrue(section.contains(".disabled(isRenderedFile)"),
                      "`captureSection` must carry `.disabled(isRenderedFile)` on the "
                      + "stack that holds the toggle. Without it the switch is live on "
                      + "every JPEG, HEIC and TIFF: it writes the recipe and the "
                      + "sidecar, lights the section's dot and reaches no stage. This "
                      + "is E2-02 and a comment saying the section is disabled is not "
                      + "a modifier that disables it.")
        XCTAssertTrue(section.contains("isOn: captureToggleBinding"),
                      "the toggle must take the guarded binding, not the raw recipe one")
    }

    /// Belt as well as braces: on a rendered file the toggle has no write path at all.
    ///
    /// The disable stops the gesture; this stops the write. They are separate defences
    /// on purpose — `.disabled` is one modifier away from being lost in a refactor of a
    /// view body, and if it is lost, a constant binding still cannot dirty a recipe.
    func testTheToggleHasNoWritePathOnARenderedFile() {
        let panel = Self.stripped(Self.panelPath)
        let binding = Self.member("private var captureToggleBinding: Binding<Bool> {",
                                  of: panel, in: "DetailPanel.swift")

        let polarityIsRight = binding.contains("guard !isRenderedFile else")
            || binding.contains("if isRenderedFile { return .constant(false)")
        XCTAssertTrue(polarityIsRight,
                      "`captureToggleBinding` must return a constant on a RENDERED "
                      + "file and the recipe binding otherwise. Found:\n" + binding)
        XCTAssertTrue(binding.contains(".constant(false)"),
                      "the constant must be FALSE: CaptureSharpen() defaults auto to "
                      + "true, so a constant-true switch would sit lit on every JPEG "
                      + "claiming a stage is running on it")
        XCTAssertTrue(binding.contains("binder.flag(\\.develop.detail.capture.auto"),
                      "the raw-file branch still has to write the recipe")

        XCTAssertEqual(Self.count(of: "binder.flag(\\.develop.detail.capture.auto",
                                  in: panel), 1,
                       "there must be exactly ONE writable binding to "
                       + "`detail.capture.auto` in this panel, and it must be the one "
                       + "inside `captureToggleBinding`. A second call site is a second "
                       + "way for a rendered file to write a raw-only field.")
    }

    /// The greyed row says WHY, on the panel, and not only in a tooltip.
    ///
    /// This project prefers explaining to silently disabling: a dead control with no
    /// stated reason makes the photographer hover it to find out what is wrong with his
    /// file, which costs him the time the disable was meant to save. `renderedCaptureNote`
    /// is the sentence, standing where the Amount row used to be.
    func testTheReasonIsOnThePanelAndNotOnlyInATooltip() {
        let panel = Self.stripped(Self.panelPath)
        let section = Self.captureSection()
        XCTAssertTrue(section.contains("if isRenderedFile { renderedCaptureNote }"),
                      "the section must DRAW the explanation on a rendered file, not "
                      + "merely stop drawing the controls")

        let note = Self.member("private var renderedCaptureNote: some View {",
                               of: panel, in: "DetailPanel.swift")
        guard let opening = note.range(of: "Text(\"") else {
            XCTFail("`renderedCaptureNote` draws no visible text, so the photographer "
                    + "is told nothing on screen and the disable is silent")
            return
        }
        let caption = String(note[opening.upperBound...].prefix { $0 != "\"" })
        XCTAssertGreaterThan(caption.count, 12,
                             "the on-panel reason has to be a sentence, not a label. "
                             + "Found: \(caption.debugDescription)")
        XCTAssertTrue(note.contains(".help("),
                      "and the row keeps its longer explanation on hover")
    }

    /// The tooltip branches on file type, the way the two computed helps beside it do.
    func testTheToggleTooltipBranchesOnFileType() {
        let panel = Self.stripped(Self.panelPath)
        let help = Self.member("private var captureToggleHelp: String {",
                               of: panel, in: "DetailPanel.swift")
        XCTAssertTrue(help.contains("if isRenderedFile"),
                      "the toggle's help must say something different on a file the "
                      + "stage cannot reach; it was the one help string in this "
                      + "section that did not branch, which is how it came to describe "
                      + "a stage that does not run")
    }

    /// The second-order half of E2-02: an inert toggle decided whether the one piece of
    /// real help on the Sharpening screen appeared.
    ///
    /// On a rendered file there is never a capture stage, whatever the recipe's `auto`
    /// says — and a recipe written by another build can arrive with `auto` true — so the
    /// refugee hint has to key on the file, not on the field.
    func testTheRefugeeHintNoLongerDependsOnAnInertToggle() {
        let panel = Self.condensed(Self.stripped(Self.panelPath))
        XCTAssertTrue(
            panel.contains("if isRenderedFile || !recipe.develop.detail.capture.auto"),
            "the Lightroom-refugee hint must show on every rendered file. Gated on "
            + "`!capture.auto` alone, a toggle that reaches no stage decides whether "
            + "the only starting point this screen offers is drawn at all.")
    }

    // MARK: - One answer to "is this file already demosaiced"

    /// The panel and the decoder fork ask the SAME question of the SAME function.
    ///
    /// This is the assertion that outlives the fix. Two copies of "is this file already
    /// demosaiced" is the next defect in this family: the panel greys a control for a
    /// `.heif` the pipeline still sends to the RAW decoder, or the reverse, and they
    /// drift one extension at a time with nothing to notice. There is one predicate,
    /// `PhotoFormats.isRendered`, and both ends must name it.
    func testThePanelAndTheDecoderForkAskTheSameQuestion() {
        let panel = Self.stripped(Self.panelPath)
        let predicate = Self.member("private var isRenderedFile: Bool {",
                                    of: panel, in: "DetailPanel.swift")
        XCTAssertTrue(predicate.contains("PhotoFormats.isRendered("),
                      "the panel must ASK the shared predicate rather than answer the "
                      + "question itself")

        let coordinator = Self.stripped("Sources/LumenApp/RenderCoordinator.swift")
        let fork = Self.slice(from: "func source(for url: URL)", in: coordinator,
                              of: "RenderCoordinator.swift", limit: 1_400)
        XCTAssertTrue(fork.contains("PhotoFormats.isRendered(url)"),
                      "the decoder fork must ask the same predicate; if it was renamed "
                      + "or moved, move this scan with it rather than deleting it")
        XCTAssertTrue(fork.contains("RenderedImageSource") && fork.contains("AppleRawSource"),
                      "and it is the fork between the two decoders — the reason the "
                      + "panel's answer has to be the same one")
    }

    /// And exactly one answer exists, in one place, for the whole application.
    func testExactlyOneDefinitionOfThatPredicateExists() {
        var definitions: [String] = []
        for file in Self.swiftFiles(under: "Sources") {
            let text = Self.withoutComments(
                (try? String(contentsOf: file, encoding: .utf8)) ?? "")
            if text.contains("func isRendered(") {
                definitions.append(file.lastPathComponent)
            }
        }
        // The count, not the filename: moving `PhotoFormats` into LumenCore so it can
        // be tested directly would be an improvement and must not fail here. TWO
        // definitions is the defect — the panel and the pipeline answering the same
        // question separately, which is the drift this whole section exists to catch.
        XCTAssertEqual(definitions.count, 1,
                       "`isRendered` must be defined exactly once. Found in: "
                       + "\(definitions). Two definitions means the panel can grey a "
                       + "control for a file the pipeline still sends to the RAW "
                       + "decoder, and nothing notices until a photographer does.")
    }

    /// The panel keeps no private copy of the question, in any shape.
    func testThePanelKeepsNoSecondCopyOfTheQuestion() {
        let panel = Self.stripped(Self.panelPath)
        XCTAssertFalse(panel.contains("pathExtension"),
                       "DetailPanel is reading file extensions itself; that is a second "
                       + "copy of `PhotoFormats.isRendered` waiting to disagree with it")
        XCTAssertFalse(panel.contains("PhotoFormats.rendered"),
                       "the panel must call `isRendered(_:)`, not reach into the "
                       + "extension set and re-implement the lowercasing")
        XCTAssertEqual(Self.count(of: "private var isRenderedFile: Bool", in: panel), 1,
                       "one `isRenderedFile` for this panel")
        XCTAssertEqual(Self.count(of: ".disabled(isRenderedFile)", in: panel), 1,
                       "ONE gate. The disable moved up to `captureSection`'s stack and "
                       + "the copy inside `captureOverrides` was deleted rather than "
                       + "left behind; two answers to the same question in one file is "
                       + "the shape of the defect this fix closed.")
    }

    // MARK: - helpers
    //
    // Copied rather than shared with the other scanners in this suite, for the reason
    // `CanvasEditScopeTests` gives: a helper shared between two files that assert
    // unrelated things is a third thing to keep true.

    private static let panelPath = "Sources/LumenApp/DetailPanel.swift"

    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LumenCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <package>
    }

    private static func stripped(_ relativePath: String) -> String {
        let url = Self.root.appendingPathComponent(relativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("\(relativePath) not found at \(url.path) — if the file moved, move "
                    + "this scan with it rather than deleting it")
            return ""
        }
        return withoutComments(text)
    }

    private static func captureSection() -> String {
        let panel = stripped(panelPath)
        let section = member("private var captureSection: some View {",
                                 of: panel, in: "DetailPanel.swift")
        return condensed(section)
    }

    private static func swiftFiles(under relativePath: String) -> [URL] {
        let base = Self.root.appendingPathComponent(relativePath)
        var found: [URL] = []
        let walk = FileManager.default.enumerator(at: base,
                                                  includingPropertiesForKeys: nil)
        while let next = walk?.nextObject() as? URL {
            if next.pathExtension == "swift" { found.append(next) }
        }
        return found.sorted { $0.path < $1.path }
    }

    /// The text of one member declaration, from its `decl` line to the next member.
    private static func member(_ decl: String, of source: String, in file: String,
                               function: StaticString = #function) -> String {
        guard let start = source.range(of: decl) else {
            XCTFail("`\(decl)` not found in \(file). If it was renamed, rename it here: "
                    + "\(function) asserts something about that member and silently "
                    + "scanning nothing is how this defect survived in the first place")
            return ""
        }
        var end = source.endIndex
        let after = source[start.upperBound...]
        for marker in ["\n    private var ", "\n    private func ",
                       "\n    var ", "\n    func ", "\n    @ViewBuilder"] {
            if let hit = after.range(of: marker), hit.lowerBound < end {
                end = hit.lowerBound
            }
        }
        return condensed(String(source[start.lowerBound..<end]))
    }

    /// A window of `limit` characters from `anchor`, for the two scans whose subject is
    /// a function in a file this test does not otherwise own.
    private static func slice(from anchor: String, in source: String, of file: String,
                              limit: Int = 4_000) -> String {
        guard let start = source.range(of: anchor) else {
            XCTFail("`\(anchor)` not found in \(file) — if it was renamed, move this "
                    + "scan with it rather than deleting it")
            return ""
        }
        return condensed(String(source[start.lowerBound...].prefix(limit)))
    }

    private static func count(of needle: String, in source: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var total = 0
        var index = source.startIndex
        while let hit = source.range(of: needle, range: index..<source.endIndex) {
            total += 1
            index = hit.upperBound
        }
        return total
    }

    /// Runs of whitespace to one space, so an assertion about a phrase is not an
    /// assertion about where the 90-column rule happened to wrap it.
    private static func condensed(_ text: String) -> String {
        var out = ""
        var space = false
        for character in text {
            if character == " " || character == "\n" || character == "\t" {
                if !space { out.append(" ") }
                space = true
            } else {
                out.append(character)
                space = false
            }
        }
        return out
    }

    /// Comments blanked, string bodies kept, length and newlines preserved.
    ///
    /// The same walk `CanvasEditScopeTests` uses and for the same reason: a `//` inside
    /// a string and a `"` inside a comment each break the other's regex, so one pass
    /// that understands both is the only correct shape. String bodies survive because
    /// one assertion here is about the sentence the photographer reads on the panel.
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
                blank(i, j)
                i = j
            } else if c == "/" && next == "*" {
                var j = i + 2
                while j + 1 < n && !(out[j] == "*" && out[j + 1] == "/") { j += 1 }
                let end = Swift.min(j + 2, n)
                blank(i, end)
                i = end
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
}
