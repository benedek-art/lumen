#if os(macOS)
import Foundation
import XCTest
@testable import LumenCore
@testable import LumenApp

final class FolderScanReconciliationTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/fixture/a.raw")
    private var before: PhotoItem { PhotoItem(id: url, catalogID: 7) }
    private func recipe(_ exposure: Double) -> Recipe {
        var recipe = Recipe(); recipe.develop.tone.exposure = exposure; return recipe
    }
    private var row: CatalogService.StoredState {
        CatalogService.StoredState(catalogID: 7, flag: .unflagged, rating: 0,
                                   label: nil, recipe: recipe(1), iso: nil)
    }

    func testChangedRecipeAndCullingFieldsSupersedeRegistrationSnapshot() throws {
        var current = before; current.flag = .pick; current.rating = 4; current.label = .red
        let merged = try XCTUnwrap(FolderScanReconciliation.merge(row: row, before: before,
            current: current, openingRecipe: recipe(1), currentRecipe: recipe(2)))
        XCTAssertEqual(merged.recipe?.develop.tone.exposure, 2)
        XCTAssertEqual(merged.flag, .pick)
        XCTAssertEqual(merged.rating, 4)
        XCTAssertEqual(merged.label, .red)
    }

    func testUntouchedExternalRecipeAndCullingFieldsStillWin() throws {
        var external = row; external.recipe = recipe(3); external.rating = 5; external.label = .blue
        let merged = try XCTUnwrap(FolderScanReconciliation.merge(row: external, before: before,
            current: before, openingRecipe: recipe(1), currentRecipe: recipe(1)))
        XCTAssertEqual(merged.recipe?.develop.tone.exposure, 3)
        XCTAssertEqual(merged.rating, 5)
        XCTAssertEqual(merged.label, .blue)
    }

    func testChangedRatingDoesNotReplaceUntouchedExternalRecipeOrLabel() throws {
        var external = row; external.recipe = recipe(3); external.label = .blue
        var current = before; current.rating = 4
        let merged = try XCTUnwrap(FolderScanReconciliation.merge(row: external, before: before,
            current: current, openingRecipe: recipe(1), currentRecipe: recipe(1)))
        XCTAssertEqual(merged.recipe?.develop.tone.exposure, 3)
        XCTAssertEqual(merged.rating, 4)
        XCTAssertEqual(merged.label, .blue)
    }

    func testUnavailableAndAbsentRowsCannotBeResurrectedByCachedLocalRecipe() throws {
        var unavailable = row; unavailable.recipe = nil; unavailable.recipeUnavailable = true
        let merged = try XCTUnwrap(FolderScanReconciliation.merge(row: unavailable, before: before,
            current: before, openingRecipe: recipe(1), currentRecipe: recipe(2)))
        XCTAssertTrue(merged.recipeUnavailable)
        XCTAssertNil(merged.recipe)
        XCTAssertNil(FolderScanReconciliation.merge(row: nil, before: before,
            current: before, openingRecipe: recipe(1), currentRecipe: recipe(2)))
    }

    func testChangedSourceGenerationCannotAcquireOldLocalRecipe() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data([1]).write(to: file)
        var opening = before
        opening.sourceIdentity = try XCTUnwrap(SourceFileIdentity.read(file))
        try Data([1, 2]).write(to: file)
        var replacement = row
        replacement.sourceIdentity = try XCTUnwrap(SourceFileIdentity.read(file))
        replacement.recipe = recipe(3)
        XCTAssertNotEqual(opening.sourceIdentity, replacement.sourceIdentity)
        let merged = try XCTUnwrap(FolderScanReconciliation.merge(row: replacement, before: opening,
            current: opening, openingRecipe: recipe(1), currentRecipe: recipe(2)))
        XCTAssertEqual(merged.recipe?.develop.tone.exposure, 3)
    }

    func testDifferentCatalogIdentityCannotAcquireOldLocalRecipe() throws {
        var replacement = row; replacement.catalogID = 8; replacement.recipe = recipe(3)
        let merged = try XCTUnwrap(FolderScanReconciliation.merge(row: replacement, before: before,
            current: before, openingRecipe: recipe(1), currentRecipe: recipe(2)))
        XCTAssertEqual(merged.catalogID, 8)
        XCTAssertEqual(merged.recipe?.develop.tone.exposure, 3)
    }
}
#endif
