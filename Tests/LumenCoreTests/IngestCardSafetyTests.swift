// IngestCardSafetyTests.swift
// Findings 1, 2 and 4 of docs/agent-runs/findings/ingest (test-ingest branch): files the
// ingest does not copy, a destination on the card, a backup on the primary's volume.

import Foundation
import XCTest
@testable import LumenCore

final class IngestCardSafetyTests: XCTestCase {

    private var root: URL!
    private var card: URL!
    private var primary: URL!
    private var backup: URL!
    private let shot = Date(timeIntervalSince1970: 1_788_357_906)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IngestCardSafety-\(UUID().uuidString)", isDirectory: true)
        card = root.appendingPathComponent("card", isDirectory: true)
        primary = root.appendingPathComponent("primary", isDirectory: true)
        backup = root.appendingPathComponent("backup", isDirectory: true)
        for dir in [card!, primary!, backup!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relative: String, _ text: String) throws -> URL {
        let url = card.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func sources(_ urls: [URL]) -> [IngestSourceFile] {
        urls.map { url in
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
            return IngestSourceFile(url: url, byteCount: Int64(size), captureDate: shot)
        }
    }

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // Finding 1: a MOV, a WAV and an XMP beside the photos.
    func testFilesThatAreNotPhotosAreNamedAndKeepEjectLocked() throws {
        let photos = [try write("DCIM/100MSDCF/DSC00001.ARW", "raw one"),
                      try write("DCIM/100MSDCF/DSC00002.JPG", "jpeg two")]
        _ = try write("DCIM/100MSDCF/DSC00009.MOV", "video")
        _ = try write("PRIVATE/M4ROOT/CLIP/C0001.MP4", "clip")
        _ = try write("DCIM/100MSDCF/DSC00003.WAV", "memo")
        _ = try write("DCIM/100MSDCF/DSC00003.XMP", "<x/>")

        let left = IngestCardScan.filesNotCopied(under: card, copying: PhotoFormats.browsable)
        XCTAssertEqual(Set(left.map(\.lastPathComponent)),
                       ["DSC00009.MOV", "C0001.MP4", "DSC00003.WAV", "DSC00003.XMP"])

        let plan = IngestPlanner.plan(sources: sources(photos),
                                      destinations: [.init(url: primary, role: .primary),
                                                     .init(url: backup, role: .backup)],
                                      folderTemplate: "{year}", renameTemplate: nil, job: nil,
                                      calendar: calendar(), sourceRoot: card, leftOnCard: left)
        let report = VerifiedCopyDriver().run(plan)

        XCTAssertTrue(report.photosVerified)
        XCTAssertFalse(report.allVerified, "eject must stay locked while clips are only on the card")
        XCTAssertFalse(report.summary.contains("every copy verified"), report.summary)
        XCTAssertTrue(report.summary.contains("4 files on the card"), report.summary)
        XCTAssertTrue(report.summary.contains("2 videos, 1 audio file, 1 other file"), report.summary)
        XCTAssertTrue(report.summary.contains("NOT be copied"), report.summary)

        var durable = OperationReport(kind: .ingest, records: [])
        durable.finishIngest(report, sources: photos, expectedRoles: [.primary, .backup])
        XCTAssertTrue(durable.issues.contains { $0.contains("DSC00009.MOV") }, "\(durable.issues)")
    }

    func testAPhotoOnlyCardStillReportsEveryCopyVerified() throws {
        let photo = try write("DCIM/100MSDCF/DSC00001.ARW", "raw one")
        let left = IngestCardScan.filesNotCopied(under: card, copying: PhotoFormats.browsable)
        XCTAssertEqual(left, [])
        let plan = IngestPlanner.plan(sources: sources([photo]),
                                      destinations: [.init(url: primary, role: .primary)],
                                      folderTemplate: "{year}", renameTemplate: nil, job: nil,
                                      calendar: calendar(), sourceRoot: card, leftOnCard: left)
        let report = VerifiedCopyDriver().run(plan)
        XCTAssertTrue(report.allVerified)
        XCTAssertTrue(report.summary.hasSuffix("every copy verified."), report.summary)
    }

    // Finding 2: the card root, and a folder on the card, as the primary.
    func testADestinationOnTheSourceCardIsRefusedAndNothingIsWritten() throws {
        let photo = try write("DCIM/100NIKON/DSC_0001.NEF", "nef")
        for destination in [card!, card.appendingPathComponent("Imports", isDirectory: true)] {
            let plan = IngestPlanner.plan(sources: sources([photo]),
                                          destinations: [.init(url: destination, role: .primary)],
                                          folderTemplate: "{year}/{date}", renameTemplate: nil,
                                          job: nil, calendar: calendar(), sourceRoot: card)
            XCTAssertTrue(plan.copies.isEmpty)
            XCTAssertEqual(plan.refusals.count, 1)
            XCTAssertTrue(plan.refusals[0].contains("on the source card"), plan.refusals[0])
            let report = VerifiedCopyDriver().run(plan)
            XCTAssertFalse(report.allVerified)
        }
        let onCard = try FileManager.default.subpathsOfDirectory(atPath: card.path)
        XCTAssertEqual(onCard.filter { $0.hasSuffix(".NEF") }, ["DCIM/100NIKON/DSC_0001.NEF"])
    }

    func testABackupOnTheCardIsRefusedEvenWhenThePrimaryIsElsewhere() throws {
        let photo = try write("DCIM/100NIKON/DSC_0001.NEF", "nef")
        let plan = IngestPlanner.plan(sources: sources([photo]),
                                      destinations: [.init(url: primary, role: .primary),
                                                     .init(url: card, role: .backup)],
                                      folderTemplate: "{year}", renameTemplate: nil, job: nil,
                                      calendar: calendar(), sourceRoot: card)
        XCTAssertTrue(plan.copies.isEmpty)
        XCTAssertTrue(plan.refusals[0].contains("backup destination is on the source card"))
    }

    func testADestinationBesideTheCardIsNotRefused() throws {
        let photo = try write("DCIM/100NIKON/DSC_0001.NEF", "nef")
        let plan = IngestPlanner.plan(sources: sources([photo]),
                                      destinations: [.init(url: root, role: .primary)],
                                      folderTemplate: "{year}", renameTemplate: nil, job: nil,
                                      calendar: calendar(), sourceRoot: card)
        XCTAssertEqual(plan.copies.count, 1)
        XCTAssertTrue(plan.refusals.isEmpty)
    }

    // Finding 4: two folders on one filesystem.
    func testABackupOnThePrimaryVolumeIsNamedInTheSummary() throws {
        let photo = try write("DCIM/100NIKON/DSC_0001.NEF", "nef")
        let plan = IngestPlanner.plan(sources: sources([photo]),
                                      destinations: [.init(url: primary, role: .primary),
                                                     .init(url: backup, role: .backup)],
                                      folderTemplate: "{year}", renameTemplate: nil, job: nil,
                                      calendar: calendar(), sourceRoot: card)
        XCTAssertTrue(plan.backupSharesVolume)
        let report = VerifiedCopyDriver().run(plan)
        XCTAssertTrue(report.summary.contains("primary and backup are on the same volume"),
                      report.summary)
    }
}
