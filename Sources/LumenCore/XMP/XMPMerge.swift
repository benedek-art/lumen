// XMPMerge.swift
// Updating an existing XMP sidecar in place, touching ONLY the fields Lumen owns.
//
// Why this exists, stated plainly because it was a data-loss bug and not a nicety:
// `XMPSidecar.serialize` builds a complete document out of an eight-field struct, and
// the writer wrote it with `.atomic` — a whole-file replace. So the first time a user
// pressed `P` or a rating key on a photo that had ever been through Lightroom, Bridge,
// Camera Raw, Capture One or exiftool, that photo's `.xmp` was replaced by a document
// containing Lumen's eight fields and nothing else. Every `crs:` develop setting, every
// keyword in `dc:subject`, the star rating, the colour label and the capture date were
// gone from disk, with no backup and no undo — on a file Lumen had not even rendered.
//
// The rule this file implements: Lumen owns `xmp:Rating`, `xmp:Label` and the whole
// `lumen:` namespace. Every other byte of an existing sidecar is somebody else's work
// and survives untouched. XMP carries simple properties in two interchangeable forms —
// as attributes on `rdf:Description` (what Adobe writes) and as child elements (what
// Lumen writes) — so both have to be found and replaced, or the document ends up
// asserting a rating twice and readers disagree about which one is real.
//
// When the document cannot be edited safely, `merge` returns nil and the CALLER MUST
// NOT WRITE. Declining to record a rating in the sidecar costs the user a rating that
// is still in the catalog; overwriting costs them their edits. Those are not close.

import Foundation

public enum XMPMerge {

    /// The properties Lumen writes, and therefore the only ones it may remove.
    static func owns(_ name: String) -> Bool {
        if name == "xmp:Rating" || name == "xmp:Label" { return true }
        return name.hasPrefix("lumen:")
    }

    /// Splice `fields` (serialized child elements, one per line, already escaped) into
    /// `original`, replacing whatever Lumen previously wrote there.
    ///
    /// Returns nil when `original` has no `rdf:Description` to edit or is malformed
    /// enough that the tag scan runs off the end — the signal to leave the file alone.
    public static func merge(into original: String, fields: String,
                             lumenNamespace: String) -> String? {
        var chars = Array(original)
        guard indexOfDescription(chars, from: 0) != nil else { return nil }
        guard let stripped = stripOwnedAttributes(chars) else { return nil }
        chars = stripped
        guard let cleaned = stripOwnedElements(chars) else { return nil }
        chars = cleaned
        guard let namespaced = ensureNamespaces(chars, lumenNamespace: lumenNamespace) else {
            return nil
        }
        chars = namespaced

        guard let open = indexOfDescription(chars, from: 0),
              let end = tagEnd(chars, from: open) else { return nil }

        let body = fields.hasSuffix("\n") ? String(fields.dropLast()) : fields
        if isSelfClosing(chars, open: open, end: end) {
            // `<rdf:Description …/>` has to become a container before children fit.
            var opened = String(chars[open..<(end - 2)])
            while opened.hasSuffix(" ") || opened.hasSuffix("\n") {
                opened = String(opened.dropLast())
            }
            return String(chars[0..<open]) + opened + ">\n" + body
                + "\n  </rdf:Description>" + String(chars[end...])
        }
        return String(chars[0..<end]) + "\n" + body + String(chars[end...])
    }

    // MARK: - Tag scanning

    /// Index just past the `>` that closes the tag opening at `start`, honouring
    /// quoted attribute values — which legally contain `>` and do in real sidecars
    /// (`aux:Lens="EF 35mm f/1.4L II USM"` is tame; XMP from video tools is not).
    static func tagEnd(_ c: [Character], from start: Int) -> Int? {
        var i = start
        while i < c.count {
            let ch = c[i]
            if ch == "\"" || ch == "'" {
                let quote = ch
                i += 1
                while i < c.count && c[i] != quote { i += 1 }
                if i >= c.count { return nil }
            } else if ch == ">" {
                return i + 1
            }
            i += 1
        }
        return nil
    }

    static func indexOfDescription(_ c: [Character], from: Int) -> Int? {
        let needle = Array("<rdf:Description")
        guard c.count >= needle.count else { return nil }
        var i = from
        while i + needle.count <= c.count {
            if c[i] == "<" && Array(c[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }

    /// `/` and `>` must be adjacent in XML, so this is exact rather than a scan — and
    /// it has to stay exact, because `stripOwnedAttributes` slices the attribute span
    /// as `end - 2` on the strength of it.
    static func isSelfClosing(_ c: [Character], open: Int, end: Int) -> Bool {
        end - 2 > open && c[end - 1] == ">" && c[end - 2] == "/"
    }

    static func isNameCharacter(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber || ch == "_" || ch == "-" || ch == "." || ch == ":"
    }

    /// The element name of the tag opening at `i`, or nil if `i` is not a tag open.
    static func elementName(_ c: [Character], at i: Int) -> String? {
        guard i < c.count, c[i] == "<", i + 1 < c.count else { return nil }
        var j = i + 1
        var name = ""
        while j < c.count && isNameCharacter(c[j]) {
            name.append(c[j])
            j += 1
        }
        return name.isEmpty ? nil : name
    }

    // MARK: - Attribute form

    /// `(elementName, [(key, rawValueIncludingQuotes)])`. Values keep their original
    /// quoting so a rebuilt tag is byte-identical for everything left in place.
    static func splitAttributes(_ inner: [Character]) -> (String, [(String, String?)]) {
        var i = 0
        var name = ""
        while i < inner.count && !inner[i].isWhitespace {
            name.append(inner[i])
            i += 1
        }
        var attrs: [(String, String?)] = []
        while i < inner.count {
            while i < inner.count && inner[i].isWhitespace { i += 1 }
            if i >= inner.count { break }
            var key = ""
            while i < inner.count && inner[i] != "=" && !inner[i].isWhitespace {
                key.append(inner[i])
                i += 1
            }
            while i < inner.count && inner[i].isWhitespace { i += 1 }
            if i < inner.count, inner[i] == "=" {
                i += 1
                while i < inner.count && inner[i].isWhitespace { i += 1 }
                if i < inner.count, inner[i] == "\"" || inner[i] == "'" {
                    let quote = inner[i]
                    var value = String(quote)
                    i += 1
                    while i < inner.count && inner[i] != quote {
                        value.append(inner[i])
                        i += 1
                    }
                    if i < inner.count { i += 1 }
                    value.append(quote)
                    attrs.append((key, value))
                    continue
                }
            }
            if !key.isEmpty { attrs.append((key, nil)) }
        }
        return (name, attrs)
    }

    static func rebuild(name: String, attrs: [(String, String?)],
                        selfClosing: Bool) -> String {
        var out = "<" + name
        for (key, value) in attrs {
            if let value {
                out += "\n    " + key + "=" + value
            } else {
                out += " " + key
            }
        }
        out += selfClosing ? "/>" : ">"
        return out
    }

    /// Drop Lumen-owned attributes from EVERY `rdf:Description` open tag. Adobe splits
    /// a sidecar into several Description blocks by namespace, so the rating Lumen is
    /// replacing is not necessarily in the first one.
    static func stripOwnedAttributes(_ c: [Character]) -> [Character]? {
        var out = ""
        var i = 0
        while true {
            guard let open = indexOfDescription(c, from: i) else {
                out += String(c[i...])
                break
            }
            guard let end = tagEnd(c, from: open) else { return nil }
            let selfClosing = isSelfClosing(c, open: open, end: end)
            let innerEnd = selfClosing ? end - 2 : end - 1
            guard innerEnd > open + 1 else { return nil }
            let (name, attrs) = splitAttributes(Array(c[(open + 1)..<innerEnd]))
            let kept = attrs.filter { !owns($0.0) }
            out += String(c[i..<open])
            if kept.count == attrs.count {
                out += String(c[open..<end])
            } else {
                out += rebuild(name: name, attrs: kept, selfClosing: selfClosing)
            }
            i = end
        }
        return Array(out)
    }

    // MARK: - Element form

    /// Remove Lumen-owned child elements document-wide, along with whatever value
    /// structure they carry (`rdf:Alt`, `rdf:Bag`, nested `rdf:li`).
    static func stripOwnedElements(_ input: [Character]) -> [Character]? {
        var c = input
        var guardCount = 0
        while true {
            guardCount += 1
            // Every iteration deletes at least one element, so this can only spin as
            // many times as there are tags; the bound is a backstop, not a policy.
            if guardCount > 100_000 { return nil }

            var found: (Int, String)? = nil
            var i = 0
            while i < c.count {
                if c[i] == "<", let name = elementName(c, at: i), owns(name) {
                    found = (i, name)
                    break
                }
                i += 1
            }
            guard let (open, name) = found else { return c }
            guard let end = tagEnd(c, from: open) else { return nil }

            var stop = end
            if !isSelfClosing(c, open: open, end: end) {
                guard let close = indexOfClose(c, name: name, from: end),
                      let past = tagEnd(c, from: close) else { return nil }
                stop = past
            }
            // Take the line's indentation and trailing newline with it, so removing a
            // property does not leave a blank line where it used to be.
            var lead = open
            var k = open - 1
            var onlyBlanks = true
            while k >= 0 && c[k] != "\n" {
                if !c[k].isWhitespace { onlyBlanks = false; break }
                k -= 1
            }
            if onlyBlanks && k >= 0 { lead = k + 1 }
            var trail = stop
            while trail < c.count && (c[trail] == " " || c[trail] == "\t") { trail += 1 }
            if trail < c.count && c[trail] == "\n" { trail += 1 }

            c = Array(c[0..<lead]) + Array(c[trail...])
        }
    }

    static func indexOfClose(_ c: [Character], name: String, from: Int) -> Int? {
        let needle = Array("</" + name)
        guard c.count >= needle.count else { return nil }
        var i = from
        while i + needle.count <= c.count {
            if c[i] == "<" && Array(c[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }

    // MARK: - Namespaces

    /// A foreign sidecar may never have declared `xmp:` or `lumen:`. Writing a prefixed
    /// element with no binding produces a document no parser will read back — including
    /// Lumen's own, on the next launch.
    static func ensureNamespaces(_ c: [Character], lumenNamespace: String) -> [Character]? {
        guard let open = indexOfDescription(c, from: 0),
              let end = tagEnd(c, from: open) else { return nil }
        let selfClosing = isSelfClosing(c, open: open, end: end)
        let innerEnd = selfClosing ? end - 2 : end - 1
        guard innerEnd > open + 1 else { return nil }
        let (name, original) = splitAttributes(Array(c[(open + 1)..<innerEnd]))
        let have = Set(original.map { $0.0 })
        var attrs = original
        if !have.contains("xmlns:xmp") {
            attrs.append(("xmlns:xmp", "\"http://ns.adobe.com/xap/1.0/\""))
        }
        if !have.contains("xmlns:lumen") {
            attrs.append(("xmlns:lumen", "\"" + lumenNamespace + "\""))
        }
        // Against `original`, not against `have` — a document with a duplicated
        // attribute would make the Set smaller than the list and rewrite every time.
        if attrs.count == original.count { return c }
        let rebuilt = rebuild(name: name, attrs: attrs, selfClosing: selfClosing)
        return Array(String(c[0..<open]) + rebuilt + String(c[end...]))
    }
}
