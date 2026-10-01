// SliderAccessibilityTests.swift
// UX-03: the custom editing sliders exposed no adjustable accessibility semantics.
//
// Two halves. The rules — name, spoken value, one step — are LumenCore and are run
// here. The wiring is `LumenSlider` and `LumenColorWheel` in LumenApp, which compile
// only on macOS; it is pinned by source contracts in the repo's existing style
// (`SliderEvidenceTests`, `CanvasEditScopeTests`), which run on every lane.

import XCTest
@testable import LumenCore

final class SliderAccessibilityTests: XCTestCase {

    // MARK: The rules

    func testTheNameIsTheWordsOnScreenAndNeverEmpty() {
        XCTAssertEqual(SliderAccessibility.label(title: "Exposure", name: nil), "Exposure")
        XCTAssertEqual(SliderAccessibility.label(title: "Exposure", name: "Other"),
                       "Exposure", "a titled row is named by its title")
        XCTAssertEqual(SliderAccessibility.label(title: "", name: "Shadows luminance"),
                       "Shadows luminance")
        XCTAssertEqual(SliderAccessibility.label(title: "  ", name: nil), "Adjustment")
        XCTAssertEqual(SliderAccessibility.label(title: "", name: " "), "Adjustment")
    }

    func testTheSpokenValueIsTheReadoutsDigitsWithoutAMinusZero() {
        XCTAssertEqual(SliderAccessibility.value(0.5, decimals: 2), "0.50")
        XCTAssertEqual(SliderAccessibility.value(-12, decimals: 0), "-12")
        XCTAssertEqual(SliderAccessibility.value(5500, decimals: 0), "5500")
        XCTAssertEqual(SliderAccessibility.value(-0.0001, decimals: 2), "0.00")
        XCTAssertEqual(SliderAccessibility.value(.nan, decimals: 2), "—")
    }

    /// One increment is exactly one of the control's own steps — for every step size the
    /// panels use — clamped at the soft range, and decrement undoes it.
    func testOneIncrementIsOneOfTheControlsOwnSteps() {
        let cases: [(lo: Double, hi: Double, step: Double, start: Double)] = [
            (-100, 100, 1, 0), (-5, 5, 0.01, 0.5), (0, 1, 0.01, 0.25),
            (-45, 45, 0.1, 3.2), (2000, 50000, 50, 5500), (0, 15, 0.001, 1.25),
        ]
        for c in cases {
            let track = SliderTrack(width: 426, lowerBound: c.lo, upperBound: c.hi,
                                    step: c.step)
            let up = SliderAccessibility.adjusted(c.start, .increment, track: track)
            XCTAssertEqual(up - c.start, c.step, accuracy: c.step * 1e-6,
                           "increment on \(c.lo)…\(c.hi) step \(c.step)")
            let back = SliderAccessibility.adjusted(up, .decrement, track: track)
            XCTAssertEqual(back, c.start, accuracy: c.step * 1e-6)
            XCTAssertEqual(SliderAccessibility.adjusted(c.hi, .increment, track: track),
                           c.hi, accuracy: c.step * 1e-6, "past the top of the range")
            XCTAssertEqual(SliderAccessibility.adjusted(c.lo, .decrement, track: track),
                           c.lo, accuracy: c.step * 1e-6, "past the bottom of the range")
        }
    }

    func testTheWheelSpeaksBothHalvesAndStepsItsStrength() {
        XCTAssertEqual(SliderAccessibility.wheelValue(hue: 210, saturation: 0.35),
                       "hue 210°, strength 35%")
        XCTAssertEqual(SliderAccessibility.wheelValue(hue: -10, saturation: 2),
                       "hue 350°, strength 100%")
        XCTAssertEqual(SliderAccessibility.adjustedWheelStrength(0.35, .increment),
                       0.36, accuracy: 1e-12)
        XCTAssertEqual(SliderAccessibility.adjustedWheelStrength(1, .increment), 1)
        XCTAssertEqual(SliderAccessibility.adjustedWheelStrength(0, .decrement), 0)
        XCTAssertEqual(SliderAccessibility.rotatedWheelHue(358, by: 1), 3, accuracy: 1e-12)
        XCTAssertEqual(SliderAccessibility.rotatedWheelHue(2, by: -1), 357, accuracy: 1e-12)
    }

    // MARK: The wiring (source contracts)

    private static func appSource(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LumenApp/\(name).swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The text from `struct <name>` to the next top-level declaration.
    private static func body(of type: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: "struct \(type): View {"))
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n}\n")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    /// `LumenSlider` is ONE adjustable element with the name on screen, the readout's
    /// value, and an increment/decrement that goes through the single-step rule rather
    /// than through `nudge`, which reads ⇧ off the keyboard.
    func testLumenSliderIsOneLabelledAdjustableElement() throws {
        let slider = try Self.body(of: "LumenSlider",
                                   in: Self.appSource("LumenControls"))
        for needle in [
            ".accessibilityElement(children: .ignore)",
            ".accessibilityLabel(Text(SliderAccessibility.label(title: title,",
            ".accessibilityValue(Text(SliderAccessibility.value(value, decimals: decimals)))",
            ".accessibilityAdjustableAction { direction in",
            "case .increment: accessibilityStep(.increment)",
            "case .decrement: accessibilityStep(.decrement)",
        ] {
            XCTAssertTrue(slider.contains(needle), "LumenSlider lost \(needle)")
        }
        let step = try XCTUnwrap(slider.range(of: "private func accessibilityStep("))
        let stepBody = String(slider[step.upperBound...].prefix(600))
        XCTAssertTrue(stepBody.contains("SliderAccessibility.adjusted(value, direction, track: scrubTrack)"))
        XCTAssertFalse(stepBody.contains("shiftIsDown"),
                       "an assistive step must not pick up ⇧ from the keyboard")
        XCTAssertFalse(stepBody.contains("nudge("))
        // Bracketed like a key press: one undo step, the deferred write landed.
        XCTAssertTrue(stepBody.contains("sliderGestureChanged(true)")
                      && stepBody.contains("sliderGestureChanged(false)"))
    }

    /// Every slider the panels draw with an empty title is named for VoiceOver.
    func testEveryUntitledSliderCarriesAnAccessibilityName() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/LumenApp")
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }
        var untitled = 0
        for file in files {
            let text = try String(contentsOf: root.appendingPathComponent(file),
                                  encoding: .utf8)
            var search = text.startIndex..<text.endIndex
            while let hit = text.range(of: "LumenSlider(title: \"\"", range: search) {
                untitled += 1
                // The call runs to its closing paren; 1,200 characters covers the
                // longest commented call in the tree.
                let call = text[hit.lowerBound...].prefix(1200)
                let close = call.range(of: "accessibilityName:")
                XCTAssertNotNil(close, "\(file): an untitled LumenSlider has no "
                                + "accessibilityName, so VoiceOver announces it as "
                                + "\"Adjustment\"")
                search = hit.upperBound..<text.endIndex
            }
        }
        XCTAssertGreaterThan(untitled, 0, "the census found no untitled slider, so it "
                             + "is not measuring the tree")
    }

    func testTheColourWheelIsAnAdjustableElement() throws {
        let wheel = try Self.body(of: "LumenColorWheel",
                                  in: Self.appSource("LumenControls"))
        for needle in [
            ".accessibilityValue(Text(SliderAccessibility.wheelValue(hue: hue, saturation: sat)))",
            ".accessibilityAdjustableAction { direction in",
            "SliderAccessibility.adjustedWheelStrength(sat, .increment)",
            "SliderAccessibility.rotatedWheelHue(hue, by: 1)",
        ] {
            XCTAssertTrue(wheel.contains(needle), "LumenColorWheel lost \(needle)")
        }
    }

    func testEachDevelopSectionIsANamedGroup() throws {
        let column = try Self.appSource("DevelopColumn")
        XCTAssertTrue(column.contains(".accessibilityElement(children: .contain)\n"
                                      + "        .accessibilityLabel(Text(section.title))"))
    }
}
