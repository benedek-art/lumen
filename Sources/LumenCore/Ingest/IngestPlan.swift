// IngestPlan.swift
// From "this card, these templates, that folder" to the exact list of paths the copy
// engine will write (D38, docs/10 §10.7).
//
// This lives in the core rather than in the sheet for two reasons that cost real bugs
// elsewhere in this project. The first is that the sheet's path PREVIEW and the paths
// the copy actually writes have to be produced by one piece of code — a preview that
// renders `{seq:4}` one way and a copy that renders it another is a lie told in the
// one place a photographer looks before pressing Return. The second is that this is
// where the traversal guards belong, and guards nobody can run on a Linux box are
// guards nobody re-checks: a folder template rendering `..`, or a filename template
// rendering nothing at all (J3-02, `RenameTemplate.usableBasename`), must be refused
// with a sentence rather than turned into a path.
//
// A refused file is NOT an error that stops the ingest. It is one frame that will not
// be copied, named in the report, with the rest of the card still going to disk.

import Foundation

public enum IngestDestinationRole: String, Sendable, Codable {
    case primary
    case backup
}

/// One destination volume, before templates are applied.
public struct IngestDestinationRoot: Sendable, Hashable {
    public var url: URL
    public var role: IngestDestinationRole

    public init(url: URL, role: IngestDestinationRole) {
        self.url = url
        self.role = role
    }
}

/// One file on the card, with everything the templates can ask about it.
///
/// `captureDate` is resolved by the caller rather than read here, so a plan is a pure
/// function of its inputs and a test can pin a date instead of pinning a clock. Camera,
/// serial and ISO are carried for the day an EXIF reader exists; until then they are
/// nil, the tokens render empty, and the sheet says so rather than implying otherwise.
public struct IngestSourceFile: Sendable, Hashable {
    public var url: URL
    public var byteCount: Int64
    public var captureDate: Date
    public var camera: String?
    public var cameraSerial: String?
    public var iso: Int?

    public init(url: URL, byteCount: Int64, captureDate: Date,
                camera: String? = nil, cameraSerial: String? = nil, iso: Int? = nil) {
        self.url = url
        self.byteCount = byteCount
        self.captureDate = captureDate
        self.camera = camera
        self.cameraSerial = cameraSerial
        self.iso = iso
    }
}

public struct IngestPlannedDestination: Sendable, Hashable {
    public var url: URL
    public var role: IngestDestinationRole

    public init(url: URL, role: IngestDestinationRole) {
        self.url = url
        self.role = role
    }
}

public struct IngestPlannedCopy: Sendable, Hashable {
    public var source: URL
    public var byteCount: Int64
    /// Every destination this one frame is going to, written from a single read of the
    /// card. Each is verified on its own — see `VerifiedCopyDriver`.
    public var destinations: [IngestPlannedDestination]

    public init(source: URL, byteCount: Int64, destinations: [IngestPlannedDestination]) {
        self.source = source
        self.byteCount = byteCount
        self.destinations = destinations
    }
}

public struct IngestPlan: Sendable {
    public var copies: [IngestPlannedCopy]
    /// Files that will not be copied, each with the sentence the sheet shows verbatim.
    public var refusals: [String]
    /// Files on the card this plan does not copy (video, audio, sidecars). Non-empty
    /// keeps `IngestReport.allVerified` false: the card is not safe to format.
    public var leftOnCard: [URL]
    /// True when primary and backup sit on one volume: verified, but not two disks.
    public var backupSharesVolume: Bool

    public init(copies: [IngestPlannedCopy], refusals: [String] = [],
                leftOnCard: [URL] = [], backupSharesVolume: Bool = false) {
        self.copies = copies
        self.refusals = refusals
        self.leftOnCard = leftOnCard
        self.backupSharesVolume = backupSharesVolume
    }

    /// The card's payload, not the payload times the number of destinations: this is
    /// what has to be READ, and the read is what takes the time.
    public var totalBytes: Int64 {
        copies.reduce(Int64(0)) { $0 + $1.byteCount }
    }
}

public enum IngestPlanner {

    /// The path components a folder template renders to, in order.
    ///
    /// Split on `/` FIRST and render each component separately, because `sanitize`
    /// maps a separator to a dash — rendering the whole template in one go turns
    /// `{year}/{date}` into a single directory called "2026-20260902". Components that
    /// render to nothing are dropped (a `{job}` nobody filled in is not an unnamed
    /// folder), and a component that renders to something that is not a usable name —
    /// `.`, `..`, or anything carrying a separator — is dropped too rather than
    /// climbing out of the destination the open panel granted.
    public static func folderComponents(template: String,
                                        context: RenameContext,
                                        seq: Int) -> [String] {
        template.split(separator: "/", omittingEmptySubsequences: true)
            .map { RenameTemplate.render(String($0), context: context, seq: seq) }
            .compactMap { RenameTemplate.usableBasename($0) }
    }

    /// Render one file's destination under one root.
    public static func destination(root: URL,
                                   folder: [String],
                                   basename: String,
                                   fileExtension: String) -> URL {
        var url = root
        for component in folder {
            url = url.appendingPathComponent(component, isDirectory: true)
        }
        let named = url.appendingPathComponent(basename, isDirectory: false)
        return fileExtension.isEmpty ? named : named.appendingPathExtension(fileExtension)
    }

    /// The whole plan. `renameTemplate` nil keeps the camera's own names.
    ///
    /// `seq` is the 1-based position of the file's FRAME in the batch, which is what
    /// makes `{seq:4}` count frames rather than repeat itself — so the order of
    /// `sources` is part of the plan's meaning and the caller sorts before it gets here.
    /// A frame is every file in one card folder sharing one stem: DSCF0001.JPG and
    /// DSCF0001.RAF are one frame and get one number, so a RAW+JPEG pair leaves the
    /// card under one base name — the name Lightroom and every other tool pairs them
    /// by. Numbering files instead gave the JPEG -0001 and its RAW -0002.
    public static func plan(sources: [IngestSourceFile],
                            destinations: [IngestDestinationRoot],
                            folderTemplate: String,
                            renameTemplate: String?,
                            job: String?,
                            calendar: Calendar = Calendar(identifier: .gregorian),
                            sourceRoot: URL? = nil,
                            leftOnCard: [URL] = []) -> IngestPlan {
        if let sourceRoot,
           let inside = destinations.first(where: { IngestLocation.isInside($0.url, sourceRoot) }) {
            return IngestPlan(copies: [], refusals: [
                "Nothing was copied: the \(inside.role.rawValue) destination is on the source "
                + "card itself. A copy on the card is lost when the card is formatted, and the "
                + "next ingest would import it again. Choose a folder on another disk."],
                leftOnCard: leftOnCard)
        }
        let primaries = destinations.filter { $0.role == .primary }
        let backupSharesVolume = destinations.contains { backup in
            backup.role == .backup
                && primaries.contains { IngestLocation.sameVolume($0.url, backup.url) }
        }
        var copies: [IngestPlannedCopy] = []
        var refusals: [String] = []
        let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]

        var frameNumbers: [String: Int] = [:]

        for source in sources {
            let frame = source.url.deletingPathExtension().standardizedFileURL.path
            let seq = frameNumbers[frame] ?? frameNumbers.count + 1
            frameNumbers[frame] = seq
            let original = source.url.deletingPathExtension().lastPathComponent
            let context = RenameContext(
                originalBasename: original,
                captureDate: calendar.dateComponents(fields, from: source.captureDate),
                camera: source.camera,
                cameraSerial: source.cameraSerial,
                iso: source.iso,
                job: job)

            let basename: String
            if let renameTemplate {
                let rendered = RenameTemplate.render(renameTemplate, context: context, seq: seq)
                guard let usable = RenameTemplate.usableBasename(rendered) else {
                    refusals.append(source.url.lastPathComponent
                                    + ": the filename template renders no usable name for "
                                    + "this file, so it was not copied.")
                    continue
                }
                basename = usable
            } else {
                // The camera's own name. It came off a filesystem, so it is already a
                // name — but it still goes through the same guard, because a card
                // mounted from somewhere less trustworthy is exactly when this matters.
                guard let usable = RenameTemplate.usableBasename(original) else {
                    refusals.append(source.url.lastPathComponent
                                    + ": the file's own name cannot be used as a filename.")
                    continue
                }
                basename = usable
            }

            let folder = folderComponents(template: folderTemplate, context: context, seq: seq)
            let planned = destinations.map { root in
                IngestPlannedDestination(
                    url: destination(root: root.url, folder: folder, basename: basename,
                                     fileExtension: source.url.pathExtension),
                    role: root.role)
            }
            copies.append(IngestPlannedCopy(source: source.url,
                                            byteCount: source.byteCount,
                                            destinations: planned))
        }

        return IngestPlan(copies: copies, refusals: refusals,
                          leftOnCard: leftOnCard, backupSharesVolume: backupSharesVolume)
    }
}

/// What a card scan leaves behind.
public enum IngestCardScan {

    /// Regular files under `root` whose extension is not in `copying`, enumerated with
    /// the same options as the sheet's photo scan, sorted by path.
    public static func filesNotCopied(under root: URL, copying extensions: Set<String>) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var left: [URL] = []
        for case let file as URL in enumerator {
            guard !extensions.contains(file.pathExtension.lowercased()) else { continue }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: file.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            left.append(file)
        }
        return left.sorted { $0.path < $1.path }
    }

    /// "2 videos, 1 audio file, 1 other file" for the files `filesNotCopied` found.
    public static func describe(_ files: [URL]) -> String {
        let video: Set<String> = ["mov", "mp4", "m4v", "avi", "mts", "m2ts", "mxf", "3gp", "insv", "lrv"]
        let audio: Set<String> = ["wav", "mp3", "m4a", "aac", "aif", "aiff", "bwf"]
        var videos = 0, audios = 0, others = 0
        for file in files {
            let ext = file.pathExtension.lowercased()
            if video.contains(ext) { videos += 1 } else if audio.contains(ext) { audios += 1 } else { others += 1 }
        }
        var parts: [String] = []
        if videos > 0 { parts.append("\(videos) video\(videos == 1 ? "" : "s")") }
        if audios > 0 { parts.append("\(audios) audio file\(audios == 1 ? "" : "s")") }
        if others > 0 { parts.append("\(others) other file\(others == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }

    /// The sentence the report and the sheet show, or nil when nothing is left.
    public static func notCopiedSentence(_ files: [URL]) -> String? {
        guard !files.isEmpty else { return nil }
        let names = files.prefix(3).map(\.lastPathComponent).joined(separator: ", ")
            + (files.count > 3 ? ", …" : "")
        let noun = files.count == 1 ? "file" : "files"
        return "\(files.count) \(noun) on the card that \(files.count == 1 ? "is" : "are") not "
            + "photos (\(describe(files))) will NOT be copied: \(names). Copy them separately "
            + "before formatting the card."
    }
}

/// Which directory a path actually names on disk — the question two destination roots
/// have to answer before they may be called two copies (S-02).
///
/// A string comparison of paths cannot answer it: a backup root chosen through a
/// symlink, a bind mount or a second mount of the same share is spelled differently and
/// is the same folder, and every "second copy" written there lands beside the first.
/// The identity used here is the device and inode of the nearest existing ancestor
/// (after resolving symlinks), plus whatever components below it do not exist yet.
///
/// WHAT THIS DOES NOT PROVE. Two directories with different identities are two
/// directories, nothing more: they can sit on one disk, one RAID set, one network share.
/// This check refuses a redundancy claim that is certainly false; it never certifies
/// physical independence, and no caller may word a result as if it did.
public enum IngestLocation {

    /// An opaque key: equal keys name the same directory.
    public static func directoryIdentity(of url: URL) -> String {
        let fm = FileManager.default
        var existing = url.standardizedFileURL
        var remainder: [String] = []
        while !fm.fileExists(atPath: existing.path) {
            let parent = existing.deletingLastPathComponent().standardizedFileURL
            if parent.path == existing.path { break }
            remainder.insert(existing.lastPathComponent, at: 0)
            existing = parent
        }
        let resolved = existing.resolvingSymlinksInPath()
        var key = "path:" + resolved.path
        if let attributes = try? fm.attributesOfItem(atPath: resolved.path),
           let device = unsigned(attributes[.systemNumber]),
           let inode = unsigned(attributes[.systemFileNumber]) {
            key = "id:\(device):\(inode)"
        }
        return ([key] + remainder).joined(separator: "/")
    }

    /// Existing files are identified by their device and inode, so case variants,
    /// symbolic links and hard links cannot be counted as distinct deliveries. A
    /// not-yet-created slot retains its directory/name identity; callers recording
    /// a completed write must ask again after publication.
    public static func fileIdentity(of url: URL) -> String {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        if let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
           let device = unsigned(attributes[.systemNumber]),
           let inode = unsigned(attributes[.systemFileNumber]) {
            return "file:\(device):\(inode)"
        }
        return directoryIdentity(of: url.deletingLastPathComponent()) + "//" + url.lastPathComponent
    }

    /// True when `url` is `root` or lies below it, compared by directory identity so a
    /// symlinked or differently spelled path to the card still counts.
    public static func isInside(_ url: URL, _ root: URL) -> Bool {
        let rootKey = directoryIdentity(of: root)
        // Resolve symlinks before walking up: the lexical parent of an alias is not the
        // parent of the directory it points at.
        let fm = FileManager.default
        var existing = url.standardizedFileURL
        var remainder: [String] = []
        while !fm.fileExists(atPath: existing.path) {
            let parent = existing.deletingLastPathComponent().standardizedFileURL
            if parent.path == existing.path { break }
            remainder.insert(existing.lastPathComponent, at: 0)
            existing = parent
        }
        var current = existing.resolvingSymlinksInPath()
        for component in remainder { current.appendPathComponent(component) }
        while true {
            if directoryIdentity(of: current) == rootKey { return true }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path { return false }
            current = parent
        }
    }

    /// True when both URLs resolve, through their nearest existing ancestors, to one
    /// device. Says nothing about physical disks behind a RAID or share.
    public static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let da = device(of: a), let db = device(of: b) else { return false }
        return da == db
    }

    private static func device(of url: URL) -> UInt64? {
        let fm = FileManager.default
        var existing = url.standardizedFileURL
        while !fm.fileExists(atPath: existing.path) {
            let parent = existing.deletingLastPathComponent().standardizedFileURL
            if parent.path == existing.path { return nil }
            existing = parent
        }
        let resolved = existing.resolvingSymlinksInPath()
        return unsigned((try? fm.attributesOfItem(atPath: resolved.path))?[.systemNumber])
    }

    /// True when the two URLs are one directory under two spellings.
    public static func sameDirectory(_ a: URL, _ b: URL) -> Bool {
        directoryIdentity(of: a) == directoryIdentity(of: b)
    }

    private static func unsigned(_ value: Any?) -> UInt64? {
        switch value {
        case let number as UInt64: return number
        case let number as Int: return UInt64(bitPattern: Int64(number))
        case let number as UInt32: return UInt64(number)
        case let number as Int32: return UInt64(bitPattern: Int64(number))
        case let number as NSNumber: return number.uint64Value
        default: return nil
        }
    }
}
