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
                var before: [URL: Recipe] = [:]
                var after: [URL: Recipe] = [:]
                for (url, tone) in suggestions {
                    let old = self.recipes[url] ?? Recipe()
                    var updated = old
                    updated.develop.tone = tone
                    before[url] = old
                    after[url] = updated
                    self.recipes[url] = updated
                }
                self.history.record(before: before, after: after, coalescingKey: nil,
                                    label: "Auto Tone")
                for (url, recipe) in after {
                    let id = self.allPhotos.first(where: { $0.id == url })?.catalogID
                    self.catalog?.saveRecipe(recipe, url: url, catalogID: id)
                }
                self.statusMessage = "Auto applied to \(after.count) photo"
                    + (after.count == 1 ? "" : "s")
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
        guard let result = await coordinator.renderOneShot(
            url: url, recipe: recipe, maxLongEdge: 512, draft: true,
            strokeSets: strokeSets) else { return nil }
        // Off the main actor for real: `nonisolated` permits being called from
        // anywhere, it does not move the work, and the caller is a main-actor Task.
        return await Task.detached(priority: .userInitiated) {
            histogramStatistics(from: result.image)
        }.value
    }

    /// Log2-luminance histogram of a rendered proxy, in stops around mid-grey.
    nonisolated static func histogramStatistics(from image: CGImage) -> AutoTone.Statistics? {
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

        let minEV = -12.0
        let maxEV = 12.0
        var bins = [Double](repeating: 0, count: 128)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let r = TransferFunction.srgb.decode(Double(bytes[i]) / 255)
            let g = TransferFunction.srgb.decode(Double(bytes[i + 1]) / 255)
            let b = TransferFunction.srgb.decode(Double(bytes[i + 2]) / 255)
            let luminance = 0.2627 * r + 0.6780 * g + 0.0593 * b
            let ev = Num.safeLog2(luminance / 0.18, floorEV: minEV)
            let t = Num.saturate((ev - minEV) / (maxEV - minEV))
            let bin = Swift.min(Int(t * 127), 127)
            bins[bin] += 1
        }
        return AutoTone.Statistics(histogram: bins, minEV: minEV, maxEV: maxEV)
    }

    // MARK: - Export

    /// One Export click emits every checked recipe (D40). The render forks at the
    /// resize node, so three recipes cost far less than three exports.
    func export(to directory: URL) {
        let targets = selectedPhotos.isEmpty
            ? (primarySelection.map { [$0] } ?? [])
            : selectedPhotos
        let active = exportRecipes.filter(\.enabled)
        guard !targets.isEmpty, !active.isEmpty else {
            statusMessage = "Nothing to export"
            return
        }

        let jobs = targets.map { photo -> (url: URL, recipe: Recipe,
                                           strokes: [String: BrushStrokeSet]) in
            let r = recipe(for: photo)
            return (url: photo.id, recipe: r, strokes: strokeSets(for: r))
        }
        isExporting = true
        exportProgress = 0
        let total = Double(jobs.count * active.count)

        Task {
            var completed = 0.0
            var failures: [String] = []
            for job in jobs {
                for exportRecipe in active {
                    let destination = Self.destination(directory: directory,
                                                       source: job.url,
                                                       recipe: exportRecipe)
                    do {
                        try FileManager.default.createDirectory(
                            at: destination.deletingLastPathComponent(),
                            withIntermediateDirectories: true)
                        try await renderCoordinator.export(url: job.url, recipe: job.recipe,
                                                           to: destination,
                                                           exportRecipe: exportRecipe,
                                                           strokeSets: job.strokes)
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
                if failures.isEmpty {
                    self.statusMessage = "Exported \(Int(total)) file"
                        + (total == 1 ? "" : "s")
                } else {
                    self.statusMessage = "\(failures.count) export"
                        + (failures.count == 1 ? "" : "s") + " failed"
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
