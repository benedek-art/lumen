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

    /// The file at `path` (package-relative) with every comment removed.
    static func code(_ path: String) throws -> String {
        let text = try String(contentsOf: ShellSource.packageRoot.appendingPathComponent(path),
                              encoding: .utf8)
        return stripComments(text)
    }

    /// The brace-balanced body that follows the first `{` after `marker`, or nil when the
    /// marker is absent. `occurrence` picks a later match of the marker.
    static func body(after marker: String, in code: String, occurrence: Int = 0) -> String? {
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
              let open = code[start.upperBound...].firstIndex(of: openBrace) else { return nil }
        var depth = 0
        var index = open
        while index < code.endIndex {
            let c = code[index]
            if c == openBrace { depth += 1 }
            if c == closeBrace {
                depth -= 1
                if depth == 0 { return String(code[open...index]) }
            }
            index = code.index(after: index)
        }
        return nil
    }

    /// Whitespace-collapsed, so a pin does not depend on line wrapping.
    static func squashed(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .joined(separator: " ")
    }

    // Quotes, backslashes, braces and comment markers by value rather than as literals,
    // so a scanner that does not parse strings (check-swift-surface.py is one) reads this
    // file with its braces balanced and no comment opened inside a string.
    private static let quote = Character("\u{22}")
    private static let backslash = Character("\u{5C}")
    private static let blockOpen = "/" + "*"
    private static let blockClose = "*" + "/"
    private static let lineComment = "/" + "/"
    private static let openBrace = Character("\u{7B}")
    private static let closeBrace = Character("\u{7D}")

    private static func stripComments(_ source: String) -> String {
        var out = ""
        var index = source.startIndex
        var inBlock = false
        var inString = false
        while index < source.endIndex {
            let rest = source[index...]
            if inBlock {
                if rest.hasPrefix(blockClose) { inBlock = false; index = source.index(index, offsetBy: 2) }
                else { index = source.index(after: index) }
                continue
            }
            if inString {
                out.append(source[index])
                if source[index] == backslash {
                    index = source.index(after: index)
                    if index < source.endIndex { out.append(source[index]) }
                } else if source[index] == quote || source[index] == "\n" {
                    inString = false
                }
                if index < source.endIndex { index = source.index(after: index) }
                continue
            }
            if rest.hasPrefix(blockOpen) { inBlock = true; index = source.index(index, offsetBy: 2); continue }
            if rest.hasPrefix(lineComment) {
                while index < source.endIndex, source[index] != "\n" { index = source.index(after: index) }
                continue
            }
            if source[index] == quote { inString = true }
            out.append(source[index])
            index = source.index(after: index)
        }
        return out
    }
}
