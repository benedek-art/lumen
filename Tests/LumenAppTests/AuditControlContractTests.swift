#if os(macOS)
import Foundation
import XCTest
@testable import LumenCore
@testable import LumenApp

/// Engine measurements plus source-level UI wiring checks, not a hosted UI test.
final class AuditControlContractTests: XCTestCase {
    func testMaskStrengthHelpDisclosesExistingControlLimits() throws {
        let panel = try source("MaskPanel.swift")
        XCTAssertTrue(panel.contains("combined group/member strength is capped at 200%"))
        XCTAssertTrue(panel.contains("absolute Kelvin reaches its target at 100%"))
        XCTAssertFalse(panel.contains("Past 100 it exaggerates them."))
    }

    private func source(_ file: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/LumenApp/\(file)"),
                          encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func testBlackTargetTypingCannotExceedEngineCeiling() throws {
        var capped = DisplayTransformParams.neutral
        capped.blackTarget = 9
        var excessive = capped
        excessive.blackTarget = 15
        for value in [0.0, 0.001, 0.02, 0.18, 1.0, 8.0] {
            XCTAssertEqual(DisplayTransform(capped).tone(value),
                           DisplayTransform(excessive).tone(value), accuracy: 1e-12)
        }
        let panel = try source("LookPanel.swift")
        let row = try XCTUnwrap(panel.components(separatedBy: "LumenSlider(title: \"Black target\"").last)
            .components(separatedBy: "onReset:").first ?? ""
        XCTAssertTrue(row.contains("range: 0...9, hardRange: 0...9"))
        XCTAssertTrue(row.contains("Num.clamp($0, 0, 9)"), "Old out-of-range recipes must display their effective value")
        XCTAssertTrue(row.contains("Num.clamp($1, 0, 9)"), "Binding must enforce the same range as typing")
    }

    func testGradingHelpDescribesSceneBrightnessNotPerceptualJStops() throws {
        var wheels = GradingWheels()
        wheels.global.lum = 1
        let out = GradeEngine(wheels: wheels, printerLights: PrinterLights()).apply(RGB(0.18, 0.18, 0.18))
        XCTAssertEqual(log2(out.r / 0.18), 1.5, accuracy: 0.001)
        let controls = try source("LumenControls.swift")
        XCTAssertFalse(controls.contains("up to half a stop"))
        XCTAssertTrue(controls.contains("1.5 stops on neutral tones"))
    }

    func testRampHelpMatchesActualGammaDirection() throws {
        XCTAssertEqual(MaskRaster.levels(0.5, lo: 0, hi: 100, gamma: 0.5), 0.25, accuracy: 1e-12)
        XCTAssertEqual(MaskRaster.levels(0.5, lo: 0, hi: 100, gamma: 2), sqrt(0.5), accuracy: 1e-12)
        let panel = try source("MaskPanel.swift")
        XCTAssertTrue(panel.contains("Below 1 the selection holds back and arrives late; "))
        XCTAssertTrue(panel.contains("above 1 it comes up early and eases in."))
    }

    func testAllThreeHalationControlsRespectStockCapability() throws {
        XCTAssertEqual(FilmStock.velvia50.halationStrength, RGB.zero)
        XCTAssertNotEqual(FilmStock.portra400.halationStrength, RGB.zero)
        let panel = try source("LookPanel.swift")
        XCTAssertTrue(panel.contains("stock.map { $0.halationStrength != .zero } ?? false"))
        for title in ["Halation", "Halo Size", "Halo Redness"] {
            let tail = try XCTUnwrap(panel.components(separatedBy: "LumenSlider(title: \"\(title)\"").last)
            let row = tail.components(separatedBy: "LumenSlider(title:").first ?? ""
            XCTAssertTrue(row.contains(".disabled(!halationSupported)"), title)
        }
        XCTAssertTrue(panel.contains("This stock has no halation response."))
    }
}
#endif
