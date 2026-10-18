#if os(macOS)
import Foundation
import LumenCore

/// A registration result can predate edits made to the still-visible old roll.
/// Keep only fields changed locally, and only while the original identity agrees.
enum FolderScanReconciliation {
    static func merge(row: CatalogService.StoredState?, before: PhotoItem, current: PhotoItem?,
                      openingRecipe: Recipe?, currentRecipe: Recipe?) -> CatalogService.StoredState? {
        guard let current, let id = before.catalogID, current.catalogID == id,
              current.id == before.id, current.sourceIdentity == before.sourceIdentity,
              var row, row.catalogID == id, !row.recipeUnavailable,
              row.sourceIdentity == before.sourceIdentity else { return row }
        if currentRecipe != openingRecipe { row.recipe = currentRecipe }
        if current.flag != before.flag { row.flag = current.flag }
        if current.rating != before.rating { row.rating = current.rating }
        if current.label != before.label { row.label = current.label }
        return row
    }
}
#endif
