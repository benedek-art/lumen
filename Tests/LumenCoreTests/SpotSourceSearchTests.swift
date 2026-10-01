// SpotSourceSearchTests.swift
// The auto-picked source: it must match texture, stay on the same side of an edge,
// never overlap the blemish, and be the same answer on every run and every window.

import XCTest
@testable import LumenCore

final class SpotSourceSearchTests: XCTestCase {

    /// Vertical stripes of period 10 px with a blemish. The ring match has to land the
    /// source in PHASE — a source half a period off pastes stripes between stripes — and
    /// the pattern search is what gets it there from a coarse candidate.
    func testTheSourceLandsInPhaseOnAPeriodicTexture() {
        let period = 10.0
        var image = ImageBuffer(width: 160, height: 120)
        for y in 0..<120 {
            for x in 0..<160 {
                let v = 0.2 + 0.1 * sin(2 * Double.pi * (Double(x) + 0.5) / period)
                image[x, y] = RGB(v, v * 0.9, v * 1.1)
                let dx = Double(x) + 0.5 - 80, dy = Double(y) + 0.5 - 60
                if dx * dx + dy * dy < 9 { image[x, y] = RGB(gray: 0.9) }
            }
        }
        for mode in HealMode.allCases {
            guard let best = SpotSourceSearch.bestSource(in: image, centerX: 80, centerY: 60,
                                                         radius: 7, mode: mode) else {
                return XCTFail("no source found for \(mode)")
            }
            var phase = (best.x - 80).truncatingRemainder(dividingBy: period)
            if phase > period / 2 { phase -= period }
            if phase < -period / 2 { phase += period }
            XCTAssertLessThan(abs(phase), 0.1 * period,
                              "\(mode): source \(best) is \(phase) px out of phase")
        }
    }

    /// Two incommensurate periods, one per axis: no coarse candidate lands in phase on
    /// both at once, so a source within 0.15 px of phase on both axes is the pattern
    /// search's work, not the candidate grid's luck.
    func testThePatternSearchLandsInPhaseOnBothAxes() {
        let px = 15.7, py = 13.3
        var image = ImageBuffer(width: 220, height: 200)
        for y in 0..<200 {
            for x in 0..<220 {
                let v = 0.3 + 0.08 * sin(2 * Double.pi * (Double(x) + 0.5) / px)
                    + 0.08 * sin(2 * Double.pi * (Double(y) + 0.5) / py)
                image[x, y] = RGB(v, v, v)
                let dx = Double(x) + 0.5 - 110, dy = Double(y) + 0.5 - 100
                if dx * dx + dy * dy < 9 { image[x, y] = RGB(gray: 0.9) }
            }
        }
        guard let best = SpotSourceSearch.bestSource(in: image, centerX: 110, centerY: 100,
                                                     radius: 7, mode: .clone) else {
            return XCTFail("no source")
        }
        func phase(_ d: Double, _ p: Double) -> Double {
            var r = d.truncatingRemainder(dividingBy: p)
            if r > p / 2 { r -= p }
            if r < -p / 2 { r += p }
            return abs(r)
        }
        XCTAssertLessThan(phase(best.x - 110, px), 0.15, "x out of phase: \(best)")
        XCTAssertLessThan(phase(best.y - 100, py), 0.15, "y out of phase: \(best)")
    }

    /// A source whose rim matches but whose middle holds another blemish must lose.
    ///
    /// Vertical stripes 20 px apart, spot radius 8: the only perfect ring matches within
    /// reach are straight above and below (any other in-phase offset is at least 20 px
    /// sideways), and the nearest of those — the one the distance preference would take —
    /// sits on a dark dot placed exactly there, above AND below. The dot is inside the
    /// candidate's disc and outside its ring, so the ring match cannot see it; only the
    /// interior penalty can refuse it.
    func testASourceWithABlemishInItsMiddleIsRefused() {
        var image = ImageBuffer(width: 200, height: 200)
        let radius = 8.0, cx = 100.0, cy = 100.0, period = 20.0
        let dots = [(cx, cy - 2.1 * radius), (cx, cy + 2.1 * radius)]
        for y in 0..<200 {
            for x in 0..<200 {
                let px = Double(x) + 0.5, py = Double(y) + 0.5
                let v = 0.4 + 0.05 * sin(2 * Double.pi * (px - cx) / period)
                image[x, y] = RGB(v, v, v)
                for dot in dots where hypot(px - dot.0, py - dot.1) < 0.3 * radius {
                    image[x, y] = RGB(gray: 0.02)
                }
                if hypot(px - cx, py - cy) < 3 { image[x, y] = RGB(gray: 0.9) }
            }
        }
        for mode in HealMode.allCases {
            guard let best = SpotSourceSearch.bestSource(in: image, centerX: cx, centerY: cy,
                                                         radius: radius, mode: mode) else {
                return XCTFail("no source")
            }
            for dot in dots {
                XCTAssertGreaterThan(hypot(best.x - dot.0, best.y - dot.1), radius * 1.3,
                                     "\(mode): the source \(best) borrows a dark dot")
            }
        }
    }

    /// A dark/bright boundary near the spot: the source must come from the spot's own
    /// side, with its whole disc there — a source straddling the edge pastes the edge in.
    func testTheSourceStaysOnTheSameSideOfAStrongEdge() {
        let edgeX = 100
        var image = ImageBuffer(width: 200, height: 140)
        for y in 0..<140 {
            for x in 0..<200 {
                let base = x < edgeX ? 0.02 : 0.5
                let n = 0.02 * (spotNoise(x, y) - 0.5)
                image[x, y] = RGB(base + n, base * 0.8 + n, base * 0.6 + n)
                let dx = Double(x) + 0.5 - 122, dy = Double(y) + 0.5 - 70
                if dx * dx + dy * dy < 9 { image[x, y] = RGB(gray: 0.05) }
            }
        }
        let radius = 6.0
        for mode in HealMode.allCases {
            guard let best = SpotSourceSearch.bestSource(in: image, centerX: 122, centerY: 70,
                                                         radius: radius, mode: mode) else {
                return XCTFail("no source")
            }
            XCTAssertGreaterThan(best.x - radius, Double(edgeX),
                                 "\(mode): source \(best) reaches across the edge")
        }
    }

    /// Never inside the destination, always inside the frame, and deterministic.
    func testTheSourceNeverOverlapsTheSpotAndIsDeterministic() {
        var image = ImageBuffer(width: 90, height: 70)
        for y in 0..<70 {
            for x in 0..<90 {
                image[x, y] = RGB(spotNoise(x, y), spotNoise(x, y, 7), 0.3)
            }
        }
        for (cx, cy) in [(45.0, 35.0), (12.0, 10.0), (80.0, 62.0)] {
            let radius = 5.0
            guard let a = SpotSourceSearch.bestSource(in: image, centerX: cx, centerY: cy,
                                                      radius: radius, mode: .heal),
                  let b = SpotSourceSearch.bestSource(in: image, centerX: cx, centerY: cy,
                                                      radius: radius, mode: .heal) else {
                return XCTFail("no source near (\(cx), \(cy))")
            }
            XCTAssertEqual(a.x, b.x)
            XCTAssertEqual(a.y, b.y)
            XCTAssertGreaterThanOrEqual(hypot(a.x - cx, a.y - cy), 2 * radius - 1e-9,
                                        "the source disc overlaps the blemish")
            XCTAssertGreaterThanOrEqual(a.x - radius, 0)
            XCTAssertGreaterThanOrEqual(a.y - radius, 0)
            XCTAssertLessThanOrEqual(a.x + radius, 90)
            XCTAssertLessThanOrEqual(a.y + radius, 70)
        }
    }

    /// The windowed search the app runs answers in source-normalized coordinates, and
    /// on a window cut from the frame at scale 1 it is the whole-frame answer.
    func testTheWindowedSearchMapsBackToTheWholeFrameAnswer() {
        let width = 400, height = 300
        var frame = ImageBuffer(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let v = 0.2 + 0.08 * sin(Double(x) * 0.7) * cos(Double(y) * 0.45)
                frame[x, y] = RGB(v, v + 0.02 * spotNoise(x, y), v * 0.8)
            }
        }
        let spot = HealSpot(x: 0.5, y: 0.5, sourceX: 0.5, sourceY: 0.5,
                            radius: 5.0 / 400.0)
        let window = SpotSourceSearch.window(for: spot, sourceWidth: width,
                                             sourceHeight: height)
        XCTAssertEqual(window.scale, 1)
        XCTAssertLessThan(window.width, width, "the window is the whole frame")
        var cut = ImageBuffer(width: window.width, height: window.height)
        for y in 0..<window.height {
            for x in 0..<window.width {
                cut[x, y] = frame[x + window.x, y + window.y]
            }
        }
        guard let windowed = SpotSourceSearch.autoSource(
                for: spot, in: cut, window: window, sourceWidth: width,
                sourceHeight: height),
              let whole = SpotSourceSearch.autoSource(for: spot, in: frame) else {
            return XCTFail("no source")
        }
        XCTAssertEqual(windowed.x * Double(width), whole.x * Double(width), accuracy: 0.5)
        XCTAssertEqual(windowed.y * Double(height), whole.y * Double(height), accuracy: 0.5)

        // A large spot is searched on a scaled window, not at full size.
        let large = HealSpot(x: 0.5, y: 0.5, sourceX: 0.5, sourceY: 0.5, radius: 0.1)
        let scaled = SpotSourceSearch.window(for: large, sourceWidth: 6000,
                                             sourceHeight: 4000)
        XCTAssertEqual(scaled.scale, SpotSourceSearch.workingRadius / 600, accuracy: 1e-12)
        XCTAssertLessThan(scaled.bufferWidth, 400)
    }
}
