// IngestCopyTests.swift
// The ingest sheet had a Start button that copied nothing.
//
// `IngestDriver`'s only conformer refused every request with "the verified-copy engine
// is not implemented yet", so the one screen that scans a card, sizes it, renders every
// destination path and validates every template stopped exactly where it mattered.
// `VerifiedCopyDriver` is the engine; this is the file that says it works, against real
// files in real temporary directories rather than against a mock filesystem — because
// the failures being defended against (a truncated write, a name already taken, a
// half-written file left behind by a cancel) are filesystem behaviour, and a mock would
// be a second opinion about the thing under test.
//
// The claim each test makes is in its name. The two that matter most:
//   · a copy that does not read back identical is DELETED and reported, and the rest of
//     the card still lands — a card ingest that silently truncates a frame is the worst
//     bug this application can have, because the evidence gets formatted afterwards;
//   · a destination that already holds a different file is never overwritten.

import XCTest
@testable import LumenCore

/// A read-back that lies about one named file.
///
/// No test can ask a filesystem to corrupt a file on demand, so the mismatch path —
/// delete the copy, report it, keep going — is only reachable through the seam the
/// driver already has for reading a landed file back.
private struct LyingReadback: IngestReadback {
    let liesAbout: String

    func digest(of url: URL, chunkSize: Int) throws -> IngestDigest {
        let honest = try IngestFileDigest.digest(of: url, chunkSize: chunkSize)
        guard url.lastPathComponent.contains(liesAbout) else { return honest }
        return IngestDigest(hex: "dead0000beef0000", byteCount: honest.byteCount)
    }
}

final class IngestCopyTests: XCTestCase {

    private var root: URL!
    private var card: URL!
    private var primary: URL!
    private var backup: URL!

    /// 2026-09-02 14:05:06 UTC, so the rendered folder and filename are literals rather
    /// than a re-run of the code under test.
    private var calendar: Calendar!
    private var captureDate: Date!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-ingest-" + UUID().uuidString, isDirectory: true)
        card = root.appendingPathComponent("card", isDirectory: true)
        primary = root.appendingPathComponent("primary", isDirectory: true)
        backup = root.appendingPathComponent("backup", isDirectory: true)
        for directory in [card, primary, backup] {
            try FileManager.default.createDirectory(at: directory!,
                                                    withIntermediateDirectories: true)
        }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        calendar = gregorian
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 2
        components.hour = 14
        components.minute = 5
        components.second = 6
        captureDate = gregorian.date(from: components)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - Fixtures

    /// A frame on the card: `size` bytes that depend on the seed, so two frames are
    /// never accidentally identical and a truncation is never accidentally invisible.
    @discardableResult
    private func frame(_ name: String, size: Int, seed: UInt8 = 1) throws -> URL {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(size)
        var value = seed
        for _ in 0..<size {
            bytes.append(value)
            value = value &* 37 &+ 11
        }
        let url = card.appendingPathComponent(name, isDirectory: false)
        try Data(bytes).write(to: url)
        return url
    }

    private func source(_ url: URL) throws -> IngestSourceFile {
        let size = try Data(contentsOf: url).count
        return IngestSourceFile(url: url, byteCount: Int64(size), captureDate: captureDate)
    }

    private func plan(_ urls: [URL],
                      roots: [IngestDestinationRoot]? = nil,
                      folderTemplate: String = "{year}/{date} {job}",
                      renameTemplate: String? = nil,
                      job: String? = "wedding") throws -> IngestPlan {
        let destinations = roots ?? [IngestDestinationRoot(url: primary, role: .primary)]
        return IngestPlanner.plan(sources: try urls.map { try source($0) },
                                  destinations: destinations,
                                  folderTemplate: folderTemplate,
                                  renameTemplate: renameTemplate,
                                  job: job,
                                  calendar: calendar)
    }

    private func bothVolumes() -> [IngestDestinationRoot] {
        [IngestDestinationRoot(url: primary, role: .primary),
         IngestDestinationRoot(url: backup, role: .backup)]
    }

    private func partFilesUnder(_ directory: URL) -> [String] {
        let enumerator = FileManager.default.enumerator(atPath: directory.path)
        var found: [String] = []
        while let entry = enumerator?.nextObject() as? String {
            if entry.contains(".lumen-ingest-") { found.append(entry) }
        }
        return found
    }

    private func result(_ report: IngestReport, _ name: String,
                        _ role: IngestDestinationRole) -> IngestFileResult? {
        report.results.first { $0.source.lastPathComponent == name && $0.role == role }
    }

    // MARK: - The hash the verification rests on

    /// The streaming digest and the fixture-verified one-shot must agree, at every
    /// length that reaches a different branch of the finaliser and at chunk sizes that
    /// split stripes and 8-byte words. Two implementations of one hash function drift;
    /// this is what notices.
    func testStreamingDigestAgreesWithTheOneShotHash() {
        var lengths = Array(0...80)
        lengths.append(contentsOf: [127, 128, 129, 255, 1000, 4096, 65_537])
        let chunkSizes = [1, 3, 7, 8, 15, 16, 31, 32, 33, 64, 1000, 8192]
        for length in lengths {
            var bytes: [UInt8] = []
            var value: UInt8 = 3
            for _ in 0..<length {
                bytes.append(value)
                value = value &* 61 &+ 7
            }
            let oneShot = XXH64.hexDigest(bytes)
            for chunkSize in chunkSizes {
                var stream = XXH64Stream()
                var index = 0
                while index < bytes.count {
                    let end = min(index + chunkSize, bytes.count)
                    stream.update(Array(bytes[index..<end]))
                    index = end
                }
                XCTAssertEqual(stream.hexDigest(), oneShot,
                               "streamed XXH64 diverged from the one-shot at length "
                               + "\(length), chunk \(chunkSize)")
            }
        }
    }

    // MARK: - The copy

    /// The whole point: bytes land, on every destination, and every one of them is read
    /// back and matched before anything says "ingested".
    func testACopyLandsEveryByteOnEveryDestinationAndVerifies() throws {
        let one = try frame("DSCF0001.RAF", size: 5000, seed: 9)
        let two = try frame("DSCF0002.RAF", size: 33, seed: 40)
        let plan = try plan([one, two], roots: bothVolumes())
        XCTAssertEqual(plan.copies.count, 2)

        var seen: [IngestProgress] = []
        let driver = VerifiedCopyDriver(chunkSize: 512)
        let report = driver.run(plan) { seen.append($0) }

        XCTAssertTrue(report.allVerified, "a clean two-volume ingest did not verify: "
                      + report.summary)
        XCTAssertEqual(report.filesAttempted, 2)
        XCTAssertTrue(report.failures.isEmpty, report.summary)
        XCTAssertEqual(report.summary, "Ingested 2 frames, every copy verified.")

        for volume in [primary!, backup!] {
            let landed = volume.appendingPathComponent("2026/20260902 wedding/DSCF0001.RAF")
            XCTAssertEqual(try Data(contentsOf: landed), try Data(contentsOf: one),
                           "the copy at \(landed.path) is not the frame that was on the card")
        }
        XCTAssertEqual(partFilesUnder(root).count, 0, "a .part file was left behind")

        // Progress has to reach the end, or the sheet's bar stops short of a run that
        // finished.
        XCTAssertEqual(seen.last?.filesCompleted, 2)
        XCTAssertEqual(seen.last?.bytesCopied, 5033)
        XCTAssertEqual(seen.last?.fraction, 1)
    }

    /// The failure this subsystem exists for. A copy whose read-back does not match is
    /// deleted, reported by name, and does not take the rest of the card down with it.
    func testAVerificationMismatchDeletesTheCopyAndTheBatchCarriesOn() throws {
        let one = try frame("DSCF0001.RAF", size: 900, seed: 5)
        let two = try frame("DSCF0002.RAF", size: 900, seed: 6)
        let three = try frame("DSCF0003.RAF", size: 900, seed: 7)
        let driver = VerifiedCopyDriver(chunkSize: 256,
                                        readback: LyingReadback(liesAbout: "DSCF0002"))
        let report = driver.run(try plan([one, two, three]))

        XCTAssertEqual(report.filesAttempted, 3, "the batch stopped at the bad frame")
        XCTAssertEqual(report.failures.count, 1)
        let mismatched = result(report, "DSCF0002.RAF", .primary)
        guard case .failed(.verificationMismatch) = mismatched?.outcome else {
            return XCTFail("the frame whose read-back disagreed was not reported as a "
                           + "mismatch: " + String(describing: mismatched))
        }
        XCTAssertFalse(report.allVerified, "a run with a mismatch claimed to be verified")

        let folder = primary.appendingPathComponent("2026/20260902 wedding", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("DSCF0002.RAF").path),
            "the copy that failed its read-back was left at the destination, where the "
            + "next run and the photographer will both count it as ingested")
        for good in ["DSCF0001.RAF", "DSCF0003.RAF"] {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: folder.appendingPathComponent(good).path),
                "\(good) did not land — one bad frame aborted the batch")
        }
        XCTAssertTrue(report.summary.contains("DSCF0002.RAF → primary"), report.summary)
        XCTAssertTrue(report.summary.contains("the copy does not match the source"),
                      report.summary)
    }

    // MARK: - Collisions

    /// A different file already at the destination is NEVER overwritten. The frame goes
    /// beside it under a disambiguated name — `ExportRecipe.disambiguated`, the policy
    /// the export path already uses — and the report says how many were renamed.
    func testAnExistingDifferentFileIsNeverOverwritten() throws {
        let one = try frame("DSCF0001.RAF", size: 700, seed: 11)
        let folder = primary.appendingPathComponent("2026/20260902 wedding", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let occupied = folder.appendingPathComponent("DSCF0001.RAF")
        let precious = Data("somebody else's photograph".utf8)
        try precious.write(to: occupied)

        let report = VerifiedCopyDriver(chunkSize: 128).run(try plan([one]))

        XCTAssertEqual(try Data(contentsOf: occupied), precious,
                       "the ingest overwrote a file that was already there")
        let landed = folder.appendingPathComponent("DSCF0001-1.RAF")
        XCTAssertEqual(try Data(contentsOf: landed), try Data(contentsOf: one),
                       "the frame did not land beside the file it collided with")
        XCTAssertEqual(report.renamed.count, 1)
        XCTAssertTrue(report.allVerified, report.summary)
        XCTAssertTrue(report.summary.contains("1 renamed to avoid overwriting"),
                      report.summary)
    }

    /// The same frame already at the destination — a card that was half drained and
    /// re-inserted — is reported as already present and not copied a second time.
    func testTheSameFrameAlreadyThereIsNotCopiedTwice() throws {
        let one = try frame("DSCF0001.RAF", size: 700, seed: 13)
        let first = VerifiedCopyDriver(chunkSize: 128).run(try plan([one]))
        XCTAssertTrue(first.allVerified, first.summary)

        let second = VerifiedCopyDriver(chunkSize: 128).run(try plan([one]))
        XCTAssertEqual(second.alreadyPresent.count, 1,
                       "re-ingesting the same card copied the frame again: " + second.summary)
        XCTAssertEqual(second.renamed.count, 0,
                       "re-ingesting the same card made a second copy under a new name")
        XCTAssertTrue(second.allVerified,
                      "a frame proven identical on disk does not count as ingested")
        let folder = primary.appendingPathComponent("2026/20260902 wedding", isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(entries, ["DSCF0001.RAF"], "the destination holds \(entries)")
    }

    /// A TRUNCATED file at the destination is not the frame, whatever it is called.
    /// This is the one the size check exists for: it is exactly what a half-finished
    /// earlier ingest leaves behind, and skipping it would bless a broken photograph.
    func testATruncatedFileAtTheDestinationIsNotMistakenForTheFrame() throws {
        let one = try frame("DSCF0001.RAF", size: 700, seed: 17)
        let folder = primary.appendingPathComponent("2026/20260902 wedding", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stub = folder.appendingPathComponent("DSCF0001.RAF")
        try Data(try Data(contentsOf: one).prefix(300)).write(to: stub)

        let report = VerifiedCopyDriver(chunkSize: 128).run(try plan([one]))

        XCTAssertEqual(report.alreadyPresent.count, 0,
                       "a truncated file was accepted as the frame already being there")
        XCTAssertEqual(try Data(contentsOf: stub).count, 300, "the stub was overwritten")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("DSCF0001-1.RAF")),
                       try Data(contentsOf: one),
                       "the whole frame did not land beside the truncated stub")
    }

    // MARK: - Cancel

    /// Stop means stop, and it leaves nothing half-written: the frames that finished are
    /// on disk whole, the one that was interrupted is not there at all, and no `.part`
    /// file survives to be mistaken for a photograph.
    func testCancelStopsTheRunAndLeavesNothingHalfWritten() throws {
        let one = try frame("DSCF0001.RAF", size: 400, seed: 21)
        let two = try frame("DSCF0002.RAF", size: 400_000, seed: 22)
        let three = try frame("DSCF0003.RAF", size: 400, seed: 23)
        let stop = IngestCancellation()
        let driver = VerifiedCopyDriver(chunkSize: 64)

        let report = driver.run(try plan([one, two, three]), cancellation: stop) { progress in
            if progress.filesCompleted >= 1 { stop.cancel() }
        }

        XCTAssertTrue(report.wasCancelled, "the run did not report that it was stopped")
        XCTAssertEqual(report.filesAttempted, 1,
                       "cancel did not stop the run: \(report.filesAttempted) frames were "
                       + "attempted")
        let folder = primary.appendingPathComponent("2026/20260902 wedding", isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(entries, ["DSCF0001.RAF"],
                       "a cancelled run left \(entries) at the destination")
        XCTAssertEqual(partFilesUnder(root), [],
                       "a cancelled run left a half-written .part file behind")
        XCTAssertFalse(report.allVerified, "a cancelled run offered to eject the card")
        XCTAssertTrue(report.summary.contains("Stopped after 1 of 3 frames"), report.summary)
    }

    // MARK: - Per-file and per-destination failure

    /// One frame the card will not give up must cost exactly one frame. The card going
    /// bad in the middle is the moment the other 339 frames matter most.
    func testAnUnreadableFrameFailsAloneAndTheBatchCarriesOn() throws {
        let one = try frame("DSCF0001.RAF", size: 500, seed: 31)
        let two = try frame("DSCF0002.RAF", size: 500, seed: 32)
        let three = try frame("DSCF0003.RAF", size: 500, seed: 33)
        let plan = try plan([one, two, three])
        // Planned while it was there, gone by the time the copy reaches it — which is
        // what a card with a bad block does to a scan that already finished.
        try FileManager.default.removeItem(at: two)

        let report = VerifiedCopyDriver(chunkSize: 128).run(plan)

        XCTAssertEqual(report.filesAttempted, 3, "the batch stopped at the unreadable frame")
        XCTAssertEqual(report.failures.count, 1)
        let unreadable = result(report, "DSCF0002.RAF", .primary)
        guard case .failed(.unreadableSource) = unreadable?.outcome else {
            return XCTFail("the unreadable frame was not reported as unreadable")
        }
        let folder = primary.appendingPathComponent("2026/20260902 wedding", isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(entries, ["DSCF0001.RAF", "DSCF0003.RAF"],
                       "one unreadable frame took others with it: \(entries)")
        XCTAssertFalse(report.allVerified)
    }

    /// A backup volume that cannot be written does not mark the primary unverified —
    /// docs/10 §10.7: "each destination verifies independently".
    func testABackupThatCannotBeWrittenDoesNotStopThePrimary() throws {
        let one = try frame("DSCF0001.RAF", size: 600, seed: 41)
        // A regular file where the backup volume's folder has to be created: the
        // directory cannot be made, so every write under it fails.
        let blocked = root.appendingPathComponent("blocked", isDirectory: false)
        try Data("not a directory".utf8).write(to: blocked)
        let roots = [IngestDestinationRoot(url: primary, role: .primary),
                     IngestDestinationRoot(url: blocked, role: .backup)]

        let report = VerifiedCopyDriver(chunkSize: 128).run(try plan([one], roots: roots))

        XCTAssertEqual(result(report, "DSCF0001.RAF", .primary)?.isProven, true,
                       "a failing backup marked the primary unverified: " + report.summary)
        XCTAssertNotNil(result(report, "DSCF0001.RAF", .backup)?.failure,
                        "the backup that could not be written reported no failure")
        XCTAssertEqual(try Data(contentsOf: primary.appendingPathComponent(
            "2026/20260902 wedding/DSCF0001.RAF")), try Data(contentsOf: one))
        XCTAssertFalse(report.allVerified, "eject was offered with a backup that failed")
    }

    // MARK: - The plan

    /// The path the sheet previews and the path the copy writes come from one place.
    func testThePlanRendersFoldersPerComponentAndNamesFilesBySequence() throws {
        let one = try frame("DSCF0001.RAF", size: 10, seed: 51)
        let two = try frame("DSCF0002.RAF", size: 10, seed: 52)
        let plan = try plan([one, two], renameTemplate: "{date}-{seq:4}-{orig}")

        XCTAssertEqual(plan.copies[0].destinations[0].url.path,
                       primary.appendingPathComponent(
                        "2026/20260902 wedding/20260902-0001-DSCF0001.RAF").path)
        XCTAssertEqual(plan.copies[1].destinations[0].url.lastPathComponent,
                       "20260902-0002-DSCF0002.RAF")
        XCTAssertTrue(plan.refusals.isEmpty)
    }

    /// A filename template that renders nothing refuses that file by name rather than
    /// writing to the DIRECTORY (J3-02), and the rest of the card still lands.
    func testAFilenameTemplateThatRendersNothingRefusesTheFileRatherThanTheFolder() throws {
        let one = try frame("DSCF0001.RAF", size: 40, seed: 61)
        let plan = try plan([one], renameTemplate: "{job}", job: nil)

        XCTAssertTrue(plan.copies.isEmpty, "a frame was planned with no usable name")
        XCTAssertEqual(plan.refusals.count, 1)
        let report = VerifiedCopyDriver().run(plan)
        XCTAssertFalse(report.allVerified,
                       "a run that refused a frame still offered to eject the card")
        XCTAssertTrue(report.summary.contains("refused"), report.summary)
    }

    /// A folder template that renders `..` does not climb out of the destination the
    /// open panel granted.
    func testAFolderTemplateCannotClimbOutOfTheDestination() throws {
        let one = try frame("DSCF0001.RAF", size: 40, seed: 71)
        let plan = try plan([one], folderTemplate: "{job}/{year}", job: "..")

        let planned = plan.copies[0].destinations[0].url
        XCTAssertFalse(planned.path.contains(".."),
                       "the planned path climbs out of the destination: \(planned.path)")
        XCTAssertEqual(planned.path,
                       primary.appendingPathComponent("2026/DSCF0001.RAF").path)
    }

    // MARK: - What eject is allowed to ask

    /// Eject is offered on one condition only: every frame proven on every destination.
    func testAnUnverifiedRunNeverClaimsToBeVerified() throws {
        let one = try frame("DSCF0001.RAF", size: 200, seed: 81)
        let report = VerifiedCopyDriver(verify: false, chunkSize: 64).run(try plan([one]))

        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertFalse(report.allVerified,
                       "a copy nobody read back was offered as verified")
        XCTAssertTrue(report.summary.contains("UNVERIFIED"), report.summary)
    }
}
