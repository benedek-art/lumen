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
    /// Select the mixer band that owns the clicked colour (docs/28 Phase 5). Writes no
    /// recipe: it moves the panel's selection to the band already grading that hue.
    case mixerBand
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
        // `.mixerBand` reads the same tap as the global Point Colour, and for the same
        // reason: the mixer is evaluated inside the S9/S10 table, so the hue that
        // decides which band owns a pixel has to be the hue that table sees.
        case .neutral, .newPointColor, .pointColor, .mixerBand: return false
        }
    }

    /// What the status line says while the click is being waited for.
    var prompt: String {
        switch self {
        case .neutral: return "Click something neutral grey in the picture."
        case .newPointColor, .pointColor: return "Click the colour to work on."
        case .mixerBand: return "Click a colour — its band selects itself."
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

    /// How many criteria are lit, for the badge on the Filter button.
    ///
    /// Criteria, not values: three flag chips lit is ONE criterion, because they OR
    /// together into a single clause of the query. A badge counting chips would read
    /// "5" for what the sentence calls two conditions.
    var activeCriteriaCount: Int {
        var n = 0
        if !flags.isEmpty { n += 1 }
        if minRating > 0 { n += 1 }
        if !labels.isEmpty { n += 1 }
        if rawOnly { n += 1 }
        if edited != nil { n += 1 }
        if !cameras.isEmpty { n += 1 }
        if !lenses.isEmpty { n += 1 }
        if !isoBands.isEmpty { n += 1 }
        if !keywords.isEmpty { n += 1 }
        if stackState != .any { n += 1 }
        if !text.isEmpty { n += 1 }
        return n
    }

    /// The criteria that are actually HIDDEN behind the Filter button.
    ///
    /// Search text is a criterion like any other and `activeCriteriaCount` counts it,
    /// but its field is right there in the strip with its own contents and its own
    /// clear ✕. Badging the button "1" for something the eye can already read would
    /// send the photographer into a popover where every group is empty.
    var hiddenCriteriaCount: Int {
        activeCriteriaCount - (text.isEmpty ? 0 : 1)
    }

    /// The active query written out. "or" inside a criterion, and between criteria
    /// whatever the Match toggle says — the sentence IS the documentation, which is why
    /// it survived the filter bar being taken apart (docs/28 Phase 3) and moved to the
    /// status bar rather than being deleted with its container.
    ///
    /// It lives on the filter rather than in a view because two surfaces now read it:
    /// the status bar shows it, and the filter popover shows the same words back inside
    /// the control that produced them. Two hand-rolled versions of a sentence that is
    /// supposed to be authoritative is exactly one too many.
    ///
    /// `catalogLive` only changes what the EMPTY sentence says: with no catalog the app
    /// filters in memory over `PhotoItem`, and a bar that did not say so would be
    /// claiming a reach it does not have.
    func sentence(catalogLive: Bool) -> String {
        guard isActive else {
            return catalogLive
                ? "No filter — showing every photo"
                : "No filter — filtering in memory, without the catalog"
        }
        var parts: [String] = []
        if !flags.isEmpty {
            parts.append(flags.sorted { $0.rawValue > $1.rawValue }
                .map(Self.flagName).joined(separator: " or "))
        }
        if minRating > 0 {
            parts.append("★ \(minRating) or better")
        }
        if !labels.isEmpty {
            parts.append(labels.sorted { $0.rawValue < $1.rawValue }
                .map { $0 == ColorLabel.none ? "Unlabelled" : $0.displayName }
                .joined(separator: " or "))
        }
        if rawOnly { parts.append("RAW only") }
        if let edited { parts.append(edited ? "edited" : "untouched") }
        if !cameras.isEmpty { parts.append(cameras.sorted().joined(separator: " or ")) }
        if !lenses.isEmpty { parts.append(lenses.sorted().joined(separator: " or ")) }
        if !isoBands.isEmpty {
            parts.append(ISOBand.allCases.filter { isoBands.contains($0) }
                .map { "ISO " + $0.rawValue }.joined(separator: " or "))
        }
        if !keywords.isEmpty { parts.append(keywords.sorted().joined(separator: " or ")) }
        if stackState != .any { parts.append(stackState.rawValue.lowercased()) }
        if !text.isEmpty { parts.append("matching \"\(text)\"") }
        return parts.joined(separator: matchAny ? "  or  " : "  and  ")
    }

    static func flagName(_ flag: PhotoFlag) -> String {
        switch flag {
        case .picked: return "Picked"
        case .rejected: return "Rejected"
        case .none: return "Unflagged"
        }
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
    @Published var selection: Set<URL> = [] {
        didSet { selectedPhotosCache = nil }
    }
    @Published var primarySelection: PhotoItem? {
        didSet {
            guard primarySelection?.id != oldValue?.id else { return }
            // A gesture cannot span photos: if a drag's release was dropped, the
            // switch is the moment its deferred writes land (audit queue item 4 —
            // the second unlatch beside the watchdog).
            sliderGesture(active: false)
            primaryFrameSize = nil
            // Which way up is a fact about THIS photograph: the next one starts without
            // an answer rather than inheriting the previous one's.
            primaryFrameTransposed = false
            primaryAsShotNeutral = nil
            refreshPrimaryFrameSize()
            refreshPrimaryAsShotNeutral()
            refreshPrimaryLibraryDetail()
            // A photo whose recipe already carries a Subject mask needs its matte
            // before the first frame is worth looking at; the call is a no-op for the
            // overwhelming majority of photographs, which have no AI component at all.
            ensureMaskMattes()
            // Export's menu item is enabled by there being a photograph.
            refreshCommandState()
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

    /// Whether `primaryFrameSize` is the delivered frame seen SIDEWAYS.
    ///
    /// A camera sensor is landscape. A portrait exposure is a landscape readout plus an
    /// EXIF orientation; the decode applies that orientation and the reported native
    /// size does not — so on a vertical photograph the number above is horizontal while
    /// the picture is not. The owner met it as the crop tool "stretching my entire image
    /// out into a horizontal landscape photo, not a vertical photo like it is". The
    /// comment just above had already recorded another face of the same defect — "on a
    /// portrait-orientation frame every ratio came out roughly half of what the menu
    /// said" — and put it down to the assumed 3:2 instead.
    ///
    /// Learned by the loupe from the first WHOLE-FRAME delivery for the photograph
    /// (`FrameOrientation` in LumenCore, with tests) rather than decided here, because
    /// only a delivery can settle it and only an uncropped one is admissible: a crop can
    /// turn a landscape frame portrait honestly. False until something knows better,
    /// which makes every landscape photograph — and every photograph at all, the day the
    /// source reports an oriented size — take exactly the path it took before.
    @Published private(set) var primaryFrameTransposed: Bool = false

    /// What the reported size MEANS, once reconciled: the frame the overlays, the crop
    /// arithmetic and the mask conversions all place themselves against.
    ///
    /// Every consumer reads this rather than `primaryFrameSize`, and that is the whole
    /// point. Two call sites disagreeing about which of the two they hold is precisely
    /// the class of defect `RenderRequest.swift`'s header was written about — "a correct
    /// rule that lives in one view is a defect with a delay".
    var sourceFrameSize: CGSize? {
        guard let size = primaryFrameSize else { return nil }
        return FrameOrientation.sourceSize(reported: size,
                                           transposed: primaryFrameTransposed)
    }

    /// Told by the loupe when a whole-frame delivery has answered the question.
    /// Idempotent: writing the same answer publishes nothing.
    func noteFrameTransposed(_ transposed: Bool) {
        guard primaryFrameTransposed != transposed else { return }
        primaryFrameTransposed = transposed
    }

    var primaryFrameAspect: Double? {
        guard let size = sourceFrameSize, size.height > 0 else { return nil }
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
    private var maskOverlayTask: Task<Void, Never>?

    /// Rebuild it for the mask the panel is showing. Superseded by generation, like
    /// every other background render here, so a fast sequence of edits does not land
    /// out of order.
    ///
    /// Supersession is checked BEFORE the actor call, not only after. The old shape —
    /// an unstored `Task {}` whose generation check sat past the `await` — meant every
    /// mouse event of a drag queued a full mask rasterization on the render actor and
    /// only threw the result away afterwards: the exact claimed-too-late defect the
    /// render coalescer was fixed for (391563a), rebuilt in the one path that fix did
    /// not touch, and blocking viewer frames during precisely the edits the overlay
    /// exists to visualise.
    func refreshMaskOverlay() {
        maskOverlayGeneration &+= 1
        let generation = maskOverlayGeneration
        maskOverlayTask?.cancel()
        guard let maskID = soloMaskOverlay, let photo = primarySelection else {
            // Guarded, not written blind. `@Published` does no equality check, so the
            // bare assignment published on EVERY pixel-touching edit — every mouse
            // event of every drag — to set nil to nil, re-bodying the window for a
            // change that had not happened.
            if maskOverlayAlpha != nil { maskOverlayAlpha = nil }
            return
        }
        let recipe = recipe(for: photo)
        let strokes = strokeSets(for: recipe)
        maskOverlayTask = Task { [weak self] in
            guard let self else { return }
            // Let the burst settle: of N refreshes queued in one runloop turn, only
            // the newest survives to touch the actor at all.
            await Task.yield()
            guard !Task.isCancelled, self.maskOverlayGeneration == generation else { return }
            let raster = await self.renderCoordinator.maskAlpha(
                url: photo.id, recipe: recipe, maskID: maskID, strokeSets: strokes)
            guard !Task.isCancelled, self.maskOverlayGeneration == generation else { return }
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
    /// `attemptedSoFar` is the union of every kind previous re-entries already tried for
    /// this photograph. Empty from the outside; carried forward by the one recursive
    /// call, which is what turns "try again" into "try again only if the last try got
    /// somewhere". See the note at the re-entry below for what it costs when it does not.
    func ensureMaskMattes(attemptedSoFar: Set<String> = []) {
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
            // A kind added WHILE the pass ran was swallowed by the pendingMattes
            // guard above — a People mask added during a Subject segmentation
            // rasterized empty under a WORKING spinner until the next edit happened
            // to call back in. One re-entry closes the gap: it no-ops unless the
            // recipe wants a kind the pass did not attempt.
            //
            // AND IT ONLY RE-ENTERS ON PROGRESS, which is what stops it being an
            // unbounded loop. `RenderCoordinator.ensureMattes` records `attempted` only
            // INSIDE its optional-binding chain, so when the source cannot be built —
            // the original is missing, the volume is ejected, Apple RAW refuses the file
            // — nothing is attempted, the `allSatisfy` is false forever, and the
            // `pendingMattes` guard has already been released a line above. Select a
            // photograph with a Subject mask whose file is gone and the app span at
            // 100%: a main-actor Task, an actor hop and a decode attempt per iteration,
            // thousands a second, while the loupe showed the embedded preview and looked
            // fine. Requiring the attempted set to have GROWN makes a pass that could
            // not run a pass that will not run again.
            let progressed = !pass.attempted.isSubset(of: attemptedSoFar)
            if progressed,
               self.primarySelection?.id == url,
               let current = self.primarySelection.map(self.recipe(for:)),
               !VisionMattes.kinds(in: current)
                   .allSatisfy({ pass.attempted.contains($0.rawValue) }) {
                self.ensureMaskMattes(attemptedSoFar: attemptedSoFar.union(pass.attempted))
            }
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
        if before != availableMattes[url] {
            refreshMaskOverlay()
            // A matte ARRIVING changes what a Subject mask selects, and the row's
            // picture of it has to follow — but the recipe did not move, so the
            // thumbnail key would not have changed on its own.
            maskThumbnailKey = nil
            refreshMaskThumbnails()
        }
    }

    /// `O`: show or hide the overlay for the mask the panel has selected. With no mask
    /// selected there is nothing to show, so the key does nothing rather than picking
    /// a mask on the user's behalf.
    ///
    /// This is the PINNED overlay: pressing the key says "leave it up", and it survives
    /// the hover and auto-hide rules below.
    func toggleMaskOverlay() {
        if soloMaskOverlay != nil {
            maskOverlayPinned = false
            // O means OFF, including off a mask that is still being made. Leaving the
            // persistent id set would put the red straight back on the next hover exit.
            maskOverlayPersistentID = nil
            cancelMaskOverlayTimers()
            soloMaskOverlay = nil
            return
        }
        guard let id = activeMaskID ?? currentRecipe.masks.first?.id else { return }
        cancelMaskOverlayTimers()
        maskOverlayPinned = true
        soloMaskOverlay = id
    }

    // MARK: - The ambient overlay (docs/35 §4.4)

    /// Whether the photographer asked for the overlay and it should stay up.
    ///
    /// The three transient rules below — flash on create, show on hover, hide while an
    /// adjustment is dragged — all defer to this. A pinned overlay is a decision; an
    /// ambient one is feedback, and feedback that will not go away is an obstruction.
    private(set) var maskOverlayPinned = false

    /// Hover intent, and the auto-hide after a creation flash. Both are `Task`s rather
    /// than timers so a second event supersedes the first by cancellation.
    private var maskOverlayHideTask: Task<Void, Never>?
    private var maskOverlayHoverTask: Task<Void, Never>?

    /// Milliseconds of pointer dwell before a hovered row shows its overlay.
    ///
    /// Without it, a pointer crossing a ten-mask list on its way somewhere else is ten
    /// overlay builds and ten flashes of red over the photograph — worse than not having
    /// the feature (docs/36 §1.4). 120 ms is below the threshold at which a deliberate
    /// hover feels laggy and above the time a pointer spends passing over a 30 pt row.
    static let maskOverlayHoverIntentMS: UInt64 = 120
    /// How long a newly created mask shows itself before getting out of the way.
    static let maskOverlayFlashMS: UInt64 = 1_400

    // MARK: - Mask thumbnails (docs/35 §4.3)

    /// Long edge a mask row's thumbnail is rasterized at.
    ///
    /// 96 px is about a hundredth of the proxy's pixels, so a whole list of them costs
    /// less than one overlay. That ratio is what makes "every row is a picture of its
    /// own alpha" affordable at all — the idea is old and the reason nobody in a raw
    /// editor does it live is that they compute it at mask resolution.
    static let maskThumbnailLongEdge = 96

    /// One grey image per mask, keyed by mask id. Published so a row redraws when its
    /// thumbnail lands.
    @Published private(set) var maskThumbnails: [String: CGImage] = [:]

    /// What the held thumbnails were computed FROM. A mask id is not enough of a key:
    /// the picture behind a Colour Range moves when Exposure does, and the same mask id
    /// exists on the next photograph after Paste Settings.
    private var maskThumbnailKey: String?
    private var maskThumbnailTask: Task<Void, Never>?

    /// Rebuild the thumbnails if anything they depend on has changed.
    ///
    /// Coalesced the same way `refreshMaskOverlay` is, and for the same reason: this is
    /// called from the edit path, so a drag would otherwise queue one job per mouse
    /// event on an actor whose queue can hold a cold decode.
    func refreshMaskThumbnails() {
        guard let photo = primarySelection else {
            if !maskThumbnails.isEmpty { maskThumbnails = [:] }
            maskThumbnailKey = nil
            return
        }
        let recipe = recipe(for: photo)
        guard !recipe.masks.isEmpty else {
            if !maskThumbnails.isEmpty { maskThumbnails = [:] }
            maskThumbnailKey = nil
            return
        }
        // The masks themselves, minus their names — renaming a mask must not re-render
        // ninety-six pixels — plus everything the mask SOURCE is a function of, which is
        // what `PipelineRenderer.maskSourceFingerprint` already knows how to state.
        let shape = (try? CanonicalJSON.tree(of: recipe.masks.map(\.withoutCosmetics)))
            .map(CanonicalJSON.serialize) ?? UUID().uuidString
        let key = [photo.id.absoluteString, shape,
                   PipelineRenderer.maskSourceFingerprint(recipe: recipe) ?? "-"]
            .joined(separator: "|")
        guard key != maskThumbnailKey else { return }
        maskThumbnailKey = key

        let ids = recipe.masks.map(\.id)
        let strokes = strokeSets(for: recipe)
        maskThumbnailTask?.cancel()
        maskThumbnailTask = Task { [weak self] in
            guard let self else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            var built: [String: CGImage] = [:]
            for id in ids {
                guard !Task.isCancelled else { return }
                let plane = await self.renderCoordinator.maskThumbnail(
                    url: photo.id, recipe: recipe, maskID: id, strokeSets: strokes)
                if let plane, let image = AppState.greyImage(from: plane) {
                    built[id] = image
                }
            }
            guard !Task.isCancelled, self.maskThumbnailKey == key else { return }
            self.maskThumbnails = built
        }
    }

    /// An alpha plane as a grey image a row can draw.
    ///
    /// 8-bit grey with no alpha channel: this is a PICTURE of a mask, not a mask, and
    /// giving it an alpha channel is how the overlay once ended up drawing a flat tint
    /// over the whole frame.
    nonisolated static func greyImage(from plane: Plane) -> CGImage? {
        let w = plane.width, h = plane.height
        guard w > 0, h > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            bytes[i] = UInt8(Num.saturate(Double(plane.values[i])) * 255)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.linearGray)
                  ?? CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)
        else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: w, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    /// Keep the overlay up until it is deliberately taken down.
    ///
    /// For the row menu's "Keep it showing", which is the pointer's version of what `O`
    /// does. Separate from `toggleMaskOverlay` because the menu has already decided
    /// WHICH mask and does not want the key's "pick one if none is selected" rule.
    /// Leave the overlay up until told otherwise, optionally raising a named mask's.
    ///
    /// Takes the id so its one caller stops writing `soloMaskOverlay` directly — the
    /// raw write is how the pin and the solo got out of step in the first place.
    func pinMaskOverlay(_ id: String? = nil) {
        cancelMaskOverlayTimers()
        maskOverlayPinned = true
        maskOverlayPersistentID = nil
        if let id, soloMaskOverlay != id { soloMaskOverlay = id }
    }

    /// Take the pin off, and take the overlay down with it.
    ///
    /// THE MISSING HALF OF `pinMaskOverlay`, and its absence was a trap. The row menu's
    /// "Keep it hidden" set `soloMaskOverlay = nil` and left `maskOverlayPinned` TRUE —
    /// and `flashMaskOverlay`, `hoverMaskOverlay` and `setMaskEdgeGesture` all open with
    /// `guard !maskOverlayPinned`. So showing an overlay once and hiding it once killed
    /// every ambient path for the rest of the photograph: no creation flash, no hover,
    /// no overlay while dragging an edge. Nothing said so, and only `O` could undo it.
    func unpinMaskOverlay() {
        cancelMaskOverlayTimers()
        maskOverlayPinned = false
        maskOverlayPersistentID = nil
        if soloMaskOverlay != nil { soloMaskOverlay = nil }
    }

    /// A mask is new and has not been adjusted yet: leave its overlay up.
    ///
    /// THE RULE THIS COMPLETES, in one sentence: a mask's overlay is persistent from the
    /// moment it is created until the first time an Effect control is touched, and
    /// hover-only afterwards.
    ///
    /// Before this there was no persistent state at all. Every path was a 1400 ms
    /// countdown or a pointer dwell, so the answer to "show me what I just selected"
    /// was a flash you had to catch — and for a brush, a gradient, a radial or an
    /// outline the flash rendered NOTHING, because an undrawn mask's alpha is zero and
    /// `colorOverlay` composites `c.mix(tint, a·s)`: at `a = 0` the output is the
    /// photograph, byte for byte. Painting did not raise it either. So a brush mask
    /// could go from creation to fully adjusted without the red being visible for one
    /// frame, which is exactly what the owner reported.
    ///
    /// Setting it on an undrawn mask is right rather than merely harmless: nothing is
    /// selected, so nothing SHOULD be washed red, and the moment the first stroke lands
    /// the alpha stops being zero and the overlay is already standing there. The
    /// feedback arrives with the selection instead of before it.
    ///
    /// It defers to the pin, because a pin is a decision and this is a default.
    func beginPersistentMaskOverlay(_ id: String) {
        guard !maskOverlayPinned else { return }
        cancelMaskOverlayTimers()
        maskOverlayPersistentID = id
        soloMaskOverlay = id
    }

    /// The mask whose overlay stays up because it has not been adjusted yet, if any.
    ///
    /// Not published: every reader of it goes through `soloMaskOverlay`, which is.
    private var maskOverlayPersistentID: String?

    /// The three inputs every ambient overlay rule is gated on, as one value.
    ///
    /// `MaskOverlayRule` lives in LumenCore because this class needs a catalog on disk
    /// to construct and therefore cannot be unit tested, which is how a five-input state
    /// machine reached the owner with three defects and no test on any of them. The
    /// guards below CALL it rather than restating it.
    private var maskOverlayRule: MaskOverlayRule {
        MaskOverlayRule(pinned: maskOverlayPinned,
                        persistentID: maskOverlayPersistentID,
                        suppressed: maskOverlaySuppressed)
    }

    /// A mask was just created: show what it selected, then stand down.
    ///
    /// The first second of every mask used to look like nothing at all — `addMask`
    /// appended, selected, and returned without touching the overlay, so the one moment
    /// a photographer most needs to see what a mask does had no feedback in it
    /// (docs/35 §2.3).
    func flashMaskOverlay(_ id: String) {
        // SUPPRESSION IS AUTHORITATIVE NOW. `maskOverlaySuppressed` existed, was set on
        // every Effect press, and was read by nothing except its own dedup guard — so a
        // flash arriving mid-drag (clicking another mask's pin, say) put the red back
        // over the pixels the photographer was in the middle of judging.
        guard maskOverlayRule.ambientAllowed else { return }
        cancelMaskOverlayTimers()
        soloMaskOverlay = id
        // `Task` inherits this type's `@MainActor` isolation, so the body already
        // runs where `soloMaskOverlay` lives — a `MainActor.run` here would be a
        // second hop to the actor it is already on.
        maskOverlayHideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.maskOverlayFlashMS * 1_000_000)
            guard !Task.isCancelled, let self, !self.maskOverlayPinned,
                  self.soloMaskOverlay == id else { return }
            // A mask that has not been adjusted yet keeps its overlay. The stand-down
            // is for feedback that has been seen, not for a selection still being made.
            guard self.maskOverlayRule.mayStandDown(id) else { return }
            self.soloMaskOverlay = nil
        }
    }

    /// A mask row (or its pin) is under the pointer, or the pointer has left.
    ///
    /// Entering arms the intent timer; leaving cancels it and takes the overlay down
    /// unless it was pinned. Passing the SAME id again while it is already showing is a
    /// no-op rather than a re-arm, so a row that redraws under a stationary pointer does
    /// not make the overlay blink.
    func hoverMaskOverlay(_ id: String?) {
        guard maskOverlayRule.ambientAllowed else { return }
        maskOverlayHoverTask?.cancel()
        maskOverlayHideTask?.cancel()
        guard let id else {
            // THE POINTER LEFT. Fall back to the persistent overlay if one is standing
            // rather than to nothing: hovering a second mask's row while a new, unadjusted
            // mask is lit used to end with the photograph dark, because the exit cleared
            // the solo outright and nothing put the persistent one back.
            let fallback = maskOverlayRule.afterHoverExit
            if soloMaskOverlay != fallback { soloMaskOverlay = fallback }
            return
        }
        guard soloMaskOverlay != id else { return }
        maskOverlayHoverTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.maskOverlayHoverIntentMS * 1_000_000)
            guard !Task.isCancelled, let self,
                  self.maskOverlayRule.ambientAllowed else { return }
            self.soloMaskOverlay = id
        }
    }

    /// An adjustment slider is being dragged: the overlay is in the way of the thing
    /// being judged, so it goes — even if it was pinned, and it comes back when the
    /// drag ends. Lightroom's rule, and it is right.
    func setMaskOverlaySuppressed(_ suppressed: Bool) {
        guard maskOverlaySuppressed != suppressed else { return }
        maskOverlaySuppressed = suppressed
        if suppressed {
            // THE FIRST EFFECT TOUCH ENDS THE PERSISTENT PHASE, and this is the line
            // that decides the whole rule. Up to here the mask was still being MADE and
            // its overlay stayed up so the selection could be judged; from here the
            // photographer is judging pixels, and a red wash over the exact pixels being
            // judged is an obstruction. It ends on the PRESS rather than the release, so
            // the overlay is already gone for the very first adjustment.
            //
            // Deliberately not fired by the Edge zone: refining an edge is still
            // selection work, and `setMaskEdgeGesture` is what that zone calls.
            maskOverlayPersistentID = nil
            maskOverlayResumeID = soloMaskOverlay
            cancelMaskOverlayTimers()
            if soloMaskOverlay != nil { soloMaskOverlay = nil }
        } else if maskOverlayPinned, let id = maskOverlayResumeID,
                  currentRecipe.masks.contains(where: { $0.id == id }) {
            soloMaskOverlay = id
            maskOverlayResumeID = nil
        } else {
            maskOverlayResumeID = nil
        }
    }

    /// An EDGE control is being dragged: show the matte, because the edge IS the thing
    /// being judged. The exact complement of `setMaskOverlaySuppressed`, and they are a
    /// pair rather than two rules — an Effect slider moves the picture and the overlay
    /// covers it up, an Edge slider moves the SELECTION and the overlay is the only
    /// place it is visible at all.
    ///
    /// Dragging Refine, Expand/Contract, Soften Edge or a Levels handle with no overlay
    /// up is a control whose whole output is invisible while you are using it, which is
    /// the "I want to know what Feather does" complaint in its purest form: the glyph
    /// says what the parameter means, and this says what it just did to THIS photograph.
    ///
    /// It stands down the way a creation flash does rather than snapping off, so
    /// nudging a value repeatedly does not strobe. A PINNED overlay is left exactly
    /// alone in both directions — that is a decision, and this is feedback.
    func setMaskEdgeGesture(_ active: Bool, mask id: String?) {
        guard !maskOverlayPinned else { return }
        if active {
            guard let id else { return }
            cancelMaskOverlayTimers()
            maskEdgeGestureID = id
            if soloMaskOverlay != id { soloMaskOverlay = id }
        } else {
            guard let held = maskEdgeGestureID else { return }
            maskEdgeGestureID = nil
            guard soloMaskOverlay == held else { return }
            flashMaskOverlay(held)
        }
    }

    private var maskEdgeGestureID: String?

    private var maskOverlaySuppressed = false
    private var maskOverlayResumeID: String?

    private func cancelMaskOverlayTimers() {
        maskOverlayHideTask?.cancel()
        maskOverlayHideTask = nil
        maskOverlayHoverTask?.cancel()
        maskOverlayHoverTask = nil
    }

    /// `⌥O` and `⇧O`: cycle the mode and the colour. Cycling either turns the overlay
    /// ON if it is off — pressing a key that changes how a thing is drawn and seeing
    /// nothing happen is how a user concludes the key is broken.
    ///
    /// THEY NO LONGER PIN AS A SIDE EFFECT. Both used to run
    /// `else { maskOverlayPinned = true }`, so cycling the colour of an overlay that was
    /// merely hovering silently converted it into a permanent one — a key that says it
    /// changes an appearance quietly changing a persistence rule instead. Turning a
    /// missing overlay on is still right and still goes through `toggleMaskOverlay`,
    /// which pins deliberately; an overlay already up is left exactly as it was found.
    func cycleMaskOverlayMode() {
        maskOverlayMode = maskOverlayMode.next
        if soloMaskOverlay == nil { toggleMaskOverlay() }
    }

    func cycleMaskOverlayTint() {
        maskOverlayTint = maskOverlayTint.next
        if soloMaskOverlay == nil { toggleMaskOverlay() }
    }

    /// Whether the component under the panel's cursor is a brush.
    ///
    /// The gate on the digit keys. Digits are RATINGS everywhere else in this
    /// application, and a rating lost to a brush's Flow would be unrecoverable — so the
    /// brush has to be the thing actually selected, not merely possible.
    var activeComponentIsBrush: Bool {
        guard let id = activeMaskID,
              let mask = currentRecipe.masks.first(where: { $0.id == id }),
              mask.components.indices.contains(activeComponentIndex) else { return false }
        return mask.components[activeComponentIndex].kind == .brush
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
    /// WHETHER THE SOURCES COLUMN IS DRAWN, and it is the single largest thing this
    /// window can do for the photograph.
    ///
    /// Measured (docs/30 §3): deleting the top bar AND the status bar changes a 3:2
    /// landscape frame by +0.00 percentage points, because a landscape photograph in
    /// this window is WIDTH-limited — every horizontal band removed returns letterbox
    /// rather than picture. Hiding the 230pt sidebar is worth +19.95 points on its own,
    /// more than every other composition change combined.
    ///
    /// On `AppState` rather than in the view because the View menu has to reach it, and
    /// a `Scene`'s commands cannot see a view's `@State`. One publish per toggle, which
    /// is a thing that happens a handful of times a session.
    /// How wide the develop column is, in points, dragged by its own divider.
    ///
    /// On `AppState` rather than in a view because both `ContentView` (which draws the
    /// divider) and `DevelopPanel` (which is the column) need it, and they are siblings.
    /// `@AppStorage` would have been the obvious home except that a drag writes it on
    /// every mouse event, and `@AppStorage` writes through to `UserDefaults` each time —
    /// so it persists on release instead, the same bargain every slider in this app
    /// already makes.
    ///
    /// Clamped on read rather than on write, because a value restored from a previous
    /// version's bounds is not the user doing anything wrong.
    @Published var developPanelWidth: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: "develop.panelWidth")
        guard stored > 0 else { return Lumen.defaultPanelWidth }
        return Swift.min(Swift.max(CGFloat(stored), Lumen.minimumPanelWidth),
                         Lumen.maximumPanelWidth)
    }()

    /// Called on release, not per event.
    func persistDevelopPanelWidth() {
        UserDefaults.standard.set(Double(developPanelWidth), forKey: "develop.panelWidth")
    }

    @Published var sidebarVisible = true

    /// Persisted (docs/32 Stream A): the strip's visibility is furniture the
    /// photographer arranged, and an editor that forgets it makes them arrange it every
    /// launch. A `didSet` write costs one defaults write per toggle — this is flipped
    /// by `F`, the View menu and the status bar's switch, never per event.
    /// `object(forKey:) as? Bool` rather than `bool(forKey:)` for the reason
    /// `PanelLayout.restore` records: the typed accessor answers false both for
    /// "stored false" and for "never written", and this flag defaults to true.
    @Published var showFilmstrip = UserDefaults.standard.object(
        forKey: "filmstrip.visible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showFilmstrip, forKey: "filmstrip.visible") }
    }
    /// Published by the grid as it lays out, so ↑/↓ move by a real row rather than by
    /// a guess. Never zero — a divide-by-row-count would be a crash in the key path.
    @Published var gridColumns: Int = 6
    /// Which modal is up. Three independent booleans let two of them be true at once,
    /// which a single presenter cannot honour; these stay as the vocabulary every call
    /// site already speaks, and all three agree on one source of truth.
    /// ⌘K's palette. Not a `SheetKind`: a sheet is modal and animates in, and this is a
    /// thing you open, type four letters into and dismiss — closer to a menu than to the
    /// export dialog. Published because the chord that opens it lives in a `Scene`'s
    /// commands and the view that draws it does not.
    @Published var showControlPalette = false

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

    /// Every photograph's edit, keyed by file.
    ///
    /// DELIBERATELY NOT `@Published`. It is written once per mouse event for the whole
    /// length of a slider drag, and publishing it here fired `objectWillChange` on an
    /// object that the menu bar, the filmstrip, the grid, the sidebar, the filter bar
    /// and the status bar all observe — none of which show an edit. `EditRevision` is
    /// the signal now, and its header has the whole argument, including the rule for
    /// any view added later that reads a recipe.
    var recipes: [URL: Recipe] = [:] {
        didSet { edits.bump() }
    }

    /// The invalidation the twelve edit-facing views subscribe to. Hung off `recipes`'
    /// `didSet` rather than called at each of the five mutation sites: a notification
    /// you have to remember to send is one that eventually is not sent, and the failure
    /// mode — a panel that renders once and then silently stops following the
    /// photograph — is not one a test in this repository would catch.
    let edits = EditRevision()

    @Published var showBefore = false
    /// What the next click on the image is FOR, if anything. The picker overlay only
    /// exists while this is set, so it can never eat a pan or a click-to-zoom the rest
    /// of the time.
    ///
    /// One target rather than a flag per consumer: every colour tool in the app needs
    /// the same click and the same coordinate inverse, and four booleans would be four
    /// chances for two of them to be true at once.
    @Published var pickTarget: PickTarget?

    /// Which mixer band the Colour panel is editing, and whether it is editing all
    /// eight at once.
    ///
    /// These were `@State` inside `ColorPanel` and they moved here for one reason: the
    /// eyedropper resolves on the render actor and has to write the answer somewhere the
    /// panel will see. That is a real cost — a band click now publishes, and a publish
    /// re-bodies the window — and it is affordable precisely because it is a CLICK.
    /// `CommandState` exists to keep per-mouse-event work off this path; one publish per
    /// deliberate selection is what that budget was protecting.
    @Published var mixerBand: Int = 0
    @Published var mixerAllBands: Bool = false

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
    /// The latency instrument (docs/23 M1b): draft/settle wall times and input→draft
    /// in the loupe's corner. Debug menu; off by default and free when off.
    @Published var showLatencyHUD = false {
        didSet {
            LatencyHUD.shared.enabled = showLatencyHUD
            refreshCommandState()
        }
    }
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
    private(set) var catalog: CatalogService? {
        didSet { refreshCommandState() }
    }
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

    /// What the menu bar and the develop footer DISPLAY about history, the catalog and
    /// the selection — kept here so those two surfaces can observe something small
    /// instead of observing this object.
    ///
    /// This replaces a `history.objectWillChange` → `self.objectWillChange` forward.
    /// The forward answered a real question (the Edit menu's undo item only refreshed
    /// when a recipe happened to change on the same tick) at a price nobody had priced:
    /// `updateRecipe` records a step on every mouse event of every drag, coalescing
    /// REPLACES `steps[position - 1]`, and the forward turned that into a full
    /// invalidation of the window and of `LumenApp`'s `Scene` — all seven `.commands`
    /// menus rebuilt per mouse event. `CommandState`'s header has the rest of it.
    let commands = CommandState()

    init() {
        openCatalog()
        // Every history mutation, and nothing else. `refresh` is equality-guarded, so
        // a drag — one coalesced step, label "Edit" from first event to last — reaches
        // it on every event and publishes on none of them.
        history.onChange = { [weak self] in self?.refreshCommandState() }
        refreshCommandState()
    }

    /// Bring `commands` up to date. Cheap and idempotent by construction, so it is
    /// called from anywhere one of its five facts might have moved rather than from a
    /// carefully-maintained list of places.
    func refreshCommandState() {
        commands.refresh(undoLabel: history.undoLabel,
                         redoLabel: history.redoLabel,
                         hasCatalog: catalog != nil,
                         hasSelection: primarySelection != nil,
                         showLatencyHUD: showLatencyHUD)
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

    /// URL to catalog row id, memoised beside the contact sheet.
    ///
    /// `persist` needed this and did not have it, so it ran
    /// `allPhotos.first(where: { $0.id == url })` — a linear scan of every photograph in
    /// the source, comparing URLs, ONCE PER CHANGED PHOTO PER MOUSE EVENT. On a batch
    /// drag over a forty-frame selection at five thousand files that is two hundred
    /// thousand URL comparisons per event, on the main actor, in front of the render.
    /// And it was pure waste: `updateRecipe` iterates `editTargets`, which are
    /// `PhotoItem`s that already carry `catalogID`. The scan existed only because
    /// `persist` had been handed a `[URL: Recipe]` and had thrown the items away.
    ///
    /// Keyed and invalidated exactly like `photoCache`, because it is derived from the
    /// same array.
    private var catalogIDCache: [URL: Int64]?

    func invalidatePhotoCache() {
        photoCache = nil
        catalogIDCache = nil
        cullCountsCache = nil
        selectedPhotosCache = nil
    }

    /// One pass over the roll for every number the chrome shows, memoised.
    ///
    /// `FilterBar` is on screen in every view mode and used to run FOURTEEN separate
    /// `reduce` passes over `allPhotos` per body evaluation — three flags, five rating
    /// thresholds, six labels — and the sidebar ran two `filter` passes more, on every
    /// one of the ≥2 `objectWillChange` publishes a slider event produces. At 5,000
    /// photos that is ~80,000 element visits of pure bookkeeping per mouse move,
    /// before a pixel was requested. The numbers only change when the roll or a cull
    /// decision does, which is exactly `invalidatePhotoCache()`'s definition.
    struct CullCounts: Equatable {
        var flags: [PhotoFlag: Int] = [:]
        /// Index r = photos with rating ≥ r, for r in 1...5. Index 0 unused.
        var ratingAtLeast = [Int](repeating: 0, count: 6)
        var labels: [ColorLabel: Int] = [:]

        /// Pure and static so `LumenAppTests` can pin it without constructing an
        /// `AppState` — whose init opens the real catalog in Application Support,
        /// which no unit test should touch.
        static func counting(_ photos: [PhotoItem]) -> CullCounts {
            var counts = CullCounts()
            for photo in photos {
                counts.flags[photo.flag, default: 0] += 1
                counts.labels[photo.label, default: 0] += 1
                if photo.rating > 0 {
                    for r in 1...Swift.min(photo.rating, 5) {
                        counts.ratingAtLeast[r] += 1
                    }
                }
            }
            return counts
        }
    }

    private var cullCountsCache: CullCounts?
    private var selectedPhotosCache: [PhotoItem]?

    var cullCounts: CullCounts {
        if let cullCountsCache { return cullCountsCache }
        let counts = CullCounts.counting(allPhotos)
        cullCountsCache = counts
        return counts
    }

    /// The catalog row for a file, in one lookup.
    func catalogID(for url: URL) -> Int64? {
        if let catalogIDCache { return catalogIDCache[url] }
        var built = [URL: Int64](minimumCapacity: allPhotos.count)
        for item in allPhotos {
            if let id = item.catalogID { built[item.id] = id }
        }
        catalogIDCache = built
        return built[url]
    }

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
        if let selectedPhotosCache { return selectedPhotosCache }
        let selected = allPhotos.filter { selection.contains($0.id) }
        selectedPhotosCache = selected
        return selected
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
            // The folder guard its siblings all carry: two overlapping refreshes
            // (folder A then B) can resume out of order, and A's chips must not
            // replace B's. Membership changes re-call this, so a dropped stale
            // answer costs nothing.
            guard self.folderURL == folder else { return }
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

    // MARK: Reopening the last folder

    /// Security-scoped bookmark of the last folder the owner opened, so a launch does
    /// not start at the empty state every single time. UserDefaults rather than the
    /// catalog's `folder.bookmark` column for now: the column has no store API yet,
    /// and a bookmark is genuinely per-machine state — it names a sandbox grant, not a
    /// fact about the photographs. (When folder rows grow an API, this migrates.)
    private static let lastFolderBookmarkKey = "lumen.lastFolder.bookmark"

    /// Reopen the folder from the previous session, if its bookmark still resolves.
    /// Called once at launch by the scene; quietly does nothing on a fresh install, a
    /// deleted folder, or a revoked grant — the empty state is the correct fallback,
    /// not an error dialog about a folder the owner may not remember.
    func reopenLastFolder() {
        guard folderURL == nil,
              let data = UserDefaults.standard.data(forKey: Self.lastFolderBookmarkKey)
        else { return }
        var stale = false
        // Scoped first, plain second: the app ships ad-hoc signed with no sandbox
        // entitlement today, where scoped bookmarks fail to CREATE but a plain one
        // resolves fine — and if it ever moves into the sandbox, the scoped branch is
        // the one that works. `startAccessingSecurityScopedResource` is called for the
        // scoped case and its result deliberately unchecked: on a plain bookmark it
        // returns false and means nothing.
        let url = (try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                            relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: data, options: [],
                         relativeTo: nil, bookmarkDataIsStale: &stale))
        guard let url else { return }
        _ = url.startAccessingSecurityScopedResource()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if stale { rememberFolder(url) }
        openFolder(url)
    }

    private func rememberFolder(_ url: URL) {
        let data = (try? url.bookmarkData(options: [.withSecurityScope],
                                          includingResourceValuesForKeys: nil,
                                          relativeTo: nil))
            ?? (try? url.bookmarkData(options: [],
                                      includingResourceValuesForKeys: nil,
                                      relativeTo: nil))
        guard let data else { return }
        UserDefaults.standard.set(data, forKey: Self.lastFolderBookmarkKey)
    }

    func openFolder(_ url: URL) {
        rememberFolder(url)
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

        // The recipes/history wipe happens in `applyScan`, at the moment the roll
        // actually changes — NOT here. It used to happen here, seconds before the new
        // roll arrived, while the OLD roll stayed fully visible and clickable: a
        // click plus one slider move during the scan window edited a photo whose
        // saved recipe had just been wiped, so the edit started from defaults and
        // persisted default-plus-delta over the real recipe in the catalog AND the
        // sidecar. The wipe and the roll swap are one atomic step or they are a
        // data-loss window.
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
            // Whether the roll this scan built is still the one the user wants —
            // decided on the main actor, and the BACKFILL LAUNCH depends on it too:
            // a superseded folder's scan used to fire its full EXIF pass anyway,
            // thousands of file opens on the catalog's serial maintenance queue,
            // AHEAD of the folder actually on screen (audit queue item 11).
            let stillCurrent = await MainActor.run { () -> Bool in
                // Open folder A, then B before A finishes, and A's scan can land
                // second. The newest folder the user asked for is the one on screen.
                guard let self, self.scanGeneration == generation else { return false }
                self.applyScan(found, stored: stored)
                return true
            }
            guard stillCurrent else { return }
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
                    // The facet lists read the very rows this pass just filled, and
                    // nothing else re-asks until membership changes — so without this
                    // the camera and lens menus said "No camera has been read yet"
                    // until the NEXT launch, on a folder whose EXIF had been sitting
                    // in the catalog since seconds after it opened (session C, the
                    // owner's Sony a7 IV / Lumix GX85 report).
                    self.refreshLibrarySections()
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
        // The old roll's last deferred writes land BEFORE its state is wiped — a
        // gesture whose release never arrived must not lose its edit to a folder
        // switch (the same promise `prepareToQuit` makes at the other exit).
        // Through `sliderGesture(active: false)` so the watchdog is retired with it.
        sliderGesture(active: false)
        // The undo stack and the in-memory recipes belong to the roll that produced
        // them; they die at the exact moment `allPhotos` is replaced, never earlier.
        // (⌘Z across a folder switch used to revert an .xmp in a folder that is not
        // open; wiping early opened the scan-window loss above. Both ends of the
        // history live here now.)
        history.clear()
        var items = urls.map { PhotoItem(id: $0) }
        // Built locally and assigned once. `recipes` signals every write, and a folder
        // of five thousand photographs would otherwise signal five thousand times
        // before the first frame is drawn.
        var loaded: [URL: Recipe] = [:]
        for i in items.indices {
            if let row = stored[items[i].id] {
                items[i].catalogID = row.catalogID
                items[i].flag = row.flag
                items[i].rating = row.rating
                items[i].label = row.label
                items[i].iso = row.iso
                if let recipe = row.recipe { loaded[items[i].id] = recipe }
            }
        }
        recipes = loaded
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
        // NO COUNT HERE. `ContentView.countText` owns the count and prints it a few
        // points to the right, so writing it into `statusMessage` put "239 photos" on
        // screen twice, in one band, permanently — `statusMessage` is cleared only by a
        // pick cancel or a colour pick, so it was not a transient toast. Counting the
        // sidebar's "All photos 239" and "This folder 239", both drawn as active, the
        // number 239 appeared four times in one window in three phrasings (docs/30 §2.4).
        // This one had the weakest claim: it is a scan completing, and a scan that
        // completes with the expected number is not news.
        statusMessage = nil
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
        // AND THE SOLO, for the same reason and it was the one that got left behind. A
        // mask id is per-photograph, so after arrowing to the next frame `soloMaskOverlay`
        // still held the previous photo's mask: the overlay did not draw (its raster
        // comes back nil for an id this recipe has no mask for) AND the next press of `O`
        // took the "solo is set, clear it" branch — so the first O after every photo
        // change did nothing and you had to press it twice.
        // And the ambient state with it: a pin, a pending hover and a pending flash all
        // name a mask that belongs to the photograph being left.
        maskOverlayPinned = false
        maskOverlayResumeID = nil
        // The persistent overlay is per-mask and a mask id is per-photograph, so it
        // travels with the pin and the pending timers rather than outliving them.
        maskOverlayPersistentID = nil
        cancelMaskOverlayTimers()
        soloMaskOverlay = nil
        loadStrokeSets(for: recipe(for: photo))
        scheduleScopeRefresh()
        // The clipping panel follows the cursor and NOTHING ELSE. It is measured on the
        // decode, before every Lumen stage, so no slider in the app can move a number
        // in it — which is exactly why the cache is keyed on the file and why the edit
        // paths above do not schedule it.
        scheduleRawTruthRefresh()
        refreshMaskOverlay()
        refreshMaskThumbnails()
    }

    /// The direction the photographer last travelled, for `DecodeWarming`: forward
    /// unless an arrow said otherwise. Starts forward because a shoot is opened at its
    /// beginning and worked through, and because auto-advance only goes one way.
    private(set) var movingForward: Bool = true

    func selectNext() { moveSelection(by: 1) }
    func selectPrevious() { moveSelection(by: -1) }

    /// One arrow press. Which list it walks — the roll, or the selection being
    /// compared — is `ArrowNavigation.step`, in LumenCore, where it has tests; this
    /// method supplies the indices and carries out the answer.
    func moveSelection(by delta: Int) {
        // Which way the read-ahead should look. Set here rather than inferred from two
        // consecutive selections, because a jump (a filmstrip click, a filter change)
        // has no direction and must not flip the guess for the next arrow press.
        if delta != 0 { movingForward = delta > 0 }
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

    /// What "unedited" means for the CURRENT photo — the baseline every modified-dot
    /// and reset affordance must compare against. Comparing against bare `Recipe()`
    /// instead is how an untouched JPEG wore a modified dot (its baseline is the
    /// Linear preset) and how Reset applied a second tone map to it.
    var currentStartingRecipe: Recipe {
        guard let photo = primarySelection else { return Recipe() }
        return AppState.startingRecipe(for: photo.id, iso: photo.iso)
    }


    /// The grey a colour-driven mask component is born with, so it is a valid
    /// component before anything has been picked. Named because two places have to
    /// agree it is a placeholder rather than a choice.
    /// Reach of a freshly planted similarity point, as a fraction of the long edge.
    /// docs/08 §8.2's "~15% long edge" — big enough that one click on a sky selects
    /// sky rather than a coin, small enough that it is visibly LOCAL, which is the
    /// property that distinguishes this component from Colour Range.
    static let similarityPointRadius: Double = 0.15

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
        // Disarmed BEFORE the hop, not after: cleared on the far side of the await, a
        // second click while the first solve was in flight spawned a second task and a
        // colour mask collected its sample twice.
        pickTarget = nil
        Task {
            // Every branch below awaits an actor whose queue can hold a cold decode,
            // then writes through `updateRecipe` — which reads the CURRENT selection.
            // Without this re-check, arrowing to the next photo mid-solve landed
            // DSC_1's neutral in DSC_2's recipe, persisted, with a status line saying
            // it worked. The sibling refreshes all carry this guard; the one path
            // that WRITES was the one that lacked it.
            // (@MainActor because a local func does NOT inherit the Task closure's
            // actor isolation the way its surrounding statements do.)
            @MainActor func selectionStillOnPickedPhoto() -> Bool {
                if primarySelection?.id == url { return true }
                statusMessage = "Pick discarded — the selection moved before it resolved."
                return false
            }
            switch target {
            case .neutral:
                let solved = await renderCoordinator.solveNeutral(
                    url: url, recipe: current, sourceX: sourceX, sourceY: sourceY)
                guard selectionStillOnPickedPhoto() else { return }
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

            case .newPointColor, .pointColor, .maskSample, .maskPointColor, .mixerBand:
                // WHICH TAP depends on what will compare against the stored value.
                // A mask's samples are compared by `colorRangePlane` and
                // `similarityPlane` against `localStageInput` — after tone, after the
                // colour and grade table — and a mask's own Point Colour is evaluated
                // inside `LocalPlan`, whose input is that same image. A GLOBAL Point
                // Colour is compared inside S9, whose input is the colour stage's —
                // after tone and presence, before the colour+grade table. It used to
                // store `sampleWorking` (post-S6 only), so a swatch picked on a
                // photograph carrying any tone move selected the wrong colour, and
                // the error grew with the edit (docs/23 dossier queue item 5).
                let sample: RGB?
                if target.samplesTheMaskStage {
                    sample = await renderCoordinator.sampleMaskReference(
                        url: url, recipe: current, sourceX: sourceX, sourceY: sourceY)
                } else {
                    sample = await renderCoordinator.samplePointColorReference(
                        url: url, recipe: current, sourceX: sourceX, sourceY: sourceY)
                }
                guard selectionStillOnPickedPhoto() else { return }
                guard let sample else {
                    statusMessage = "Could not read a colour there."
                    return
                }
                let rgb = [sample.r, sample.g, sample.b]
                switch target {
                case .mixerBand:
                    // The only pick that writes no recipe. It answers "which of eight
                    // bands is this colour?" — a question the photographer previously
                    // had to answer from memory before the three sliders meant
                    // anything — and moves the panel's selection there.
                    //
                    // Through `ColorEngine.dominantBand`, which reads the LIVE arcs off
                    // the recipe rather than the canonical geometry: the ring's handles
                    // are draggable, so a widened Blue really does own hues that the
                    // default geometry gives to Aqua, and selecting from the centres
                    // would contradict the ring on screen.
                    let arcs = ColorEngine.bandArcs(current.develop.mixer.bands)
                    guard let band = ColorEngine.dominantBand(for: sample, arcs: arcs) else {
                        statusMessage = "No colour to work on there — that pixel is grey."
                        return
                    }
                    mixerBand = band
                    mixerAllBands = false
                    statusMessage = "\(ColorEngine.bandNames[band]) selected."
                    return
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
                        let replacing = list == [AppState.placeholderSample]
                        if replacing {
                            list = [rgb]
                        } else {
                            guard list.count < 8 else { return }
                            list.append(rgb)
                        }
                        recipe.masks[m].components[component].samples = list

                        // A Colour Pick is "pixels like this one, NEAR HERE", so the
                        // click that takes the colour also plants the point. Without
                        // this the spatial half of the component would be a control
                        // nobody could reach: there is no other gesture in the app that
                        // knows where on the photograph a sample came from.
                        //
                        // Colour Range is deliberately excluded — it IS the global
                        // version, and that distinction is the whole reason both kinds
                        // exist.
                        let kind = recipe.masks[m].components[component].kind
                        if kind == .similarity || kind == .similarityLine {
                            var points = recipe.masks[m].components[component].points ?? []
                            let planted = [sourceX, sourceY,
                                           AppState.similarityPointRadius, 1]
                            if replacing || points.isEmpty {
                                points = [planted]
                            } else {
                                points.append(planted)
                            }
                            recipe.masks[m].components[component].points = points
                        }
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

    func updateRecipe(coalescingKey: String? = nil, label: String? = nil,
                      _ mutate: (inout Recipe) -> Void) {
        updateRecipe(coalescingKey: coalescingKey, label: label) { _, recipe in
            mutate(&recipe)
        }
    }

    /// The photo-aware overload, for edits whose result depends on WHICH photo —
    /// a reset must land on `startingRecipe(for:)`, which is not the same for every
    /// file (Linear preset for rendered files, ISO-resolved denoise for RAW), and a
    /// closure that cannot see the photo can only reset everyone to the same wrong
    /// baseline. Session findings: Reset flipped a JPEG's Linear preset to the
    /// default sigmoid — a second tone map, persisted, and undo recorded the same
    /// wrong baseline so it could not come back.
    /// `targets` narrows the write to specific photographs. Nil means the whole
    /// selection, which is what every ordinary edit wants and what this always did.
    ///
    /// It exists for the gestures that are about ONE picture even when several are
    /// selected. Escape in the crop tool is the case that forced it: the baseline it puts
    /// back is taken for the primary selection alone, so writing it through the selection
    /// stamped that photograph's framing onto every other one and destroyed their crops —
    /// from a key that means "cancel".
    func updateRecipe(coalescingKey: String? = nil, label: String? = nil,
                      targets explicit: [PhotoItem]? = nil,
                      _ mutate: (PhotoItem, inout Recipe) -> Void) {
        let targets = explicit ?? editTargets
        guard !targets.isEmpty else { return }
        var before: [URL: HistoryStack.PhotoEdit] = [:]
        var after: [URL: HistoryStack.PhotoEdit] = [:]
        var changed: [URL: Recipe] = [:]
        var touchedPixels = false
        for photo in targets {
            let old = recipe(for: photo)
            var updated = old
            mutate(photo, &updated)
            guard updated != old else { continue }
            if !updated.rendersSameAs(old) { touchedPixels = true }
            before[photo.id] = HistoryStack.PhotoEdit(recipe: old)
            after[photo.id] = HistoryStack.PhotoEdit(recipe: updated)
            changed[photo.id] = updated
            recipes[photo.id] = updated
        }
        guard !after.isEmpty else { return }
        history.record(before: before, after: after, coalescingKey: coalescingKey,
                       label: label)
        if sliderGestureActive {
            // Mid-gesture: the in-memory recipe is current (the render reads that),
            // the catalog write and the scope re-bin land once at release. The overlay
            // stays live below — it is the picture OF the drag.
            noteGestureActivity()
            for (url, recipe) in changed { pendingGesturePersist[url] = recipe }
            if touchedPixels { pendingGestureTouchedPixels = true }
        } else {
            persist(changed)
            // Renaming a mask changes the recipe without changing the picture.
            // Re-binning the scopes for it would mean a proxy render per keystroke.
            if touchedPixels {
                scheduleScopeRefresh()
                // Adding a Subject or People component is the moment its matte is
                // wanted.
                ensureMaskMattes()
            }
        }
        if touchedPixels {
            // The overlay is a picture of the mask, so editing the mask must move it —
            // including while dragging the mask's own sliders. Its refresh is
            // generation-guarded and cancels its predecessor, so per-event is cheap.
            refreshMaskOverlay()
            // And the rows' pictures of the same masks. Keyed on the masks' own shape
            // plus the mask-source fingerprint, so an edit that moves neither — a
            // rename, a crop the masks reproject through — costs nothing.
            refreshMaskThumbnails()
            // The HUD's input side: the next draft that lands closes the loop.
            LatencyHUD.shared.noteInput()
        }
    }

    // MARK: Slider gestures

    /// True between the first movement of a slider gesture and its release.
    ///
    /// While it holds, `updateRecipe` keeps the in-memory recipe current (the render
    /// path reads that) but defers the catalog write — a SQLite statement plus four
    /// whole-recipe JSON codings for the fingerprint, previously paid PER PHOTO PER
    /// MOUSE EVENT on the lane every thumbnail decode shares — and the scope
    /// re-binning, whose 180 ms debounce a drag restarted every event and so never
    /// fired anyway. Both land once, at release.
    /// True from the first movement of any slider or wheel gesture to its release.
    ///
    /// Read OUTSIDE this type by the loupe, which must not start a full-resolution
    /// settle while a hand is moving — see `settleTick`. Not `@Published`: the render
    /// key changes on the tick, not on the latch, so publishing this would re-body the
    /// window twice per gesture for nothing.
    private(set) var sliderGestureActive = false

    /// Bumped once per completed gesture, and read by `ViewerRenderKey`.
    ///
    /// The settle is deferred while a gesture runs, so something has to ask for it
    /// when the hand stops — and the release alone cannot, because `onEnded` commits
    /// a value that is usually EQUAL to the last motion sample, leaving the render key
    /// unchanged and the picture on its last draft. This tick is that ask. It is
    /// bumped in `flushSliderGesture`, which the release, the photo switch and the
    /// 8-second watchdog all already call, so the deferred settle inherits all three
    /// safety nets rather than needing its own.
    @Published private(set) var settleTick: Int = 0

    private var pendingGesturePersist: [URL: Recipe] = [:]
    private var pendingGestureTouchedPixels = false

    /// The two unlatches for a release SwiftUI dropped (docs/23 audit queue item 4).
    ///
    /// `.onEnded` is not a promise: a drag cancelled by a window teardown or a view
    /// rebuild never delivers it, and the latch used to stay shut — every LATER edit,
    /// gesture or not, deferred its catalog write until the next completed gesture,
    /// a folder switch, or quit. A real drag's events are milliseconds apart, so
    /// silence this long means the release is not coming; the watchdog closes the
    /// gesture and lands the deferred writes. The photo switch in
    /// `primarySelection.didSet` is the second unlatch: a gesture cannot span photos.
    static let gestureSilenceTimeout: TimeInterval = 8
    private var lastGestureEventAt = Date.distantPast
    private var gestureWatchdog: Task<Void, Never>?

    /// The gesture hook, allocated ONCE and handed to the environment as a stable
    /// value — see the injection site in `ContentView`. `lazy` so `self` is available.
    lazy var sliderGestureSink: (Bool) -> Void = { [weak self] active in
        self?.sliderGesture(active: active)
    }

    /// Slider keyboard focus, and DELIBERATELY NOT `@Published`.
    ///
    /// Only `KeyDispatcher` reads it, imperatively, at key-down time — no view renders
    /// anything from it — so publishing would re-body the window every time focus moved
    /// between two sliders for no one's benefit. `EditRevision`'s header states the rule
    /// this is the other side of: a view reading state must observe it, and state no
    /// view reads must not be observable.
    ///
    /// A COUNT rather than a flag, because SwiftUI does not order focus changes: moving
    /// from one slider to the next can deliver the new row's `true` before the old row's
    /// `false`, and a flag would end up clear while a slider plainly had focus — arrows
    /// paging photographs out from under a control the photographer is using, which is
    /// the exact failure this whole mechanism exists to prevent.
    private var sliderFocusCount = 0

    var sliderHoldsFocus: Bool { sliderFocusCount > 0 }

    /// The focus hook, allocated ONCE and handed to the environment as a stable value —
    /// same pattern as `sliderGestureSink`, and for the same reason.
    lazy var sliderFocusSink: (Bool) -> Void = { [weak self] focused in
        self?.noteSliderFocus(focused)
    }

    func noteSliderFocus(_ focused: Bool) {
        // Floored rather than allowed to go negative: a slider that disappears while
        // focused reports its blur from `onDisappear` as well, and a double-decrement
        // that went to −1 would leave the count unable to reach zero again.
        sliderFocusCount = focused ? sliderFocusCount + 1
                                   : Swift.max(0, sliderFocusCount - 1)
    }

    /// The grid's hover-rating hook, on the same pattern and for the same reason.
    ///
    /// `PhotoCell` is value-typed by contract — "it never reads AppState, so a rating
    /// written three cells away does not invalidate the whole sheet" — so the click has
    /// to arrive as a value. Allocating a closure per cell inside the grid's `body`
    /// would mean sixty new closure identities on every pass of a view that re-bodies
    /// on selection, scroll and every culling keystroke. One stored closure, handed
    /// down unchanged.
    lazy var ratingSink: (PhotoItem, Int) -> Void = { [weak self] photo, rating in
        self?.rate(photo, rating)
    }

    /// Rate one photograph from the contact sheet.
    ///
    /// It SELECTS first, which is what makes it correct rather than merely convenient:
    /// `setRating` acts on `editTargets`, so a click on an unselected thumbnail would
    /// otherwise rate whatever was selected somewhere else on screen. Selecting first
    /// is also what every other grid in the field does with a click, and it leaves the
    /// keyboard grammar — 1…5 on the selection, toggling, honouring auto-advance —
    /// as the single implementation of what a rating means.
    func rate(_ photo: PhotoItem, _ rating: Int) {
        if primarySelection?.id != photo.id || selection.count > 1 {
            select(photo)
        }
        setRating(rating)
    }

    func sliderGesture(active: Bool) {
        if active {
            lastGestureEventAt = Date()
            if !sliderGestureActive {
                sliderGestureActive = true
                armGestureWatchdog()
            }
            return
        }
        guard sliderGestureActive else { return }
        sliderGestureActive = false
        gestureWatchdog?.cancel()
        gestureWatchdog = nil
        flushSliderGesture()
    }

    /// Note a mid-gesture edit, so the watchdog measures silence rather than duration:
    /// a long careful drag is not a dropped one.
    func noteGestureActivity() {
        lastGestureEventAt = Date()
    }

    private func armGestureWatchdog() {
        gestureWatchdog?.cancel()
        gestureWatchdog = Task { @MainActor [weak self] in
            while let self, self.sliderGestureActive {
                let silence = Date().timeIntervalSince(self.lastGestureEventAt)
                let remaining = Self.gestureSilenceTimeout - silence
                if remaining <= 0 {
                    self.sliderGestureActive = false
                    self.gestureWatchdog = nil
                    self.flushSliderGesture()
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1e9))
                if Task.isCancelled { return }
            }
        }
    }

    /// Also called from `prepareToQuit`: a gesture whose release the app never saw
    /// (a cancelled drag, a window torn down mid-gesture) must not cost the edit.
    func flushSliderGesture() {
        if !pendingGesturePersist.isEmpty {
            persist(pendingGesturePersist)
            pendingGesturePersist = [:]
        }
        if pendingGestureTouchedPixels {
            pendingGestureTouchedPixels = false
            scheduleScopeRefresh()
            ensureMaskMattes()
        }
        // The hand has stopped: ask every viewer for the quality pass its drag
        // deferred. Unconditional — a gesture that changed nothing costs one settle
        // whose every table and decode is already cached, and a gesture that landed on
        // its last drafted value would otherwise never settle at all.
        settleTick &+= 1
    }

    /// INTERNAL, not private, because `AppStateActions` is an extension in another file
    /// and `private` in Swift is file-scoped. Auto Tone lived over there writing the
    /// catalog by hand for want of this, and so skipped the library requery that keeps an
    /// "Edited: no" filter honest.
    func persist(_ changes: [URL: Recipe]) {
        guard let catalog else { return }
        for (url, recipe) in changes {
            // One dictionary lookup. This was `allPhotos.first(where:)` — a linear scan
            // of the whole source, per changed photo, per mouse event, on the main
            // actor, in front of the render. See `catalogIDCache`.
            catalog.saveRecipe(recipe, url: url, catalogID: catalogID(for: url))
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
        // A gesture whose release never arrived must not cost the edit.
        flushSliderGesture()
        // The thumbnail-size debounce (800 ms) has the same quit window the sidecar
        // flush once had: resize the grid and ⌘Q inside it, and the size reverted
        // next launch. The final event lands here.
        sourceStateSaveTask?.cancel()
        saveSourceState()
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
        if touchedPixels {
            scheduleScopeRefresh()
            // AND THE MASK OVERLAY, which undo never told. `maskOverlayAlpha` is written
            // only by `refreshMaskOverlay`, whose callers are the solo toggle,
            // `updateRecipe`, the matte pass and a photo change — none of which fires
            // here. So turning a mask's overlay on, dragging its radius and pressing ⌘Z
            // reverted the picture and left the red wash at the pre-undo shape: the
            // instrument and the photograph disagreeing about the same mask. Undoing a
            // mask DELETION was worse — the overlay for a mask that no longer existed
            // stayed painted until some unrelated edit happened to refresh it.
            refreshMaskOverlay()
            refreshMaskThumbnails()
            // Same reason: a restored Vision mask needs its matte asked for again.
            ensureMaskMattes()
        }
    }

    // MARK: Copy / paste settings

    /// `@Published` because two menu items are `.disabled` on whether it is nil, and a
    /// plain stored property does not tell SwiftUI to look again — so "Paste Masks"
    /// would stay greyed out until something else happened to redraw the menu bar.
    @Published private var copiedRecipe: Recipe?
    private var copiedLook: Look?

    func copySettings() { copiedRecipe = primarySelection.map(recipe(for:)) }

    func pasteSettings() {
        guard let source = copiedRecipe else { return }
        updateRecipe(label: "Paste Settings") { recipe in
            recipe.develop = source.develop
            recipe.look = source.look
            recipe.masks = source.masks
            // The folders come with their masks. Without this line every pasted mask
            // names a group the target photograph has not got, which `Recipe.effective`
            // treats as ungrouped — so the edit survives and the organization silently
            // does not, which is the kind of loss nobody notices until they go looking.
            recipe.maskGroups = source.maskGroups
        }
    }

    /// Everything except the masks — the develop and look, with this photograph's own
    /// masks left exactly where they are.
    ///
    /// The variant that makes Paste Settings usable across a shoot. Masks are geometry
    /// in SOURCE coordinates, so a radial placed over a face in one frame lands on a
    /// shoulder in the next; pasting a whole recipe across forty frames therefore
    /// destroys forty sets of local work to deliver one white balance. Lightroom asks
    /// with a checkbox dialog every time, which is a question you answer identically
    /// nine times out of ten. Two commands cost nothing and ask nothing.
    func pasteSettingsWithoutMasks() {
        guard let source = copiedRecipe else { return }
        updateRecipe(label: "Paste Settings Without Masks") { recipe in
            recipe.develop = source.develop
            recipe.look = source.look
        }
    }

    /// Only the masks, and their folders. The develop and look of each target are left
    /// alone, which is what "put this sky mask on the rest of the sequence" means when
    /// the frames were exposed differently.
    ///
    /// APPENDED, not replaced, and that is the difference between this and the two
    /// above: those are "make this photograph like that one", and this one is "also do
    /// this". Replacing would silently delete whatever local work each target already
    /// had, with no way back but undo — and it is the same gesture people use to build a
    /// stack up mask by mask across a sequence.
    func pasteMasks() {
        guard let source = copiedRecipe, !source.masks.isEmpty else { return }
        // `Recipe.appendingMasks` owns the id remapping, in LumenCore where
        // `PasteMasksTests` can reach it — the interesting half of this command is an
        // algorithm about references, not a menu item.
        updateRecipe(label: "Paste Masks") { recipe in
            recipe = recipe.appendingMasks(from: source)
        }
    }

    /// True when there is something on the clipboard worth offering the mask commands
    /// for — the menu greys them out rather than offering a paste that does nothing.
    var hasCopiedMasks: Bool { !(copiedRecipe?.masks.isEmpty ?? true) }
    var hasCopiedSettings: Bool { copiedRecipe != nil }

    /// Copy Look copies exactly the look-tagged slice (D4) — grade, film stock,
    /// transform preset — and nothing else. Each target keeps its own white balance,
    /// exposure and denoise, which is what makes one look across 800 frames a
    /// selection gesture rather than a copy-paste-then-fix ritual.
    func copyLook() { copiedLook = primarySelection.map { recipe(for: $0).look } }

    func pasteLook() {
        guard let look = copiedLook else { return }
        updateRecipe(label: "Paste Look") { $0.look = look }
    }

    // MARK: Saved looks

    /// The looks in the catalog, as the browser lists them.
    ///
    /// Refreshed on demand — when the panel appears and after anything that changes the
    /// list — and never on a timer, for the reason `refreshLibrarySections` gives about
    /// a list that moves while you are reading it.
    @Published private(set) var savedLooks: [LookRow] = []

    func refreshSavedLooks() {
        guard let catalog else {
            savedLooks = []
            return
        }
        Task { [weak self] in
            let rows = await catalog.looks()
            self?.savedLooks = rows
        }
    }

    /// Save the Look layer of the photo under the cursor, under a name.
    ///
    /// What gets saved is decided by `LookSubset.extracted(from:)` in LumenCore, not
    /// here: which subtrees a look carries is the whole design of the feature and it is
    /// tested where it can fail, rather than being a line in an untestable view model.
    func saveCurrentLook(named name: String) {
        guard let catalog else {
            statusMessage = "No catalog — a look needs somewhere to live"
            return
        }
        guard primarySelection != nil else {
            statusMessage = "Select a photo whose look you want to keep"
            return
        }
        guard let clean = LookSubset.normalizedName(name) else {
            statusMessage = "A look needs a name"
            return
        }
        let replacing = savedLooks.contains { $0.name == clean }
        let subset = LookSubset.extracted(from: currentRecipe)
        Task { [weak self] in
            let saved = await catalog.saveLook(name: clean, subset: subset)
            guard let self else { return }
            if saved == nil {
                self.statusMessage = "\"\(clean)\" could not be saved"
            } else {
                self.statusMessage = replacing ? "Look \"\(clean)\" updated"
                                               : "Look \"\(clean)\" saved"
            }
            self.refreshSavedLooks()
        }
    }

    /// Put a saved look on the selection: one history step, undoable, and every frame
    /// keeps its own white balance, exposure, crop and masks.
    func applyLook(_ look: LookRow) {
        let targets = editTargets.count
        guard targets > 0 else {
            statusMessage = "Select the photos to apply \"\(look.name)\" to"
            return
        }
        guard let subset = try? look.subset() else {
            statusMessage = "\"\(look.name)\" could not be read"
            return
        }
        updateRecipe(label: "Apply Look") { recipe in
            recipe = subset.applied(to: recipe)
        }
        statusMessage = targets == 1
            ? "Applied \"\(look.name)\""
            : "Applied \"\(look.name)\" to \(targets) photos"
    }

    func renameLook(_ look: LookRow, to name: String) {
        guard let catalog else { return }
        guard let clean = LookSubset.normalizedName(name), clean != look.name else {
            return
        }
        Task { [weak self] in
            let renamed = await catalog.renameLook(id: look.id, to: clean)
            guard let self else { return }
            if !renamed { self.statusMessage = "There is already a look called \"\(clean)\"" }
            self.refreshSavedLooks()
        }
    }

    func deleteLook(_ look: LookRow) {
        guard let catalog else { return }
        Task { [weak self] in
            await catalog.deleteLook(id: look.id)
            guard let self else { return }
            // Deliberately said out loud: throwing a look away is not undoable, and
            // every photograph already graded with it keeps its grade.
            self.statusMessage = "Deleted \"\(look.name)\" — graded photos keep their grade"
            self.refreshSavedLooks()
        }
    }

    func resetSettings() {
        // Reset lands on the photo's own STARTING recipe, not on bare defaults:
        // a JPEG's baseline carries the Linear preset (a bare Recipe() would apply
        // a second tone map), a RAW's carries its ISO-resolved denoise.
        updateRecipe { photo, recipe in
            var base = AppState.startingRecipe(for: photo.id, iso: photo.iso)
            base.pipelineVersion = recipe.pipelineVersion
            recipe = base
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
