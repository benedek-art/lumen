// ColorTableAccuracyLinuxTests.swift
// AI-03 on the Linux lane: the CPU twin of `ColorTableAccuracyTests`' four assertions.
//
// The GPU suite compares the actual Core Image graph against `RenderPlan.exactColor`,
// and it only runs on macOS. The defect it pins is not a GPU defect, though: it is the
// colour stage being sampled through a table at all. `referenceColor` is the CPU
// renderer's per-pixel path and it went through the SAME combined cube, with the
// tetrahedral sampler rather than trilinear — V4 measured 39.8/35.8 codes (Aqua) and
// 12.2/37.4 (Saturation) here, at 33/65. So the Linux lane can see the defect, and
// this file makes it look.
//
// Same inputs, same recipes, same metric and the same unchanged three-code bound as the
// GPU suite: `255 × max |sRGB-transfer(actual) − sRGB-transfer(exact)|` on encoded
// Rec2020 channels. Not DeltaE, not a final sRGB pixel. Ordinary assertions: there is
// no expected failure anywhere in this file.

import XCTest
@testable import LumenCore

final class ColorTableAccuracyLinuxTests: XCTestCase {

    static let aquaInput = RGB(0.38413364324424248, 0.59591710513566343,
                               0.64828909901873966)
    static let saturationInput = RGB(0.78994447795661316, 0.51750730037644888,
                                     0.21031789665386302)

    func testAquaLuminancePositiveInputAndOutput() {
        var recipe = Recipe()
        recipe.develop.mixer.bands[4].lum = -100
        check(recipe, input: Self.aquaInput)
    }

    func testSaturationPositiveInputAndOutput() {
        var recipe = Recipe()
        recipe.develop.color.saturation = 100
        check(recipe, input: Self.saturationInput)
    }

    /// The code-equivalent error of the CPU render path against the exact operations.
    static func codeError(_ recipe: Recipe, input: RGB, size: Int) -> Double {
        let plan = RenderPlan(recipe: recipe, lutSize: size)
        let actual = plan.referenceColor(input)
        let exact = plan.exactColor(input)
        return 255 * TransferFunction.srgb.encode(actual)
            .maxAbsDifference(TransferFunction.srgb.encode(exact))
    }

    private func check(_ original: Recipe, input: RGB,
                       file: StaticString = #filePath, line: UInt = #line) {
        var recipe = original
        recipe.develop.denoise.mode = .off
        let colour = ColorEngine(mixer: recipe.develop.mixer,
                                 pointColors: recipe.develop.pointColors,
                                 color: recipe.develop.color, primaries: recipe.look.primaries,
                                 bw: recipe.look.bw)
        let grade = GradeEngine(wheels: recipe.look.wheels,
                                printerLights: recipe.look.printerLights)
        // Positive on both sides, so this is not the separate negative-domain defect.
        XCTAssertGreaterThan(input.minComponent, 0, file: file, line: line)
        XCTAssertGreaterThan(grade.apply(colour.apply(input)).minComponent, 0,
                             file: file, line: line)
        for size in [33, 65] {
            let error = Self.codeError(recipe, input: input, size: size)
            XCTAssertTrue(error.isFinite, file: file, line: line)
            XCTAssertLessThan(error, 3,
                              "\(size)-cube: CPU render path versus the exact operations",
                              file: file, line: line)
        }
    }
}
