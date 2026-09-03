// DecodeResidencyTests.swift
// The two ceiling rules the decode cache classifies and bounds itself with.
//
// Both live in `DraftLadder` because both are statements ABOUT its ceilings, and both
// were previously spelled out inline in `AppleRawSource` / `DecodeMaterializer` — inside
// `#if os(macOS)`, in a target that does not build on the free lane, so nothing could
// check either of them without a camera RAW and a Mac. That is the same argument
// `DraftLadder`'s own header makes for why a resolution rule is not allowed to be a
// constant in a view.

import XCTest
@testable import LumenCore

final class DecodeResidencyTests: XCTestCase {

    // MARK: - isInspectionAsk

    /// Every rung of the ladder is an interactive ask, including the top one. A rule
    /// that classified `rungs[0]` as inspection would hand the drag's own decode the
    /// budget exemption and the one-entry limit at the same time — the entry would
    /// survive eviction and evict everything else in its class.
    func testEveryRungIsInteractive() {
        for rung in DraftLadder.rungs {
            XCTAssertFalse(DraftLadder.isInspectionAsk(longEdge: rung),
                           "rung \(rung) must be an interactive ask")
        }
    }

    /// The boundary is exactly the interactive ceiling, inclusive on the interactive
    /// side. `LoupeView.maxRenderLongEdge` is that number and the fit ask is capped to
    /// it, so a fit settle on the largest window this app can be opened in must not be
    /// classified as an inspection.
    func testCeilingItselfIsInteractive() {
        XCTAssertFalse(DraftLadder.isInspectionAsk(
            longEdge: DraftLadder.interactiveLongEdgeCeiling))
        XCTAssertTrue(DraftLadder.isInspectionAsk(
            longEdge: DraftLadder.interactiveLongEdgeCeiling + 1))
    }

    /// The sizes the zoomed settle actually asks for — the sensor's own long edge —
    /// are inspection asks on every body worth zooming into.
    func testNativeSensorSizesAreInspectionAsks() {
        for native in [7008, 8256, 9504, 11664, 14204,
                       DraftLadder.inspectionLongEdgeCeiling] {
            XCTAssertTrue(DraftLadder.isInspectionAsk(longEdge: native),
                          "\(native) px is a native ask")
        }
    }

    /// A degenerate or absent ask is interactive, not inspection. The caller computes
    /// this from `scaleFactor × nativeLongEdge`, and a source that cannot say how big it
    /// is answers zero — which must not be granted the exemption reserved for the one
    /// entry the app is deliberately holding a quarter of a gigabyte for.
    func testDegenerateAsksAreNotInspections() {
        XCTAssertFalse(DraftLadder.isInspectionAsk(longEdge: 0))
        XCTAssertFalse(DraftLadder.isInspectionAsk(longEdge: -1))
    }

    /// The two ceilings are ordered, which is what makes the classification meaningful
    /// at all: an ask can be above the interactive ceiling and still be one the app is
    /// willing to make.
    func testCeilingsAreOrdered() {
        XCTAssertGreaterThan(DraftLadder.inspectionLongEdgeCeiling,
                             DraftLadder.interactiveLongEdgeCeiling)
    }

    // MARK: - mayHoldAsPixels

    /// The file the owner is actually working on: a 7008 × 4672 Sony ARW, half-float
    /// RGBA. 262 MB, and the entry the whole inspection exemption exists to hold — so
    /// the byte ceiling must not be the thing that refuses it.
    func testHoldsANativeSonyFrame() {
        XCTAssertTrue(DraftLadder.mayHoldAsPixels(width: 7008, height: 4672,
                                                  bytesPerPixel: 8))
    }

    /// Every interactive rung, at 3:2 and at 4:3, is holdable by a wide margin. These
    /// are the sizes that repeat under a hand; a byte ceiling that could refuse one
    /// would reintroduce the 457 ms-per-frame demosaic on the drag path.
    func testHoldsEveryInteractiveRung() {
        for rung in DraftLadder.rungs {
            for shortEdge in [(rung * 2) / 3, (rung * 3) / 4, rung] {
                XCTAssertTrue(DraftLadder.mayHoldAsPixels(width: rung,
                                                          height: shortEdge,
                                                          bytesPerPixel: 8),
                              "rung \(rung)×\(shortEdge) must be holdable")
            }
        }
    }

    /// The shape the long-edge limit alone cannot refuse. `inspectionLongEdgeCeiling` is
    /// 16384 so that it is past any real sensor's LONG EDGE; a square decode at that
    /// size is 1.4 GB in one allocation, and passes a long-edge test by construction.
    func testRefusesTheAllocationTheLongEdgeLimitWouldAdmit() {
        let edge = DraftLadder.inspectionLongEdgeCeiling
        XCTAssertLessThanOrEqual(edge, DraftLadder.inspectionLongEdgeCeiling,
                                 "the long-edge limit admits this shape")
        XCTAssertFalse(DraftLadder.mayHoldAsPixels(width: edge, height: edge,
                                                   bytesPerPixel: 8))
    }

    /// …and the converse, which is the other half of why one number could not do both
    /// jobs: a stitched panorama is enormous along one axis and perfectly cheap to hold.
    func testHoldsAWidePanorama() {
        XCTAssertTrue(DraftLadder.mayHoldAsPixels(width: 16000, height: 2000,
                                                  bytesPerPixel: 8))
    }

    /// Exactly on the line is holdable; one pixel past it is not. The ceiling is a
    /// budget, and a budget that rejected the amount it names would be a different
    /// number written down wrong.
    func testBoundaryIsInclusive() {
        let ceiling = DraftLadder.materializedDecodeByteCeiling
        XCTAssertEqual(ceiling % 8, 0, "the ceiling must be expressible in whole pixels")
        let pixels = ceiling / 8
        XCTAssertTrue(DraftLadder.mayHoldAsPixels(width: pixels, height: 1,
                                                  bytesPerPixel: 8))
        XCTAssertFalse(DraftLadder.mayHoldAsPixels(width: pixels + 1, height: 1,
                                                   bytesPerPixel: 8))
    }

    /// A caller that cannot say how large the buffer is has not earned one. Zero and
    /// negative dimensions answer false rather than multiplying out to a harmless-looking
    /// zero that would pass every budget.
    func testDegenerateSizesAreRefused() {
        XCTAssertFalse(DraftLadder.mayHoldAsPixels(width: 0, height: 4672,
                                                   bytesPerPixel: 8))
        XCTAssertFalse(DraftLadder.mayHoldAsPixels(width: 7008, height: 0,
                                                   bytesPerPixel: 8))
        XCTAssertFalse(DraftLadder.mayHoldAsPixels(width: 7008, height: 4672,
                                                   bytesPerPixel: 0))
        XCTAssertFalse(DraftLadder.mayHoldAsPixels(width: -7008, height: 4672,
                                                   bytesPerPixel: 8))
    }

    /// A memory bound must never answer by trapping. This test convicted the first
    /// version of the rule, which widened the product to `Int64` and called that safe:
    /// two `Int32.max` edges multiply to 4.6e18 and eight bytes a pixel takes that past
    /// a signed 64-bit word, so the guard against overflow overflowed. Nonsense
    /// dimensions come from corrupt headers, and the honest reply to nonsense is "no".
    func testLargeProductsDoNotOverflow() {
        XCTAssertFalse(DraftLadder.mayHoldAsPixels(width: 65_536, height: 65_536,
                                                   bytesPerPixel: 8))
        XCTAssertFalse(DraftLadder.mayHoldAsPixels(width: Int(Int32.max),
                                                   height: Int(Int32.max),
                                                   bytesPerPixel: 8))
        XCTAssertFalse(DraftLadder.mayHoldAsPixels(width: Int.max, height: Int.max,
                                                   bytesPerPixel: 8))
        XCTAssertFalse(DraftLadder.mayHoldAsPixels(width: Int.max, height: 1,
                                                   bytesPerPixel: 8))
    }

    /// The ceiling is a real bound rather than a formality: it has to be big enough for
    /// the working set the cache is built around and small enough to matter. One native
    /// inspection plane fits; a gigabyte does not.
    func testCeilingIsInAUsefulBand() {
        XCTAssertGreaterThanOrEqual(DraftLadder.materializedDecodeByteCeiling,
                                    7008 * 4672 * 8,
                                    "must hold one native frame from a 33 MP body")
        XCTAssertLessThan(DraftLadder.materializedDecodeByteCeiling,
                          1024 * 1024 * 1024,
                          "a gigabyte in one IOSurface is not a cache, it is a leak")
    }
}
