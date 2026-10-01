// LibraryFilter.swift
// The library query grammar — the filter bar as a value, and the boolean rule it obeys.
//
// docs/10 §10.8 and D39, day one: **multi-value within one criterion is OR, and criteria
// AND with each other.** The bar's All/Any toggle (`matchAny`) flips the join BETWEEN
// criteria and never the join within one — lighting Pick and Reject always means "pick
// or reject", whatever the toggle says.
//
// This lived in `LumenApp/AppState.swift`, which is `#if os(macOS)`, so none of it could
// be tested on the lane where every other rule in this project is pinned. Nothing here
// needs a window — it is set algebra over value types and a string — so it moved, and
// the presentation it used to sit beside (SF Symbols, SwiftUI `Color`, the app's
// `SortOrder` menu) stayed behind in LumenApp. `LibraryFilterTests` holds it.

import Foundation

// MARK: - What the memory path can ask a photo

/// The five questions `LibraryFilter.matches` puts to a photo.
///
/// A protocol rather than a moved `PhotoItem`, because `PhotoItem` is the app's roll
/// entry — it carries a catalog row id, an ISO and a source identity the filter never
/// reads, and it is at home in LumenApp. This is the part of it the grammar needs, which
/// is also exactly the part a test can build in one line.
public protocol LibraryFilterable {
    var flag: PhotoFlag { get }
    var rating: Int { get }
    /// `nil` is unlabelled — the absence of a label, not a sixth colour.
    var label: ColorLabel? { get }
    var isRaw: Bool { get }
    var filename: String { get }
}

// MARK: - Criteria vocabulary

/// ISO as a chip: bands rather than a free-form pair of numbers, because the question
/// a photographer actually asks a filter is "show me the clean ones" or "show me the
/// ones that will need denoise", and because a band is one click.
public enum ISOBand: String, CaseIterable, Identifiable, Sendable {
    case upTo400 = "≤ 400"
    case to1600 = "401–1600"
    case to6400 = "1601–6400"
    case above6400 = "≥ 6401"

    public var id: String { rawValue }

    public var range: ClosedRange<Int> {
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
public enum StackFilter: String, CaseIterable, Identifiable, Sendable {
    case any = "All frames"
    case collapsedTops = "Collapsed stacks"
    case unstacked = "Unstacked only"

    public var id: String { rawValue }
}

// MARK: - The filter

public struct LibraryFilter: Equatable, Sendable {
    /// Criteria OR within themselves and AND across themselves — the day-one rule
    /// (D39). An empty set means "no constraint from this criterion". `matchAny` is
    /// the bar's All/Any toggle and flips the join BETWEEN criteria, never within one.
    public var flags: Set<PhotoFlag> = []
    public var minRating: Int = 0
    public var labels: Set<ColorLabel> = []
    /// The "Unlabelled" chip. Its own field rather than a sixth `ColorLabel` case,
    /// because unlabelled is a NULL in `photo.label` and `label IN (…)` can never match
    /// a NULL — which is why `PhotoQuery` has always carried the same split. It joins
    /// the colours with OR, exactly like one more colour would: it is one criterion.
    public var includeUnlabeled: Bool = false
    public var text: String = ""
    public var rawOnly: Bool = false

    /// nil = no constraint, true = has an edit that changes the picture, false = as
    /// shot. Reads `photo.edited`, which `saveRecipe` maintains in the same transaction
    /// as the recipe — no join, no parse, and true only when the recipe actually
    /// renders differently.
    public var edited: Bool? = nil
    public var cameras: Set<String> = []
    public var lenses: Set<String> = []
    public var isoBands: Set<ISOBand> = []
    public var stackState: StackFilter = .any
    public var keywords: Set<String> = []
    public var matchAny: Bool = false

    public init() {}

    // MARK: Shape of the query

    /// The criteria that only exist in SQL. The memory fallback cannot evaluate any of
    /// them — it has no camera, no ISO and no stack table — so the bar hides these
    /// chips rather than offering controls that would quietly do nothing.
    public var usesCatalogOnlyCriteria: Bool {
        edited != nil || !cameras.isEmpty || !lenses.isEmpty || !isoBands.isEmpty
            || stackState != .any || !keywords.isEmpty
    }

    public var isActive: Bool {
        !flags.isEmpty || minRating > 0 || !labels.isEmpty || includeUnlabeled
            || !text.isEmpty || rawOnly || usesCatalogOnlyCriteria
    }

    /// How many criteria are lit, for the badge on the Filter button.
    ///
    /// Criteria, not values: three flag chips lit is ONE criterion, because they OR
    /// together into a single clause of the query. A badge counting chips would read
    /// "5" for what the sentence calls two conditions. Unlabelled is one more value of
    /// the label criterion, not a criterion of its own.
    public var activeCriteriaCount: Int {
        var n = 0
        if !flags.isEmpty { n += 1 }
        if minRating > 0 { n += 1 }
        if !labels.isEmpty || includeUnlabeled { n += 1 }
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
    public var hiddenCriteriaCount: Int {
        activeCriteriaCount - (text.isEmpty ? 0 : 1)
    }

    // MARK: The memory path

    /// The memory path, used only when there is no catalog to ask. It answers the five
    /// criteria a roll entry can answer and is deliberately not extended past them:
    /// a filter that silently ignores a lit chip is the failure this file exists to
    /// avoid, which is why the bar hides those chips in this mode instead.
    ///
    /// It honours `matchAny` the way `CatalogStore`'s builder does: each lit criterion
    /// is one verdict, OR-ed within itself, and the verdicts are AND-ed — or OR-ed under
    /// Match: Any. It used to AND them whatever the toggle said, so with no catalog the
    /// grid, and every chip count `memoryCount` draws from this, answered a different
    /// question from the sentence above them.
    public func matches<Photo: LibraryFilterable>(_ photo: Photo) -> Bool {
        if matchAny { return matchesAny(photo) }
        if !flags.isEmpty && !flags.contains(photo.flag) { return false }
        if photo.rating < minRating { return false }
        if !labels.isEmpty || includeUnlabeled {
            if let label = photo.label {
                if !labels.contains(label) { return false }
            } else if !includeUnlabeled {
                return false
            }
        }
        if rawOnly && !photo.isRaw { return false }
        if !text.isEmpty
            && !photo.filename.localizedCaseInsensitiveContains(text) { return false }
        return true
    }

    /// Match: Any over the same five criteria. A photo passes when ANY lit criterion
    /// passes; with none of the five lit there is nothing to disagree with, so it passes
    /// — the same answer the All join gives an empty set of criteria.
    private func matchesAny<Photo: LibraryFilterable>(_ photo: Photo) -> Bool {
        var lit = false
        if !flags.isEmpty {
            if flags.contains(photo.flag) { return true }
            lit = true
        }
        if minRating > 0 {
            if photo.rating >= minRating { return true }
            lit = true
        }
        if !labels.isEmpty || includeUnlabeled {
            let passes = photo.label.map { labels.contains($0) } ?? includeUnlabeled
            if passes { return true }
            lit = true
        }
        if rawOnly {
            if photo.isRaw { return true }
            lit = true
        }
        if !text.isEmpty {
            if photo.filename.localizedCaseInsensitiveContains(text) { return true }
            lit = true
        }
        return !lit
    }

    // MARK: The catalog path

    /// The bar, compiled. Every chip becomes an indexed predicate in `CatalogStore`'s
    /// builder — which was 200 lines of correct, tested SQL with no caller at all while
    /// this struct filtered five criteria with a linear scan of the roll.
    ///
    /// The flag and label criteria are sorted on the way out. `Set` iteration order is
    /// unspecified, so they used to reach SQL as a differently-ordered `IN (…)` list run
    /// to run — same rows either way, but nothing a test could hold still.
    public func query(sortKey: PhotoQuery.SortKey, ascending: Bool,
                      albumID: Int64?) -> PhotoQuery {
        var query = PhotoQuery()
        query.flags = flags.sorted { $0.rawValue < $1.rawValue }
        if minRating > 0 {
            query.rating = minRating
            query.ratingComparison = .atLeast
        }
        query.labels = labels.sorted { $0.metaSlot < $1.metaSlot }
        // "Unlabelled" is its own predicate, because `label IN (…)` can never match a
        // NULL. One criterion, two predicates, OR-ed — which is what `PhotoQuery` does
        // with the pair.
        query.includeUnlabeled = includeUnlabeled
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
        query.sortKey = sortKey
        query.ascending = ascending
        return query
    }

    // MARK: The sentence

    /// The active query written out. "or" inside a criterion, and between criteria
    /// whatever the Match toggle says — the sentence IS the documentation, which is why
    /// it survived the filter bar being taken apart (docs/28 Phase 3) and moved to the
    /// status bar rather than being deleted with its container.
    ///
    /// It lives on the filter rather than in a view because two surfaces read it: the
    /// status bar shows it, and the filter popover shows the same words back inside the
    /// control that produced them. Two hand-rolled versions of a sentence that is
    /// supposed to be authoritative is exactly one too many.
    ///
    /// `catalogLive` only changes what the EMPTY sentence says: with no catalog the app
    /// filters in memory, and a bar that did not say so would be claiming a reach it
    /// does not have.
    public func sentence(catalogLive: Bool) -> String {
        guard isActive else {
            return catalogLive
                ? "No filter — showing every photo"
                : "No filter — filtering in memory, without the catalog"
        }
        var parts: [String] = []
        if !flags.isEmpty {
            parts.append(flags.sorted { $0.rawValue > $1.rawValue }
                .map(\.displayName).joined(separator: " or "))
        }
        if minRating > 0 {
            parts.append("★ \(minRating) or better")
        }
        if !labels.isEmpty || includeUnlabeled {
            // Unlabelled leads, then the colours in key order (`6`–`9`, then purple) —
            // the order the chips sit in. By `metaSlot`, NOT `rawValue`: the raw value
            // is the String name now, and sorting on it reads alphabetically.
            var names = includeUnlabeled ? ["Unlabelled"] : []
            names += labels.sorted { $0.metaSlot < $1.metaSlot }.map(\.displayName)
            parts.append(names.joined(separator: " or "))
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
}

// MARK: - Saved filters (smart albums)

/// A filter-bar state as text, for `album.query` (docs/10 §10.8: "smart albums ARE
/// saved queries — one engine, two entry points", D39).
///
/// The column has existed since the base schema with nothing writing it: `kind` was
/// always 'manual'. The bar's state is a value type with sets in it, so it gets a
/// canonical spelling here — every set sorted, keys sorted — and the same filter
/// always saves as the same bytes.
extension LibraryFilter {

    /// The format version written into every saved filter. A reader that meets a
    /// newer one refuses it rather than dropping the criteria it cannot name: a smart
    /// album that silently lost a chip would show MORE photographs than it was saved
    /// to show, under the same name.
    public static let savedFormatVersion = 1

    private struct Saved: Codable {
        var v: Int
        var flags: [Int]?
        var minRating: Int?
        var labels: [String]?
        var unlabeled: Bool?
        var text: String?
        var rawOnly: Bool?
        var edited: Bool?
        var cameras: [String]?
        var lenses: [String]?
        var iso: [String]?
        var stack: String?
        var keywords: [String]?
        var any: Bool?
    }

    /// Canonical JSON. Only lit criteria are written, so a filter saved before a
    /// criterion existed and one saved after with it off are the same document.
    public func savedJSON() -> String {
        var saved = Saved(v: Self.savedFormatVersion)
        if !flags.isEmpty { saved.flags = flags.map(\.rawValue).sorted() }
        if minRating > 0 { saved.minRating = minRating }
        if !labels.isEmpty { saved.labels = labels.map(\.rawValue).sorted() }
        if includeUnlabeled { saved.unlabeled = true }
        if !text.isEmpty { saved.text = text }
        if rawOnly { saved.rawOnly = true }
        saved.edited = edited
        if !cameras.isEmpty { saved.cameras = cameras.sorted() }
        if !lenses.isEmpty { saved.lenses = lenses.sorted() }
        if !isoBands.isEmpty {
            saved.iso = ISOBand.allCases.filter { isoBands.contains($0) }.map(\.rawValue)
        }
        if stackState != .any { saved.stack = stackState.rawValue }
        if !keywords.isEmpty { saved.keywords = keywords.sorted() }
        if matchAny { saved.any = true }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(saved),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    /// The filter a saved document describes, or nil when it cannot be read whole:
    /// malformed, from a newer format, or naming a value this build does not have.
    /// All-or-nothing for the same reason the version is checked — a partial read
    /// widens the album.
    public init?(savedJSON json: String) {
        guard let saved = try? JSONDecoder().decode(Saved.self, from: Data(json.utf8)),
              saved.v <= Self.savedFormatVersion else { return nil }
        var filter = LibraryFilter()
        for raw in saved.flags ?? [] {
            guard let flag = PhotoFlag(rawValue: raw) else { return nil }
            filter.flags.insert(flag)
        }
        filter.minRating = Swift.min(Swift.max(saved.minRating ?? 0, 0), 5)
        for raw in saved.labels ?? [] {
            guard let label = ColorLabel(rawValue: raw) else { return nil }
            filter.labels.insert(label)
        }
        filter.includeUnlabeled = saved.unlabeled ?? false
        filter.text = saved.text ?? ""
        filter.rawOnly = saved.rawOnly ?? false
        filter.edited = saved.edited
        filter.cameras = Set(saved.cameras ?? [])
        filter.lenses = Set(saved.lenses ?? [])
        for raw in saved.iso ?? [] {
            guard let band = ISOBand(rawValue: raw) else { return nil }
            filter.isoBands.insert(band)
        }
        if let raw = saved.stack {
            guard let state = StackFilter(rawValue: raw) else { return nil }
            filter.stackState = state
        }
        filter.keywords = Set(saved.keywords ?? [])
        filter.matchAny = saved.any ?? false
        self = filter
    }
}
