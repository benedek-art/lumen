// SliderReadoutTests.swift
// U2: the slider's readout digits, the geometry that ended the "L" at the centre of
// Exposure and Contrast, the fine gear that addresses every step, and the source
// contracts for the parts of `LumenSlider` a Linux test can only read.

import Foundation
import XCTest
@testable import LumenCore

final class SliderReadoutTests: XCTestCase {

    // MARK: - Readout digits

    func testTheReadoutNeverPrintsANegativeZero() {
        // The value a drag back to centre actually lands on.
        let landed = SliderTrack(width: 142, lowerBound: -100, upperBound: 100, step: 1)
            .snapped(-0.4)
        XCTAssertEqual(landed, 0)
        XCTAssertEqual(String(format: "%.0f", landed), "-0", "the defect this replaces")
        for decimals in 0...3 {
            for v in [-0.0, -0.0004, -1e-12, -0.004] where
                abs(v) < 0.5 * pow(10, -Double(decimals)) {
                for signed in [false, true] {
                    let t = SliderReadout.text(v, decimals: decimals, signed: signed)
                    XCTAssertFalse(t.hasPrefix("-"), "\(v) at \(decimals) printed \(t)")
                    XCTAssertFalse(t.hasPrefix("+"), "zero carries no sign: \(t)")
                }
            }
        }
    }

    func testZeroCentredBipolarControlsPrintASignLikeLightroom() {
        XCTAssertEqual(SliderReadout.text(0.35, decimals: 2, signed: true), "+0.35")
        XCTAssertEqual(SliderReadout.text(24, decimals: 0, signed: true), "+24")
        XCTAssertEqual(SliderReadout.text(-38, decimals: 0, signed: true), "-38")
        XCTAssertEqual(SliderReadout.text(0, decimals: 2, signed: true), "0.00")
        XCTAssertEqual(SliderReadout.text(24, decimals: 0, signed: false), "24")
        XCTAssertTrue(SliderReadout.isSigned(defaultValue: 0, lowerBound: -100, upperBound: 100))
        XCTAssertFalse(SliderReadout.isSigned(defaultValue: 5500, lowerBound: 2000,
                                              upperBound: 50000), "Temp is not an offset")
        XCTAssertFalse(SliderReadout.isSigned(defaultValue: 0, lowerBound: 0, upperBound: 100),
                       "a unipolar control never goes negative, so a + says nothing")
    }

    func testTheEditingTextHasNoPlusAndParsesBackToTheValue() throws {
        for v in [0.35, -0.35, 24.0, -38.0, 0.0] {
            let t = SliderReadout.editingText(v, decimals: 2)
            XCTAssertFalse(t.hasPrefix("+"))
            XCTAssertEqual(try XCTUnwrap(SliderEntry.value(of: t, current: 99)), v,
                           accuracy: 1e-9)
        }
        // A signed readout pasted back in still parses as the absolute value.
        XCTAssertEqual(SliderEntry.value(of: "+0.35", current: 2), 0.35)
    }

    func testTheReadoutAndVoiceOverSayTheSameDigits() {
        for v in [-0.0, 0.004, -12.0, 3.14159, 100.0] {
            for d in 0...2 {
                XCTAssertEqual(SliderReadout.text(v, decimals: d),
                               SliderAccessibility.value(v, decimals: d))
            }
        }
    }

    func testDecimalsForAStepAreTheDigitsItNeeds() {
        XCTAssertEqual(SliderReadout.decimals(forStep: 1), 0)
        XCTAssertEqual(SliderReadout.decimals(forStep: 10), 0)
        XCTAssertEqual(SliderReadout.decimals(forStep: 0.1), 1)
        XCTAssertEqual(SliderReadout.decimals(forStep: 0.05), 2)
        XCTAssertEqual(SliderReadout.decimals(forStep: 0.01), 2)
        XCTAssertEqual(SliderReadout.decimals(forStep: 0.001), 3)
    }

    /// Every literal `LumenSlider(...)` call site prints exactly the digits its step
    /// needs: fewer and two reachable values print alike (the control looks stuck),
    /// more and the readout advertises a precision no gesture reaches.
    func testEveryLiteralCallSitePrintsTheDigitsItsStepNeeds() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LumenApp")
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }
        var checked = 0
        var mismatches: [String] = []
        for file in files {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            var search = text.startIndex..<text.endIndex
            while let open = text.range(of: "LumenSlider(", range: search) {
                // The call's balanced argument list.
                var depth = 1
                var i = open.upperBound
                while depth > 0, i < text.endIndex {
                    if text[i] == "(" { depth += 1 } else if text[i] == ")" { depth -= 1 }
                    i = text.index(after: i)
                }
                let call = String(text[open.lowerBound..<i])
                search = i..<text.endIndex
                let step = Self.literal("step:", in: call) ?? (call.contains("step:") ? nil : 1)
                let decimalsArg = Self.literal("decimals:", in: call)
                    ?? (call.contains("decimals:") ? nil : 0)
                guard let step, let decimalsArg else { continue }   // computed: skip
                checked += 1
                let need = SliderReadout.decimals(forStep: step)
                if need != Int(decimalsArg) {
                    mismatches.append("\(file): step \(step) decimals \(Int(decimalsArg))")
                }
            }
        }
        XCTAssertGreaterThan(checked, 40, "the scan found too few call sites to mean anything")
        XCTAssertEqual(mismatches, [])
    }

    private static func literal(_ label: String, in call: String) -> Double? {
        guard let r = call.range(of: label) else { return nil }
        let tail = call[r.upperBound...].drop { $0 == " " }
        let token = tail.prefix { $0.isNumber || $0 == "." || $0 == "-" }
        guard !token.isEmpty else { return nil }
        let after = tail.dropFirst(token.count).first
        guard after == nil || after == "," || after == ")" || after == "\n" else { return nil }
        return Double(token)
    }

    // MARK: - Geometry

    func testTheZeroTickCannotMeetTheGrooveOrTheUnderline() {
        XCTAssertLessThanOrEqual(SliderMetrics.neutralTickBottom, SliderMetrics.grooveTop - 1)
        XCTAssertGreaterThanOrEqual(SliderMetrics.underlineTop, SliderMetrics.grooveBottom + 1)
        XCTAssertLessThan(SliderMetrics.neutralTickTop, SliderMetrics.neutralTickBottom)
        // Both stay inside the row.
        XCTAssertGreaterThan(SliderMetrics.neutralTickTop, -24 / 2)
        XCTAssertLessThan(SliderMetrics.underlineTop + SliderMetrics.underlineHeight, 24 / 2)
    }

    func testHitTargetsAreAtLeastTwentyPoints() throws {
        let controls = try ShellSource.code("Sources/LumenApp/LumenControls.swift")
        let squashed = ShellSource.squashed(controls)
        let r = try XCTUnwrap(squashed.range(of: "static let rowHeight: CGFloat = "))
        let rowHeight = try XCTUnwrap(Double(squashed[r.upperBound...].prefix { $0.isNumber }))
        XCTAssertGreaterThanOrEqual(SliderMetrics.hitHeight(rowHeight: rowHeight), 20)
        XCTAssertGreaterThanOrEqual(SliderMetrics.thumbGrabWidth, 20)
        XCTAssertGreaterThan(SliderMetrics.thumbGrabWidth, SliderMetrics.thumbDraggingDiameter)
    }

    // MARK: - Fine drag resolution

    /// Points of travel per step of value, coarse and fine, on the develop column's
    /// 142 pt track. The fine gear must address every step on every linear control.
    func testTheFineGearAddressesEveryStepOnTheDevelopTrack() {
        let cases: [(String, Double, Double, Double)] = [
            ("Exposure", -5, 5, 0.01), ("Tone ±100", -100, 100, 1),
            ("Tint", -150, 150, 1), ("Amount 0…150", 0, 150, 1), ("Radius", 0.5, 3, 0.1),
        ]
        for (name, lo, hi, step) in cases {
            let track = SliderTrack(width: 142, lowerBound: lo, upperBound: hi, step: step)
            let coarse = track.width * step / track.span
            let fine = coarse / FineDrag.fineGear(for: track)
            XCTAssertGreaterThanOrEqual(fine, FineDrag.finePointsPerStep - 1e-9,
                                        "\(name): \(fine) pt/step under ⇧")
            XCTAssertLessThanOrEqual(FineDrag.fineGear(for: track), FineDrag.scale)
        }
        let exposure = SliderTrack(width: 142, lowerBound: -5, upperBound: 5, step: 0.01)
        XCTAssertEqual(FineDrag.fineGear(for: exposure), 0.142, accuracy: 1e-9)
        let tone = SliderTrack(width: 142, lowerBound: -100, upperBound: 100, step: 1)
        XCTAssertEqual(FineDrag.fineGear(for: tone), FineDrag.scale,
                       "the ±100 controls keep the quarter they have always had")
        let temp = SliderTrack(width: 142, lowerBound: 2000, upperBound: 50000, step: 50,
                               scale: .reciprocal)
        XCTAssertEqual(FineDrag.fineGear(for: temp), FineDrag.scale)
    }

    /// Under ⇧ on Exposure, every hundredth is reachable: one point of travel per step.
    func testAFineExposureDragLandsOnEveryHundredth() {
        let exposure = SliderTrack(width: 142, lowerBound: -5, upperBound: 5, step: 0.01)
        var drag = FineDrag(startValue: 0, fine: true)
        var seen = Set<Int>()
        var x = 0.0
        while x <= 40 {
            seen.insert(Int((drag.value(track: exposure, travelled: x, fine: true) * 100)
                .rounded()))
            x += 0.5
        }
        XCTAssertEqual(seen, Set(0...40), "fine Exposure skipped hundredths")
    }

    func testAChangeOfGearIsStillWorthNothingWithTheAdaptiveGear() {
        let exposure = SliderTrack(width: 142, lowerBound: -5, upperBound: 5, step: 0.01)
        var drag = FineDrag(startValue: 0)
        let before = drag.value(track: exposure, travelled: 30, fine: false)
        let after = drag.value(track: exposure, travelled: 30, fine: true)
        XCTAssertEqual(before, after)
        XCTAssertEqual(drag.value(track: exposure, travelled: 40, fine: true),
                       exposure.value(from: before, travelled: 10 * 0.142), accuracy: 1e-9)
    }

    // MARK: - Source contracts (LumenApp does not build on Linux)

    private static func slider() throws -> String {
        let code = try ShellSource.code("Sources/LumenApp/LumenControls.swift")
        return try XCTUnwrap(ShellSource.body(after: "struct LumenSlider: View", in: code))
    }

    func testTheSliderDrawsItsZeroAndUnderlineFromTheMetrics() throws {
        let s = ShellSource.squashed(try Self.slider())
        XCTAssertTrue(s.contains("SliderMetrics.underlineCentre"))
        XCTAssertTrue(s.contains("SliderMetrics.neutralTickCentre"))
        XCTAssertFalse(s.contains("neutralMarkHeight"), "the bar through the groove is back")
    }

    func testTheRowFillIsKeyboardFocusOnlyAndUnaskedFocusIsRefused() throws {
        let s = ShellSource.squashed(try Self.slider())
        XCTAssertTrue(s.contains(".lumenFocusSurface(focused: rowFocused && keyboardFocus)"))
        XCTAssertTrue(s.contains(".allowsHitTesting(false))"),
                      "the outset fill must not widen the row's click target")
        XCTAssertTrue(s.contains("case .unasked: rowFocused = false return"))
    }

    func testTheOpenFieldNudgesWithTheArrowsAndTheReadoutIsShared() throws {
        let s = ShellSource.squashed(try Self.slider())
        XCTAssertTrue(s.contains(".onKeyPress(.upArrow) { typedNudge(1) }"))
        XCTAssertTrue(s.contains(".onKeyPress(.downArrow) { typedNudge(-1) }"))
        XCTAssertTrue(s.contains("scrubTrack.nudged(base,"))
        XCTAssertTrue(s.contains("SliderReadout.text(value, decimals: decimals,"))
        XCTAssertFalse(s.contains("String(format: \"%.\\(decimals)f\", value)"))
    }
}
