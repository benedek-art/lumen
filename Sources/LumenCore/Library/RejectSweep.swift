// RejectSweep.swift
// Which files leave the folder when the rejects are swept out, and what they are called
// when they land.
//
// docs/10's "Delete rejects — ⌘⌫ — moves files to a _Rejected subfolder". Nothing is
// ever deleted: a reject goes into `_Rejected` beside its original, or to the Trash,
// and either way Finder can put it back. The folder scan skips `_Rejected`, which is
// what makes the sweep stick — the scan is recursive, and without the skip every frame
// moved there would be registered again on the next open.
//
// Three rules here are about somebody's work, which is why they are in LumenCore, pure
// and Linux-tested, rather than in the app's `#if os(macOS)` executor:
//
//   1. A SIDECAR TRAVELS WITH ITS PHOTOGRAPH. `NAME.EXT.xmp` (and the other tools'
//      qualified files) is that frame's alone. A bare `NAME.xmp` goes with the frame
//      that owns it: the RAW its `sourceExtension` names, or, unowned, the RAW by
//      Adobe's convention (`SidecarNaming` never gives a JPEG the bare name). It stays
//      only when a photograph that stays may own it — a kept RAW twin, say a NEF+DNG
//      pair where just one was rejected.
//   2. A GROUP MOVES TOGETHER. Every swept file with one basename in one directory —
//      the RAW, its JPEG twin, their sidecars — gets one destination stem, so a
//      collision rename cannot split a sidecar from its photograph.
//   3. NOTHING IS OVERWRITTEN. A name already taken in `_Rejected` (case-insensitively,
//      as APFS compares by default) gets `-1`, `-2`, … on the whole group.

import Foundation

public enum RejectSweep {

    /// The subfolder rejects are moved into, beside each original.
    public static let folderName = "_Rejected"

    /// Sidecar extensions matched as `NAME.EXT.<ext>`: Adobe's non-RAW and collision
    /// form, darktable's, RawTherapee's, DxO's and ON1's.
    public static let qualifiedSidecarExtensions = ["xmp", "pp3", "dop", "on1"]

    /// Sidecar extensions matched as `NAME.<ext>` — the Adobe RAW convention.
    public static let bareSidecarExtensions = ["xmp"]

    /// True for a directory name the folder scan must not descend into.
    public static func isSweepFolderName(_ name: String) -> Bool {
        name.lowercased() == folderName.lowercased()
    }

    /// True when any directory above `url` is a `_Rejected` folder.
    public static func isInsideSweepFolder(_ url: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent().pathComponents
            .contains { isSweepFolderName($0) }
    }

    /// Where the swept files go.
    public enum Disposition: String, Sendable {
        /// `<photo's folder>/_Rejected/`.
        case rejectedFolder
        /// The macOS Trash, through `FileManager.trashItem`; it picks the names.
        case trash
    }

    /// One photograph the sweep may consider.
    public struct SweepCandidate: Equatable, Sendable {
        public var url: URL
        public var photoID: Int64?
        public var isRejected: Bool
        /// True while the catalog still owes this frame a sidecar write (a write that
        /// failed and waits for its retry). Moving it would leave its latest flag and
        /// edits nowhere once the catalog row goes, so it is skipped.
        public var sidecarOwed: Bool

        public init(url: URL, photoID: Int64?, isRejected: Bool, sidecarOwed: Bool = false) {
            self.url = url
            self.photoID = photoID
            self.isRejected = isRejected
            self.sidecarOwed = sidecarOwed
        }
    }

    public struct FileMove: Equatable, Sendable {
        public var source: URL
        /// Nil for the Trash, which names the file itself.
        public var destination: URL?
        public var isSidecar: Bool
    }

    /// Files that move or stay together: one basename in one directory.
    public struct Group: Equatable, Sendable {
        public var photos: [SweepCandidate]
        /// Originals first, then sidecars, so an executor can stop before any sidecar
        /// leaves without its photograph.
        public var moves: [FileMove]
        public var renamed: Bool
    }

    public struct Skip: Equatable, Sendable {
        public var url: URL
        public var reason: String
    }

    public struct Plan: Equatable, Sendable {
        public var disposition: Disposition
        public var groups: [Group] = []
        public var skipped: [Skip] = []
        /// Bare sidecars left in place because a photograph that stays shares them.
        public var keptSidecars: [URL] = []

        public init(disposition: Disposition) {
            self.disposition = disposition
        }

        public var photoCount: Int { groups.reduce(0) { $0 + $1.photos.count } }
        public var sidecarCount: Int {
            groups.reduce(0) { $0 + $1.moves.filter(\.isSidecar).count }
        }
        public var renamedCount: Int { groups.filter(\.renamed).count }
        public var photoIDs: [Int64] { groups.flatMap { $0.photos.compactMap(\.photoID) } }
        public var isEmpty: Bool { groups.isEmpty }
    }

    /// The plan for sweeping the rejected candidates.
    ///
    /// - Parameters:
    ///   - listing: the file names in a directory, or `[]` when it does not exist.
    ///     Asked for each source directory (sidecars and staying siblings) and, for
    ///     `.rejectedFolder`, each destination (names already taken).
    ///   - bareSidecarOwner: the `sourceExtension` a bare `NAME.xmp` records, or nil
    ///     when it records none or cannot be read. Asked only for a bare sidecar that a
    ///     staying photograph shares a basename with.
    public static func plan(_ candidates: [SweepCandidate], into disposition: Disposition,
                            listing: (URL) -> [String],
                            bareSidecarOwner: (URL) -> String? = { _ in nil }) -> Plan {
        var plan = Plan(disposition: disposition)
        var seen: Set<String> = []
        var byDirectory: [String: [SweepCandidate]] = [:]
        for candidate in candidates where candidate.isRejected {
            let url = candidate.url.standardizedFileURL
            guard seen.insert(url.path).inserted else { continue }
            if isInsideSweepFolder(url) {
                plan.skipped.append(Skip(url: url, reason: "Already in a \(folderName) folder."))
                continue
            }
            if candidate.sidecarOwed {
                plan.skipped.append(Skip(url: url, reason: "Its sidecar could not be saved yet; "
                                         + "it stays until Lumen has written it."))
                continue
            }
            var normalized = candidate
            normalized.url = url
            byDirectory[url.deletingLastPathComponent().path, default: []].append(normalized)
        }

        var claimed: [String: Set<String>] = [:]   // destination path -> lowercased names
        for directoryPath in byDirectory.keys.sorted() {
            let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
            let names = listing(directory)
            var actualName: [String: String] = [:]
            for name in names { actualName[name.lowercased()] = name }

            var byStem: [String: [SweepCandidate]] = [:]
            for candidate in byDirectory[directoryPath] ?? [] {
                guard actualName[candidate.url.lastPathComponent.lowercased()] != nil else {
                    plan.skipped.append(Skip(url: candidate.url,
                                             reason: "The original is not in its folder."))
                    continue
                }
                byStem[stem(of: candidate.url.lastPathComponent), default: []].append(candidate)
            }

            let destination = directory.appendingPathComponent(folderName, isDirectory: true)
            if disposition == .rejectedFolder, claimed[destination.path] == nil {
                claimed[destination.path] = Set(listing(destination).map { $0.lowercased() })
            }

            for key in byStem.keys.sorted() {
                let photos = (byStem[key] ?? []).sorted {
                    $0.url.lastPathComponent < $1.url.lastPathComponent
                }
                let moving = Set(photos.map { $0.url.lastPathComponent.lowercased() })
                let originals: [String] = photos.map { $0.url.lastPathComponent }
                var sidecars: [String] = []
                for photo in photos {
                    for ext in qualifiedSidecarExtensions {
                        let wanted = (photo.url.lastPathComponent + "." + ext).lowercased()
                        if let found = actualName[wanted] { sidecars.append(found) }
                    }
                }
                // Photographs with this basename that are NOT moving, by extension.
                let staying: [String] = names.compactMap { name in
                    let lower = name.lowercased()
                    guard !moving.contains(lower), stem(of: name) == key else { return nil }
                    let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
                    return PhotoFormats.browsable.contains(ext) ? ext : nil
                }
                let movingExtensions = Set(photos.map { $0.url.pathExtension.lowercased() })
                // The basename as it is spelled on disk, which is what a rename keeps.
                let stemText = URL(fileURLWithPath: originals[0])
                    .deletingPathExtension().lastPathComponent
                for ext in bareSidecarExtensions {
                    guard let found = actualName[(stemText + "." + ext).lowercased()] else { continue }
                    let stays = !staying.isEmpty && !bareTravels(
                        owner: bareSidecarOwner(directory.appendingPathComponent(found)),
                        moving: movingExtensions, staying: Set(staying))
                    if stays {
                        plan.keptSidecars.append(directory.appendingPathComponent(found))
                    } else if !sidecars.contains(found) {
                        sidecars.append(found)
                    }
                }

                let files = originals + sidecars
                var targets = files
                var renamed = false
                if disposition == .rejectedFolder {
                    let taken = claimed[destination.path] ?? []
                    guard let free = freeNames(for: files, stem: stemText, taken: taken) else {
                        for photo in photos {
                            plan.skipped.append(Skip(url: photo.url,
                                reason: "No free name in \(folderName)."))
                        }
                        continue
                    }
                    targets = free.names
                    renamed = free.renamed
                    claimed[destination.path] = taken.union(targets.map { $0.lowercased() })
                }

                var moves: [FileMove] = []
                for (index, file) in files.enumerated() {
                    let target: URL? = disposition == .rejectedFolder
                        ? destination.appendingPathComponent(targets[index]) : nil
                    moves.append(FileMove(source: directory.appendingPathComponent(file),
                                          destination: target,
                                          isSidecar: index >= originals.count))
                }
                plan.groups.append(Group(photos: photos, moves: moves, renamed: renamed))
            }
        }
        return plan
    }

    /// Whether a bare `NAME.xmp` leaves with the moving photographs when others with
    /// the same basename stay. An owner tag decides; without one, Adobe's convention
    /// gives the bare name to a RAW, so it goes with a moving RAW unless a RAW stays.
    static func bareTravels(owner: String?, moving: Set<String>, staying: Set<String>) -> Bool {
        if let owner = owner?.lowercased() {
            if moving.contains(owner) { return true }
            if staying.contains(owner) { return false }
        }
        let isRaw: (String) -> Bool = { PhotoFormats.raw.contains($0) }
        return moving.contains(where: isRaw) && !staying.contains(where: isRaw)
    }

    /// The lowercased basename a group is keyed by: the name up to its LAST dot, so
    /// `DSC_1.ARW` and `DSC_1.JPG` share `dsc_1`.
    static func stem(of name: String) -> String {
        URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent.lowercased()
    }

    /// `files` unchanged when none is taken; otherwise every name's leading `stem`
    /// replaced by `stem-N` for the smallest N that frees them all.
    static func freeNames(for files: [String], stem: String,
                          taken: Set<String>) -> (names: [String], renamed: Bool)? {
        func fits(_ names: [String]) -> Bool {
            let lower = names.map { $0.lowercased() }
            return Set(lower).count == lower.count && !lower.contains { taken.contains($0) }
        }
        if fits(files) { return (files, false) }
        for n in 1...9_999 {
            let names = files.map { file -> String in
                let rest = file.lowercased().hasPrefix(stem.lowercased())
                    ? String(file.dropFirst(stem.count))
                    : "." + URL(fileURLWithPath: file).pathExtension
                return "\(stem)-\(n)" + rest
            }
            if fits(names) { return (names, true) }
        }
        return nil
    }

    // MARK: - Words

    /// The confirmation's body, from the plan it confirms.
    public static func confirmationMessage(for plan: Plan) -> String {
        var lines: [String] = []
        let photos = count(plan.photoCount, "photo")
        let sidecars = plan.sidecarCount > 0
            ? " and \(count(plan.sidecarCount, "sidecar"))" : ""
        switch plan.disposition {
        case .rejectedFolder:
            lines.append("\(photos)\(sidecars) move into a \(folderName) folder beside "
                         + "each original. Lumen does not show \(folderName) folders.")
            if plan.renamedCount > 0 {
                lines.append("\(count(plan.renamedCount, "name")) already taken there "
                             + "get a numbered suffix.")
            }
        case .trash:
            lines.append("\(photos)\(sidecars) move to the Trash. Finder's Put Back "
                         + "returns them.")
        }
        if !plan.keptSidecars.isEmpty {
            lines.append("\(count(plan.keptSidecars.count, "shared sidecar")) stay, "
                         + "because a photo that is not rejected uses them.")
        }
        if !plan.skipped.isEmpty {
            lines.append("\(count(plan.skipped.count, "rejected photo")) cannot be moved "
                         + "and stay where they are.")
        }
        lines.append("Nothing is deleted. Flags and edits travel in the sidecars. "
                     + "Their catalog entries are removed, and the undo history is cleared.")
        return lines.joined(separator: "\n\n")
    }

    static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    // MARK: - The report

    /// What happened to one group, as the executor saw it.
    public struct GroupResult: Equatable, Sendable {
        public var moved: Bool
        /// Where each of the group's files actually landed, in `moves` order, when
        /// moved. The Trash's names are only known after the fact.
        public var landed: [URL]
        public var failure: String?

        public init(moved: Bool, landed: [URL] = [], failure: String? = nil) {
            self.moved = moved
            self.landed = landed
            self.failure = failure
        }
    }

    /// One record per file, then one per skipped photograph. `results` is in
    /// `plan.groups` order; a group with no result was not attempted.
    public static func records(for plan: Plan, results: [GroupResult]) -> [OperationFileRecord] {
        var records: [OperationFileRecord] = []
        for (index, group) in plan.groups.enumerated() {
            let result = index < results.count ? results[index] : nil
            for (fileIndex, move) in group.moves.enumerated() {
                var outcome = OperationFileRecord.Outcome.notAttempted
                var landed: URL? = nil
                if let result {
                    outcome = result.moved ? .delivered : .failed
                    if result.moved, fileIndex < result.landed.count {
                        landed = result.landed[fileIndex]
                    }
                }
                var record = OperationFileRecord(id: records.count, source: move.source,
                    label: move.isSidecar ? "sidecar" : "original", outcome: outcome,
                    plannedDestination: move.destination, attemptedDestination: move.destination,
                    actualDestination: landed, detail: result?.failure)
                record.renamed = group.renamed
                records.append(record)
            }
        }
        for skip in plan.skipped {
            records.append(OperationFileRecord(id: records.count, source: skip.url,
                label: "original", outcome: .skipped, detail: skip.reason))
        }
        return records
    }
}
