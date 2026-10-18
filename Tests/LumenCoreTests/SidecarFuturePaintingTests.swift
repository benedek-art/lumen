import XCTest
@testable import LumenCore

final class SidecarFuturePaintingTests: XCTestCase {
    func testFutureRecipeAndOpaquePaintingSurviveOlderRecipeAndPaintingPublication() throws {
        let futureVersion = supportedPipelineVersion + 1
        let futureJSON = "{\"futureBrushEngine\":{\"painting\":\"future-ref\",\"version\":99}}"
        let opaquePainting = "opaque-future-painting-v99"
        var external = SidecarContent(rating: 0, pipelineVersion: futureVersion,
                                      recipeFingerprint: "future-fingerprint", recipeJSON: futureJSON,
                                      strokesPayload: opaquePainting)
        external.keywords = ["Existing"]
        let document = XMPSidecar.serialize(external)
        // Both an incomplete older painting and an explicit clear used to destroy
        // the payload belonging to the future recipe that the same flush preserved.
        for olderPainting in [Optional("older-partial-painting"), nil] {
            var queued = SidecarContent(rating: 4, flag: .pick, label: "green",
                                        pipelineVersion: supportedPipelineVersion,
                                        recipeFingerprint: "older-fingerprint", recipeJSON: "{}",
                                        strokesPayload: olderPainting)
            queued.keywordEdit = SidecarKeywordEdit(added: ["Added"])
            let fresh = try XCTUnwrap(XMPSidecar.parse(document))
            let fields: SidecarStatedFields = [.rating, .flag, .label, .recipe, .strokes, .keywords]
            let honoured = XMPSidecar.writableFields(fields, documentVersion: fresh.pipelineVersion)
            let content = XMPSidecar.reseed(queued, fields: honoured, onto: fresh)
            let written = try XCTUnwrap(XMPSidecar.update(document, with: content))
            let result = try XCTUnwrap(XMPSidecar.parse(written))
            XCTAssertEqual(result.strokesPayload, opaquePainting,
                           "the protected future recipe must retain its own opaque painting")
            XCTAssertEqual(result.recipeJSON, futureJSON)
            XCTAssertEqual(result.recipeFingerprint, "future-fingerprint")
            XCTAssertEqual(result.pipelineVersion, futureVersion)
            XCTAssertEqual(result.rating, 4)
            XCTAssertEqual(result.flag, .pick)
            XCTAssertEqual(result.label, "green")
            XCTAssertEqual(Set(result.keywords ?? []), ["Existing", "Added"])
        }
    }
}
