// Source pins for the app shell (LumenApp), which no Linux compiler ever sees.
//
// `LumenApp` is `#if os(macOS)` throughout, so the only check on it that runs on every
// push is text. These helpers keep that text honest: comments are stripped before
// anything is matched (a pin that matches a comment proves only that somebody wrote the
// word down), and a pin can be scoped to ONE body — the closure after a marker — so a
// guard written somewhere else in a 3,000-line file cannot satisfy it.
import Foundation
import XCTest

enum ShellSource {

    static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // LumenCoreTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // <package>
    }

    /// The file at `path` (package-relative) with every comment blanked by the shared
    /// `blankingComments(in:)`: same length and lines as the file, comments as spaces.
    static func code(_ path: String) throws -> String {
        let text = try String(contentsOf: ShellSource.packageRoot.appendingPathComponent(path),
                              encoding: .utf8)
        return blankingComments(in: text)
    }

    /// The brace-balanced body that follows the first `{` after `marker`, or nil when the
    /// marker is absent. `occurrence` picks a later match of the marker.
    static func body(after marker: String, in code: String, occurrence: Int = 0) -> String? {
        balanced(after: marker, in: code, occurrence: occurrence, open: openBrace, close: closeBrace)
    }

    /// The parenthesis-balanced argument list that follows the first `(` after `marker`
    /// (both parentheses included), or nil when the marker is absent. Run it on code
    /// that is already comment-blanked.
    static func call(after marker: String, in code: String, occurrence: Int = 0) -> String? {
        balanced(after: marker, in: code, occurrence: occurrence, open: openParen, close: closeParen)
    }

    /// Whitespace-collapsed, so a pin does not depend on line wrapping.
    static func squashed(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .joined(separator: " ")
    }

    // Braces and parentheses by value rather than as literals, so a scanner that does
    // not parse strings (check-swift-surface.py is one) reads this file balanced.
    private static let openBrace = Character("\u{7B}")
    private static let closeBrace = Character("\u{7D}")
    private static let openParen = Character("\u{28}")
    private static let closeParen = Character("\u{29}")

    private static func balanced(after marker: String, in code: String, occurrence: Int,
                                 open: Character, close: Character) -> String? {
        var searchFrom = code.startIndex
        var found: Range<String.Index>? = nil
        for _ in 0...occurrence {
            guard let r = code.range(of: marker, range: searchFrom..<code.endIndex) else {
                return nil
            }
            found = r
            searchFrom = r.upperBound
        }
        guard let start = found,
              let first = code[start.upperBound...].firstIndex(of: open) else { return nil }
        var depth = 0
        var index = first
        while index < code.endIndex {
            let c = code[index]
            if c == open { depth += 1 }
            if c == close {
                depth -= 1
                if depth == 0 { return String(code[first...index]) }
            }
            index = code.index(after: index)
        }
        return nil
    }
}
