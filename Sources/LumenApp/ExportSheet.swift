// ExportSheet.swift
// The multi-recipe export dialog (D40, docs/11 §A2): a checkbox list of recipes on the
// left, the focused recipe's settings on the right, a footer that says exactly how many
// files one Export click is about to write. Several recipes checked at once is the whole
// point — the web JPEG, the print TIFF and the HDR HEIC leave together, off one gesture.
//
// One gesture, not one render. This line used to end "off one render that forks at the
// resize node", and no render forks: each checked recipe renders the full develop chain
// from the decode (see `ExportRecipe`'s header). The footer's file count is honest; the
// time it takes scales with the number of boxes ticked.
//
// The sheet keeps no local copy of anything. Every control writes straight back into
// `state.exportRecipes`, so editing a recipe here edits it everywhere; there is no
// "apply" step and no dialog-local state to drift. Indices into the recipe array are
// never held across a view update — rows are addressed by `id` and every lookup is
// bounds-checked, because a recipe can be deleted while its editor is open.

#if os(macOS)

import AppKit
import Foundation
import LumenCore
// For `PipelineRenderer.canWriteTenBitHEIC` — the bit-depth row must not offer a
// depth this machine's encoder would then throw on, and only the pipeline can ask.
import LumenPipeline
import SwiftUI

// MARK: - Segmented option tables

private let formatOptions: [(value: ExportFormat, label: String)] =
    [(value: .jpeg, label: "JPEG"), (value: .heif, label: "HEIC"),
     (value: .tiff, label: "TIFF"), (value: .png, label: "PNG")]

/// Medium × amount is the entire sharpening surface — no radius, no amount slider.
private let sharpenMediumOptions: [(value: OutputSharpen.Medium, label: String)] =
    [(value: .none, label: "Off"), (value: .screen, label: "Screen"),
     (value: .matte, label: "Matte"), (value: .glossy, label: "Glossy")]

private let sharpenAmountOptions: [(value: OutputSharpen.Amount, label: String)] =
    [(value: .low, label: "Low"), (value: .standard, label: "Standard"),
     (value: .high, label: "High")]

private let watermarkPositionOptions: [(value: Watermark.Position, label: String)] =
    [(value: .bottomLeft, label: "BL"), (value: .bottomRight, label: "BR"),
     (value: .topLeft, label: "TL"), (value: .topRight, label: "TR"),
     (value: .centre, label: "Mid")]

private let bitDepthOptions: [(value: Int, label: String)] =
    [(value: 8, label: "8-bit"), (value: 16, label: "16-bit")]

/// HEIC's pair: HEVC has a Main 10 profile and nothing deeper, and the row only shows
/// this control at all when `PipelineRenderer.canWriteTenBitHEIC` probed true.
private let heifBitDepthOptions: [(value: Int, label: String)] =
    [(value: 8, label: "8-bit"), (value: 10, label: "10-bit")]

private let mapScaleOptions: [(value: Double, label: String)] =
    [(value: 1.0, label: "Full"), (value: 0.5, label: "Half"),
     (value: 0.25, label: "Quarter")]

// MARK: - Sheet

@MainActor
struct ExportSheet: View {
    @EnvironmentObject var state: AppState

    @State private var selectedRecipeID: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Lumen.separator)
            HStack(spacing: 0) {
                recipeColumn.frame(width: 244)
                Divider().overlay(Lumen.separator)
                editorColumn.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            Divider().overlay(Lumen.separator)
            footer
        }
        .frame(width: 800, height: 640)
        .background(Lumen.panelBackground)
        .onAppear {
            if selectedRecipeID == nil { selectedRecipeID = state.exportRecipes.first?.id }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Export")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Lumen.primaryText)
            Text(sourceSummary)
                .font(.system(size: 11))
                .foregroundStyle(Lumen.secondaryText)
            Spacer()
            Button("Close") { state.showExportSheet = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding(14)
    }

    private var sourceSummary: String {
        let count = targetPhotos.count
        if count == 0 { return "nothing selected" }
        if count == 1, let only = targetPhotos.first { return only.filename }
        return "\(count) photos selected"
    }

    // MARK: Recipe list

    private var recipeColumn: some View {
        VStack(spacing: 0) {
            HStack {
                Text("RECIPES")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Lumen.secondaryText)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 1) {
                    ForEach(state.exportRecipes) { recipe in
                        ExportRecipeRow(name: recipe.name,
                                        summary: Self.summary(of: recipe),
                                        isHDR: recipe.hdr != nil,
                                        isSelected: recipe.id == selectedRecipeID,
                                        enabled: enabledBinding(id: recipe.id),
                                        onSelect: { selectedRecipeID = recipe.id })
                    }
                }
                .padding(.bottom, 6)
            }
            // docs/30: every scroll view in the app is silent. A legacy scroller insets
            // its content, so an indicator appearing is a relayout of everything inside it.
            .scrollIndicators(.never)

            Divider().overlay(Lumen.separator)

            HStack(spacing: 12) {
                iconButton("plus", help: "New recipe", disabled: false) { addRecipe() }
                iconButton("plus.square.on.square", help: "Duplicate the selected recipe",
                           disabled: selectedRecipeID == nil) { duplicateSelectedRecipe() }
                iconButton("minus", help: "Delete the selected recipe",
                           disabled: selectedRecipeID == nil
                                     || state.exportRecipes.count <= 1) { deleteSelectedRecipe() }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func iconButton(_ symbol: String, help: String, disabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Lumen.secondaryText)
        .disabled(disabled)
        .help(help)
    }

    /// One line of prose per row, so the list is scannable without opening each editor.
    static func summary(of recipe: ExportRecipe) -> String {
        var parts: [String] = [recipe.format.rawValue.uppercased()]
        if recipe.format.supportsQuality {
            parts.append("q\(Int(recipe.quality.rounded()))")
        }
        // `effectiveBitDepth`, never the stored number: `bitDepth` can hold a value
        // this format cannot write (a 10-bit HEIC recipe switched to TIFF still
        // stores 10), and a summary claiming "10-bit TIFF" would be the lie the
        // depth-folding exists to prevent. A 10-bit HEIC is worth a word; an 8-bit
        // lossy file is the norm and says nothing.
        if recipe.format.supportsSixteenBit {
            parts.append("\(recipe.effectiveBitDepth)-bit")
        } else if recipe.effectiveBitDepth == 10 {
            parts.append("10-bit")
        }
        parts.append(recipe.colorSpace.displayName)
        if recipe.resizeMode != .none {
            let unit = recipe.resizeMode == .megapixels ? "MP" : "px"
            parts.append("\(recipe.resizeMode.displayName) "
                         + "\(Int(recipe.resizeValue.rounded()))\(unit)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Editor

    @ViewBuilder
    private var editorColumn: some View {
        if let id = selectedRecipeID, state.exportRecipes.contains(where: { $0.id == id }) {
            ExportRecipeEditor(recipe: recipeBinding(id: id),
                               previewSource: previewSourceURL,
                               previewIsPlaceholder: targetPhotos.isEmpty)
        } else {
            VStack(spacing: 6) {
                Spacer()
                Text("No recipe selected")
                    .font(.system(size: 12))
                    .foregroundStyle(Lumen.secondaryText)
                Text("Pick one on the left, or press + to make a new one.")
                    .font(.system(size: 11))
                    .foregroundStyle(Lumen.secondaryText)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.isExporting {
                VStack(alignment: .leading, spacing: 3) {
                    // Drawn, for the same reason as the checkbox above — and this one
                    // matters more, because an export bar is the one control in the app
                    // a photographer watches instead of watching a photograph, so there
                    // is nothing beside it to judge its hue against.
                    LumenProgressBar(value: clampedProgress)
                    Text("Exporting — \(Int((clampedProgress * 100).rounded()))%")
                        .font(.system(size: 10))
                        .foregroundStyle(Lumen.secondaryText)
                }
            }
            HStack(spacing: 10) {
                Text(fileCountSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(fileCount == 0 ? Lumen.secondaryText : Lumen.primaryText)
                Spacer()
                Button("Export…") { state.chooseExportDestination() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(fileCount == 0 || state.isExporting)
            }
        }
        .padding(14)
    }

    private var clampedProgress: Double { min(max(state.exportProgress, 0), 1) }

    private var checkedRecipeCount: Int { state.exportRecipes.filter({ $0.enabled }).count }

    private var fileCount: Int { targetPhotos.count * checkedRecipeCount }

    private var fileCountSummary: String {
        let photos = targetPhotos.count
        if photos == 0 { return "Select at least one photo to export." }
        if checkedRecipeCount == 0 { return "Check at least one recipe." }
        let files = fileCount
        return "\(photos) photo\(photos == 1 ? "" : "s") × "
            + "\(checkedRecipeCount) recipe\(checkedRecipeCount == 1 ? "" : "s") = "
            + "\(files) file\(files == 1 ? "" : "s")"
    }

    /// Mirrors `AppState.export(to:)`: the selection when there is one, otherwise the
    /// photo under the cursor. The footer must count exactly what the export will do.
    private var targetPhotos: [PhotoItem] {
        let selected = state.selectedPhotos
        if !selected.isEmpty { return selected }
        if let primary = state.primarySelection { return [primary] }
        return []
    }

    private var previewSourceURL: URL {
        targetPhotos.first?.id ?? URL(fileURLWithPath: "/Pictures/DSCF0001.RAF")
    }

    // MARK: Bindings into the shared recipe array

    private func recipeBinding(id: String) -> Binding<ExportRecipe> {
        let state = self.state
        return Binding(
            get: {
                state.exportRecipes.first(where: { $0.id == id })
                    ?? ExportRecipe(name: "Missing recipe")
            },
            set: { updated in
                guard let index = state.exportRecipes.firstIndex(where: { $0.id == id }),
                      state.exportRecipes.indices.contains(index) else { return }
                state.exportRecipes[index] = updated
            })
    }

    private func enabledBinding(id: String) -> Binding<Bool> {
        let state = self.state
        return Binding(
            get: { state.exportRecipes.first(where: { $0.id == id })?.enabled ?? false },
            set: { isOn in
                guard let index = state.exportRecipes.firstIndex(where: { $0.id == id }),
                      state.exportRecipes.indices.contains(index) else { return }
                state.exportRecipes[index].enabled = isOn
            })
    }

    // MARK: Recipe management

    private func addRecipe() {
        let recipe = ExportRecipe(name: "New recipe")
        state.exportRecipes.append(recipe)
        selectedRecipeID = recipe.id
    }

    private func duplicateSelectedRecipe() {
        guard let id = selectedRecipeID,
              let index = state.exportRecipes.firstIndex(where: { $0.id == id }),
              state.exportRecipes.indices.contains(index) else { return }
        var copy = state.exportRecipes[index]
        copy.id = UUID().uuidString
        copy.name = copy.name + " copy"
        state.exportRecipes.insert(copy, at: min(index + 1, state.exportRecipes.count))
        selectedRecipeID = copy.id
    }

    private func deleteSelectedRecipe() {
        guard let id = selectedRecipeID,
              let index = state.exportRecipes.firstIndex(where: { $0.id == id }),
              state.exportRecipes.indices.contains(index) else { return }
        state.exportRecipes.remove(at: index)
        selectedRecipeID = state.exportRecipes.indices.contains(index)
            ? state.exportRecipes[index].id
            : state.exportRecipes.last?.id
    }
}

// MARK: - Recipe row

@MainActor
private struct ExportRecipeRow: View {
    let name: String
    let summary: String
    let isHDR: Bool
    let isSelected: Bool
    @Binding var enabled: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            // `LumenCheckbox`, not `.toggleStyle(.checkbox)`: a checked AppKit box is
            // filled with the system accent, and this sheet is the last place in the app
            // that was still drawing one.
            LumenCheckbox(isOn: $enabled)
                .help("Include this recipe in the next export")
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(name.isEmpty ? "Untitled" : name)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(enabled ? Lumen.primaryText : Lumen.secondaryText)
                        .lineLimit(1)
                    if isHDR { LumenBadge(text: "HDR", emphasized: true) }
                }
                Text(summary)
                    .font(.system(size: 9))
                    .foregroundStyle(Lumen.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(isSelected ? Lumen.fillColor.opacity(0.22) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }
}

// MARK: - Recipe editor

@MainActor
private struct ExportRecipeEditor: View {
    @Binding var recipe: ExportRecipe
    let previewSource: URL
    let previewIsPlaceholder: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                LumenSectionHeader(title: "Recipe")
                ExportFieldRow("Name") {
                    ExportTextEntry(text: $recipe.name, placeholder: "Recipe name")
                }
                formatSection
                sizeSection
                sharpenSection
                namingSection
                metadataSection
                watermarkSection
                if recipe.format.supportsGainMap { hdrSection }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        // docs/30: every scroll view in the app is silent. A legacy scroller insets
        // its content, so an indicator appearing is a relayout of everything inside it.
        .scrollIndicators(.never)
    }

    // MARK: Menu option tables

    // The two lists that stayed lists. Format, bit depth, sharpening and watermark
    // position are four or five short words each and belong in a `LumenSegmented`,
    // where every option is visible without a click; these two are five and six
    // entries of full names, which is where a segmented strip stops fitting and a menu
    // starts being the right control. Same values, same order as the `Picker`s they
    // replace — drawn by this app.

    private var colorSpaceOptions: [LumenMenuOption<ExportColorSpace>] {
        ExportColorSpace.allCases.map { LumenMenuOption($0, $0.displayName) }
    }

    private var resizeOptions: [LumenMenuOption<ResizeMode>] {
        ResizeMode.allCases.map { LumenMenuOption($0, $0.displayName) }
    }

    // MARK: Format

    private var formatSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Format")
            ExportFieldRow("Format") {
                LumenSegmented(options: formatOptions, selection: $recipe.format)
                    .frame(maxWidth: 260)
            }
            if recipe.format.supportsQuality {
                LumenSlider(title: "Quality", value: $recipe.quality, range: 0...100,
                            defaultValue: 100,
                            step: 1, decimals: 0, bipolar: false,
                            help: "Encoder quality — 100 by default, because a "
                                + "delivery should not lose to compression unasked. "
                                + "The stock web preset stays at 90 deliberately: at "
                                + "2048 px for screens it reads identically and "
                                + "roughly halves the file.")
            }
            ExportFieldRow("Bit depth") {
                bitDepthControl
            }
            // NO GLYPHS HERE, deliberately, and `LumenMenu` says why in its own file:
            // a colour space has no shape. sRGB is not rounder than ProPhoto, and a
            // column of five identical swatches would be decoration standing where
            // information goes. The names are the whole of what there is to know.
            //
            // `LumenMenuPicker` rather than `ExportFieldRow` around a menu, because it
            // draws the label at `Lumen.labelWidth` — the same 86 points every
            // `LumenSlider` in this sheet uses. Quality, Resolution and this row now
            // start their controls on one line, which is the alignment `Picker` could
            // never hold: AppKit sizes a picker's label to its own text, so "Colour"
            // and "Resize" put their popups at two different left edges.
            LumenMenuPicker(title: "Colour",
                            options: colorSpaceOptions,
                            selection: $recipe.colorSpace,
                            help: "The space the file is written in — ⇧S in develop "
                                + "proofs against it")
            // The first half of this used to say there was no dithering, which was true
            // until the ordered dither landed; the second half is still true and still
            // worth saying, because the space picker does not move where the gamut clip
            // happens — soft proofing (⇧S) is what shows you that clip.
            ExportNote(depthNote
                       + " Out-of-gamut colour is soft-clipped to Rec.2020 at the "
                       + "display transform and then converted by ColorSync; the space "
                       + "picker does not change where that clip happens. Press ⇧S in "
                       + "develop to proof against this space and see what it cannot "
                       + "hold.")
        }
    }

    /// The bit-depth row, one honest branch per format (docs/32 Stream G item 2a).
    ///
    /// TIFF/PNG choose 8 or 16. HEIC chooses 8 or 10 — but only on a machine whose
    /// encoder accepted the one-time Main-10 probe; where it declined, the row SAYS
    /// it declined rather than offering a segment the export would throw on. JPEG
    /// states its own limit in words: 8-bit is the format, not a Lumen decision.
    @ViewBuilder
    private var bitDepthControl: some View {
        if recipe.format.supportsSixteenBit {
            LumenSegmented(options: bitDepthOptions, selection: sixteenBitDepthBinding)
                .frame(maxWidth: 140)
        } else if recipe.format.supportsTenBit, PipelineRenderer.canWriteTenBitHEIC {
            LumenSegmented(options: heifBitDepthOptions, selection: tenBitDepthBinding)
                .frame(maxWidth: 140)
        } else if recipe.format.supportsTenBit {
            Text("8-bit — this Mac's HEVC encoder declined a 10-bit probe")
                .font(.system(size: 10))
                .foregroundStyle(Lumen.secondaryText)
        } else {
            Text("8-bit — all the JPEG format can carry; the dither below is what "
                 + "stands between an 8-bit sky and banding")
                .font(.system(size: 10))
                .foregroundStyle(Lumen.secondaryText)
        }
    }

    /// The stored `bitDepth` can hold a value the current format cannot write (switch
    /// a 10-bit HEIC recipe to TIFF and 10 is still stored). These write the tapped
    /// value straight through but READ through the same folding `effectiveBitDepth`
    /// applies, so the selected segment is always the depth the encoder will use and
    /// never an unselectable orphan number.
    private var sixteenBitDepthBinding: Binding<Int> {
        let recipe = self.$recipe
        return Binding(get: { recipe.wrappedValue.bitDepth >= 16 ? 16 : 8 },
                       set: { recipe.wrappedValue.bitDepth = $0 })
    }

    private var tenBitDepthBinding: Binding<Int> {
        let recipe = self.$recipe
        return Binding(get: { recipe.wrappedValue.bitDepth >= 10 ? 10 : 8 },
                       set: { recipe.wrappedValue.bitDepth = $0 })
    }

    /// Says what the encode actually does with the depth this recipe will use — which
    /// is not always the depth the field holds, since `effectiveBitDepth` folds the
    /// stored number to what the format can carry.
    private var depthNote: String {
        switch recipe.effectiveBitDepth {
        case 16:
            return "16-bit encodes carry codes 257× finer than an 8-bit one, so they "
                + "are written straight through with no dithering."
        case 10:
            return "10-bit HEIC carries four times the codes of an 8-bit file — "
                + "headroom that keeps a long sky gradient from stepping — and is "
                + "still dithered, at its own four-times-finer code width."
        default:
            return "8-bit encodes are dithered with an ordered 8×8 pattern of at most "
                + "half an output code, measured against this space's own transfer "
                + "curve, so a long smooth gradient keeps its local mean instead of "
                + "banding."
        }
    }

    // MARK: Size

    private var sizeSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Size")
            // ONE FIELD, TWO UNITS — so the mode change has to carry the number.
            //
            // Megapixels (0.5…100) and Pixels (320…8000) both write `resizeValue`, and
            // nothing converted it. Take the shipped "Web sRGB 2048" preset and switch to
            // Megapixels: the row reads 2048 on a slider whose drag ends at 100, and
            // `targetSize` computes two GIGApixels — clamped to no resize at all, or
            // attempted if "Don't enlarge" is off. Drag it back to a sane 24 and switch
            // to Long edge, and every photograph exports **24 pixels wide**. The only
            // warning anywhere was a summary line reading "Long edge 24px".
            //
            // Written through a wrapper binding rather than an `onChange` so the
            // conversion happens in the same update as the mode, and the row can never be
            // drawn holding the other unit's number.
            LumenMenuPicker(title: "Resize",
                            options: resizeOptions,
                            selection: Binding(
                                get: { recipe.resizeMode },
                                set: { mode in
                                    let wasMP = recipe.resizeMode == .megapixels
                                    let isMP = mode == .megapixels
                                    recipe.resizeMode = mode
                                    if wasMP != isMP {
                                        recipe.resizeValue = isMP ? 24 : 2048
                                    }
                                }),
                            help: "Which measurement of the picture the number below "
                                + "sets")
            if recipe.resizeMode == .none {
                // True since the docs/31 round one §11 fix and worth a sentence
                // BECAUSE it used to be false: the old tail resampled every cropped
                // or straightened photograph at ~0.9999× under this very setting.
                ExportNote("Don't resize means the resampler does not run: the "
                           + "delivery is the cropped frame's own pixels, not a "
                           + "1.0× resample of them.")
            }
            if recipe.resizeMode == .megapixels {
                LumenSlider(title: "Megapixels", value: $recipe.resizeValue,
                            range: 0.5...100, hardRange: 0.1...500, defaultValue: 24,
                            step: 0.5, decimals: 1, bipolar: false)
            } else if recipe.resizeMode != .none {
                LumenSlider(title: "Pixels", value: $recipe.resizeValue,
                            range: 320...8000, hardRange: 16...30000, defaultValue: 2048,
                            step: 8, decimals: 0, bipolar: false)
            }
            if recipe.resizeMode != .none {
                LumenToggleRow(title: "Don't enlarge", isOn: invertedFlag(\.allowUpscale),
                               help: "Never upscale past the source's own pixels.")
            }
            LumenSlider(title: "Resolution", value: $recipe.resolutionPPI,
                        range: 72...600, hardRange: 1...2400, defaultValue: 300,
                        step: 1, decimals: 0, bipolar: false)
            // There is no print-size preview. This note used to name one, and grepping
            // the repository for it finds a single unrelated thing: `FilmLab.printSize`,
            // the film-grain anchor — whose own picker was removed from `LookPanel` when
            // it was proven that the print size cancels out of the grain arithmetic
            // exactly. Nothing in Lumen shows a photographer how big this file prints.
            //
            // What Resolution actually reaches is named instead, both of it. The DPI
            // half is written through `applyMetadataPolicy`, on the same
            // `settingProperties` path as Copyright, and carries the same unconfirmed
            // status — the Metadata section below states it at length, so this row says
            // it in one clause rather than repeating the argument.
            ExportNote("Resolution feeds the output-sharpening radius, and is written "
                       + "into the file as its DPI — unconfirmed, like Copyright below. "
                       + "It does not change the pixel count.")
        }
    }

    // MARK: Output sharpening

    private var sharpenSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Output sharpening")
            ExportFieldRow("Medium") {
                LumenSegmented(options: sharpenMediumOptions, selection: $recipe.sharpen.medium)
                    .frame(maxWidth: 260)
            }
            ExportFieldRow("Amount") {
                LumenSegmented(options: sharpenAmountOptions, selection: $recipe.sharpen.amount)
                    .frame(maxWidth: 260)
                    .disabled(recipe.sharpen.isIdentity)
                    .opacity(recipe.sharpen.isIdentity ? 0.4 : 1)
            }
            ExportNote(sharpenExplanation)
        }
    }

    /// The radius printed is `appliedRadius` — the formula's answer through the SAME
    /// clamp the renderer runs (0.3…12 px, shared as `OutputSharpen.appliedRadiusBounds`)
    /// — so a matte print at a typed-in 2400 ppi reads the 12 px that will be applied,
    /// not the 24 the formula derives. And the ppi clause only appears for the print
    /// media: Screen's radius is the display's own sampling width and does not move
    /// with Resolution, so naming a ppi there would claim a dependency that is not
    /// in the arithmetic. Both radii are in DELIVERED pixels — the sharpen runs after
    /// the resize.
    private var sharpenExplanation: String {
        if recipe.sharpen.isIdentity {
            return "Off — for files headed to further retouching."
        }
        let radius = recipe.sharpen.appliedRadius(printPPI: recipe.resolutionPPI)
        let tail = "Medium × amount is the whole surface — no radius slider, by design."
        if recipe.sharpen.medium == .screen {
            return String(format: "Halo radius %.2f px of the delivered pixels — a "
                          + "screen's own sampling width, unmoved by Resolution — "
                          + "energy %.2f. " + tail,
                          radius, recipe.sharpen.energy())
        }
        return String(format: "Halo radius %.2f px of the delivered pixels at %.0f "
                      + "ppi, energy %.2f. " + tail,
                      radius, recipe.resolutionPPI, recipe.sharpen.energy())
    }

    // MARK: Naming

    private var namingSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Naming")
            ExportFieldRow("Filename") {
                ExportTextEntry(text: $recipe.filenameTemplate, placeholder: "{name}",
                                monospaced: true)
            }
            ExportFieldRow("Subfolder") {
                ExportTextEntry(text: optionalText(\.subfolder), placeholder: "none",
                                monospaced: true)
            }
            ExportFieldRow("Preview") {
                Text(filenamePreview)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Lumen.primaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ExportNote(namingNote)
        }
    }

    private var namingNote: String {
        var note: String
        if previewIsPlaceholder {
            note = "Preview uses a placeholder file — select a photo for the real name. "
        } else {
            note = "Preview is the real name for " + previewSource.lastPathComponent + ". "
        }
        note += "Tokens implemented today: {name} {date} {recipe} {ext}. Anything else stays "
        note += "visible in the name rather than being silently dropped, so a typo shows up "
        note += "here instead of in the delivered folder."
        return note
    }

    private var filenamePreview: String {
        let base = AppState.renderFilename(template: recipe.filenameTemplate,
                                           source: previewSource, recipeName: recipe.name)
        let file = base + "." + recipe.format.fileExtension
        // Through the same sanitizer the exporter uses. Concatenating the raw string
        // here meant the preview showed `../../secrets/x.jpg` for a subfolder the
        // exporter would have written as `secrets/x.jpg` — a preview that lies about
        // precisely the input a user would be checking it for.
        let sub = ExportRecipe.sanitizedSubfolderPath(recipe.subfolder)
        return sub.isEmpty ? file : sub + "/" + file
    }

    // MARK: Metadata

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Metadata")
            LumenToggleRow(title: "Strip GPS", isOn: invertedFlag(\.metadata.includeGPS),
                           help: "Client-safe by default, independent of everything else here.")
            LumenToggleRow(title: "EXIF", isOn: $recipe.metadata.includeEXIF,
                           help: "Camera, lens, exposure — read from the original "
                               + "file, not the render. Off removes them; on keeps "
                               + "what the original carried, which is not a promise "
                               + "that every field is present.")
            LumenToggleRow(title: "Camera serial", isOn: $recipe.metadata.includeCameraSerial,
                           help: "Off by default — a serial number identifies the body "
                               + "across every frame it ever shot.")
            LumenToggleRow(title: "Keywords", isOn: $recipe.metadata.includeKeywords)
            ExportFieldRow("Copyright") {
                ExportTextEntry(text: optionalText(\.metadata.copyright), placeholder: "© …")
            }
            ExportFieldRow("Contact") {
                ExportTextEntry(text: optionalText(\.metadata.contact),
                                placeholder: "email or site")
            }
            // Said plainly rather than left to be discovered in a delivered file, and
            // the two halves are said separately because they rest on different amounts
            // of evidence.
            //
            // The switches above REMOVE metadata, and that is reliable whichever way
            // Core Image treats the property dictionary: either the encoder honours it
            // and the keys are gone, or it ignores it and they were never going to be
            // written. Since the source-dictionary fix (docs/31 round one §13), the
            // policy's base is the ORIGINAL file's properties read through ImageIO —
            // so "EXIF: on" now has real camera data to keep, and the delivery's
            // orientation and pixel dimensions are rewritten to match the rendered
            // pixels. But everything the file is meant to CARRY — the kept EXIF, the
            // added Copyright, Contact and DPI — rides the same `settingProperties`
            // seam, and nobody has opened a delivered file on a Mac and read it back.
            // Telling the user it is written and unconfirmed is the only caption that
            // is true today; promising it outright would be a guess wearing a fact's
            // clothes, and saying nothing at all would hand a photographer a client
            // delivery they believe is protected.
            ExportNote("The switches that remove metadata are reliable. What the file "
                       + "keeps and gains — camera data with EXIF on, Copyright, "
                       + "Contact, the DPI — is written but not yet verified by "
                       + "reading a delivered file back, so check one before you rely "
                       + "on it. Size and orientation are corrected to the delivered "
                       + "pixels either way.")
        }
    }

    // MARK: Watermark

    private var watermarkSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Watermark")
            LumenToggleRow(title: "Watermark", isOn: watermarkEnabled,
                           help: "Composited into every exported file.")
            if recipe.watermark != nil {
                ExportFieldRow("Text") {
                    ExportTextEntry(text: watermarkValue(\.text), placeholder: "© Your Name")
                }
                ExportFieldRow("Position") {
                    LumenSegmented(options: watermarkPositionOptions,
                                   selection: watermarkValue(\.position))
                        .frame(maxWidth: 260)
                }
                LumenSlider(title: "Opacity", value: watermarkValue(\.opacity),
                            range: 0...100, defaultValue: 60, step: 1, decimals: 0,
                            bipolar: false)
                LumenSlider(title: "Size", value: watermarkValue(\.sizePercent),
                            range: 0.5...20, defaultValue: 3, step: 0.1, decimals: 1,
                            bipolar: false)
                LumenSlider(title: "Inset", value: watermarkValue(\.insetPercent),
                            range: 0...20, defaultValue: 2, step: 0.1, decimals: 1,
                            bipolar: false)
                ExportNote("Drawn into the exported pixels, not into the metadata — an "
                           + "exported file carries the mark wherever it goes, and the "
                           + "original is untouched. Size is a percentage of the long "
                           + "edge, so one setting looks the same on every crop; a "
                           + "mark too wide for its frame is shrunk to fit rather "
                           + "than cropped, and the file is always the size the Size "
                           + "section promised.")
            }
        }
    }

    private var watermarkEnabled: Binding<Bool> {
        let recipe = self.$recipe
        return Binding(get: { recipe.wrappedValue.watermark != nil },
                       set: { recipe.wrappedValue.watermark = $0 ? Watermark() : nil })
    }

    private func watermarkValue<V>(_ keyPath: WritableKeyPath<Watermark, V>) -> Binding<V> {
        let recipe = self.$recipe
        return Binding(
            get: {
                recipe.wrappedValue.watermark?[keyPath: keyPath] ?? Watermark()[keyPath: keyPath]
            },
            set: { value in
                var mark = recipe.wrappedValue.watermark ?? Watermark()
                mark[keyPath: keyPath] = value
                recipe.wrappedValue.watermark = mark
            })
    }

    // MARK: HDR

    private var hdrSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "HDR gain map")
            LumenToggleRow(title: "Emit gain map", isOn: hdrEnabled,
                           help: "Schema-reserved. The encoder writes no map yet, and "
                               + "these settings do not change the exported file.")
            if recipe.hdr != nil {
                LumenSlider(title: "Headroom", value: hdrValue(\.headroomEV),
                            range: 0.5...4, defaultValue: 2, step: 0.1, decimals: 1,
                            bipolar: false)
                ExportFieldRow("Map size") {
                    LumenSegmented(options: mapScaleOptions, selection: hdrValue(\.mapScale))
                        .frame(maxWidth: 200)
                }
                LumenToggleRow(title: "Deliberate SDR base", isOn: hdrValue(\.deliberateSDRBase),
                               help: "The SDR rendition is authored, never an automatic tone-map.")
                ExportNote(hdrExplanation)
            } else {
                ExportNote("\(recipe.format.rawValue.uppercased()) will be able to "
                           + "carry a gain map. Today every export is a plain SDR file.")
            }
        }
    }

    /// Says what will happen, not what was designed.
    ///
    /// This used to report "HDR ceiling 2.0 EV above SDR white; map stored at 25%
    /// resolution" for a file that had no map in it — and the setting it described was
    /// actively harmful, because the raised ceiling reached the render and the 8-bit
    /// encode then clipped everything above diffuse white. The settings are stored so
    /// nothing migrates when the encoder lands; they no longer touch the render.
    private var hdrExplanation: String {
        let settings = recipe.hdr ?? HDRSettings()
        return String(format: "Planned: %.1f EV of headroom above SDR white, map at "
                      + "%.0f%% resolution. Not written yet — this export is a plain "
                      + "SDR file either way, and turning this on no longer changes "
                      + "its pixels.",
                      settings.headroomEV, settings.mapScale * 100)
    }

    private var hdrEnabled: Binding<Bool> {
        let recipe = self.$recipe
        return Binding(get: { recipe.wrappedValue.hdr != nil },
                       set: { recipe.wrappedValue.hdr = $0 ? HDRSettings() : nil })
    }

    private func hdrValue<V>(_ keyPath: WritableKeyPath<HDRSettings, V>) -> Binding<V> {
        let recipe = self.$recipe
        return Binding(
            get: {
                recipe.wrappedValue.hdr?[keyPath: keyPath] ?? HDRSettings()[keyPath: keyPath]
            },
            set: { value in
                var settings = recipe.wrappedValue.hdr ?? HDRSettings()
                settings[keyPath: keyPath] = value
                recipe.wrappedValue.hdr = settings
            })
    }

    // MARK: Shared binding helpers

    /// A checkbox phrased as the negative of the stored flag ("Don't enlarge",
    /// "Strip GPS"), so the safe answer is the one that reads as on.
    private func invertedFlag(_ keyPath: WritableKeyPath<ExportRecipe, Bool>) -> Binding<Bool> {
        let recipe = self.$recipe
        return Binding(get: { !recipe.wrappedValue[keyPath: keyPath] },
                       set: { recipe.wrappedValue[keyPath: keyPath] = !$0 })
    }

    private func optionalText(_ keyPath: WritableKeyPath<ExportRecipe, String?>) -> Binding<String> {
        let recipe = self.$recipe
        return Binding(
            get: { recipe.wrappedValue[keyPath: keyPath] ?? "" },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                recipe.wrappedValue[keyPath: keyPath] = trimmed.isEmpty ? nil : value
            })
    }
}

// MARK: - Small pieces

private struct ExportFieldRow<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                // `.lumenBody`, not a bare 11. Two rows in this sheet are
                // `LumenMenuPicker`s now, which draw their own label through the type
                // scale at 12 — so Format and Bit depth were sitting one point smaller
                // than Colour space and Resize, in the same column, three rows apart.
                // That is precisely the 9/10/11 jitter `LumenType.swift` was written to
                // end, showing up at the seam between the migrated and the unmigrated.
                .font(.lumenBody)
                .foregroundStyle(Lumen.secondaryText)
                .frame(width: Lumen.labelWidth, alignment: .leading)
                .lineLimit(1)
                // The same shrink-rather-than-truncate `LumenSlider`'s label takes, and
                // for the same reason: the 86-point column was measured against 11 point
                // labels, and this sheet's longest ("Output sharpening") is over at 12.
                .minimumScaleFactor(0.86)
            content
            Spacer(minLength: 0)
        }
        .frame(minHeight: Lumen.rowHeight)
    }
}

private struct ExportTextEntry: View {
    @Binding var text: String
    var placeholder: String = ""
    var monospaced: Bool = false

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 11, design: monospaced ? .monospaced : .default))
            .foregroundStyle(Lumen.primaryText)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(Lumen.controlBackground)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .frame(maxWidth: 300)
    }
}

private struct ExportNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(Lumen.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
            .padding(.bottom, 4)
    }
}

#endif
