// ExportOverwriteSafetyTests.swift
// The Overwrite collision policy is "the re-delivery of a corrected batch". It used to
// answer `.write(wanted, replacing: true)` for ANY file on disk, so exporting a JPEG
// into its own folder with the default `{name}` template renamed the render over the
// original it was rendered from — and on case-insensitive APFS, exporting a RAW of a
// RAW+JPEG pair replaced the camera's JPEG. An original is never a delivery: these pin
// that no policy, and no disambiguated candidate, lands on one.
//
// They run against a real directory and the real publish, because the loss happens in
// `ExclusivePublish.publish(allowOverwrite: true)`, not in the placement's answer.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import XCTest
@testable import LumenCore

final class ExportOverwriteSafetyTests: XCTestCase {

    private var directory: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        directory = fm.temporaryDirectory
            .appendingPathComponent("lumen-overwrite-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? fm.removeItem(at: directory) }
    }

    private func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    private func write(_ text: String, _ name: String) throws -> URL {
        let url = file(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func read(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    /// The placement exactly as the batch asks it, with the batch's originals protected.
    private func place(_ wanted: URL, _ policy: ExportCollisionPolicy, sources: [URL],
                       claimed: Set<String> = []) -> ExportPlacement {
        let originals = ExportRecipe.originalIdentities(of: sources)
        return ExportRecipe.placement(
            for: wanted, policy: policy,
            claimedThisRun: { claimed.contains(IngestLocation.fileIdentity(of: $0)) },
            existsOnDisk: { self.fm.fileExists(atPath: $0.path) },
            isOriginal: { originals.contains(IngestLocation.fileIdentity(of: $0)) })
    }

    /// Render, then publish where the placement said — the renderer's last step. The
    /// exclusive rename answers ENOTSUP so every host takes the real link path.
    private func deliver(_ placement: ExportPlacement, rendered: String) throws {
        guard case .write(let destination, let replacing) = placement else { return }
        let partial = try write(rendered, "." + destination.lastPathComponent + ".part")
        try ExclusivePublish.publish(partial, as: destination, allowOverwrite: replacing,
                                     using: .init(renameExclusive: { _, _ in ENOTSUP }))
    }

    // MARK: - The original being exported

    func testOverwriteNeverReplacesTheOriginalBeingExported() throws {
        let original = try write("ORIGINAL", "IMG_0001.jpg")
        // `{name}` + JPEG into the source folder renders exactly the source path.
        let placement = place(original, .overwrite, sources: [original])
        XCTAssertEqual(placement, .write(file("IMG_0001-1.jpg"), replacing: false),
                       "Overwrite chose the original as the file to replace")
        try deliver(placement, rendered: "RENDER")
        XCTAssertEqual(try read(original), "ORIGINAL", "the export replaced its own original")
        XCTAssertEqual(try read(file("IMG_0001-1.jpg")), "RENDER")
    }

    /// A RAW exported as JPEG with `{name}` into its card folder: the first render sits
    /// beside the RAW with its stem, so it reads as an original from then on. Overwrite
    /// must settle on `-1` and keep replacing it, not write `-2`, `-3`, ... per run.
    func testRepeatedOverwriteIntoTheSourceFolderSettlesOnOneDelivery() throws {
        let raw = try write("RAW", "DSC00001.ARW")
        let wanted = file("DSC00001.jpg")
        for run in 1...4 {
            try deliver(place(wanted, .overwrite, sources: [raw]), rendered: "RENDER \(run)")
        }
        XCTAssertEqual(try read(wanted), "RENDER 1", "the first delivery is now protected")
        XCTAssertEqual(try read(file("DSC00001-1.jpg")), "RENDER 4", "later runs replace -1")
        XCTAssertFalse(fm.fileExists(atPath: file("DSC00001-2.jpg").path),
                       "a new copy per run is the pile-up Overwrite exists to avoid")
        XCTAssertEqual(try read(raw), "RAW")
    }

    // MARK: - Its RAW+JPEG sibling

    func testOverwriteNeverReplacesTheCamerasJPEGOfARawPlusJPEGPair() throws {
        let raw = try write("RAW", "DSC00001.ARW")
        let jpeg = try write("CAMERA JPEG", "DSC00001.jpg")
        // Only the RAW is in the batch; the JPEG beside it is an original all the same.
        let placement = place(jpeg, .overwrite, sources: [raw])
        XCTAssertEqual(placement, .write(file("DSC00001-1.jpg"), replacing: false))
        try deliver(placement, rendered: "RENDER")
        XCTAssertEqual(try read(jpeg), "CAMERA JPEG")
    }

    func testTheSiblingIsFoundWhateverTheCaseOfItsSpelling() throws {
        // The camera writes DSC00001.JPG; the recipe asks for `.jpg`. On APFS these are
        // one file, and the identity check sees that; here the camera's spelling is the
        // one on disk and the protection must still find it from the RAW's stem.
        let raw = try write("RAW", "dsc00001.arw")
        let jpeg = try write("CAMERA JPEG", "DSC00001.JPG")
        XCTAssertTrue(ExportRecipe.originalIdentities(of: [raw])
                        .contains(IngestLocation.fileIdentity(of: jpeg)))
        XCTAssertEqual(place(jpeg, .overwrite, sources: [raw]),
                       .write(file("DSC00001-1.JPG"), replacing: false))
        XCTAssertEqual(try read(jpeg), "CAMERA JPEG")
    }

    func testAnAliasOfTheOriginalIsTheOriginal() throws {
        let original = try write("ORIGINAL", "IMG_0002.jpg")
        let alias = file("img_0002-link.jpg")
        try fm.linkItem(at: original, to: alias)
        let placement = place(alias, .overwrite, sources: [original])
        XCTAssertEqual(placement, .write(file("img_0002-link-1.jpg"), replacing: false))
        try deliver(placement, rendered: "RENDER")
        XCTAssertEqual(try read(original), "ORIGINAL")
    }

    // MARK: - A renamed candidate never lands on an original either

    func testDisambiguationSkipsOverAnOriginal() throws {
        let original = try write("ORIGINAL", "IMG_0003.jpg")
        // A free `-1` that is somebody's original in a folder listing that changed
        // under us is still not a name the batch may take.
        let sibling = try write("OTHER ORIGINAL", "IMG_0003-1.jpg")
        let originals = ExportRecipe.originalIdentities(of: [original, sibling])
        let placement = ExportRecipe.placement(
            for: original, policy: .rename,
            claimedThisRun: { _ in false },
            existsOnDisk: { $0 == original },
            isOriginal: { originals.contains(IngestLocation.fileIdentity(of: $0)) })
        XCTAssertEqual(placement, .write(file("IMG_0003-2.jpg"), replacing: false))
    }

    // MARK: - What Overwrite is for is kept

    func testOverwriteStillReplacesAnEarlierDelivery() throws {
        let original = try write("ORIGINAL", "IMG_0004.jpg")
        let earlier = try write("OLD RENDER", "IMG_0004-1.jpg")
        let placement = place(earlier, .overwrite, sources: [original])
        XCTAssertEqual(placement, .write(earlier, replacing: true))
        try deliver(placement, rendered: "NEW RENDER")
        XCTAssertEqual(try read(earlier), "NEW RENDER")
        XCTAssertEqual(try read(original), "ORIGINAL")
    }

    func testSkipAndRenameAreUnchangedOnAnOriginal() throws {
        let original = try write("ORIGINAL", "IMG_0005.jpg")
        XCTAssertEqual(place(original, .skip, sources: [original]), .skip(original))
        XCTAssertEqual(place(original, .rename, sources: [original]),
                       .write(file("IMG_0005-1.jpg"), replacing: false))
    }

    // MARK: - The batch protects its originals

    func testTheBatchPassesItsOriginalsToThePlacement() throws {
        let flat = ShellSource.squashed(try ShellSource.code("Sources/LumenApp/AppStateActions.swift"))
        XCTAssertTrue(flat.contains("ExportRecipe.originalIdentities(of:"),
                      "the batch no longer collects the identities of its originals")
        XCTAssertTrue(flat.contains("isOriginal: { originals.contains(IngestLocation.fileIdentity(of: $0)) }"),
                      "the batch asks the collision policy without protecting the originals")
    }
}
