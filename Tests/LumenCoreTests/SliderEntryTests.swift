// SliderEntryTests.swift
// Typing into a slider's readout, and the two ways that can go wrong.
//
// The first is arithmetic nobody asked for: a grammar in which `-40` means "subtract
// 40" turns the ordinary way of setting −40 into a silent, wrong edit. Half of these
// tests exist to pin that it does not.
//
// The second is a non-finite number reaching a recipe, which is not a bad render but
// data loss — `JSONEncoder` refuses non-conforming floats, the canonical JSON collapses
// to "{}", and that is what gets written to the sidecar. `Double(_:)` parses "nan",
// "inf" and "1e999" quite happily, so refusing them is this parser's job.

import XCTest
@testable import LumenCore

final class SliderEntryTests: XCTestCase {

    // MARK: A number replaces the value — including a negative one

    func testABareNumberIsAbsolute() {
        XCTAssertEqual(SliderEntry.parse("40"), .absolute(40))
        XCTAssertEqual(SliderEntry.parse("0"), .absolute(0))
        XCTAssertEqual(SliderEntry.parse("1.75"), .absolute(1.75))
        XCTAssertEqual(SliderEntry.parse("  12  "), .absolute(12))
    }

    func testALeadingMinusIsANegativeNumberAndNotASubtraction() {
        // The trap this grammar is shaped around. The readout pre-fills with the current
        // value and the field selects it, so replacing the lot with "-40" is how a
        // photographer sets −40 on a ±100 control. Figma's convention would read this as
        // "subtract 40" and land on −10 from a value of 30, silently.
        XCTAssertEqual(SliderEntry.parse("-40"), .absolute(-40))
        XCTAssertEqual(SliderEntry.value(of: "-40", current: 30), -40)
        XCTAssertEqual(SliderEntry.value(of: "-0.5", current: 2), -0.5)
    }

    func testALeadingPlusIsAlsoAbsoluteSoTheTwoSignsBehaveTheSame() {
        // Asymmetry would be the worst of both: "+40 adds but -40 replaces" is a rule
        // nobody can hold in their head while editing.
        XCTAssertEqual(SliderEntry.parse("+40"), .absolute(40))
        XCTAssertEqual(SliderEntry.value(of: "+40", current: 30), 40)
    }

    func testAnExplicitEqualsIsAbsoluteToo() {
        XCTAssertEqual(SliderEntry.value(of: "= 12", current: 99), 12)
        XCTAssertEqual(SliderEntry.value(of: "=-12", current: 99), -12)
    }

    // MARK: An operator changes it

    func testPlusEqualsAdds() throws {
        XCTAssertEqual(try XCTUnwrap(SliderEntry.value(of: "+= 0.3", current: 1)),
                       1.3, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(SliderEntry.value(of: "+=0.3", current: 1)),
                       1.3, accuracy: 1e-12)
        XCTAssertEqual(SliderEntry.value(of: "+= -5", current: 10), 5)
    }

    func testMinusEqualsSubtracts() throws {
        XCTAssertEqual(try XCTUnwrap(SliderEntry.value(of: "-= 0.2", current: 1)),
                       0.8, accuracy: 1e-12)
        XCTAssertEqual(SliderEntry.value(of: "-=40", current: 30), -10)
    }

    func testTimesAndOverNeedNoEqualsBecauseNoNumberStartsWithThem() {
        XCTAssertEqual(SliderEntry.value(of: "* 2", current: 21), 42)
        XCTAssertEqual(SliderEntry.value(of: "*2", current: 21), 42)
        XCTAssertEqual(SliderEntry.value(of: "*= 2", current: 21), 42)
        XCTAssertEqual(SliderEntry.value(of: "/ 2", current: 42), 21)
        XCTAssertEqual(SliderEntry.value(of: "/2", current: 42), 21)
        XCTAssertEqual(SliderEntry.value(of: "/= 2", current: 42), 21)
    }

    func testTheTypographicSignsWorkToo() {
        XCTAssertEqual(SliderEntry.value(of: "× 2", current: 21), 42)
        XCTAssertEqual(SliderEntry.value(of: "÷ 2", current: 42), 21)
    }

    func testANegativeMultiplierFlipsTheValue() {
        XCTAssertEqual(SliderEntry.value(of: "* -1", current: 37), -37)
    }

    // MARK: Nothing non-finite may reach a recipe

    func testDivideByZeroIsRefusedRatherThanResolved() {
        XCTAssertNil(SliderEntry.parse("/ 0"))
        XCTAssertNil(SliderEntry.parse("/0"))
        XCTAssertNil(SliderEntry.parse("/= 0.0"))
        XCTAssertNil(SliderEntry.value(of: "/0", current: 5))
    }

    func testTheWordsThatDoubleWillHappilyParseAreRefused() {
        for text in ["nan", "NaN", "inf", "-inf", "infinity", "Infinity"] {
            XCTAssertNil(SliderEntry.parse(text), "\(text) parsed")
            XCTAssertNil(SliderEntry.value(of: "+= \(text)", current: 1),
                         "+= \(text) parsed")
        }
    }

    func testAnOverflowingLiteralIsRefused() {
        XCTAssertNil(SliderEntry.parse("1e999"))
        XCTAssertNil(SliderEntry.parse("-1e999"))
        XCTAssertNil(SliderEntry.value(of: "* 1e999", current: 2))
    }

    func testAHexFloatIsNotANumberAPhotographerTyped() {
        XCTAssertNil(SliderEntry.parse("0x1p3"))
    }

    func testAnOverflowingRESULTIsRefusedAndNotJustAnOverflowingLiteral() {
        // The literal is fine and the arithmetic is not. Only checking the input would
        // let this one through.
        XCTAssertNil(SliderEntry.value(of: "* 1e308", current: 1e308))
        XCTAssertNil(SliderEntry.value(of: "+= 1e308", current: .greatestFiniteMagnitude))
    }

    func testARubbishStringIsNil() {
        for text in ["", "   ", "abc", "+", "-", "*", "/", "+=", "=", "1.2.3", "--4",
                     "4 5", "+= abc"] {
            XCTAssertNil(SliderEntry.parse(text), "\(text.debugDescription) parsed")
        }
    }

    // MARK: A decimal comma is a decimal point, where it cannot be a thousands comma

    func testADecimalCommaIsReadAsTheDecimalPointItIsOnACommaLocalesKeyboard() {
        // Hungarian, German and French write a half as "0,5", and the numeric keypad's
        // decimal key types ',' under those layouts. Refusing it dropped the entry
        // silently — the readout just went back to the old value — so a photographer on
        // such a keyboard could not type a fractional Exposure at all.
        XCTAssertEqual(SliderEntry.value(of: "0,5", current: 0), 0.5)
        XCTAssertEqual(SliderEntry.value(of: "-1,25", current: 0), -1.25)
        XCTAssertEqual(SliderEntry.value(of: "+= 0,25", current: 1), 1.25)
        XCTAssertEqual(SliderEntry.value(of: "-=0,3", current: 1), 0.7)
        XCTAssertEqual(SliderEntry.value(of: "* 1,5", current: 2), 3)
        XCTAssertEqual(SliderEntry.value(of: "/ 0,5", current: 2), 4)
    }

    func testACommaThatCouldBeAThousandsSeparatorIsRefusedRatherThanGuessed() {
        // Temperature runs to 50 000 K through this same parser. On an English keyboard
        // "5,500" means 5500 K; read as 5.5 it would clamp to 2000 K with no warning,
        // which is the quiet wrong edit this type exists to prevent. Exactly three digits
        // after the comma is ambiguous, so it stays refused, as do two separators.
        for text in ["5,500", "1,000", "+= 1,500", "1,2,3", "1,5.0", "1.5,0", ","] {
            XCTAssertNil(SliderEntry.parse(text), "\(text.debugDescription) parsed")
        }
    }

    func testANonFiniteCURRENTValueCannotBeBuiltOn() {
        // Defence in depth: nothing should ever hand this a NaN, and if something does,
        // the answer is "no" rather than another NaN travelling one hop further.
        XCTAssertNil(SliderEntry.value(of: "+= 1", current: .nan))
        XCTAssertNil(SliderEntry.value(of: "* 2", current: .infinity))
        // An absolute entry does not READ the current value, but it is still refused:
        // a control whose value is already NaN is broken, and writing over it silently
        // would hide that rather than fix it.
        XCTAssertNil(SliderEntry.value(of: "40", current: .nan))
    }

    // MARK: The properties that matter more than any single case

    func testEveryParseOfEveryFormattedValueRoundTripsToItself() {
        // Whatever the readout shows, typing it back must be a no-op. This is what makes
        // "click the number, glance at it, press return" safe.
        for decimals in 0...2 {
            for value in [-150.0, -5.5, -1, 0, 0.25, 1, 42, 5500, 50000] {
                let shown = String(format: "%.\(decimals)f", value)
                guard let back = SliderEntry.value(of: shown, current: value) else {
                    XCTFail("readout \(shown) did not parse")
                    continue
                }
                XCTAssertEqual(back, Double(shown) ?? .nan, accuracy: 1e-9)
            }
        }
    }

    func testAddingThenSubtractingTheSameAmountReturnsToWhereItStarted() {
        for start in [-100.0, -0.5, 0, 0.5, 100] {
            let up = SliderEntry.value(of: "+= 3.25", current: start)
            XCTAssertEqual(SliderEntry.value(of: "-= 3.25", current: up ?? .nan) ?? .nan,
                           start, accuracy: 1e-9)
        }
    }

    func testMultiplyingThenDividingReturnsToWhereItStarted() {
        for start in [-100.0, -0.5, 0.5, 100] {
            let up = SliderEntry.value(of: "* 4", current: start)
            XCTAssertEqual(SliderEntry.value(of: "/ 4", current: up ?? .nan) ?? .nan,
                           start, accuracy: 1e-9)
        }
    }
}
