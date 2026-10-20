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

    // MARK: - Finding 37: a zone pivot resets alone and is reachable by VoiceOver

    func testAZonePivotResetsToItsOwnDefault() {
        for (index, home) in Zones.defaultPivots.enumerated() {
            XCTAssertEqual(ZonesPanel.defaultPivot(at: index), home)
        }
        XCTAssertNil(ZonesPanel.defaultPivot(at: -1))
        XCTAssertNil(ZonesPanel.defaultPivot(at: Zones.defaultPivots.count))
    }

    func testAZonePivotStepsByWholePercentsAndStaysOnTheAxis() {
        XCTAssertEqual(ZonePivotStrip.steppedPivot(0.5, .increment), 0.51, accuracy: 1e-12)
        XCTAssertEqual(ZonePivotStrip.steppedPivot(0.5, .decrement), 0.49, accuracy: 1e-12)
        // Off-grid positions snap rather than accumulate float dust.
        XCTAssertEqual(ZonePivotStrip.steppedPivot(0.3333, .increment), 0.34, accuracy: 1e-12)
        XCTAssertEqual(ZonePivotStrip.steppedPivot(1, .increment), 1)
        XCTAssertEqual(ZonePivotStrip.steppedPivot(0, .decrement), 0)
        XCTAssertEqual(ZonePivotStrip.steppedPivot(.nan, .increment), 0.01, accuracy: 1e-12)
    }

    func testAZonePivotIsNamedForItsZone() {
        let names = ["Darks", "Shadows", "Midtones", "Lights", "Brights"]
        XCTAssertEqual(ZonePivotStrip.pivotLabel(index: 2, names: names), "Midtones centre")
        XCTAssertEqual(ZonePivotStrip.pivotLabel(index: 7, names: names), "Zone centre 8")
    }

    func testThePivotHandleHasADoubleClickResetAndAnAdjustableAction() throws {
        let zones = try source("ZonesPanel.swift")
        let call = try slice(zones, from: "ZonePivotStrip(pivots:", to: "if let flattened")
        XCTAssertTrue(call.contains("names: Self.register.map(\\.name)"))
        XCTAssertTrue(call.contains("onPivotReset:"))
        XCTAssertTrue(call.contains("Self.defaultPivot(at: index)"))

        let handle = try slice(zones, from: "private func handle(", to: "private func stepPivot(")
        for needle in [
            "(NSApp.currentEvent?.clickCount ?? 1) >= 2",
            "onPivotReset(index)",
            ".accessibilityElement(children: .ignore)",
            ".accessibilityLabel(Text(Self.pivotLabel(index: index, names: names)))",
            ".accessibilityAdjustableAction { direction in",
            "case .increment: stepPivot(index, from: position, .increment)",
            "case .decrement: stepPivot(index, from: position, .decrement)",
        ] {
            XCTAssertTrue(handle.contains(needle), "the pivot handle lost \(needle)")
        }
        let step = try slice(zones, from: "private func stepPivot(", to: "\n}\n")
        XCTAssertTrue(step.contains("sliderGestureChanged(true)")
                      && step.contains("sliderGestureChanged(false)"),
                      "an assistive step is bracketed like a drag")
    }

    // MARK: - Finding 36: the pivot drag's release is a sample

    func testThePivotDragResolvesTheReleaseLocation() throws {
        let zones = try source("ZonesPanel.swift")
        let handle = try slice(zones, from: "private func handle(", to: "private func stepPivot(")
        XCTAssertFalse(handle.contains(".onEnded { _ in"),
                       "the release location is thrown away")
        let ended = try slice(handle, from: ".onEnded { drag in", to: "dragOrigin = nil")
        XCTAssertTrue(ended.contains("drag.translation.width"))
        XCTAssertTrue(ended.contains("onPivotChanged(index,"),
                      "the release is not committed before the drag state is cleared")
    }
}
#endif
