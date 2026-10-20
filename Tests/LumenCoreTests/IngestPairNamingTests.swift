// IngestPairNamingTests.swift
// A RAW+JPEG pair is one frame, and every tool that pairs the two — Lightroom's import,
// "JPEG next to raw", stacking — does it by the shared base name. These tests hold the
// ingest planner to that: whatever the rename template renders, the two files of one
// frame leave the card under one stem.

import Foundation
import XCTest
@testable import LumenCore

final class IngestPairNamingTests: XCTestCase {

    /// 2026-09-02 14:05:06 UTC, so rendered names are literals.
    private var calendar: Calendar {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        return gregorian
    }

    private var captureDate: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 2,
                                           hour: 14, minute: 5, second: 6))!
    }

    private func plannedNames(_ names: [String], folder: String = "/card/DCIM/100FUJI",
                              template: String = "{date}-{seq:4}-{orig}") -> [String] {
        let card = URL(fileURLWithPath: folder, isDirectory: true)
        let sources = names.map {
            IngestSourceFile(url: card.appendingPathComponent($0), byteCount: 10,
                             captureDate: captureDate)
        }
        let plan = IngestPlanner.plan(
            sources: sources,
            destinations: [IngestDestinationRoot(url: URL(fileURLWithPath: "/dest"),
                                                 role: .primary)],
            folderTemplate: "", renameTemplate: template, job: nil, calendar: calendar)
        return plan.copies.map { $0.destinations[0].url.lastPathComponent }
    }

    // MARK: - {seq} counts frames

    /// The card scan sorts by name, so a pair sits next to itself; both halves get the
    /// frame's one sequence number, and a RAW-only frame after them gets the next.
    func testARawJpegPairSharesOneSequenceNumberAndOneBaseName() {
        XCTAssertEqual(
            plannedNames(["DSCF0001.JPG", "DSCF0001.RAF", "DSCF0002.JPG", "DSCF0002.RAF",
                          "DSCF0003.RAF"]),
            ["20260902-0001-DSCF0001.JPG", "20260902-0001-DSCF0001.RAF",
             "20260902-0002-DSCF0002.JPG", "20260902-0002-DSCF0002.RAF",
             "20260902-0003-DSCF0003.RAF"])
    }

    /// A template without `{orig}` is where a split pair hurts most: the stem is all
    /// that ties the two files together.
    func testAPairSharesItsNameUnderATemplateWithoutTheOriginalName() {
        XCTAssertEqual(plannedNames(["DSCF0001.JPG", "DSCF0001.RAF", "DSCF0002.RAF"],
                                    template: "{date}-{seq:4}"),
                       ["20260902-0001.JPG", "20260902-0001.RAF", "20260902-0002.RAF"])
    }

    /// The same camera name in two card folders (100FUJI, 101FUJI after a counter
    /// reset) is two frames, not one pair.
    func testTheSameNameInTwoCardFoldersIsTwoFrames() {
        let card = URL(fileURLWithPath: "/card/DCIM", isDirectory: true)
        let sources = ["100FUJI/DSCF0001.RAF", "101FUJI/DSCF0001.RAF"].map {
            IngestSourceFile(url: card.appendingPathComponent($0), byteCount: 10,
                             captureDate: captureDate)
        }
        let plan = IngestPlanner.plan(
            sources: sources,
            destinations: [IngestDestinationRoot(url: URL(fileURLWithPath: "/dest"),
                                                 role: .primary)],
            folderTemplate: "", renameTemplate: "{seq:4}-{orig}", job: nil,
            calendar: calendar)
        XCTAssertEqual(plan.copies.map { $0.destinations[0].url.lastPathComponent },
                       ["0001-DSCF0001.RAF", "0002-DSCF0001.RAF"])
    }

    // MARK: - A collision moves the whole pair

    /// Real files in a temporary card and destination, for the copy engine.
    private func scratch() throws -> (card: URL, dest: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-pair-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let card = root.appendingPathComponent("card", isDirectory: true)
        let dest = root.appendingPathComponent("dest", isDirectory: true)
        for directory in [card, dest] {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
        }
        return (card, dest)
    }

    private func write(_ url: URL, size: Int, seed: UInt8) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data((0..<size).map { UInt8(truncatingIfNeeded: $0) &+ seed }).write(to: url)
    }

    private func copyPlan(_ files: [URL], to dest: URL) -> IngestPlan {
        IngestPlanner.plan(
            sources: files.map { IngestSourceFile(url: $0, byteCount: Int64(
                (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
                captureDate: captureDate) },
            destinations: [IngestDestinationRoot(url: dest, role: .primary)],
            folderTemplate: "", renameTemplate: nil, job: nil, calendar: calendar)
    }

    private func landed(_ report: IngestReport) -> [String] {
        report.results.map { $0.destination.lastPathComponent }
    }

    /// A second body's DSCF0001.JPG is already in the folder. The card's pair steps
    /// round it TOGETHER: the RAW must not land beside the stranger's JPEG under the
    /// one name a pairing tool reads as "these two belong together".
    func testAPairStepsRoundAStrangersFileTogether() throws {
        let (card, dest) = try scratch()
        let stranger = dest.appendingPathComponent("DSCF0001.JPG")
        try Data(repeating: 0xEE, count: 33).write(to: stranger)
        let jpg = card.appendingPathComponent("DSCF0001.JPG")
        let raf = card.appendingPathComponent("DSCF0001.RAF")
        try write(jpg, size: 40, seed: 7)
        try write(raf, size: 80, seed: 8)

        let report = VerifiedCopyDriver(chunkSize: 16).run(copyPlan([jpg, raf], to: dest))

        XCTAssertTrue(report.allVerified, report.summary)
        XCTAssertEqual(landed(report), ["DSCF0001-1.JPG", "DSCF0001-1.RAF"])
        XCTAssertEqual(try Data(contentsOf: stranger), Data(repeating: 0xEE, count: 33))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("DSCF0001.RAF").path),
            "the card's RAW sits beside a stranger's JPEG of the same name")

        // And the card going back in finds both halves where they went.
        let again = VerifiedCopyDriver(chunkSize: 16).run(copyPlan([jpg, raf], to: dest))
        XCTAssertEqual(again.alreadyPresent.count, 2, again.summary)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dest.path).count, 3)
    }

    /// The stranger can be from this very run: 100FUJI/DSCF0001.RAF landed first, then
    /// the counter-reset 101FUJI pair arrives. Its JPEG name is free and its RAW name is
    /// not — the pair still goes to one stem.
    func testAPairStepsRoundAnEarlierFrameOfTheSameRunTogether() throws {
        let (card, dest) = try scratch()
        let first = card.appendingPathComponent("100FUJI/DSCF0001.RAF")
        let jpg = card.appendingPathComponent("101FUJI/DSCF0001.JPG")
        let raf = card.appendingPathComponent("101FUJI/DSCF0001.RAF")
        try write(first, size: 80, seed: 1)
        try write(jpg, size: 40, seed: 2)
        try write(raf, size: 80, seed: 3)

        let report = VerifiedCopyDriver(chunkSize: 16).run(
            copyPlan([first, jpg, raf], to: dest))

        XCTAssertTrue(report.allVerified, report.summary)
        XCTAssertEqual(landed(report), ["DSCF0001.RAF", "DSCF0001-1.JPG", "DSCF0001-1.RAF"])
    }

    /// A folder an earlier build split — the JPEG stepped to -1, the RAW at its own
    /// name — is still recognised on re-ingest, half by half, and gains no third copy.
    func testAPairAnEarlierBuildSplitIsStillFoundOnReingest() throws {
        let (card, dest) = try scratch()
        try Data(repeating: 0xEE, count: 33).write(to: dest.appendingPathComponent("DSCF0001.JPG"))
        let jpg = card.appendingPathComponent("DSCF0001.JPG")
        let raf = card.appendingPathComponent("DSCF0001.RAF")
        try write(jpg, size: 40, seed: 7)
        try write(raf, size: 80, seed: 8)
        try FileManager.default.copyItem(at: jpg, to: dest.appendingPathComponent("DSCF0001-1.JPG"))
        try FileManager.default.copyItem(at: raf, to: dest.appendingPathComponent("DSCF0001.RAF"))

        let report = VerifiedCopyDriver(chunkSize: 16).run(copyPlan([jpg, raf], to: dest))

        XCTAssertEqual(report.alreadyPresent.count, 2, report.summary)
        XCTAssertEqual(landed(report), ["DSCF0001-1.JPG", "DSCF0001.RAF"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dest.path).count, 3)
    }

    /// A lone frame is untouched by any of this: it lands at its own name when that is
    /// free, whatever its neighbours had to do.
    func testALoneFrameStillLandsAtItsOwnName() throws {
        let (card, dest) = try scratch()
        try Data(repeating: 0xEE, count: 33).write(to: dest.appendingPathComponent("DSCF0001.JPG"))
        let jpg = card.appendingPathComponent("DSCF0001.JPG")
        let raf = card.appendingPathComponent("DSCF0001.RAF")
        let next = card.appendingPathComponent("DSCF0002.RAF")
        try write(jpg, size: 40, seed: 7)
        try write(raf, size: 80, seed: 8)
        try write(next, size: 80, seed: 9)

        let report = VerifiedCopyDriver(chunkSize: 16).run(copyPlan([jpg, raf, next], to: dest))

        XCTAssertTrue(report.allVerified, report.summary)
        XCTAssertEqual(landed(report), ["DSCF0001-1.JPG", "DSCF0001-1.RAF", "DSCF0002.RAF"])
    }
}
