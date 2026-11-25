// The pump that carries a viewer's drafts: a request renders and lands whatever
// happened to the task that asked, the newest waiting request runs next, and a second
// ask for the value in flight shares its render.
#if os(macOS)

import Foundation
import XCTest
@testable import LumenApp

@MainActor
final class LatestWinsPumpTests: XCTestCase {

    private final class Log {
        var rendered: [Int] = []
        var sawSuccessor: [Bool] = []
        var cancelledInsideWork = false
    }

    /// A render the test finishes by hand.
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        @MainActor func holdUntilLifted() async {
            if isOpen { return }
            await withCheckedContinuation { (waiting: CheckedContinuation<Void, Never>) in
                continuation = waiting
            }
        }

        @MainActor func lift() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    /// The drag case: the task that asked is cancelled before it has even run.
    func testARequestFromACancelledTaskStillRendersAndLands() async {
        let pump = LatestWinsPump<Int>()
        let log = Log()
        let caller = Task { @MainActor in
            await pump.submit(1) { _ in
                await Task.yield()
                log.cancelledInsideWork = Task.isCancelled
                log.rendered.append(1)
                return true
            }
        }
        caller.cancel()
        let landed = await caller.value
        XCTAssertTrue(landed)
        XCTAssertEqual(log.rendered, [1])
        XCTAssertFalse(log.cancelledInsideWork,
                       "the work must not inherit its caller's cancellation")
    }

    func testTheFrameInFlightLandsAndOnlyTheNewestWaitingRendersNext() async {
        let pump = LatestWinsPump<Int>()
        let log = Log()
        let gate = Gate()
        let first = Task { @MainActor in
            await pump.submit(1) { successorWaiting in
                await gate.holdUntilLifted()
                log.sawSuccessor.append(successorWaiting())
                log.rendered.append(1)
                return true
            }
        }
        let second = Task { @MainActor in
            await pump.submit(2) { _ in
                log.rendered.append(2)
                return true
            }
        }
        let third = Task { @MainActor in
            await pump.submit(3) { successorWaiting in
                log.sawSuccessor.append(successorWaiting())
                log.rendered.append(3)
                return true
            }
        }
        // Displaced by the third before the first finished: told so, never rendered.
        let secondLanded = await second.value
        XCTAssertFalse(secondLanded)
        XCTAssertEqual(log.rendered, [])

        gate.lift()
        let firstLanded = await first.value
        let thirdLanded = await third.value
        XCTAssertTrue(firstLanded)
        XCTAssertTrue(thirdLanded)
        XCTAssertEqual(log.rendered, [1, 3])
        XCTAssertEqual(log.sawSuccessor, [true, false])
    }

    func testAskingAgainForTheValueInFlightSharesItsRender() async {
        let pump = LatestWinsPump<Int>()
        let log = Log()
        let gate = Gate()
        let first = Task { @MainActor in
            await pump.submit(7) { _ in
                await gate.holdUntilLifted()
                log.rendered.append(7)
                return true
            }
        }
        let again = Task { @MainActor in
            await pump.submit(7) { _ in
                log.rendered.append(-7)
                return true
            }
        }
        // Let both reach the pump before the render is allowed to finish.
        for _ in 0..<5 { await Task.yield() }
        gate.lift()
        let firstLanded = await first.value
        let againLanded = await again.value
        XCTAssertTrue(firstLanded)
        XCTAssertTrue(againLanded)
        XCTAssertEqual(log.rendered, [7])
    }

    func testAnIdlePumpStartsTheNextRequestAndReportsAFailedRender() async {
        let pump = LatestWinsPump<Int>()
        let log = Log()
        let failed = await pump.submit(1) { _ in false }
        XCTAssertFalse(failed)
        let landed = await pump.submit(2) { _ in
            log.rendered.append(2)
            return true
        }
        XCTAssertTrue(landed)
        XCTAssertEqual(log.rendered, [2])
    }
}
#endif
