// HistogramDisplayTests.swift
// What `Histogram.normalized(_:)` — the array `HistogramView` and the curve
// editor's backdrop actually draw — owes the extreme frames that most need a
// histogram. Found by the owner in session 2 (docs/23, audit fix queue item 14):
// at +5 EV the panel read "29.86% white" over a graph drawn almost empty, because
// a third of the pixels sat in one bin and every other bin was scaled against it
// into sub-pixel heights. The caption was doing the histogram's job.
//
// The contract fixed here: the drawing reference is the 99th-percentile NONZERO
// bin height, not the raw peak — a spike saturates at the panel's ceiling instead
// of erasing the field (the Lightroom behaviour), while a histogram with no spike
// keeps its exact proportions because the percentile of its few occupied bins IS
// its peak. `peak(_:)` still reports the true count for anything that needs it.

import XCTest
@testable import LumenCore

final class HistogramDisplayTests: XCTestCase {

    /// A histogram with `heights` placed on the red channel starting at bin 20,
    /// plus an optional spike in the last bin. Everything else zero.
    private func redHistogram(bins: Int = 256,
                              heights: [Int],
                              spike: Int = 0) -> Histogram {
        var counts = [Int](repeating: 0, count: Histogram.channelCount * bins)
        for (i, h) in heights.enumerated() { counts[20 + i] = h }
        if spike > 0 { counts[bins - 1] = spike }
        let total = heights.reduce(0, +) + spike
        return Histogram(bins: bins, counts: counts, sampleCount: total,
                         transform: ReadoutTransform(space: .srgb255, working: .rec2020),
                         clippedLowCounts: [0, 0, 0, 0],
                         clippedHighCounts: [spike, 0, 0, 0])
    }

    /// The owner's +5 EV frame in miniature: a broad field of occupied bins and a
    /// white-bin spike holding ~30% of the samples. The field must still draw at
    /// full height — under peak normalization it drew at 100/7714 ≈ 0.013 of the
    /// panel, which on a 60-point panel is less than one point.
    func testASpikeCannotEraseTheRestOfTheGraph() {
        let field = [Int](repeating: 100, count: 90) + [Int](repeating: 50, count: 90)
        let h = redHistogram(heights: field, spike: 7714)
        let drawn = h.normalized(.red)

        // The tall half of the field reaches the top of the panel …
        XCTAssertEqual(drawn[30], 1.0, accuracy: 1e-12,
                       "a 100-count bin must draw full height when the 99th-percentile"
                       + " occupied bin is 100 — got \(drawn[30])")
        // … the half-height field keeps its proportion …
        XCTAssertEqual(drawn[150], 0.5, accuracy: 1e-12)
        // … and the spike saturates at the ceiling instead of owning the scale.
        XCTAssertEqual(drawn[255], 1.0, accuracy: 1e-12)
        // The raw peak is still the truth for non-drawing consumers.
        XCTAssertEqual(h.peak(.red), 7714)
    }

    /// A sparse histogram — a handful of occupied bins, no spike — must keep its
    /// exact peak-relative proportions: the 99th percentile of four occupied bins
    /// is the tallest of them, so nothing clamps and nothing rescales.
    func testASparseHistogramKeepsItsExactProportions() {
        let h = redHistogram(heights: [50, 100, 150, 200])
        let drawn = h.normalized(.red)
        XCTAssertEqual(drawn[20], 0.25, accuracy: 1e-12)
        XCTAssertEqual(drawn[21], 0.50, accuracy: 1e-12)
        XCTAssertEqual(drawn[22], 0.75, accuracy: 1e-12)
        XCTAssertEqual(drawn[23], 1.00, accuracy: 1e-12)
        XCTAssertEqual(drawn[24], 0.0, accuracy: 1e-12)
    }

    /// Empty stays empty — no division by a zero reference.
    func testAnEmptyHistogramDrawsNothing() {
        let h = redHistogram(heights: [])
        XCTAssertEqual(h.normalized(.red).reduce(0, +), 0.0, accuracy: 1e-12)
    }

    /// The three colour traces are drawn on one pair of axes, additively, so a
    /// reader compares them — "red fills the graph, blue is a spike" is read as a
    /// statement about the image. That only holds if R, G and B share ONE vertical
    /// reference, the way the parade "normalizes as one instrument". Under a
    /// per-channel reference a tungsten-lit frame with red spread evenly over 200
    /// bins and blue packed into 20 drew both at full height: equal sample counts,
    /// red painted with ten times blue's area, the cast read backwards. With the
    /// shared 99th-percentile reference (here blue's 10-count bins) red draws at
    /// 0.1 and the two areas match, as their counts do — exact here because no bin
    /// exceeds the shared reference; a spike above it still saturates.
    func testTheColourTracesShareOneVerticalScaleSoEqualCountsDrawEqualAreas() {
        let bins = 256
        var counts = [Int](repeating: 0, count: Histogram.channelCount * bins)
        for i in 20..<220 { counts[0 * bins + i] = 1 }      // red: 200 bins of 1
        for i in 100..<120 { counts[2 * bins + i] = 10 }    // blue: 20 bins of 10
        let h = Histogram(bins: bins, counts: counts, sampleCount: 200,
                          transform: ReadoutTransform(space: .srgb255, working: .rec2020),
                          clippedLowCounts: [0, 0, 0, 0],
                          clippedHighCounts: [0, 0, 0, 0])
        let redArea = h.normalized(.red).reduce(0, +)
        let blueArea = h.normalized(.blue).reduce(0, +)
        XCTAssertEqual(redArea, blueArea, accuracy: blueArea * 0.01,
                       "red and blue hold the same 200 samples, so their drawn areas must"
                       + " match on a shared scale — got red \(redArea), blue \(blueArea)")
        XCTAssertEqual(h.normalized(.blue)[110], 1.0, accuracy: 1e-12)
        XCTAssertEqual(h.normalized(.red)[50], 0.1, accuracy: 1e-12)
        XCTAssertEqual(h.normalized(.green).reduce(0, +), 0.0, accuracy: 1e-12)
    }

    /// Luma is a separate line drawn over the channels (and the curve editor's
    /// backdrop on its own), so it keeps its own reference: a luma channel is not
    /// rescaled by a colour channel's spread.
    func testLumaKeepsItsOwnReference() {
        let bins = 256
        var counts = [Int](repeating: 0, count: Histogram.channelCount * bins)
        for i in 20..<220 { counts[3 * bins + i] = 1 }      // luma: 200 bins of 1
        for i in 100..<120 { counts[2 * bins + i] = 10 }    // blue: 20 bins of 10
        let h = Histogram(bins: bins, counts: counts, sampleCount: 200,
                          transform: ReadoutTransform(space: .srgb255, working: .rec2020),
                          clippedLowCounts: [0, 0, 0, 0],
                          clippedHighCounts: [0, 0, 0, 0])
        XCTAssertEqual(h.normalized(.luma)[50], 1.0, accuracy: 1e-12)
    }
}
