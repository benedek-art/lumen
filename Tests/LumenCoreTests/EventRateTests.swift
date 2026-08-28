// The rate counter behind the HUD's input/s and frames/s pair — the two numbers that
// tell a render bottleneck apart from dropped input. See `EventRate`'s header.
import XCTest
@testable import LumenCore

final class EventRateTests: XCTestCase {

    /// A steady stream reads as its own frequency.
    func testASteadyStreamReadsAsItsFrequency() {
        var rate = EventRate()
        var t = 0.0
        for _ in 0..<60 {
            rate.record(at: t)
            t += 1.0 / 60
        }
        let measured = try? XCTUnwrap(rate.perSecond(now: t))
        XCTAssertEqual(measured ?? 0, 60, accuracy: 1,
                       "sixty events one sixtieth of a second apart is 60 per second")
    }

    /// THE REASON THIS IS NOT `count ÷ window`. A gesture 200 ms old has put its events
    /// into a fifth of the window, and dividing by the whole window would report a
    /// fifth of the true rate — for the first second of every drag, which is precisely
    /// when someone is watching the HUD.
    func testAStreamShorterThanTheWindowStillReadsAtFullRate() {
        var rate = EventRate()
        var t = 0.0
        for _ in 0..<12 {                     // 200 ms of a 60 Hz drag
            rate.record(at: t)
            t += 1.0 / 60
        }
        let measured = try? XCTUnwrap(rate.perSecond(now: t))
        XCTAssertEqual(measured ?? 0, 60, accuracy: 2,
                       "a drag that just started is not a slow drag")
    }

    /// The distinction the HUD exists to draw, as arithmetic: same window, two streams,
    /// two very different numbers.
    func testDroppedInputAndASlowRenderAreDifferentNumbers() {
        // Input seen at 12 Hz and frames out at 12 Hz: the render loop is keeping up
        // perfectly with a gesture it is only seeing a fifth of.
        var starvedInput = EventRate()
        var starvedFrames = EventRate()
        // Input seen at 60 Hz, frames out at 12 Hz: the hand is seen, the picture
        // cannot keep up.
        var liveInput = EventRate()

        var t = 0.0
        for step in 0..<60 {
            liveInput.record(at: t)
            if step % 5 == 0 {
                starvedInput.record(at: t)
                starvedFrames.record(at: t)
            }
            t += 1.0 / 60
        }

        XCTAssertEqual(starvedInput.perSecond(now: t) ?? 0, 12, accuracy: 1)
        XCTAssertEqual(starvedFrames.perSecond(now: t) ?? 0, 12, accuracy: 1)
        XCTAssertEqual(liveInput.perSecond(now: t) ?? 0, 60, accuracy: 2)
        // Equal in / out at a low rate means the input never arrived; the pair is the
        // whole diagnostic and either number alone says nothing.
        XCTAssertEqual(starvedInput.perSecond(now: t) ?? 0,
                       starvedFrames.perSecond(now: t) ?? 0, accuracy: 0.5)
    }

    func testOneEventIsATimestampNotARate() {
        var rate = EventRate()
        rate.record(at: 5)
        XCTAssertNil(rate.perSecond(now: 5),
                     "a rate needs an interval, and one event has none")
        XCTAssertFalse(rate.isIdle(now: 5), "something did happen, though")
    }

    func testLettingGoClearsWithinABeat() {
        var rate = EventRate()
        var t = 0.0
        for _ in 0..<60 {
            rate.record(at: t)
            t += 1.0 / 60
        }
        XCTAssertNotNil(rate.perSecond(now: t))
        XCTAssertTrue(rate.isIdle(now: t + EventRate.windowSeconds + 0.01),
                      "a window after the hand stopped, the HUD must not still be "
                          + "showing the drag's rate")
        XCTAssertNil(rate.perSecond(now: t + EventRate.windowSeconds + 0.01))
    }

    /// Stamps outside the window must not be counted, or a drag that paused would read
    /// as a slow drag rather than as two fast ones.
    func testEventsOlderThanTheWindowAreForgotten() {
        var rate = EventRate()
        for i in 0..<10 { rate.record(at: Double(i) * 0.5) }   // 2 Hz for five seconds
        var t = 10.0
        for _ in 0..<60 {                                       // then 60 Hz
            rate.record(at: t)
            t += 1.0 / 60
        }
        XCTAssertEqual(rate.perSecond(now: t) ?? 0, 60, accuracy: 2,
                       "the slow prelude is outside the window and must not drag the "
                           + "current rate down")
    }

    /// A clock that goes backwards produces a negative span and, unguarded, a negative
    /// rate. The HUD prints this number and a photographer will believe it.
    func testAClockGoingBackwardsIsIgnoredRatherThanBelieved() {
        var rate = EventRate()
        rate.record(at: 1.0)
        rate.record(at: 1.1)
        rate.record(at: 0.2)          // dropped
        rate.record(at: .nan)         // dropped
        let measured = rate.perSecond(now: 1.1)
        XCTAssertNotNil(measured)
        XCTAssertGreaterThan(measured ?? -1, 0)
    }
}
