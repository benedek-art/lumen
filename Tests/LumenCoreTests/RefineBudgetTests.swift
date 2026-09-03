// RefineBudgetTests.swift
// The progressive-refine deadline, checked against the constant the viewer sleeps for.
//
// The defect this pins: the viewer waited 250 ms and THEN started the quality pass,
// against a docs/12 budget of 200 ms from the last input. No render, at any speed, on
// any machine, could land inside the budget. A comment claimed the 250 ms already
// contained the pass; the statement order in the file said otherwise, and nothing
// could arbitrate because the constant lived in a target with no tests.

import XCTest
@testable import LumenCore

final class RefineBudgetTests: XCTestCase {

    func testTheLoupeBudgetIsTheOneDocsTwelveStates() {
        // "Progressive refine to full quality — ≤200 ms after drag pause", docs/12
        // §12.2, measured input→photon.
        XCTAssertEqual(RefineBudget.loupe.totalNanoseconds, 200_000_000)
    }

    func testTheDebounceAloneCannotSpendTheDeadline() {
        // The by-construction failure, stated as an assertion: a debounce that meets or
        // exceeds the deadline leaves no time in which any pass could finish. 250 ms
        // against 200 ms fails here.
        XCTAssertTrue(RefineBudget.loupe.isAchievable)
        XCTAssertLessThan(RefineBudget.loupe.settleNanoseconds,
                          RefineBudget.loupe.totalNanoseconds)
        XCTAssertGreaterThan(RefineBudget.loupe.renderAllowanceNanoseconds, 0)
    }

    func testThePassesKeepTheGreaterPartOfTheDeadline() {
        // Waiting is the part of the budget that buys the least: it produces no pixels
        // and cannot be made faster by better code. Two render passes have to fit in
        // what is left, so the debounce is held to a quarter of the deadline.
        XCTAssertLessThanOrEqual(RefineBudget.loupe.settleShare, 0.25)
        XCTAssertGreaterThan(RefineBudget.loupe.renderAllowanceNanoseconds,
                             RefineBudget.loupe.settleNanoseconds)
    }

    func testTheDebounceIsLongerThanTheGapBetweenTwoDragEvents() {
        // The other end of it. A debounce shorter than the interval between two events
        // of a live drag fires mid-drag on every frame, so the quality pass is started
        // and superseded continuously. 16.7 ms is one frame at 60 Hz, which is the
        // slowest event rate a drag arrives at.
        XCTAssertGreaterThan(RefineBudget.loupe.settleNanoseconds, 16_700_000)
    }

    func testTheAllowanceIsWhateverTheDebounceDidNotTake() {
        let budget = RefineBudget(totalNanoseconds: 200_000_000,
                                  settleNanoseconds: 40_000_000)
        XCTAssertEqual(budget.renderAllowanceNanoseconds, 160_000_000)
        XCTAssertEqual(budget.settleNanoseconds + budget.renderAllowanceNanoseconds,
                       budget.totalNanoseconds)
    }

    func testABudgetSpentEntirelyOnWaitingReportsNoAllowanceRatherThanUnderflowing() {
        // The shape the viewer actually shipped. `renderAllowanceNanoseconds` is
        // unsigned, so the arithmetic that says "there is nothing left" must not be a
        // subtraction that traps or wraps to nineteen billion seconds.
        let overspent = RefineBudget(totalNanoseconds: 200_000_000,
                                     settleNanoseconds: 250_000_000)
        XCTAssertFalse(overspent.isAchievable)
        XCTAssertEqual(overspent.renderAllowanceNanoseconds, 0)
        XCTAssertGreaterThan(overspent.settleShare, 1)

        let exact = RefineBudget(totalNanoseconds: 200_000_000,
                                 settleNanoseconds: 200_000_000)
        XCTAssertFalse(exact.isAchievable, "a deadline reached is a deadline missed")
        XCTAssertEqual(exact.renderAllowanceNanoseconds, 0)
    }

    func testAZeroDeadlineIsReportedAsFullySpentRatherThanDividingByZero() {
        let empty = RefineBudget(totalNanoseconds: 0, settleNanoseconds: 0)
        XCTAssertEqual(empty.settleShare, 1)
        XCTAssertFalse(empty.isAchievable)
        XCTAssertEqual(empty.renderAllowanceNanoseconds, 0)
    }
}
