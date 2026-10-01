// SidecarNamingTests.swift
// Two RAWs with one basename do not share a sidecar (K-015).

import XCTest
@testable import LumenCore

final class SidecarNamingTests: XCTestCase {

    private let dir = URL(fileURLWithPath: "/Volumes/Shoots/2026-08-20", isDirectory: true)
    private func file(_ name: String) -> URL { dir.appendingPathComponent(name) }

    private let rawExts: Set<String> = ["nef", "dng", "cr3", "arw"]
    private func isRawName(_ name: String) -> Bool {
        rawExts.contains(URL(fileURLWithPath: name).pathExtension.lowercased())
    }

    /// The whole pipeline, as `CatalogService` composes it.
    private func sidecar(_ name: String, in names: [String]) -> URL {
        let photo = file(name)
        return SidecarNaming.url(
            for: photo, isRaw: isRawName(name),
            rawSiblingExtensions: SidecarNaming.rawSiblingExtensions(
                of: photo, amongNames: names, isRawName: isRawName))
    }

    // MARK: - The defect

    /// THE ONE THAT COST THE RECIPE: a NEF and its DNG conversion in one folder.
    func testANEFAndItsDNGDoNotShareASidecar() {
        let names = ["DSC_0001.NEF", "DSC_0001.DNG"]
        let nef = sidecar("DSC_0001.NEF", in: names)
        let dng = sidecar("DSC_0001.DNG", in: names)
        XCTAssertNotEqual(nef, dng,
                          "both RAWs address one .xmp — editing the DNG destroys the "
                          + "NEF's recipe, and the next scan writes it into the NEF's "
                          + "catalog row")
        // Adobe never writes a sidecar for a DNG, so the bare file beside one is the
        // NEF's — and Lightroom's rating on it keeps being read.
        XCTAssertEqual(nef, file("DSC_0001.xmp"))
        XCTAssertEqual(dng, file("DSC_0001.DNG.xmp"))
    }

    /// Two non-DNG RAWs with one basename: nobody can claim the bare file, so nobody
    /// does, and it is left to whoever wrote it.
    func testTwoNonDNGRawsAreBothQualified() {
        let names = ["IMG_0042.NEF", "IMG_0042.CR3"]
        XCTAssertEqual(sidecar("IMG_0042.NEF", in: names), file("IMG_0042.NEF.xmp"))
        XCTAssertEqual(sidecar("IMG_0042.CR3", in: names), file("IMG_0042.CR3.xmp"))
    }

    /// Case does not separate files on the default macOS volume, so it must not
    /// separate them here either.
    func testTheCollisionIsCaseInsensitive() {
        let names = ["dsc_0001.nef", "DSC_0001.DNG"]
        XCTAssertNotEqual(sidecar("dsc_0001.nef", in: names),
                          sidecar("DSC_0001.DNG", in: names))
    }

    // MARK: - What must NOT change

    /// The single-RAW folder — every folder Lightroom ever wrote a sidecar into — is
    /// untouched. A fix that qualified every RAW would orphan all of them.
    func testARawAloneKeepsTheAdobeName() {
        let names = ["DSC_0002.CR3", "DSC_0002.JPG", "DSC_0003.ARW"]
        XCTAssertEqual(sidecar("DSC_0002.CR3", in: names), file("DSC_0002.xmp"))
        XCTAssertEqual(sidecar("DSC_0003.ARW", in: names), file("DSC_0003.xmp"))
    }

    /// A RAW+JPEG pair was already kept apart by qualifying the JPEG; that stays.
    func testARawPlusJPEGPairIsStillTwoFiles() {
        let names = ["DSC_0002.CR3", "DSC_0002.JPG"]
        XCTAssertEqual(sidecar("DSC_0002.JPG", in: names), file("DSC_0002.JPG.xmp"))
        XCTAssertEqual(sidecar("DSC_0002.CR3", in: names), file("DSC_0002.xmp"))
    }

    /// Stable across launches: the same inputs, the same file, every time. A rule that
    /// depended on listing order would hand the bare name back and forth.
    func testTheAnswerIsStableAcrossListingOrder() {
        let a = sidecar("DSC_0001.NEF", in: ["DSC_0001.NEF", "DSC_0001.DNG"])
        let b = sidecar("DSC_0001.NEF", in: ["DSC_0001.DNG", "DSC_0001.NEF"])
        XCTAssertEqual(a, b)
    }

    /// The sibling set excludes the photograph itself and everything that is not a
    /// RAW sharing its basename.
    func testTheSiblingSetIsOnlyOtherRawsWithThisBasename() {
        let set = SidecarNaming.rawSiblingExtensions(
            of: file("DSC_0001.NEF"),
            amongNames: ["DSC_0001.NEF", "DSC_0001.DNG", "DSC_0001.JPG",
                         "DSC_0001.xmp", "DSC_0010.NEF", "DSC_0001.NEF.xmp"],
            isRawName: isRawName)
        XCTAssertEqual(set, ["dng"])
    }

    // MARK: - Ownership decides (REL-02 regression)

    private func owned(_ ext: String) -> SidecarContent {
        SidecarContent(recipeJSON: "{}", writeStamp: "2026-10-01T00:00:00Z", sourceExtension: ext)
    }
    /// What darktable leaves beside every RAW it opens: a rating, no Lumen fields.
    private var darktable: SidecarContent { SidecarContent(rating: 2) }

    private func resolve(_ name: String, bare: SidecarContent?, qualified: SidecarContent?,
                         siblings: Set<String> = []) -> URL {
        SidecarNaming.resolve(photo: file(name), isRaw: isRawName(name),
                              bare: bare, qualified: qualified, rawSiblingExtensions: siblings)
    }

    /// THE REGRESSION: a lone NEF whose Lumen edits are in NAME.xmp (owner nef) must not
    /// switch to darktable's NAME.NEF.xmp once darktable has opened the folder.
    func testForeignQualifiedFileNeverDisplacesAnOwnedBareFile() {
        XCTAssertEqual(resolve("DSC_0001.NEF", bare: owned("nef"), qualified: darktable),
                       file("DSC_0001.xmp"),
                       "darktable's NAME.NEF.xmp displaced Lumen's own NAME.xmp")
        // Owner tags compare case-insensitively, as the extension does.
        XCTAssertEqual(resolve("DSC_0001.nef", bare: owned("NEF"), qualified: darktable),
                       file("DSC_0001.xmp"))
        // Even in a collision, an owned bare file stays its owner's.
        XCTAssertEqual(resolve("DSC_0001.NEF", bare: owned("nef"), qualified: darktable,
                               siblings: ["cr3"]), file("DSC_0001.xmp"))
    }

    /// A legacy Lumen document (no owner tag) on a lone RAW also stays put: a foreign
    /// qualified file is not a reason to leave it.
    func testForeignQualifiedFileDoesNotDisplaceALegacyLoneBareFile() {
        let legacy = SidecarContent(recipeJSON: "{}", writeStamp: "2026-08-01T00:00:00Z")
        XCTAssertEqual(resolve("DSC_0001.NEF", bare: legacy, qualified: darktable),
                       file("DSC_0001.xmp"))
        XCTAssertEqual(resolve("DSC_0001.NEF", bare: nil, qualified: darktable),
                       file("DSC_0001.xmp"))
    }

    /// The other half of the spec: a qualified file Lumen owns for this extension is
    /// honoured when the bare one belongs to somebody else, and after that neighbour is
    /// gone, so the frame never moves back.
    func testOwnedQualifiedFileIsHonoured() {
        XCTAssertEqual(resolve("DSC_0001.NEF", bare: owned("dng"), qualified: owned("nef"),
                               siblings: ["dng"]), file("DSC_0001.NEF.xmp"))
        XCTAssertEqual(resolve("DSC_0001.NEF", bare: owned("dng"), qualified: owned("nef")),
                       file("DSC_0001.NEF.xmp"))
        XCTAssertEqual(resolve("DSC_0001.NEF", bare: nil, qualified: owned("nef")),
                       file("DSC_0001.NEF.xmp"))
        // An older Lumen write to the qualified name, before owner tags existed.
        let older = SidecarContent(recipeJSON: "{}", writeStamp: "2026-09-01T00:00:00Z")
        XCTAssertEqual(resolve("DSC_0001.NEF", bare: nil, qualified: older),
                       file("DSC_0001.NEF.xmp"))
        // A bare file owned by another extension sends this frame to qualified even
        // when nothing is there yet.
        XCTAssertEqual(resolve("DSC_0001.NEF", bare: owned("dng"), qualified: nil),
                       file("DSC_0001.NEF.xmp"))
    }

    /// K-015 is unchanged when no Lumen document decides: the NEF beside a DNG keeps
    /// the bare (Adobe) file even if darktable wrote a qualified one, and an unowned
    /// Lumen document in a collision is not assigned by Adobe's convention.
    func testSeptemberCollisionRulesStillApplyWithoutOwnership() {
        let adobe = SidecarContent(rating: 4)
        XCTAssertEqual(resolve("DSC_0001.NEF", bare: adobe, qualified: darktable, siblings: ["dng"]),
                       file("DSC_0001.xmp"))
        XCTAssertEqual(resolve("DSC_0001.DNG", bare: adobe, qualified: nil, siblings: ["nef"]),
                       file("DSC_0001.DNG.xmp"))
        XCTAssertEqual(resolve("IMG_0042.NEF", bare: nil, qualified: nil, siblings: ["cr3"]),
                       file("IMG_0042.NEF.xmp"))
        let legacy = SidecarContent(recipeJSON: "{}")
        XCTAssertEqual(resolve("DSC_0001.NEF", bare: legacy, qualified: nil, siblings: ["dng"]),
                       file("DSC_0001.NEF.xmp"))
        XCTAssertEqual(resolve("DSC_0001.JPG", bare: owned("jpg"), qualified: nil),
                       file("DSC_0001.JPG.xmp"))
    }
}
