// SidecarReseedTests.swift
// J1-03: a queued sidecar write must state its own fields, not the file's two-second-old
// copy of them.
//
// The write path seeds a whole `SidecarContent` from a read of the sidecar at the moment
// of the keystroke, sets the one field that changed, and writes the WHOLE struct
// `sidecarDebounce` (2 s) later — because `fieldLines` re-emits every field it is handed
// and `XMPMerge` strips the old elements first. So a field nobody touched is still
// written, from a copy taken two seconds ago.
//
// Two seconds is not a theoretical window. It is a Lightroom write, a Dropbox or
// Lightroom-sync pull, or an `exiftool` invocation landing between the keystroke and the
// flush — and what it costs is that tool's work, reverted by a rating, with the catalog
// still holding Lumen's version so nothing anywhere looks wrong.
//
// `SidecarStatedFields` is the intent, carried instead of collapsed; `reseed` is the rule
// that applies it. What follows pins both, and then pins the flush to actually using
// them — because the rule being right in LumenCore is worth nothing if `CatalogService`
// still splices the stale struct.

import XCTest
@testable import LumenCore

final class SidecarReseedTests: XCTestCase {

    /// The file as another tool left it during the debounce window.
    private func fileOnDisk() -> SidecarContent {
        SidecarContent(rating: 5, flag: .pick, label: "Green",
                       pipelineVersion: 3,
                       recipeFingerprint: "theirs", recipeJSON: "{\"a\":1}",
                       strokesPayload: "theirstrokes",
                       catalogUUID: "their-catalog", writeStamp: "2026-09-02T10:00:00Z")
    }

    /// What the queue is holding: a seed taken BEFORE that write, plus one stated field.
    private func queued(rating: Int) -> SidecarContent {
        SidecarContent(rating: rating, flag: .none, label: nil,
                       pipelineVersion: 1,
                       recipeFingerprint: "ours-stale", recipeJSON: "{\"stale\":1}",
                       strokesPayload: nil,
                       catalogUUID: nil, writeStamp: "2026-09-02T10:00:02Z")
    }

    // MARK: - The rule

    func testAStatedFieldWinsAndEverythingElseComesFromTheFile() {
        let out = XMPSidecar.reseed(queued(rating: 3), fields: [.rating],
                                    onto: fileOnDisk())

        XCTAssertEqual(out.rating, 3, "the rating is what this batch stated")

        // Everything the batch did not state is the file's, not the seed's.
        XCTAssertEqual(out.label, "Green",
                       "a label another tool wrote during the debounce must survive a "
                       + "rating keystroke")
        XCTAssertEqual(out.flag, .pick)
        XCTAssertEqual(out.recipeJSON, "{\"a\":1}")
        XCTAssertEqual(out.recipeFingerprint, "theirs")
        XCTAssertEqual(out.pipelineVersion, 3)
        XCTAssertEqual(out.strokesPayload, "theirstrokes")
        XCTAssertEqual(out.catalogUUID, "their-catalog")
    }

    /// The stamp is the one exception, and it is not an oversight: this write is what
    /// the stamp describes, so it is always the new one.
    func testTheWriteStampIsAlwaysTheNewWrites() {
        let out = XMPSidecar.reseed(queued(rating: 3), fields: [.rating],
                                    onto: fileOnDisk())
        XCTAssertEqual(out.writeStamp, "2026-09-02T10:00:02Z")
    }

    /// `.some(nil)` — "the label was cleared" — has to reach the file. If clearing were
    /// indistinguishable from silence the fix would trade one lost edit for another, and
    /// it would be the user's own.
    func testClearingALabelIsStatedAndReachesTheFile() {
        var cleared = queued(rating: 0)
        cleared.label = nil
        let out = XMPSidecar.reseed(cleared, fields: [.label], onto: fileOnDisk())
        XCTAssertNil(out.label,
                     "clearing a label is a statement about the label, not silence")
        XCTAssertEqual(out.rating, 5, "and it says nothing about the rating")
    }

    /// The recipe trio moves together or not at all — a fingerprint from one build over
    /// a recipe from another is worse than either alone.
    func testTheRecipeTrioMovesAsOne() {
        let out = XMPSidecar.reseed(queued(rating: 0), fields: [.recipe],
                                    onto: fileOnDisk())
        XCTAssertEqual(out.recipeJSON, "{\"stale\":1}")
        XCTAssertEqual(out.recipeFingerprint, "ours-stale")
        XCTAssertEqual(out.pipelineVersion, 1)
        XCTAssertEqual(out.rating, 5, "and the rating is still the file's")
    }

    func testStatingEverythingIsTheOldBehaviourExactly() {
        let all: SidecarStatedFields = [.rating, .flag, .label, .recipe, .strokes]
        let batch = queued(rating: 2)
        let out = XMPSidecar.reseed(batch, fields: all, onto: fileOnDisk())
        XCTAssertEqual(out.rating, batch.rating)
        XCTAssertEqual(out.flag, batch.flag)
        XCTAssertEqual(out.label, batch.label)
        XCTAssertEqual(out.recipeJSON, batch.recipeJSON)
        XCTAssertEqual(out.strokesPayload, batch.strokesPayload)
        // `catalogUUID` is never stated by any caller, so it is the file's even here.
        XCTAssertEqual(out.catalogUUID, "their-catalog")
    }

    /// The end-to-end shape, through the same two functions the flush calls: parse the
    /// document on disk, reseed onto it, splice. This is the test that fails on the
    /// behaviour the finding describes.
    func testARatingKeystrokeDoesNotRevertAnotherToolsLabel() throws {
        let theirs = XMPSidecar.serialize(fileOnDisk())
        let fresh = try XCTUnwrap(XMPSidecar.parse(theirs))
        let content = XMPSidecar.reseed(queued(rating: 3), fields: [.rating], onto: fresh)
        let merged = try XCTUnwrap(XMPSidecar.update(theirs, with: content))

        let after = try XCTUnwrap(XMPSidecar.parse(merged))
        XCTAssertEqual(after.rating, 3)
        XCTAssertEqual(after.label, "Green")
        XCTAssertEqual(after.recipeJSON, "{\"a\":1}")
        XCTAssertEqual(after.strokesPayload, "theirstrokes")
    }

    // MARK: - The flush has to use it

    /// `reseed` existing and `flushSidecars` calling it are different facts, and only the
    /// second one is the fix. `CatalogService` is in `LumenApp`, which has no test target
    /// that runs here, so this reads it as text — the same shape `EditRevisionRuleTests`
    /// uses, comments stripped, because a doc comment naming the symbol would otherwise
    /// let this test pass its own substitution proof.
    func testTheFlushReSeedsFromTheDocumentItIsAboutToSplice() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/LumenApp")
        let path = root.appendingPathComponent("CatalogService.swift")
        let source = Self.strippingComments(try String(contentsOf: path,
                                                       encoding: .utf8))

        XCTAssertTrue(source.contains("XMPSidecar.reseed("),
                      "flushSidecars must re-seed from the file it is about to splice; "
                      + "without it every unstated field is a two-second-old copy")
        XCTAssertTrue(source.contains("stated: SidecarStatedFields"),
                      "the queue has to carry WHICH fields were stated, or reseed has "
                      + "nothing to apply")

        // And the reseed has to happen on the `.document` path, ahead of the splice —
        // reseeding after `update` would be decoration.
        let reseedAt = try XCTUnwrap(source.range(of: "XMPSidecar.reseed(")).lowerBound
        let updateAt = try XCTUnwrap(source.range(of: "XMPSidecar.update(")).lowerBound
        XCTAssertLessThan(reseedAt, updateAt,
                          "the re-seed must come before the splice that consumes it")
    }

    /// Line and block comments removed. `DesignSystemTests` and `EditRevisionRuleTests`
    /// both learned this the same way: a text-scanning test whose own explanation
    /// contains the symbol it scans for passes when the code is gone.
    private static func strippingComments(_ source: String) -> String {
        var out = ""
        var index = source.startIndex
        var inBlock = false
        while index < source.endIndex {
            let rest = source[index...]
            if inBlock {
                if rest.hasPrefix("*/") {
                    inBlock = false
                    index = source.index(index, offsetBy: 2)
                } else {
                    index = source.index(after: index)
                }
                continue
            }
            if rest.hasPrefix("/*") {
                inBlock = true
                index = source.index(index, offsetBy: 2)
                continue
            }
            if rest.hasPrefix("//") {
                while index < source.endIndex, source[index] != "\n" {
                    index = source.index(after: index)
                }
                continue
            }
            out.append(source[index])
            index = source.index(after: index)
        }
        return out
    }
}

// MARK: - M-01

/// A `.xmp` written by a build newer than this one must come back out of a flush with
/// its recipe untouched.
///
/// `CatalogStore` refuses a newer recipe twice — it clamps the stamp it writes and
/// rejects a row whose version exceeds this build's. The sidecar path did neither, and
/// the sidecar is the copy that exists for when the catalog is gone.
///
/// The mechanism that destroys it is not a bug in the decoder; it is the decoder working
/// as designed in the wrong place. `decodeRecipe` drops every key this build's
/// `CodingKeys` do not name — correct, and free, for a recipe that stays in memory. The
/// flush then writes that reduced recipe back over the document it was read from.
final class SidecarNewerFormatTests: XCTestCase {

    func testThisBuildDeclinesToStateARecipeItCannotRepresent() {
        let newer = currentPipelineVersion + 1
        let all: SidecarStatedFields = [.rating, .flag, .label, .recipe, .strokes]
        XCTAssertEqual(XMPSidecar.writableFields(all, documentVersion: newer),
                       [.rating, .flag, .label, .strokes],
                       "a rating still lands; the recipe does not")
    }

    func testAnOlderOrEqualDocumentIsWrittenNormally() {
        let all: SidecarStatedFields = [.rating, .recipe]
        XCTAssertEqual(XMPSidecar.writableFields(all, documentVersion: currentPipelineVersion),
                       all, "this build's own format is not a newer one")
        XCTAssertEqual(XMPSidecar.writableFields(all, documentVersion: 1), all,
                       "and an OLDER document is exactly what this build is for")
    }

    /// The whole path, through the three functions the flush calls in order. The
    /// downgrade this pins is the real one: a recipe decoded by this build, reduced to
    /// the keys it knows, on its way back to a file that had more.
    func testANewerBuildsRecipeSurvivesARatingKeystroke() throws {
        let newer = currentPipelineVersion + 1
        let theirs = XMPSidecar.serialize(
            SidecarContent(rating: 0, flag: .none, label: nil,
                           pipelineVersion: newer,
                           recipeFingerprint: "newer-fp",
                           recipeJSON: "{\"develop\":{\"somethingThisBuildDropped\":7}}",
                           catalogUUID: "their-catalog"))

        // What this build would write: the reduced recipe, and the version carried
        // forward from the document it decoded.
        var queued = SidecarContent(rating: 4, pipelineVersion: newer,
                                    recipeFingerprint: "reduced-fp",
                                    recipeJSON: "{\"develop\":{}}",
                                    writeStamp: "2026-09-02T11:00:00Z")
        queued.label = nil

        let fresh = try XCTUnwrap(XMPSidecar.parse(theirs))
        XCTAssertEqual(fresh.pipelineVersion, newer, "the document says what it is")

        let honoured = XMPSidecar.writableFields([.rating, .recipe],
                                                 documentVersion: fresh.pipelineVersion)
        let content = XMPSidecar.reseed(queued, fields: honoured, onto: fresh)
        let merged = try XCTUnwrap(XMPSidecar.update(theirs, with: content))
        let after = try XCTUnwrap(XMPSidecar.parse(merged))

        XCTAssertEqual(after.rating, 4, "the keystroke that started this still lands")
        XCTAssertEqual(after.recipeJSON,
                       "{\"develop\":{\"somethingThisBuildDropped\":7}}",
                       "the newer build's recipe is re-emitted verbatim, not reduced")
        XCTAssertEqual(after.recipeFingerprint, "newer-fp")
        XCTAssertEqual(after.pipelineVersion, newer,
                       "and the document still truthfully says which build wrote it")
    }

    /// The write side has a second half: a document THIS build authors must not claim a
    /// version it does not implement. A recipe carries its version forward once decoded,
    /// so without the clamp the number outlives the file it came from — the next build
    /// to read it declines to touch a recipe this build actually wrote.
    func testTheStampThisBuildWritesIsClampedToWhatItImplements() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/LumenApp")
        let source = try String(contentsOf: root.appendingPathComponent(
            "CatalogService.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("Swift.min(recipe.pipelineVersion,"),
                      "the version handed to the sidecar must be clamped to this build's")
    }

    /// And the refusal has to be wired into the flush, not merely available to it.
    func testTheFlushAsksWhichFieldsItMayState() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/LumenApp")
        let source = try String(contentsOf: root.appendingPathComponent(
            "CatalogService.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("XMPSidecar.writableFields("),
                      "flushSidecars must ask before it states a recipe")
        // The answer has to be what reaches `reseed`. Passing `entry.stated` straight
        // through would leave the call site looking right and doing nothing.
        XCTAssertFalse(source.contains("reseed(content, fields: entry.stated"),
                       "the honoured set, not the stated one, is what may be written")
    }
}
