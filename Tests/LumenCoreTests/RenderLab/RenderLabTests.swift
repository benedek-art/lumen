// RenderLabTests.swift
// The render lab's manifest, patch and measurement rules.

import Foundation
import XCTest
@testable import LumenCore

final class RenderLabTests: XCTestCase {

    func testDottedAndNestedPatchesReachTheRecipe() throws {
        let patch = try RenderLabJSON.parse(Data("""
            {"develop.tone.exposure": 1.5, "develop": {"tone": {"contrast": 20}},
             "look": {"filmLab": {"stock": "lumen/portra400", "grain": {"amount": 40}}},
             "develop.mixer.bands.2.sat": -30}
            """.utf8))
        let applied = try RecipePatch.apply(patch, to: Recipe())
        XCTAssertEqual(applied.recipe.develop.tone.exposure, 1.5)
        XCTAssertEqual(applied.recipe.develop.tone.contrast, 20)
        XCTAssertEqual(applied.recipe.look.filmLab?.stock, "lumen/portra400")
        XCTAssertEqual(applied.recipe.look.filmLab?.grain.amount, 40)
        XCTAssertEqual(applied.recipe.develop.mixer.bands[2].sat, -30)
    }

    func testAnAbsentOptionalBlockCanBeIndexed() throws {
        let patch = try RenderLabJSON.parse(Data(#"{"look.bw.bands.2": 40}"#.utf8))
        let recipe = try RecipePatch.apply(patch, to: Recipe()).recipe
        XCTAssertEqual(recipe.look.bw?.bands[2], 40)
        XCTAssertEqual(recipe.look.bw?.enabled, true)
    }

    func testAnUnknownFieldIsRefusedRatherThanDropped() throws {
        let patch = try RenderLabJSON.parse(Data(#"{"develop.tone.exposre": 1}"#.utf8))
        XCTAssertThrowsError(try RecipePatch.apply(patch, to: Recipe()))
    }

    func testASweepExpandsAndItsReferenceIsTheBasePatch() throws {
        let manifest = try RenderLabManifest(data: Data("""
            {"jobs": [{"id": "exp", "photo": "chart:greyRamp",
              "recipe": {"develop.tone.contrast": 10},
              "sweep": {"path": "develop.tone.exposure", "values": [-1, 0, 1]}}]}
            """.utf8))
        let job = manifest.jobs[0]
        XCTAssertEqual(job.variants.count, 3)
        XCTAssertEqual(job.variants[2].label, "tone.exposure +1")
        let r = try RecipePatch.apply(job.variants[2].patch, to: Recipe()).recipe
        XCTAssertEqual(r.develop.tone.exposure, 1)
        XCTAssertEqual(r.develop.tone.contrast, 10)
        let ref = try RecipePatch.apply(job.reference!, to: Recipe()).recipe
        XCTAssertEqual(ref.develop.tone.exposure, 0)
    }

    func testAGridIsColumnsByRows() throws {
        let manifest = try RenderLabManifest(data: Data("""
            [{"id": "g", "photo": "chart:flatGrey",
              "grid": {"x": {"path": "look.vignette", "values": [-50, 0, 50]},
                       "y": {"path": "develop.tone.exposure", "from": -1, "to": 1, "steps": 2}}}]
            """.utf8))
        XCTAssertEqual(manifest.jobs[0].variants.count, 6)
        XCTAssertEqual(manifest.jobs[0].columns, 3)
    }

    func testStatsCountClippingAndDeltasSeeADoubling() {
        var a = RenderLabImage(width: 4, height: 2, fill: 0)
        for i in stride(from: 0, to: 16, by: 4) { a.rgba[i] = 255; a.rgba[i + 1] = 255; a.rgba[i + 2] = 255 }
        let s = RenderLabStats(a)
        XCTAssertEqual(s.clipping.allChannelsAt255, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.clipping.allChannelsAt0, 0.5, accuracy: 1e-9)

        let grey = RenderLabImage(displayLinear: ImageBuffer(width: 8, height: 8) { _, _ in RGB(gray: 0.1) })
        let twice = RenderLabImage(displayLinear: ImageBuffer(width: 8, height: 8) { _, _ in RGB(gray: 0.2) })
        let d = RenderLabDelta(twice, against: grey)
        XCTAssertEqual(d.linearYRatio, 2, accuracy: 0.03)
        XCTAssertGreaterThan(d.meanLumaShift, 0)
    }

    func testChartsBuildAndTheSheetEncodes() throws {
        for name in RenderLabCharts.names {
            let chart = try RenderLabCharts.make(name, longEdge: 96)
            XCTAssertEqual(chart.image.width, 96)
            XCTAssertFalse(chart.patches.isEmpty, name)
        }
        let img = RenderLabImage(width: 20, height: 10, fill: 100)
        let sheet = RenderLabSheet.compose(title: ["T"], cells: [
            RenderLabSheet.Cell(image: img, lines: ["EXPOSURE +1.5"], histogram: Array(repeating: 1, count: 256)),
        ], columns: 3, tile: 64)
        let png = RenderLabSheet.encodePNG(sheet)
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }
}
