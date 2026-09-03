// AppStateActions.swift
// The verbs that are too big to live among `AppState`'s state.
//
// Two of them need the pipeline: Auto tone, which has to look at the picture before it
// can suggest anything, and export, which drives the render at full size. Both are async
// and both keep every pixel of work off the main actor.
//
// Reset needs none of it — it is a pure value replacement — and it is here rather than
// beside the copy/paste family because it is the same shape as those two in the way that
// matters: a photographer's command with a stated contract, a named undo step, and a
// baseline it has to resolve per photograph rather than once for the selection.

#if os(macOS)

import AppKit
import Foundation
import LumenCore
import LumenPipeline
import SwiftUI

extension AppState {

    // MARK: - Auto tone (D11)

    /// Auto sets VISIBLE slider values the user can then argue with — it is not a
    /// hidden mode. Statistics come from a small proxy of the actual render, so Auto
    /// sees what the user sees, including the crop.
    func applyAutoTone() {
        let targets = editTargets
        guard !targets.isEmpty else { return }
        let recipesByURL = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, recipe(for: $0)) })
        statusMessage = "Analysing…"

        Task {
            var suggestions: [URL: Tone] = [:]
            for (url, recipe) in recipesByURL {
                // Neutral tone for the analysis pass: measuring the scene through the
                // edit you are about to replace would make Auto depend on its own
                // previous answer.
                var probe = recipe
                probe.develop.tone = Tone()
                guard let stats = await Self.statistics(url: url, recipe: probe,
                                                        coordinator: renderCoordinator,
                                                        strokeSets: strokeSets(for: probe))
                else { continue }
                suggestions[url] = AutoTone.suggest(from: stats)
            }
            await MainActor.run {
                guard !suggestions.isEmpty else {
                    self.statusMessage = "Auto could not read those files"
                    return
                }
                var before: [URL: HistoryStack.PhotoEdit] = [:]
                var after: [URL: HistoryStack.PhotoEdit] = [:]
                var applied: [URL: Recipe] = [:]
                for (url, tone) in suggestions {
                    // The photo's real baseline, not bare defaults: Auto measured
                    // through recipe(for:) — starting from Recipe() here installed a
                    // recipe it never measured, stripping a JPEG's Linear preset
                    // (second tone map) or a RAW's ISO denoise, unrecoverably (undo
                    // recorded the same wrong `before`).
                    let iso = self.allPhotos.first(where: { $0.id == url })?.iso
                    let old = self.recipes[url]
                        ?? AppState.startingRecipe(for: url, iso: iso)
                    var updated = old
                    updated.develop.tone = tone
                    before[url] = HistoryStack.PhotoEdit(recipe: old)
                    after[url] = HistoryStack.PhotoEdit(recipe: updated)
                    applied[url] = updated
                    self.recipes[url] = updated
                }
                self.history.record(before: before, after: after, coalescingKey: nil,
                                    label: "Auto Tone")
                // THROUGH `persist`, not a hand-rolled save loop. Writing the catalog
                // directly skipped everything else `persist` does — notably
                // `refreshLibraryQueryIfEditStateShows`, so with the filter chip set to
                // "Edited: no" an auto-toned frame stayed in a list claiming to hold only
                // untouched photographs until something unrelated forced a requery.
                self.persist(applied)
                // AND THE INSTRUMENTS. `scheduleScopeRefresh` is the only producer of
                // `AppState.scopes`, and every other write path calls it. Auto did not:
                // press Auto with the histogram open and it kept describing the picture
                // from BEFORE Auto ran, until you touched another control. The one
                // instrument you would use to judge Auto was the one that did not move.
                self.scheduleScopeRefresh()
                self.statusMessage = "Auto applied to \(applied.count) photo"
                    + (applied.count == 1 ? "" : "s")
            }
        }
    }

    private static func statistics(url: URL, recipe: Recipe,
                                   coordinator: RenderCoordinator,
                                   strokeSets: [String: BrushStrokeSet]
                                   ) async -> AutoTone.Statistics? {
        // A 512-px proxy is plenty for tonal statistics and costs a fraction of a
        // full render — Auto must feel instant or nobody presses it twice. One-shot,
        // so measuring the picture cannot cancel the frame the viewer is drawing.
        // Not draft, for the reason ScopeData.swift gives at its own probe: draft skips
        // presence, every local adjustment, sharpening, halation and grain, and builds
        // no mask rasters at all. Auto measuring that render is Auto measuring a
        // picture nobody is looking at, which is the opposite of the line above.
        guard let result = await coordinator.renderOneShot(
            url: url, recipe: recipe, maxLongEdge: 512, draft: false,
            strokeSets: strokeSets) else { return nil }
        // The transform the render was made through, so the measurement can be taken
        // back through it. Cheap — the curve's constants, not a baked table.
        let transform = DisplayTransform.forRecipe(recipe)
        // Off the main actor for real: `nonisolated` permits being called from
        // anywhere, it does not move the work, and the caller is a main-actor Task.
        return await Task.detached(priority: .userInitiated) {
            histogramStatistics(from: result.image, transform: transform)
        }.value
    }

    /// Scene-referred log2-luminance histogram of a rendered proxy, in stops around
    /// mid-grey.
    ///
    /// This binned `log2(displayLuminance / 0.18)` and called the result a scene EV. It
    /// is not one: the proxy has already been through the display transform, so the
    /// value cannot exceed 1.0 and the expression cannot exceed +2.47 EV. `AutoTone
    /// .suggest` fires highlight recovery at `percentileEV(0.995) + exposure > 3.0`, so
    /// on a blown sky — the frame the branch exists for, and the single most common
    /// thing an Auto button is pressed to do — it could never fire. The same squeeze at
    /// the bottom had the shadow branch reading the transform's toe rather than the
    /// photograph. Both thresholds are denominated in scene EV; the measurement was not.
    ///
    /// `AutoTone.SceneHistogram` puts it back where it belongs by inverting the curve
    /// the render applied, and carries the two limits of doing so — censoring at the
    /// anchors, and luminance rather than colour. The whole of the arithmetic lives
    /// there because it is testable there and this function is not.
    nonisolated static func histogramStatistics(from image: CGImage,
                                                transform: DisplayTransform)
        -> AutoTone.Statistics?
    {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: &bytes, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: info) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // sRGB primaries, because that is the space the proxy was drawn into. The Rec.
        // 2020 weights that used to be here were a second unit mismatch in the same
        // expression as the first, worth about 2% on a saturated pixel's luminance.
        let weights = RGBColorSpace.srgb.luminanceWeights
        // The finish table ends NORMALIZED against display white (RenderPlan's
        // `display` divides by `finishScale`), so the proxy's 1.0 is display white
        // whatever the display peak is, while `transform.tone` answers in absolute
        // display-linear. One multiply reconciles them; it is 1.0 for every SDR recipe
        // and is here for the one that pins an EDR white target.
        let white = transform.white
        var histogram = AutoTone.SceneHistogram(transform: transform)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let r = TransferFunction.srgb.decode(Double(bytes[i]) / 255)
            let g = TransferFunction.srgb.decode(Double(bytes[i + 1]) / 255)
            let b = TransferFunction.srgb.decode(Double(bytes[i + 2]) / 255)
            histogram.add(displayLuminance:
                (weights.r * r + weights.g * g + weights.b * b) * white)
        }
        return histogram.statistics
    }

    // MARK: - Reset

    /// Put the selection back to how it was imported, in ONE undo step.
    ///
    /// The control a photographer reaches for when an edit has gone wrong, and the
    /// reason it has to exist is not convenience: without it the way to try something is
    /// to duplicate the photograph first, and a library full of defensive copies is the
    /// habit an editor teaches when it cannot promise a way back.
    ///
    /// THE BASELINE IS THE PHOTOGRAPH'S OWN, never bare defaults, and
    /// `Recipe.asImported(from:)` in LumenCore is the single statement of what that
    /// means — a rendered file starts on the "Linear" display transform because Lumen's
    /// own transform is the only one a raw will ever get and a second one crushes an
    /// already-mapped picture; a camera raw starts on the Tier-1 denoise its capture ISO
    /// calls for. That rule was `AppState.startingRecipe` and nothing else — a statement
    /// in a target that compiles on macOS alone, so nothing could check the answer until
    /// CI, and the four places that need it (this command, the two per-section Resets
    /// that have to patch their own baseline back in afterwards, and the modified dot)
    /// each carried their own reading of it. `RecipeReset.swift` is the one place now,
    /// and `ResetSemanticsTests` is what holds it there.
    ///
    /// ONE STEP, AND IT IS NAMED. `label:` matters more than it looks: a step that
    /// arrives without one wears `HistoryStack.unnamedLabel`, which the Edit menu prints
    /// as "Undo Edit" and the history list treats as "nobody named this". Throwing away
    /// a whole afternoon's grade is the single step in the app a photographer is most
    /// likely to want to walk back deliberately, and it is the one that must not be
    /// anonymous in the list they walk back through. No coalescing key, either: a reset
    /// folded into the slider drag that preceded it would be one undo for both.
    ///
    /// WHAT IT PRESERVES is on `Recipe.resetToImported(from:)` at length. The short
    /// version: rating, flag, colour label, keywords, album and stack membership are not
    /// in a recipe at all, and `updateRecipe` records `PhotoEdit(recipe:)` with no
    /// culling, so neither the reset nor undoing it can move a star. The crop goes, with
    /// everything else in the develop and look layers, because in this app a crop is an
    /// edit and there is no as-shot one to keep.
    ///
    /// Across the whole selection, like Paste Settings and Auto Tone — `updateRecipe`
    /// resolves the baseline per photograph, so a raw at ISO 12800 and a JPEG reset in
    /// the same gesture each land on their own starting point rather than on the
    /// primary selection's.
    func resetToImported() {
        updateRecipe(label: "Reset") { photo, recipe in
            recipe.resetToImported(from: AppState.sourceFile(for: photo))
        }
    }

    /// Whether Reset would change anything for the current selection.
    ///
    /// Any photograph in the selection that is off its own baseline is enough — a batch
    /// reset where four of five frames are already untouched still has work to do on the
    /// fifth, and greying the command out because most of the selection is clean would
    /// refuse the request the photographer actually made.
    var canResetToImported: Bool {
        editTargets.contains { photo in
            !recipe(for: photo).isAsImported(from: AppState.sourceFile(for: photo))
        }
    }

    /// The two facts about a file that decide its untouched recipe, read off the item
    /// the scanner produced.
    ///
    /// The bridge is here and is deliberately thin. LumenCore does not know which
    /// extensions are rendered — that list is `PhotoFormats`, and a second copy of it
    /// inside the recipe model could disagree with the one the folder scan used about
    /// the same file, which would be a photograph whose Reset lands somewhere its
    /// modified dot does not.
    static func sourceFile(for photo: PhotoItem) -> Recipe.SourceFile {
        Recipe.SourceFile(isRendered: PhotoFormats.isRendered(photo.id), iso: photo.iso)
    }

    // MARK: - Export

    /// One Export click emits every checked recipe (D40) — and this loop is the reason
    /// that costs what three exports cost.
    ///
    /// It used to say "the render forks at the resize node, so three recipes cost far
    /// less than three exports", which is exactly what the two nested loops below do
    /// not do: photos × recipes, each iteration a separate `renderCoordinator.export`,
    /// each of those a fresh `RenderGraph` and a full develop render. Only the decode is
    /// reused. The claim survived in four places at once — here, `ExportRecipe`,
    /// `ExportSheet` and docs/11 — which is how a design note becomes a fact nobody
    /// re-checks.
    ///
    /// The sharing is worth building and is not built. `PipelineRenderer.export` names
    /// the shape and the one complication: `RenderPlan` reads
    /// `exportRecipe.renderWhiteTargetPercent`, so recipes with different HDR white
    /// targets cannot share a master.
    func export(to directory: URL) {
        let targets = selectedPhotos.isEmpty
            ? (primarySelection.map { [$0] } ?? [])
            : selectedPhotos
        let active = exportRecipes.filter(\.enabled)
        guard !targets.isEmpty, !active.isEmpty else {
            statusMessage = "Nothing to export"
            return
        }

        // Resolved, not read from memory. `strokeSets(for:)` serves the session cache
        // and never the disk, and the cache is filled by a detached task at catalog
        // open — so a batch started before that task finished used to hand the renderer
        // an empty dictionary, rasterize every brush component to nothing, and write the
        // file anyway. Reading here blocks for a few tens of kilobytes per component;
        // the alternative is a delivered file with the photographer's masking missing
        // and nothing to say so.
        let jobs = targets.map { photo -> (url: URL, recipe: Recipe,
                                           strokes: [String: BrushStrokeSet],
                                           refusal: String?) in
            let r = recipe(for: photo)
            let resolved = resolveStrokeSets(for: r)
            return (url: photo.id, recipe: r, strokes: resolved.sets,
                    refusal: BrushStrokes.refusal(unresolved: resolved.unresolved))
        }
        isExporting = true
        exportProgress = 0
        // Cleared here rather than only at the end, so a batch that was cancelled and
        // restarted does not inherit the previous run's stop.
        clearExportCancel()
        let total = Double(jobs.count * active.count)

        Task {
            var completed = 0.0
            var failures: [String] = []
            // Nothing this run writes may land on a path an earlier job claimed or on a
            // file that was already there. The encoders truncate, so without this a
            // re-export replaced a delivery and two same-named frames from different
            // subfolders silently became one file.
            var claimed: Set<URL> = []
            var renamed = 0
            var written = 0
            var stopped = false
            // A file that was written with a stage missing is not a failure and is not
            // a clean delivery either, and the status line called it clean. The preview
            // has labelled this since it was written ("Reduced — N GPU kernels
            // unavailable"); the file the photographer keeps said nothing.
            var reducedFiles = 0
            var reducedKernels: Set<String> = []
            batch: for job in jobs {
                // A photo whose masking cannot be honoured is not delivered at all.
                // Writing it would produce a frame that looks finished with its brush
                // masks absent — the ".lrcat-data black mask" failure docs/08 §8.7
                // exists to prevent, and the one failure mode a photographer cannot
                // catch by looking at the export count.
                if let refusal = job.refusal {
                    for exportRecipe in active {
                        failures.append(job.url.lastPathComponent + " → "
                                            + exportRecipe.name + ": " + refusal)
                        completed += 1
                    }
                    let progress = completed / total
                    await MainActor.run { self.exportProgress = progress }
                    if await MainActor.run(body: { self.exportCancelRequested }) {
                        stopped = true
                        break batch
                    }
                    continue
                }
                for exportRecipe in active {
                    let wanted = Self.destination(directory: directory,
                                                  source: job.url,
                                                  recipe: exportRecipe)
                    let destination = ExportRecipe.disambiguated(wanted) { candidate in
                        claimed.contains(candidate)
                            || FileManager.default.fileExists(atPath: candidate.path)
                    }
                    claimed.insert(destination)
                    if destination != wanted { renamed += 1 }
                    do {
                        try FileManager.default.createDirectory(
                            at: destination.deletingLastPathComponent(),
                            withIntermediateDirectories: true)
                        let missing = try await renderCoordinator.export(
                            url: job.url, recipe: job.recipe, to: destination,
                            exportRecipe: exportRecipe, strokeSets: job.strokes)
                        written += 1
                        if !missing.isEmpty {
                            reducedFiles += 1
                            reducedKernels.formUnion(missing)
                        }
                    } catch {
                        failures.append(job.url.lastPathComponent + " → " + exportRecipe.name)
                    }
                    completed += 1
                    let progress = completed / total
                    await MainActor.run { self.exportProgress = progress }
                    // Between files, and only between files. The write above has
                    // already renamed its temp into place, so stopping here can never
                    // leave a partial delivery on disk — which is the property that
                    // makes cancelling safe to offer at all.
                    if await MainActor.run(body: { self.exportCancelRequested }) {
                        stopped = true
                        break batch
                    }
                }
            }
            await MainActor.run {
                self.isExporting = false
                self.exportProgress = 0
                self.clearExportCancel()
                // Count what was actually written, not what was planned. The old
                // message reported photos × recipes whatever happened, so a run that
                // overwrote two of its own outputs still claimed every file.
                let renamedNote = renamed == 0 ? ""
                    : " (\(renamed) renamed to avoid overwriting)"
                // Named, not counted: "2 reduced" tells a photographer nothing about
                // what is missing from a file they are about to send to a client.
                let reducedNote = reducedFiles == 0 ? ""
                    : " — \(reducedFiles) reduced, GPU "
                        + (reducedKernels.count == 1 ? "kernel" : "kernels")
                        + " unavailable: " + reducedKernels.sorted().joined(separator: ", ")
                if stopped {
                    // Say it was stopped. Reporting "Exported 4 files" for a batch the
                    // photographer halted at 4 of 200 reads as a finished run, and the
                    // whole point of the button is that they know it did not finish.
                    let failureNote = failures.isEmpty ? ""
                        : " — \(failures.count) failed"
                    self.statusMessage = "Stopped — \(written) file"
                        + (written == 1 ? "" : "s") + " of \(Int(total)) written"
                        + failureNote + renamedNote + reducedNote
                } else if failures.isEmpty {
                    self.statusMessage = "Exported \(written) file"
                        + (written == 1 ? "" : "s") + renamedNote + reducedNote
                } else {
                    // Name the first failure. "2 failed" leaves a photographer with no
                    // way to tell a disk error from masking that could not be read, and
                    // the second one is the one that decides whether the delivery can
                    // go out at all.
                    self.statusMessage = "Exported \(written) of \(Int(total)) — "
                        + "\(failures.count) failed"
                        + (failures.first.map { " — " + $0 } ?? "")
                        + renamedNote + reducedNote
                }
            }
        }
    }

    static func destination(directory: URL, source: URL, recipe: ExportRecipe) -> URL {
        var folder = directory
        // Sanitizing lives in LumenCore so the export sheet's preview can call the same
        // function — it used to build its own path by concatenation, and so disagreed
        // with what actually got written for exactly the inputs that matter. See
        // `ExportRecipe.sanitizedSubfolderComponents`.
        for component in ExportRecipe.sanitizedSubfolderComponents(recipe.subfolder) {
            folder = folder.appendingPathComponent(component, isDirectory: true)
        }
        let base = renderFilename(template: recipe.filenameTemplate, source: source,
                                  recipeName: recipe.name)
        return folder.appendingPathComponent(base)
            .appendingPathExtension(recipe.format.fileExtension)
    }

    /// The token grammar shared with the ingest renamer. An unknown token is left
    /// alone rather than silently deleted — a filename that still shows `{whatever}`
    /// tells the user what went wrong.
    static func renderFilename(template: String, source: URL, recipeName: String) -> String {
        let name = source.deletingPathExtension().lastPathComponent
        var out = template.isEmpty ? "{name}" : template
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let attributes = try? FileManager.default.attributesOfItem(atPath: source.path)
        let date = (attributes?[.creationDate] as? Date) ?? Date()

        out = out.replacingOccurrences(of: "{name}", with: name)
        out = out.replacingOccurrences(of: "{date}", with: formatter.string(from: date))
        out = out.replacingOccurrences(of: "{recipe}", with: recipeName)
        out = out.replacingOccurrences(of: "{ext}", with: source.pathExtension)
        // Filesystem-hostile characters never reach a path.
        let rendered = out.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        // AND NEITHER DOES AN EMPTY RESULT. The guard above is on the literal template;
        // this one is on what the template RENDERED, which is a different question and
        // the one that reaches the filesystem. `{recipe}` with a cleared recipe name
        // renders nothing, and a nothing appended to the delivery folder puts the
        // extension on the FOLDER — the whole batch written beside it as one file.
        // Falling back to the source's own name is what the empty-template branch above
        // already does; this applies the same answer to the same question one step later.
        return RenameTemplate.usableBasename(rendered)
            ?? RenameTemplate.usableBasename(name)
            ?? "Untitled"
    }

    func chooseExportDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        if panel.runModal() == .OK, let url = panel.url {
            // The sheet STAYS UP for the run. It used to close here, one line before
            // the batch started, which put the progress readout and the Stop button
            // behind a door that shut itself: the only always-visible sign of an export
            // was a percentage in the status bar with no way to halt it. `ExportSheet`
            // watches `isExporting` and shows its progress section; closing it is the
            // photographer's call, and `Close` is still there for a batch they are happy
            // to leave running.
            export(to: url)
        }
    }
}

#endif
