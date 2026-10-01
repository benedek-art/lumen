// LastValueMemoTests.swift
// The mixer ribbon is computed once per arc geometry, not once per mouse event (B3-04).

import XCTest
@testable import LumenCore

final class LastValueMemoTests: XCTestCase {

    private func ribbon(_ arcs: [ColorEngine.BandArc]) -> [[Double]] {
        (0...96).map { ColorEngine.bandWeights(hue: Double($0) / 96 * 360, arcs: arcs) }
    }

    func testTheRibbonIsComputedOnceForUnchangedArcs() {
        let memo = LastValueMemo<[ColorEngine.BandArc], [[Double]]>()
        let arcs = ColorEngine.bandArcs([MixerBand](repeating: MixerBand(), count: 8))
        let first = memo.value(for: arcs, compute: ribbon)
        // Forty more "mouse events" of an unrelated drag: the arcs are rebuilt from the
        // same bands each time, equal but not identical.
        for _ in 0..<40 {
            let again = ColorEngine.bandArcs([MixerBand](repeating: MixerBand(), count: 8))
            XCTAssertEqual(memo.value(for: again, compute: ribbon), first)
        }
        XCTAssertEqual(memo.misses, 1,
                       "the ribbon's 97 membership vectors were rebuilt for arcs that had "
                           + "not changed")
    }

    func testMovingOneHandleRecomputes() {
        let memo = LastValueMemo<[ColorEngine.BandArc], [[Double]]>()
        var bands = [MixerBand](repeating: MixerBand(), count: 8)
        let before = memo.value(for: ColorEngine.bandArcs(bands), compute: ribbon)
        bands[2].core = [bands[2].core[0] + 10, bands[2].core[1]]
        let movedArcs = ColorEngine.bandArcs(bands)
        let after = memo.value(for: movedArcs, compute: ribbon)
        XCTAssertEqual(memo.misses, 2, "a moved handle must redraw the ribbon")
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(after, ribbon(movedArcs),
                       "the remembered ribbon must be the one the live arcs draw")
    }

    /// The panel draws the remembered ribbon, not a fresh one per body.
    func testTheMixerPanelDrawsTheRememberedRibbon() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LumenApp/ColorPanel.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let calls = source.split(separator: "\n")
            .filter { $0.contains("MixerBandRibbon(weights:") }
        XCTAssertEqual(calls.count, 1, "expected one ribbon in the panel")
        for call in calls {
            XCTAssertTrue(call.contains("ColorPanel.ribbon(arcs)"),
                          "the ribbon is computed per body again: \(call)")
        }
        XCTAssertTrue(source.contains("ribbonMemo.value(for: arcs, compute: ribbonWeights)"),
                      "ColorPanel.ribbon no longer goes through the memo")
    }
}
