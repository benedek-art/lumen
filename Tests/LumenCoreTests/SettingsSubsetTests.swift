// SettingsSubsetTests.swift
// Copy Settings… / Sync Settings…: only the ticked groups travel, every field belongs to
// exactly one group, and the version stamp follows `adoptingSettings`.

import XCTest
@testable import LumenCore

final class SettingsSubsetTests: XCTestCase {

    /// A source that differs from the default recipe in every field a group carries.
    private func source() -> Recipe {
        var r = Recipe(pipelineVersion: 2)
        r.develop.raw.decoder = "lumen"
        r.develop.raw.decoderVersion = 9
        r.develop.raw.temp = 3200
        r.develop.raw.tint = 12
        r.develop.tone.exposure = 0.7
        r.develop.zones.mid.ev = 0.3
        r.develop.curve.parametric.lights = 20
        r.develop.color.vibrance = 15
        r.develop.mixer.uniformity = 40
        r.develop.pointColors = [PointColor(sample: [0.5, 0.4, 0.3])]
        r.develop.detail.texture = 10
        r.develop.detail.clarity = 11
        r.develop.detail.dehaze = 12
        r.develop.detail.capture = CaptureSharpen(auto: false, radius: 0.8, amount: 60)
        r.develop.detail.sharpen.amount = 70
        r.develop.denoise.amount = 80
        r.develop.denoise.classic.luma = 35
        r.develop.geometry.crop = Crop(x: 0.1, y: 0.1, w: 0.5, h: 0.5)
        r.develop.geometry.angle = 2.5
        r.develop.geometry.flipH = true
        r.develop.geometry.lens = LensCorrections(profile: false, removeCA: false)
        r.look.bw = BlackAndWhite(bands: [0, 0, 0, 0, -40, -65, 0, 0], enabled: false)
        r.look.wheels.blending = 70
        r.look.printerLights = PrinterLights(master: 2, r: 1, g: 0, b: -1)
        r.look.primaries.rHue = 5
        r.look.render.preset = "Punchy"
        r.look.lut = LUTReference(ref: "blob:xxh64:0000000000000001", name: "Teal")
        r.look.vignette = -1
        r.look.vignetteFeather = 20
        r.look.grain = CreativeGrain(amount: 30)
        r.look.filmLab = FilmLab(stock: "lumen/portra400")
        r.masks = [Mask(id: "m1", name: "Sky", group: "g1")]
        r.maskGroups = [MaskGroup(id: "g1", name: "Sky work")]
        r.develop.heal.spots = [HealSpot(id: "a", x: 0.3, y: 0.4, sourceX: 0.35, sourceY: 0.4)]
        r.develop.heal.count = 1
        return r
    }

    private func target() -> Recipe {
        var r = Recipe(pipelineVersion: 1)
        r.develop.raw.decoderVersion = 8
        r.develop.tone.exposure = -0.4
        r.develop.geometry.crop = Crop(x: 0.2, y: 0.0, w: 0.6, h: 0.8)
        r.develop.denoise.classic.luma = 60
        r.masks = [Mask(id: "own", name: "Face")]
        return r
    }

    func testAnEmptyChoiceChangesNothing() {
        XCTAssertEqual(target().adoptingSettings(from: source(), groups: []), target())
    }

    /// Every group ticked is a whole-recipe paste with masks and spots, less the two
    /// per-file decoder fields. If a new field reaches `Develop` or `Look` without a
    /// group, this fails — and the field-count guard below says which struct grew.
    func testEveryGroupTogetherIsTheWholePaste() {
        let src = source()
        var whole = target().adoptingSettings(from: src, includingMasks: true,
                                              includingRetouch: true)
        whole.develop.raw.decoder = target().develop.raw.decoder
        whole.develop.raw.decoderVersion = target().develop.raw.decoderVersion
        XCTAssertEqual(target().adoptingSettings(from: src, groups: Set(SettingsGroup.allCases)),
                       whole)
    }

    func testTheGroupTableCoversTheRecipeAsItIsToday() {
        XCTAssertEqual(Mirror(reflecting: Develop()).children.count, 11,
                       "Develop grew a field: give it a SettingsGroup")
        XCTAssertEqual(Mirror(reflecting: Look()).children.count, 10,
                       "Look grew a field: give it a SettingsGroup")
        // The three structs the table splits field by field rather than whole.
        XCTAssertEqual(Mirror(reflecting: RawParams()).children.count, 4,
                       "RawParams grew a field: decide its SettingsGroup")
        XCTAssertEqual(Mirror(reflecting: Detail()).children.count, 5,
                       "Detail grew a field: decide its SettingsGroup")
        XCTAssertEqual(Mirror(reflecting: Geometry()).children.count, 5,
                       "Geometry grew a field: decide its SettingsGroup")
        XCTAssertEqual(Mirror(reflecting: Recipe()).children.count, 5,
                       "Recipe grew a field: decide whether a SettingsGroup carries it")
    }

    /// Each group alone changes something, and taking one group never moves a field
    /// another group owns: the groups partition the recipe.
    func testEachGroupAloneIsDisjointFromTheRest() {
        let src = source()
        let base = target()
        for group in SettingsGroup.allCases {
            let one = base.adoptingSettings(from: src, groups: [group])
            XCTAssertNotEqual(one, base, "\(group) carried nothing")
            let rest = Set(SettingsGroup.allCases).subtracting([group])
            // Applying the rest on top of `one` must give the same as all of them,
            // and applying `group` on top of the rest must too — order-free.
            let all = base.adoptingSettings(from: src, groups: Set(SettingsGroup.allCases))
            XCTAssertEqual(one.adoptingSettings(from: src, groups: rest), all, "\(group)")
            XCTAssertEqual(base.adoptingSettings(from: src, groups: rest)
                            .adoptingSettings(from: src, groups: [group]), all, "\(group)")
        }
    }

    /// The case that motivated this: white balance across a burst without touching
    /// each frame's crop, exposure, masks or spots.
    func testWhiteBalanceAloneLeavesTheFrameItsOwn() {
        let out = target().adoptingSettings(from: source(), groups: [.whiteBalance])
        XCTAssertEqual(out.develop.raw.temp, 3200)
        XCTAssertEqual(out.develop.raw.tint, 12)
        XCTAssertEqual(out.develop.raw.decoderVersion, 8, "a decoder pin is the file's")
        XCTAssertEqual(out.develop.tone.exposure, -0.4)
        XCTAssertEqual(out.develop.geometry, target().develop.geometry)
        XCTAssertEqual(out.masks, target().masks)
        XCTAssertTrue(out.develop.heal.spots.isEmpty)
        XCTAssertEqual(out.look, target().look)
    }

    func testCropAndLensTravelApart() {
        let src = source()
        let crop = target().adoptingSettings(from: src, groups: [.crop])
        XCTAssertEqual(crop.develop.geometry.crop, src.develop.geometry.crop)
        XCTAssertEqual(crop.develop.geometry.angle, 2.5)
        XCTAssertEqual(crop.develop.geometry.lens, LensCorrections())
        let lens = target().adoptingSettings(from: src, groups: [.lens])
        XCTAssertEqual(lens.develop.geometry.crop, target().develop.geometry.crop)
        XCTAssertEqual(lens.develop.geometry.lens, src.develop.geometry.lens)
    }

    func testPresenceAndSharpeningSplitDetail() {
        let src = source()
        let presence = target().adoptingSettings(from: src, groups: [.presence])
        XCTAssertEqual(presence.develop.detail.clarity, 11)
        XCTAssertEqual(presence.develop.detail.sharpen, ManualSharpen())
        let sharpening = target().adoptingSettings(from: src, groups: [.sharpening])
        XCTAssertEqual(sharpening.develop.detail.sharpen.amount, 70)
        XCTAssertEqual(sharpening.develop.detail.clarity, 0)
        XCTAssertEqual(sharpening.develop.denoise, target().develop.denoise,
                       "noise reduction is its own group")
    }

    func testMasksReplaceWithTheirFolders() {
        let out = target().adoptingSettings(from: source(), groups: [.masks])
        XCTAssertEqual(out.masks, source().masks)
        XCTAssertEqual(out.maskGroups, source().maskGroups)
        XCTAssertEqual(out.develop, target().develop)
    }

    // MARK: Version stamp

    /// Spots that stay behind do not stamp the target as a spot recipe — the cap
    /// `adoptingSettings` owns, reached through the donor.
    func testSpotsLeftBehindDoNotRaiseTheStampToTheSpotVersion() {
        let src = source()
        XCTAssertGreaterThanOrEqual(src.pipelineVersion, healSpotsPipelineVersion)
        let out = target().adoptingSettings(from: src, groups: [.whiteBalance])
        XCTAssertLessThan(out.pipelineVersion, healSpotsPipelineVersion)
        XCTAssertGreaterThanOrEqual(out.pipelineVersion, 2,
                                    "the M-06 raise for what did travel still happens")
        let spots = target().adoptingSettings(from: src, groups: [.spotRemoval])
        XCTAssertEqual(spots.develop.heal, src.develop.heal)
        XCTAssertGreaterThanOrEqual(spots.pipelineVersion, healSpotsPipelineVersion)
    }

    func testANewerTargetIsNeverLowered() {
        var newer = target()
        newer.pipelineVersion = 99
        XCTAssertEqual(newer.adoptingSettings(from: source(), groups: [.tone]).pipelineVersion,
                       99)
    }

    func testTheRenderPresetKeepsItsRegisterBoundary() {
        var jpeg = target()
        jpeg.look.render.preset = LookSubset.linearPresetName
        let out = jpeg.adoptingSettings(from: source(), groups: [.displayTransform])
        XCTAssertEqual(out.look.render.preset, LookSubset.linearPresetName)
        XCTAssertEqual(out.look.lut, source().look.lut)
        let untouched = jpeg.adoptingSettings(from: source(), groups: [.tone])
        XCTAssertEqual(untouched.look.render.preset, LookSubset.linearPresetName)
    }

    // MARK: Remembering

    func testTheDefaultLeavesEveryPerFrameGroupBehind() {
        let d = SettingsGroup.defaultSelection
        for group in [SettingsGroup.crop, .masks, .spotRemoval, .noiseReduction] {
            XCTAssertFalse(d.contains(group), "\(group)")
        }
        XCTAssertTrue(d.contains(.whiteBalance))
        XCTAssertEqual(d.count, SettingsGroup.allCases.count - 4)
    }

    func testStorageRoundTrips() {
        XCTAssertEqual(SettingsGroup.fromStorageString(nil), SettingsGroup.defaultSelection)
        XCTAssertEqual(SettingsGroup.fromStorageString(""), [])
        for set: Set<SettingsGroup> in [[], [.whiteBalance], [.noiseReduction, .crop],
                                         Set(SettingsGroup.allCases)] {
            XCTAssertEqual(SettingsGroup.fromStorageString(SettingsGroup.storageString(set)),
                           set)
        }
        XCTAssertEqual(SettingsGroup.fromStorageString("tone,renamedLongAgo"), [.tone])
    }

    func testSummaryReadsInMenuOrder() {
        XCTAssertEqual(SettingsGroup.summary([]), "nothing")
        XCTAssertEqual(SettingsGroup.summary([.tone, .whiteBalance]),
                       "White Balance and Exposure & Tone")
        XCTAssertEqual(SettingsGroup.summary([.crop, .tone, .whiteBalance, .masks]),
                       "White Balance, Exposure & Tone and 2 more")
    }
}

final class PreviousPhotoTests: XCTestCase {

    private let a = URL(fileURLWithPath: "/shoot/a.ARW")
    private let b = URL(fileURLWithPath: "/shoot/b.ARW")
    private let c = URL(fileURLWithPath: "/shoot/c.ARW")

    func testNothingBeforeTheCursorHasMoved() {
        var p = PreviousPhoto()
        XCTAssertNil(p.previous)
        p.note(a)
        XCTAssertNil(p.previous)
        XCTAssertNil(p.source(writingTo: [a]))
    }

    func testThePhotoBeingLeftBecomesPrevious() {
        var p = PreviousPhoto()
        p.note(a)
        p.note(b)
        XCTAssertEqual(p.previous, a)
        p.note(c)
        XCTAssertEqual(p.previous, b)
        p.note(b)
        XCTAssertEqual(p.previous, c)
    }

    func testRenotingTheSamePhotoKeepsTheAnswer() {
        var p = PreviousPhoto()
        p.note(a)
        p.note(b)
        p.note(b)
        XCTAssertEqual(p.previous, a)
    }

    func testAnEmptySelectionInBetweenDoesNotEraseIt() {
        var p = PreviousPhoto()
        p.note(a)
        p.note(nil)
        p.note(b)
        XCTAssertEqual(p.previous, a)
        XCTAssertEqual(p.current, b)
    }

    /// Esc (or ⌘D) and a click back on the SAME frame is not a move.
    func testClearingAndReturningToTheSamePhotoKeepsTheAnswer() {
        var p = PreviousPhoto()
        p.note(a)
        p.note(b)
        p.note(nil)
        p.note(b)
        XCTAssertEqual(p.previous, a)
        XCTAssertEqual(p.source(writingTo: [b]), a)
    }

    func testTheSourceNeedsATargetOtherThanItself() {
        var p = PreviousPhoto()
        p.note(a)
        p.note(b)
        XCTAssertEqual(p.source(writingTo: [b]), a)
        XCTAssertEqual(p.source(writingTo: [a, b, c]), a)
        XCTAssertNil(p.source(writingTo: [a]))
        XCTAssertNil(p.source(writingTo: []))
    }
}
