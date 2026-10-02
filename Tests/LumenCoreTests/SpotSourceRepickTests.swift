// SpotSourceRepickTests.swift
// `/` re-picks the selected spot's source (docs/09 §Heal / Clone, LR's binding): the
// next-best DISTINCT candidate, cycling back to the best. The first candidate must be the
// auto source itself, or the first press would appear to do nothing — or worse, the cycle
// would never visit the answer the click originally gave.

import XCTest
@testable import LumenCore

final class SpotSourceRepickTests: XCTestCase {

    private func texture(_ width: Int, _ height: Int) -> ImageBuffer {
        var image = ImageBuffer(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let v = 0.25 + 0.06 * sin(Double(x) * 0.61) * cos(Double(y) * 0.37)
                    + 0.03 * spotNoise(x, y)
                image[x, y] = RGB(v, v * 0.92 + 0.01 * spotNoise(x, y, 3), v * 0.8)
            }
        }
        return image
    }

    /// The ranking's head IS `bestSource`, bit for bit, for both modes and several spots.
    func testTheFirstCandidateIsTheAutoSource() {
        let image = texture(160, 120)
        for (cx, cy) in [(80.0, 60.0), (30.0, 25.0), (130.0, 95.0)] {
            for mode in HealMode.allCases {
                let ranked = SpotSourceSearch.rankedSources(in: image, centerX: cx,
                                                            centerY: cy, radius: 6,
                                                            mode: mode)
                guard let best = SpotSourceSearch.bestSource(in: image, centerX: cx,
                                                             centerY: cy, radius: 6,
                                                             mode: mode),
                      let first = ranked.first else {
                    return XCTFail("no source at (\(cx), \(cy)) for \(mode)")
                }
                XCTAssertEqual(first.x, best.x)
                XCTAssertEqual(first.y, best.y)
            }
        }
    }

    /// Every alternative is a real choice: at least one radius from every other, never
    /// overlapping the blemish, inside the frame — and there are several of them.
    func testTheAlternativesAreDistinctAndLegal() {
        let image = texture(160, 120)
        let radius = 6.0, cx = 80.0, cy = 60.0
        let ranked = SpotSourceSearch.rankedSources(in: image, centerX: cx, centerY: cy,
                                                    radius: radius, mode: .heal)
        XCTAssertEqual(ranked.count, SpotSourceSearch.alternativeCount)
        for (i, a) in ranked.enumerated() {
            XCTAssertGreaterThanOrEqual(hypot(a.x - cx, a.y - cy), 2 * radius - 1e-9)
            XCTAssertGreaterThanOrEqual(a.x - radius, 0)
            XCTAssertLessThanOrEqual(a.x + radius, 160)
            XCTAssertGreaterThanOrEqual(a.y - radius, 0)
            XCTAssertLessThanOrEqual(a.y + radius, 120)
            for b in ranked[(i + 1)...] {
                XCTAssertGreaterThanOrEqual(hypot(a.x - b.x, a.y - b.y), radius,
                                            "two alternatives are the same choice")
            }
        }
    }

    /// A ramp along x: every candidate straight above or below matches perfectly, so the
    /// raw ranking is a column of near-identical sources half a radius apart. The
    /// alternatives must still be one radius apart — a `/` that moves the source half a
    /// radius along the same column is a key that looks like it did nothing.
    func testAlternativesStayDistinctWhereTheRankingStacksThem() {
        var image = ImageBuffer(width: 160, height: 160)
        for y in 0..<160 {
            for x in 0..<160 { image[x, y] = RGB(gray: 0.1 + 0.004 * Double(x)) }
        }
        let radius = 6.0
        let ranked = SpotSourceSearch.rankedSources(in: image, centerX: 80, centerY: 80,
                                                    radius: radius, mode: .clone)
        XCTAssertGreaterThan(ranked.count, 1)
        for (i, a) in ranked.enumerated() {
            for b in ranked[(i + 1)...] {
                XCTAssertGreaterThanOrEqual(hypot(a.x - b.x, a.y - b.y), radius,
                                            "\(a) and \(b) are the same choice")
            }
        }
    }

    /// Pressing `/` walks every alternative once and comes back to the first; a source
    /// dragged off every candidate goes to the best.
    func testRepickCyclesThroughEveryAlternative() {
        let width = 400, height = 300
        let frame = texture(width, height)
        var spot = HealSpot(x: 0.5, y: 0.5, sourceX: 0.5, sourceY: 0.5,
                            radius: 6.0 / 400.0)
        let candidates = SpotSourceSearch.rankedSources(
            for: spot, in: frame,
            window: .init(x: 0, y: 0, width: width, height: height, scale: 1),
            sourceWidth: width, sourceHeight: height)
        XCTAssertGreaterThan(candidates.count, 2)
        guard let auto = SpotSourceSearch.autoSource(for: spot, in: frame) else {
            return XCTFail("no auto source")
        }
        spot.sourceX = auto.x
        spot.sourceY = auto.y

        var visited: [Int] = []
        for _ in 0..<candidates.count {
            guard let next = SpotSourceSearch.nextSource(for: spot, candidates: candidates,
                                                         sourceWidth: width,
                                                         sourceHeight: height),
                  let index = candidates.firstIndex(where: { $0 == next }) else {
                return XCTFail("re-pick left the candidate list")
            }
            visited.append(index)
            spot.sourceX = next.x
            spot.sourceY = next.y
        }
        XCTAssertEqual(visited, Array(1..<candidates.count) + [0],
                       "the cycle skipped, repeated or stuck on an alternative")

        // Dragged by hand to somewhere no candidate is: re-pick means "the best".
        spot.sourceX = 0.1
        spot.sourceY = 0.9
        let fresh = SpotSourceSearch.nextSource(for: spot, candidates: candidates,
                                                sourceWidth: width, sourceHeight: height)
        XCTAssertEqual(fresh?.x, candidates[0].x)
        XCTAssertEqual(fresh?.y, candidates[0].y)
        XCTAssertNil(SpotSourceSearch.nextSource(for: spot, candidates: [],
                                                 sourceWidth: width, sourceHeight: height))
    }
}
