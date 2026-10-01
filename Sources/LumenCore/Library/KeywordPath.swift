// KeywordPath.swift
// How a keyword hierarchy is typed and shown: "Places > Iceland > Reykjavik".
//
// docs/15 §15.3 gives `keyword` a `parent_id` and nothing ever set it, so the
// hierarchy Lightroom users organise thousands of keywords into had nowhere to land.
// The spelling is Lightroom's own keyword-entry form, written left to right from the
// root, because that is the form a photographer migrating a vocabulary already types.

import Foundation

public enum KeywordPath {

    /// The separator, as typed and as shown.
    public static let separator = ">"

    /// The components of a typed keyword, root first. Whitespace around each one is
    /// dropped; an empty component (`"A >> B"`, a trailing `>`) makes the whole entry
    /// one literal keyword rather than a guessed hierarchy, so a name that merely
    /// contains the character is never split into nonsense. An entry that is blank
    /// once trimmed is no keyword at all.
    public static func parse(_ typed: String) -> [String] {
        let whole = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !whole.isEmpty else { return [] }
        let parts = whole.components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if parts.count > 1, !parts.contains(where: \.isEmpty) { return parts }
        return [whole]
    }

    /// The display form of a path: "Places > Iceland".
    public static func display(_ components: [String]) -> String {
        components.joined(separator: " \(separator) ")
    }

    /// The keyword itself, without its ancestors — what a sidecar's flat
    /// `dc:subject` carries for a hierarchical keyword.
    public static func leaf(_ typed: String) -> String {
        parse(typed).last ?? ""
    }
}
