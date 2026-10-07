// ExportGainMapTests.swift
// docs/11 §HDR export: a recipe with HDR settings on HEIC or JPEG writes a gain map,
// whose HDR rendition renders at the settings' white, while the file's primary stays
// the SDR export pixel for pixel. The encoder half (Core Image's `hdrImage` option) is
// read back on the macOS lane in `ExportDeliveryReadbackTests`; this is the decision
// and the wiring, on every lane.

import Foundation
import XCTest
@testable import LumenCore

final class ExportGainMapTests: XCTestCase {

    func testOnlyAGainMapContainerWithHDRSettingsWritesAMap() {
        XCTAssertTrue(ExportRecipe.hdrHEIC.hdrIsWritable, "the stock HDR HEIC recipe")
        for format in ExportFormat.allCases {
            let on = ExportRecipe(name: "x", format: format, hdr: HDRSettings())
            XCTAssertEqual(on.hdrIsWritable, format == .heif || format == .jpeg, "\(format)")
            XCTAssertFalse(ExportRecipe(name: "x", format: format).hdrIsWritable,
                           "\(format) without HDR settings")
        }
    }

    /// The HDR rendition's white is the settings' own expression — the number the
    /// loupe's HDR preview renders at when the display covers the content — and there
    /// is none when no map is written.
    func testTheHDRRenditionRendersAtTheSettingsWhite() throws {
        for ev in [0.5, 1.0, 2.0, 3.3, 4.0] {
            let recipe = ExportRecipe(name: "x", format: .heif,
                                      hdr: HDRSettings(headroomEV: ev))
            XCTAssertEqual(recipe.gainMapWhiteTargetPercent,
                           HDRSettings(headroomEV: ev).whiteTargetPercent)
            XCTAssertEqual(try XCTUnwrap(recipe.gainMapWhiteTargetPercent),
                           100 * pow(2, ev), accuracy: 1e-9)
        }
        XCTAssertNil(ExportRecipe(name: "x", format: .tiff,
                                  hdr: HDRSettings()).gainMapWhiteTargetPercent)
        XCTAssertNil(ExportRecipe(name: "x", format: .heif).gainMapWhiteTargetPercent)
    }

    // MARK: - The renderer wiring (LumenPipeline does not build here; read as text)

    /// The primary is the SDR delivery whatever the recipe says, and the HDR rendition
    /// reaches the encoder only as `hdrImage`. Three things that each, missing, ship a
    /// wrong file: an `exportedImage` that renders at the HDR white clips the primary
    /// (the defect `hdrIsWritable = false` was guarding against); an export that never
    /// renders the second rendition writes no map; a `write` that never sets the option
    /// writes no map either.
    func testThePrimaryIsSDRAndTheHDRRenditionReachesTheEncoder() throws {
        let source = Self.stripped(try Self.pipelineSource())
        let primary = try Self.body(of: "func exportedImage(", in: source,
                                    upTo: "func exportedHDRImage(")
        XCTAssertTrue(primary.contains("displayWhiteTarget: nil, dither: true"),
                      "the primary must render at SDR white, dithered, as it always did")

        let hdr = try Self.body(of: "func exportedHDRImage(", in: source,
                                upTo: "private func deliveredRendition(")
        XCTAssertTrue(hdr.contains("exportRecipe.gainMapWhiteTargetPercent"))
        XCTAssertTrue(hdr.contains("dither: false"))

        let export = try Self.body(of: "public func export(source:", in: source,
                                   upTo: "static func sourceImageProperties(")
        XCTAssertTrue(export.contains("exportedHDRImage(source: source"))
        XCTAssertTrue(export.contains("hdrImage: hdr"))

        let write = try Self.body(of: "private func write(_ image: CIImage", in: source,
                                  upTo: "static func partialURL(")
        XCTAssertTrue(write.contains("options[.hdrImage] = hdrImage"),
                      "the HDR rendition never reaches the encoder")

        let plan = try Self.body(of: "func exportPlan(", in: source,
                                 upTo: "static func deliveredProof(")
        XCTAssertFalse(plan.contains("whiteTargetPercent"),
                       "the plan must take its white from the caller; reading the "
                           + "recipe's HDR white here would raise the primary's ceiling")
    }

    // MARK: - helpers

    private static func pipelineSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(
            "Sources/LumenPipeline/PipelineRenderer.swift"), encoding: .utf8)
    }

    private static func body(of start: String, in source: String,
                             upTo end: String) throws -> String {
        let from = try XCTUnwrap(source.range(of: start), "\(start) not found")
        let to = try XCTUnwrap(source.range(of: end, range: from.upperBound..<source.endIndex),
                               "\(end) not found after \(start)")
        return String(source[from.lowerBound..<to.lowerBound])
    }

    private static func stripped(_ source: String) -> String {
        blankingComments(in: source)
    }
}
