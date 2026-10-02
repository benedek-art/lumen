// LibraryQueryPacing.swift
// When a change to the filter re-asks the catalog: now, or after the typing stops.
//
// The grid query runs on the catalog's serial queue — the same queue that hands the
// grid its thumbnails — and the search field wrote straight into `LibraryFilter.text`,
// so every keystroke of a word re-ran the whole roll's query: "portrait" was eight
// statements, seven of them answers to a question nobody asked, each one queued in
// front of the thumbnails for the folder being searched. At the library sizes this
// app is for, that is the search field stalling the contact sheet while it is typed.
//
// The answer is NOT a LIMIT on the query. `AppState.libraryOrder` IS the roll — the
// grid, the filmstrip, the cursor, auto-advance and every cull verb read it — so a
// window over it would be a roll with photographs missing from it, which is the
// worst failure this app has. What is wasted is the number of queries, not their size.
//
// So the rule is about WHICH change it is:
//   · a chip — a flag, a star, a label, a camera — is one deliberate click and is
//     answered at once, exactly as before;
//   · a keystroke in the search text waits `textDebounce` for the next one, and a
//     newer keystroke supersedes it, so a typed word is one query;
//   · clearing the text is one deliberate act too (the field's ✕, or the last
//     backspace), and is answered at once — the whole roll coming back is not a burst.
//
// Pure, so the rule is pinned on the Linux lane; `AppState.filterOrSortChanged` is the
// one caller and `LibraryQueryPacingTests` also holds that it asks.

import Foundation

public enum LibraryQueryPacing {

    /// How long a keystroke waits for the next one. The scopes' refresh debounce
    /// (`AppState.scopeDebounce`, 180 ms) is the same kind of wait in the same app and
    /// this matches it: long enough to cover a typist's inter-key gap, short enough
    /// that the grid answers before the hand has left the keyboard.
    public static let textDebounce: Duration = .milliseconds(180)

    /// nil means run the query now; a duration means run it once that long has passed
    /// with no newer change.
    public static func delay(from old: LibraryFilter, to new: LibraryFilter) -> Duration? {
        guard old != new else { return nil }
        var oldWithoutText = old
        oldWithoutText.text = ""
        var newWithoutText = new
        newWithoutText.text = ""
        // Anything besides the text moved: a click, answered at once.
        guard oldWithoutText == newWithoutText else { return nil }
        // Only the text moved. Emptying it is a single act, not a burst.
        guard !new.text.isEmpty else { return nil }
        return textDebounce
    }
}
