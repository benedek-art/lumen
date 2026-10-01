// V6 REL-04 portability: RENAME_EXCL answers ENOTSUP or EINVAL on exFAT, FAT, SMB and
// NFS, and every export there failed. The fallback must publish on those volumes and
// still never replace a file that appeared under the name.
//
// These run against a real directory: the exclusive rename is injected (it is Darwin's
// `renamex_np`, and the point is to make it answer ENOTSUP), and link, open(O_EXCL),
// rename and unlink are the real calls unless a case injects them too.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import XCTest
@testable import LumenCore

final class ExclusivePublishTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-publish-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func write(_ text: String, _ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func read(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    private static func answering(_ code: Int32) -> @Sendable (URL, URL) -> Int32 {
        { _, _ in code }
    }

    /// The volume does not support RENAME_EXCL.
    private static let noExclusiveRename = ExclusivePublish.Syscalls(
        renameExclusive: answering(ENOTSUP))

    /// Nor hard links (FAT, exFAT): only the exclusive create is left.
    private static let noExclusiveRenameNoLinks = ExclusivePublish.Syscalls(
        renameExclusive: answering(ENOTSUP), link: answering(EPERM))

    // MARK: - ENOTSUP / EINVAL publish anyway

    func testUnsupportedExclusiveRenamePublishesThroughALink() throws {
        let partial = try write("photo", ".a.jpg.part")
        let destination = directory.appendingPathComponent("a.jpg")
        XCTAssertNoThrow(try ExclusivePublish.publish(partial, as: destination,
                                                      allowOverwrite: false,
                                                      using: Self.noExclusiveRename),
                         "ENOTSUP from RENAME_EXCL failed the export: every export to an "
                             + "exFAT card or an SMB share would fail")
        XCTAssertEqual(try read(destination), "photo")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path),
                       "the partial must not be left beside the delivery")
    }

    func testEINVALIsTreatedTheSameAsENOTSUP() throws {
        let partial = try write("photo", ".b.jpg.part")
        let destination = directory.appendingPathComponent("b.jpg")
        try ExclusivePublish.publish(partial, as: destination, allowOverwrite: false,
                                     using: .init(renameExclusive: Self.answering(EINVAL)))
        XCTAssertEqual(try read(destination), "photo")
    }

    func testWithoutLinksTheNameIsClaimedThenFilled() throws {
        let partial = try write("photo", ".c.jpg.part")
        let destination = directory.appendingPathComponent("c.jpg")
        try ExclusivePublish.publish(partial, as: destination, allowOverwrite: false,
                                     using: Self.noExclusiveRenameNoLinks)
        XCTAssertEqual(try read(destination), "photo")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    // MARK: - …and still never overwrite

    /// The sentinel race on an unsupported volume: a file appeared under the name while
    /// the export encoded. Both fallbacks refuse, and the sentinel is intact.
    func testTheFallbacksNeverReplaceAFileThatAppeared() throws {
        for (label, calls) in [("link", Self.noExclusiveRename),
                               ("exclusive create", Self.noExclusiveRenameNoLinks)] {
            let partial = try write("photo", ".d.jpg.part")
            let destination = try write("sentinel", "d.jpg")
            XCTAssertThrowsError(try ExclusivePublish.publish(partial, as: destination,
                                                              allowOverwrite: false,
                                                              using: calls), label) { error in
                XCTAssertEqual(error as? ExportPublishError, .destinationExists, label)
            }
            XCTAssertEqual(try read(destination), "sentinel",
                           "the \(label) fallback replaced a file that appeared during the export")
            try FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: partial)
        }
    }

    /// The claim's rename failing must take the empty claim with it, not leave a
    /// zero-byte "delivery" under the name.
    func testAFailedFillRemovesTheClaim() throws {
        let partial = try write("photo", ".e.jpg.part")
        let destination = directory.appendingPathComponent("e.jpg")
        let calls = ExclusivePublish.Syscalls(renameExclusive: Self.answering(ENOTSUP),
                                              link: Self.answering(EPERM),
                                              rename: Self.answering(EIO))
        XCTAssertThrowsError(try ExclusivePublish.publish(partial, as: destination,
                                                          allowOverwrite: false, using: calls)) {
            XCTAssertEqual($0 as? ExportPublishError, .failed(errno: EIO))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Every other answer is kept, not retried

    func testOtherAnswersAreReportedAsTheyCame() throws {
        let partial = try write("photo", ".f.jpg.part")
        let destination = directory.appendingPathComponent("f.jpg")
        XCTAssertThrowsError(try ExclusivePublish.publish(
            partial, as: destination, allowOverwrite: false,
            using: .init(renameExclusive: Self.answering(EEXIST)))) {
            XCTAssertEqual($0 as? ExportPublishError, .destinationExists)
        }
        XCTAssertThrowsError(try ExclusivePublish.publish(
            partial, as: destination, allowOverwrite: false,
            using: .init(renameExclusive: Self.answering(ENOSPC)))) {
            XCTAssertEqual($0 as? ExportPublishError, .failed(errno: ENOSPC))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
                       "a disk failure must not fall back to another way of writing")
        // No exclusive anything on this volume at all.
        let calls = ExclusivePublish.Syscalls(renameExclusive: Self.answering(ENOTSUP),
                                              link: Self.answering(ENOTSUP),
                                              createExclusive: { _ in ENOTSUP })
        XCTAssertThrowsError(try ExclusivePublish.publish(partial, as: destination,
                                                          allowOverwrite: false, using: calls)) {
            XCTAssertEqual($0 as? ExportPublishError, .unsupportedVolume(errno: ENOTSUP))
        }
    }

    // MARK: - The status line can tell the three apart (V6 note 2)

    func testTheStatusLineNamesTheReason() {
        let race = ExclusivePublish.statusReason(for: ExportPublishError.destinationExists)
        let volume = ExclusivePublish.statusReason(for: ExportPublishError.unsupportedVolume(errno: ENOTSUP))
        let contact = ExclusivePublish.statusReason(
            for: MetadataPolicy.InvalidContact(message: "Contact must be an email address or a web address"))
        XCTAssertNotNil(race)
        XCTAssertNotNil(volume)
        XCTAssertNotNil(contact)
        XCTAssertEqual(Set([race, volume, contact].compactMap { $0 }).count, 3,
                       "a lost race, an unsupported volume and a refused contact read the same")
        struct Unrelated: Error {}
        XCTAssertNil(ExclusivePublish.statusReason(for: Unrelated()))
    }

    // MARK: - The renderer publishes through this

    func testTheRendererPublishesThroughTheFallback() throws {
        let code = try ShellSource.code("Sources/LumenPipeline/PipelineRenderer.swift")
        let write = try XCTUnwrap(ShellSource.body(after: "private func write(_ image: CIImage", in: code))
        let flat = ShellSource.squashed(write)
        XCTAssertTrue(flat.contains("ExclusivePublish.publish(partial, as: destination"),
                      "the renderer publishes with a bare renamex_np again, and ENOTSUP "
                          + "fails every export to an exFAT card")
        XCTAssertTrue(flat.contains("renamex_np(from!, to!, flags)"))
        XCTAssertTrue(flat.contains("RENAME_EXCL"))
        XCTAssertTrue(flat.contains("allowOverwrite: allowOverwrite"))
    }

    func testTheBatchStatusLineCarriesTheReason() throws {
        let code = try ShellSource.code("Sources/LumenApp/AppStateActions.swift")
        XCTAssertTrue(ShellSource.squashed(code).contains("ExclusivePublish.statusReason(for: error)"),
                      "the batch discards the reason a file failed")
    }
}
