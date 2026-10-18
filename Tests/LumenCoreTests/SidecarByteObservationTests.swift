import XCTest
@testable import LumenCore

final class SidecarByteObservationTests: XCTestCase {
    private func fixture(pending: Bool = false) throws -> (SidecarMerge.State, SidecarContent, Recipe) {
        var incoming = Recipe(); incoming.develop.tone.exposure = 1.25
        return (SidecarMerge.State(recipe: Recipe(), sidecarMTime: 123, hasUnflushedEdits: pending),
                SidecarContent(recipeJSON: try CanonicalJSON.canonicalRecipeJSON(incoming)), incoming)
    }

    func testExplicitByteChangeDetectsAnEqualTimestampRewrite() throws {
        let (catalog, external, incoming) = try fixture()
        let result = SidecarMerge.resolve(catalog: catalog, sidecar: external,
                                          sidecarMTime: 123, sidecarChanged: true)
        XCTAssertEqual(result.decision, .sidecarWins)
        XCTAssertEqual(result.state.recipe, incoming)
    }

    func testExplicitByteChangePreservesPendingCatalogPrecedenceAndConflict() throws {
        let (catalog, external, _) = try fixture(pending: true)
        let result = SidecarMerge.resolve(catalog: catalog, sidecar: external,
                                          sidecarMTime: 123, sidecarChanged: true)
        XCTAssertEqual(result.decision, .conflictCatalogWins)
        XCTAssertEqual(result.state.recipe, catalog.recipe)
        XCTAssertEqual(result.unpreservedSidecar, external)
    }

    func testIdenticalBytesDoNotBecomeAConflictBecauseTheirTimestampChanged() throws {
        let (catalog, external, _) = try fixture(pending: true)
        let result = SidecarMerge.resolve(catalog: catalog, sidecar: external,
                                          sidecarMTime: 999, sidecarChanged: false)
        XCTAssertEqual(result.decision, .catalogWins)
    }

    func testUnobservedLegacyCallRetainsItsTimestampContract() throws {
        let (catalog, external, _) = try fixture()
        XCTAssertEqual(SidecarMerge.resolve(catalog: catalog, sidecar: external,
                                             sidecarMTime: 123).decision, .catalogWins)
        XCTAssertEqual(SidecarMerge.resolve(catalog: catalog, sidecar: external,
                                             sidecarMTime: 999).decision, .sidecarWins)
    }
    func testExplicitByteChangeDoesNotTrustAStaleExternalFingerprint() throws {
        for pending in [false, true] {
            let (catalog, external, incoming) = try fixture(pending: pending)
            var stale = external
            stale.recipeFingerprint = try RecipeFingerprint.fingerprint(Recipe())
            let result = SidecarMerge.resolve(catalog: catalog, sidecar: stale,
                                              sidecarMTime: 123, sidecarChanged: true)
            XCTAssertEqual(result.decision, pending ? .conflictCatalogWins : .sidecarWins)
            XCTAssertEqual(result.state.recipe, pending ? catalog.recipe : incoming)
        }
    }

}
