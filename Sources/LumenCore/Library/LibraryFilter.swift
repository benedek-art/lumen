// LibraryFilter.swift
// The library query grammar — the filter bar as a value, and the boolean rule it obeys.
//
// docs/10 §10.8 and D39, day one: **multi-value within one criterion is OR, and criteria
// AND with each other.** The bar's All/Any toggle (`matchAny`) flips the join BETWEEN
// criteria and never the join within one — lighting Pick and Reject always means "pick
// or reject", whatever the toggle says.
//
// This lived in `LumenApp/AppState.swift`, which is `#if os(macOS)`, so none of it could
// be tested: the Linux lane is where every rule in this project is pinned, and a rule
// the compiler on that lane never sees is a rule nobody checks. Nothing here needs a
// window — it is set algebra over five value types and a string — so it moved, and the
// presentation it used to be tangled with (SF Symbols, SwiftUI `Color`) stayed behind in
// a LumenApp extension.

import Foundation

// MARK: - What the memory path can ask a photo

/// The five questions `LibraryFilter.matches` puts to a photo.
///
/// A protocol rather than a moved `PhotoItem`, because `PhotoItem` is the app's roll
/// entry — it carries a catalog row id and an `iso` the filter never reads, and it is
/// perfectly at home in LumenApp. This is the part of it the grammar needs, which is
/// also exactly the part a test can build in one line.
public protocol LibraryFilterable {
    var flag: PhotoFlag { get }
    var rating: Int { get }
    /// `nil` is unlabelled — the absence of a label, not a sixth colour. See the note on
    /// `ColorLabel`.
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

    /// How many *criteria* are constraining the result — not how many chips are lit.
    ///
    /// The distinction is the whole point: Pick + Reject + Unflagged is three lit chips
    /// and **one** criterion, because they OR together into a single question about the
    /// flag. A count of chips would tell the user they had narrowed three times when
    /// they had in fact widened one criterion to match everything.
    public var activeCriteriaCount: Int {
        var n = 0
        if !flags.isEmpty { n += 1 }
        if minRating > 0 { n += 1 }
        if !labels.isEmpty || includeUnlabeled { n += 1 }
        if !text.isEmpty { n += 1 }
        if rawOnly { n += 1 }
        if edited != nil { n += 1 }
        if !cameras.isEmpty { n += 1 }
        if !lenses.isEmpty { n += 1 }
        if !isoBands.isEmpty { n += 1 }
        if stackState != .any { n += 1 }
        if !keywords.isEmpty { n += 1 }
        return n
    }

    /// Whether anything is being filtered at all. Defined in terms of the count so the
    /// two can never disagree about what "a criterion" is.
    public var isActive: Bool { activeCriteriaCount > 0 }

    // MARK: The memory path

    /// The memory path, used only when there is no catalog to ask. It answers the five
    /// criteria a roll entry can answer and is deliberately not extended past them:
    /// a filter that silently ignores a lit chip is the failure this file exists to
    /// avoid, which is why the bar hides those chips in this mode instead.
    ///
    /// Note what it does NOT read: `matchAny`. Every criterion here ANDs, whatever the
    /// toggle says, which is how this has always behaved — see
    /// `LibraryFilterTests.matchAnyIsNotHonouredByTheMemoryPath`, which pins it rather
    /// than blesses it.
    public func matches(_ photo: some LibraryFilterable) -> Bool {
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

    // MARK: The catalog path

    /// The bar, compiled. Every chip becomes an indexed predicate in `CatalogStore`'s
    /// builder — which was 200 lines of correct, tested SQL with no caller at all while
    /// this struct filtered five criteria with a linear scan of the roll.
    ///
    /// The set-valued criteria are sorted on the way out. `Set` iteration order is
    /// unspecified, so this used to hand SQL a differently-ordered `IN (…)` list run to
    /// run — same rows either way, but nothing a test could hold still. Sorting costs
    /// nothing at these sizes and makes the compiled query a value one can assert on.
    public func query(sortKey: PhotoQuery.SortKey,
                      ascending: Bool,
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

    /// The active query written out, for the status bar. "or" inside a criterion, and
    /// between criteria whatever the Match toggle says — the sentence is the
    /// documentation, and it is better product thinking than a bar of lit rectangles
    /// that leaves the user to infer the boolean.
    ///
    /// `catalogLive` is false in the sessions where the catalog would not open. The
    /// empty sentence says so, because "no filter" and "no filter, and also I am
    /// running on half the criteria" are different facts about what the grid is showing.
    public func sentence(catalogLive: Bool) -> String {
        guard isActive else {
            return catalogLive
                ? "No filter — showing every photo"
                : "No filter — filtering in memory, without the catalog"
        }
        var parts: [String] = []
        if !flags.isEmpty {
            parts.append(flags.sorted { $0.rawValue > $1.rawValue }
                .map(\.displayName)
                .joined(separator: " or "))
        }
        if minRating > 0 {
            parts.append("★ \(minRating) or better")
        }
        if !labels.isEmpty || includeUnlabeled {
            // Unlabelled leads, then the colours in key order (`6`–`9`, purple) — the
            // order the chips sit in, so the sentence reads left to right like the bar.
            var names = includeUnlabeled ? ["Unlabelled"] : []
            names += labels.sorted { $0.metaSlot < $1.metaSlot }.map(\.displayName)
            parts.append(names.joined(separator: " or "))
        }
        if rawOnly {
            parts.append("RAW only")
        }
        if let edited {
            parts.append(edited ? "edited" : "untouched")
        }
        if !cameras.isEmpty {
            parts.append(cameras.sorted().joined(separator: " or "))
        }
        if !lenses.isEmpty {
            parts.append(lenses.sorted().joined(separator: " or "))
        }
        if !isoBands.isEmpty {
            parts.append(ISOBand.allCases
                .filter { isoBands.contains($0) }
                .map { "ISO " + $0.rawValue }
                .joined(separator: " or "))
        }
        if !keywords.isEmpty {
            parts.append(keywords.sorted().joined(separator: " or "))
        }
        if stackState != .any {
            parts.append(stackState.rawValue.lowercased())
        }
        if !text.isEmpty {
            parts.append("matching \"\(text)\"")
        }
        return parts.joined(separator: matchAny ? "  or  " : "  and  ")
    }
}
