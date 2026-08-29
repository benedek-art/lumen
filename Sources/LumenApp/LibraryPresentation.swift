// LibraryPresentation.swift
// How LumenCore's library vocabulary looks on screen.
//
// The grammar — `LibraryFilter`, `PhotoFlag`, `ColorLabel`, `ISOBand`, `StackFilter` —
// lives in LumenCore, where it compiles and is tested on Linux. What is left over is
// genuinely presentation: an SF Symbol name, a SwiftUI `Color`, and the app's own
// `SortOrder` menu. None of it can go the other way, because LumenCore has no SwiftUI
// and gains nothing from knowing what a flag looks like.

#if os(macOS)

import LumenCore
import SwiftUI

// MARK: - Flags

extension PhotoFlag {
    var symbolName: String {
        switch self {
        case .pick: return "flag.fill"
        case .reject: return "xmark"
        case .unflagged: return "flag"
        }
    }
}

// MARK: - Colour labels

extension ColorLabel {
    /// The swatch. Deliberately not in LumenCore: `Color` is SwiftUI, and the catalog
    /// has no opinion about what red looks like — only that the key is `"red"`.
    var color: Color {
        switch self {
        case .red: return Color(red: 0.85, green: 0.25, blue: 0.25)
        case .yellow: return Color(red: 0.90, green: 0.75, blue: 0.20)
        case .green: return Color(red: 0.30, green: 0.70, blue: 0.35)
        case .blue: return Color(red: 0.25, green: 0.50, blue: 0.85)
        case .purple: return Color(red: 0.60, green: 0.35, blue: 0.80)
        }
    }
}

// MARK: - The roll entry, as the filter sees it

extension PhotoItem: LibraryFilterable {}

// MARK: - Sorting

extension LibraryFilter {
    /// The app's menu picks a `SortOrder`; the query wants a `PhotoQuery.SortKey`.
    /// `SortOrder` stays here because it is a menu — it carries the twelve titles the
    /// user reads and `worksFromMemory`, which is a statement about this app's fallback
    /// path, not about the catalog.
    func query(sort: SortOrder, ascending: Bool, albumID: Int64?) -> PhotoQuery {
        query(sortKey: sort.sortKey, ascending: ascending, albumID: albumID)
    }
}

#endif
