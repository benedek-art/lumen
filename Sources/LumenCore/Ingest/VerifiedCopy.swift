// VerifiedCopy.swift
// The copy engine behind the ingest sheet's Start button (D38, docs/10 §10.7).
//
// The protocol docs/10 specifies, and the reason this file exists at all: a copy is
// not finished when the bytes have been written. It is finished when the file at the
// destination has been read BACK and hashes to what came off the card. Photo Mechanic
// does not do this; the culture it created ("format in camera once both copies are
// confirmed") rests on a confirmation nobody ever actually performed. A card ingest
// that silently truncates a frame and then reports success is the worst bug this
// application can have, because the evidence — the card — gets formatted right after.
//
// Four properties are load-bearing, and each one is a decision rather than an accident:
//
//   · NOTHING IS EVER OVERWRITTEN. Bytes are streamed into a hidden `.part` file in
//     the destination directory and moved into place only once they are all there, so
//     the destination path never exists in a half-written state. If something is
//     already at that path, one of two things is true: it is the same file (a
//     re-ingest of a card that was half-drained — docs/10 calls this incremental
//     re-ingest), which is reported as already present and not copied again; or it is
//     a different file, and the new frame goes beside it under a disambiguated name
//     via `ExportRecipe.disambiguated`, the same policy the export path already uses.
//   · A FAILURE IS PER DESTINATION, NOT PER RUN. A backup volume that fills up does
//     not stop the primary, and one unreadable frame does not abandon the other 339.
//     Each destination gets its own verdict, which is exactly what docs/10 means by
//     "each destination verifies independently".
//   · AN UNVERIFIED COPY IS DELETED. If the read-back does not match, the file at the
//     destination is removed. Leaving it is how a corrupt frame gets counted as
//     ingested by the next run, by the contact sheet, and by the photographer who is
//     about to format the card.
//   · CANCEL LEAVES NOTHING BEHIND. Stopping mid-file deletes that file's `.part` and
//     records no verdict for it, so "stopped after 42 frames" means exactly 42 frames
//     are on disk.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A stop button, in the shape the copy loop can read.
///
/// Deliberately not `Task.isCancelled`: the loop is synchronous — it is a file copy,
/// not a structured-concurrency graph — and a flag is the one mechanism that can be
/// tripped from the UI thread, from a progress callback, and from a test, all three of
/// which happen.
public final class IngestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    public func cancel() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}

/// What the copy has done so far. Reported after every chunk, so a 400 MB frame moves
/// the bar rather than sitting still for four seconds.
///
/// Two byte counters, because they answer two questions (S-03). `bytesProcessed` is how
/// far through the card the run has got — every frame finished, landed or not, plus the
/// one in flight — and is what the bar fills by: a run that has dealt with every frame
/// is finished, and the bar says so. `bytesCopied` is what has actually landed on a
/// destination, plus the frame in flight; a frame that failed everywhere, was already
/// on disk, or had nowhere to go adds nothing to it. Whether a finished run SUCCEEDED
/// is never the bar's to say: `filesFailed` and the report's summary name the failures.
public struct IngestProgress: Sendable, Equatable {
    public var filesCompleted: Int
    public var filesTotal: Int
    public var bytesCopied: Int64
    public var bytesTotal: Int64
    /// The file being read right now, by name — the path is not what a photographer
    /// watching a card drain is reading.
    public var currentFile: String?
    public var bytesProcessed: Int64
    /// Frames finished so far with at least one destination failed.
    public var filesFailed: Int

    public init(filesCompleted: Int, filesTotal: Int, bytesCopied: Int64,
                bytesTotal: Int64, currentFile: String?,
                bytesProcessed: Int64? = nil, filesFailed: Int = 0) {
        self.filesCompleted = filesCompleted
        self.filesTotal = filesTotal
        self.bytesCopied = bytesCopied
        self.bytesTotal = bytesTotal
        self.currentFile = currentFile
        self.bytesProcessed = bytesProcessed ?? bytesCopied
        self.filesFailed = filesFailed
    }

    /// 0…1 through the card, by bytes where there are any and by file count otherwise.
    /// Reaches 1 when every frame has been dealt with, whatever happened to it.
    public var fraction: Double {
        if bytesTotal > 0 { return min(1, Double(bytesProcessed) / Double(bytesTotal)) }
        guard filesTotal > 0 else { return 0 }
        return min(1, Double(filesCompleted) / Double(filesTotal))
    }
}

public enum IngestCopyFailure: Sendable, Equatable {
    case unreadableSource(String)
    case unwritableDestination(String)
    case unreadableCopy(String)
    case destinationChanged
    /// Verification failed and removing the installed, unusable file also failed.
    case unverifiedCopyRemains(verificationFailure: String, cleanupFailure: String)
    case verificationMismatch(expected: IngestDigest, found: IngestDigest)
    /// The source delivered fewer bytes than the card scan recorded, without raising an
    /// error — a clean premature EOF. Distinct from `verificationMismatch` because
    /// nothing disagreed: the copy matched the read exactly, and the read was short.
    case shortRead(expected: Int64, read: Int64)
    /// This destination is the same directory as another destination of the same frame
    /// (a symlink, a bind mount, the same share mounted twice). Nothing was written to
    /// it: a file there would be a second name for the first copy, not a second copy.
    case aliasedDestination(of: IngestDestinationRole)

    /// The sentence the sheet shows. Never "something went wrong": the difference
    /// between a full disk and a card going bad is the whole of what the photographer
    /// needs to decide, and it is known here.
    public var message: String {
        switch self {
        case .unreadableSource(let why):
            return "could not be read from the source: " + why
        case .unwritableDestination(let why):
            return "could not be written to the destination: " + why
        case .unreadableCopy(let why):
            return "landed but could not be read back to verify it: " + why
        case .destinationChanged:
            return "destination ownership changed or the file generation could not be verified. "
                + "The current destination was left untouched; its bytes are not a verified delivery. "
                + "Keep the source and inspect the destination before trying again."
        case .unverifiedCopyRemains(let verificationFailure, let cleanupFailure):
            return "the copy could not be verified (" + verificationFailure
                + ") and could not be removed: " + cleanupFailure
                + ". The unverified file remains at the destination; do not use it or eject the source."
        case .shortRead(let expected, let read):
            return "the source ended early — the card said \(expected) bytes and only "
                + "\(read) arrived, so nothing was written"
        case .aliasedDestination(let other):
            return "is the same folder as the \(other.rawValue) destination, so it would "
                + "not be a second copy — nothing was written there"
        case .verificationMismatch(let expected, let found):
            return "the copy does not match the source — source \(expected), copy "
                + "\(found) — so the copy was deleted"
        }
    }
}

public enum IngestCopyOutcome: Sendable, Equatable {
    /// Written, read back, and the read-back matched.
    case verified(IngestDigest)
    /// Written, with verification switched off. Not the same claim, so not the same case.
    case copied(IngestDigest)
    /// The identical bytes were already at the destination, so nothing was copied.
    case alreadyPresent(IngestDigest)
    case failed(IngestCopyFailure)
}

/// One frame, one destination, one verdict.
public struct IngestFileResult: Sendable, Equatable {
    public var source: URL
    /// Where the plan said it would go.
    public var plannedDestination: URL
    /// Where it actually went. Differs from the planned path when something was
    /// already there — never because the copy chose to move somebody's file.
    public var destination: URL
    public var role: IngestDestinationRole
    public var outcome: IngestCopyOutcome

    public init(source: URL, plannedDestination: URL, destination: URL,
                role: IngestDestinationRole, outcome: IngestCopyOutcome) {
        self.source = source
        self.plannedDestination = plannedDestination
        self.destination = destination
        self.role = role
        self.outcome = outcome
    }

    public var wasRenamed: Bool { destination != plannedDestination }

    public var failure: IngestCopyFailure? {
        if case .failed(let failure) = outcome { return failure }
        return nil
    }

    /// Verified, or already there and proven identical. Both mean the same thing about
    /// the bytes on that volume, which is the only thing eject is allowed to ask about.
    public var isProven: Bool {
        switch outcome {
        case .verified, .alreadyPresent: return true
        case .copied, .failed: return false
        }
    }

    /// "DSCF0001.RAF → primary: …", the form the sheet lists failures in.
    public var label: String {
        source.lastPathComponent + " → " + role.rawValue
    }
}

public struct IngestReport: Sendable {
    public var results: [IngestFileResult]
    /// Files the plan refused to name — never copied, always said out loud.
    public var refusals: [String]
    public var wasCancelled: Bool
    public var filesAttempted: Int
    public var filesPlanned: Int
    /// The card bytes of every frame that landed on at least one destination — not of
    /// frames that were already there, failed everywhere, or had nowhere to go.
    public var bytesCopied: Int64
    /// Frames with at least one destination, every one of which is proven (verified or
    /// already present). The only count a sentence may call "ingested".
    public var framesVerified: Int
    /// Frames with at least one destination, every one of which landed or was already
    /// there — verified or not. Equal to `framesVerified` whenever verification is on.
    public var framesLanded: Int

    /// `framesVerified` / `framesLanded` default to a count over `results` grouped by
    /// source, for a report built by hand; the driver passes the per-plan counts, which
    /// also know about frames that had no destination at all.
    public init(results: [IngestFileResult], refusals: [String], wasCancelled: Bool,
                filesAttempted: Int, filesPlanned: Int, bytesCopied: Int64,
                framesVerified: Int? = nil, framesLanded: Int? = nil) {
        self.results = results
        self.refusals = refusals
        self.wasCancelled = wasCancelled
        self.filesAttempted = filesAttempted
        self.filesPlanned = filesPlanned
        self.bytesCopied = bytesCopied
        let bySource = Dictionary(grouping: results, by: \.source).values
        self.framesVerified = framesVerified
            ?? bySource.filter { $0.allSatisfy(\.isProven) }.count
        self.framesLanded = framesLanded
            ?? bySource.filter { $0.allSatisfy { $0.failure == nil } }.count
    }

    public var failures: [IngestFileResult] { results.filter { $0.failure != nil } }
    /// Frames THIS run wrote under a name other than the planned one. A frame found
    /// already on disk under an earlier run's disambiguated name was not renamed now —
    /// nothing was written — so it is counted as already present, not here.
    public var renamed: [IngestFileResult] {
        results.filter {
            guard $0.wasRenamed else { return false }
            if case .alreadyPresent = $0.outcome { return false }
            return true
        }
    }
    public var alreadyPresent: [IngestFileResult] {
        results.filter { if case .alreadyPresent = $0.outcome { return true } else { return false } }
    }

    /// Every planned frame is on every planned destination, and every one of those was
    /// read back and matched. This — and nothing weaker — is what may offer eject.
    public var allVerified: Bool {
        !wasCancelled
            && refusals.isEmpty
            && filesAttempted == filesPlanned
            && framesVerified == filesPlanned
            && !results.isEmpty
            && results.allSatisfy(\.isProven)
            && !twoFramesShareOneFile
            && !twoCopiesShareOneFile
            && !destinationAliasesSource
    }

    /// Two different frames on the card standing on ONE file at the destination. Each
    /// verdict on its own can be honest — the bytes there do match each source — and
    /// the card still holds a frame the volume does not (S-01). Compared by directory
    /// identity, so a second spelling of the same folder is the same file.
    public var twoFramesShareOneFile: Bool {
        var owner: [String: URL] = [:]
        for result in results where result.isProven {
            let slot = IngestLocation.fileIdentity(of: result.destination)
            if let other = owner[slot], other != result.source { return true }
            owner[slot] = result.source
        }
        return false
    }

    /// A primary and backup for one source must not be two links to the same file.
    /// Also defend legacy/manually constructed reports independently of the driver.
    public var twoCopiesShareOneFile: Bool {
        var owners: [String: IngestFileResult] = [:]
        for result in results where result.isProven {
            let identity = IngestLocation.fileIdentity(of: result.destination)
            if let other = owners[identity], other.role != result.role { return true }
            owners[identity] = result
        }
        return false
    }

    public var destinationAliasesSource: Bool {
        results.contains { result in
            result.isProven && IngestLocation.fileIdentity(of: result.destination)
                == IngestLocation.fileIdentity(of: result.source)
        }
    }

    /// One line, true, and specific enough to act on.
    ///
    /// The noun agrees with the count it is attached to, which is not fussiness: "1 of 3
    /// frame" is the sentence a photographer reads at the moment they are deciding
    /// whether the card is safe to reuse, and a status line that cannot count does not
    /// invite trust in the count.
    public var summary: String {
        let attemptedWord = framesLanded == 1 ? "frame" : "frames"
        let plannedWord = filesPlanned == 1 ? "frame" : "frames"
        var sentence: String
        // Name the first failure. "2 failed" leaves a photographer with no way to tell
        // a full disk from a card going bad, and that is the whole decision.
        let firstFailure = failures.first.map {
            "\(failures.count) failed — " + $0.label + ": " + ($0.failure?.message ?? "")
        }
        if wasCancelled {
            sentence = "Stopped after \(filesAttempted) of \(filesPlanned) \(plannedWord) — "
                + "nothing was left half-written."
            // A stop does not erase what went wrong before it (S-03).
            if let firstFailure { sentence += " Before the stop, " + firstFailure }
        } else if filesAttempted == 0 && failures.isEmpty {
            sentence = "Nothing was copied."
        } else if failures.isEmpty {
            if framesLanded == filesAttempted {
                sentence = "Ingested \(framesLanded) \(attemptedWord)"
            } else {
                // Frames with no destination at all: attempted, never written.
                sentence = "Ingested \(framesLanded) of \(filesPlanned) \(plannedWord) — "
                    + "\(filesAttempted - framesLanded) had nowhere to go"
            }
            sentence += allVerified ? ", every copy verified." : ", UNVERIFIED."
        } else {
            // "Ingested" counts only frames proven on every destination — a frame that
            // failed is not ingested because it was attempted (S-03).
            sentence = "Ingested \(framesVerified) of \(filesPlanned) \(plannedWord) — "
                + (firstFailure ?? "")
            if framesLanded > framesVerified {
                sentence += " · \(framesLanded - framesVerified) copied without verification"
            }
        }
        if !alreadyPresent.isEmpty {
            sentence += " · \(alreadyPresent.count) already on disk"
        }
        if !renamed.isEmpty {
            sentence += " · \(renamed.count) renamed to avoid overwriting"
        }
        if !refusals.isEmpty {
            sentence += " · \(refusals.count) refused: " + refusals[0]
        }
        if twoFramesShareOneFile {
            sentence += " · two different frames point at one file on the destination"
        }
        if twoCopiesShareOneFile {
            sentence += " · primary and backup point at one file; an independent copy is still needed"
        }
        if destinationAliasesSource {
            sentence += " · a destination is the source itself; an independent copy is still needed"
        }
        return sentence
    }
}

/// How a landed file is read back.
///
/// A seam, for two reasons that are both real. On a platform with a page cache, a
/// re-read straight after a write can be served from memory — which verifies RAM
/// rather than the platter — so the layer that knows how to open a handle with caching
/// off can substitute one here. And the mismatch path (delete the copy, keep the batch
/// running) is otherwise unfalsifiable: no test can ask a filesystem to corrupt a file
/// on demand, so the test substitutes a read-back that lies.
public protocol IngestReadback: Sendable {
    func digest(of url: URL, chunkSize: Int) throws -> IngestDigest
}

/// The default: re-open the file and hash every byte of it.
public struct FileReadback: IngestReadback {
    public init() {}

    public func digest(of url: URL, chunkSize: Int) throws -> IngestDigest {
        try IngestFileDigest.digest(of: url, chunkSize: chunkSize)
    }
}

public struct VerifiedCopyDriver: Sendable {

    public var verify: Bool
    public var chunkSize: Int
    public var readback: any IngestReadback

    public init(verify: Bool = true,
                chunkSize: Int = IngestFileDigest.defaultChunkSize,
                readback: any IngestReadback = FileReadback()) {
        self.verify = verify
        self.chunkSize = max(1, chunkSize)
        self.readback = readback
    }

    /// No-follow ownership: a replacement symlink must never authorize removal.
    private struct InstalledOwnership: Equatable {
        let device: UInt64
        let inode: UInt64

        static func read(_ url: URL) -> InstalledOwnership? {
            #if canImport(Darwin) || canImport(Glibc)
            var info = stat()
            let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return -1 }
                return lstat(path, &info)
            }
            guard status == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return nil }
            return InstalledOwnership(device: UInt64(truncatingIfNeeded: info.st_dev),
                                      inode: UInt64(truncatingIfNeeded: info.st_ino))
            #else
            return nil
            #endif
        }
    }

    private func cleanupUnverifiedCopy(at url: URL, owner: InstalledOwnership?,
                                       failure: IngestCopyFailure) -> IngestCopyFailure {
        // This narrows the path race; filesystem APIs do not offer conditional unlink.
        guard let owner, InstalledOwnership.read(url) == owner else { return .destinationChanged }
        do {
            try FileManager.default.removeItem(at: url)
            return failure
        } catch {
            // Keep digests out of durable report details, as for ordinary mismatch reports.
            let reason: String
            switch failure {
            case .verificationMismatch: reason = "Verification mismatch"
            case .unreadableCopy(let why): reason = "Read-back failed: " + why
            default: reason = "Verification failed"
            }
            return .unverifiedCopyRemains(verificationFailure: reason,
                                          cleanupFailure: error.localizedDescription)
        }
    }

    /// Copy the whole plan. Returns when every frame has a verdict, or as soon as
    /// `cancellation` is tripped.
    ///
    /// Synchronous on purpose: this is one long read, and the caller decides which
    /// thread it happens on. `progress` is called on that same thread.
    public func run(_ plan: IngestPlan,
                    cancellation: IngestCancellation = IngestCancellation(),
                    progress: (@Sendable (IngestProgress) -> Void)? = nil) -> IngestReport {
        var results: [IngestFileResult] = []
        var attempted = 0
        // Landed bytes and processed bytes are different numbers (S-03): see
        // `IngestProgress`. Only a frame that reached at least one destination this run
        // adds to `bytesCopied`.
        var bytesCopied: Int64 = 0
        var bytesProcessed: Int64 = 0
        var framesVerified = 0
        var framesLanded = 0
        var framesFailed = 0
        var cancelled = false
        let total = plan.totalBytes
        // Which source frame each destination file stands for in THIS run (S-01). A
        // file this run already landed or proved for one frame is that frame's copy;
        // a second frame with identical bytes rendered to the same name is a second
        // frame, and must get its own file rather than be absorbed into the first.
        var claims: [String: URL] = [:]

        for copy in plan.copies {
            if cancellation.isCancelled { cancelled = true; break }
            let name = copy.source.lastPathComponent
            func report(copied: Int64, processed: Int64) {
                progress?(IngestProgress(filesCompleted: attempted,
                                         filesTotal: plan.copies.count,
                                         bytesCopied: copied, bytesTotal: total,
                                         currentFile: name, bytesProcessed: processed,
                                         filesFailed: framesFailed))
            }
            report(copied: bytesCopied, processed: bytesProcessed)
            var readSoFar: Int64 = 0
            let outcome = perform(copy, cancellation: cancellation, claims: &claims) { chunk in
                readSoFar += chunk
                report(copied: bytesCopied + readSoFar, processed: bytesProcessed + readSoFar)
            }
            results.append(contentsOf: outcome.results)
            if outcome.cancelled {
                cancelled = true
                break
            }
            attempted += 1
            bytesProcessed += copy.byteCount
            let verdicts = outcome.results
            let landedSomewhere = verdicts.contains {
                switch $0.outcome {
                case .verified, .copied: return true
                case .alreadyPresent, .failed: return false
                }
            }
            if landedSomewhere { bytesCopied += copy.byteCount }
            if verdicts.contains(where: { $0.failure != nil }) { framesFailed += 1 }
            let everyDestination = !copy.destinations.isEmpty
                && verdicts.count == copy.destinations.count
            if everyDestination && verdicts.allSatisfy(\.isProven) { framesVerified += 1 }
            if everyDestination && verdicts.allSatisfy({ $0.failure == nil }) { framesLanded += 1 }
            report(copied: bytesCopied, processed: bytesProcessed)
        }

        return IngestReport(results: results, refusals: plan.refusals,
                            wasCancelled: cancelled, filesAttempted: attempted,
                            filesPlanned: plan.copies.count, bytesCopied: bytesCopied,
                            framesVerified: framesVerified, framesLanded: framesLanded)
    }

    // MARK: - One frame

    /// A destination that is being written: where it is going, and the hidden file the
    /// bytes are landing in until they are all there.
    private struct Writer {
        var planned: URL
        var final: URL
        var temp: URL
        var handle: FileHandle
        var role: IngestDestinationRole
    }

    /// What one frame's attempt produced: a verdict per destination, and whether the
    /// stop button was pressed while it was in flight.
    private struct FrameOutcome {
        var results: [IngestFileResult]
        var cancelled: Bool
    }

    private func perform(_ copy: IngestPlannedCopy, cancellation: IngestCancellation,
                         claims: inout [String: URL],
                         onChunk: (Int64) -> Void) -> FrameOutcome {
        let fm = FileManager.default
        var results: [IngestFileResult] = []
        var landedDestinations: Set<String> = []
        let sourceIdentity = IngestLocation.fileIdentity(of: copy.source)

        func verdict(_ planned: URL, _ landed: URL, _ role: IngestDestinationRole,
                     _ outcome: IngestCopyOutcome) -> IngestFileResult {
            switch outcome {
            case .verified, .copied, .alreadyPresent:
                let identity = IngestLocation.fileIdentity(of: landed)
                claims[identity] = copy.source
                landedDestinations.insert(identity)
            case .failed:
                break
            }
            return IngestFileResult(source: copy.source, plannedDestination: planned,
                                    destination: landed, role: role, outcome: outcome)
        }
        /// A file this run has already landed or proved for a DIFFERENT frame.
        func claimedByAnotherFrame(_ url: URL) -> Bool {
            guard let owner = claims[IngestLocation.fileIdentity(of: url)] else { return false }
            return owner != copy.source
        }

        let reader: FileHandle
        do {
            reader = try FileHandle(forReadingFrom: copy.source)
        } catch let error {
            // One frame the card will not give up. Every destination for it fails, and
            // the run carries on with the next frame.
            for destination in copy.destinations {
                results.append(verdict(destination.url, destination.url, destination.role,
                                       .failed(.unreadableSource(error.localizedDescription))))
            }
            return FrameOutcome(results: results, cancelled: false)
        }
        defer { try? reader.close() }

        // The source's own digest, computed only if a collision makes it necessary —
        // it costs a second full read of the file, so it is not paid on the ordinary
        // path where the in-flight hash is free.
        var sourceDigest: IngestDigest?
        func digestOfSource() -> IngestDigest? {
            if sourceDigest == nil {
                sourceDigest = try? IngestFileDigest.digest(of: copy.source, chunkSize: chunkSize)
            }
            return sourceDigest
        }

        var writers: [Writer] = []
        // Which directory each of this frame's destinations really is (S-02). Two roots
        // that are one folder under two spellings would otherwise each "verify" a copy,
        // and the run would claim a redundancy the photographer does not have.
        var directoriesWritten: [String: IngestDestinationRole] = [:]
        for destination in copy.destinations {
            let folder = destination.url.deletingLastPathComponent()
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch let error {
                results.append(verdict(destination.url, destination.url, destination.role,
                                       .failed(.unwritableDestination(error.localizedDescription))))
                continue
            }
            let directory = IngestLocation.directoryIdentity(of: folder)
            if let first = directoriesWritten[directory] {
                results.append(verdict(destination.url, destination.url, destination.role,
                                       .failed(.aliasedDestination(of: first))))
                continue
            }
            directoriesWritten[directory] = destination.role

            var landing = destination.url
            if fm.fileExists(atPath: destination.url.path) {
                // Already there. Either it is this frame — a card that was half
                // drained, re-inserted — or it is a different frame that rendered to
                // the same name. The bytes decide, never the name — and never for a
                // file this run already wrote for another frame on the card, which is
                // that frame's copy however alike the bytes are (S-01).
                //
                // The search walks the same disambiguation chain a landing would
                // (`name`, `name-1`, `name-2`, …) and stops at the first slot that is
                // either free or this frame. An earlier run that had to step round a
                // stranger's file left this frame at `name-1`; without the walk every
                // re-ingest found the stranger, stepped round it again and added
                // `name-2`, `name-3`, … (S-04). A slot is this frame only if it is not
                // claimed by another frame of this run, is the size the source is,
                // and hashes to the source's digest — so the walk costs a stat per
                // stranger and a hash only for a same-sized candidate.
                var earlierCopy: URL?
                var earlierDigest: IngestDigest?
                func holdsThisFrame(_ candidate: URL) -> Bool {
                    // A second role needs its own file, and the source itself is
                    // never an already-ingested copy. Walk past those aliases without
                    // modifying them, just like any other occupied collision slot.
                    let identity = IngestLocation.fileIdentity(of: candidate)
                    guard identity != sourceIdentity,
                          !landedDestinations.contains(identity),
                          !claimedByAnotherFrame(candidate),
                          let mine = digestOfSource(),
                          let size = try? candidate.resourceValues(forKeys: [.fileSizeKey])
                              .fileSize,
                          Int64(size) == mine.byteCount,
                          let existing = try? IngestFileDigest.digest(of: candidate,
                                                                      chunkSize: chunkSize),
                          existing == mine else { return false }
                    earlierCopy = candidate
                    earlierDigest = existing
                    return true
                }
                let free = ExportRecipe.disambiguated(destination.url) { candidate in
                    fm.fileExists(atPath: candidate.path) && !holdsThisFrame(candidate)
                }
                if let earlierCopy, let earlierDigest {
                    guard earlierDigest.byteCount == copy.byteCount else {
                        results.append(verdict(destination.url, earlierCopy, destination.role,
                            .failed(.shortRead(expected: copy.byteCount,
                                               read: earlierDigest.byteCount))))
                        continue
                    }
                    results.append(verdict(destination.url, earlierCopy, destination.role,
                                           .alreadyPresent(earlierDigest)))
                    continue
                }
                landing = free
            }

            // Hidden and suffixed, in the destination directory rather than a temp
            // volume: a move within one filesystem is a rename, and a rename is the
            // only way the destination path never exists half-written.
            let temp = folder.appendingPathComponent(
                ".lumen-ingest-" + UUID().uuidString + ".part", isDirectory: false)
            guard fm.createFile(atPath: temp.path, contents: nil),
                  let handle = try? FileHandle(forWritingTo: temp) else {
                try? fm.removeItem(at: temp)
                results.append(verdict(destination.url, landing, destination.role,
                                       .failed(.unwritableDestination(
                                           "could not open " + temp.lastPathComponent
                                           + " for writing"))))
                continue
            }
            writers.append(Writer(planned: destination.url, final: landing, temp: temp,
                                  handle: handle, role: destination.role))
        }

        // Everything was already present, or every destination failed before a byte
        // moved. Either way there is nothing to read the card for.
        guard !writers.isEmpty else {
            return FrameOutcome(results: results, cancelled: false)
        }

        var digest = XXH64Stream()
        var bytes: Int64 = 0
        var live = writers
        var readFailure: String?
        var stopped = false

        while true {
            if cancellation.isCancelled { stopped = true; break }
            var chunk: Data?
            do {
                chunk = try reader.read(upToCount: chunkSize)
            } catch let error {
                readFailure = error.localizedDescription
                break
            }
            guard let chunk, !chunk.isEmpty else { break }
            digest.update(chunk)
            bytes += Int64(chunk.count)
            var surviving: [Writer] = []
            for writer in live {
                do {
                    try writer.handle.write(contentsOf: chunk)
                    surviving.append(writer)
                } catch let error {
                    // This destination is gone — a full volume, a card pulled out of
                    // the other slot. The others keep receiving the same read.
                    try? writer.handle.close()
                    try? fm.removeItem(at: writer.temp)
                    results.append(verdict(writer.planned, writer.final, writer.role,
                                           .failed(.unwritableDestination(
                                               error.localizedDescription))))
                }
            }
            live = surviving
            if live.isEmpty { break }
            onChunk(Int64(chunk.count))
        }

        for writer in live { try? writer.handle.close() }

        if stopped || readFailure != nil {
            for writer in live {
                try? fm.removeItem(at: writer.temp)
                if let readFailure {
                    results.append(verdict(writer.planned, writer.final, writer.role,
                                           .failed(.unreadableSource(readFailure))))
                }
                // Cancelled: no verdict at all. The frame was not copied and not
                // failed — it was not attempted to a conclusion, and its `.part` is
                // gone, so the destination holds exactly the frames that finished.
            }
            return FrameOutcome(results: results, cancelled: stopped)
        }

        let inFlight = IngestDigest(hex: digest.hexDigest(), byteCount: bytes)

        // THE FRAME HAS TO BE THE SIZE THE CARD SAID IT WAS.
        //
        // Without this the verification is self-referential: it hashes what the read
        // returned and compares it to what landed, which proves the copy equals the
        // READ and never that the read was the whole file. A source that ends early
        // and cleanly — a dying reader returning a premature EOF, a card swapped at the
        // same mount path after the scan, a camera still flushing — sails through as
        // "every copy verified", and `allVerified` is what unlocks the eject button.
        // That is the one failure this whole subsystem exists to prevent, and the
        // number needed to catch it was already in hand: `copy.byteCount` is what the
        // scan recorded and what the sheet showed the photographer.
        //
        // Fails every destination rather than the frame quietly: each volume holds a
        // short file, and none of them may be counted as ingested.
        if bytes != copy.byteCount {
            let planned = IngestDigest(hex: "", byteCount: copy.byteCount)
            for writer in live {
                try? fm.removeItem(at: writer.temp)
                results.append(verdict(writer.planned, writer.final, writer.role,
                                       .failed(.shortRead(expected: copy.byteCount,
                                                          read: bytes))))
                _ = planned
            }
            return FrameOutcome(results: results, cancelled: false)
        }

        for writer in live {
            let installedOwner = InstalledOwnership.read(writer.temp)
            var landed = writer.final
            do {
                // The window between planning the name and finishing the bytes is long
                // enough for something else to take it. `moveItem` refuses to
                // overwrite, so this is belt and braces rather than the only guard.
                if fm.fileExists(atPath: landed.path) {
                    landed = ExportRecipe.disambiguated(landed) { fm.fileExists(atPath: $0.path) }
                }
                try fm.moveItem(at: writer.temp, to: landed)
            } catch let error {
                try? fm.removeItem(at: writer.temp)
                results.append(verdict(writer.planned, writer.final, writer.role,
                                       .failed(.unwritableDestination(error.localizedDescription))))
                continue
            }

            guard verify else {
                results.append(verdict(writer.planned, landed, writer.role, .copied(inFlight)))
                continue
            }

            guard let installedOwner, InstalledOwnership.read(landed) == installedOwner,
                  let generation = SourceFileIdentity.read(landed) else {
                results.append(verdict(writer.planned, landed, writer.role, .failed(.destinationChanged)))
                continue
            }
            let found: IngestDigest
            do {
                found = try readback.digest(of: landed, chunkSize: chunkSize)
            } catch let error {
                let failure = cleanupUnverifiedCopy(at: landed, owner: installedOwner,
                    failure: .unreadableCopy(error.localizedDescription))
                results.append(verdict(writer.planned, landed, writer.role, .failed(failure)))
                continue
            }
            guard InstalledOwnership.read(landed) == installedOwner else {
                results.append(verdict(writer.planned, landed, writer.role, .failed(.destinationChanged)))
                continue
            }
            guard found == inFlight else {
                // Attempt removal; if the volume became unwritable, explicitly report
                // the retained unusable file rather than claiming it was deleted.
                let failure = cleanupUnverifiedCopy(at: landed, owner: installedOwner,
                    failure: .verificationMismatch(expected: inFlight, found: found))
                results.append(verdict(writer.planned, landed, writer.role, .failed(failure)))
                continue
            }
            guard SourceFileIdentity.read(landed) == generation else {
                // Same-inode writes during read-back also invalidate its digest.
                results.append(verdict(writer.planned, landed, writer.role, .failed(.destinationChanged)))
                continue
            }
            results.append(verdict(writer.planned, landed, writer.role, .verified(inFlight)))
        }

        return FrameOutcome(results: results, cancelled: false)
    }
}
