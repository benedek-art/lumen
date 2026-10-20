// ExportSizingNaming.swift
// The export sheet's sizing and naming decisions, in LumenCore so they are tested on
// Linux: what a resize-mode change does to the stored numbers, how the recipe row
// summarises the size, and which per-recipe and per-batch values the naming tokens read.

import Foundation

extension ExportRecipe {

    /// Switch the resize mode the way the sheet's menu does.
    ///
    /// `resizeValue` is one field read in three units (px, MP, %), so a change of unit
    /// resets it to the new mode's default instead of carrying the number across — the
    /// 2048 of a web preset is two gigapixels as Megapixels and a 20× enlargement as a
    /// percentage. Entering a box mode from a single-side pixel mode makes the box
    /// square on the old number, which delivers what the long-edge setting delivered
    /// until the photographer edits the second side.
    ///
    /// Don't resize has no unit and leaves the number where it was, so a trip through it
    /// does not reset Long edge 1600 to 2048. Coming back from it to a pixel mode keeps
    /// a number that can only be pixels (320…30000); a parked Megapixels 24 or 50 % is
    /// reset as before.
    public mutating func setResizeMode(_ mode: ResizeMode) {
        let old = resizeMode
        resizeMode = mode
        if old.unit != mode.unit && mode != .none {
            let keepsPixels = old == .none && mode.unit == .pixels
                && resizeValue >= 320 && resizeValue <= 30000
            if !keepsPixels { resizeValue = mode.defaultValue }
        }
        if mode.usesBox && !old.usesBox {
            resizeHeight = resizeValue
        }
    }

    /// The size clause of the recipe row, or nil for Don't resize. The four single-side
    /// pixel modes and Megapixels read exactly as before ("Long edge 2048px").
    public var resizeSummary: String? {
        func whole(_ value: Double) -> String {
            value.isFinite && abs(value) < 1e9 ? String(Int(value.rounded())) : "?"
        }
        switch resizeMode {
        case .none:
            return nil
        case .fitWithin, .dimensions:
            return resizeMode.displayName + " " + whole(resizeValue) + "×"
                + whole(resizeHeight) + "px"
        case .percent:
            return resizeMode.displayName + " " + whole(resizeValue) + "%"
        case .megapixels:
            return resizeMode.displayName + " " + whole(resizeValue) + "MP"
        case .longEdge, .shortEdge, .width, .height:
            return resizeMode.displayName + " " + whole(resizeValue) + "px"
        }
    }
}

extension ExportNamingContext {

    /// This photo's context for one recipe of a batch of `batchCount` photos: the
    /// recipe's name, its `{seq}` for the photo at 0-based `photoIndex`, its `{custom}`
    /// text, and the batch values `{total}` and `{seq:auto}` read. The exporter and the
    /// sheet's preview both come through here, so the preview is the written name.
    public func forRecipe(_ recipe: ExportRecipe, photoIndex: Int,
                          batchCount: Int) -> ExportNamingContext {
        var context = self
        context.recipeName = recipe.name
        context.sequence = recipe.sequenceNumber(forPhotoAt: photoIndex)
        context.customText = recipe.customText
        if batchCount > 0 {
            context.batchCount = batchCount
            context.lastSequence = recipe.sequenceNumber(forPhotoAt: batchCount - 1)
        } else {
            context.batchCount = nil
            context.lastSequence = nil
        }
        return context
    }
}
