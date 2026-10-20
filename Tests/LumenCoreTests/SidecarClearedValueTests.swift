import XCTest
@testable import LumenCore

/// docs/15 §15.5 rule 1 must not undo a CLEAR.
///
/// A recorded stamp that equals the file's mtime means the sidecar is the one we last
/// read (and absorbed) or last wrote. Anything it says that the catalog does not is
/// therefore older than the catalog — a cleared rating, flag or label whose flush has
/// not landed (inside the debounce, a crash before it, or a write that keeps failing).
/// Filling those back in turned the user's "no rating" into the old rating on every
/// folder open, and the next flush then split catalog and sidecar for good.
final class SidecarClearedValueTests: XCTestCase {

    private let stamp: Int64 = 1_800_000_000

    func testRule1DoesNotResurrectClearedFieldsFromAnUnchangedSidecar() throws {
        // Lightroom's vocabulary: three stars, picked, red label — then cleared here,
        // and the clear has not been flushed to the file yet.
        let catalog = SidecarMerge.State(rating: 0, flag: .none, label: nil,
                                         sidecarMTime: stamp, hasUnflushedEdits: true)
        let sidecar = SidecarContent(rating: 3, flag: .pick, label: "Red")

        let unchanged = SidecarMerge.resolve(catalog: catalog, sidecar: sidecar,
                                             sidecarMTime: stamp)
        XCTAssertEqual(unchanged.decision, .catalogWins)
        XCTAssertEqual(unchanged.state.rating, 0, "a cleared rating came back")
        XCTAssertEqual(unchanged.state.flag, SidecarFlag.none, "a cleared flag came back")
        XCTAssertNil(unchanged.state.label, "a cleared label came back")

        // A cleared reject (xmp:Rating -1 in Lightroom terms) is a clear like any other.
        let rejected = SidecarMerge.resolve(
            catalog: catalog, sidecar: SidecarContent(rating: 2, flag: .reject),
            sidecarMTime: stamp)
        XCTAssertEqual(rejected.state.flag, SidecarFlag.none, "a cleared reject came back")
        XCTAssertEqual(rejected.state.rating, 0)

    }

    /// Bridge rates the photo 4 while Lumen has it at 0; a recipe-only Lumen write then
    /// carries the 4 forward and stamps the file. Nothing is queued, so the stamped
    /// file's 4 is news, and it fills in.
    func testAStampedSidecarStillBringsInARatingAnotherToolAdded() throws {
        let catalog = SidecarMerge.State(rating: 0, flag: .none, label: nil,
                                         sidecarMTime: stamp, hasUnflushedEdits: false)
        let sidecar = SidecarContent(rating: 4, flag: .pick, label: "Green")
        let merged = SidecarMerge.resolve(catalog: catalog, sidecar: sidecar,
                                          sidecarMTime: stamp)
        XCTAssertEqual(merged.decision, .catalogWins)
        XCTAssertEqual(merged.state.rating, 4)
        XCTAssertEqual(merged.state.flag, .pick)
        XCTAssertEqual(merged.state.label, "Green")
    }

    /// The fill-in the clear must not cost: a row we never stamped, and a file that
    /// moved since our stamp, still bring the sidecar's values in.
    func testFillInStillWorksForUnstampedRowsAndMovedFiles() throws {
        let sidecar = SidecarContent(rating: 3, flag: .pick, label: "Red")

        let fresh = SidecarMerge.State(sidecarMTime: nil)
        let arrived = SidecarMerge.resolve(catalog: fresh, sidecar: sidecar,
                                           sidecarMTime: stamp)
        XCTAssertEqual(arrived.state.rating, 3)
        XCTAssertEqual(arrived.state.flag, .pick)
        XCTAssertEqual(arrived.state.label, "Red")

        // Edited in Lightroom since our last write: a newer file with no recipe stays
        // rule 1, and what it states where the catalog is silent fills in.
        let moved = SidecarMerge.resolve(
            catalog: SidecarMerge.State(sidecarMTime: stamp), sidecar: sidecar,
            sidecarMTime: stamp + 600)
        XCTAssertEqual(moved.decision, .catalogWins)
        XCTAssertEqual(moved.state.rating, 3)
        XCTAssertEqual(moved.state.flag, .pick)
        XCTAssertEqual(moved.state.label, "Red")
    }

    /// The recipe fill-in stays unconditional: the caller hands in a nil recipe when the
    /// stored one would not decode, and an unchanged sidecar is how that edit comes back.
    func testAnUnchangedSidecarStillRecoversAMissingRecipe() throws {
        var recipe = Recipe()
        recipe.develop.tone.exposure = 0.5
        let sidecar = SidecarContent(
            recipeJSON: try CanonicalJSON.canonicalRecipeJSON(recipe))
        let recovered = SidecarMerge.resolve(
            catalog: SidecarMerge.State(sidecarMTime: stamp), sidecar: sidecar,
            sidecarMTime: stamp)
        XCTAssertEqual(recovered.decision, .catalogWins)
        XCTAssertEqual(recovered.state.recipe, recipe)
    }
}
