// DevelopPresetLibrary.swift
// The photographer's develop presets: the list, its edits, and the file it lives in.
//
// One library per Mac, not per catalog — a Lightroom preset follows the photographer
// from shoot to shoot, and a "Soccer ISO 6400" that vanished when another folder's
// catalog opened would be a preset nobody trusts. So it is a JSON file
// (`DevelopPreset.libraryData`) beside the catalogs in Application Support, not rows in
// a catalog's `look` table, which also keeps that table's look-only partition intact.
//
// Names are unique case-insensitively. Save over a taken name replaces (the save sheet
// says "Replace" first, as Saved Looks do); rename onto one is refused; import never
// replaces — a clash with different settings arrives as "Name 2".

import Foundation

public struct DevelopPresetLibrary: Equatable, Sendable {

    /// Sorted by name, case-insensitively.
    public private(set) var presets: [DevelopPreset]

    public init(_ presets: [DevelopPreset] = []) {
        self.presets = []
        for preset in presets { save(preset) }
    }

    public enum EditError: Error, Equatable, Sendable {
        case notFound
        case nameTaken(String)
        case invalidName
    }

    public func preset(named name: String) -> DevelopPreset? {
        presets.first { $0.hasName(name) }
    }

    /// Adds or replaces by name. Returns true when it replaced.
    @discardableResult
    public mutating func save(_ preset: DevelopPreset) -> Bool {
        let replaced = presets.contains { $0.hasName(preset.name) }
        presets.removeAll { $0.hasName(preset.name) }
        presets.append(preset)
        sort()
        return replaced
    }

    public mutating func renamePreset(_ name: String, to newName: String) throws {
        guard let clean = LookSubset.normalizedName(newName) else {
            throw EditError.invalidName
        }
        guard let index = presets.firstIndex(where: { $0.hasName(name) }) else {
            throw EditError.notFound
        }
        // A change of case alone is a rename of the same preset, not a clash.
        if presets.enumerated().contains(where: { $0.offset != index && $0.element.hasName(clean) }) {
            throw EditError.nameTaken(clean)
        }
        presets[index].name = clean
        sort()
    }

    @discardableResult
    public mutating func delete(named name: String) -> Bool {
        let before = presets.count
        presets.removeAll { $0.hasName(name) }
        return presets.count != before
    }

    /// What an import did, by name, for the status bar.
    public struct ImportResult: Equatable, Sendable {
        /// Names as stored — a clash's renamed name, not the file's.
        public var added: [String] = []
        /// Already here under the same name with the same groups and settings.
        public var unchanged: [String] = []
    }

    /// Adds `incoming` without replacing anything: an identical preset is skipped, a
    /// different one under a taken name is stored as "Name 2", "Name 3", ….
    public mutating func importing(_ incoming: [DevelopPreset]) -> ImportResult {
        var result = ImportResult()
        for var preset in incoming {
            if let existing = identicalCopy(of: preset) {
                result.unchanged.append(existing.name)
                continue
            }
            preset.name = freeName(for: preset.name)
            save(preset)
            result.added.append(preset.name)
        }
        return result
    }

    /// A stored preset with the same groups and settings under `preset`'s name or a
    /// clash name made from it ("Name 2"), so importing one file twice adds nothing.
    private func identicalCopy(of preset: DevelopPreset) -> DevelopPreset? {
        let base = preset.name.lowercased()
        return presets.first { existing in
            guard existing.groups == preset.groups,
                  existing.settings == preset.settings else { return false }
            let name = existing.name.lowercased()
            if name == base { return true }
            guard name.hasPrefix(base + " ") else { return false }
            let suffix = name.dropFirst(base.count + 1)
            return !suffix.isEmpty && suffix.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }

    /// `name`, or the first "name N" (N from 2) no preset has.
    public func freeName(for name: String) -> String {
        let base = LookSubset.normalizedName(name) ?? name
        guard preset(named: base) != nil else { return base }
        var n = 2
        while preset(named: "\(base) \(n)") != nil { n += 1 }
        return "\(base) \(n)"
    }

    /// The presets `query` names, for the ⌘K palette: prefix, word-prefix or substring
    /// of the name, as the palette's command lane matches. An empty query names none —
    /// the palette's empty state is the controls, not a preset list.
    public func matching(_ query: String) -> [DevelopPreset] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        // The lane's own word ("pres", "preset", "presets") lists every preset, and
        // "preset soccer" looks for Soccer. Three letters at least, so "p" stays a
        // search rather than a flood.
        var words = needle.split(separator: " ").map(String.init)
        if let first = words.first, first.count >= 3, "presets".hasPrefix(first) {
            words.removeFirst()
            if words.isEmpty { return presets }
        }
        let terms = words.joined(separator: " ")
        return presets.filter { preset in
            let hay = preset.name.lowercased()
            return hay.hasPrefix(terms)
                || hay.split(separator: " ").contains { $0.hasPrefix(terms) }
                || hay.contains(terms)
        }
    }

    private mutating func sort() {
        presets.sort { lhs, rhs in
            let l = lhs.name.lowercased(), r = rhs.name.lowercased()
            return l != r ? l < r : lhs.name < rhs.name
        }
    }
}

/// The library's file. Plain file I/O so the round trip is tested on Linux.
public struct DevelopPresetStore: Sendable {

    public let url: URL

    public init(url: URL) { self.url = url }

    /// `<directory>/DevelopPresets.json`.
    public init(directory: URL) {
        self.url = directory.appendingPathComponent("DevelopPresets.json")
    }

    /// An absent file is an empty library; an unreadable one throws, and the caller
    /// sets it aside (`setAsideUnreadable`) before anything is written over it.
    public func load() throws -> DevelopPresetLibrary {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return DevelopPresetLibrary()
        }
        let data = try Data(contentsOf: url)
        return DevelopPresetLibrary(try DevelopPreset.presets(fromFileData: data))
    }

    /// Atomic, so a crash mid-write leaves the previous library rather than half of one.
    public func save(_ library: DevelopPresetLibrary) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DevelopPreset.libraryData(library.presets).write(to: url, options: .atomic)
    }

    /// Moves an unreadable library to `DevelopPresets.json.unreadable` (then `-2`, …) so
    /// the next save cannot destroy it. Returns where it went, or nil if it could not move.
    @discardableResult
    public func setAsideUnreadable() -> URL? {
        var n = 1
        var target = url.appendingPathExtension("unreadable")
        while FileManager.default.fileExists(atPath: target.path) {
            n += 1
            target = url.appendingPathExtension("unreadable-\(n)")
        }
        do {
            try FileManager.default.moveItem(at: url, to: target)
            return target
        } catch {
            return nil
        }
    }
}
