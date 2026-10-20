// DevelopPresetTests.swift
// Develop presets: only the chosen groups are stored and applied, the file format round
// trips and refuses what it cannot read, and the library's names stay unique.

import XCTest
@testable import LumenCore

final class DevelopPresetTests: XCTestCase {

    /// A high-ISO soccer frame: WB, NR, sharpening worth keeping, plus a crop, masks and
    /// spots that must never travel in a preset.
    private func soccerFrame() -> Recipe {
        var r = Recipe()
        r.develop.raw.temp = 5200
        r.develop.raw.tint = 6
        r.develop.denoise.amount = 70
        r.develop.denoise.classic.luma = 45
        r.develop.detail.sharpen.amount = 55
        r.develop.tone.exposure = 0.3
        r.develop.detail.clarity = 12
        r.develop.geometry.crop = Crop(x: 0.1, y: 0.1, w: 0.5, h: 0.5)
        r.masks = [Mask(id: "m1", name: "Player")]
        r.develop.heal.spots = [HealSpot(id: "a", x: 0.3, y: 0.4, sourceX: 0.35, sourceY: 0.4)]
        r.develop.heal.count = 1
        return r
    }

    private let soccerGroups: Set<SettingsGroup> = [.whiteBalance, .noiseReduction, .sharpening]

    private func soccerPreset() -> DevelopPreset {
        DevelopPreset.captured(named: "Soccer ISO 6400", from: soccerFrame(),
                               groups: soccerGroups)!
    }

    private func otherFrame() -> Recipe {
        var r = Recipe()
        r.develop.raw.temp = 3000
        r.develop.tone.exposure = -0.5
        r.develop.detail.clarity = -8
        r.develop.geometry.crop = Crop(x: 0.2, y: 0.0, w: 0.6, h: 0.8)
        r.masks = [Mask(id: "own", name: "Face")]
        return r
    }

    // MARK: Capture and apply

    func testOnlyTheChosenGroupsAreStored() {
        let preset = soccerPreset()
        XCTAssertEqual(preset.groups, soccerGroups)
        XCTAssertEqual(preset.settings.develop.raw.temp, 5200)
        XCTAssertEqual(preset.settings.develop.denoise.amount, 70)
        XCTAssertEqual(preset.settings.develop.detail.sharpen.amount, 55)
        // Unchosen groups are the defaults, so the stored JSON is sparse.
        XCTAssertEqual(preset.settings.develop.tone, Recipe().develop.tone)
        XCTAssertEqual(preset.settings.develop.detail.clarity, Recipe().develop.detail.clarity)
        XCTAssertEqual(preset.settings.develop.geometry, Recipe().develop.geometry)
        XCTAssertTrue(preset.settings.masks.isEmpty)
        XCTAssertTrue(preset.settings.develop.heal.spots.isEmpty)
        XCTAssertLessThanOrEqual(preset.settings.pipelineVersion, currentPipelineVersion,
                                 "spots stayed behind, so the stamp must not claim them")
    }

    func testApplyingCarriesOnlyThePresetsGroups() {
        let applied = soccerPreset().applied(to: otherFrame())
        XCTAssertEqual(applied.develop.raw.temp, 5200)
        XCTAssertEqual(applied.develop.raw.tint, 6)
        XCTAssertEqual(applied.develop.denoise, soccerFrame().develop.denoise)
        XCTAssertEqual(applied.develop.detail.sharpen, soccerFrame().develop.detail.sharpen)
        // The target's own exposure, clarity, crop and masks survive.
        XCTAssertEqual(applied.develop.tone.exposure, -0.5)
        XCTAssertEqual(applied.develop.detail.clarity, -8)
        XCTAssertEqual(applied.develop.geometry.crop, otherFrame().develop.geometry.crop)
        XCTAssertEqual(applied.masks, otherFrame().masks)
    }

    /// A preset and a Sync of the same groups land identically.
    func testApplyingMatchesASyncOfTheSameGroups() {
        let viaSync = otherFrame().adoptingSettings(from: soccerFrame(), groups: soccerGroups)
        XCTAssertEqual(soccerPreset().applied(to: otherFrame()), viaSync)
    }

    func testPerFrameGroupsAreNeverOffered() {
        XCTAssertFalse(DevelopPreset.offeredGroups.contains(.crop))
        XCTAssertFalse(DevelopPreset.offeredGroups.contains(.masks))
        XCTAssertFalse(DevelopPreset.offeredGroups.contains(.spotRemoval))
        XCTAssertTrue(DevelopPreset.offeredGroups.contains(.noiseReduction))
        XCTAssertTrue(DevelopPreset.defaultGroups.isSubset(of: Set(DevelopPreset.offeredGroups)))
        let preset = DevelopPreset.captured(named: "Sneaky", from: soccerFrame(),
                                            groups: [.crop, .masks, .whiteBalance])!
        XCTAssertEqual(preset.groups, [.whiteBalance])
        let applied = preset.applied(to: otherFrame())
        XCTAssertEqual(applied.develop.geometry, otherFrame().develop.geometry)
        XCTAssertEqual(applied.masks, otherFrame().masks)
    }

    func testANamelessOrEmptyPresetIsRefused() {
        XCTAssertNil(DevelopPreset.captured(named: "  ", from: soccerFrame(),
                                            groups: soccerGroups))
        XCTAssertNil(DevelopPreset.captured(named: "Crop only", from: soccerFrame(),
                                            groups: [.crop]))
        XCTAssertNil(DevelopPreset.captured(named: "Nothing", from: soccerFrame(), groups: []))
        XCTAssertEqual(DevelopPreset.captured(named: "  Astro   base ", from: Recipe(),
                                              groups: [.whiteBalance])?.name, "Astro base")
    }

    // MARK: Files

    func testAPresetFileRoundTrips() throws {
        let preset = soccerPreset()
        let data = try preset.fileData()
        XCTAssertEqual(try DevelopPreset.presets(fromFileData: data), [preset])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"format\":\"lumen-develop-preset\""))
        XCTAssertFalse(text.contains("clarity"), "unchosen groups must not be written")
    }

    func testALibraryFileRoundTrips() throws {
        let astro = DevelopPreset.captured(named: "Astro base", from: otherFrame(),
                                           groups: [.whiteBalance, .tone, .lens])!
        let presets = [astro, soccerPreset()]
        let data = try DevelopPreset.libraryData(presets)
        XCTAssertEqual(try DevelopPreset.presets(fromFileData: data), presets)
    }

    func testTheFileIsDeterministic() throws {
        XCTAssertEqual(try soccerPreset().fileData(), try soccerPreset().fileData())
    }

    func testBadFilesAreRefusedByName() {
        func refusal(_ text: String) -> DevelopPresetFileError? {
            do {
                _ = try DevelopPreset.presets(fromFileData: Data(text.utf8))
                return nil
            } catch let error as DevelopPresetFileError {
                return error
            } catch {
                return nil
            }
        }
        XCTAssertEqual(refusal("not json"), .notJSON)
        XCTAssertEqual(refusal(#"{"format":"lumen-look","version":1}"#), .notAPresetFile)
        XCTAssertEqual(refusal(#"{"format":"lumen-develop-preset","version":2,"preset":{}}"#),
                       .newerFormat(2))
        XCTAssertEqual(refusal(#"{"format":"lumen-develop-preset","version":1,"preset":"#
                               + #"{"name":"X","groups":["whiteBalance"],"#
                               + #""settings":{"pipelineVersion":99}}}"#),
                       .newerRecipe(99))
        XCTAssertEqual(refusal(#"{"format":"lumen-develop-preset","version":1,"preset":"#
                               + #"{"name":"X","groups":["crop","futureGroup"],"#
                               + #""settings":{"pipelineVersion":2}}}"#),
                       .emptyPreset)
    }

    func testUnknownGroupsAndKeysAreDroppedNotFatal() throws {
        let text = #"{"format":"lumen-develop-preset","version":1,"futureKey":true,"preset":"#
            + #"{"name":"WB","groups":["whiteBalance","futureGroup"],"#
            + #""settings":{"pipelineVersion":2,"develop":{"raw":{"temp":4100}},"futureTree":{}}}}"#
        let presets = try DevelopPreset.presets(fromFileData: Data(text.utf8))
        XCTAssertEqual(presets.count, 1)
        XCTAssertEqual(presets[0].groups, [.whiteBalance])
        XCTAssertEqual(presets[0].settings.develop.raw.temp, 4100)
    }

    func testSuggestedFileNameIsSafe() {
        var preset = soccerPreset()
        preset.name = "A/B: test"
        XCTAssertEqual(preset.suggestedFileName, "A-B- test.lumenpreset")
    }

    // MARK: Library

    func testSaveReplacesByNameCaseInsensitively() {
        var library = DevelopPresetLibrary()
        XCTAssertFalse(library.save(soccerPreset()))
        var louder = soccerPreset()
        louder.name = "SOCCER iso 6400"
        louder.groups = [.whiteBalance]
        XCTAssertTrue(library.save(louder))
        XCTAssertEqual(library.presets.count, 1)
        XCTAssertEqual(library.presets[0].name, "SOCCER iso 6400")
        XCTAssertEqual(library.preset(named: "soccer ISO 6400")?.groups, [.whiteBalance])
    }

    func testPresetsAreSortedByName() {
        var b = soccerPreset(); b.name = "beta"
        var a = soccerPreset(); a.name = "Alpha"
        var c = soccerPreset(); c.name = "Charlie"
        let library = DevelopPresetLibrary([c, b, a])
        XCTAssertEqual(library.presets.map(\.name), ["Alpha", "beta", "Charlie"])
    }

    func testRenameRefusesATakenNameButAllowsACaseChange() throws {
        var astro = soccerPreset(); astro.name = "Astro"
        var library = DevelopPresetLibrary([soccerPreset(), astro])
        XCTAssertThrowsError(try library.renamePreset("Astro", to: "soccer iso 6400")) { error in
            XCTAssertEqual(error as? DevelopPresetLibrary.EditError, .nameTaken("soccer iso 6400"))
        }
        XCTAssertThrowsError(try library.renamePreset("Astro", to: "   ")) { error in
            XCTAssertEqual(error as? DevelopPresetLibrary.EditError, .invalidName)
        }
        XCTAssertThrowsError(try library.renamePreset("Missing", to: "X")) { error in
            XCTAssertEqual(error as? DevelopPresetLibrary.EditError, .notFound)
        }
        try library.renamePreset("Astro", to: "ASTRO")
        XCTAssertNotNil(library.preset(named: "ASTRO"))
        try library.renamePreset("ASTRO", to: "Milky Way")
        XCTAssertEqual(library.presets.map(\.name), ["Milky Way", "Soccer ISO 6400"])
    }

    func testDelete() {
        var library = DevelopPresetLibrary([soccerPreset()])
        XCTAssertFalse(library.delete(named: "Astro"))
        XCTAssertTrue(library.delete(named: "soccer iso 6400"))
        XCTAssertTrue(library.presets.isEmpty)
    }

    func testImportSkipsIdenticalAndRenamesClashes() {
        var library = DevelopPresetLibrary([soccerPreset()])
        var different = soccerPreset()
        different.groups = [.whiteBalance]
        let result = library.importing([soccerPreset(), different, different])
        // The second copy of `different` finds the first under its clash name.
        XCTAssertEqual(result.unchanged, ["Soccer ISO 6400", "Soccer ISO 6400 2"])
        XCTAssertEqual(result.added, ["Soccer ISO 6400 2"])
        XCTAssertEqual(library.presets.count, 2)
        XCTAssertEqual(library.preset(named: "Soccer ISO 6400")?.groups, soccerGroups)
        // Importing the whole library back into itself adds nothing.
        let again = library.importing(library.presets)
        XCTAssertTrue(again.added.isEmpty)
    }

    func testMatchingForThePalette() {
        var astro = soccerPreset(); astro.name = "Astro base"
        var night = soccerPreset(); night.name = "Night sky"
        let library = DevelopPresetLibrary([soccerPreset(), astro, night])
        XCTAssertEqual(library.matching("").map(\.name), [])
        XCTAssertEqual(library.matching("socc").map(\.name), ["Soccer ISO 6400"])
        XCTAssertEqual(library.matching("sky").map(\.name), ["Night sky"])
        XCTAssertEqual(library.matching("6400").map(\.name), ["Soccer ISO 6400"])
        XCTAssertEqual(library.matching("preset").count, 3)
        XCTAssertEqual(library.matching("preset astro").map(\.name), ["Astro base"])
        XCTAssertEqual(library.matching("p").map(\.name), [])
    }

    // MARK: Store

    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevelopPresetTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testStoreRoundTripsAndAbsentIsEmpty() throws {
        let presetFile = DevelopPresetStore(directory: try temporaryDirectory()
            .appendingPathComponent("nested"))
        XCTAssertEqual(try presetFile.load(), DevelopPresetLibrary())
        let library = DevelopPresetLibrary([soccerPreset()])
        try presetFile.save(library)
        XCTAssertEqual(try presetFile.load(), library)
        XCTAssertEqual(presetFile.url.lastPathComponent, "DevelopPresets.json")
    }

    func testAnUnreadableLibraryIsSetAsideNotOverwritten() throws {
        let presetFile = DevelopPresetStore(directory: try temporaryDirectory())
        try Data("garbage".utf8).write(to: presetFile.url)
        XCTAssertThrowsError(try presetFile.load())
        let first = presetFile.setAsideUnreadable()
        XCTAssertEqual(first?.lastPathComponent, "DevelopPresets.json.unreadable")
        XCTAssertFalse(FileManager.default.fileExists(atPath: presetFile.url.path))
        try Data("garbage again".utf8).write(to: presetFile.url)
        XCTAssertEqual(presetFile.setAsideUnreadable()?.lastPathComponent,
                       "DevelopPresets.json.unreadable-2")
        XCTAssertEqual(try Data(contentsOf: first!), Data("garbage".utf8))
    }
}
