// SoftProofExportTests.swift
// What survives the trip from the screen to the file, and what must not.
//
// `PipelineRenderer.exportedImage` built its render plan with no `softProof:` argument,
// so ⇧S proofed the loupe and the exported file rendered against the working space —
// ColorSync then converted it at write time and clipped each channel independently,
// which is the one mapping a proof exists to replace. The photographer approved one
// picture and received another.
//
// Threading the settings through is half a fix. The other half is that a soft proof is
// two different kinds of thing wearing one switch:
//
//   · a TRANSFORM — a destination gamut and a rendering intent, a decision about what
//     happens to colours the file cannot hold. That belongs in the delivery;
//   · two INSTRUMENTS — the gamut warning, which paints flat grey over every pixel the
//     destination cannot store, and the paper-white simulation, which squeezes the
//     picture into a print's own range so the screen can show how flat it will look.
//     Neither belongs in a delivery, and the first one is catastrophic there.
//
// The fix lives in `Sources/LumenPipeline/PipelineRenderer.swift`, which does not build
// on this lane (no Core Image), so this file is in two halves, in the shape
// `ScopeHonestyTests` established:
//
//   · the SEMANTICS, run for real against LumenCore — the same `SoftProof`,
//     `SoftProofTransform`, `RenderPlan` and `ReferenceRenderer` the shipped export
//     path composes, asked what each of those two decisions is actually worth in
//     pixels;
//   · a TEXT SCAN of the shipped file with comments stripped, because the comments
//     there name every symbol below and would otherwise let the scan pass its own
//     substitution proof.

import Foundation
import XCTest
@testable import LumenCore

final class SoftProofExportTests: XCTestCase {

    /// A viewing proof as a photographer checking a print would actually set it:
    /// proofing to sRGB, warning on so the unprintable colours are findable, paper
    /// simulated so the flatness is visible.
    private let viewing = SoftProof(enabled: true, space: .srgb, intent: .perceptual,
                                    showGamutWarning: true, simulatePaperWhite: true)

    /// The same proof as it must reach a file — `PipelineRenderer.deliveredProof(_:)`
    /// spelled out.
    ///
    /// It is spelled rather than called because LumenPipeline is not built on this lane,
    /// which means the semantics below are a statement about what the shipped function
    /// MUST do and not proof that it does it. The scan at the bottom of this file is the
    /// half that checks the shipped file still says it.
    private var delivered: SoftProof {
        var proof = viewing
        proof.showGamutWarning = false
        proof.simulatePaperWhite = false
        return proof
    }

    /// A scene-linear colour that forms into a green sRGB cannot store, and a neutral
    /// every destination can. Both halves, always: a transform that did nothing would
    /// pass the neutral assertion alone, and one that tinted everything would pass the
    /// green one.
    private let unstorable = RGB(0.02, 1.2, 0.02)
    private let neutral = RGB(gray: 0.18)

    // MARK: - The transform is the half that ships

    /// The delivered proof still has to MAP. This is the assertion that fails if
    /// "strip the screen aids" is implemented as "strip the proof".
    func testTheDeliveredProofStillMapsWhatTheDestinationCannotHold() {
        let plain = RenderPlan(recipe: Recipe())
        let export = RenderPlan(recipe: Recipe(), softProof: delivered)
        XCTAssertNotNil(export.softProof,
                        "the delivery must carry a proof, or the file is not the "
                            + "picture that was approved")

        let before = plain.referenceColor(unstorable)
        let after = export.referenceColor(unstorable)
        XCTAssertGreaterThan(after.maxAbsDifference(before), 0.05,
                             "the delivered proof left a colour sRGB cannot hold exactly "
                                 + "where the unproofed render put it: \(after)")
        XCTAssertLessThan(export.referenceColor(neutral)
                            .maxAbsDifference(plain.referenceColor(neutral)), 0.01,
                          "a proof that moves a neutral is not a proof")
    }

    /// And the destination and the intent have to be the photographer's, not a default.
    /// Dropping `intent` would leave a plausible picture — every out-of-gamut colour
    /// still lands inside sRGB — that is nonetheless the wrong one: the colorimetric
    /// intent clips per channel and rotates a saturated blue toward purple, which is the
    /// exact failure the perceptual intent was chosen to avoid.
    func testTheDeliveredProofCarriesTheDestinationAndTheIntent() {
        XCTAssertEqual(delivered.space, viewing.space)
        XCTAssertEqual(delivered.intent, viewing.intent)
        XCTAssertTrue(delivered.enabled)

        var colorimetric = delivered
        colorimetric.intent = .relativeColorimetric
        let blue = RGB(0.03, 0.05, 0.95)
        let perceptual = SoftProofTransform(delivered).mapped(blue)
        let clipped = SoftProofTransform(colorimetric).mapped(blue)
        XCTAssertGreaterThan(perceptual.maxAbsDifference(clipped), 0.01,
                             "the two intents are the same function here, so carrying "
                                 + "`intent` into the delivery would prove nothing")
    }

    // MARK: - The instruments are the half that must not

    /// THE ONE THAT WOULD RUIN A DELIVERY. The warning is flat grey painted over every
    /// unstorable pixel; baked into a file it replaces the photograph with the
    /// instrument, and a batch of two hundred would go to a client with grey blocks
    /// where the flowers were.
    func testTheGamutWarningCannotReachAFile() {
        let screen = RenderPlan(recipe: Recipe(), softProof: viewing)
        let file = RenderPlan(recipe: Recipe(), softProof: delivered)

        let flag = SoftProof.warningColor
        XCTAssertLessThan(screen.referenceColor(unstorable).maxAbsDifference(flag), 0.12,
                          "the viewing proof has to flag it, or the contrast below is "
                              + "between two things that both do nothing")
        XCTAssertGreaterThan(file.referenceColor(unstorable).maxAbsDifference(flag), 0.12,
                             "the delivered file was painted with the gamut warning")

        // And the machinery that draws it is not merely unused, it is not built:
        // `finishLUTBeforeProof` is the second table the flag needs, and a delivery
        // must not pay a 35 937-sample bake for an instrument it may not draw.
        XCTAssertNotNil(screen.finishLUTBeforeProof)
        XCTAssertNil(file.finishLUTBeforeProof,
                     "an export that keeps the unproofed table is an export that can "
                         + "still be made to draw the flag")

        // The whole frame, through the renderer that applies the plan, because a stage
        // can be correct and unreached.
        let source = ImageBuffer(width: 16, height: 4) { u, _ in
            u < 0.5 ? RGB(0.02, 1.1, 0.02) : RGB(gray: 0.18)
        }
        let onScreen = ReferenceRenderer.render(source, plan: screen)
        let inFile = ReferenceRenderer.render(source, plan: file)
        XCTAssertLessThan(onScreen[2, 2].maxAbsDifference(flag), 0.02)
        XCTAssertGreaterThan(inFile[2, 2].maxAbsDifference(flag), 0.05,
                             "the delivered frame's unstorable half is the warning "
                                 + "colour: \(inFile[2, 2])")

        // The in-gamut half, against the UNPROOFED render rather than against the
        // viewing one. Measured, the two proofed renders differ by 0.0052 on this
        // neutral — and that difference is the paper simulation doing exactly what the
        // test below it says it does, so comparing the file to the screen here would be
        // asserting that the delivery is wrong.
        let unproofed = ReferenceRenderer.render(source, plan: RenderPlan(recipe: Recipe()))
        XCTAssertLessThan(inFile[13, 2].maxAbsDifference(unproofed[13, 2]), 0.005,
                          "the delivery moved an in-gamut neutral: \(inFile[13, 2]) "
                              + "against \(unproofed[13, 2])")
    }

    /// THE ONE THAT IS EASY TO GET WRONG. The paper simulation is not a conversion, it
    /// is a picture of what a print looks like: white comes down to the sheet's
    /// reflectance and black comes up to the ink's. A file that arrives already
    /// compressed into that range gets compressed a second time by the paper itself and
    /// prints muddy — and the photographer's answer to a flat proof, more contrast in
    /// Develop, is in the recipe and therefore already in the file.
    func testThePaperSimulationIsNotBakedIntoAFile() {
        let screen = SoftProofTransform(viewing)
        let file = SoftProofTransform(delivered)

        let white = RGB(gray: 1)
        XCTAssertEqual(screen.mapped(white).g, SoftProof.paperWhite, accuracy: 1e-6,
                       "the viewing proof brings white down to the sheet")
        XCTAssertEqual(file.mapped(white).g, 1, accuracy: 1e-6,
                       "the delivered file's white is the file's white")

        let black = RGB(gray: 0)
        XCTAssertEqual(screen.mapped(black).g, SoftProof.inkBlack, accuracy: 1e-6)
        XCTAssertEqual(file.mapped(black).g, 0, accuracy: 1e-6,
                       "a delivery that arrives with the ink's black already in it "
                           + "prints its shadows twice")

        // The size of what is being dropped, on the record, so the drop is a decision
        // rather than an oversight: 12% of display white off the top and 2% on the
        // bottom is a visibly flatter file, not a rounding difference.
        XCTAssertEqual(1 - SoftProof.paperWhite, 0.12, accuracy: 1e-9)
        XCTAssertEqual(SoftProof.inkBlack, 0.02, accuracy: 1e-9)
    }

    // MARK: - The shipped files have to take these paths

    /// The export plan must be built WITH the proof, and with the delivered form of it.
    /// This is the scan that goes red the moment `softProof:` comes back off the export
    /// call site, which is the state the tree was found in.
    func testTheExportPlanIsBuiltWithTheDeliveredProof() throws {
        let source = Self.stripped(try Self.pipelineSource())

        let plan = try Self.body(of: "func exportPlan(", in: source,
                                 upTo: "static func deliveredProof(")
        XCTAssertTrue(plan.contains("softProof: Self.deliveredProof(softProof)"),
                      "the export plan has to carry the proof, in its delivered form")
        XCTAssertTrue(plan.contains("lutSize: LUT3D.exportSize"),
                      "and still be the delivery-quality plan it was")

        let image = try Self.body(of: "func exportedImage(", in: source,
                                  upTo: "static func applyDither(")
        XCTAssertTrue(image.contains("exportPlan(source: source, recipe: recipe"),
                      "the export render has to go through that plan and not build "
                          + "its own")
        XCTAssertTrue(image.contains("softProof: softProof"),
                      "and hand it the session's proof rather than nothing")
    }

    /// Both instruments, dropped, in the one function that is allowed to decide it.
    func testTheDeliveredProofDropsBothScreenAids() throws {
        let source = Self.stripped(try Self.pipelineSource())
        let function = try Self.body(of: "static func deliveredProof(", in: source,
                                     upTo: "public struct PreviewDelivery")
        XCTAssertTrue(function.contains("showGamutWarning = false"),
                      "the gamut warning must be forced off for a delivery")
        XCTAssertTrue(function.contains("simulatePaperWhite = false"),
                      "and so must the paper simulation")
        XCTAssertFalse(function.contains(".space = "),
                       "the destination is the photographer's and must not be rewritten")
        XCTAssertFalse(function.contains(".intent = "),
                       "nor the rendering intent")
        // And what comes back is the edited proof, not nothing. A `deliveredProof` that
        // returned nil for every input would satisfy "the warning cannot reach a file"
        // by deleting the proof, which is the other way to get this wrong.
        XCTAssertTrue(function.contains("var delivered = viewing"))
        XCTAssertTrue(function.contains("return delivered"),
                      "the delivery has to get the proof back, not an absence of one")
    }

    /// The delivered path is only ever created by a rename.
    ///
    /// Handing an encoder the destination URL means the file exists, under its final
    /// name, from the first byte written until the last — so anything that stops the
    /// write leaves a truncated photograph that opens, looks like a delivery, and
    /// permanently claims the name against `ExportRecipe.disambiguated`.
    func testAnEncoderIsNeverHandedTheDeliveryPath() throws {
        let source = Self.stripped(try Self.pipelineSource())
        let write = try Self.body(of: "private func write(_ image: CIImage", in: source,
                                  upTo: "static func partialURL(")

        // `of: prepared, to:` is the encoder's own shape, which is what makes this
        // exact rather than a search for the word "destination" — the rename below
        // names the destination legitimately, and it is the one line that may.
        XCTAssertEqual(write.components(separatedBy: "of: prepared, to: destination")
                        .count - 1, 0,
                       "an encoder was handed the delivery path: a stopped write leaves "
                           + "a truncated file under the name of a finished one")
        // Four formats, five calls — HEIC branches on depth. Counted rather than merely
        // "contains", so fixing one branch and leaving the others is caught.
        XCTAssertEqual(write.components(separatedBy: "of: prepared, to: partial")
                        .count - 1, 5,
                       "every encoder branch has to write to the temp file")
        XCTAssertTrue(write.contains("moveItem(at: partial, to: destination)"),
                      "and the delivery is the rename")
        XCTAssertTrue(write.contains("removeItem(at: partial)"),
                      "every exit that is not the rename has to take the temp with it")
    }

    /// A batch that cannot be stopped is the other half of the same promise: the reason
    /// a half-written file matters is that something stops the write, and until now the
    /// only thing that could was quitting the app.
    func testTheExportSheetOffersAWayToStopTheBatch() throws {
        let sheet = Self.stripped(try Self.appSource("ExportSheet.swift"))
        XCTAssertTrue(sheet.contains("state.cancelExport()"),
                      "the sheet has to be able to ask the batch to stop")
        XCTAssertTrue(sheet.contains("Cancel"),
                      "and to say so on a control a photographer can press")
        XCTAssertFalse(sheet.contains("Text(\"Exporting — \\(Int((clampedProgress"),
                      "the caption has to stop claiming a percentage once a stop has "
                          + "been asked for")
    }

    // MARK: - Reading the shipped sources

    private static func pipelineSource() throws -> String {
        try packageSource("Sources/LumenPipeline/PipelineRenderer.swift")
    }

    private static func appSource(_ name: String) throws -> String {
        try packageSource("Sources/LumenApp/" + name)
    }

    private static func packageSource(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative),
                          encoding: .utf8)
    }

    /// The text between a declaration and the next landmark. Bounded by a landmark
    /// rather than by counting braces because a brace counter over Swift source is a
    /// parser, and a wrong one would fail this file rather than the code it guards.
    private static func body(of declaration: String, in source: String,
                             upTo landmark: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: declaration),
                                  "\(declaration) is gone from the shipped file")
        let rest = source[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: landmark),
                                "\(landmark) no longer follows \(declaration)")
        return String(rest[..<end.lowerBound])
    }

    /// Comments blanked, so a doc comment naming a symbol cannot let a scan above pass
    /// its own substitution proof — `PipelineRenderer.swift` names every one of them.
    private static func stripped(_ source: String) -> String {
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
}
