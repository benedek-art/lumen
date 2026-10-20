// SelectivePasteTests.swift
// Paste Selected Settings and settings presets (SelectivePaste.swift).
//
// The case this exists for: white balance and exposure synced across a burst of a
// soccer game must leave every frame's own crop, masks and spots exactly where they
// were. Each group is checked to carry its subtree and nothing else.

import XCTest
@testable import LumenCore

final class SelectivePasteTests: XCTestCase {

    private func source() -> Recipe {
        var r = Recipe()
        r.develop.raw.temp = 3400
        r.develop.raw.tint = 12
        r.develop.raw.decoder = "lumen"
        r.develop.raw.decoderVersion = 9
        r.develop.tone.exposure = 1.3
        r.develop.tone.shadows = 40
        r.develop.color.vibrance = 25
        r.develop.detail.texture = 18
        r.develop.denoise.mode = .classic
        r.develop.geometry.crop = Crop(x: 0.1, y: 0.1, w: 0.5, h: 0.5)
        r.develop.geometry.angle = 2.5
        r.develop.geometry.lens.removeCA.toggle()
        r.look.vignette = -1
        r.masks = [Mask(id: "m-src", name: "Sky")]
        return r
    }

    private func target() -> Recipe {
        var r = Recipe()
        r.develop.raw.temp = 5600
        r.develop.tone.exposure = -0.5
        r.develop.geometry.crop = Crop(x: 0.2, y: 0.3, w: 0.4, h: 0.6)
        r.develop.geometry.angle = -1
        r.masks = [Mask(id: "m-own", name: "Face")]
        r.develop.heal.spots = [HealSpot(x: 0.5, y: 0.5, sourceX: 0.6, sourceY: 0.6)]
        return r
    }

    func testExposureAndWhiteBalanceLeaveCropMasksAndSpotsAlone() {
        let out = target().adopting(PasteGroup.exposureAndWhiteBalance, from: source())
        XCTAssertEqual(out.develop.raw.temp, 3400)
        XCTAssertEqual(out.develop.raw.tint, 12)
        XCTAssertEqual(out.develop.tone.exposure, 1.3)
        XCTAssertEqual(out.develop.tone.shadows, 40)
        XCTAssertEqual(out.develop.geometry.crop, target().develop.geometry.crop)
        XCTAssertEqual(out.develop.geometry.angle, -1)
        XCTAssertEqual(out.masks.map(\.id), ["m-own"])
        XCTAssertEqual(out.develop.heal.spots.count, 1)
        XCTAssertEqual(out.develop.color, target().develop.color)
        XCTAssertEqual(out.look, target().look)
    }

    func testWhiteBalanceNeverCarriesTheDecoderPin() {
        let out = target().adopting([.whiteBalance], from: source())
        XCTAssertEqual(out.develop.raw.decoder, target().develop.raw.decoder)
        XCTAssertEqual(out.develop.raw.decoderVersion, target().develop.raw.decoderVersion)
    }

    func testEachGroupChangesOnlyItsOwnSubtree() {
        let s = source(), t = target()
        for group in PasteGroup.allCases {
            let out = t.adopting([group], from: s)
            let changed = t.differingGroups(from: out)
            XCTAssertTrue(changed.isSubset(of: [group]),
                          "\(group) also changed \(changed.subtracting([group]))")
        }
    }

    func testCropGroupCarriesFramingButNotLens() {
        let out = target().adopting([.crop], from: source())
        XCTAssertEqual(out.develop.geometry.crop, source().develop.geometry.crop)
        XCTAssertEqual(out.develop.geometry.angle, 2.5)
        XCTAssertEqual(out.develop.geometry.lens, target().develop.geometry.lens)
    }

    func testAllGroupsMatchesPasteSettingsWithRetouch() {
        let s = source(), t = target()
        let all = t.adopting(Set(PasteGroup.allCases), from: s)
        var expected = t.adoptingSettings(from: s, includingMasks: true, includingRetouch: true)
        // The whole-recipe paste carries the decoder pin; selective paste never does.
        expected.develop.raw.decoder = t.develop.raw.decoder
        expected.develop.raw.decoderVersion = t.develop.raw.decoderVersion
        XCTAssertEqual(all, expected)
    }

    func testEmptySelectionIsANoOp() {
        let t = target()
        XCTAssertEqual(t.adopting([], from: source()), t)
    }

    func testSyncDefaultLeavesPerFrameGroupsOut() {
        XCTAssertTrue(PasteGroup.syncDefault.isDisjoint(with: PasteGroup.perFrame))
        XCTAssertEqual(PasteGroup.syncDefault.union(PasteGroup.perFrame),
                       Set(PasteGroup.allCases))
    }

    func testSpotsLeftBehindDoNotRaiseTheStamp() {
        var s = source()
        s.develop.heal.spots = [HealSpot(x: 0.1, y: 0.1, sourceX: 0.2, sourceY: 0.2)]
        XCTAssertGreaterThanOrEqual(s.pipelineVersion, healSpotsPipelineVersion)
        var t = Recipe()
        t.pipelineVersion = 1
        let out = t.adopting([.tone], from: s)
        XCTAssertLessThan(out.pipelineVersion, healSpotsPipelineVersion)
        let withSpots = t.adopting([.tone, .retouch], from: s)
        XCTAssertGreaterThanOrEqual(withSpots.pipelineVersion, healSpotsPipelineVersion)
    }

    func testLookKeepsTargetRenderPresetAcrossRegisters() {
        var jpeg = source()
        jpeg.look.render.preset = LookSubset.linearPresetName
        var raw = target()
        raw.look.render.preset = "Neutral"
        let out = raw.adopting([.look], from: jpeg)
        XCTAssertEqual(out.look.render.preset, "Neutral")
        XCTAssertEqual(out.look.vignette, -1)
    }

    func testPresetRoundTripsAndAppliesOnlyItsGroups() {
        var jpeg = source()
        jpeg.look.render.preset = LookSubset.linearPresetName
        let preset = SettingsPreset(name: "Indoor 6400",
                                    groups: [.denoise, .whiteBalance, .look], recipe: jpeg)
        XCTAssertEqual(preset.groups, [.whiteBalance, .denoise, .look])
        var library = SettingsPresetLibrary()
        XCTAssertTrue(library.save(preset))
        let decoded = SettingsPresetLibrary.decode(library.encoded())
        XCTAssertEqual(decoded, library)

        var other = Recipe()
        other.look.render.preset = LookSubset.linearPresetName
        let out = decoded.presets[0].applied(to: other)
        XCTAssertEqual(out.develop.raw.temp, 3400)
        XCTAssertEqual(out.develop.denoise.mode, .classic)
        XCTAssertEqual(out.develop.tone, other.develop.tone)
        // JPEG preset onto a JPEG: Linear survives because the stored source kept it.
        XCTAssertEqual(out.look.render.preset, LookSubset.linearPresetName)
    }

    func testLibrarySaveReplacesByNameAndRefusesBlanks() {
        var library = SettingsPresetLibrary()
        XCTAssertTrue(library.save(SettingsPreset(name: "Night", groups: [.tone],
                                                  recipe: source())))
        XCTAssertTrue(library.save(SettingsPreset(name: "  night ", groups: [.detail],
                                                  recipe: source())))
        XCTAssertEqual(library.presets.count, 1)
        XCTAssertEqual(library.presets[0].groups, [.detail])
        XCTAssertFalse(library.save(SettingsPreset(name: "   ", groups: [.tone],
                                                   recipe: source())))
        XCTAssertFalse(library.save(SettingsPreset(name: "Empty", groups: [],
                                                   recipe: source())))
        library.delete(named: "NIGHT")
        XCTAssertTrue(library.presets.isEmpty)
    }

    func testDecodeSkipsBadEntriesAndUnknownGroups() throws {
        var library = SettingsPresetLibrary()
        library.save(SettingsPreset(name: "Good", groups: [.tone], recipe: source()))
        var array = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: library.encoded()) as? [[String: Any]])
        var future = array[0]
        future["name"] = "Future"
        future["groups"] = ["tone", "hologram"]
        array.append(future)
        array.append(["name": 7])
        let data = try JSONSerialization.data(withJSONObject: array)
        let decoded = SettingsPresetLibrary.decode(data)
        XCTAssertEqual(decoded.presets.map(\.name), ["Good", "Future"])
        XCTAssertEqual(decoded.presets[1].groups, [.tone])
        XCTAssertTrue(SettingsPresetLibrary.decode(Data("nope".utf8)).presets.isEmpty)
    }
}
