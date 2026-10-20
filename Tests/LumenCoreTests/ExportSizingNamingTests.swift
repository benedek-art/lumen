// ExportSizingNamingTests.swift
// The box and percentage resize modes, the mode switch that keeps the stored numbers in
// the right unit, the extra naming tokens, and that recipes stored before any of this
// still decode to what they meant.

import XCTest
@testable import LumenCore

final class ExportResizeBoxTests: XCTestCase {

    private func recipe(_ mode: ResizeMode, _ value: Double, _ height: Double = 2048,
                        upscale: Bool = false) -> ExportRecipe {
        ExportRecipe(name: "t", resizeMode: mode, resizeValue: value,
                     resizeHeight: height, allowUpscale: upscale)
    }

    private func size(_ r: ExportRecipe, _ w: Int, _ h: Int) -> [Int] {
        let s = r.targetSize(sourceWidth: w, sourceHeight: h)
        return [s.width, s.height]
    }

    // MARK: Width & height (fit inside the box as drawn)

    func testFitWithinBoundsBothSidesAsDrawn() {
        let box = recipe(.fitWithin, 1920, 1080)
        // 3:2 landscape: width is the tighter side? 1920/6000 = 0.32, 1080/4000 = 0.27.
        XCTAssertEqual(size(box, 6000, 4000), [1620, 1080])
        // Portrait in a landscape box: bounded by the 1080 height.
        XCTAssertEqual(size(box, 4000, 6000), [720, 1080])
        // A panorama is bounded by the width.
        XCTAssertEqual(size(box, 12000, 3000), [1920, 480])
    }

    func testFitWithinNeverEnlargesUnlessAsked() {
        XCTAssertEqual(size(recipe(.fitWithin, 1920, 1080), 1200, 800), [1200, 800])
        XCTAssertEqual(size(recipe(.fitWithin, 1920, 1080, upscale: true), 1200, 800),
                       [1620, 1080])
    }

    // MARK: Dimensions (the box turns with the photo)

    func testDimensionsTurnsTheBoxToMatchTheOrientation() {
        let box = recipe(.dimensions, 1920, 1080)
        XCTAssertEqual(size(box, 6000, 4000), [1620, 1080])
        // The same box on a portrait: 1080 wide, not 720.
        XCTAssertEqual(size(box, 4000, 6000), [1080, 1620])
        // Typing the box the other way round means the same thing.
        XCTAssertEqual(size(recipe(.dimensions, 1080, 1920), 4000, 6000), [1080, 1620])
        XCTAssertEqual(size(box, 12000, 3000), [1920, 480])
        XCTAssertEqual(size(box, 1000, 500), [1000, 500], "no enlarging by default")
    }

    // MARK: Percentage

    func testPercentScalesTheFrame() {
        XCTAssertEqual(size(recipe(.percent, 50), 6000, 4000), [3000, 2000])
        XCTAssertEqual(size(recipe(.percent, 25), 4000, 6000), [1000, 1500])
        XCTAssertEqual(size(recipe(.percent, 100), 7728, 5152), [7728, 5152])
        XCTAssertEqual(size(recipe(.percent, 150), 6000, 4000), [6000, 4000],
                       "150% is an enlargement and Don't enlarge is on")
        XCTAssertEqual(size(recipe(.percent, 150, upscale: true), 6000, 4000),
                       [9000, 6000])
    }

    func testDegenerateBoxesAndPercentsFallBackToTheSource() {
        for mode in [ResizeMode.fitWithin, .dimensions, .percent] {
            for (value, height) in [(0.0, 1080.0), (1920.0, 0.0), (-5, 1080),
                                    (Double.nan, 1080), (1920, Double.infinity)] {
                let s = recipe(mode, value, height).targetSize(sourceWidth: 6000,
                                                               sourceHeight: 4000)
                XCTAssertGreaterThanOrEqual(s.width, 1, "\(mode) \(value)×\(height)")
                XCTAssertGreaterThanOrEqual(s.height, 1, "\(mode) \(value)×\(height)")
                XCTAssertLessThanOrEqual(s.width, 6000, "\(mode) \(value)×\(height)")
            }
        }
        // A tiny percentage still delivers a pixel.
        XCTAssertEqual(size(recipe(.percent, 0.001), 6000, 4000), [1, 1])
    }

    // MARK: The mode switch keeps the number in the mode's unit

    func testSwitchingUnitResetsTheValue() {
        var r = ExportRecipe.webJPEG
        r.setResizeMode(.percent)
        XCTAssertEqual(r.resizeValue, 50, "2048 percent is a 20x enlargement")
        r.setResizeMode(.megapixels)
        XCTAssertEqual(r.resizeValue, 24)
        r.setResizeMode(.longEdge)
        XCTAssertEqual(r.resizeValue, 2048)
        r.resizeValue = 1600
        r.setResizeMode(.width)
        XCTAssertEqual(r.resizeValue, 1600, "same unit keeps the number")
    }

    func testEnteringABoxStartsSquareOnTheOldNumber() {
        var r = ExportRecipe.webJPEG
        r.resizeValue = 1600
        r.resizeHeight = 333
        r.setResizeMode(.dimensions)
        XCTAssertEqual(r.resizeValue, 1600)
        XCTAssertEqual(r.resizeHeight, 1600)
        // A square box delivers what the long edge delivered.
        XCTAssertEqual(r.targetSize(sourceWidth: 6000, sourceHeight: 4000).width, 1600)
        r.resizeHeight = 900
        r.setResizeMode(.fitWithin)
        XCTAssertEqual(r.resizeHeight, 900, "box to box keeps the box")
    }

    // MARK: The recipe row

    func testTheSummaryNamesTheBoxAndThePercent() {
        XCTAssertNil(recipe(.none, 2048).resizeSummary)
        XCTAssertEqual(recipe(.longEdge, 2048).resizeSummary, "Long edge 2048px")
        XCTAssertEqual(recipe(.megapixels, 24).resizeSummary, "Megapixels 24MP")
        XCTAssertEqual(recipe(.fitWithin, 1920, 1080).resizeSummary,
                       "Width & height 1920×1080px")
        XCTAssertEqual(recipe(.dimensions, 1080, 1920).resizeSummary,
                       "Dimensions 1080×1920px")
        XCTAssertEqual(recipe(.percent, 50).resizeSummary, "Percentage 50%")
        XCTAssertEqual(recipe(.percent, Double.nan).resizeSummary, "Percentage ?%")
    }

    // MARK: Stored recipes

    func testARecipeStoredBeforeTheBoxExistedDecodesAsItWas() throws {
        let json = """
        {"id":"web","name":"Web","resizeMode":"longEdge","resizeValue":1600,
         "filenameTemplate":"{name}"}
        """
        let r = try JSONDecoder().decode(ExportRecipe.self, from: Data(json.utf8))
        XCTAssertEqual(r.resizeMode, .longEdge)
        XCTAssertEqual(r.resizeValue, 1600)
        XCTAssertEqual(r.resizeHeight, ExportRecipe(name: "").resizeHeight)
        XCTAssertNil(r.customText)
        XCTAssertEqual(r.targetSize(sourceWidth: 6000, sourceHeight: 4000).width, 1600)
    }

    func testABadSecondSideOrUnknownModeDoesNotLoseThePreset() throws {
        let json = """
        {"id":"x","name":"Club site","resizeMode":"someFutureMode","resizeValue":1920,
         "resizeHeight":"tall","customText":42}
        """
        let r = try JSONDecoder().decode(ExportRecipe.self, from: Data(json.utf8))
        XCTAssertEqual(r.name, "Club site")
        XCTAssertEqual(r.resizeMode, .none)
        XCTAssertEqual(r.resizeHeight, ExportRecipe(name: "").resizeHeight)
        XCTAssertNil(r.customText)
    }

    func testTheNewFieldsRoundTrip() throws {
        for mode in [ResizeMode.fitWithin, .dimensions, .percent] {
            let r = ExportRecipe(name: "Box", resizeMode: mode, resizeValue: 1920,
                                 resizeHeight: 1080, filenameTemplate: "{custom}_{orignum}",
                                 customText: "U17-vs-Ajax")
            let back = try JSONDecoder().decode(ExportRecipe.self,
                                                from: JSONEncoder().encode(r))
            XCTAssertEqual(back, r, "\(mode)")
        }
    }
}

final class ExportNamingTokenTests: XCTestCase {

    private static let arw = URL(fileURLWithPath: "/Volumes/Work/2026-10-18 U17 Ajax/DSC01234.ARW")

    private func render(_ template: String, _ context: ExportNamingContext) -> String {
        ExportNaming.render(template: template, context: context)
    }

    func testOriginalNumberIsTheLastDigitRun() {
        XCTAssertEqual(ExportNaming.originalNumber(of: "DSC01234"), "01234")
        XCTAssertEqual(ExportNaming.originalNumber(of: "P1000123"), "1000123")
        XCTAssertEqual(ExportNaming.originalNumber(of: "_DSC0042"), "0042")
        XCTAssertEqual(ExportNaming.originalNumber(of: "2026-08-20_DSC01234"), "01234")
        XCTAssertEqual(ExportNaming.originalNumber(of: "DSC01234-Edit"), "01234")
        XCTAssertEqual(ExportNaming.originalNumber(of: "Portrait"), "")
        XCTAssertEqual(ExportNaming.originalNumber(of: "IMG_٣٤"), "", "ASCII digits only")
    }

    func testCustomTextOriginalNumberAndFolder() {
        let context = ExportNamingContext(source: Self.arw, recipeName: "web",
                                          customText: " U17-vs-Ajax ")
        XCTAssertEqual(render("{custom}_{orignum}", context), "U17-vs-Ajax_01234")
        XCTAssertEqual(render("{job}", context), "U17-vs-Ajax", "the ingest spelling")
        XCTAssertEqual(render("{folder}-{orignum}", context), "2026-10-18 U17 Ajax-01234")
        XCTAssertEqual(render("{orig}", context), "DSC01234", "ingest's {orig} is the name")
        let bare = ExportNamingContext(source: Self.arw, recipeName: "web")
        XCTAssertEqual(render("{custom}{name}", bare), "DSC01234",
                       "no custom text renders as nothing")
        let root = ExportNamingContext(source: URL(fileURLWithPath: "/DSC01234.ARW"),
                                       recipeName: "web")
        XCTAssertEqual(render("{folder}{name}", root), "DSC01234")
    }

    func testCustomTextCannotMakeAPath() {
        let context = ExportNamingContext(source: Self.arw, recipeName: "web",
                                          customText: "../U17/Ajax")
        XCTAssertEqual(render("{custom}", context), "..-U17-Ajax")
    }

    func testTotalAndAutoPaddedSequence() {
        let recipe = ExportRecipe(name: "web", filenameTemplate: "{seq:auto}-of-{total}",
                                  customText: "Ajax")
        let base = ExportNamingContext(source: Self.arw, recipeName: "")
        let first = base.forRecipe(recipe, photoIndex: 0, batchCount: 250)
        let last = base.forRecipe(recipe, photoIndex: 249, batchCount: 250)
        XCTAssertEqual(render(recipe.filenameTemplate, first), "001-of-250")
        XCTAssertEqual(render(recipe.filenameTemplate, last), "250-of-250")
        XCTAssertEqual(first.recipeName, "web")
        XCTAssertEqual(first.customText, "Ajax")

        // The width follows the last NUMBER, so a start of 995 widens it.
        var late = recipe
        late.sequenceStart = 995
        XCTAssertEqual(render("{seq:auto}", base.forRecipe(late, photoIndex: 0, batchCount: 10)),
                       "0995")
        // Unknown batch: as wide as this photo's own number.
        XCTAssertEqual(render("{seq:auto}{total}", base.forRecipe(recipe, photoIndex: 6,
                                                                  batchCount: 0)), "7")
    }

    func testTheNewTokensAreKnownAndSequenceAwareWhereTheyCount() {
        XCTAssertEqual(ExportNaming.unknownTokens(
            in: "{custom}{job}{folder}{orignum}{orig}{total}{seq:auto}"), [])
        XCTAssertTrue(ExportNaming.usesSequence("{custom}-{seq:auto}"))
        XCTAssertTrue(ExportNaming.identifiesEachPhoto("{custom}-{seq:auto}"))
        XCTAssertFalse(ExportNaming.identifiesEachPhoto("{custom}-{total}"))
        for token in ["{custom}", "{orignum}", "{folder}", "{seq:auto}", "{total}"] {
            XCTAssertTrue(ExportNaming.documentedTokens.contains(token), token)
        }
        // Every documented token is one the renderer knows.
        for token in ExportNaming.documentedTokens where token != "{seq:N}" {
            XCTAssertEqual(ExportNaming.unknownTokens(in: token), [], token)
        }
    }
}
