// AppState.swift
// The application's state hub. Folders are the library — there is no import ceremony
// (D34) — and everything the user does to a photo is a value written into a recipe and
// persisted to the catalog plus an XMP sidecar.
//
// Three rules this file exists to enforce:
//   · Zero pipeline work on the main actor. Every decode, render and rasterization
//     goes to the render coordinator; this type only holds values and publishes them.
//   · The browse path never decodes RAW. Thumbnails come from embedded previews.
//   · Losing the catalog costs speed, never work: if it will not open, the app runs
//     from memory and says so, because a photographer mid-shoot needs the app to open.

#if os(macOS)

import AppKit
import Foundation
import LumenCore
import LumenPipeline
import SwiftUI

// MARK: - Formats

/// What Lumen will browse. Deliberately NOT on `AppState`: the folder scan runs off
/// the main actor, and a main-actor-isolated constant it has to reach for is both a
/// concurrency warning today and an error under Swift 6.
enum PhotoFormats {
    static let raw: Set<String> = [
        "arw", "cr2", "cr3", "crw", "dng", "erf", "nef", "nrw", "orf",
        "pef", "raf", "raw", "rw2", "srw", "x3f",
    ]
    static let rendered: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff",
    ]
    static let browsable: Set<String> = raw.union(rendered)

    static func isRaw(_ url: URL) -> Bool {
        raw.contains(url.pathExtension.lowercased())
    }
}

// MARK: - Photo

struct PhotoItem: Identifiable, Hashable, Sendable {
    let id: URL
    var catalogID: Int64?
    var flag: PhotoFlag = .none
    var rating: Int = 0
    var label: ColorLabel = .none

    var filename: String { id.lastPathComponent }
    var isRaw: Bool { PhotoFormats.isRaw(id) }

    static func == (a: PhotoItem, b: PhotoItem) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum PhotoFlag: Int, Codable, Sendable, CaseIterable {
    case rejected = -1
    case none = 0
    case picked = 1

    var symbolName: String {
        switch self {
        case .picked: return "flag.fill"
        case .rejected: return "xmark"
        case .none: return "flag"
        }
    }
}

enum ColorLabel: Int, Codable, Sendable, CaseIterable {
    case none = 0, red, yellow, green, blue, purple

    var displayName: String {
        switch self {
        case .none: return "None"
        case .red: return "Red"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .purple: return "Purple"
        }
    }

    var color: Color {
        switch self {
        case .none: return .clear
        case .red: return Color(red: 0.85, green: 0.25, blue: 0.25)
        case .yellow: return Color(red: 0.90, green: 0.75, blue: 0.20)
        case .green: return Color(red: 0.30, green: 0.70, blue: 0.35)
        case .blue: return Color(red: 0.25, green: 0.50, blue: 0.85)
        case .purple: return Color(red: 0.60, green: 0.35, blue: 0.80)
        }
    }
}

// MARK: - View mode

enum ViewMode: String, Sendable {
    case grid, loupe, compare, survey
}

/// Which panel group the develop column is showing. The simple register is the
/// default; depth is one disclosure away (D3).
enum PanelSection: String, CaseIterable, Identifiable, Sendable {
    case basic = "Basic"
    case curve = "Curve"
    case color = "Color"
    case detail = "Detail"
    case effects = "Effects"
    case masks = "Masks"
    case look = "Look"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .basic: return "slider.horizontal.3"
        case .curve: return "point.topleft.down.curvedto.point.bottomright.up"
        case .color: return "paintpalette"
        case .detail: return "wand.and.rays"
        case .effects: return "camera.filters"
        case .masks: return "theatermasks"
        case .look: return "photo.stack"
        }
    }
}

// MARK: - Filtering

struct LibraryFilter: Equatable, Sendable {
    /// Criteria OR within themselves and AND across themselves — the day-one rule
    /// (D39). An empty set means "no constraint from this criterion".
    var flags: Set<PhotoFlag> = []
    var minRating: Int = 0
    var labels: Set<ColorLabel> = []
    var text: String = ""
    var rawOnly: Bool = false

    var isActive: Bool {
        !flags.isEmpty || minRating > 0 || !labels.isEmpty || !text.isEmpty || rawOnly
    }

    func matches(_ photo: PhotoItem) -> Bool {
        if !flags.isEmpty && !flags.contains(photo.flag) { return false }
        if photo.rating < minRating { return false }
        if !labels.isEmpty && !labels.contains(photo.label) { return false }
        if rawOnly && !photo.isRaw { return false }
        if !text.isEmpty
            && !photo.filename.localizedCaseInsensitiveContains(text) { return false }
        return true
    }
}

enum SortOrder: String, CaseIterable, Identifiable, Sendable {
    case filename = "File name"
    case captureDate = "Capture time"
    case rating = "Rating"
    case flag = "Flag"

    var id: String { rawValue }
}

// MARK: - AppState

@MainActor
final class AppState: ObservableObject {

    static var rawExtensions: Set<String> { PhotoFormats.raw }
    static var jpegExtensions: Set<String> { PhotoFormats.rendered }
    static var browsableExtensions: Set<String> { PhotoFormats.browsable }

    // MARK: Library

    @Published var folderURL: URL?
    @Published private(set) var allPhotos: [PhotoItem] = []
    @Published var filter = LibraryFilter()
    @Published var sortOrder: SortOrder = .filename
    @Published var selection: Set<URL> = []
    @Published var primarySelection: PhotoItem?
    @Published var viewMode: ViewMode = .grid
    @Published var statusMessage: String?
    @Published var catalogStatus: String?
    @Published var isScanning = false

    /// Auto-advance after a flag or rating is the culling loop's whole point, and it
    /// is visible and toggleable rather than a hidden preference (D35).
    @Published var autoAdvance = true
    @Published var gridThumbnailSize: Double = 160
    @Published var showFilmstrip = true
    /// Published by the grid as it lays out, so ↑/↓ move by a real row rather than by
    /// a guess. Never zero — a divide-by-row-count would be a crash in the key path.
    @Published var gridColumns: Int = 6
    @Published var showKeyReference = false
    @Published var showExportSheet = false
    @Published var showIngestSheet = false

    // MARK: Editor

    @Published var recipes: [URL: Recipe] = [:]
    @Published var activeSection: PanelSection = .basic
    @Published var showBefore = false
    @Published var soloMaskOverlay: String?
    /// Which mask and component the panel has selected. Published because the on-image
    /// canvas edits geometry and lives in the viewer, not the panel.
    @Published var activeMaskID: String?
    @Published var activeComponentIndex: Int = 0
    @Published var clippingOverlay: ClippingOverlay.Mode?
    @Published var showHistogram = true
    @Published var showScopes = false
    /// The histogram and scopes for the current photo, binned from a small proxy of
    /// the actual composite off the main actor.
    @Published var scopes: ScopeData?
    var scopeGeneration: UInt64 = 0
    @Published var zoomLevel: Double = 0        // 0 = fit; otherwise a ratio like 1.0

    // MARK: Services

    let thumbnails = ThumbnailLoader()
    let history = HistoryStack()
    private(set) var catalog: CatalogService?
    let renderCoordinator = RenderCoordinator()

    @Published var exportRecipes: [ExportRecipe] = ExportRecipe.defaults
    @Published var isExporting = false
    @Published var exportProgress: Double = 0

    init() {
        openCatalog()
    }

    // MARK: Derived

    /// The photos actually on screen, after filtering and sorting.
    var photos: [PhotoItem] {
        let filtered = filter.isActive ? allPhotos.filter(filter.matches) : allPhotos
        switch sortOrder {
        case .filename:
            return filtered.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        case .captureDate:
            return filtered   // capture time arrives with the catalog's metadata scan
        case .rating:
            return filtered.sorted { ($0.rating, $1.filename) > ($1.rating, $0.filename) }
        case .flag:
            return filtered.sorted { $0.flag.rawValue > $1.flag.rawValue }
        }
    }

    var selectedPhotos: [PhotoItem] {
        photos.filter { selection.contains($0.id) }
    }

    /// What an edit applies to: the whole selection when there is one, otherwise the
    /// photo under the cursor.
    var editTargets: [PhotoItem] {
        if selection.count > 1 { return selectedPhotos }
        if let primary = primarySelection { return [primary] }
        return []
    }

    // MARK: Catalog

    private func openCatalog() {
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            let directory = support.appendingPathComponent("Lumen", isDirectory: true)
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            let service = try CatalogService(directory: directory)
            catalog = service
            catalogStatus = nil
        } catch {
            catalog = nil
            catalogStatus = "Catalog unavailable — edits live in memory this session "
                + "(\(error.localizedDescription))"
        }
    }

    // MARK: Folder scanning

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
        selection = []
        primarySelection = nil
        viewMode = .grid
        isScanning = true
        statusMessage = "Scanning…"

        let extensions = Self.browsableExtensions
        Task.detached(priority: .userInitiated) {
            let found = Self.scan(url: url, extensions: extensions)
            await MainActor.run {
                self.applyScan(found)
            }
        }
    }

    /// The scan itself runs off the main actor: a card with 5,000 frames must not
    /// freeze the window while it is enumerated.
    nonisolated private static func scan(url: URL, extensions: Set<String>) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [URL] = []
        for case let file as URL in enumerator {
            if extensions.contains(file.pathExtension.lowercased()) {
                found.append(file)
            }
        }
        return found.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func applyScan(_ urls: [URL]) {
        var items = urls.map { PhotoItem(id: $0) }
        if let catalog, let folder = folderURL {
            let state = catalog.registerAndLoad(folder: folder, files: urls)
            for i in items.indices {
                if let stored = state[items[i].id] {
                    items[i].catalogID = stored.catalogID
                    items[i].flag = stored.flag
                    items[i].rating = stored.rating
                    items[i].label = stored.label
                    if let recipe = stored.recipe { recipes[items[i].id] = recipe }
                }
            }
        }
        allPhotos = items
        isScanning = false
        statusMessage = "\(items.count) photo\(items.count == 1 ? "" : "s")"
        if primarySelection == nil, let first = photos.first {
            select(first)
        }
    }

    // MARK: Selection

    func select(_ photo: PhotoItem, extending: Bool = false, toggling: Bool = false) {
        if toggling {
            if selection.contains(photo.id) {
                selection.remove(photo.id)
            } else {
                selection.insert(photo.id)
            }
            primarySelection = photo
            return
        }
        if extending, let anchor = primarySelection,
           let from = photos.firstIndex(of: anchor),
           let to = photos.firstIndex(of: photo) {
            let range = from <= to ? from...to : to...from
            selection = Set(photos[range].map(\.id))
            primarySelection = photo
            return
        }
        selection = [photo.id]
        primarySelection = photo
        scheduleScopeRefresh()
    }

    func selectNext() { moveSelection(by: 1) }
    func selectPrevious() { moveSelection(by: -1) }

    func moveSelection(by delta: Int) {
        let list = photos
        guard !list.isEmpty else { return }
        guard let current = primarySelection,
              let index = list.firstIndex(of: current) else {
            select(list[0])
            return
        }
        let next = Swift.min(Swift.max(index + delta, 0), list.count - 1)
        guard next != index else { return }
        select(list[next])
    }

    func selectAll() { selection = Set(photos.map(\.id)) }
    func selectNone() { selection = [] }

    // MARK: Culling actions

    func setFlag(_ flag: PhotoFlag) {
        mutateTargets { $0.flag = $0.flag == flag ? .none : flag }
        advanceIfNeeded()
    }

    func setRating(_ rating: Int) {
        let clamped = Swift.min(Swift.max(rating, 0), 5)
        mutateTargets { $0.rating = $0.rating == clamped ? 0 : clamped }
        advanceIfNeeded()
    }

    func setLabel(_ label: ColorLabel) {
        mutateTargets { $0.label = $0.label == label ? .none : label }
        advanceIfNeeded()
    }

    private func mutateTargets(_ body: (inout PhotoItem) -> Void) {
        let targets = Set(editTargets.map(\.id))
        guard !targets.isEmpty else { return }
        for i in allPhotos.indices where targets.contains(allPhotos[i].id) {
            body(&allPhotos[i])
            catalog?.saveCullingState(allPhotos[i])
            if allPhotos[i].id == primarySelection?.id {
                primarySelection = allPhotos[i]
            }
        }
    }

    private func advanceIfNeeded() {
        guard autoAdvance, selection.count <= 1 else { return }
        selectNext()
    }

    // MARK: Recipes

    func recipe(for photo: PhotoItem) -> Recipe {
        recipes[photo.id] ?? Recipe()
    }

    var currentRecipe: Recipe {
        primarySelection.map(recipe(for:)) ?? Recipe()
    }

    /// Every edit goes through here so history, persistence and the sidecar all see
    /// it. `coalescingKey` lets a slider drag collapse into one undo step.
    func updateRecipe(coalescingKey: String? = nil, _ mutate: (inout Recipe) -> Void) {
        let targets = editTargets
        guard !targets.isEmpty else { return }
        var before: [URL: Recipe] = [:]
        var after: [URL: Recipe] = [:]
        for photo in targets {
            let old = recipe(for: photo)
            var updated = old
            mutate(&updated)
            guard updated != old else { continue }
            before[photo.id] = old
            after[photo.id] = updated
            recipes[photo.id] = updated
        }
        guard !after.isEmpty else { return }
        history.record(before: before, after: after, coalescingKey: coalescingKey)
        persist(after)
        scheduleScopeRefresh()
    }

    private func persist(_ changes: [URL: Recipe]) {
        guard let catalog else { return }
        for (url, recipe) in changes {
            let id = allPhotos.first(where: { $0.id == url })?.catalogID
            catalog.saveRecipe(recipe, url: url, catalogID: id)
        }
    }

    func undo() {
        guard let step = history.undo() else { return }
        for (url, recipe) in step { recipes[url] = recipe }
        persist(step)
    }

    func redo() {
        guard let step = history.redo() else { return }
        for (url, recipe) in step { recipes[url] = recipe }
        persist(step)
    }

    // MARK: Copy / paste settings

    private var copiedRecipe: Recipe?
    private var copiedLook: Look?

    func copySettings() { copiedRecipe = primarySelection.map(recipe(for:)) }

    func pasteSettings() {
        guard let source = copiedRecipe else { return }
        updateRecipe { recipe in
            recipe.develop = source.develop
            recipe.look = source.look
            recipe.masks = source.masks
        }
    }

    /// Copy Look copies exactly the look-tagged slice (D4) — grade, film stock,
    /// transform preset — and nothing else. Each target keeps its own white balance,
    /// exposure and denoise, which is what makes one look across 800 frames a
    /// selection gesture rather than a copy-paste-then-fix ritual.
    func copyLook() { copiedLook = primarySelection.map { recipe(for: $0).look } }

    func pasteLook() {
        guard let look = copiedLook else { return }
        updateRecipe { $0.look = look }
    }

    func resetSettings() {
        updateRecipe { recipe in
            recipe = Recipe(pipelineVersion: recipe.pipelineVersion)
        }
    }

    // MARK: View switching

    func showGrid() { viewMode = .grid }

    func showLoupe() {
        if primarySelection == nil { primarySelection = photos.first }
        if primarySelection != nil { viewMode = .loupe }
    }

    func toggleCompare() {
        viewMode = viewMode == .compare ? .grid : .compare
    }

    func toggleSurvey() {
        viewMode = viewMode == .survey ? .grid : .survey
    }
}

#endif
