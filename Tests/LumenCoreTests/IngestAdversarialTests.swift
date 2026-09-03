// IngestAdversarialTests.swift
// An attempt to BREAK the card-ingest driver, not to confirm it.
//
// The suite that shipped with `VerifiedCopyDriver` was green while the engine copied
// zero bytes, because nothing in it compared the LANDED file against the SOURCE byte
// for byte independently of the engine's own verification step. Every test here starts
// from that lesson: the landed bytes are read off disk with Foundation and compared to
// the source bytes with Foundation, and the report is treated as a claim to be checked
// rather than as evidence.

import XCTest
@testable import LumenCore

/// A read-back that returns the truth about a file's bytes but lies about its length.
/// The question it asks: does the verdict rest on the hash alone, or on the length too?
/// Progress events, collected off whichever thread the driver reports on.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [IngestProgress] = []
    func append(_ event: IngestProgress) {
        lock.lock(); events.append(event); lock.unlock()
    }
    var last: IngestProgress? {
        lock.lock(); defer { lock.unlock() }; return events.last
    }
}

private struct ShortCountReadback: IngestReadback {
    func digest(of url: URL, chunkSize: Int) throws -> IngestDigest {
        let honest = try IngestFileDigest.digest(of: url, chunkSize: chunkSize)
        return IngestDigest(hex: honest.hex, byteCount: honest.byteCount - 1)
    }
}

final class IngestAdversarialTests: XCTestCase {

    private var root: URL!
    private var card: URL!
    private var primary: URL!
    private var backup: URL!
    private var calendar: Calendar!
    private var captureDate: Date!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("lumen-adv-" + UUID().uuidString, isDirectory: true)
        card = root.appendingPathComponent("card", isDirectory: true)
        primary = root.appendingPathComponent("primary", isDirectory: true)
        backup = root.appendingPathComponent("backup", isDirectory: true)
        for directory in [card, primary, backup] {
            try fm.createDirectory(at: directory!, withIntermediateDirectories: true)
        }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        calendar = gregorian
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 2
        components.hour = 14; components.minute = 5; components.second = 6
        captureDate = gregorian.date(from: components)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
    }

    // MARK: - Fixtures

    @discardableResult
    private func frame(_ name: String, size: Int, seed: UInt8 = 1) throws -> URL {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(size)
        var value = seed &+ 1
        for _ in 0..<size {
            bytes.append(value)
            value = value &* 37 &+ 11
        }
        let url = card.appendingPathComponent(name, isDirectory: false)
        try Data(bytes).write(to: url)
        return url
    }

    private func source(_ url: URL) throws -> IngestSourceFile {
        let size = (try? Data(contentsOf: url).count) ?? 0
        return IngestSourceFile(url: url, byteCount: Int64(size), captureDate: captureDate)
    }

    private func plan(_ urls: [URL],
                      roots: [IngestDestinationRoot]? = nil,
                      folderTemplate: String = "{year}",
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

    private func leftovers(_ directory: URL) -> [String] {
        let enumerator = fm.enumerator(atPath: directory.path)
        var found: [String] = []
        while let entry = enumerator?.nextObject() as? String {
            if entry.contains(".lumen-ingest-") { found.append(entry) }
        }
        return found
    }

    private func filesUnder(_ directory: URL) -> [String] {
        let enumerator = fm.enumerator(atPath: directory.path)
        var found: [String] = []
        while let entry = enumerator?.nextObject() as? String {
            var isDir: ObjCBool = false
            let full = directory.appendingPathComponent(entry).path
            if fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue {
                found.append(entry)
            }
        }
        return found.sorted()
    }

    /// The only comparison that matters: the file the photographer will open, against
    /// the file that came off the card, byte for byte, read independently of the engine.
    private func assertLandedMatchesSource(_ source: URL, _ landed: URL,
                                           _ what: String,
                                           file: StaticString = #filePath,
                                           line: UInt = #line) throws {
        guard fm.fileExists(atPath: landed.path) else {
            XCTFail("\(what): nothing landed at \(landed.path)", file: file, line: line)
            return
        }
        let want = try Data(contentsOf: source)
        let got = try Data(contentsOf: landed)
        XCTAssertEqual(got.count, want.count,
                       "\(what): landed \(got.count) bytes, source has \(want.count)",
                       file: file, line: line)
        XCTAssertEqual(got, want, "\(what): landed bytes differ from the source",
                       file: file, line: line)
    }

    // MARK: - Truncation and awkward lengths

    /// Every length that can fall on, either side of, and far past a chunk boundary —
    /// each one copied and then compared to the source outside the engine.
    func testLandedBytesEqualSourceBytesAtEveryAwkwardLength() throws {
        let chunk = 64
        let lengths = [0, 1, 2, 63, 64, 65, 127, 128, 129, 191, 192, 193, 4095, 4096, 4097]
        for (index, length) in lengths.enumerated() {
            let name = String(format: "AWK%04d.RAF", index)
            let url = try frame(name, size: length, seed: UInt8(index &+ 3))
            let report = VerifiedCopyDriver(chunkSize: chunk).run(try plan([url]))
            XCTAssertTrue(report.allVerified,
                          "length \(length) did not verify: " + report.summary)
            let landed = primary.appendingPathComponent("2026/" + name)
            try assertLandedMatchesSource(url, landed, "length \(length)")
            XCTAssertEqual(leftovers(primary), [], "length \(length) left a .part behind")
        }
    }

    /// A frame larger than any buffer the engine allocates, at the shipping chunk size.
    func testAFrameLargerThanTheDefaultChunkLandsWhole() throws {
        let size = (4 << 20) + 12_345          // one default chunk plus a ragged tail
        let url = try frame("BIG0001.RAF", size: size, seed: 9)
        let report = VerifiedCopyDriver().run(try plan([url], roots: bothVolumes()))
        XCTAssertTrue(report.allVerified, report.summary)
        try assertLandedMatchesSource(url, primary.appendingPathComponent("2026/BIG0001.RAF"),
                                      "big frame, primary")
        try assertLandedMatchesSource(url, backup.appendingPathComponent("2026/BIG0001.RAF"),
                                      "big frame, backup")
        XCTAssertEqual(report.bytesCopied, Int64(size))
    }

    /// A zero-byte file is still a file on the card. It must land, and land empty.
    func testAZeroByteFrameLandsAndIsNotSilentlySkipped() throws {
        let url = try frame("EMPTY001.RAF", size: 0)
        let report = VerifiedCopyDriver(chunkSize: 16).run(try plan([url]))
        XCTAssertTrue(report.allVerified, report.summary)
        let landed = primary.appendingPathComponent("2026/EMPTY001.RAF")
        XCTAssertTrue(fm.fileExists(atPath: landed.path), "the empty frame did not land")
        try assertLandedMatchesSource(url, landed, "zero-byte frame")
    }

    // MARK: - Does the length travel with the hash?

    /// The read-back tells the truth about the bytes and lies about the length by one.
    /// If the verdict rests on the hash alone, this passes verification.
    func testAOneByteLieAboutTheLengthIsCaught() throws {
        let url = try frame("LEN0001.RAF", size: 300)
        let driver = VerifiedCopyDriver(chunkSize: 64, readback: ShortCountReadback())
        let report = driver.run(try plan([url]))
        XCTAssertFalse(report.allVerified,
                       "a read-back that mis-stated the landed length still verified")
        XCTAssertEqual(report.failures.count, 1, report.summary)
    }

    /// THE ATTACK: the frame shrinks between the moment the card is scanned (which is
    /// where the plan's byte count comes from) and the moment it is read. The engine
    /// hashes what it managed to read and compares it with what landed — both agree,
    /// because both are the truncated file. Nothing compares either of them with the
    /// length the plan said this frame was.
    func testAFrameThatShrinksAfterThePlanIsNotReportedAsShort() throws {
        XCTExpectFailure("A FINDING from adversarial verification, recorded rather than silenced. It runs and prints its real numbers on every lane; only the red is suppressed. The day it is fixed this becomes an unexpected pass and asks to be deleted.")
        let url = try frame("SHRINK01.RAF", size: 5_000, seed: 4)
        let plan = try plan([url])                       // plan records 5000 bytes
        try Data([UInt8](repeating: 7, count: 100)).write(to: url)   // card now returns 100
        let report = VerifiedCopyDriver(chunkSize: 64).run(plan)

        let landed = primary.appendingPathComponent("2026/SHRINK01.RAF")
        let landedSize = (try? Data(contentsOf: landed).count) ?? -1
        XCTAssertFalse(report.allVerified,
                       "a frame that was 5000 bytes in the plan landed as \(landedSize) "
                       + "bytes and the run still offered eject: " + report.summary)
        XCTAssertEqual(report.bytesCopied, Int64(landedSize),
                       "the report claims \(report.bytesCopied) bytes copied, "
                       + "\(landedSize) bytes are on disk")
    }

    // MARK: - The report's arithmetic

    /// A frame already on disk is not copied. The byte counter must not say it was.
    func testBytesCopiedDoesNotCountFramesThatWereAlreadyPresent() throws {
        XCTExpectFailure("A FINDING from adversarial verification, recorded rather than silenced. It runs and prints its real numbers on every lane; only the red is suppressed. The day it is fixed this becomes an unexpected pass and asks to be deleted.")
        let one = try frame("DUP00001.RAF", size: 900, seed: 2)
        let first = VerifiedCopyDriver(chunkSize: 128).run(try plan([one]))
        XCTAssertTrue(first.allVerified, first.summary)
        let second = VerifiedCopyDriver(chunkSize: 128).run(try plan([one]))
        XCTAssertEqual(second.alreadyPresent.count, 1, second.summary)
        XCTAssertEqual(second.bytesCopied, 0,
                       "nothing was copied, and the report says \(second.bytesCopied) "
                       + "bytes were: " + second.summary)
    }

    /// A frame the card would not give up moves no bytes anywhere. The byte counter
    /// must not say it did.
    func testBytesCopiedDoesNotCountAFrameThatFailedEverywhere() throws {
        XCTExpectFailure("A FINDING from adversarial verification, recorded rather than silenced. It runs and prints its real numbers on every lane; only the red is suppressed. The day it is fixed this becomes an unexpected pass and asks to be deleted.")
        let good = try frame("OK000001.RAF", size: 400, seed: 5)
        let bad = card.appendingPathComponent("BAD00001.RAF", isDirectory: false)
        try Data([UInt8](repeating: 3, count: 7_000)).write(to: bad)
        var sources = [try source(good), try source(bad)]
        sources[1] = IngestSourceFile(url: bad, byteCount: 7_000, captureDate: captureDate)
        let plan = IngestPlanner.plan(sources: sources,
                                      destinations: [IngestDestinationRoot(url: primary,
                                                                           role: .primary)],
                                      folderTemplate: "{year}", renameTemplate: nil,
                                      job: nil, calendar: calendar)
        try fm.removeItem(at: bad)      // the card cannot read it back
        let report = VerifiedCopyDriver(chunkSize: 64).run(plan)
        XCTAssertEqual(report.failures.count, 1, report.summary)
        XCTAssertEqual(report.bytesCopied, 400,
                       "one 400-byte frame landed; the report claims "
                       + "\(report.bytesCopied) bytes: " + report.summary)
    }

    /// A run that was stopped AND had a destination fail says only that it was stopped.
    func testACancelledRunStillNamesTheDestinationThatFailed() throws {
        XCTExpectFailure("A FINDING from adversarial verification, recorded rather than silenced. It runs and prints its real numbers on every lane; only the red is suppressed. The day it is fixed this becomes an unexpected pass and asks to be deleted.")
        // The backup root is a regular file, so every backup write fails.
        let blocked = root.appendingPathComponent("blocked", isDirectory: true)
        try Data("not a directory".utf8).write(to: blocked)
        let roots = [IngestDestinationRoot(url: primary, role: .primary),
                     IngestDestinationRoot(url: blocked, role: .backup)]
        let one = try frame("STOP0001.RAF", size: 300, seed: 6)
        let two = try frame("STOP0002.RAF", size: 300, seed: 7)
        let plan = try plan([one, two], roots: roots)
        let cancellation = IngestCancellation()
        let report = VerifiedCopyDriver(chunkSize: 64).run(plan, cancellation: cancellation) { p in
            if p.filesCompleted >= 1 { cancellation.cancel() }
        }
        XCTAssertTrue(report.wasCancelled, report.summary)
        XCTAssertFalse(report.failures.isEmpty, "the blocked backup produced no failure")
        XCTAssertTrue(report.summary.contains("failed") || report.summary.contains("backup"),
                      "a stopped run with a failed destination reported only: "
                      + report.summary)
    }

    /// `allVerified` is what unlocks eject. A frame with nowhere to go is not verified.
    func testAFrameWithNoDestinationCannotCountAsVerified() throws {
        XCTExpectFailure("A FINDING from adversarial verification, recorded rather than silenced. It runs and prints its real numbers on every lane; only the red is suppressed. The day it is fixed this becomes an unexpected pass and asks to be deleted.")
        let one = try frame("NODEST01.RAF", size: 200, seed: 8)
        let plan = IngestPlanner.plan(sources: [try source(one)],
                                      destinations: [],
                                      folderTemplate: "{year}", renameTemplate: nil,
                                      job: nil, calendar: calendar)
        let report = VerifiedCopyDriver(chunkSize: 64).run(plan)
        XCTAssertFalse(report.allVerified,
                       "a frame that was written nowhere reported: " + report.summary)
        XCTAssertEqual(report.bytesCopied, 0,
                       "nothing was written anywhere and the report claims "
                       + "\(report.bytesCopied) bytes")
    }

    // MARK: - Collisions and re-ingest

    /// Incremental re-ingest, after a first run that had to disambiguate around a
    /// stranger's file. The frame is already on the volume under its `-1` name; a
    /// second run must recognise it rather than land it again.
    func testReIngestAfterADisambiguationDoesNotDuplicateTheFrame() throws {
        XCTExpectFailure("A FINDING from adversarial verification, recorded rather than silenced. It runs and prints its real numbers on every lane; only the red is suppressed. The day it is fixed this becomes an unexpected pass and asks to be deleted.")
        let one = try frame("SAME0001.RAF", size: 700, seed: 11)
        let folder = primary.appendingPathComponent("2026", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        // Somebody else's file is already sitting on the planned name.
        try Data([UInt8](repeating: 200, count: 40))
            .write(to: folder.appendingPathComponent("SAME0001.RAF"))

        let first = VerifiedCopyDriver(chunkSize: 128).run(try plan([one]))
        XCTAssertEqual(first.renamed.count, 1, first.summary)
        try assertLandedMatchesSource(one, folder.appendingPathComponent("SAME0001-1.RAF"),
                                      "first run")

        let second = VerifiedCopyDriver(chunkSize: 128).run(try plan([one]))
        let landedNames = filesUnder(primary)
        XCTAssertEqual(second.alreadyPresent.count, 1,
                       "the frame was already on the volume and the second run "
                       + "reported: " + second.summary)
        XCTAssertEqual(landedNames.count, 2,
                       "after two runs of a one-frame card the volume holds "
                       + "\(landedNames): " + second.summary)
        XCTAssertEqual(second.bytesCopied, 0, second.summary)
    }

    /// Two distinct frames on the card whose template renders them to one name, with
    /// identical bytes. One of them must not simply vanish into the other.
    func testTwoIdenticalFramesUnderOneRenderedNameBothSurvive() throws {
        XCTExpectFailure("A FINDING from adversarial verification, recorded rather than silenced. It runs and prints its real numbers on every lane; only the red is suppressed. The day it is fixed this becomes an unexpected pass and asks to be deleted.")
        let a = try frame("TWIN0001.RAF", size: 500, seed: 21)
        let b = card.appendingPathComponent("TWIN0002.RAF", isDirectory: false)
        try fm.copyItem(at: a, to: b)
        // A template with no per-file token: both frames render to the same name.
        let report = VerifiedCopyDriver(chunkSize: 64)
            .run(try plan([a, b], renameTemplate: "{job}"))
        let landed = filesUnder(primary)
        XCTAssertEqual(landed.count, 2,
                       "two frames were planned and the volume holds \(landed): "
                       + report.summary)
    }

    /// A directory where a frame should be. It must fail, not land as an empty file
    /// that verifies against its own emptiness.
    func testADirectoryInPlaceOfAFrameDoesNotLandAsAnEmptyVerifiedFile() throws {
        let fake = card.appendingPathComponent("DIR00001.RAF", isDirectory: true)
        try fm.createDirectory(at: fake, withIntermediateDirectories: true)
        let plan = IngestPlanner.plan(
            sources: [IngestSourceFile(url: fake, byteCount: 1_000, captureDate: captureDate)],
            destinations: [IngestDestinationRoot(url: primary, role: .primary)],
            folderTemplate: "{year}", renameTemplate: nil, job: nil, calendar: calendar)
        let report = VerifiedCopyDriver(chunkSize: 64).run(plan)
        let landed = primary.appendingPathComponent("2026/DIR00001.RAF")
        let size = (try? Data(contentsOf: landed).count)
        XCTAssertFalse(report.allVerified,
                       "a directory was ingested as a frame (landed size \(size as Any)): "
                       + report.summary)
    }

    // MARK: - Cancellation

    /// Stop the run inside the first frame's own progress, before its last chunk.
    /// Nothing of that frame may remain: no `.part`, no destination file, no verdict.
    func testCancelInsideAFrameLeavesNoTraceOfIt() throws {
        let one = try frame("CAN00001.RAF", size: 4_000, seed: 31)
        let two = try frame("CAN00002.RAF", size: 4_000, seed: 32)
        let cancellation = IngestCancellation()
        let report = VerifiedCopyDriver(chunkSize: 64)
            .run(try plan([one, two], roots: bothVolumes()),
                 cancellation: cancellation) { p in
                     if p.bytesCopied > 500 { cancellation.cancel() }
                 }
        XCTAssertTrue(report.wasCancelled)
        XCTAssertEqual(report.filesAttempted, 0, report.summary)
        XCTAssertEqual(leftovers(primary), [], "a .part survived the cancel on primary")
        XCTAssertEqual(leftovers(backup), [], "a .part survived the cancel on backup")
        XCTAssertEqual(filesUnder(primary), [], "a cancelled frame landed on primary")
        XCTAssertEqual(filesUnder(backup), [], "a cancelled frame landed on backup")
        XCTAssertFalse(report.allVerified)
    }

    /// Stopping between the last byte of one frame and the start of the next must
    /// leave exactly the frames that finished, whole.
    func testCancelBetweenFramesKeepsTheFinishedOnesWhole() throws {
        let one = try frame("BET00001.RAF", size: 1_000, seed: 41)
        let two = try frame("BET00002.RAF", size: 1_000, seed: 42)
        let cancellation = IngestCancellation()
        let report = VerifiedCopyDriver(chunkSize: 128)
            .run(try plan([one, two]), cancellation: cancellation) { p in
                if p.filesCompleted == 1 { cancellation.cancel() }
            }
        XCTAssertTrue(report.wasCancelled)
        XCTAssertEqual(report.filesAttempted, 1, report.summary)
        try assertLandedMatchesSource(one, primary.appendingPathComponent("2026/BET00001.RAF"),
                                      "the frame that finished before the stop")
        XCTAssertFalse(fm.fileExists(atPath: primary
            .appendingPathComponent("2026/BET00002.RAF").path),
            "the frame after the stop landed anyway")
        XCTAssertEqual(leftovers(primary), [])
    }

    // MARK: - Per-file isolation

    /// One unreadable frame in the middle of a batch. The others must land whole, and
    /// the failure must not be attributed to any of them.
    func testAnUnreadableFrameInTheMiddleDoesNotTouchItsNeighbours() throws {
        let a = try frame("ISO00001.RAF", size: 1_500, seed: 51)
        let bad = card.appendingPathComponent("ISO00002.RAF", isDirectory: false)
        try Data([UInt8](repeating: 1, count: 100)).write(to: bad)
        let c = try frame("ISO00003.RAF", size: 2_500, seed: 53)
        var sources = [try source(a), try source(bad), try source(c)]
        _ = sources
        let plan = IngestPlanner.plan(sources: sources,
                                      destinations: bothVolumes(),
                                      folderTemplate: "{year}", renameTemplate: nil,
                                      job: nil, calendar: calendar)
        try fm.removeItem(at: bad)
        let report = VerifiedCopyDriver(chunkSize: 64).run(plan)
        try assertLandedMatchesSource(a, primary.appendingPathComponent("2026/ISO00001.RAF"),
                                      "neighbour before the bad frame, primary")
        try assertLandedMatchesSource(c, backup.appendingPathComponent("2026/ISO00003.RAF"),
                                      "neighbour after the bad frame, backup")
        XCTAssertEqual(report.failures.count, 2, report.summary)   // one per destination
        for failure in report.failures {
            XCTAssertEqual(failure.source.lastPathComponent, "ISO00002.RAF")
        }
        XCTAssertFalse(report.allVerified, report.summary)
        XCTAssertEqual(leftovers(primary), [])
        XCTAssertEqual(leftovers(backup), [])
    }

    /// A destination that appears under the planned name between planning and landing.
    /// The engine has already decided the name; the file arrives while it is copying.
    func testAFileThatAppearsDuringTheCopyIsNotOverwritten() throws {
        let one = try frame("RACE0001.RAF", size: 6_000, seed: 61)
        let folder = primary.appendingPathComponent("2026", isDirectory: true)
        let planned = folder.appendingPathComponent("RACE0001.RAF")
        let intruder = Data([UInt8](repeating: 99, count: 33))
        let report = VerifiedCopyDriver(chunkSize: 64).run(try plan([one])) { p in
            if p.bytesCopied > 1_000, !self.fm.fileExists(atPath: planned.path) {
                try? intruder.write(to: planned)
            }
        }
        XCTAssertEqual(try Data(contentsOf: planned), intruder,
                       "the file that appeared mid-copy was overwritten")
        try assertLandedMatchesSource(one, folder.appendingPathComponent("RACE0001-1.RAF"),
                                      "the frame that had to move aside")
        XCTAssertEqual(leftovers(primary), [], report.summary)
    }

    // MARK: - Second wave

    /// The bar the photographer watches. It must not count bytes that never landed.
    func testTheProgressBarDoesNotCountFramesThatNeverLanded() throws {
        XCTExpectFailure("A FINDING from adversarial verification, recorded rather than silenced. It runs and prints its real numbers on every lane; only the red is suppressed. The day it is fixed this becomes an unexpected pass and asks to be deleted.")
        let good = try frame("PRG00001.RAF", size: 400, seed: 71)
        let bad = card.appendingPathComponent("PRG00002.RAF", isDirectory: false)
        try Data([UInt8](repeating: 3, count: 9_600)).write(to: bad)
        let plan = IngestPlanner.plan(sources: [try source(good), try source(bad)],
                                      destinations: [IngestDestinationRoot(url: primary,
                                                                           role: .primary)],
                                      folderTemplate: "{year}", renameTemplate: nil,
                                      job: nil, calendar: calendar)
        try fm.removeItem(at: bad)
        let seen = ProgressLog()
        let report = VerifiedCopyDriver(chunkSize: 64).run(plan) { seen.append($0) }
        let onDisk = filesUnder(primary).reduce(Int64(0)) {
            $0 + Int64((try? Data(contentsOf: primary.appendingPathComponent($1)).count) ?? 0)
        }
        XCTAssertEqual(seen.last?.bytesCopied, onDisk,
                       "the bar finished at \(seen.last?.bytesCopied ?? -1) bytes with "
                       + "\(onDisk) bytes on the volume: " + report.summary)
        XCTAssertLessThan(seen.last?.fraction ?? 0, 1.0,
                          "the bar reached 100% for a run that lost a frame")
    }

    /// Each further re-ingest of a card whose frame had to be renamed once adds
    /// another whole copy of it.
    func testEveryReIngestOfARenamedFrameAddsAnotherCopy() throws {
        XCTExpectFailure("A FINDING from adversarial verification, recorded rather than silenced. It runs and prints its real numbers on every lane; only the red is suppressed. The day it is fixed this becomes an unexpected pass and asks to be deleted.")
        let one = try frame("GROW0001.RAF", size: 600, seed: 81)
        let folder = primary.appendingPathComponent("2026", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([UInt8](repeating: 17, count: 12))
            .write(to: folder.appendingPathComponent("GROW0001.RAF"))
        for _ in 0..<3 { _ = VerifiedCopyDriver(chunkSize: 128).run(try plan([one])) }
        let landed = filesUnder(primary)
        XCTAssertEqual(landed.count, 2,
                       "three ingests of the same one-frame card left \(landed)")
    }

    /// The eject gate, in the twin case: two frames on the card, one file on the volume.
    func testATwinFrameThatWasAbsorbedDoesNotUnlockEject() throws {
        XCTExpectFailure("A FINDING from adversarial verification, recorded rather than silenced. It runs and prints its real numbers on every lane; only the red is suppressed. The day it is fixed this becomes an unexpected pass and asks to be deleted.")
        let a = try frame("EJT00001.RAF", size: 500, seed: 91)
        let b = card.appendingPathComponent("EJT00002.RAF", isDirectory: false)
        try fm.copyItem(at: a, to: b)
        let report = VerifiedCopyDriver(chunkSize: 64)
            .run(try plan([a, b], renameTemplate: "{job}"))
        XCTAssertFalse(report.allVerified,
                       "two frames on the card, \(filesUnder(primary)) on the volume, "
                       + "and the card may be ejected: " + report.summary)
    }

    /// Two destination roots that are two names for one directory. The photographer is
    /// told they have a primary and a backup; both land in the same place.
    func testTwoRootsThatAreOneDirectoryAreNotReportedAsTwoCopies() throws {
        XCTExpectFailure("A FINDING from adversarial verification, recorded rather than silenced. It runs and prints its real numbers on every lane; only the red is suppressed. The day it is fixed this becomes an unexpected pass and asks to be deleted.")
        let link = root.appendingPathComponent("backup-link", isDirectory: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: primary)
        let roots = [IngestDestinationRoot(url: primary, role: .primary),
                     IngestDestinationRoot(url: link, role: .backup)]
        let one = try frame("LNK00001.RAF", size: 800, seed: 101)
        let report = VerifiedCopyDriver(chunkSize: 64).run(try plan([one], roots: roots))
        let landed = filesUnder(primary)
        XCTAssertEqual(landed.count, 1,
                       "one volume holds \(landed) for a one-frame card: " + report.summary)
        XCTAssertFalse(report.allVerified,
                       "a backup that is the primary reported: " + report.summary)
    }

    /// The sentence a photographer reads when a frame failed.
    func testTheSummaryDoesNotSayItIngestedAFrameThatFailed() throws {
        XCTExpectFailure("A FINDING from adversarial verification, recorded rather than silenced. It runs and prints its real numbers on every lane; only the red is suppressed. The day it is fixed this becomes an unexpected pass and asks to be deleted.")
        let good = try frame("SUM00001.RAF", size: 300, seed: 111)
        let bad = card.appendingPathComponent("SUM00002.RAF", isDirectory: false)
        try Data([UInt8](repeating: 5, count: 300)).write(to: bad)
        let plan = IngestPlanner.plan(sources: [try source(good), try source(bad)],
                                      destinations: [IngestDestinationRoot(url: primary,
                                                                           role: .primary)],
                                      folderTemplate: "{year}", renameTemplate: nil,
                                      job: nil, calendar: calendar)
        try fm.removeItem(at: bad)
        let report = VerifiedCopyDriver(chunkSize: 64).run(plan)
        XCTAssertFalse(report.summary.hasPrefix("Ingested 2 of 2"),
                       "one frame of two landed and the sentence is: " + report.summary)
    }
}
