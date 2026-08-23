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
    /// Everything CIRAWFilter will decode. The short list this started as made a
    /// Hasselblad, Phase One, Leica or Minolta file invisible in the grid and uncounted
    /// by the ingest planner — not an error the user could act on, just an empty folder
    /// where their shoot was.
    static let raw: Set<String> = [
        "arw", "sr2", "srf", "arq",              // Sony
        "cr2", "cr3", "crw",                     // Canon
        "nef", "nrw",                            // Nikon
        "orf",                                   // Olympus / OM
        "pef", "dng",                            // Pentax, and the open format
        "raf",                                   // Fujifilm
        "rw2",                                   // Panasonic
        "rwl",                                   // Leica
        "srw",                                   // Samsung
        "erf",                                   // Epson
        "x3f",                                   // Sigma
        "3fr", "fff",                            // Hasselblad
        "iiq", "cap",                            // Phase One
        "mrw",                                   // Minolta
        "dcr", "kdc",                            // Kodak
        "mef",                                   // Mamiya
        "raw",                                   // generic
    ]
    static let rendered: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff",
    ]
    static let browsable: Set<String> = raw.union(rendered)

    static func isRaw(_ url: URL) -> Bool {
        raw.contains(url.pathExtension.lowercased())
    }

    /// Already-rendered files, which decode through `RenderedImageSource` rather than
    /// the RAW stage. A sibling of `isRaw` so callers do not each write the
    /// lowercase-the-extension dance and drift apart on the one that forgets.
    static func isRendered(_ url: URL) -> Bool {
        rendered.contains(url.pathExtension.lowercased())
    }
}

// MARK: - Photo

struct PhotoItem: Identifiable, Hashable, Sendable {
    let id: URL
    var catalogID: Int64?
    var flag: PhotoFlag = .none
    var rating: Int = 0
    var label: ColorLabel = .none
    /// What the file says it was shot at, from the catalog's EXIF row. It is what makes
    /// an unedited photo's noise-reduction defaults ISO-adaptive; nil until the
    /// metadata backfill has reached this photo, and nil forever for a file that
    /// records no ISO, in which case the flat wire defaults stand.
    var iso: Int?

    var filename: String { id.lastPathComponent }
    var isRaw: Bool { PhotoFormats.isRaw(id) }

    static func == (a: PhotoItem, b: PhotoItem) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// What a click on the image is being collected for.
enum PickTarget: Equatable, Sendable {
    /// Solve Temp/Tint so the clicked pixel is grey.
    case neutral
    /// Append a Point Colour swatch carrying the clicked colour.
    case newPointColor
    /// Re-sample an existing swatch.
    case pointColor(index: Int)
    /// Add a sample to a Colour Range or Similarity mask component.
    case maskSample(maskID: String, component: Int)
    /// Append a Point Colour swatch to a mask's own sub-recipe.
    case maskPointColor(maskID: String)

    /// True for the targets whose value is compared against the LOCAL STAGE INPUT
    /// rather than against the linear stage's output.
    ///
    /// The global Point Colour swatches are deliberately not on this list, and that is
    /// not because they are correct — `ColorEngine` evaluates them inside the S9/S10
    /// table, whose input already carries S7 tone, so a global swatch has the same
    /// class of divergence one stage smaller. Moving it is a change to what the colour
    /// panel's eyedropper means and belongs with that panel.
    var samplesTheMaskStage: Bool {
        switch self {
        case .maskSample, .maskPointColor: return true
        case .neutral, .newPointColor, .pointColor: return false
        }
    }

    /// What the status line says while the click is being waited for.
    var prompt: String {
        switch self {
        case .neutral: return "Click something neutral grey in the picture."
        case .newPointColor, .pointColor: return "Click the colour to work on."
        case .maskSample: return "Click the colour this mask should select."
        case .maskPointColor: return "Click the colour to work on inside this mask."
        }
    }
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
    case zones = "Zones"
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
        case .zones: return "square.stack.3d.down.right"
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

/// ISO as a chip: bands rather than a free-form pair of numbers, because the question
/// a photographer actually asks a filter is "show me the clean ones" or "show me the
/// ones that will need denoise", and because a band is one click.
enum ISOBand: String, CaseIterable, Identifiable, Sendable {
    case upTo400 = "≤ 400"
    case to1600 = "401–1600"
    case to6400 = "1601–6400"
    case above6400 = "≥ 6401"

    var id: String { rawValue }

    var range: ClosedRange<Int> {
        switch self {
        case .upTo400: return 0...400
        case .to1600: return 401...1600
        case .to6400: return 1601...6400
        case .above6400: return 6401...4_000_000
        }
    }
}

/// The stack-state chip (docs/10 §10.2): everything, one row per collapsed stack, or
/// only the frames that were never grouped.
enum StackFilter: String, CaseIterable, Identifiable, Sendable {
    case any = "All frames"
    case collapsedTops = "Collapsed stacks"
    case unstacked = "Unstacked only"

    var id: String { rawValue }
}

struct LibraryFilter: Equatable, Sendable {
    /// Criteria OR within themselves and AND across themselves — the day-one rule
    /// (D39). An empty set means "no constraint from this criterion". `matchAny` is
    /// the bar's All/Any toggle and flips the join BETWEEN criteria, never within one.
    var flags: Set<PhotoFlag> = []
    var minRating: Int = 0
    var labels: Set<ColorLabel> = []
    var text: String = ""
    var rawOnly: Bool = false

    /// nil = no constraint, true = has an edit that changes the picture, false = as
    /// shot. Reads `photo.edited`, which `saveRecipe` maintains in the same transaction
    /// as the recipe — no join, no parse, and true only when the recipe actually
    /// renders differently.
    var edited: Bool? = nil
    var cameras: Set<String> = []
    var lenses: Set<String> = []
    var isoBands: Set<ISOBand> = []
    var stackState: StackFilter = .any
    var keywords: Set<String> = []
    var matchAny: Bool = false

    /// The criteria that only exist in SQL. The memory fallback cannot evaluate any of
    /// them — it has no camera, no ISO and no stack table — so the bar hides these
    /// chips rather than offering controls that would quietly do nothing.
    var usesCatalogOnlyCriteria: Bool {
        edited != nil || !cameras.isEmpty || !lenses.isEmpty || !isoBands.isEmpty
            || stackState != .any || !keywords.isEmpty
    }

    var isActive: Bool {
        !flags.isEmpty || minRating > 0 || !labels.isEmpty || !text.isEmpty || rawOnly
            || usesCatalogOnlyCriteria
    }

    /// The memory path, used only when there is no catalog to ask. It answers the five
    /// criteria a `PhotoItem` can answer and is deliberately not extended past them:
    /// a filter that silently ignores a lit chip is the failure this file exists to
    /// avoid, which is why the bar hides those chips in this mode instead.
    func matches(_ photo: PhotoItem) -> Bool {
        if !flags.isEmpty && !flags.contains(photo.flag) { return false }
        if photo.rating < minRating { return false }
        if !labels.isEmpty && !labels.contains(photo.label) { return false }
        if rawOnly && !photo.isRaw { return false }
        if !text.isEmpty
            && !photo.filename.localizedCaseInsensitiveContains(text) { return false }
        return true
    }

    /// The bar, compiled. Every chip becomes an indexed predicate in `CatalogStore`'s
    /// builder — which was 200 lines of correct, tested SQL with no caller at all while
    /// this struct filtered five criteria with a linear scan of the roll.
    func query(sort: SortOrder, ascending: Bool, albumID: Int64?) -> PhotoQuery {
        var query = PhotoQuery()
        query.flags = flags.map(CatalogService.coreFlag)
        if minRating > 0 {
            query.rating = minRating
            query.ratingComparison = .atLeast
        }
        for label in labels {
            if let core = CatalogService.coreLabel(label) {
                query.labels.append(core)
            } else {
                // `.none` in the app's vocabulary is "unlabelled", which is a NULL in
                // the catalog's and therefore its own predicate — `label IN (…)` can
                // never match a NULL.
                query.includeUnlabeled = true
            }
        }
        if rawOnly { query.fileTypes = PhotoFormats.raw.sorted() }
        query.edited = edited
        query.cameras = cameras.sorted()
        query.lenses = lenses.sorted()
        query.keywords = keywords.sorted()
        if !isoBands.isEmpty {
            // One predicate per lit band, OR-ed — NOT one range spanning them all.
            //
            // This used to take the minimum lower bound and the maximum upper bound and
            // call the span "the honest reading of OR within a criterion". It is not:
            // lighting "≤ 400" and "≥ 6401" asked for two bands and returned every ISO
            // 800 frame between them. Adjacent bands still collapse naturally, because
            // adjacent BETWEENs cover the same rows either way.
            query.isoRanges = isoBands.map { $0.range }.sorted { $0.lowerBound < $1.lowerBound }
        }
        switch stackState {
        case .any: query.stackState = .any
        case .collapsedTops: query.stackState = .collapsedTopsOnly
        case .unstacked: query.stackState = .unstacked
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        query.text = trimmed.isEmpty ? nil : trimmed
        query.matchAny = matchAny
        query.albumID = albumID
        // The grid shows files that are on the disk. Rows for frames that have gone
        // offline keep their edits and stay findable, but putting them in the contact
        // sheet would put cells in it that cannot be opened.
        query.includeMissing = false
        query.sortKey = sort.sortKey
        query.ascending = ascending
        return query
    }
}

/// The twelve sort keys docs/10 §10.2 specifies, one per `PhotoQuery.SortKey`.
///
/// Four of them used to exist, and "capture time" was the file's modification time —
/// which is the time the card was copied, not the time the shutter opened, and on a
/// re-copied card is simply today. Everything here now orders in SQL over the EXIF the
/// backfill pass writes.
enum SortOrder: String, CaseIterable, Identifiable, Sendable {
    case captureTime = "Capture time"
    case addedOrder = "Added order"
    case editTime = "Edit time"
    case rating = "Rating"
    case flag = "Flag"
    case label = "Label"
    case filename = "File name"
    case fileType = "File type"
    case aspectRatio = "Aspect ratio"
    /// The order photos were ADDED to the album, not one the user arranged.
    ///
    /// It was called "User order" and captioned "drag to reorder inside an album", and
    /// there is no drag-reorder anywhere in Lumen — `onMove` appears in no file, and
    /// `album_photo.position` has exactly one writer, `addToAlbum`, which assigns
    /// `MAX(position) + 1` per photo at insert. Nothing can change a position
    /// afterwards except removing the photo and adding it again. The spec still asks
    /// for the gesture (docs/10 §sort keys); the menu no longer claims it is here.
    case userOrder = "Album order"
    case sharpness = "Sharpness score"
    case aesthetic = "Aesthetic score"

    var id: String { rawValue }

    var sortKey: PhotoQuery.SortKey {
        switch self {
        case .captureTime: return .captureTime
        case .addedOrder: return .addedOrder
        case .editTime: return .editTime
        case .rating: return .rating
        case .flag: return .flag
        case .label: return .label
        case .filename: return .filename
        case .fileType: return .fileType
        case .aspectRatio: return .aspectRatio
        case .userOrder: return .userOrder
        case .sharpness: return .sharpness
        case .aesthetic: return .aesthetic
        }
    }

    /// The keys a roll of `PhotoItem`s can order on its own, for the sessions where the
    /// catalog would not open. The rest need columns only the catalog has.
    var worksFromMemory: Bool {
        switch self {
        case .filename, .rating, .flag, .label: return true
        default: return false
        }
    }

    /// Why this key is not offered right now, or nil when it is live. Shown next to the
    /// disabled item in the menu: an ordering that silently does nothing is worse than
    /// one that says what it is waiting for.
    static let scoreSortsPending =
        "waiting on the culling analysis pass, which does not run yet"
}

// MARK: - Library sections

/// One album as the sidebar shows it. A view-shaped value rather than `CollectionRow`,
/// so the sidebar never has to know a database row exists — and so the membership
/// count travels with the name instead of being a second query per row.
struct CollectionItem: Identifiable, Equatable, Sendable {
    let id: Int64
    var name: String
    var count: Int
    var isTarget: Bool
}

/// One value a metadata chip offers — a keyword, a camera body — and how many photos
/// carry it. The live counts docs/10 §10.8 asks for ("Sony A7 IV (1,203)"), computed by
/// the same indexes the chip's predicate uses, so the number and the result agree.
struct LibraryFacet: Identifiable, Equatable, Sendable {
    var name: String
    var count: Int

    var id: String { name }
}

/// The stack the photo under the cursor is in, as the sidebar needs it.
struct StackSummary: Equatable, Sendable {
    var id: Int64
    var memberCount: Int
    var collapsed: Bool
    /// True when this photo is the frame a collapsed stack shows.
    var isPick: Bool
}

// MARK: - Sheets

enum SheetKind: String, Identifiable, Sendable {
    case keyReference, export, ingest
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
    @Published private(set) var allPhotos: [PhotoItem] = [] {
        didSet { invalidatePhotoCache() }
    }
    @Published var filter = LibraryFilter() {
        didSet {
            invalidatePhotoCache()
            filterOrSortChanged(oldValue)
        }
    }
    /// Capture time is the default docs/10 §10.2 asks for. It is only honest now that
    /// something writes `capture_at`: before the EXIF backfill landed this key meant
    /// the file's modification time, which is when the card was copied.
    @Published var sortOrder: SortOrder = .captureTime {
        didSet {
            guard sortOrder != oldValue else { return }
            invalidatePhotoCache()
            refreshLibraryQuery()
            saveSourceState()
        }
    }
    @Published var sortAscending: Bool = true {
        didSet {
            guard sortAscending != oldValue else { return }
            invalidatePhotoCache()
            refreshLibraryQuery()
            saveSourceState()
        }
    }
    @Published var selection: Set<URL> = []
    @Published var primarySelection: PhotoItem? {
        didSet {
            guard primarySelection?.id != oldValue?.id else { return }
            primaryFrameSize = nil
            primaryAsShotNeutral = nil
            refreshPrimaryFrameSize()
            refreshPrimaryAsShotNeutral()
            refreshPrimaryLibraryDetail()
            // A photo whose recipe already carries a Subject mask needs its matte
            // before the first frame is worth looking at; the call is a no-op for the
            // overwhelming majority of photographs, which have no AI component at all.
            ensureMaskMattes()
        }
    }

    /// Width ÷ height of the primary selection's decoded frame; nil until it is known.
    ///
    /// The crop ratio menu cannot work without it. A crop is stored normalized to the
    /// source frame, so turning "1:1" into a rectangle needs the frame's own aspect —
    /// and `EffectsPanel` was constructed with no aspect at all, so it always fell back
    /// to an assumed 3:2. On a Micro-Four-Thirds or any 4:3 body, "1:1" produced an 8:9
    /// portrait rectangle and "16:9" produced 1.58:1; on a portrait-orientation frame
    /// every ratio came out roughly half of what the menu said. The menu then read the
    /// result back through the same assumption and reported it as "Custom".
    /// Also what the on-image mask tools need: a mask component is stored normalized to
    /// the source frame, and every gesture arrives in the cropped preview's frame, so
    /// converting between them needs the source's real pixel extent and not just its
    /// shape.
    @Published private(set) var primaryFrameSize: CGSize?

    var primaryFrameAspect: Double? {
        guard let size = primaryFrameSize, size.height > 0 else { return nil }
        return Double(size.width / size.height)
    }

    /// The active mask's alpha, rasterized for the loupe overlay.
    ///
    /// Nothing produced this before, so `MaskOverlayView` always fell back to a flat
    /// tint over the whole frame — which reads as "this mask selects everything" and
    /// was the app's only way to look at a mask.
    ///
    /// A `Plane` of numbers rather than a `CGImage`: the six overlay modes composite
    /// the alpha against the picture per pixel, and the CGImage form was being used as
    /// a SwiftUI `.mask`, which reads an alpha channel the grey image did not have.
    @Published private(set) var maskOverlayAlpha: Plane?

    /// Which of the six overlay modes the loupe draws, and in which colour
    /// (docs/08 §8.6). `⌥O` cycles the mode, `⇧O` the colour, and both are also in
    /// the mask panel so neither needs a key to be discovered.
    @Published var maskOverlayMode: MaskOverlay.Mode = .colorOverlay
    @Published var maskOverlayTint: MaskOverlay.Tint = .red

    private var maskOverlayGeneration: Int = 0

    /// Rebuild it for the mask the panel is showing. Superseded by generation, like
    /// every other background render here, so a fast sequence of edits does not land
    /// out of order.
    func refreshMaskOverlay() {
        maskOverlayGeneration &+= 1
        let generation = maskOverlayGeneration
        guard let maskID = soloMaskOverlay, let photo = primarySelection else {
            maskOverlayAlpha = nil
            return
        }
        let recipe = recipe(for: photo)
        let strokes = strokeSets(for: recipe)
        Task { [weak self] in
            guard let self else { return }
            let raster = await self.renderCoordinator.maskAlpha(
                url: photo.id, recipe: recipe, maskID: maskID, strokeSets: strokes)
            guard self.maskOverlayGeneration == generation else { return }
            self.maskOverlayAlpha = raster
        }
    }

    /// Which AI matte kinds each file has, so the views that consume them can go stale
    /// when one arrives.
    ///
    /// The mattes themselves live in the renderer's cache, behind the render actor —
    /// this is only the ledger of what exists. It is published because the loupe's
    /// render key has to mention it: a matte arrives asynchronously, exactly like a
    /// brush blob, and a `.task(id:)` that does not name it renders the mask empty and
    /// stays that way until an unrelated edit moves the recipe.
    @Published private(set) var availableMattes: [URL: Set<String>] = [:]
    /// Which KINDS a generation pass has already finished for, per file, whatever it
    /// found. Separate from `pendingMattes` so "still working" and "looked and found
    /// nothing" are different states — the panel says different things about them.
    ///
    /// This was a `Set<URL>`: a file was attempted or it was not. Two consequences,
    /// both shipped. Adding a Subject mask ran the pass for `{aiSubject}` and marked
    /// the FILE done, so adding a People mask afterwards never generated its matte and
    /// the panel reported "Vision found no person in this frame" about a request
    /// nobody had made. And it was never trimmed, while the renderer's matte cache is
    /// bounded at twelve files — so after browsing thirteen photographs with Vision
    /// masks, the first one's entry here said ready about a matte that had been
    /// evicted, the mask rendered as nothing, and no edit could clear it.
    ///
    /// Both entries below are a COPY of state `PipelineRenderer` owns. They are
    /// replaced from its answer on every pass and dropped when it says a file was
    /// evicted; nothing here decides on its own that a pass can be skipped.
    private var attemptedMattes: [URL: Set<String>] = [:]
    private var pendingMattes: Set<URL> = []

    func maskMatteKinds(for url: URL) -> Set<String> { availableMattes[url] ?? [] }

    /// What to tell the user about one AI component (docs/08 §8.7: errors are specific
    /// and actionable, never "Something went wrong").
    enum MatteStatus {
        /// Rasterized from geometry or the picture — no matte involved.
        case notNeeded
        /// Vision can produce it and has not been asked yet, or is working.
        case working
        /// Vision produced one.
        case ready
        /// Vision ran and found nothing in this photograph.
        case notFound
        /// Needs a Core ML model that is not bundled.
        case needsModel
    }

    func matteStatus(for kind: MaskKind) -> MatteStatus {
        switch kind.matteProvider {
        case .none: return .notNeeded
        case .model: return .needsModel
        case .vision:
            guard let url = primarySelection?.id else { return .working }
            if maskMatteKinds(for: url).contains(kind.rawValue) { return .ready }
            if pendingMattes.contains(url) { return .working }
            // Per KIND. Asking whether the FILE had been attempted made this say
            // NOTHING FOUND about a kind added after the pass ran — a specific,
            // actionable error message about a request that was never issued, which is
            // worse than a vague one.
            return (attemptedMattes[url] ?? []).contains(kind.rawValue)
                ? .notFound : .working
        }
    }

    /// Ask for whatever Vision mattes the current photo's masks need. Cheap and
    /// idempotent: it returns immediately when the recipe has no AI component at all,
    /// which is the overwhelming majority of photographs, and the coordinator's own
    /// fast path is two dictionary lookups when every kind has already been tried.
    ///
    /// There is deliberately NO "this file was already attempted" short circuit here.
    /// The ledger below is a copy of a bounded cache the renderer owns, so a guard
    /// written against it can only be as fresh as the last thing that happened to tell
    /// it — and the thing that used to be missing, an eviction, is exactly the case
    /// where skipping the pass renders the mask as nothing. The authoritative check
    /// lives beside the cache, in `RenderCoordinator.ensureMattes`.
    func ensureMaskMattes() {
        guard let photo = primarySelection else { return }
        let url = photo.id
        let recipe = recipe(for: photo)
        guard !VisionMattes.kinds(in: recipe).isEmpty else { return }
        guard !pendingMattes.contains(url) else { return }
        pendingMattes.insert(url)
        Task { [weak self] in
            guard let self else { return }
            // `await`: the coordinator is an actor, and the segmentation it runs is on
            // a third one, so neither this actor nor the render loop is blocked.
            let pass = await self.renderCoordinator.ensureMattes(url: url, recipe: recipe)
            self.pendingMattes.remove(url)
            self.applyMattePass(pass, for: url)
        }
    }

    /// Replace this file's ledger with what the renderer reported, and drop every file
    /// it says it evicted.
    ///
    /// The eviction half is not housekeeping. `LoupeView`'s render key names
    /// `availableMattes` precisely so that a matte ARRIVING re-renders the frame — and
    /// a matte that was evicted and then regenerated arrives at the same value it had
    /// before, so unless the entry is removed when the eviction is reported the key
    /// never moves and the loupe keeps showing the empty-mask render.
    private func applyMattePass(_ pass: MattePass, for url: URL) {
        for dropped in pass.evicted where dropped != url {
            attemptedMattes.removeValue(forKey: dropped)
            if availableMattes[dropped] != nil {
                availableMattes.removeValue(forKey: dropped)
            }
        }
        attemptedMattes[url] = pass.attempted
        let before = availableMattes[url]
        if pass.available.isEmpty {
            if before != nil { availableMattes.removeValue(forKey: url) }
        } else if before != pass.available {
            availableMattes[url] = pass.available
        }
        // The overlay is a picture of the mask, and the mask only changed if this did.
        if before != availableMattes[url] { refreshMaskOverlay() }
    }

    /// `O`: show or hide the overlay for the mask the panel has selected. With no mask
    /// selected there is nothing to show, so the key does nothing rather than picking
    /// a mask on the user's behalf.
    func toggleMaskOverlay() {
        if soloMaskOverlay != nil {
            soloMaskOverlay = nil
            return
        }
        guard let id = activeMaskID ?? currentRecipe.masks.first?.id else { return }
        soloMaskOverlay = id
    }

    /// `⌥O` and `⇧O`: cycle the mode and the colour. Cycling either turns the overlay
    /// ON if it is off — pressing a key that changes how a thing is drawn and seeing
    /// nothing happen is how a user concludes the key is broken.
    func cycleMaskOverlayMode() {
        maskOverlayMode = maskOverlayMode.next
        if soloMaskOverlay == nil { toggleMaskOverlay() }
    }

    func cycleMaskOverlayTint() {
        maskOverlayTint = maskOverlayTint.next
        if soloMaskOverlay == nil { toggleMaskOverlay() }
    }

    /// `'`: invert the component the mask panel has selected (docs/08 §8.6).
    func invertActiveMaskComponent() {
        guard let id = activeMaskID ?? currentRecipe.masks.first?.id else { return }
        let index = activeComponentIndex
        updateRecipe(coalescingKey: nil) { recipe in
            guard let m = recipe.masks.firstIndex(where: { $0.id == id }),
                  recipe.masks[m].components.indices.contains(index) else { return }
            recipe.masks[m].components[index].invert.toggle()
        }
    }

    private func refreshPrimaryFrameSize() {
        guard let url = primarySelection?.id else { return }
        // Off the synchronous path: the first call for a photo opens the file to read
        // its header. For the frame in the loupe the decode is already cached, so this
        // is usually a property read — but selection changes must never wait on it.
        Task { [weak self] in
            guard let self else { return }
            // `await`: RenderCoordinator is an actor, and reading a photo's native size
            // is a hop onto it.
            guard let size = await self.renderCoordinator.nativeSize(for: url),
                  size.width > 0, size.height > 0 else { return }
            // The selection can have moved on across that hop.
            guard self.primarySelection?.id == url else { return }
            self.primaryFrameSize = CGSize(width: size.width, height: size.height)
        }
    }

    /// The neutral the primary selection was shot at; nil until the source has answered.
    ///
    /// The White Balance rows need it and had no way to get it: `raw.temp` nil means
    /// "as shot", the slider has to stand a number in while the field is nil, and the
    /// number it stood in was the literal 5500 for every file in the library. nil here
    /// means "not known yet" and the rows say so rather than showing a number that is
    /// not this photograph's — the same rule DetailPanel follows for the ISO the
    /// denoise profile resolves against.
    @Published private(set) var primaryAsShotNeutral: WhiteBalanceEngine.Neutral?

    private func refreshPrimaryAsShotNeutral() {
        guard let url = primarySelection?.id else { return }
        // Same shape and the same reasoning as `refreshPrimaryFrameSize`: the first call
        // for a photo opens the file, and a selection change must never wait on it.
        Task { [weak self] in
            guard let self else { return }
            guard let neutral = await self.renderCoordinator.asShotNeutral(for: url)
            else { return }
            guard self.primarySelection?.id == url else { return }
            self.primaryAsShotNeutral = neutral
        }
    }

    /// The units the pixel readout speaks, everywhere it appears.
    ///
    /// One home, because there were two: the histogram panel's segmented control wrote
    /// a view-local `@State`, and the loupe's on-image HUD read `LoupeViewport
    /// .readoutSpace`, which nothing ever assigned. Switching the histogram to % or
    /// 0–1 left the readout under the cursor in sRGB 0–255 forever.
    @Published var readoutSpace: ReadoutSpace = .srgb255

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
    @Published var gridThumbnailSize: Double = 160 {
        didSet { scheduleSourceStateSave() }
    }
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
    /// What the next click on the image is FOR, if anything. The picker overlay only
    /// exists while this is set, so it can never eat a pan or a click-to-zoom the rest
    /// of the time.
    ///
    /// One target rather than a flag per consumer: every colour tool in the app needs
    /// the same click and the same coordinate inverse, and four booleans would be four
    /// chances for two of them to be true at once.
    @Published var pickTarget: PickTarget?
    /// Which mask the loupe is showing as an overlay, if any. Setting it rasterizes
    /// that mask's alpha.
    @Published var soloMaskOverlay: String? {
        didSet {
            guard soloMaskOverlay != oldValue else { return }
            refreshMaskOverlay()
        }
    }
    /// Which mask and component the panel has selected. Published because the on-image
    /// canvas edits geometry and lives in the viewer, not the panel.
    @Published var activeMaskID: String?
    @Published var activeComponentIndex: Int = 0
    @Published var clippingOverlay: ClippingOverlay.Mode?
    /// The soft proof, which is a VIEWING mode and not an edit (docs/11) — so it lives
    /// here beside the clipping overlay rather than in the recipe, and switching photos
    /// or copying settings never carries it along.
    ///
    /// `SoftProof` and its gamut test have been in `LumenCore` since the export model
    /// landed with no caller of any kind. What made it reach pixels is that it now
    /// travels to `RenderPlan`, which bakes the destination transform into the finish
    /// table both render paths apply, and to `RenderGraph`'s flag stage.
    @Published var softProof = SoftProof()

    /// What the renderer should be handed: nil unless proofing is actually on, so a
    /// disabled proof cannot cost a table bake or bust a render key.
    var activeSoftProof: SoftProof? { softProof.enabled ? softProof : nil }
    /// Switching a scope on has to fill it. `scheduleScopeRefresh` refuses to work
    /// when both are off, so without this the panel reads "no histogram yet" until the
    /// user happens to touch a slider.
    @Published var showHistogram = true { didSet { scopesBecameVisible(oldValue) } }
    @Published var showScopes = false { didSet { scopesBecameVisible(oldValue) } }
    /// The histogram and scopes for the current photo, binned from a small proxy of
    /// the actual composite off the main actor.
    @Published var scopes: ScopeData?
    var scopeGeneration: UInt64 = 0

    /// `⇧H` — the cull-time clipping panel (docs/10 §10.5, README goal 3).
    ///
    /// A separate switch from `showHistogram` because the two instruments measure
    /// different images and answer different questions. The histogram bins the render;
    /// this bins the decoded scene-linear frame, before every Lumen stage and before
    /// the display transform, and reports per-channel clipped percentages. It is not
    /// the sensor's mosaic — nothing here can read one — and `RawTruth` supplies the
    /// words the panel uses to say so.
    @Published var showRawTruth = false { didSet { rawTruthBecameVisible(oldValue) } }
    /// The measurement for `primarySelection`, from the cache when there is one.
    @Published var rawTruth: RawStatistics?
    /// How the measurement in hand was taken, when it was taken this session. Nil for
    /// one read back from the cache — the row records its own site stride and the
    /// readout rebuilds the caption from that.
    @Published var rawTruthPlan: RawTruth.Plan?
    /// Set while a measurement is being taken, so the panel can say "measuring" rather
    /// than showing the last photo's numbers under this photo's name.
    @Published var rawTruthMeasuring = false
    var rawTruthGeneration: UInt64 = 0
    /// The inspection currently held down (`[` / `]`), or nil. Never written to a
    /// recipe: it is a display gain over the frame already on screen.
    @Published var inspectionHold: InspectionHold?
    /// Which folder scan is the current one. Opening B while A is still enumerating
    /// must not let A's results land on top of B's.
    var scanGeneration: UInt64 = 0
    @Published var zoomLevel: Double = 0        // 0 = fit; otherwise a ratio like 1.0

    // MARK: Services

    let thumbnails = ThumbnailLoader()
    let history = HistoryStack()
    private(set) var catalog: CatalogService?
    /// The disk preview cache. Lives beside the catalog because it is bookkeeping in
    /// `cache.preview` plus payloads under `~/Library/Caches/Lumen`, and nil when the
    /// catalog could not be opened — a session without one browses out of memory, which
    /// is what every session did before this was wired.
    private(set) var previews: PreviewStore?
    let renderCoordinator = RenderCoordinator()

    /// The export recipes, as edited. Persisted on every change.
    ///
    /// This was pure memory: no UserDefaults, no @AppStorage, and nothing anywhere
    /// reads or writes the `export_recipe` table the schema declares. The sheet's +,
    /// duplicate and delete buttons and every setting on them — watermark text, naming
    /// template, subfolder, size, colour space — survived exactly as long as the
    /// process, and relaunching put the four stock recipes back with no warning.
    ///
    /// Written on `didSet` rather than at quit, because a crash must not cost the user
    /// the delivery preset they just built.
    /// A computed property rather than `= loadExportRecipes()`, because an initializer
    /// that ends in a call followed by a brace block is the trailing-closure ambiguity
    /// Swift is strict about in property declarations. No parentheses, no ambiguity.
    @Published var exportRecipes: [ExportRecipe] = AppState.storedExportRecipes {
        didSet {
            guard exportRecipes != oldValue else { return }
            AppState.saveExportRecipes(exportRecipes)
        }
    }

    private static let exportRecipesKey = "dev.lumenapp.exportRecipes"

    private static var storedExportRecipes: [ExportRecipe] { loadExportRecipes() }

    private static func loadExportRecipes() -> [ExportRecipe] {
        guard let data = UserDefaults.standard.data(forKey: exportRecipesKey),
              let stored = try? JSONDecoder().decode([ExportRecipe].self, from: data),
              !stored.isEmpty else {
            return ExportRecipe.defaults
        }
        return stored
    }

    private static func saveExportRecipes(_ recipes: [ExportRecipe]) {
        guard let data = try? JSONEncoder().encode(recipes) else {
            // Nothing to do but keep the last good copy: overwriting it with nothing
            // would turn a serialization bug into the loss of the user's presets.
            NSLog("Lumen: could not serialize the export recipes; left the stored "
                  + "copy alone")
            return
        }
        UserDefaults.standard.set(data, forKey: exportRecipesKey)
    }
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
    ///
    /// The order comes from SQL when there is a catalog to ask, and the *contents* of
    /// each cell come from `allPhotos`, which is the copy a cull keystroke has already
    /// updated. Reading the badges out of the query result instead would make every
    /// rating lag by one database round trip.
    /// Memoised, because this is read on the hot path and used to be rebuilt every time.
    ///
    /// Measured at 5,000 photos in a release build: 1.68 ms to build the URL-keyed
    /// dictionary and map the order, plus 2.41 ms more when filename sort adds the
    /// `localizedStandardCompare` pass. `GridView`, `FilterBar`, `ContentView` (twice),
    /// `FilmstripView`, `cursorIndex` and `advanceIfNeeded` all read it, and every
    /// `@Published` write on this object re-evaluates the bodies that do — so one
    /// slider event was paying it around seven times, ~12 ms of main-actor work per
    /// mouse move at 5,000 frames and ~85 ms at 50,000, before a single pixel was asked
    /// for. The 8.3 ms frame budget was gone to bookkeeping.
    ///
    /// The cache is keyed on everything the computation reads. Getting that wrong shows
    /// a stale contact sheet, so the invalidation lives in `invalidatePhotoCache()` and
    /// every mutation of those four inputs calls it.
    private var photoCache: [PhotoItem]?

    func invalidatePhotoCache() { photoCache = nil }

    var photos: [PhotoItem] {
        if let photoCache { return photoCache }
        let built = buildPhotos()
        photoCache = built
        return built
    }

    private func buildPhotos() -> [PhotoItem] {
        guard let order = libraryOrder else { return memoryOrdered() }
        var byURL = [URL: PhotoItem](minimumCapacity: allPhotos.count)
        for item in allPhotos { byURL[item.id] = item }
        let ordered = order.compactMap { byURL[$0] }
        guard sortOrder == .filename else { return ordered }
        // SQLite orders TEXT by bytes, so `DSC_10` sorts before `DSC_9`. Every camera
        // this will meet zero-pads its counter, which is why the two agree almost
        // always — but "almost" is how a frame ends up in the wrong place in a contact
        // sheet, and Finder-order is what a photographer means by file name.
        return ordered.sorted {
            let comparison = $0.filename.localizedStandardCompare($1.filename)
            return sortAscending ? comparison == .orderedAscending
                                 : comparison == .orderedDescending
        }
    }

    /// The path for a session with no catalog: filter and sort the roll in memory.
    ///
    /// Deliberately narrow. It answers only the keys a `PhotoItem` can answer, and the
    /// filter bar hides the chips and sort keys it cannot honour while this is what is
    /// running — an app that silently ignores a lit chip is worse than one that admits
    /// the catalog is gone.
    private func memoryOrdered() -> [PhotoItem] {
        let filtered = filter.isActive ? allPhotos.filter(filter.matches) : allPhotos
        let ascending = sortAscending
        func by(_ ordered: Bool) -> Bool { ascending ? ordered : !ordered }
        switch sortOrder {
        case .rating:
            return filtered.sorted { by($0.rating < $1.rating) }
        case .flag:
            return filtered.sorted { by($0.flag.rawValue < $1.flag.rawValue) }
        case .label:
            return filtered.sorted { by($0.label.rawValue < $1.label.rawValue) }
        default:
            return filtered.sorted {
                by($0.filename.localizedStandardCompare($1.filename) == .orderedAscending)
            }
        }
    }

    /// Everything selected, whether or not the current filter happens to be showing
    /// it. Deriving this from the filtered list meant narrowing a filter after
    /// selecting forty frames quietly shrank both the export and the count that
    /// promised what would be exported.
    var selectedPhotos: [PhotoItem] {
        allPhotos.filter { selection.contains($0.id) }
    }

    // MARK: The library query

    /// What the catalog's query returned, in its order, or nil when there is nothing to
    /// ask — no catalog, no folder, or the first query has not come back yet.
    @Published private(set) var libraryOrder: [URL]? {
        didSet { invalidatePhotoCache() }
    }

    /// True while the grid is being decided by SQL. The filter bar reads this to know
    /// which chips it is allowed to offer.
    var isLibraryQueryLive: Bool { libraryOrder != nil }

    private var libraryQueryGeneration: UInt64 = 0

    /// Which album is the source, or nil for the whole open folder.
    @Published var selectedCollectionID: Int64? {
        didSet { if selectedCollectionID != oldValue { refreshLibraryQuery() } }
    }

    /// Re-run the grid query. Cheap enough to call on every chip, keystroke and cull
    /// decision: it is one indexed statement on the catalog's own serial queue, and a
    /// generation stamp drops anything that lands after a newer request.
    func refreshLibraryQuery() {
        guard let catalog, let folder = folderURL else {
            libraryOrder = nil
            return
        }
        libraryQueryGeneration &+= 1
        let generation = libraryQueryGeneration
        let query = filter.query(sort: sortOrder, ascending: sortAscending,
                                 albumID: selectedCollectionID)
        // Photos the catalog has no row for cannot be ordered by it. There should be
        // none — registration runs before the grid appears — but a photograph silently
        // missing from a contact sheet is the worst failure this app has, so any stray
        // is kept, filtered in memory, and put at the end rather than dropped.
        let strays = allPhotos.filter { $0.catalogID == nil && filter.matches($0) }
        Task { [weak self] in
            let rows = await catalog.photos(matching: query, folderPath: folder.path)
            guard let self, self.libraryQueryGeneration == generation else { return }
            var byID = [Int64: URL](minimumCapacity: self.allPhotos.count)
            for item in self.allPhotos {
                if let id = item.catalogID { byID[id] = item.id }
            }
            self.libraryOrder = rows.compactMap { byID[$0.id] } + strays.map(\.id)
            self.adoptCaptureISO(from: rows)
            self.reportAlbumScope()
        }
    }

    /// Carry the capture ISO from the catalog's rows onto the items the grid holds.
    ///
    /// EXIF arrives after the grid does — `backfillMetadata` runs behind it, and asks
    /// for this refresh when its last batch lands — so this is where a freshly imported
    /// folder's ISOs reach `PhotoItem`. Without it an unedited frame's ISO-adaptive
    /// denoise defaults would not appear until the next launch, which reads as the
    /// defaults simply being flat.
    ///
    /// One assignment rather than one per row: `allPhotos` is `@Published` and a
    /// per-element write republishes the whole grid.
    private func adoptCaptureISO(from rows: [PhotoRow]) {
        var isoByID: [Int64: Int] = [:]
        for row in rows {
            if let iso = row.iso { isoByID[row.id] = iso }
        }
        guard !isoByID.isEmpty else { return }
        var updated = allPhotos
        var changed = false
        for i in updated.indices {
            guard let id = updated[i].catalogID, let iso = isoByID[id],
                  updated[i].iso != iso else { continue }
            updated[i].iso = iso
            changed = true
        }
        guard changed else { return }
        allPhotos = updated
        // The develop panel reads the primary selection's own copy, so it needs the
        // same news; the id has not changed, so the `didSet` observer returns early.
        if let primary = primarySelection,
           let fresh = updated.first(where: { $0.id == primary.id }),
           fresh.iso != primary.iso {
            primarySelection = fresh
        }
    }

    /// An album is a source that spans folders, and only one folder is open at a time.
    /// Saying so beats an album row that reads 40 opening a grid of 6 with no
    /// explanation anywhere on screen.
    private func reportAlbumScope() {
        guard let albumID = selectedCollectionID,
              let album = collections.first(where: { $0.id == albumID }) else { return }
        let shown = libraryOrder?.count ?? 0
        if shown < album.count {
            statusMessage = "\(album.name): \(shown) of \(album.count) — the rest are "
                + "in folders that are not open"
        } else {
            statusMessage = "\(album.name): \(shown) photo" + (shown == 1 ? "" : "s")
        }
    }

    /// A recipe write moves `photo.edited` and `edit.updated_at`, which only two things
    /// read: the edited chip and the edit-time sort. Re-querying on every slider drag
    /// otherwise would put a database round trip inside the develop loop.
    private func refreshLibraryQueryIfEditStateShows() {
        guard filter.edited != nil || sortOrder == .editTime else { return }
        refreshLibraryQuery()
    }

    private func filterOrSortChanged(_ oldValue: LibraryFilter) {
        guard filter != oldValue else { return }
        refreshLibraryQuery()
    }

    // MARK: Per-source view state (docs/10 §10.2)

    /// Sort key, direction and thumbnail size belong to the source, not to the app: a
    /// wedding folder wants capture time and big cells, an archive folder wants file
    /// name and small ones, and re-choosing on every visit is the friction the spec
    /// calls out. `source_state` has held these columns since migration 2 with nothing
    /// reading or writing them.
    private var sourceKey: String? { folderURL.map { "folder:" + $0.path } }

    /// True while the stored state is being applied, so restoring it does not
    /// immediately write it back.
    private var isRestoringSourceState = false
    private var sourceStateSaveTask: Task<Void, Never>?

    private func loadSourceState() {
        guard let catalog, let key = sourceKey else { return }
        Task { [weak self] in
            guard let stored = await catalog.sourceState(key) else { return }
            guard let self, self.sourceKey == key else { return }
            self.isRestoringSourceState = true
            if let order = SortOrder.allCases.first(where: {
                $0.sortKey.rawValue == stored.sortKey
            }) {
                self.sortOrder = order
            }
            self.sortAscending = stored.ascending
            self.gridThumbnailSize = Swift.min(
                Swift.max(Double(stored.thumbnailSize), AppState.minThumbnailSize),
                AppState.maxThumbnailSize)
            self.isRestoringSourceState = false
        }
    }

    private func saveSourceState() {
        guard !isRestoringSourceState, let catalog, let key = sourceKey else { return }
        let value = CatalogService.SourceViewState(sortKey: sortOrder.sortKey.rawValue,
                                                  ascending: sortAscending,
                                                  thumbnailSize: Int(gridThumbnailSize))
        Task { await catalog.setSourceState(key, value) }
    }

    /// The thumbnail slider emits a value per pixel of drag. Writing each one is a
    /// database transaction per frame of a gesture; the size the drag settles on is the
    /// only one worth keeping.
    private func scheduleSourceStateSave() {
        sourceStateSaveTask?.cancel()
        sourceStateSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.saveSourceState()
        }
    }

    // MARK: Albums, keywords and stacks

    /// True when there is a database behind the app. Everything in this section writes
    /// to it and nothing else, so the sidebar hides the whole group when it is false
    /// rather than offering buttons that would be swallowed.
    var isCatalogAvailable: Bool { catalog != nil }

    @Published private(set) var collections: [CollectionItem] = []
    @Published private(set) var keywordVocabulary: [LibraryFacet] = []
    /// The camera bodies and lenses present in this source, most-used first.
    @Published private(set) var cameraChoices: [LibraryFacet] = []
    @Published private(set) var lensChoices: [LibraryFacet] = []
    /// The keywords on the photo under the cursor, for the sidebar's token row.
    @Published private(set) var primaryKeywords: [String] = []
    /// The stack the photo under the cursor belongs to, if any.
    @Published private(set) var primaryStack: StackSummary?

    var targetCollection: CollectionItem? { collections.first(where: \.isTarget) }

    /// Reload the sidebar's library lists. Called when the folder changes and after
    /// anything that could change membership — never on a timer, because a list that
    /// refreshes on its own while you are reading it is its own kind of wrong.
    func refreshLibrarySections() {
        guard let catalog, let folder = folderURL else {
            collections = []
            keywordVocabulary = []
            cameraChoices = []
            lensChoices = []
            return
        }
        Task { [weak self] in
            let albums = await catalog.collections()
            let keywords = await catalog.allKeywords()
            let cameras = await catalog.facets(.camera, folderPath: folder.path)
            let lenses = await catalog.facets(.lens, folderPath: folder.path)
            guard let self else { return }
            self.collections = albums
            self.keywordVocabulary = keywords.map {
                LibraryFacet(name: $0.value, count: $0.count)
            }
            self.cameraChoices = cameras.map {
                LibraryFacet(name: $0.value, count: $0.count)
            }
            self.lensChoices = lenses.map {
                LibraryFacet(name: $0.value, count: $0.count)
            }
        }
        refreshPrimaryLibraryDetail()
    }

    /// The keywords and stack of the photo under the cursor.
    func refreshPrimaryLibraryDetail() {
        guard let catalog, let photoID = primarySelection?.catalogID else {
            primaryKeywords = []
            primaryStack = nil
            return
        }
        Task { [weak self] in
            let words = await catalog.keywords(photoID: photoID)
            let stack = await catalog.stack(containing: photoID)
            var summary: StackSummary?
            if let stack {
                let members = await catalog.stackMembers(stackID: stack.id)
                summary = StackSummary(id: stack.id, memberCount: members.count,
                                       collapsed: stack.collapsed,
                                       isPick: stack.pickPhotoID == photoID)
            }
            guard let self, self.primarySelection?.catalogID == photoID else { return }
            self.primaryKeywords = words
            self.primaryStack = summary
        }
    }

    func createCollection(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let catalog, !trimmed.isEmpty else { return }
        Task { [weak self] in
            _ = await catalog.createCollection(name: trimmed)
            guard let self else { return }
            self.statusMessage = "Album \"\(trimmed)\" created"
            self.refreshLibrarySections()
        }
    }

    func setTargetCollection(_ albumID: Int64) {
        guard let catalog else { return }
        Task { [weak self] in
            await catalog.setTargetCollection(albumID)
            self?.refreshLibrarySections()
        }
    }

    /// `B` in docs/10 §10.9 — gather while culling. The target album is the scratch pad
    /// every shoot ends up needing; any album can be designated.
    func addSelectionToTargetCollection() {
        let ids = editTargets.compactMap(\.catalogID)
        guard let catalog, !ids.isEmpty else { return }
        guard let target = targetCollection else {
            statusMessage = "No target album yet — make one in the sidebar first"
            return
        }
        Task { [weak self] in
            await catalog.addToCollection(target.id, photoIDs: ids)
            guard let self else { return }
            self.statusMessage = "Added \(ids.count) photo"
                + (ids.count == 1 ? "" : "s") + " to \(target.name)"
            self.refreshLibrarySections()
            // The grid is showing that album: what it holds just changed.
            if self.selectedCollectionID == target.id { self.refreshLibraryQuery() }
        }
    }

    func removeSelectionFromCollection(_ albumID: Int64) {
        let ids = editTargets.compactMap(\.catalogID)
        guard let catalog, !ids.isEmpty else { return }
        Task { [weak self] in
            await catalog.removeFromCollection(albumID, photoIDs: ids)
            guard let self else { return }
            self.refreshLibrarySections()
            if self.selectedCollectionID == albumID { self.refreshLibraryQuery() }
        }
    }

    func addKeyword(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let ids = editTargets.compactMap(\.catalogID)
        guard let catalog, !trimmed.isEmpty, !ids.isEmpty else { return }
        Task { [weak self] in
            await catalog.addKeyword(trimmed, photoIDs: ids)
            guard let self else { return }
            self.statusMessage = "Keyworded \(ids.count) photo"
                + (ids.count == 1 ? "" : "s") + " \"\(trimmed)\""
            self.refreshLibrarySections()
            // The keyword is also a filter chip and a text-index term.
            if !self.filter.keywords.isEmpty || !self.filter.text.isEmpty {
                self.refreshLibraryQuery()
            }
        }
    }

    func removeKeyword(_ name: String) {
        let ids = editTargets.compactMap(\.catalogID)
        guard let catalog, !ids.isEmpty else { return }
        Task { [weak self] in
            await catalog.removeKeyword(name, photoIDs: ids)
            guard let self else { return }
            self.refreshLibrarySections()
            if !self.filter.keywords.isEmpty { self.refreshLibraryQuery() }
        }
    }

    /// `⌘G` — group a burst or a bracket into one decision unit. The frame under the
    /// cursor becomes the pick, which is the frame a collapsed stack shows.
    func stackSelection() {
        let targets = selection.count > 1 ? selectedPhotos : []
        let ids = targets.compactMap(\.catalogID)
        guard let catalog, ids.count > 1 else {
            statusMessage = "Select two or more photos to stack them"
            return
        }
        let pick = primarySelection?.catalogID
        Task { [weak self] in
            _ = await catalog.createStack(photoIDs: ids, pickPhotoID: pick)
            guard let self else { return }
            self.statusMessage = "Stacked \(ids.count) frames"
            self.refreshPrimaryLibraryDetail()
            self.refreshLibraryQuery()
        }
    }

    /// `⇧⌘G` — the grouping goes, the photographs stay.
    func unstackSelection() {
        guard let catalog, let stack = primaryStack else {
            statusMessage = "That photo is not in a stack"
            return
        }
        Task { [weak self] in
            await catalog.dissolveStack(id: stack.id)
            guard let self else { return }
            self.statusMessage = "Unstacked"
            self.refreshPrimaryLibraryDetail()
            self.refreshLibraryQuery()
        }
    }

    /// Collapse or expand the stack under the cursor. Visible in the grid through the
    /// "Collapsed stacks" chip, which is what turns 3,000 frames into 400 decisions.
    func toggleStackCollapsed() {
        guard let catalog, let stack = primaryStack else { return }
        Task { [weak self] in
            await catalog.setStackCollapsed(!stack.collapsed, stackID: stack.id)
            guard let self else { return }
            self.refreshPrimaryLibraryDetail()
            if self.filter.stackState == .collapsedTops { self.refreshLibraryQuery() }
        }
    }

    /// Promote the frame under the cursor to its stack's pick.
    func promoteStackPick() {
        guard let catalog, let stack = primaryStack,
              let photoID = primarySelection?.catalogID else { return }
        Task { [weak self] in
            await catalog.setStackPick(photoID, stackID: stack.id)
            guard let self else { return }
            self.statusMessage = "Stack pick set"
            self.refreshPrimaryLibraryDetail()
            if self.filter.stackState == .collapsedTops { self.refreshLibraryQuery() }
        }
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

    /// The stroke set behind `ref`, for the canvas to append to.
    ///
    /// Cache first, then the blob store — and the disk fallback is the point. This used
    /// to be cache-only, and the canvas appends to whatever it is handed before writing
    /// the result back as the component's new strokes. So a cache miss did not mean
    /// "wait": it meant the next brush stroke replaced every earlier stroke on that
    /// component with itself, as an ordinary edit, with nothing to indicate it. A miss
    /// is entirely reachable — `loadStrokeSets` reads on a detached task and gives up
    /// quietly if the blob is unreadable, so a catalog copied without its blobs, or a
    /// recipe arriving from another machine, leaves the entry nil forever.
    ///
    /// The read is synchronous here on purpose. It happens once per component, the
    /// payload is a few tens of kilobytes, and the alternative on a miss is losing the
    /// user's masking. `nil` now means genuinely no strokes, not "not loaded yet".
    func strokeSet(ref: String?) -> BrushStrokeSet? {
        guard let ref else { return nil }
        if let cached = strokeCache[ref] { return cached }
        guard let set = catalog?.blobs.strokeSet(for: ref) else { return nil }
        strokeCache[ref] = set
        return set
    }

    /// Whether every brush blob this component needs is in hand.
    ///
    /// `strokeSet(ref:)` returning nil is ambiguous on its own — a component with no
    /// strokes yet and a component whose bytes cannot be read look the same, and only
    /// one of those is safe to paint over.
    func strokesAreResolved(for component: MaskComponent?) -> Bool {
        guard let ref = component?.strokesRef, !ref.isEmpty else { return true }
        return strokeSet(ref: ref) != nil
    }

    /// The brush blobs a delivery needs, and the ones it could not get.
    ///
    /// This is the export path's answer to `strokeSets(for:)`, which is memory-only by
    /// design and therefore not an answer at all for a file being written: the blobs
    /// load on a detached task at catalog open, so an export starting before that task
    /// finishes saw an empty cache, rasterized every brush component to nothing, and
    /// delivered the frame with its masking silently absent.
    ///
    /// `strokesAreResolved` reaches the blob store synchronously on a miss — a few tens
    /// of kilobytes, once per component — so asking the question also warms the cache
    /// that `strokeSets(for:)` reads on the next line. Blocking here is the point: the
    /// alternative is a wrong file.
    func resolveStrokeSets(for recipe: Recipe)
        -> (sets: [String: BrushStrokeSet], unresolved: [String]) {
        let unresolved = BrushStrokes.unresolvedReferences(in: recipe) { component in
            self.strokesAreResolved(for: component)
        }
        return (sets: strokeSets(for: recipe), unresolved: unresolved)
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
            // `loaded` is bound to a `let` before the hop, and `self` is captured
            // explicitly in the capture list rather than referenced through the
            // enclosing scope. Both were warnings — "reference to captured var in
            // concurrently-executing code" — and both are ERRORS under the Swift 6
            // language mode this package will move to.
            let resolved = loaded
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (ref, set) in resolved { self.strokeCache[ref] = set }
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
            // The browse cache's disk half (docs/15 §15.6). Payloads go under
            // `~/Library/Caches` rather than beside the catalog because that is where
            // the OS expects reclaimable data and where Time Machine will not carry
            // tens of gigabytes of regenerable previews.
            if let cacheDirectory = PreviewStore.defaultDirectory() {
                let store = PreviewStore(catalog: service, directory: cacheDirectory)
                previews = store
                thumbnails.attach(previews: store)
            }
            // The open-time integrity check has already run and already acted (§15.8).
            // Told, not asked: by the time this line executes the catalog on disk is
            // either the one that passed or the newest backup that did, and the only
            // thing left is to say so. A healthy catalog has no notice and stays silent.
            catalogStatus = service.recovery.notice
            if let notice = service.recovery.notice { statusMessage = notice }
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
        // The previous folder's query answer describes photographs that are no longer
        // on screen. Nil means "ask again"; leaving it would show the old roll's order
        // over the new roll's contents for as long as the scan takes.
        libraryOrder = nil
        selectedCollectionID = nil
        viewMode = .grid
        isScanning = true
        statusMessage = "Scanning…"

        // The undo stack belongs to the folder that produced it. `HistoryStack.clear`
        // existed and had no callers, and `recipes` was never reset, so opening folder
        // A, editing a frame, opening folder B and pressing ⌘Z wrote a recipe for a URL
        // that is no longer in `allPhotos`: no catalog row was found, so the catalog
        // write was skipped — but the sidecar write was still enqueued, silently
        // reverting an .xmp next to a photo in a folder that is not open, with nothing
        // on screen changing to show it.
        history.clear()
        recipes = [:]

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
            // AFTER the grid, never before it. Reading EXIF is a file open per photo,
            // and capture time, body, lens and exposure are what ten of the twelve sort
            // orders and every metadata filter read — until now nothing wrote them, so
            // all of it was reading NULL. Fire-and-forget on the catalog's own serial
            // queue: it is an enrichment, it resumes by itself next launch, and nothing
            // on screen waits for it.
            catalog?.backfillMetadata(folder: url) { _, finished in
                // The default sort is capture time and the grid is already up, ordered
                // on rows whose `capture_at` is still NULL. Re-asking when the last
                // batch lands is what turns the EXIF pass into something the user can
                // see; without it the frames only fall into shooting order on the next
                // launch, which reads as the sort having ignored them.
                guard finished else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.folderURL == url else { return }
                    self.refreshLibraryQuery()
                }
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
                items[i].iso = row.iso
                if let recipe = row.recipe { recipes[items[i].id] = recipe }
            }
        }
        allPhotos = items
        // The preview cache is keyed on `photo_id` and the loader is keyed on URL; this
        // dictionary is the join, and it has been coming back from `registerAndLoad`
        // unread for as long as both have existed.
        previews?.register(stored.mapValues(\.catalogID))
        for recipe in recipes.values where !recipe.masks.isEmpty {
            loadStrokeSets(for: recipe)
        }
        // The grid's order and membership are the catalog's answer from here on.
        loadSourceState()
        refreshLibraryQuery()
        refreshLibrarySections()
        isScanning = false
        statusMessage = "\(items.count) photo\(items.count == 1 ? "" : "s")"
        if primarySelection == nil, let first = photos.first {
            select(first)
        }
    }

    // MARK: Selection

    /// What Compare and Survey are showing.
    ///
    /// A real multi-selection is the answer; with one photo selected the obvious second
    /// frame is its neighbour, which is what "compare this to the next one" means during
    /// a cull. It lives here rather than in the view because the arrow keys have to know
    /// what set they are moving inside — the view drawing it and the key moving through
    /// it disagreeing about which set that is would be the same class of bug again.
    var comparisonSet: [PhotoItem] {
        let selected = selectedPhotos
        if selected.count >= 2 { return selected }
        guard let primary = primarySelection else { return selected }
        let all = photos
        if let index = all.firstIndex(of: primary), index + 1 < all.count {
            return [primary, all[index + 1]]
        }
        return [primary]
    }

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
        cursorDidChange(to: photo)
    }

    /// Move the cursor to a photo WITHOUT rebuilding the selection.
    ///
    /// Compare and Survey are views of the selection: the frames on screen are the
    /// selected photos. A key that moves attention between them must not edit them, and
    /// `select` — which resets `selection` to a single photo — did exactly that, so →
    /// in a six-frame survey collapsed it to two.
    func moveCursor(to photo: PhotoItem) {
        let changedPhoto = primarySelection?.id != photo.id
        primarySelection = photo
        guard changedPhoto else { return }
        cursorDidChange(to: photo)
    }

    /// Everything that has to follow the cursor, wherever the cursor was moved from.
    ///
    /// Every path lands here, including ⌘-click and ⇧-click, which used to return early
    /// and leave the histogram describing the previous frame.
    ///
    /// Mask selection is per-photo, so it does not travel: mask "c-9F3B" on this photo
    /// is not the same object as mask 1 on the next one, and carrying the index across
    /// would point the on-image handles at a component that is not there.
    private func cursorDidChange(to photo: PhotoItem) {
        activeMaskID = nil
        activeComponentIndex = 0
        loadStrokeSets(for: recipe(for: photo))
        scheduleScopeRefresh()
        // The clipping panel follows the cursor and NOTHING ELSE. It is measured on the
        // decode, before every Lumen stage, so no slider in the app can move a number
        // in it — which is exactly why the cache is keyed on the file and why the edit
        // paths above do not schedule it.
        scheduleRawTruthRefresh()
        refreshMaskOverlay()
    }

    func selectNext() { moveSelection(by: 1) }
    func selectPrevious() { moveSelection(by: -1) }

    /// One arrow press. Which list it walks — the roll, or the selection being
    /// compared — is `ArrowNavigation.step`, in LumenCore, where it has tests; this
    /// method supplies the indices and carries out the answer.
    func moveSelection(by delta: Int) {
        let list = photos
        // The photos actually chosen, in the order the panes draw them — the same
        // branch `comparisonSet` takes, so the set the key walks and the set on screen
        // cannot be two different sets. Below two, a comparison is the cull gesture
        // "this one against the next one" and the arrows browse the roll as usual.
        let selected = selectedPhotos
        let step = ArrowNavigation.step(
            delta: delta,
            libraryCursor: primarySelection.flatMap { list.firstIndex(of: $0) },
            libraryCount: list.count,
            selectionCursor: primarySelection.flatMap { selected.firstIndex(of: $0) },
            selectionCount: selected.count,
            comparing: viewMode == .compare || viewMode == .survey)
        switch step {
        case .stay:
            return
        case .selectSingle(let index):
            guard list.indices.contains(index) else { return }
            select(list[index])
        case .moveWithinSelection(let index):
            guard selected.indices.contains(index) else { return }
            moveCursor(to: selected[index])
        }
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
        mutateTargets("Flag") { $0.flag = target }
        advanceIfNeeded(from: from)
    }

    func setRating(_ rating: Int) {
        let clamped = Swift.min(Swift.max(rating, 0), 5)
        let target = referenceItem?.rating == clamped ? 0 : clamped
        let from = cursorIndex
        mutateTargets("Rating") { $0.rating = target }
        advanceIfNeeded(from: from)
    }

    func setLabel(_ label: ColorLabel) {
        let target: ColorLabel = referenceItem?.label == label ? .none : label
        let from = cursorIndex
        mutateTargets("Label") { $0.label = target }
        advanceIfNeeded(from: from)
    }

    private func scopesBecameVisible(_ wasOn: Bool) {
        if !wasOn { scheduleScopeRefresh() }
    }

    /// Opening the panel on an unmeasured frame has to measure it. docs/10 §10.5 gives
    /// that request a ≤400 ms budget and lets it jump the queue, which is what the
    /// on-demand path here is: nothing is measured until somebody asks.
    private func rawTruthBecameVisible(_ wasOn: Bool) {
        if !wasOn { scheduleRawTruthRefresh() }
    }

    /// The photo whose current state decides whether a cull key sets or clears.
    private var referenceItem: PhotoItem? {
        primarySelection ?? editTargets.first
    }

    private static func culling(of photo: PhotoItem) -> HistoryStack.Culling {
        HistoryStack.Culling(flag: photo.flag, rating: photo.rating, label: photo.label)
    }

    /// Apply a culling change to every edit target AND put it on the undo stack.
    ///
    /// It was not on the stack at all: flag, rating and label wrote `allPhotos` and the
    /// catalog directly, and `undo()` only ever restored recipes. Pressing X with two
    /// hundred photos selected by accident could not be taken back — and ⌘Z did not do
    /// nothing, it silently undid whatever develop edit happened to be on top of the
    /// stack, on a possibly different photo. For an app whose highest-frequency job is
    /// the culling loop, its primary action had no undo.
    private func mutateTargets(_ label: String, _ body: (inout PhotoItem) -> Void) {
        let targets = Set(editTargets.map(\.id))
        guard !targets.isEmpty else { return }
        var before: [URL: HistoryStack.PhotoEdit] = [:]
        var after: [URL: HistoryStack.PhotoEdit] = [:]
        for i in allPhotos.indices where targets.contains(allPhotos[i].id) {
            let was = Self.culling(of: allPhotos[i])
            body(&allPhotos[i])
            let now = Self.culling(of: allPhotos[i])
            guard now != was else { continue }
            before[allPhotos[i].id] = HistoryStack.PhotoEdit(culling: was)
            after[allPhotos[i].id] = HistoryStack.PhotoEdit(culling: now)
            catalog?.saveCullingState(allPhotos[i])
            if allPhotos[i].id == primarySelection?.id {
                primarySelection = allPhotos[i]
            }
        }
        guard !after.isEmpty else { return }
        // No coalescing key: every cull decision is its own step. One keystroke over a
        // multi-selection is already one step, because it is one `record` call.
        history.record(before: before, after: after, coalescingKey: nil, label: label)
        // A rejected frame under a "Picked" chip has just left the grid, and only the
        // catalog knows it: the badge lives in `allPhotos`, the membership does not.
        if filter.isActive || sortOrder == .rating || sortOrder == .flag
            || sortOrder == .label {
            refreshLibraryQuery()
        }
    }

    /// Put a culling state back on a photo, wherever it currently sits in the roll.
    private func restore(_ culling: HistoryStack.Culling, to url: URL) {
        guard let i = allPhotos.firstIndex(where: { $0.id == url }) else { return }
        allPhotos[i].flag = culling.flag
        allPhotos[i].rating = culling.rating
        allPhotos[i].label = culling.label
        catalog?.saveCullingState(allPhotos[i])
        if allPhotos[i].id == primarySelection?.id {
            primarySelection = allPhotos[i]
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
        recipes[photo.id] ?? AppState.startingRecipe(for: photo.id, iso: photo.iso)
    }

    /// What an unedited photo starts as, which is not the same for every file.
    ///
    /// A camera RAW arrives scene-referred and unbounded, and Lumen's display transform
    /// is the ONLY tone mapping it will ever get — that is the point of running Apple's
    /// stage flat. A JPEG, HEIC or TIFF has already been through one: it is clipped at
    /// display white and carries a manufacturer's S-curve. Handing it the default
    /// sigmoid applies a SECOND, which crushes the blacks, hardens the highlights and
    /// makes an ordinary photograph look worse than the file you opened.
    ///
    /// So a rendered file starts on the Linear preset, which docs/04 §6.1 put there as
    /// exactly this escape hatch. It is a starting point and not a lock: the preset
    /// picker still offers the other four, and any recipe the user has saved wins over
    /// this entirely.
    ///
    /// The other thing that is not the same for every file is its noise. Tier-1 denoise
    /// is always live, and docs/07 §4's whole point is that a flat "Colour 25" is a
    /// guess that happens to be acceptable — so an unedited photo starts on the values
    /// its own ISO calls for, resolved to concrete numbers here so the panel shows what
    /// will render. A file with no ISO recorded keeps the flat defaults; a saved recipe
    /// wins over this entirely, so nothing is ever recomputed under a hand-set slider.
    ///
    /// Rendered files are left alone for the same reason they start on Linear: the
    /// camera has already denoised them, and their pixels no longer follow any sensor
    /// noise model this table knows.
    static func startingRecipe(for url: URL, iso: Int? = nil) -> Recipe {
        var recipe = Recipe()
        if PhotoFormats.isRendered(url) {
            recipe.look.render.preset = "Linear"
        } else if let iso {
            recipe.develop.denoise = ISODefaults.startingDenoise(forISO: Double(iso))
        }
        return recipe
    }

    var currentRecipe: Recipe {
        primarySelection.map(recipe(for:)) ?? Recipe()
    }


    /// The grey a colour-driven mask component is born with, so it is a valid
    /// component before anything has been picked. Named because two places have to
    /// agree it is a placeholder rather than a choice.
    static let placeholderSample: [Double] = [0.18, 0.18, 0.18]

    /// Arm the next click on the image, and say what it is for.
    func beginPick(_ target: PickTarget) {
        pickTarget = target
        statusMessage = target.prompt
        showLoupe()          // the catcher lives on the loupe
    }

    func cancelPick() {
        pickTarget = nil
        statusMessage = nil
    }

    /// A click landed. Resolve it against whatever the pick was for.
    ///
    /// THREE different taps, deliberately, and the rule is one sentence: a sample is
    /// taken from the same image the thing that will read it compares against.
    ///
    /// The neutral solver wants the value BEFORE white balance, because it is
    /// computing that white balance. The global Point Colour swatches want the working
    /// image — after the linear matrix — or a swatch picked off a warm frame would stop
    /// matching the moment Temp moved. And a MASK's samples want the local stage input,
    /// because that is what `colorRangePlane`, `similarityPlane` and `LocalPlan` all
    /// compare against; they used to be given the working image too, which is one tap
    /// short of the comparison by the whole of the tone stage and the whole of the
    /// colour and grade table.
    ///
    /// Every write goes through `updateRecipe`, so a picked colour is one undo step and
    /// one history entry, exactly like the sliders it replaces.
    func resolvePick(on photo: PhotoItem, sourceX: Double, sourceY: Double) {
        guard let target = pickTarget else { return }
        let current = recipe(for: photo)
        let url = photo.id                      // PhotoItem.id IS the URL
        Task {
            switch target {
            case .neutral:
                let solved = await renderCoordinator.solveNeutral(
                    url: url, recipe: current, sourceX: sourceX, sourceY: sourceY)
                pickTarget = nil
                guard let solved else {
                    statusMessage = "Too dark there to read a neutral — try a lit grey."
                    return
                }
                updateRecipe { recipe in
                    recipe.develop.raw.temp = solved.kelvin
                    recipe.develop.raw.tint = solved.tint
                }
                statusMessage = String(format: "Neutral picked — %.0f K, tint %.0f",
                                       solved.kelvin, solved.tint)

            case .newPointColor, .pointColor, .maskSample, .maskPointColor:
                // WHICH TAP depends on what will compare against the stored value.
                // A mask's samples are compared by `colorRangePlane` and
                // `similarityPlane` against `localStageInput` — after tone, after the
                // colour and grade table — and a mask's own Point Colour is evaluated
                // inside `LocalPlan`, whose input is that same image. `sampleWorking`
                // stops after the linear matrix, so storing it here meant the clicked
                // colour and the compared colour diverged by every global edit the
                // photograph carried, and the mask could miss the pixel that was
                // clicked.
                let sample: RGB?
                if target.samplesTheMaskStage {
                    sample = await renderCoordinator.sampleMaskReference(
                        url: url, recipe: current, sourceX: sourceX, sourceY: sourceY)
                } else {
                    sample = await renderCoordinator.sampleWorking(
                        url: url, recipe: current, sourceX: sourceX, sourceY: sourceY)
                }
                pickTarget = nil
                guard let sample else {
                    statusMessage = "Could not read a colour there."
                    return
                }
                let rgb = [sample.r, sample.g, sample.b]
                switch target {
                case .newPointColor:
                    updateRecipe { recipe in
                        guard recipe.develop.pointColors.count < 8 else { return }
                        recipe.develop.pointColors.append(PointColor(sample: rgb))
                    }
                case .pointColor(let index):
                    updateRecipe { recipe in
                        guard recipe.develop.pointColors.indices.contains(index) else {
                            return
                        }
                        recipe.develop.pointColors[index].sample = rgb
                    }
                case .maskSample(let maskID, let component):
                    updateRecipe { recipe in
                        guard let m = recipe.masks.firstIndex(where: { $0.id == maskID }),
                              recipe.masks[m].components.indices.contains(component)
                        else { return }
                        var list = recipe.masks[m].components[component].samples ?? []
                        // A component is born carrying one placeholder grey so it is a
                        // valid component; the first real pick REPLACES it rather than
                        // sitting beside it. Otherwise every colour mask would select
                        // its target plus mid-grey, which on a photograph is most of
                        // the frame.
                        if list == [AppState.placeholderSample] {
                            list = [rgb]
                        } else {
                            guard list.count < 8 else { return }
                            list.append(rgb)
                        }
                        recipe.masks[m].components[component].samples = list
                    }
                case .maskPointColor(let maskID):
                    updateRecipe { recipe in
                        guard let m = recipe.masks.firstIndex(where: { $0.id == maskID }),
                              recipe.masks[m].adjust.pointColors.count < 8
                        else { return }
                        recipe.masks[m].adjust.pointColors.append(
                            PointColor(sample: rgb))
                    }
                case .neutral:
                    break        // handled above; unreachable
                }
                statusMessage = nil
            }
        }
    }

    func updateRecipe(coalescingKey: String? = nil, _ mutate: (inout Recipe) -> Void) {
        let targets = editTargets
        guard !targets.isEmpty else { return }
        var before: [URL: HistoryStack.PhotoEdit] = [:]
        var after: [URL: HistoryStack.PhotoEdit] = [:]
        var changed: [URL: Recipe] = [:]
        var touchedPixels = false
        for photo in targets {
            let old = recipe(for: photo)
            var updated = old
            mutate(&updated)
            guard updated != old else { continue }
            if !updated.rendersSameAs(old) { touchedPixels = true }
            before[photo.id] = HistoryStack.PhotoEdit(recipe: old)
            after[photo.id] = HistoryStack.PhotoEdit(recipe: updated)
            changed[photo.id] = updated
            recipes[photo.id] = updated
        }
        guard !after.isEmpty else { return }
        history.record(before: before, after: after, coalescingKey: coalescingKey)
        persist(changed)
        // Renaming a mask changes the recipe without changing the picture. Re-binning
        // the scopes for it would mean a proxy render per keystroke.
        if touchedPixels {
            scheduleScopeRefresh()
            // The overlay is a picture of the mask, so editing the mask must move it.
            // Cheap when nothing is soloed — the refresh guards on that first.
            refreshMaskOverlay()
            // Adding a Subject or People component is the moment its matte is wanted.
            ensureMaskMattes()
        }
    }

    private func persist(_ changes: [URL: Recipe]) {
        guard let catalog else { return }
        for (url, recipe) in changes {
            let id = allPhotos.first(where: { $0.id == url })?.catalogID
            catalog.saveRecipe(recipe, url: url, catalogID: id)
        }
        refreshLibraryQueryIfEditStateShows()
    }

    // MARK: Shutdown and maintenance

    /// Everything that must happen before the process goes away.
    ///
    /// Sidecar writes coalesce over a two-second window, so quitting inside it dropped
    /// them: the flags and ratings from the last moments of a culling session reached
    /// the catalog and never reached the disk beside the photos. `close` flushes the
    /// pending batch and then checkpoints and closes the database. It is synchronous
    /// because `applicationWillTerminate` is the last moment anything runs.
    func prepareToQuit() {
        // Eviction before the database closes, because the eviction runs through it.
        // docs/10 §10.10: the photographer never hears about this — no menu item, no
        // confirmation, no "Optimize Catalog" ritual.
        previews?.prune()
        catalog?.close()
    }

    /// A consistent snapshot of the catalog, via `VACUUM INTO`.
    func backUpCatalog() {
        guard let catalog else {
            statusMessage = "No catalog to back up"
            return
        }
        catalog.backup()
        statusMessage = "Backing up the catalog…"
    }

    func undo() { apply(history.undo()) }
    func redo() { apply(history.redo()) }

    /// Put one history step back, restoring only the fields it recorded.
    private func apply(_ step: [URL: HistoryStack.PhotoEdit]?) {
        guard let step else { return }
        var recipeChanges: [URL: Recipe] = [:]
        var touchedPixels = false
        for (url, edit) in step {
            if let recipe = edit.recipe {
                recipes[url] = recipe
                recipeChanges[url] = recipe
                touchedPixels = true
            }
            if let culling = edit.culling {
                restore(culling, to: url)
            }
        }
        persist(recipeChanges)
        if touchedPixels { scheduleScopeRefresh() }
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
