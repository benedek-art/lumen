// MaskOverlayCompositeSizeTests.swift
// How big the overlay layer is built, which is how fast dragging a mask feels.
//
// The overlay is composited one output pixel at a time in Swift, so this number squared
// IS the cost of every frame the photographer sees while moving a gradient. The owner's
// report — "the mask isn't updating quick enough, so if I drag it around, it's still
// delayed" — was two full-size passes per settled frame: a 1024-px alpha fold under a
// 2048-px composite, whether or not anything at that size could be seen.
//
// The fix is a draft alpha during a gesture and a layer that follows it down. This is
// the "follows it down" half, and it is arithmetic with a right answer, so it is here
// rather than inside a macOS-gated view where the only way to check it is to look at it.

import XCTest
@testable import LumenCore

final class MaskOverlayCompositeSizeTests: XCTestCase {

    /// The settled case: a full-size alpha earns the full cap.
    ///
    /// This is the assertion that stops the optimisation from becoming a permanent
    /// downgrade. A rule that made everything cheap would pass every performance test
    /// here and quietly cost the app its overlay quality at rest, which is when the
    /// edge is actually being judged.
    func testAFullSizeAlphaCompositesAtTheFullCap() {
        XCTAssertEqual(MaskOverlay.compositeLongEdge(alphaLongEdge: 1024, cap: 2048), 2048)
    }

    /// The gesture case, and the whole point: half the alpha is a quarter of the work.
    ///
    /// 512 × 2 = 1024 against a 2048 cap, so the layer is half as wide and half as tall
    /// — 1.4 megapixels instead of 5.6 for a 3:2 frame at the cap. Together with the
    /// alpha fold's own 4×, that is the difference between an overlay that trails the
    /// hand and one that keeps up.
    func testADraftAlphaHalvesTheLayerRatherThanInterpolatingDetailItDoesNotHave() {
        let settled = MaskOverlay.compositeLongEdge(alphaLongEdge: 1024, cap: 2048)
        let draft = MaskOverlay.compositeLongEdge(alphaLongEdge: 512, cap: 2048)
        XCTAssertEqual(draft, 1024)
        XCTAssertEqual(Double(settled) / Double(draft), 2, accuracy: 0.001,
                       "Halving the alpha must halve the layer's edge — a quarter of "
                       + "the pixels — or the draft raster buys nothing.")
    }

    /// The cap is a CEILING and the alpha bound never raises it.
    ///
    /// The bug this forbids is the one that would undo the pane bound `compositeLongEdge`
    /// exists for: an alpha bigger than half the cap must not talk the composite up past
    /// it. At 4096 the loop ran 11.2 million times, measured at 823 ms, to feed a pane
    /// rarely wider than 1400 points.
    func testAnAlphaLargerThanTheCapCannotRaiseIt() {
        XCTAssertEqual(MaskOverlay.compositeLongEdge(alphaLongEdge: 4096, cap: 2048), 2048)
        XCTAssertEqual(MaskOverlay.compositeLongEdge(alphaLongEdge: 100_000, cap: 2048), 2048)
    }

    /// A tiny alpha still composites at something a person would call a picture.
    ///
    /// A mask row's thumbnail plane is 96 px on its long edge and reaches the renderer
    /// by the same call. Doubling that alone would build a 192-px overlay over the whole
    /// photograph, which does not read as "soft while you drag" — it reads as broken.
    func testATinyAlphaIsFlooredRatherThanDoubled() {
        XCTAssertEqual(MaskOverlay.compositeLongEdge(alphaLongEdge: 96, cap: 2048), 512)
        XCTAssertEqual(MaskOverlay.compositeLongEdge(alphaLongEdge: 8, cap: 2048), 512)
    }

    /// The floor is a floor, not an override: a small CAP still wins.
    ///
    /// Both bounds are ceilings. If the 512 floor could beat the cap, a pane that asked
    /// for a small layer would get a large one, which is the failure mode in the exact
    /// opposite direction from the one being fixed.
    func testTheCapBeatsTheFloor() {
        XCTAssertEqual(MaskOverlay.compositeLongEdge(alphaLongEdge: 96, cap: 256), 256)
        XCTAssertEqual(MaskOverlay.compositeLongEdge(alphaLongEdge: 1024, cap: 300), 300)
    }

    /// Never zero, whatever it is handed.
    ///
    /// The result is a divisor and an image dimension downstream. A degenerate cap
    /// arriving from a collapsed pane must produce a small layer, not a crash.
    func testItNeverReturnsAnUnusableSize() {
        XCTAssertEqual(MaskOverlay.compositeLongEdge(alphaLongEdge: 0, cap: 0), 1)
        XCTAssertGreaterThan(MaskOverlay.compositeLongEdge(alphaLongEdge: -5, cap: -5), 0)
    }

    /// Monotonic: a better alpha is never composited smaller than a worse one.
    ///
    /// The property that makes the rule safe to apply per frame. Without it, the alpha
    /// improving mid-gesture could shrink the layer, and the overlay would visibly
    /// coarsen at the exact moment the photographer let go.
    func testABetterAlphaIsNeverCompositedSmaller() {
        var previous = 0
        for edge in stride(from: 8, through: 3000, by: 37) {
            let size = MaskOverlay.compositeLongEdge(alphaLongEdge: edge, cap: 2048)
            XCTAssertGreaterThanOrEqual(size, previous,
                                        "Growing the alpha shrank the layer at \(edge).")
            previous = size
        }
    }
}
