// The Point Colour minus button's contract: the swatch removed is the swatch the RING
// marks — the clamped, displayed selection — never the raw view-state index.
//
// The defect this pins (docs/32 Stream D item 3, "the minus button does nothing"):
// `ColorPanel.selectedSwatch` is @State on the panel while the swatch list is per
// photo, so a photo switch could leave the selection pointing past the current list's
// end. Everything the user could SEE clamped it — the ring, the sliders, the button's
// enabled state — but `removeSwatch()` read it raw, and the mutation's own bounds
// guard turned the click into a silent no-op: an enabled button, a ringed chip, and
// nothing happening. `removalTarget` is the clamp `removeSwatch` now routes through;
// these tests are what keeps a refactor from quietly reading the raw index again.
#if os(macOS)

import XCTest
import LumenCore
@testable import LumenApp

final class PointColorSwatchTests: XCTestCase {

    // The shipped scenario, exactly: the previous photo had three swatches with the
    // third selected; this photo has one. The list is non-empty so the button is
    // enabled and the ring marks chip 0 — the removal must take index 0, which the
    // raw selection (2) never would have reached.
    func testAStaleSelectionStillRemovesTheRingedSwatch() {
        XCTAssertEqual(ColorPanel.removalTarget(selected: 2, count: 1), 0,
                       "the ring clamps to the tail, so the removal must too")
    }

    func testTheTargetIsAlwaysTheDisplayedIndex() {
        // The display rule in `pointColorSection` is
        // `min(max(selectedSwatch, 0), swatches.count - 1)`; the removal target must
        // be that value for every selection the view state could be holding, in
        // bounds or not, negative included.
        for selected in -3...10 {
            for count in 1...ColorPanel.maxSwatches {
                let target = ColorPanel.removalTarget(selected: selected, count: count)
                XCTAssertEqual(target, min(max(selected, 0), count - 1),
                               "selected \(selected) of \(count) must remove the "
                               + "chip the ring marks")
            }
        }
    }

    func testAnEmptyListHasNothingToRemove() {
        // nil is what keeps the button disabled and the mutation unreached — the one
        // case where "does nothing" is the correct behaviour.
        XCTAssertNil(ColorPanel.removalTarget(selected: 0, count: 0))
        XCTAssertNil(ColorPanel.removalTarget(selected: 5, count: 0))
    }

    // End to end on a real swatch list: with a stale selection, the swatch that
    // disappears is the ringed tail chip, not "nothing" and not some other index.
    func testRemovalTakesOutTheSwatchTheRingMarks() {
        var list = [PointColor(sample: [1, 0, 0]),
                    PointColor(sample: [0, 1, 0]),
                    PointColor(sample: [0, 0, 1])]
        guard let target = ColorPanel.removalTarget(selected: 7, count: list.count)
        else {
            XCTFail("three swatches must yield a removal target")
            return
        }
        list.remove(at: target)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.map { $0.sample }, [[1, 0, 0], [0, 1, 0]],
                       "selection 7 rings the tail chip — the blue tail is what goes")
    }

    func testTheRingLandsSomewhereRealAfterARemoval() {
        // Removing the tail pulls the ring back one; removing an interior swatch
        // keeps the slot (the next swatch moves up into it); emptying the list floors
        // at zero rather than going negative.
        XCTAssertEqual(ColorPanel.selectionAfterRemoval(of: 2, newCount: 2), 1)
        XCTAssertEqual(ColorPanel.selectionAfterRemoval(of: 0, newCount: 2), 0)
        XCTAssertEqual(ColorPanel.selectionAfterRemoval(of: 0, newCount: 0), 0)
    }
}

#endif
