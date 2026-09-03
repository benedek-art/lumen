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
public struct IngestProgress: Sendable, Equatable {
    public var filesCompleted: Int
    public var filesTotal: Int
    public var bytesCopied: Int64
    public var bytesTotal: Int64
    /// The file being read right now, by name — the path is not what a photographer
    /// watching a card drain is reading.
    public var currentFile: String?

    public init(filesCompleted: Int, filesTotal: Int, bytesCopied: Int64,
                bytesTotal: Int64, currentFile: String?) {
        self.filesCompleted = filesCompleted
        self.filesTotal = filesTotal
        self.bytesCopied = bytesCopied
        self.bytesTotal = bytesTotal
        self.currentFile = currentFile
    }

    /// 0…1, by bytes where there are any and by file count otherwise.
    public var fraction: Double {
        if bytesTotal > 0 { return min(1, Double(bytesCopied) / Double(bytesTotal)) }
        guard filesTotal > 0 else { return 0 }
        return min(1, Double(filesCompleted) / Double(filesTotal))
    }
}

public enum IngestCopyFailure: Sendable, Equatable {
    case unreadableSource(String)
    case unwritableDestination(String)
    case unreadableCopy(String)
    case verificationMismatch(expected: IngestDigest, found: IngestDigest)

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
    public var bytesCopied: Int64

    public init(results: [IngestFileResult], refusals: [String], wasCancelled: Bool,
                filesAttempted: Int, filesPlanned: Int, bytesCopied: Int64) {
        self.results = results
        self.refusals = refusals
        self.wasCancelled = wasCancelled
        self.filesAttempted = filesAttempted
        self.filesPlanned = filesPlanned
        self.bytesCopied = bytesCopied
    }

    public var failures: [IngestFileResult] { results.filter { $0.failure != nil } }
    public var renamed: [IngestFileResult] { results.filter(\.wasRenamed) }
    public var alreadyPresent: [IngestFileResult] {
        results.filter { if case .alreadyPresent = $0.outcome { return true } else { return false } }
    }

    /// Every planned frame is on every planned destination, and every one of those was
    /// read back and matched. This — and nothing weaker — is what may offer eject.
    public var allVerified: Bool {
        !wasCancelled
            && refusals.isEmpty
            && filesAttempted == filesPlanned
            && !results.isEmpty
            && results.allSatisfy(\.isProven)
    }

    /// One line, true, and specific enough to act on.
    ///
    /// The noun agrees with the count it is attached to, which is not fussiness: "1 of 3
    /// frame" is the sentence a photographer reads at the moment they are deciding
    /// whether the card is safe to reuse, and a status line that cannot count does not
    /// invite trust in the count.
    public var summary: String {
        let attemptedWord = filesAttempted == 1 ? "frame" : "frames"
        let plannedWord = filesPlanned == 1 ? "frame" : "frames"
        var sentence: String
        if wasCancelled {
            sentence = "Stopped after \(filesAttempted) of \(filesPlanned) \(plannedWord) — "
                + "nothing was left half-written."
        } else if filesAttempted == 0 && failures.isEmpty {
            sentence = "Nothing was copied."
        } else if failures.isEmpty {
            sentence = "Ingested \(filesAttempted) \(attemptedWord)"
                + (allVerified ? ", every copy verified." : ", UNVERIFIED.")
        } else {
            // Name the first failure. "2 failed" leaves a photographer with no way to
            // tell a full disk from a card going bad, and that is the whole decision.
            let first = failures[0]
            sentence = "Ingested \(filesAttempted) of \(filesPlanned) \(plannedWord) — "
                + "\(failures.count) failed — " + first.label + ": "
                + (first.failure?.message ?? "")
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
        var bytesCopied: Int64 = 0
        var cancelled = false
        let total = plan.totalBytes

        for copy in plan.copies {
            if cancellation.isCancelled { cancelled = true; break }
            let name = copy.source.lastPathComponent
            progress?(IngestProgress(filesCompleted: attempted, filesTotal: plan.copies.count,
                                     bytesCopied: bytesCopied, bytesTotal: total,
                                     currentFile: name))
            var readSoFar: Int64 = 0
            let outcome = perform(copy, cancellation: cancellation) { chunk in
                readSoFar += chunk
                progress?(IngestProgress(filesCompleted: attempted,
                                         filesTotal: plan.copies.count,
                                         bytesCopied: bytesCopied + readSoFar,
                                         bytesTotal: total, currentFile: name))
            }
            results.append(contentsOf: outcome.results)
            if outcome.cancelled {
                cancelled = true
                break
            }
            attempted += 1
            bytesCopied += copy.byteCount
            progress?(IngestProgress(filesCompleted: attempted, filesTotal: plan.copies.count,
                                     bytesCopied: bytesCopied, bytesTotal: total,
                                     currentFile: name))
        }

        return IngestReport(results: results, refusals: plan.refusals,
                            wasCancelled: cancelled, filesAttempted: attempted,
                            filesPlanned: plan.copies.count, bytesCopied: bytesCopied)
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
                         onChunk: (Int64) -> Void) -> FrameOutcome {
        let fm = FileManager.default
        var results: [IngestFileResult] = []

        func verdict(_ planned: URL, _ landed: URL, _ role: IngestDestinationRole,
                     _ outcome: IngestCopyOutcome) -> IngestFileResult {
            IngestFileResult(source: copy.source, plannedDestination: planned,
                             destination: landed, role: role, outcome: outcome)
        }

        let reader: FileHandle
        do {
            reader = try FileHandle(forReadingFrom: copy.source)
        } catch {
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
        for destination in copy.destinations {
            let folder = destination.url.deletingLastPathComponent()
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                results.append(verdict(destination.url, destination.url, destination.role,
                                       .failed(.unwritableDestination(error.localizedDescription))))
                continue
            }

            var landing = destination.url
            if fm.fileExists(atPath: destination.url.path) {
                // Already there. Either it is this frame — a card that was half
                // drained, re-inserted — or it is a different frame that rendered to
                // the same name. The bytes decide, never the name.
                if let existing = try? IngestFileDigest.digest(of: destination.url,
                                                               chunkSize: chunkSize),
                   let mine = digestOfSource(), existing == mine {
                    results.append(verdict(destination.url, destination.url, destination.role,
                                           .alreadyPresent(existing)))
                    continue
                }
                landing = ExportRecipe.disambiguated(destination.url) {
                    fm.fileExists(atPath: $0.path)
                }
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
            } catch {
                readFailure = error.localizedDescription
                break
            }
            guard let chunk, !chunk.isEmpty else { break }
            digest.update(chunk)
            bytes += Int64(chunk.count)
            var surviving: [Writer] = []
            for writer in live {
                do {
                    if bytes < 0 { try writer.handle.write(contentsOf: chunk) }
                    surviving.append(writer)
                } catch {
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

        for writer in live {
            var landed = writer.final
            do {
                // The window between planning the name and finishing the bytes is long
                // enough for something else to take it. `moveItem` refuses to
                // overwrite, so this is belt and braces rather than the only guard.
                if fm.fileExists(atPath: landed.path) {
                    landed = ExportRecipe.disambiguated(landed) { fm.fileExists(atPath: $0.path) }
                }
                try fm.moveItem(at: writer.temp, to: landed)
            } catch {
                try? fm.removeItem(at: writer.temp)
                results.append(verdict(writer.planned, writer.final, writer.role,
                                       .failed(.unwritableDestination(error.localizedDescription))))
                continue
            }

            guard verify else {
                results.append(verdict(writer.planned, landed, writer.role, .copied(inFlight)))
                continue
            }

            let found: IngestDigest
            do {
                found = try readback.digest(of: landed, chunkSize: chunkSize)
            } catch {
                try? fm.removeItem(at: landed)
                results.append(verdict(writer.planned, landed, writer.role,
                                       .failed(.unreadableCopy(error.localizedDescription))))
                continue
            }
            guard found == inFlight else {
                // DELETED, not kept. A file that failed its read-back is not evidence
                // of anything, and leaving it at the destination is precisely how a
                // truncated frame gets counted as ingested by the next run and by the
                // photographer about to format the card.
                try? fm.removeItem(at: landed)
                results.append(verdict(writer.planned, landed, writer.role,
                                       .failed(.verificationMismatch(expected: inFlight,
                                                                     found: found))))
                continue
            }
            results.append(verdict(writer.planned, landed, writer.role, .verified(inFlight)))
        }

        return FrameOutcome(results: results, cancelled: false)
    }
}
