// The one comment stripper for source-scanning tests. This file is duplicated
// byte-for-byte as Tests/LumenAppTests/CommentBlanking.swift, because test targets
// cannot share a source file without a new package target; `CommentBlankingTests`
// (LumenCoreTests, so it runs on Linux) fails if the two copies ever differ.
//
// Why it exists. Twenty-one test files carried their own copy of a stripper that
// walked `//` and `/*` with no idea of string literals, so `URL(string: "https://…")`
// read as a comment: the rest of that line was deleted, the closing quote with it, and
// an assertion for an ABSENT word could not see the code it was meant to guard
// (docs/audit-2026-09/STATUS.md). This one walks code, comments and literals in ONE
// pass — a pass for either alone is wrong in the presence of the other, since a `"` in
// a comment desyncs strings just as a `//` in a string desyncs comments.
//
// What it does:
//   · every comment character becomes a SPACE, newlines kept, so the result has the
//     same Character count and the same lines as the input — an offset or a line
//     number taken on the stripped text is valid on the raw file;
//   · block comments nest, as Swift's do;
//   · "…", """…""" and raw #"…"# literals are copied through whole, including a `\(…)`
//     interpolation, which is code again (and may hold literals or comments of its own).
// What it does not handle: bare `/…/` regex literals. Nothing in `Sources/` uses one.
func blankingComments(in source: String) -> String {
    var chars = Array(source)
    let n = chars.count

    func blank(_ from: Int, _ to: Int) {
        for k in from..<min(to, n) where !chars[k].isNewline { chars[k] = " " }
    }
    func at(_ i: Int, _ text: String) -> Bool {
        var k = i
        for c in text {
            guard k < n, chars[k] == c else { return false }
            k += 1
        }
        return true
    }
    func hashes(from i: Int) -> Int {
        var k = i
        while k < n, chars[k] == "#" { k += 1 }
        return k - i
    }

    /// Code from `i`. With `closing`, stops AT the `)` that closes an interpolation.
    func code(_ start: Int, closing: Bool) -> Int {
        var i = start
        var parens = 0
        while i < n {
            let c = chars[i]
            if at(i, "//") {
                var j = i
                while j < n, !chars[j].isNewline { j += 1 }
                blank(i, j)
                i = j
            } else if at(i, "/*") {
                var j = i + 2
                var depth = 1
                while j < n, depth > 0 {
                    if at(j, "/*") { depth += 1; j += 2 }
                    else if at(j, "*/") { depth -= 1; j += 2 }
                    else { j += 1 }
                }
                blank(i, j)
                i = j
            } else if c == "\"" || (c == "#" && i + hashes(from: i) < n
                                    && chars[i + hashes(from: i)] == "\"") {
                i = literal(i)
            } else if c == "(" {
                parens += 1
                i += 1
            } else if c == ")" {
                if closing && parens == 0 { return i }
                parens -= 1
                i += 1
            } else {
                i += 1
            }
        }
        return n
    }

    /// A literal opening at `start` (its `#`s or its first quote); returns the index
    /// just past its closing delimiter.
    func literal(_ start: Int) -> Int {
        let h = hashes(from: start)
        var i = start + h
        let multi = at(i, "\"\"\"")
        i += multi ? 3 : 1
        let close = (multi ? "\"\"\"" : "\"") + String(repeating: "#", count: h)
        let escape = "\\" + String(repeating: "#", count: h)
        while i < n {
            if at(i, close) { return i + close.count }
            if !multi && chars[i].isNewline { return i }   // unterminated: stop at the line
            if at(i, escape) {
                i += escape.count
                if i < n, chars[i] == "(" {
                    i = code(i + 1, closing: true) + 1
                } else {
                    i += 1
                }
                continue
            }
            i += 1
        }
        return n
    }

    _ = code(0, closing: false)
    return String(chars)
}
