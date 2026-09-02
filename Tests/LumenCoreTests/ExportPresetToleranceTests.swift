// ExportPresetToleranceTests.swift
// The proof for J3-01: reading a stored preset list cannot throw, whatever a NESTED
// type — or a build that has moved on — puts inside it.
//
// `ExportRecipeDecodeTests` already pins the tolerance ExportRecipe has at its own
// level: a missing top-level key takes the memberwise default and the preset survives.
// That tolerance was one level deep, and one level is not where the damage comes from.
// `decodeIfPresent` answers nil for a key that is ABSENT; a key that is PRESENT is
// handed to its type's own decoder and everything that decoder objects to is rethrown
// straight through it. So:
//
//   * `"sharpen": {"amount":"high"}` written before this build added `medium` throws
//     `keyNotFound` out of `OutputSharpen`'s synthesised decoder;
//   * `"format":"avif"`, or `"medium":"lustre"`, written by a build that ships one,
//     throws `dataCorrupted` out of the enum's;
//   * a value whose type changed throws `typeMismatch` out of either.
//
// `JSONDecoder` decodes an array ATOMICALLY, so any one of those takes every entry with
// it, and `AppState.loadExportRecipes` (AppState.swift:1663-1670) reads the array with
// `try?` and answers `ExportRecipe.defaults`. The first edit afterwards fires `didSet`
// and `saveExportRecipes` writes the stock four over the stored blob. The failure this
// file exists to prevent is therefore not "a field defaulted" — it is EVERY DELIVERY
// PRESET THE PHOTOGRAPHER EVER BUILT REVERTING TO THE STOCK FOUR, silently, on launch,
// with nothing to restore from. Every case below ends in that one assertion.
//
// HOW THESE PAYLOADS ARE BUILT. Not by hand. Each case encodes a real `[ExportRecipe]`
// through the real encoder, parses the result into a dictionary tree, changes exactly
// one thing in it, and re-encodes. A hand-typed blob stops resembling what the app
// actually stores the day a property is renamed and quietly goes on passing; a mutation
// applied to a genuine encode either lands on the real key or fails loudly here
// (`editing` XCTFails when the key it is told to change is not in the encoded form).
//
// WHAT IS RED WITHOUT THE FIX. Every case except one: revert `tolerant` to a plain
// `try decodeIfPresent`, or drop the hand-written `init(from:)` on the four nested
// types, and the decode throws, `loadAsTheAppDoes` substitutes `ExportRecipe.defaults`
// exactly as production does, and the survival assertion prints three custom names
// against the stock four. The exception is `testAKeyALaterBuildAddedInsideANestedObjectCostsNothing`
// — a synthesised decoder already ignores keys it does not know, so that case is green
// either way; it is here as the forward-compatibility guard for the day one of these
// nested types gets custom CodingKeys or a stricter decoder.
//
// WHAT THIS FILE CANNOT REACH. An array element that is not an object at all
// (`["Print", {...}]`) throws before `ExportRecipe.init(from:)` is ever handed a
// container, and no amount of tolerance inside the type can catch it. Closing that door
// needs the element-by-element decode J3-01 asks of `AppState.loadExportRecipes`, which
// is not written; asserting the hole from here would only pin a behaviour we want
// changed, so it is reported rather than tested.

import XCTest
import Foundation
@testable import LumenCore

final class ExportPresetToleranceTests: XCTestCase {

    // MARK: - The photographer's list

    /// Three presets he built himself, over two years, and the only thing that has to
    /// be true at the end of every case: still three, still these, still his.
    private static let customNames = ["Client proof 2048 q80",
                                      "Album master 16-bit",
                                      "Instagram HDR square"]

    private static let customIDs = ["preset-proof", "preset-album", "preset-social"]

    /// Ids fixed rather than minted, so the fixture compares equal to itself across a
    /// round trip and `id` is not silently testing the UUID generator.
    ///
    /// Every nested type is populated on purpose, and with values that are NOT the
    /// memberwise defaults: `sharpen` and `metadata` on all three (they always encode),
    /// `watermark` on the proof preset and `hdr` on the social one (they are optional
    /// and encode only when set). A fallback that quietly replaced one of these would
    /// otherwise be indistinguishable from the value surviving.
    private func customPresets() -> [ExportRecipe] {
        [
            ExportRecipe(id: Self.customIDs[0], name: Self.customNames[0],
                         format: .jpeg, quality: 80, colorSpace: .srgb,
                         resizeMode: .longEdge, resizeValue: 2048,
                         sharpen: OutputSharpen(medium: .screen, amount: .low),
                         metadata: MetadataPolicy(includeEXIF: false,
                                                  includeCameraSerial: false,
                                                  includeGPS: false,
                                                  includeKeywords: false,
                                                  copyright: "© Studio 2026"),
                         watermark: Watermark(text: "PROOF", position: .bottomLeft,
                                              opacity: 35, sizePercent: 4,
                                              insetPercent: 3),
                         filenameTemplate: "{name}-proof", subfolder: "proofs"),
            ExportRecipe(id: Self.customIDs[1], name: Self.customNames[1],
                         enabled: false, format: .tiff, quality: 100, bitDepth: 16,
                         colorSpace: .adobeRGB, resizeMode: .none,
                         sharpen: OutputSharpen(medium: .matte, amount: .high),
                         metadata: MetadataPolicy(includeEXIF: true,
                                                  includeCameraSerial: true,
                                                  includeGPS: false,
                                                  includeKeywords: true,
                                                  copyright: "© Studio 2026",
                                                  contact: "studio@example.com"),
                         filenameTemplate: "{name}-album", subfolder: "album"),
            ExportRecipe(id: Self.customIDs[2], name: Self.customNames[2],
                         format: .heif, quality: 95, colorSpace: .displayP3,
                         resizeMode: .longEdge, resizeValue: 1440,
                         sharpen: OutputSharpen(medium: .screen, amount: .high),
                         metadata: MetadataPolicy(includeEXIF: false,
                                                  includeCameraSerial: false,
                                                  includeGPS: false,
                                                  includeKeywords: false),
                         filenameTemplate: "{name}-ig", subfolder: "social",
                         hdr: HDRSettings(headroomEV: 1.5, mapScale: 0.5,
                                          deliberateSDRBase: true))
        ]
    }

    // MARK: - The payload, and what the app does with it

    private typealias Tree = [[String: Any]]

    /// The stored blob as the app really writes it: a genuine `[ExportRecipe]` through
    /// the genuine encoder, opened up into a tree so a case can change one value in it.
    private func storedTree(file: StaticString = #filePath, line: UInt = #line) -> Tree {
        do {
            let data = try JSONEncoder().encode(customPresets())
            guard let tree = try JSONSerialization.jsonObject(with: data) as? Tree else {
                XCTFail("a stored [ExportRecipe] is no longer a JSON array of objects; "
                        + "these cases mutate that shape and cannot proceed",
                        file: file, line: line)
                return []
            }
            XCTAssertEqual(tree.count, Self.customNames.count,
                           "the fixture itself did not encode as three presets",
                           file: file, line: line)
            return tree
        } catch {
            XCTFail("the fixture would not encode: \(error)", file: file, line: line)
            return []
        }
    }

    /// EXACTLY what `AppState.loadExportRecipes` does (AppState.swift:1663-1670): one
    /// atomic `try?` over the whole array, and `ExportRecipe.defaults` when it throws.
    /// Modelled here rather than asserted away with `XCTAssertNoThrow`, because "it
    /// threw" is not what the photographer sees — what he sees is the stock four, and
    /// that is what these cases must be able to say.
    private func loadAsTheAppDoes(_ data: Data) -> (recipes: [ExportRecipe], threw: Error?) {
        do { return (try JSONDecoder().decode([ExportRecipe].self, from: data), nil) }
        catch { return (ExportRecipe.defaults, error) }
    }

    /// THE HEADLINE ASSERTION, applied by every case: three custom presets in, three
    /// custom presets out, by name.
    @discardableResult
    private func assertTheListSurvived(_ tree: Tree, _ scenario: String,
                                       file: StaticString = #filePath,
                                       line: UInt = #line) -> [ExportRecipe] {
        let payload: Data
        do { payload = try JSONSerialization.data(withJSONObject: tree) }
        catch {
            XCTFail("the mutated tree would not re-encode: \(error)", file: file, line: line)
            return []
        }

        let (recipes, threw) = loadAsTheAppDoes(payload)
        let stock = ExportRecipe.defaults.map(\.name)
        let cause: String
        if let threw {
            cause = """
                Decoding [ExportRecipe] threw \(threw). JSONDecoder decodes an array \
                atomically, so that one unreadable value took every entry with it; \
                AppState.loadExportRecipes swallows the error with `try?` and answers \
                ExportRecipe.defaults — \(stock) — and the next edit's didSet writes \
                those four over the stored blob. Every delivery preset the photographer \
                ever built, gone, with no error and nothing to restore from.
                """
        } else {
            cause = "Nothing threw, so the list did decode — the presets that came back "
                + "are simply not the ones that were stored."
        }

        XCTAssertEqual(recipes.count, Self.customNames.count, """
            \(scenario): the photographer had \(Self.customNames.count) delivery presets \
            and \(recipes.count) came back. \(cause)
            """, file: file, line: line)
        XCTAssertEqual(recipes.map(\.name), Self.customNames, """
            \(scenario): THE DELIVERY PRESET LIST REVERTED TO THE STOCK FOUR. \(cause)
            """, file: file, line: line)
        return recipes
    }

    // MARK: - Mutating the real encoded form

    /// Change one value inside entry `entry`'s nested object under `key`, failing
    /// loudly if that object is not in the encoded form. The point of building the
    /// payload from a real encode is that a renamed key must BREAK this file rather
    /// than let a mutation land on nothing and go on passing.
    private func editing(_ tree: Tree, entry: Int, nested key: String,
                         file: StaticString = #filePath, line: UInt = #line,
                         _ change: (inout [String: Any]) -> Void) -> Tree {
        var tree = tree
        guard tree.indices.contains(entry) else {
            XCTFail("the encoded list has no entry \(entry)", file: file, line: line)
            return tree
        }
        guard var object = tree[entry][key] as? [String: Any] else {
            XCTFail("""
                a stored recipe carries no object under "\(key)" any more — the wire \
                format moved. Point this case at the key that replaced it, and check \
                that key still decodes tolerantly; do not delete the case, because a \
                mutation that lands on nothing proves nothing.
                """, file: file, line: line)
            return tree
        }
        change(&object)
        tree[entry][key] = object
        return tree
    }

    /// The same for a top-level key, which must already be in the encoded form.
    private func editing(_ tree: Tree, entry: Int, key: String, to value: Any,
                         file: StaticString = #filePath, line: UInt = #line) -> Tree {
        var tree = tree
        guard tree.indices.contains(entry) else {
            XCTFail("the encoded list has no entry \(entry)", file: file, line: line)
            return tree
        }
        guard tree[entry].keys.contains(key) else {
            XCTFail("""
                a stored recipe carries no "\(key)" key any more — the wire format \
                moved. Point this case at the key that replaced it rather than \
                deleting it.
                """, file: file, line: line)
            return tree
        }
        tree[entry][key] = value
        return tree
    }

    // MARK: - The control

    /// Unmutated, the fixture round-trips exactly. Without this, a case that "passes"
    /// might only be proving that the tree never resembled a stored preset list.
    func testTheUnmutatedListRoundTripsSoEveryCaseBelowIsolatesOneCorruption() throws {
        let payload = try JSONSerialization.data(withJSONObject: storedTree())
        let list = try JSONDecoder().decode([ExportRecipe].self, from: payload)
        XCTAssertEqual(list, customPresets(),
                       "encode → tree → re-encode → decode is not the identity, so the "
                       + "payloads the cases below mutate are not the app's own")
        XCTAssertEqual(list.map(\.name), Self.customNames)
    }

    // MARK: - A key a later build added, inside a nested object

    /// The forward half of a rollback: a build that has moved on wrote fields inside
    /// `sharpen`, `metadata` and `hdr` that this build has never heard of.
    ///
    /// Green with the fix and without it — a synthesised decoder ignores keys it does
    /// not know — and here anyway, because that is the property being relied on, and
    /// the day one of these types grows custom CodingKeys or a stricter decoder is the
    /// day it stops holding.
    func testAKeyALaterBuildAddedInsideANestedObjectCostsNothing() {
        var tree = storedTree()
        tree = editing(tree, entry: 0, nested: "sharpen") { $0["lightHaloRatio"] = 0.6 }
        tree = editing(tree, entry: 1, nested: "metadata") { $0["copyrightToIPTCOnly"] = true }
        tree = editing(tree, entry: 2, nested: "hdr") { $0["iso21496GainMapVersion"] = 1 }

        let list = assertTheListSurvived(
            tree, "a newer build added a key inside sharpen, metadata and hdr")
        guard list.count == Self.customNames.count else { return }
        XCTAssertEqual(list[0].sharpen, OutputSharpen(medium: .screen, amount: .low),
                       "the sharpening beside the unknown key was replaced by defaults")
        XCTAssertTrue(list[1].metadata.includeCameraSerial,
                      "the policy beside the unknown key was replaced by defaults")
        XCTAssertEqual(list[2].hdr?.mapScale, 0.5,
                       "the HDR settings beside the unknown key were replaced by defaults")
    }

    // MARK: - An enum case a later build invented

    /// `"format":"avif"` — the client rolls back a version, or opens a catalogue the
    /// newer build touched. One raw value this build has no case for.
    func testAFormatFromANewerBuildFallsBackWithoutCostingTheList() {
        var tree = storedTree()
        tree = editing(tree, entry: 1, key: "format", to: "avif")

        let list = assertTheListSurvived(tree, #"a preset stored with "format":"avif""#)
        guard list.count == Self.customNames.count else { return }
        XCTAssertEqual(list[1].format, .jpeg,
                       "the unreadable field falls back; the preset does not")
        XCTAssertEqual(list[1].bitDepth, 16,
                       "and the preset around it is still the photographer's own — "
                       + "one field defaulted, not a stock recipe wearing his name")
        XCTAssertEqual(list[1].subfolder, "album")
        XCTAssertEqual(list[1].sharpen.medium, OutputSharpen.Medium.matte)
        XCTAssertFalse(list[1].enabled)
    }

    /// The same thing one level down, which is the half the old decoder could not
    /// reach: the unknown raw value is on a NESTED type's enum.
    func testASharpenMediumFromANewerBuildFallsBackAndKeepsTheAmountBesideIt() {
        var tree = storedTree()
        tree = editing(tree, entry: 1, nested: "sharpen") { sharpen in
            let stored = sharpen["medium"] as? String
            XCTAssertEqual(stored, "matte",
                           "the fixture no longer stores the value this case corrupts")
            sharpen["medium"] = "lustre"
        }

        let list = assertTheListSurvived(
            tree, #"a preset stored with "sharpen":{"medium":"lustre"}"#)
        guard list.count == Self.customNames.count else { return }
        XCTAssertEqual(list[1].sharpen.medium, OutputSharpen.Medium.none,
                       "an unknown medium falls back to Off")
        XCTAssertEqual(list[1].sharpen.amount, OutputSharpen.Amount.high, """
            the amount BESIDE the unreadable medium was reset to standard: the whole \
            sharpen object was discarded over one unreadable field instead of the one \
            field falling back. That is the granularity the nested init(from:) exists \
            for — the outer fallback alone would silently undo a setting the \
            photographer chose.
            """)
    }

    // MARK: - A key this build added, missing from an old payload

    /// The backward half, and the one that arrives by ordinary means: the payload was
    /// written before this build grew the key, so a required nested field is simply
    /// not there.
    func testANestedObjectMissingAKeyThisBuildAddedCostsNothing() {
        var tree = storedTree()
        tree = editing(tree, entry: 0, nested: "sharpen") { sharpen in
            let removed = sharpen.removeValue(forKey: "medium")
            XCTAssertNotNil(removed, "the fixture no longer stores sharpen.medium")
        }
        tree = editing(tree, entry: 1, nested: "metadata") { metadata in
            let removed = metadata.removeValue(forKey: "includeCameraSerial")
            XCTAssertNotNil(removed,
                            "the fixture no longer stores metadata.includeCameraSerial")
        }

        let list = assertTheListSurvived(
            tree, "a payload written before this build added sharpen.medium and "
                + "metadata.includeCameraSerial")
        guard list.count == Self.customNames.count else { return }
        XCTAssertEqual(list[0].sharpen.medium, OutputSharpen.Medium.none,
                       "the absent field takes the memberwise default")
        XCTAssertEqual(list[0].sharpen.amount, OutputSharpen.Amount.low,
                       "and the field that WAS stored beside it survived, rather than "
                       + "the whole sharpen object being replaced")
        XCTAssertEqual(list[1].metadata.copyright, "© Studio 2026",
                       "the copyright line survived the missing flag beside it")
        XCTAssertEqual(list[1].metadata.contact, "studio@example.com")
    }

    // MARK: - A value whose type changed

    /// A string where a number belongs, at both levels — and a nested object stored as
    /// something that is not an object at all, which is the outer `tolerant`'s own job.
    func testAValueOfTheWrongTypeFallsBackWithoutCostingTheList() {
        var tree = storedTree()
        tree = editing(tree, entry: 0, key: "quality", to: "eighty")
        tree = editing(tree, entry: 0, nested: "watermark") { watermark in
            let stored = watermark["opacity"]
            XCTAssertNotNil(stored, "the fixture no longer stores watermark.opacity")
            watermark["opacity"] = "thirty-five percent"
        }
        tree = editing(tree, entry: 2, key: "hdr", to: "on")

        let list = assertTheListSurvived(
            tree, "a string stored where a number belongs, at the top level and inside "
                + "watermark, and an hdr value that is not an object")
        guard list.count == Self.customNames.count else { return }
        XCTAssertEqual(list[0].quality, 100,
                       "an unreadable quality falls back to the memberwise default")
        XCTAssertEqual(list[0].watermark?.text, "PROOF",
                       "the studio's mark — the part with his work in it — must outlive "
                       + "an unreadable number beside it")
        XCTAssertEqual(list[0].watermark?.opacity, 60)
        XCTAssertEqual(list[0].watermark?.position, Watermark.Position.bottomLeft)
        XCTAssertNil(list[2].hdr,
                     "an hdr value that is not an object at all reads as no HDR: the "
                     + "recipe survives, its gain map does not")
        XCTAssertEqual(list[2].filenameTemplate, "{name}-ig")
    }

    // MARK: - The headline

    /// Everything above, in one blob, which is what a real rollback looks like: a
    /// stored list written by a build that had moved on, read by one that had not.
    ///
    /// Three presets in. Three presets out. By name, by id, and with the naming the
    /// photographer set — because "the list survived" is not the same claim as "four
    /// recipes came back", and the stock four would satisfy a count-only assertion.
    func testThreeCustomPresetsAreStillThreeAfterEveryCorruptionAtOnce() {
        var tree = storedTree()
        // Every corruption below changes the field to something that is NOT its own
        // default, so a fallback can never be mistaken for the value surviving.
        // Proof: a key a later build added, and a string where a number belongs.
        tree = editing(tree, entry: 0, nested: "sharpen") { $0["lightHaloRatio"] = 0.6 }
        tree = editing(tree, entry: 0, key: "quality", to: "eighty")
        // Album: an unknown case on a NESTED enum, a key this build has since added,
        // and an unknown case on a top-level enum.
        tree = editing(tree, entry: 1, nested: "sharpen") { $0["medium"] = "lustre" }
        tree = editing(tree, entry: 1, nested: "metadata") { metadata in
            metadata.removeValue(forKey: "includeCameraSerial")
        }
        tree = editing(tree, entry: 1, key: "colorSpace", to: "rec2100pq")
        // Social: a format only the newer build ships, and an object where a number
        // belongs, inside the nested type most likely to grow one.
        tree = editing(tree, entry: 2, key: "format", to: "avif")
        tree = editing(tree, entry: 2, nested: "hdr") {
            $0["mapScale"] = ["numerator": 1, "denominator": 4]
        }

        let list = assertTheListSurvived(
            tree, "one stored blob carrying an added key, three unknown enum cases, a "
                + "missing key and two wrong types across all three presets")
        guard list.count == Self.customNames.count else { return }

        XCTAssertEqual(list.map(\.id), Self.customIDs,
                       "the ids the export sheet selects rows by did not survive")
        XCTAssertEqual(list.map(\.subfolder), ["proofs", "album", "social"] as [String?],
                       "the delivery folders he set did not survive")
        XCTAssertEqual(list.map(\.filenameTemplate),
                       ["{name}-proof", "{name}-album", "{name}-ig"],
                       "the naming he set did not survive")

        // Each corrupted field fell back, and ONLY it: every assertion below compares
        // against a value the fixture stored and the defaults do not carry.
        XCTAssertEqual(list[0].quality, 100, "the unreadable quality fell back (80 → 100)")
        XCTAssertEqual(list[0].sharpen, OutputSharpen(medium: .screen, amount: .low),
                       "a key a later build added cost the sharpening beside it")
        XCTAssertEqual(list[0].watermark?.text, "PROOF", "the studio's mark survived")
        XCTAssertEqual(list[1].sharpen.medium, OutputSharpen.Medium.none)
        XCTAssertEqual(list[1].sharpen.amount, OutputSharpen.Amount.high,
                       "the amount beside the unknown medium was reset")
        XCTAssertFalse(list[1].metadata.includeCameraSerial,
                       "the key removed from metadata did not fall back to its default")
        XCTAssertEqual(list[1].metadata.copyright, "© Studio 2026",
                       "the copyright line did not survive the flag beside it")
        XCTAssertEqual(list[1].colorSpace, .srgb, "the unknown colour space fell back")
        XCTAssertEqual(list[1].bitDepth, 16, "and 16-bit survived beside it")
        XCTAssertEqual(list[2].format, .jpeg, "the unknown format fell back (heif → jpeg)")
        XCTAssertEqual(list[2].quality, 95, "and the quality beside it is still his")
        XCTAssertEqual(list[2].hdr?.mapScale, 0.25, "the unreadable map scale fell back")
        XCTAssertEqual(list[2].hdr?.headroomEV, 1.5,
                       "the headroom beside the unreadable map scale was reset, so the "
                       + "whole HDRSettings object fell back instead of the one field")
    }
}

/// The other half of J3-01: the ARRAY, not the element.
///
/// The tolerant per-field decoding proved above makes any one `ExportRecipe` survive a
/// field this build does not understand. It cannot make the array survive, because it is
/// the container that throws — `JSONDecoder` decodes an array atomically, so one element
/// that is not even a JSON object takes every sibling with it, and the caller's `try?`
/// answers with the stock four.
///
/// That is the shape the finding actually describes, and it survived the first fix. The
/// reviewer who wrote the tests above found it by reading the caller rather than the
/// decoder, which is the only place it is visible.
final class ExportPresetListDecodeTests: XCTestCase {

    private func recipes(_ names: [String]) -> [ExportRecipe] {
        names.map { ExportRecipe(name: $0) }
    }

    private func wire(_ list: [ExportRecipe]) throws -> [Any] {
        let data = try JSONEncoder().encode(list)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [Any])
    }

    private func data(_ tree: [Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: tree)
    }

    func testOneUnreadableElementCostsOnlyItself() throws {
        var tree = try wire(recipes(["Client proof", "Album master", "Instagram"]))
        tree[1] = "this is not a preset at all"          // a string where an object belongs

        let out = try XCTUnwrap(ExportRecipe.decodeList(try data(tree)))
        XCTAssertEqual(out.map(\.name), ["Client proof", "Instagram"],
                       "one unreadable element must cost one preset, not the list. The "
                       + "failure this prevents is every delivery preset the photographer "
                       + "ever made reverting to the stock four.")
    }

    /// The loop has to make progress on the failing element or it never terminates.
    /// Three consecutive bad entries is the case that catches a decoder which inspects
    /// an element without consuming it.
    func testSeveralUnreadableElementsInARowStillTerminate() throws {
        var tree = try wire(recipes(["A", "B", "C", "D"]))
        tree[1] = 7
        tree[2] = NSNull()
        tree[3] = ["not": "a recipe", "at": "all"]

        let out = try XCTUnwrap(ExportRecipe.decodeList(try data(tree)))
        XCTAssertEqual(out.map(\.name).first, "A")
        XCTAssertLessThanOrEqual(out.count, 4)
    }

    /// An EMPTY list is a statement, not a failure. Answering it with the defaults
    /// resurrects presets the photographer deleted on purpose — the same class of wrong,
    /// in the other direction.
    func testAnEmptyListComesBackEmptyRatherThanAsTheStockFour() throws {
        let out = try XCTUnwrap(ExportRecipe.decodeList(try data([])))
        XCTAssertEqual(out.count, 0)
    }

    /// Only a blob that is not a list at all earns the defaults.
    func testSomethingThatIsNotAListAtAllIsRefused() throws {
        let notAList = try JSONSerialization.data(withJSONObject: ["nope": true])
        XCTAssertNil(ExportRecipe.decodeList(notAList))
        XCTAssertNil(ExportRecipe.decodeList(Data("garbage".utf8)))
    }

    func testAHealthyListIsUnchanged() throws {
        let list = recipes(["One", "Two", "Three"])
        let out = try XCTUnwrap(ExportRecipe.decodeList(try JSONEncoder().encode(list)))
        XCTAssertEqual(out.map(\.name), ["One", "Two", "Three"])
    }

    /// And the caller has to use it. `AppState` is in `LumenApp`, which has no test
    /// target on this lane, so this reads it as text — with comments stripped, because
    /// this file's own prose names the symbol.
    func testTheCallerDecodesTheListElementByElement() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/LumenApp")
        var src = try String(contentsOf: root.appendingPathComponent("AppState.swift"),
                             encoding: .utf8)
        // comment strip
        var out = ""; var i = src.startIndex; var block = false
        while i < src.endIndex {
            let rest = src[i...]
            if block {
                if rest.hasPrefix("*/") { block = false; i = src.index(i, offsetBy: 2) }
                else { i = src.index(after: i) }
                continue
            }
            if rest.hasPrefix("/*") { block = true; i = src.index(i, offsetBy: 2); continue }
            if rest.hasPrefix("//") {
                while i < src.endIndex, src[i] != "\n" { i = src.index(after: i) }
                continue
            }
            out.append(src[i]); i = src.index(after: i)
        }
        src = out

        XCTAssertTrue(src.contains("ExportRecipe.decodeList("),
                      "loadExportRecipes must decode element by element; an atomic array "
                      + "decode reverts every preset over one bad entry")
        XCTAssertFalse(src.contains("decode([ExportRecipe].self"),
                       "the atomic array decode is the defect and must not remain")
        XCTAssertFalse(src.contains("!stored.isEmpty"),
                       "an empty preset list is the photographer's decision, not a "
                       + "failure to be replaced with the stock four")
    }
}
