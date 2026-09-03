// MaskRasterKeyTests.swift
// F2-01: a mask raster's cache key must name the PHOTOGRAPH, with no condition on it.
//
// `MaskRasterCache.plane` serves an exact key hit to any identity — it adopts the
// identity it is handed rather than comparing it — on the stated ground that "the key
// contains the file url wherever pixels are read, so an exact hit cannot lie". So the
// whole guard against one photograph wearing another's mask is a property of the KEY,
// and the key is built in `PipelineRenderer.makeGraph`.
//
// It did not hold that property. The url went into the key only inside
// `if source != nil`, and `source` is nil whenever `maskSource`'s `needsPicture` is
// false — which asks `MaskKind.readsSourceImage`, which is false for every AI kind and
// for `depthRange`, correctly, because those read a cached Vision matte rather than the
// decode. A matte is the most photograph-specific thing in the engine, so the single
// question that decided whether the file was named was the one question that does not
// decide it. A Subject mask with Follow at 0 keyed as `maskJSON|1024x682||aiSubject|-`:
// `maskJSON` is the mask DEFINITION, which Paste Settings copies verbatim, ids and all;
// `1024x682` is what every 3:2 frame drafts at, whatever the sensor; `aiSubject` is the
// matte's KIND NAME, not its pixels; `-` is the absent picture fingerprint. Nothing in
// it is the file. Two frames of a sequence collided and the second one's subject
// brightened where the first one's subject had been, in the loupe and in the JPEG.
//
// WHY THIS TEST IS A TEXT SCAN. `LumenPipeline` is `#if os(macOS)` and has no test
// target that runs on this lane, so the key builder cannot be called from here. It is
// read as source instead — WITH COMMENTS STRIPPED, which is not a detail: the file
// explains this defect at length in prose that names `sourceURL` and
// `renderIdentity` many times over, so a scan over the raw text would be satisfied by
// the explanation of the term it is meant to find present. That mistake has been made
// twice in this repository (see `EditRevisionRuleTests`), and it makes a test pass its
// own substitution proof.
//
// WHAT IS DELIBERATELY NOT ASSERTED HERE: that `MaskKind.readsSourceImage` is false for
// the AI kinds. It is, today, and that is the reachability argument above — but it is
// also the WRONG thing to depend on. The point of the fix is that the raster key does
// not consult that property, or any other per-kind predicate, so this test must not
// either. If someone later makes the AI kinds read the picture, the key is still right
// and this file still passes.

import XCTest
@testable import LumenCore

final class MaskRasterKeyTests: XCTestCase {

    // MARK: - The rule

    /// The photograph is a term of the key, always, on every path.
    func testTheRasterKeyAlwaysNamesThePhotograph() throws {
        let body = try Self.keyBuilderBody()

        // The url reaches the key by SOME spelling — either the raw string or the
        // shared `PlanTableCache.renderIdentity(for:)` the cache's own identity check
        // uses. Both are accepted, because which of the two is a refactor; having
        // neither is the defect.
        let namesTheFile = body.contains("renderIdentity(for: sourceURL)")
            || body.contains("sourceURL.absoluteString")
        XCTAssertTrue(namesTheFile,
                      "the mask raster key no longer contains the photograph. Every "
                      + "other term collides across photographs by design — the mask "
                      + "DEFINITION travels verbatim through Paste Settings, the "
                      + "raster size is 1024x682 for every 3:2 frame at draft, and the "
                      + "matte term is the kind NAME (aiSubject), not the matte. "
                      + "MaskRasterCache serves an exact key hit to any identity "
                      + "without comparing it, so with the file gone from the key one "
                      + "photograph's subject matte renders on a different "
                      + "photograph, in the loupe and in the delivered file, with "
                      + "nothing badged. Key builder body was:\n" + body)

        // And it is not gated. The defect was not a missing term, it was a term
        // behind a condition that asked the wrong question; a key that names the file
        // only sometimes is the same defect with a different predicate.
        for token in ["if ", "guard ", "??", "? "] {
            XCTAssertFalse(body.contains(token),
                           "the raster key has a `\(token.trimmingCharacters(in: .whitespaces))` "
                           + "in it. The photograph must be in the key "
                           + "UNCONDITIONALLY: the previous version put it behind "
                           + "`if source != nil`, which is false for exactly the "
                           + "matte-backed masks whose raster is most specific to one "
                           + "photograph — so the branch that looked like an "
                           + "optimisation was the branch that let one photograph wear "
                           + "another's matte. Key builder body was:\n" + body)
        }
    }

    /// Not just present — impossible to leave out. The photograph is a required,
    /// non-optional parameter of the only function that spells a raster key.
    func testThePhotographIsARequiredParameterOfTheKey() throws {
        let source = try Self.pipelineSource()
        guard let start = source.range(of: "static func maskRasterKey(") else {
            return XCTFail(
                "there is no single place that builds a mask raster key. F2-01 was a "
                + "key assembled inline from whatever terms were in scope, where the "
                + "photograph was one optional contributor among five and the branch "
                + "that dropped it read as reasonable. One builder, taking the "
                + "photograph as a required argument, is what makes a key with no "
                + "photograph in it unwriteable.")
        }
        guard let arrow = source.range(of: "-> String", range: start.upperBound..<source.endIndex) else {
            return XCTFail("maskRasterKey has no return type; the scan cannot read its "
                           + "signature")
        }
        let signature = String(source[start.upperBound..<arrow.lowerBound])

        XCTAssertTrue(signature.contains("sourceURL: URL"),
                      "maskRasterKey does not take the photograph. A caller that does "
                      + "not have to supply the file can build a key without it, which "
                      + "is how one photograph came to wear another's mask. "
                      + "Signature was: " + signature)
        XCTAssertFalse(signature.contains("sourceURL: URL?"),
                       "the photograph is OPTIONAL in maskRasterKey. `nil` is the "
                       + "omission this fix removed — an optional parameter restores "
                       + "it, and the caller that passes nil will look as locally "
                       + "reasonable as `if source != nil` did. "
                       + "Signature was: " + signature)
    }

    /// The builder is the only door. A second, inline key would be outside the rule
    /// above and could omit the file again without any of this noticing.
    func testTheRenderBuildsItsKeyThroughTheBuilder() throws {
        let source = try Self.pipelineSource()

        XCTAssertTrue(source.contains("maskRasterKey(sourceURL: sourceURL"),
                      "makeGraph does not build its raster key through maskRasterKey. "
                      + "Whatever it builds instead is not covered by the "
                      + "unconditional-photograph rule, and MaskRasterCache trusts the "
                      + "key completely: an exact hit is served to any photograph.")
        XCTAssertFalse(source.contains("let key = [maskJSON"),
                       "the inline key literal is back in makeGraph. That is the exact "
                       + "shape of F2-01: five terms joined by hand, the photograph "
                       + "optional among them, and no one place to state the rule.")

        // The cache is handed the same identity the key names. Two spellings of "which
        // photograph" is how the key and the stale-borrow check drift apart.
        guard let call = source.range(of: "maskRasters.plane(") else {
            return XCTFail("the render no longer consults MaskRasterCache; if the cache "
                           + "moved, move this scan with it")
        }
        let arguments = String(source[call.upperBound...].prefix(400))
        XCTAssertTrue(arguments.contains("identity:"),
                      "the raster lookup no longer passes an identity, so the stale "
                      + "door — the one check that DOES compare photographs — has "
                      + "nothing to compare. Call site was: " + arguments)
    }

    // MARK: - The premise, pinned

    /// Why the matte term cannot stand in for the file. `mattesKey` is the dictionary's
    /// KEYS — `aiSubject`, `aiSky` — which are identical for any two photographs
    /// carrying the same mask. It reads like a photograph-specific term and is not one,
    /// and that is most of how F2-01 survived review.
    ///
    /// If this ever becomes a content hash of the mattes themselves, this assertion is
    /// the thing to update — but the photograph stays in the key regardless, because a
    /// matte-free mask still rasterizes from one photograph's decode.
    func testTheMatteTermNamesKindsNotPixels() throws {
        let source = try Self.pipelineSource()
        XCTAssertTrue(source.contains("aiMattes.keys.sorted()"),
                      "the matte term changed shape. It used to be the matte kind "
                      + "NAMES, which is why it could not distinguish two "
                      + "photographs; check that whatever replaced it does not now "
                      + "look like a licence to drop the file url from the key.")
    }

    // MARK: - helpers

    /// The body of `maskRasterKey`, braces matched, comments already gone.
    private static func keyBuilderBody() throws -> String {
        let source = try pipelineSource()
        guard let declaration = source.range(of: "static func maskRasterKey(") else {
            XCTFail("no maskRasterKey to read — see "
                    + "testThePhotographIsARequiredParameterOfTheKey for what that "
                    + "means")
            return ""
        }
        guard let open = source.range(of: "{", range: declaration.upperBound..<source.endIndex)
        else {
            XCTFail("maskRasterKey has no body")
            return ""
        }
        var depth = 0
        var index = open.lowerBound
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { break }
            }
            index = source.index(after: index)
        }
        return String(source[open.upperBound..<index])
    }

    private static func pipelineSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LumenPipeline/PipelineRenderer.swift")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("Sources/LumenPipeline/PipelineRenderer.swift not found — if it "
                    + "moved, move this scan with it")
            return ""
        }
        return strippingComments(raw)
    }

    /// Comments out before anything is looked for. The file argues this defect at
    /// length in prose containing every symbol below, so a scan over the raw text
    /// would be satisfied by the argument for the code rather than by the code.
    private static func strippingComments(_ source: String) -> String {
        var out = ""
        var index = source.startIndex
        var inBlock = false
        while index < source.endIndex {
            let rest = source[index...]
            if inBlock {
                if rest.hasPrefix("*/") { inBlock = false; index = source.index(index, offsetBy: 2) }
                else { index = source.index(after: index) }
                continue
            }
            if rest.hasPrefix("/*") { inBlock = true; index = source.index(index, offsetBy: 2); continue }
            if rest.hasPrefix("//") {
                while index < source.endIndex, source[index] != "\n" { index = source.index(after: index) }
                continue
            }
            out.append(source[index])
            index = source.index(after: index)
        }
        return out
    }
}
