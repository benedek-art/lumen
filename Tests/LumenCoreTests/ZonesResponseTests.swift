// ZonesResponseTests.swift
//
// WS-08: the Zones register's response on its own, `y(t) = t + zonePanelStops(t)`, with
// the tone sliders at default. Before this, two neighbouring zones more than 1.27 EV apart
// made a brighter tone render darker (the raised cosine's steepest slope is π/2 × the step
// over the gap), and the bake's forward clamp then rendered whole EV bands as one grey —
// Darks +3 turned −3.75 … −0.85 EV into a single code value. The register now delivers
// each request at its own pivot and spills the excess past a seam's limit into the
// untouched neighbours, holding a request back only where two touched zones conflict
// (`ToneEngine.appliedZoneEV`), so the response never runs slower than a quarter stop
// per stop and the clamp never fires on a Zones-only recipe.
// Every number here is a line of docs/quality/lanes/WS-08/SPEC.md.

import XCTest
@testable import LumenCore

final class ZonesResponseTests: XCTestCase {

    private static let span = ToneEngine.defaultWhiteAnchorEV - ToneEngine.defaultBlackAnchorEV

    /// EV of a pivot on the register's axis.
    private static func ev(ofPivot p: Double) -> Double {
        ToneEngine.defaultBlackAnchorEV + p * span
    }

    private static func pivot(atEV ev: Double) -> Double {
        (ev - ToneEngine.defaultBlackAnchorEV) / span
    }

    private static func zones(_ ev: [Double], global: Double = 0,
                              pivots: [Double] = Zones.defaultPivots) -> Zones {
        var z = Zones(pivots: pivots)
        z.dark.ev = ev[0]
        z.shadow.ev = ev[1]
        z.mid.ev = ev[2]
        z.light.ev = ev[3]
        z.bright.ev = ev[4]
        z.global.ev = global
        return z
    }

    private static func engine(_ ev: [Double], global: Double = 0,
                               pivots: [Double] = Zones.defaultPivots) -> ToneEngine {
        ToneEngine(tone: Tone(), zones: zones(ev, global: global, pivots: pivots))
    }

    private static func y(_ e: ToneEngine, _ t: Double) -> Double { t + e.zonePanelStops(t) }

    /// Every combination of `values` over the five zones.
    private static func combinations(_ values: [Double]) -> [[Double]] {
        var out: [[Double]] = [[]]
        for _ in 0..<5 {
            out = out.flatMap { prefix in values.map { prefix + [$0] } }
        }
        return out
    }

    /// G5: {−3, −1.5, 0, 1.5, 3}^5 at the default pivots, global 0 and 3.
    private static let g5: [(ev: [Double], global: Double)] = {
        let evs = combinations([-3, -1.5, 0, 1.5, 3])
        return [0.0, 3].flatMap { g in evs.map { (ev: $0, global: g) } }
    }()

    /// The pivot sets G3 runs on: four with one adjacent pair exactly a stop apart, the
    /// five pivots packed a stop apart at the bottom of the axis, 50 seeded random sets
    /// with every gap at least a stop, and one legacy list with a 0.28 EV gap (Z4.2:
    /// the ease reads each list's actual gaps).
    private static let g3Pivots: [[Double]] = {
        var sets: [[Double]] = []
        let defaults = Zones.defaultPivots
        for i in 0..<4 {
            var p = defaults
            p[i + 1] = p[i] + Zones.minimumPivotGap
            sets.append(p)
        }
        sets.append((0..<5).map { Double($0) / 14 })
        var rng = SplitMix(seed: 0x5EED_0808)
        while sets.count < 4 + 1 + 50 {
            // Five gaps of at least a stop inside the 14 EV axis: 4 stops of minimum gap,
            // the other ten shared out at random.
            var parts = (0..<6).map { _ in rng.unit() }
            let total = parts.reduce(0, +)
            parts = parts.map { $0 / total * 10 }
            var p: [Double] = []
            var at = parts[0]
            for k in 0..<5 {
                p.append(at / 14)
                if k < 4 { at += 1 + parts[k + 1] }
            }
            sets.append(p)
        }
        sets.append([defaults[0], 0.5, 0.52, defaults[3], defaults[4]])
        return sets
    }()

    private static let g3Values = combinations([-3, 0, 3])

    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }

    /// Every engine G5 and G3 describe.
    private static func allEngines() -> [(label: String, engine: ToneEngine, pivots: [Double])] {
        var out: [(label: String, engine: ToneEngine, pivots: [Double])] = []
        for c in g5 {
            out.append((label: "\(c.ev) global \(c.global)",
                        engine: engine(c.ev, global: c.global), pivots: Zones.defaultPivots))
        }
        for p in g3Pivots {
            for v in g3Values {
                out.append((label: "\(v) pivots \(p)", engine: engine(v, pivots: p), pivots: p))
            }
        }
        return out
    }

    // MARK: - Z1

    /// Z1.1. Slope ≥ 0.25 everywhere on −12 … +8 EV, at 0.01 EV.
    func testMonotoneWithATextureFloor() {
        var worst = Double.infinity
        var worstAt = ""
        for (label, e, _) in Self.allEngines() {
            var previous = Self.y(e, -12)
            for step in 1...2000 {
                let t = -12 + Double(step) * 0.01
                let current = Self.y(e, t)
                let slope = (current - previous) / 0.01
                if slope < worst { worst = slope; worstAt = "\(label) at \(t) EV" }
                previous = current
            }
        }
        print("ZonesResponse Z1.1: slowest slope \(worst) (\(worstAt))")
        XCTAssertGreaterThanOrEqual(worst, 0.25 - 1e-9,
                                    "the zone response runs at \(worst) stops per stop: \(worstAt)")
    }

    /// Z1.2. No C0 join anywhere: one-sided slopes agree at every 0.05 EV sample and at
    /// every pivot.
    func testNoSlopeBreakAnywhere() {
        let delta = 1e-5
        var worst = 0.0
        var worstAt = ""
        for (label, e, pivots) in Self.allEngines() {
            var ts = (0...400).map { -12 + Double($0) * 0.05 }
            ts += pivots.map { Self.ev(ofPivot: $0) }
            for t in ts {
                let y0 = Self.y(e, t)
                let right = (Self.y(e, t + delta) - y0) / delta
                let left = (y0 - Self.y(e, t - delta)) / delta
                let jump = abs(right - left)
                if jump > worst { worst = jump; worstAt = "\(label) at \(t) EV" }
            }
        }
        print("ZonesResponse Z1.2: largest slope break \(worst) (\(worstAt))")
        XCTAssertLessThanOrEqual(worst, 0.01, "slope breaks by \(worst): \(worstAt)")
    }

    /// Z1.3. Between two pivots the register never leaves its two zones' applied values;
    /// below the first and above the last it is flat.
    func testNoOvershootAndPeaksAtThePivot() {
        for (label, e, pivots) in Self.allEngines() {
            let a = e.appliedZoneEV
            let g = e.zones.global.ev
            let T = pivots.map { Self.ev(ofPivot: $0) }
            for step in 0...2000 {
                let t = -12 + Double(step) * 0.01
                let z = e.zonePanelStops(t)
                if t <= T[0] {
                    XCTAssertEqual(z, a[0] + g, accuracy: 1e-9, "\(label) below T0 at \(t)")
                } else if t >= T[4] {
                    XCTAssertEqual(z, a[4] + g, accuracy: 1e-9, "\(label) above T4 at \(t)")
                } else {
                    let i = (0..<4).first { t >= T[$0] && t <= T[$0 + 1] } ?? 0
                    let lo = Swift.min(a[i], a[i + 1]) + g - 1e-9
                    let hi = Swift.max(a[i], a[i + 1]) + g + 1e-9
                    XCTAssertTrue(z >= lo && z <= hi,
                                  "\(label): \(z) at \(t) EV is outside zones \(i), \(i + 1)")
                }
            }
        }
    }

    private static let singleZoneCases: [(zone: Int, ev: Double)] = (0..<5).flatMap { z in
        (-15...15).map { (z, Double($0) * 0.05) }
    }

    /// Z1.4. A single zone inside its seams' limit (±0.955 EV at the default gaps; these
    /// cases stop at ±0.75) is applied exactly, peaks at its own pivot and is zero at the
    /// others — nothing spills.
    func testSmallMovesAreExact() {
        for (zone, v) in Self.singleZoneCases {
            var ev = [Double](repeating: 0, count: 5)
            ev[zone] = v
            let e = Self.engine(ev)
            XCTAssertEqual(e.appliedZoneEV, ev, "zone \(zone) at \(v) was eased")
            for (k, p) in Zones.defaultPivots.enumerated() {
                XCTAssertEqual(e.zonePanelStops(Self.ev(ofPivot: p)), k == zone ? v : 0,
                               accuracy: 1e-9, "zone \(zone) at \(v), pivot \(k)")
            }
        }
    }

    /// Z1.5. A photographer's existing small zone edits do not visibly move.
    func testSmallMovesMatchTodaysResponse() {
        let oldAxis = ToneEngine()
        for (zone, v) in Self.singleZoneCases where abs(v) <= 0.5 + 1e-12 {
            var ev = [Double](repeating: 0, count: 5)
            ev[zone] = v
            let e = Self.engine(ev)
            var worst = 0.0
            for step in 0...2000 {
                let t = -12 + Double(step) * 0.01
                let old = ZoneWeights.exposureStops(x: oldAxis.normalizedAxis(t),
                                                    pivots: Zones.defaultPivots,
                                                    zoneEV: ev, globalEV: 0)
                worst = Swift.max(worst, abs(e.zonePanelStops(t) - old))
            }
            XCTAssertLessThanOrEqual(worst, 0.02, "zone \(zone) at \(v) moved by \(worst) EV")
        }
    }

    /// Z1.6 (amended, round 2). No dead range: a lone zone is delivered in full at its own
    /// pivot across the whole slider, so every quarter stop of travel moves it by a
    /// quarter stop, and its excess past a seam's limit spills into the untouched
    /// neighbours instead of being thrown away.
    func testTheEaseNeverGoesDead() {
        for zone in 0..<5 {
            let T = Self.ev(ofPivot: Zones.defaultPivots[zone])
            func at(_ v: Double) -> (y: Double, a: Double) {
                var ev = [Double](repeating: 0, count: 5)
                ev[zone] = v
                let e = Self.engine(ev)
                return (Self.y(e, T), e.appliedZoneEV[zone])
            }
            for k in 0...23 {
                let v = -3 + Double(k) * 0.25
                let here = at(v), next = at(v + 0.25)
                let gain = (next.y - here.y) / 0.25
                XCTAssertGreaterThanOrEqual(gain, 0.99,
                                            "zone \(zone): \(v) → \(v + 0.25) moved its pivot "
                                                + "\(gain) EV per EV of slider")
                XCTAssertEqual(here.a, v, accuracy: 1e-12, "zone \(zone) at \(v) was not delivered")
            }
        }
    }

    /// Z1.6b. What the spill does, at the default pivots: Darks +3 is delivered as +3.00
    /// and its neighbours carry the excess past each seam's 0.955 EV limit; Brights −3
    /// is the mirror.
    func testALoneZoneSpillsItsExcessIntoItsNeighbours() {
        let limit = 2 * 2 * (1 - ToneEngine.zoneSlopeFloor) / Double.pi
        let darks = Self.engine([3, 0, 0, 0, 0])
        let expected = [3, 3 - limit, 3 - 2 * limit, 3 - 3 * limit, 0]
        for (k, p) in Zones.defaultPivots.enumerated() {
            XCTAssertEqual(darks.zonePanelStops(Self.ev(ofPivot: p)), expected[k],
                           accuracy: 0.01, "Darks +3 at pivot \(k)")
        }
        XCTAssertEqual(darks.appliedZoneEV[1], 2.045, accuracy: 0.001)
        XCTAssertEqual(darks.appliedZoneEV[2], 1.090, accuracy: 0.001)
        XCTAssertEqual(darks.appliedZoneEV[3], 0.135, accuracy: 0.001)
        let brights = Self.engine([0, 0, 0, 0, -3])
        for (k, p) in Zones.defaultPivots.enumerated() {
            XCTAssertEqual(brights.zonePanelStops(Self.ev(ofPivot: p)), -expected[4 - k],
                           accuracy: 0.01, "Brights −3 at pivot \(k)")
        }
    }

    /// Z1.7 (amended, round 2). What the register does is reported, zone by zone, in the
    /// row that moved: a carried row names the zone it carries for, a held-back row the
    /// zone it conflicts with, and nothing else gets a line.
    func testTheEaseIsReported() throws {
        for (zone, v) in Self.singleZoneCases {
            var ev = [Double](repeating: 0, count: 5)
            ev[zone] = v
            XCTAssertEqual(AppliedReadout.zoneEasing(tone: Tone(), zones: Self.zones(ev)), [],
                           "zone \(zone) at \(v) is reported as eased")
        }
        let darks = AppliedReadout.zoneEasing(tone: Tone(), zones: Self.zones([3, 0, 0, 0, 0]))
        XCTAssertEqual(darks.map(\.name), ["Shadows", "Midtones", "Lights"])
        XCTAssertTrue(darks.allSatisfy { $0.carriedFrom == "Darks" && $0.conflictsWith == nil })
        XCTAssertEqual(darks.first?.caption, "+2.05 EV carried from Darks")

        let conflict = AppliedReadout.zoneEasing(tone: Tone(),
                                                 zones: Self.zones([3, 0, -3, 0, 0]))
        let held = try XCTUnwrap(conflict.first { $0.name == "Darks" })
        XCTAssertEqual(held.conflictsWith, "Midtones")
        XCTAssertLessThan(held.applied, 3)
        XCTAssertGreaterThan(held.applied, 0)
        XCTAssertEqual(held.caption, "Applied \(AppliedReadout.ev(held.applied)) of +3.00 EV "
                                     + "(conflicts with Midtones)")
        let mids = try XCTUnwrap(conflict.first { $0.name == "Midtones" })
        XCTAssertEqual(mids.conflictsWith, "Darks")
        XCTAssertGreaterThan(mids.applied, -3)
    }

    /// Z1.8. A zone separated from the conflict by an untouched zone is never scaled, and
    /// a lone zone is never scaled at all.
    func testEasingIsLocal() {
        // A touched pair the spill can reconcile (drop 2.5 over a 2.865 EV span) is
        // delivered exactly, both ends (amended, round 2b).
        let a = Self.engine([3, 0, 0, 0.5, 0]).appliedZoneEV
        XCTAssertEqual(a[3], 0.5, accuracy: 1e-9)
        XCTAssertEqual(a[0], 3, accuracy: 1e-12)
        XCTAssertEqual(AppliedReadout.zoneEasing(tone: Tone(), zones: Self.zones([3, 0, 0, 0.5, 0]))
                           .filter { $0.conflictsWith != nil }, [])
        let b = Self.engine([0, 0, -3, 0, 1]).appliedZoneEV
        XCTAssertEqual(b[4], 1, accuracy: 1e-9)
        XCTAssertEqual(b[2], -3, accuracy: 1e-12)
    }

    /// Round 2b. Crossing from a span the spill can reconcile into one it cannot, the
    /// applied value is continuous and never falls as the slider rises: exact up to the
    /// span's capacity, held at it after. Same-sign (Darks against Lights +0.5, capacity
    /// 2.865 EV) and opposite-sign (Darks against Midtones −1, capacity 1.910 EV).
    func testTheConflictCapIsContinuousAndMonotone() {
        let limit = 2 * 2 * (1 - ToneEngine.zoneSlopeFloor) / Double.pi
        for (other, value, capacity) in [(3, 0.5, 3 * limit), (2, -1.0, 2 * limit)] {
            var previous: [Double]? = nil
            for k in 0...300 {
                let v = Double(k) * 0.01
                var ev = [Double](repeating: 0, count: 5)
                ev[0] = v
                ev[other] = value
                let a = Self.engine(ev).appliedZoneEV
                if v - value <= capacity - 1e-12 {
                    XCTAssertEqual(a[0], v, accuracy: 1e-12, "Darks \(v) against \(value) is feasible")
                } else {
                    XCTAssertEqual(a[0] - a[other], capacity, accuracy: 1e-9,
                                   "Darks \(v) against \(value): the span is not at its capacity")
                }
                if let previous {
                    XCTAssertGreaterThanOrEqual(a[0], previous[0] - 1e-12, "Darks fell at \(v)")
                    XCTAssertLessThanOrEqual(abs(a[0] - previous[0]), 0.01 + 1e-12,
                                             "Darks jumped at \(v)")
                    XCTAssertLessThanOrEqual(abs(a[other] - previous[other]), 0.01 + 1e-12,
                                             "zone \(other) jumped at \(v)")
                }
                previous = a
            }
        }
    }

    /// Z1.13 (round 3). Spill is a bound, not a target: with one zone at ±3, sweeping any
    /// other zone from −3 to +3 in 0.01 EV steps moves no pivot by more than the step,
    /// never moves a pivot the wrong way, and keeps the floor and C¹ everywhere. Round 2
    /// failed this by 2 EV in one step: Darks +3 with Shadows nudged 0 → +0.05 dropped
    /// Shadows from +2.045 to +0.05 and Darks from 3 to 1.005.
    func testEverySliderMovesEveryPivotContinuouslyAndMonotonically() {
        // The verifier's case, by name.
        let nudged = Self.engine([3, 0.05, 0, 0, 0]).appliedZoneEV
        XCTAssertEqual(nudged[0], 3, accuracy: 1e-12)
        XCTAssertEqual(nudged[1], 3 - 2 * 2 * (1 - ToneEngine.zoneSlopeFloor) / Double.pi,
                       accuracy: 1e-12)

        var worstStep = 0.0, worstFall = 0.0, worstSlope = Double.infinity, worstBreak = 0.0
        let T = Zones.defaultPivots.map { Self.ev(ofPivot: $0) }
        for fixed in 0..<5 {
            for sign in [-3.0, 3.0] {
                for swept in 0..<5 where swept != fixed {
                    var previous: [Double]? = nil
                    for k in 0...600 {
                        var ev = [Double](repeating: 0, count: 5)
                        ev[fixed] = sign
                        ev[swept] = -3 + Double(k) * 0.01
                        let e = Self.engine(ev)
                        let atPivots = T.map { e.zonePanelStops($0) }
                        if let previous {
                            for p in 0..<5 {
                                worstStep = Swift.max(worstStep, abs(atPivots[p] - previous[p]))
                                worstFall = Swift.max(worstFall, previous[p] - atPivots[p])
                            }
                        }
                        previous = atPivots
                        guard k % 20 == 0 else { continue }
                        // (c) floor and C¹ at sampled settings.
                        var y0 = Self.y(e, -12)
                        for step in 1...400 {
                            let t = -12 + Double(step) * 0.05
                            let y1 = Self.y(e, t)
                            worstSlope = Swift.min(worstSlope, (y1 - y0) / 0.05)
                            y0 = y1
                        }
                        for t in T {
                            let d = 1e-5, m = Self.y(e, t)
                            let jump = abs((Self.y(e, t + d) - m) / d - (m - Self.y(e, t - d)) / d)
                            worstBreak = Swift.max(worstBreak, jump)
                        }
                    }
                }
            }
        }
        print("ZonesResponse Z1.13: largest pivot step \(worstStep), largest fall \(worstFall), "
              + "slowest slope \(worstSlope), largest break \(worstBreak)")
        XCTAssertLessThanOrEqual(worstStep, 0.01 + 1e-9, "a pivot jumped by \(worstStep) EV")
        XCTAssertLessThanOrEqual(worstFall, 1e-9, "a pivot fell by \(worstFall) EV as a slider rose")
        XCTAssertGreaterThanOrEqual(worstSlope, 0.25 - 1e-9)
        XCTAssertLessThanOrEqual(worstBreak, 0.01)
    }

    /// Two touched zones that cannot both be honoured: held back, still monotone with
    /// the floor, and the untouched zone between them sits between their applied values.
    func testAConflictIsEasedAndKeepsTheFloor() {
        let e = Self.engine([3, 0, -3, 0, 0])
        let a = e.appliedZoneEV
        XCTAssertLessThan(a[0], 3)
        XCTAssertGreaterThan(a[2], -3)
        XCTAssertTrue(a[1] <= a[0] && a[1] >= a[2], "\(a)")
        var previous = Self.y(e, -12)
        for step in 1...2000 {
            let t = -12 + Double(step) * 0.01
            let current = Self.y(e, t)
            XCTAssertGreaterThanOrEqual((current - previous) / 0.01, 0.25 - 1e-9, "at \(t)")
            previous = current
        }
    }

    /// Z1.9. With the ease in place the bake's forward clamp is idle on every G5 recipe.
    func testTheClampNeverFiresOnAZonesOnlyRecipe() {
        for c in Self.g5 {
            let f = Self.engine(c.ev, global: c.global).zoneFlattening()
            XCTAssertNil(f, "\(c.ev) global \(c.global) reached the clamp: \(String(describing: f))")
        }
    }

    // MARK: - Z3

    /// Zones are fixed in stops: Whites and Blacks move the display anchors and not the
    /// zones.
    func testWhitesAndBlacksDoNotMoveTheZones() {
        var zones = Zones()
        zones.mid.ev = 1
        let plain = ToneEngine(tone: Tone(), zones: zones)
        func peak(_ e: ToneEngine) -> Double {
            var best = -Double.infinity, at = 0.0
            for step in 0...4000 {
                let t = -2 + Double(step) * 0.001
                let z = e.zonePanelStops(t)
                if z > best { best = z; at = t }
            }
            return at
        }
        let plainPeak = peak(plain)
        for tone in [Tone(whites: 100), Tone(whites: -100), Tone(blacks: 100),
                     Tone(blacks: -100)] {
            let moved = ToneEngine(tone: tone, zones: zones)
            for step in 0...2000 {
                let t = -12 + Double(step) * 0.01
                XCTAssertEqual(moved.zonePanelStops(t), plain.zonePanelStops(t),
                               accuracy: 1e-12, "\(tone) moved the zones at \(t) EV")
            }
            XCTAssertLessThan(abs(peak(moved) - plainPeak), 0.01, "\(tone) moved the Mid peak")
        }
    }

    // MARK: - Z4

    func testPivotDragKeepsAOneStopGap() {
        let gap = Zones.minimumPivotGap
        XCTAssertEqual(gap, 1.0 / 14, accuracy: 1e-15)
        let defaults = Zones.defaultPivots
        for index in 0..<5 {
            for k in -20...120 {
                let target = Double(k) / 100
                let out = Zones.movingPivot(index, to: target, in: defaults)
                for i in 1..<5 {
                    XCTAssertGreaterThanOrEqual(out[i] - out[i - 1], gap - 1e-12,
                                                "pivot \(index) to \(target): \(out)")
                }
                XCTAssertTrue(out.allSatisfy { $0 >= 0 && $0 <= 1 })
                for i in 0..<5 where i != index { XCTAssertEqual(out[i], defaults[i]) }
            }
            // Past a neighbour it stops a stop short of it.
            if index > 0 {
                XCTAssertEqual(Zones.movingPivot(index, to: 0, in: defaults)[index],
                               defaults[index - 1] + gap, accuracy: 1e-12)
            }
            if index < 4 {
                XCTAssertEqual(Zones.movingPivot(index, to: 1, in: defaults)[index],
                               defaults[index + 1] - gap, accuracy: 1e-12)
            }
        }
        // A legacy pair 0.02 apart can be pulled apart, and is never pushed together.
        let legacy = [defaults[0], 0.5, 0.52, defaults[3], defaults[4]]
        XCTAssertEqual(Zones.movingPivot(2, to: 0.6, in: legacy)[2], 0.6, accuracy: 1e-12)
        XCTAssertEqual(Zones.movingPivot(2, to: 0.51, in: legacy)[2], 0.52)
        XCTAssertEqual(Zones.movingPivot(2, to: 0.53, in: legacy)[2], 0.53, accuracy: 1e-12)
        XCTAssertEqual(Zones.movingPivot(1, to: 0.45, in: legacy)[1], 0.45, accuracy: 1e-12)
        XCTAssertEqual(Zones.movingPivot(1, to: 0.51, in: legacy)[1], 0.5)
        // Garbage in: the defaults the engine reads it as, or nothing changed.
        XCTAssertEqual(Zones.movingPivot(1, to: 0.4, in: [0.5]), defaults)
        XCTAssertEqual(Zones.movingPivot(7, to: 0.4, in: defaults), defaults)
        XCTAssertEqual(Zones.movingPivot(1, to: .nan, in: defaults), defaults)
    }

    func testDecodedRepairUsesTheOneStopGap() {
        let repaired = Zones.decodedPivots([0.3, 0.3, 0.5, 0.7, 0.9])
        XCTAssertEqual(repaired[1], 0.3 + Zones.minimumPivotGap, accuracy: 1e-12)
        XCTAssertEqual(repaired, [0.3, repaired[1], 0.5, 0.7, 0.9])
        // An ascending list, however close, is a list this app wrote and is not moved.
        let legacy = [0.3, 0.32, 0.5, 0.7, 0.9]
        XCTAssertEqual(Zones.decodedPivots(legacy), legacy)
    }

    // MARK: - Z5

    func testMovingOnlyPivotsChangesNothing() {
        for pivots in Self.g3Pivots {
            let e = ToneEngine(tone: Tone(), zones: Zones(pivots: pivots))
            XCTAssertTrue(e.isIdentity, "\(pivots)")
            for step in 0...200 {
                XCTAssertEqual(e.zonePanelStops(-12 + Double(step) * 0.1), 0)
            }
        }
    }

    // MARK: - Z7

    /// A recipe written with the removed wheel / sat / falloff keys decodes, renders the
    /// tone of the same recipe without them, and re-saves without them.
    func testLegacyZoneFieldsDecodeAndRenderIdentically() throws {
        let legacy = #"{"develop":{"zones":{"mid":{"ev":0.4,"sat":30,"wheel":[0.1,-0.2],"falloff":0.2}}}}"#
        let clean = #"{"develop":{"zones":{"mid":{"ev":0.4}}}}"#
        let old = try CanonicalJSON.decodeRecipe(from: Data(legacy.utf8))
        let new = try CanonicalJSON.decodeRecipe(from: Data(clean.utf8))
        XCTAssertEqual(old.develop.zones.mid.ev, 0.4)
        XCTAssertEqual(old, new)
        XCTAssertEqual(RenderPlan(recipe: old).toneGainLUT, RenderPlan(recipe: new).toneGainLUT)
        let saved = try CanonicalJSON.canonicalRecipeJSON(old)
        for key in ["\"sat\"", "\"wheel\"", "\"falloff\""] {
            XCTAssertFalse(saved.contains(key), "re-saved with \(key): \(saved)")
        }
        XCTAssertTrue(saved.contains("\"mid\""), saved)
    }
}
