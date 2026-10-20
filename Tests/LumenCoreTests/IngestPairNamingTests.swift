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
}
