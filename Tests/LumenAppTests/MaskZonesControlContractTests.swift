#if os(macOS)
import Foundation
import XCTest
@testable import LumenCore
@testable import LumenApp

/// Source-level wiring checks for the mask rows that mirror a global row, and for the
/// Zones pivot strip. Not a hosted UI test: there is no window server in CI.
final class MaskZonesControlContractTests: XCTestCase {

    private func source(_ file: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return blankingComments(in: try String(
            contentsOf: root.appendingPathComponent("Sources/LumenApp/\(file)"), encoding: .utf8))
    }

    /// The text from `start` up to the next `end`, or a failure naming what was missing.
    private func slice(_ text: String, from start: String, to end: String,
                       file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let head = try XCTUnwrap(text.range(of: start), "missing `\(start)`",
                                 file: file, line: line)
        let rest = text[head.upperBound...]
        let stop = rest.range(of: end)?.lowerBound ?? rest.endIndex
        return String(rest[..<stop])
    }

    // MARK: - Finding 11: absolute mask Tint accepts what the global Tint accepts

    func testAbsoluteMaskTintTakesTheGlobalRowsHardRange() throws {
        let basic = try source("BasicPanel.swift")
        let global = try slice(basic, from: "LumenSlider(title: \"Tint\"", to: "help:")
        XCTAssertTrue(global.contains("hardRange: -300...300"),
                      "the global Tint's typing range moved; the mask row must follow it")

        let panel = try source("MaskPanel.swift")
        let row = try slice(panel, from: "optionalAdjustSlider(mask.id, \"Tint\"", to: "help:")
        XCTAssertTrue(row.contains("hardRange: -300...300"),
                      "a stand-in tint past ±150 is clamped by reset and nudges")

        // The setter clamps to the hard range, and the slider is told about it, so
        // typing, reset and nudges all agree.
        let helper = try slice(panel, from: "private func optionalAdjustSlider(",
                               to: "private func adjustSlider(")
        XCTAssertTrue(helper.contains("let limit = hardRange ?? r"))
        XCTAssertTrue(helper.contains("Num.clamp($1, limit.lowerBound, limit.upperBound)"))
        XCTAssertFalse(helper.contains("Num.clamp($1, r.lowerBound, r.upperBound)"))
        XCTAssertTrue(helper.contains("hardRange: hardRange"))
    }

    // MARK: - Finding 13: mask Exposure is the global Exposure's row

    func testMaskExposureMatchesTheGlobalExposureRow() throws {
        let basic = try source("BasicPanel.swift")
        let global = try slice(basic, from: "LumenSlider(title: \"Exposure\"", to: "help:")
        for part in ["range: -5...5", "hardRange: -10...10", "step: 0.01"] {
            XCTAssertTrue(global.contains(part), "global Exposure lost `\(part)`")
        }

        let panel = try source("MaskPanel.swift")
        let row = try slice(panel, from: "adjustSlider(mask.id, \"Exposure\"", to: "help:")
        for part in ["-5...5", "hardRange: -10...10", "step: 0.01"] {
            XCTAssertTrue(row.contains(part),
                          "mask Exposure is not the global row's `\(part)`; its help "
                          + "promises the same unit")
        }

        let helper = try slice(panel, from: "private func adjustSlider(",
                               to: "private func wheel(")
        XCTAssertTrue(helper.contains("let limit = hardRange ?? r"))
        XCTAssertTrue(helper.contains("Num.clamp($1, limit.lowerBound, limit.upperBound)"))
        XCTAssertTrue(helper.contains("hardRange: hardRange"))
    }

    // MARK: - Finding 12: Ramp shape is a gamma, so its track is logarithmic

    func testRampShapeIsOnTheLogAxisWithNeutralAtTheMiddle() throws {
        let panel = try source("MaskPanel.swift")
        let row = try slice(panel, from: "refineSlider(mask.id, \"Ramp shape\"", to: "help:")
        XCTAssertTrue(row.contains("0.2...5"))
        XCTAssertTrue(row.contains("scale: .log"),
                      "a gamma on a linear track puts 1.0 at 17 % of the travel")
        let helper = try slice(panel, from: "private func refineSlider(",
                               to: "private func levelsSlider(")
        XCTAssertTrue(helper.contains("scale: scale"), "refineSlider drops its scale")

        // 0.2 and 5 are reciprocal, so the neutral gamma lands at exactly half way.
        let ratio = SliderTrack(width: 142, lowerBound: 0.2, upperBound: 5, step: 0.05,
                                scale: .log)
        XCTAssertEqual(ratio.fraction(of: 1), 0.5, accuracy: 1e-9)
        let linear = SliderTrack(width: 142, lowerBound: 0.2, upperBound: 5, step: 0.05)
        XCTAssertEqual(linear.fraction(of: 1), 0.8 / 4.8, accuracy: 1e-9)
    }
}
#endif
