#if os(macOS)
import Foundation
import XCTest
import LumenCore
@testable import LumenApp

final class AuditDenoiseAvailabilityTests: XCTestCase {
    func testRawRetainsAllModesAndItsLiveAmountControl() {
        let raw = DenoiseControlAvailability(isRendered: false)
        XCTAssertEqual(raw.modeOptions.map(\.value), [.off, .classic, .ai])
        XCTAssertTrue(raw.supportsAmount)
    }

    func testRenderedInputsCannotSelectTheDecoderOnlyModeOrAdjustAmount() {
        let rendered = DenoiseControlAvailability(isRendered: true)
        XCTAssertEqual(rendered.modeOptions.map(\.value), [.off, .classic])
        XCTAssertFalse(rendered.supportsAmount)
    }

    func testLegacyAiRecipeRemainsVisibleButItsAmountIsDisabledAndExplained() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let panel = try String(contentsOf: root.appendingPathComponent("Sources/LumenApp/DetailPanel.swift"), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let ai = try XCTUnwrap(panel.components(separatedBy: "case .ai:").last)
        XCTAssertTrue(ai.contains(".disabled(!denoiseAvailability.supportsAmount)"))
        XCTAssertTrue(ai.contains("Saved AI settings are retained, but the stand-in is RAW-only. Choose Classic to denoise this rendered file."))
        XCTAssertTrue(panel.contains("LumenSegmented(options: denoiseAvailability.modeOptions,"))
        XCTAssertTrue(panel.contains("DenoiseControlAvailability(isRendered: isRenderedFile)"))
    }
}
#endif
