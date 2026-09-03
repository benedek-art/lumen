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

    public init(copies: [IngestPlannedCopy], refusals: [String] = []) {
        self.copies = copies
        self.refusals = refusals
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
    /// `seq` is the file's 1-based position in the batch, which is what makes
    /// `{seq:4}` count frames rather than repeat itself — so the order of `sources` is
    /// part of the plan's meaning and the caller sorts before it gets here.
    public static func plan(sources: [IngestSourceFile],
                            destinations: [IngestDestinationRoot],
                            folderTemplate: String,
                            renameTemplate: String?,
                            job: String?,
                            calendar: Calendar = Calendar(identifier: .gregorian)) -> IngestPlan {
        var copies: [IngestPlannedCopy] = []
        var refusals: [String] = []
        let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]

        for (index, source) in sources.enumerated() {
            let seq = index + 1
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

        return IngestPlan(copies: copies, refusals: refusals)
    }
}
