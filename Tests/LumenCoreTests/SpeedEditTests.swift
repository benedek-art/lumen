// The tap/hold discriminator and the drag arithmetic behind D44's Speed Edit.
import XCTest
@testable import LumenCore

final class SpeedEditTests: XCTestCase {

    // MARK: The discriminator

    /// A short, still press is the key's ordinary meaning. This is the case that must
    /// never regress, because eight of these letters already DO something.
    func testAShortStillPressIsATap() {
        XCTAssertEqual(SpeedEdit.resolve(key: "s", heldMilliseconds: 60,
                                         pointerMoved: false), .tap)
    }

    /// MOVEMENT WINS OVER TIME, and the ordering is the whole discriminator: a
    /// photographer who presses and immediately drags has committed inside 20 ms, and
    /// waiting out 150 ms first would put a visible hitch at the start of every speed
    /// edit — the one place it has to feel instant.
    func testMovementMakesItAnEditBeforeTheThresholdElapses() {
        XCTAssertEqual(SpeedEdit.resolve(key: "e", heldMilliseconds: 20,
                                         pointerMoved: true), .edit)
    }

    /// Held past the threshold without moving is still an edit — that is what "hold to
    /// adjust, then drag" means, and the readout has to be up before the drag starts or
    /// the photographer cannot tell the hold registered.
    func testHoldingPastTheThresholdIsAnEditEvenWithoutMovement() {
        XCTAssertEqual(
            SpeedEdit.resolve(key: "e",
                              heldMilliseconds: SpeedEdit.holdThresholdMilliseconds,
                              pointerMoved: false), .edit)
    }

    /// A SLOW PRESS OF AN UNRELATED KEY MUST STILL WORK. `G` is the grid and edits
    /// nothing; holding it for half a second because a hand is slow must still show the
    /// grid. Refusing would mean a photographer cannot tell a slow press from a broken
    /// app — which is the single worst failure mode a discriminator has.
    func testASlowPressOfANonEditingKeyStillDoesItsJob() {
        XCTAssertEqual(SpeedEdit.resolve(key: "g", heldMilliseconds: 800,
                                         pointerMoved: false), .tapAfterHold)
        XCTAssertEqual(SpeedEdit.resolve(key: "g", heldMilliseconds: 800,
                                         pointerMoved: true), .tapAfterHold,
                       "a key that edits nothing cannot be dragged into an edit either")
    }

    /// The boundary itself, stated once so a later refactor cannot quietly move it.
    func testTheThresholdIsInclusive() {
        let t = SpeedEdit.holdThresholdMilliseconds
        XCTAssertEqual(SpeedEdit.resolve(key: "e", heldMilliseconds: t - 0.001,
                                         pointerMoved: false), .tap)
        XCTAssertEqual(SpeedEdit.resolve(key: "e", heldMilliseconds: t,
                                         pointerMoved: false), .edit)
    }

    // MARK: The map

    /// docs/12 §12.4's eight letters, and nothing else.
    func testTheMappedLettersAreTheSpecsEight() {
        let mapped = "abcdefghijklmnopqrstuvwxyz".filter {
            SpeedEdit.parameter(forKey: String($0)) != nil
        }
        XCTAssertEqual(String(mapped).sorted(), "cehkmstw".sorted())
    }

    func testTheMapIsCaseInsensitive() {
        XCTAssertEqual(SpeedEdit.parameter(forKey: "E"), .exposure)
        XCTAssertEqual(SpeedEdit.parameter(forKey: "e"), .exposure)
    }

    /// No two letters may edit the same parameter, and no parameter may be unreachable
    /// — either would be a map that reads as complete and is not.
    func testEveryParameterHasExactlyOneLetter() {
        var seen: [SpeedEdit.Parameter: Int] = [:]
        for scalar in "abcdefghijklmnopqrstuvwxyz" {
            if let p = SpeedEdit.parameter(forKey: String(scalar)) {
                seen[p, default: 0] += 1
            }
        }
        let unreachable = Set(SpeedEdit.Parameter.allCases).subtracting(seen.keys)
        XCTAssertEqual(Set(seen.keys), Set(SpeedEdit.Parameter.allCases),
                       "unreachable: \(unreachable)")
        XCTAssertTrue(seen.values.allSatisfy { $0 == 1 })
    }

    // MARK: The drag

    /// ONE WINDOW-WIDTH IS ONE FULL RANGE, for every parameter. That is the property
    /// that makes a pointer-free edit learnable: the hand learns one distance, not
    /// eight, however differently the parameters are denominated.
    func testAFullWidthDragCoversAParametersWholeRange() {
        for parameter in SpeedEdit.Parameter.allCases {
            let span = parameter.range.upperBound - parameter.range.lowerBound
            let moved = SpeedEdit.delta(dragPoints: 1000, across: 1000,
                                        parameter: parameter, fine: false)
            XCTAssertEqual(moved, span, accuracy: parameter.step,
                           "\(parameter) does not travel its range in one width")
        }
    }

    /// ⇧ is a tenth, matching the slider's own fine drag rather than inventing a second
    /// ratio for the same idea.
    func testShiftIsATenth() {
        let coarse = SpeedEdit.delta(dragPoints: 500, across: 1000,
                                     parameter: .contrast, fine: false)
        let fine = SpeedEdit.delta(dragPoints: 500, across: 1000,
                                   parameter: .contrast, fine: true)
        XCTAssertEqual(fine, coarse / 10, accuracy: 1e-9)
    }

    /// A speed edit must land on the same quantised values a slider does, or the two
    /// produce different numbers for the same gesture and the recipe records which tool
    /// was used.
    func testADragLandsOnTheParametersStep() {
        for parameter in SpeedEdit.Parameter.allCases {
            let value = SpeedEdit.value(from: parameter.range.lowerBound,
                                        dragPoints: 137.4, across: 900,
                                        parameter: parameter, fine: false)
            let steps = value / parameter.step
            XCTAssertEqual(steps, steps.rounded(), accuracy: 1e-6,
                           "\(parameter) landed off its own step at \(value)")
        }
    }

    /// Clamped at both ends, so dragging past the edge of the window cannot write a
    /// value the panel could never show.
    func testADragCannotLeaveTheParametersRange() {
        for parameter in SpeedEdit.Parameter.allCases {
            let high = SpeedEdit.value(from: parameter.range.upperBound,
                                       dragPoints: 100000, across: 800,
                                       parameter: parameter, fine: false)
            let low = SpeedEdit.value(from: parameter.range.lowerBound,
                                      dragPoints: -100000, across: 800,
                                      parameter: parameter, fine: false)
            XCTAssertLessThanOrEqual(high, parameter.range.upperBound)
            XCTAssertGreaterThanOrEqual(low, parameter.range.lowerBound)
        }
    }

    /// A zero or nonsense width is a layout that has not happened yet, and it must move
    /// nothing rather than divide by it.
    func testAnUnmeasuredWindowMovesNothing() {
        XCTAssertEqual(SpeedEdit.delta(dragPoints: 200, across: 0,
                                       parameter: .exposure, fine: false), 0)
        XCTAssertEqual(SpeedEdit.delta(dragPoints: .nan, across: 900,
                                       parameter: .exposure, fine: false), 0)
    }

    /// Dragging back to where you started returns the value you started with. Trivial
    /// to state, easy to break with an accumulating implementation, and the difference
    /// a photographer feels as drift.
    func testADragAndItsReverseCancel() {
        let there = SpeedEdit.value(from: 0, dragPoints: 240, across: 900,
                                    parameter: .contrast, fine: false)
        let back = SpeedEdit.value(from: there, dragPoints: -240, across: 900,
                                   parameter: .contrast, fine: false)
        XCTAssertEqual(back, 0, accuracy: 1e-9)
    }
}
