// AppStateActions.swift
// The actions that need the pipeline: Auto tone, which has to look at the picture
// before it can suggest anything, and export, which drives the render at full size.
// Both are async and both keep every pixel of work off the main actor.

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
                    let old = self.recipes[url] ?? Recipe()
                    var updated = old
                    updated.develop.tone = tone
                    before[url] = HistoryStack.PhotoEdit(recipe: old)
                    after[url] = HistoryStack.PhotoEdit(recipe: updated)
                    applied[url] = updated
                    self.recipes[url] = updated
                }
                self.history.record(before: before, after: after, coalescingKey: nil,
                                    label: "Auto Tone")
                for (url, recipe) in applied {
                    let id = self.allPhotos.first(where: { $0.id == url })?.catalogID
                    self.catalog?.saveRecipe(recipe, url: url, catalogID: id)
                }
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
            // A file that was written with a stage missing is not a failure and is not
            // a clean delivery either, and the status line called it clean. The preview
            // has labelled this since it was written ("Reduced — N GPU kernels
            // unavailable"); the file the photographer keeps said nothing.
            var reducedFiles = 0
            var reducedKernels: Set<String> = []
            for job in jobs {
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
                }
            }
            await MainActor.run {
                self.isExporting = false
                self.exportProgress = 0
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
                if failures.isEmpty {
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
        return out.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    func chooseExportDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        if panel.runModal() == .OK, let url = panel.url {
            showExportSheet = false
            export(to: url)
        }
    }
}

#endif
