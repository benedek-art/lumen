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
import Combine
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

// MARK: - Sheets

enum SheetKind: String, Identifiable, Sendable {
    case keyReference, export, ingest
    var id: String { rawValue }
}

// MARK: - File dates

/// Modification times, remembered. A sort comparator runs O(n log n) times over the
/// same n files, and stat-ing a network volume that often is how a folder of 5,000
/// frames stops responding to a menu click.
final class FileDateCache: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [URL: Date] = [:]

    func date(for url: URL) -> Date {
        lock.lock()
        if let hit = dates[url] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let date = (attributes?[.creationDate] as? Date)
            ?? (attributes?[.modificationDate] as? Date)
            ?? Date.distantPast
        lock.lock()
        dates[url] = date
        lock.unlock()
        return date
    }
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
    /// One range, named once. The slider and the [ ] keys disagreeing meant dragging
    /// to the slider's maximum and then pressing [ snapped the grid down a step.
    static let minThumbnailSize: Double = 96
    static let maxThumbnailSize: Double = 512
    @Published var gridThumbnailSize: Double = 160
    @Published var showFilmstrip = true
    /// Published by the grid as it lays out, so ↑/↓ move by a real row rather than by
    /// a guess. Never zero — a divide-by-row-count would be a crash in the key path.
    @Published var gridColumns: Int = 6
    /// Which modal is up. Three independent booleans let two of them be true at once,
    /// which a single presenter cannot honour; these stay as the vocabulary every call
    /// site already speaks, and all three agree on one source of truth.
    @Published var activeSheet: SheetKind?

    var showKeyReference: Bool {
        get { activeSheet == .keyReference }
        set { activeSheet = newValue ? .keyReference : (showKeyReference ? nil : activeSheet) }
    }
    var showExportSheet: Bool {
        get { activeSheet == .export }
        set { activeSheet = newValue ? .export : (showExportSheet ? nil : activeSheet) }
    }
    var showIngestSheet: Bool {
        get { activeSheet == .ingest }
        set { activeSheet = newValue ? .ingest : (showIngestSheet ? nil : activeSheet) }
    }

    /// True while anything modal is on screen — the bare-key grammar stands down.
    var isPresentingSheet: Bool { activeSheet != nil }

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
    /// Switching a scope on has to fill it. `scheduleScopeRefresh` refuses to work
    /// when both are off, so without this the panel reads "no histogram yet" until the
    /// user happens to touch a slider.
    @Published var showHistogram = true { didSet { scopesBecameVisible(oldValue) } }
    @Published var showScopes = false { didSet { scopesBecameVisible(oldValue) } }
    /// The histogram and scopes for the current photo, binned from a small proxy of
    /// the actual composite off the main actor.
    @Published var scopes: ScopeData?
    var scopeGeneration: UInt64 = 0
    /// Which folder scan is the current one. Opening B while A is still enumerating
    /// must not let A's results land on top of B's.
    var scanGeneration: UInt64 = 0
    @Published var zoomLevel: Double = 0        // 0 = fit; otherwise a ratio like 1.0

    // MARK: Services

    let thumbnails = ThumbnailLoader()
    let history = HistoryStack()
    private(set) var catalog: CatalogService?
    let renderCoordinator = RenderCoordinator()

    @Published var exportRecipes: [ExportRecipe] = ExportRecipe.defaults
    @Published var isExporting = false
    @Published var exportProgress: Double = 0

    /// `HistoryStack` is its own observable object, and SwiftUI only re-renders a
    /// view for the object it observes. The Edit menu reads `state.history`, so
    /// without this the undo item's enablement only refreshed when a recipe happened
    /// to change on the same tick — correct by accident, and wrong the first time
    /// history moves on its own.
    private var historyObserver: AnyCancellable?

    init() {
        openCatalog()
        historyObserver = history.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    // MARK: Derived

    /// The photos actually on screen, after filtering and sorting.
    var photos: [PhotoItem] {
        let filtered = filter.isActive ? allPhotos.filter(filter.matches) : allPhotos
        switch sortOrder {
        case .filename:
            return filtered.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        case .captureDate:
            // Until the catalog's metadata scan lands, the file's own modification
            // time is the closest honest answer. Silently returning the list unsorted
            // made the menu item look broken rather than approximate.
            return filtered.sorted {
                let a = Self.fileDate($0.id), b = Self.fileDate($1.id)
                if a != b { return a < b }
                return $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
            }
        case .rating:
            return filtered.sorted { ($0.rating, $1.filename) > ($1.rating, $0.filename) }
        case .flag:
            return filtered.sorted { $0.flag.rawValue > $1.flag.rawValue }
        }
    }

    /// Cached so a sort does not stat the same file once per comparison.
    private static let fileDateCache = FileDateCache()

    static func fileDate(_ url: URL) -> Date {
        fileDateCache.date(for: url)
    }

    /// Everything selected, whether or not the current filter happens to be showing
    /// it. Deriving this from the filtered list meant narrowing a filter after
    /// selecting forty frames quietly shrank both the export and the count that
    /// promised what would be exported.
    var selectedPhotos: [PhotoItem] {
        allPhotos.filter { selection.contains($0.id) }
    }

    /// Brush stroke blobs this session has read or written, by reference. Content
    /// addressed, so an entry is never stale: the name IS the bytes.
    @Published private var strokeCache: [String: BrushStrokeSet] = [:]


    /// The brush blobs a recipe's masks refer to. A `strokesRef` is a promise that
    /// bytes exist somewhere; these are the bytes.
    ///
    /// Served from memory, never from the disk, because every caller is on the main
    /// actor and two of them are inside a view's `body`. Reading the blob here would
    /// be a blocking file read during layout — the exact thing the rule at the top of
    /// this file forbids. `loadStrokeSets` does the reading, off the actor, and
    /// publishes the result.
    func strokeSets(for recipe: Recipe) -> [String: BrushStrokeSet] {
        var out: [String: BrushStrokeSet] = [:]
        for mask in recipe.masks {
            for component in mask.components where component.kind == .brush {
                guard let ref = component.strokesRef, let set = strokeCache[ref] else { continue }
                out[ref] = set
            }
        }
        return out
    }

    /// A stroke set the app already holds, for the canvas to append to.
    func strokeSet(ref: String?) -> BrushStrokeSet? {
        guard let ref else { return nil }
        return strokeCache[ref]
    }

    /// Record a set the user just painted. The bytes are already in hand, so this
    /// closes the loop without a round trip through the disk.
    func remember(_ set: BrushStrokeSet, ref: String) {
        strokeCache[ref] = set
    }

    /// Pull in any blob this recipe references that is not in memory yet. Reading is
    /// off the actor; only the handoff is on it. Called when the selection changes and
    /// after a recipe arrives from the catalog, which is every moment a new `strokesRef`
    /// can appear that this session did not write.
    func loadStrokeSets(for recipe: Recipe) {
        guard let blobs = catalog?.blobs else { return }
        let missing = recipe.masks
            .flatMap(\.components)
            .filter { $0.kind == .brush }
            .compactMap(\.strokesRef)
            .filter { strokeCache[$0] == nil }
        guard !missing.isEmpty else { return }

        Task.detached(priority: .userInitiated) { [weak self] in
            var loaded: [String: BrushStrokeSet] = [:]
            for ref in missing {
                if let set = blobs.strokeSet(for: ref) { loaded[ref] = set }
            }
            guard !loaded.isEmpty else { return }
            await MainActor.run {
                guard let self else { return }
                for (ref, set) in loaded { self.strokeCache[ref] = set }
            }
        }
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
            service.onFailure = { [weak self] message in
                Task { @MainActor in
                    self?.catalogStatus = message
                    self?.statusMessage = message
                }
            }
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
        scanGeneration &+= 1
        let generation = scanGeneration
        let catalog = self.catalog
        Task.detached(priority: .userInitiated) { [weak self] in
            let found = Self.scan(url: url, extensions: extensions)
            // Registration is thousands of SQL round-trips and a sidecar read per
            // file. It stays out here, on this thread: it used to run inside the
            // main-actor hop, which stopped the run loop for the whole of a 5,000
            // frame card.
            let stored = catalog?.registerAndLoad(folder: url, files: found) ?? [:]
            await MainActor.run {
                // Open folder A, then B before A finishes, and A's scan can land
                // second. The newest folder the user asked for is the one on screen.
                guard let self, self.scanGeneration == generation else { return }
                self.applyScan(found, stored: stored)
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

    private func applyScan(_ urls: [URL], stored: [URL: CatalogService.StoredState]) {
        var items = urls.map { PhotoItem(id: $0) }
        for i in items.indices {
            if let row = stored[items[i].id] {
                items[i].catalogID = row.catalogID
                items[i].flag = row.flag
                items[i].rating = row.rating
                items[i].label = row.label
                if let recipe = row.recipe { recipes[items[i].id] = recipe }
            }
        }
        allPhotos = items
        for recipe in recipes.values where !recipe.masks.isEmpty {
            loadStrokeSets(for: recipe)
        }
        isScanning = false
        statusMessage = "\(items.count) photo\(items.count == 1 ? "" : "s")"
        if primarySelection == nil, let first = photos.first {
            select(first)
        }
    }

    // MARK: Selection

    func select(_ photo: PhotoItem, extending: Bool = false, toggling: Bool = false) {
        let changedPhoto = primarySelection?.id != photo.id
        if toggling {
            if selection.contains(photo.id) {
                selection.remove(photo.id)
            } else {
                selection.insert(photo.id)
            }
        } else if extending, let anchor = primarySelection,
                  let from = photos.firstIndex(of: anchor),
                  let to = photos.firstIndex(of: photo) {
            let range = from <= to ? from...to : to...from
            selection = Set(photos[range].map(\.id))
        } else {
            selection = [photo.id]
        }
        primarySelection = photo
        guard changedPhoto else { return }
        // Every path lands here, including ⌘-click and ⇧-click, which used to return
        // early and leave the histogram describing the previous frame.
        //
        // Mask selection is per-photo, so it does not travel: mask "c-9F3B" on this
        // photo is not the same object as mask 1 on the next one, and carrying the
        // index across would point the on-image handles at a component that is not
        // there.
        activeMaskID = nil
        activeComponentIndex = 0
        loadStrokeSets(for: recipe(for: photo))
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

    /// Clears the selection, not the cursor. `editTargets` falls back to the photo
    /// under the cursor by design — in the loupe there is always exactly one photo
    /// being edited, and clearing it would empty the viewer.
    func selectNone() { selection = [] }

    // MARK: Culling actions

    /// A cull key is one decision, not one decision per photo. Pressing P on ten
    /// photos of which three are already picked must leave ten picked — deciding
    /// per-item toggled the three back off, which is how a pass over a selection ends
    /// up with holes in it.
    func setFlag(_ flag: PhotoFlag) {
        let target: PhotoFlag = referenceItem?.flag == flag ? .none : flag
        let from = cursorIndex
        mutateTargets { $0.flag = target }
        advanceIfNeeded(from: from)
    }

    func setRating(_ rating: Int) {
        let clamped = Swift.min(Swift.max(rating, 0), 5)
        let target = referenceItem?.rating == clamped ? 0 : clamped
        let from = cursorIndex
        mutateTargets { $0.rating = target }
        advanceIfNeeded(from: from)
    }

    func setLabel(_ label: ColorLabel) {
        let target: ColorLabel = referenceItem?.label == label ? .none : label
        let from = cursorIndex
        mutateTargets { $0.label = target }
        advanceIfNeeded(from: from)
    }

    private func scopesBecameVisible(_ wasOn: Bool) {
        if !wasOn { scheduleScopeRefresh() }
    }

    /// The photo whose current state decides whether a cull key sets or clears.
    private var referenceItem: PhotoItem? {
        primarySelection ?? editTargets.first
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

    /// Advance from where the cursor WAS. `mutateTargets` may have just made the
    /// current photo fail the active filter — rejecting under a "Unflagged" filter
    /// does exactly that — and then it is no longer in `photos` to be found. Looking
    /// it up afterwards returned nil and sent the cursor to the top of the roll on
    /// every keystroke.
    private func advanceIfNeeded(from index: Int?) {
        guard autoAdvance, selection.count <= 1 else { return }
        let list = photos
        guard !list.isEmpty else { return }
        guard let current = primarySelection,
              let found = list.firstIndex(of: current) else {
            // The photo left the filtered list under us. Its old neighbour is the
            // honest place to land.
            if let index {
                select(list[Swift.min(index, list.count - 1)])
            }
            return
        }
        guard found + 1 < list.count else { return }
        select(list[found + 1])
    }

    /// Where the cursor sits in the list as it stands right now.
    private var cursorIndex: Int? {
        guard let current = primarySelection else { return nil }
        return photos.firstIndex(of: current)
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
        var touchedPixels = false
        for photo in targets {
            let old = recipe(for: photo)
            var updated = old
            mutate(&updated)
            guard updated != old else { continue }
            if !updated.rendersSameAs(old) { touchedPixels = true }
            before[photo.id] = old
            after[photo.id] = updated
            recipes[photo.id] = updated
        }
        guard !after.isEmpty else { return }
        history.record(before: before, after: after, coalescingKey: coalescingKey)
        persist(after)
        // Renaming a mask changes the recipe without changing the picture. Re-binning
        // the scopes for it would mean a proxy render per keystroke.
        if touchedPixels { scheduleScopeRefresh() }
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
        scheduleScopeRefresh()
    }

    func redo() {
        guard let step = history.redo() else { return }
        for (url, recipe) in step { recipes[url] = recipe }
        persist(step)
        scheduleScopeRefresh()
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
