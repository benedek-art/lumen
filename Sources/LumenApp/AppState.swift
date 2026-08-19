// AppState.swift
// Phase-1 application state: an in-memory folder scan (the catalog arrives in
// Phase 2), per-photo recipes, and the render coordination for the loupe.
// Doctrine enforced even in the skeleton (D34/D43): the browse path never decodes
// RAW — thumbnails come from embedded previews; renders happen off the main actor.

#if os(macOS)

import AppKit
import Foundation
import LumenCore
import SwiftUI

struct PhotoItem: Identifiable, Hashable {
    let id: URL
    var filename: String { id.lastPathComponent }
}

@MainActor
final class AppState: ObservableObject {

    // The extensions Apple's RAW pipeline + ImageIO handle; JPEGs browse too.
    static let browsableExtensions: Set<String> = [
        "arw", "cr2", "cr3", "crw", "dng", "erf", "nef", "nrw", "orf",
        "pef", "raf", "raw", "rw2", "srw", "x3f", "jpg", "jpeg", "heic",
    ]

    @Published var folderURL: URL?
    @Published var photos: [PhotoItem] = []
    @Published var selected: PhotoItem?
    @Published var isLoupeVisible = false
    @Published var statusMessage: String?

    /// Per-photo recipes, keyed by file URL. Phase 2 moves these into the catalog +
    /// sidecars; the model type is already the real one.
    @Published var recipes: [URL: Recipe] = [:]

    let thumbnails = ThumbnailLoader()

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Folder"
        if panel.runModal() == .OK, let url = panel.url {
            openFolder(url)
        }
    }

    func openFolder(_ url: URL) {
        folderURL = url
        selected = nil
        isLoupeVisible = false
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
            photos = contents
                .filter { Self.browsableExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { PhotoItem(id: $0) }
            statusMessage = "\(photos.count) photos"
        } catch {
            photos = []
            statusMessage = "Could not read folder: \(error.localizedDescription)"
        }
    }

    func recipe(for photo: PhotoItem) -> Recipe {
        recipes[photo.id] ?? Recipe()
    }

    func updateRecipe(for photo: PhotoItem, _ mutate: (inout Recipe) -> Void) {
        var recipe = recipes[photo.id] ?? Recipe()
        mutate(&recipe)
        recipes[photo.id] = recipe
    }

    // MARK: - Selection movement (arrow keys / culling flow)

    func selectNext() { moveSelection(by: 1) }
    func selectPrevious() { moveSelection(by: -1) }

    private func moveSelection(by delta: Int) {
        guard !photos.isEmpty else { return }
        guard let current = selected,
              let index = photos.firstIndex(of: current) else {
            selected = photos.first
            return
        }
        let next = min(max(index + delta, 0), photos.count - 1)
        selected = photos[next]
    }
}

#endif
