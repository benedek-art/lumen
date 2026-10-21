// MixerBandGeometryTests.swift
// WS-31 SPEC G0 and G6: the Mixer's eight uneven bands, read straight off `ColorEngine`.
//
// G0: eight bands in wire order, centres strictly increasing round the circle, every gap
// at least 30°. G6: on a 0.01° grid the membership is a partition of unity within 1e-9,
// every weight is in 0…1, and the weights are C¹ — the second difference over δ = 0.01°
// stays under 0.1/deg² — at the default geometry AND for every corner of the arc limits
// the panel can drag the four handles to. Plus the wire contract that made per-band
// defaults possible without a migration: a stored `[22.5, 22.5]`/`[15, 15]` is the new
// per-band default, and `wireHandles` inverts `bandArcs`.

import XCTest
@testable import LumenCore

final class MixerBandGeometryTests: XCTestCase {

    // MARK: G0

    func testEightBandsInWireOrderWithGapsOfAtLeastThirtyDegrees() {
        XCTAssertEqual(ColorEngine.bandCount, 8)
        XCTAssertEqual(ColorEngine.bandHueCentres.count, 8)
        XCTAssertEqual(ColorEngine.bandNames,
                       ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"])
        // Strictly increasing round the circle: exactly one wrap, at Magenta → Red.
        var wraps = 0
        var total = 0.0
        for i in 0..<8 {
            let a = ColorEngine.bandHueCentres[i]
            let b = ColorEngine.bandHueCentres[(i + 1) % 8]
            XCTAssertTrue((0..<360).contains(a), "centre \(i) = \(a) is not a hue")
            if b <= a { wraps += 1 }
            let gap = ColorEngine.bandGapAbove(i)
            XCTAssertGreaterThanOrEqual(gap, 30, "gap \(ColorEngine.bandNames[i]) → next = \(gap)°")
            total += gap
        }
        XCTAssertEqual(wraps, 1, "centres are not in order round the circle")
        XCTAssertEqual(total, 360, accuracy: 1e-9)
    }

    func testEveryCrossoverSitsInsideItsGapAndTheDefaultCoresAreLegal() {
        for i in 0..<8 {
            let arc = ColorEngine.defaultArc(i)
            XCTAssertEqual(arc.centre, ColorEngine.bandHueCentres[i])
            for core in [arc.coreBelow, arc.coreAbove] {
                XCTAssertGreaterThanOrEqual(core, ColorEngine.bandCoreMinDegrees, "band \(i)")
                XCTAssertLessThanOrEqual(core, ColorEngine.bandCoreMaxDegrees, "band \(i)")
            }
            for feather in [arc.featherBelow, arc.featherAbove] {
                XCTAssertGreaterThanOrEqual(feather, ColorEngine.bandFeatherMinDegrees, "band \(i)")
                XCTAssertLessThanOrEqual(feather, ColorEngine.bandFeatherMaxDegrees, "band \(i)")
            }
            // Band i's upper side and band i+1's lower side span the same transition.
            let next = ColorEngine.defaultArc(i + 1)
            XCTAssertEqual(arc.featherAbove, next.featherBelow, "band \(i)")
            XCTAssertEqual(Num.wrapHue(arc.featherEnd), Num.wrapHue(next.coreStart), accuracy: 1e-9)
            XCTAssertEqual(Num.wrapHue(arc.coreEnd), Num.wrapHue(next.featherStart), accuracy: 1e-9)
            let reach = ColorEngine.bandMinReach(i)
            XCTAssertGreaterThanOrEqual(arc.coreBelow + arc.featherBelow, reach.below - 1e-9)
            XCTAssertGreaterThanOrEqual(arc.coreAbove + arc.featherAbove, reach.above - 1e-9)
        }
        XCTAssertEqual(ColorEngine.canonicalArcs, (0..<8).map { ColorEngine.defaultArc($0) },
                       "the sanitizer moved the default geometry")
    }

    // MARK: G6

    private static func check(_ arcs: [ColorEngine.BandArc], raw: Bool, label: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let delta = 0.01
        var worstSum = 0.0, worstCurvature = 0.0, worstRange = 0.0
        var previous: [Double] = ColorEngine.bandWeights(hue: -delta, arcs: arcs)
        var current: [Double] = ColorEngine.bandWeights(hue: 0, arcs: arcs)
        var rawPrevious = arcs.map { ColorEngine.rawBandWeight(hue: -delta, arc: $0) }
        var rawCurrent = arcs.map { ColorEngine.rawBandWeight(hue: 0, arc: $0) }
        for step in 1...36_001 {
            let h = Double(step) * delta
            let next = ColorEngine.bandWeights(hue: h, arcs: arcs)
            let rawNext = arcs.map { ColorEngine.rawBandWeight(hue: h, arc: $0) }
            worstSum = Swift.max(worstSum, abs(current.reduce(0, +) - 1))
            for i in 0..<8 {
                worstRange = Swift.max(worstRange, Swift.max(-current[i], current[i] - 1),
                                       Swift.max(-rawCurrent[i], rawCurrent[i] - 1))
                let d2 = abs(next[i] - 2 * current[i] + previous[i]) / (delta * delta)
                let r2 = abs(rawNext[i] - 2 * rawCurrent[i] + rawPrevious[i]) / (delta * delta)
                worstCurvature = Swift.max(worstCurvature, d2, r2)
            }
            if raw {
                worstSum = Swift.max(worstSum, abs(rawCurrent.reduce(0, +) - 1))
            }
            previous = current
            current = next
            rawPrevious = rawCurrent
            rawCurrent = rawNext
        }
        XCTAssertLessThanOrEqual(worstSum, 1e-9, "\(label): Σw off by \(worstSum)", file: file, line: line)
        XCTAssertLessThanOrEqual(worstRange, 0, "\(label): a weight left 0…1", file: file, line: line)
        XCTAssertLessThanOrEqual(worstCurvature, 0.1,
                                 "\(label): second difference \(worstCurvature)/deg² (a slope jump)",
                                 file: file, line: line)
    }

    func testTheDefaultGeometryIsASmoothPartitionOfUnityRawAndNormalised() {
        // Raw too: complementary feathers sum to exactly one before normalisation.
        Self.check(ColorEngine.canonicalArcs, raw: true, label: "default")
    }

    func testEveryArcCornerTheSanitizerCanProduceIsStillASmoothPartition() {
        // Degrees → wire units per band, so each corner is the degrees the panel's arc
        // limits allow; `bandArcs` then applies the min-reach floor exactly as it does
        // for a file.
        let cores = [ColorEngine.bandCoreMinDegrees, ColorEngine.bandCoreMaxDegrees]
        let feathers = [ColorEngine.bandFeatherMinDegrees, ColorEngine.bandFeatherMaxDegrees]
        for cb in cores {
            for ca in cores {
                for fb in feathers {
                    for fa in feathers {
                        var bands = [MixerBand](repeating: MixerBand(), count: 8)
                        for i in 0..<8 {
                            let arc = ColorEngine.BandArc(centre: ColorEngine.bandHueCentres[i],
                                                          coreBelow: cb, coreAbove: ca,
                                                          featherBelow: fb, featherAbove: fa)
                            let wire = ColorEngine.wireHandles(for: arc, band: i)
                            bands[i].core = wire.core
                            bands[i].feather = wire.feather
                        }
                        let arcs = ColorEngine.bandArcs(bands)
                        Self.check(arcs, raw: false, label: "core \(cb)/\(ca) feather \(fb)/\(fa)")
                    }
                }
            }
        }
    }

    func testOneReshapedBandBetweenDefaultNeighboursStaysSmooth() {
        // The mixed case: one band at an extreme, its neighbours at the default.
        for band in [0, 3, 5] {
            for (core, feather) in [([5.0, 5.0], [12.0, 12.0]), ([44.0, 44.0], [60.0, 60.0]),
                                    ([5.0, 44.0], [60.0, 12.0])] {
                var arcs = ColorEngine.canonicalArcs
                var bands = [MixerBand](repeating: MixerBand(), count: 8)
                let arc = ColorEngine.BandArc(centre: ColorEngine.bandHueCentres[band],
                                              coreBelow: core[0], coreAbove: core[1],
                                              featherBelow: feather[0], featherAbove: feather[1])
                let wire = ColorEngine.wireHandles(for: arc, band: band)
                bands[band].core = wire.core
                bands[band].feather = wire.feather
                arcs = ColorEngine.bandArcs(bands)
                Self.check(arcs, raw: false, label: "band \(band) \(core) \(feather)")
            }
        }
    }

    // MARK: The wire contract

    func testTheOldWireDefaultIsTheNewPerBandDefault() throws {
        // A recipe written before WS-31 that never touched a handle stores exactly this.
        let json = #"{"hue": 0, "sat": 0, "lum": -40, "core": [22.5, 22.5], "feather": [15, 15]}"#
        let band = try JSONDecoder().decode(MixerBand.self, from: Data(json.utf8))
        var bands = [MixerBand](repeating: MixerBand(), count: 8)
        bands[5] = band
        let arcs = ColorEngine.bandArcs(bands)
        XCTAssertEqual(arcs[5], ColorEngine.defaultArc(5))
        XCTAssertEqual(arcs, ColorEngine.canonicalArcs)
        // And one written before the handles existed at all.
        let bare = try JSONDecoder().decode(MixerBand.self, from: Data(#"{"hue": 10}"#.utf8))
        XCTAssertEqual(ColorEngine.bandArcs([bare])[0], ColorEngine.defaultArc(0))
    }

    func testAStoredHandleScalesWithTheBandsOwnDefault() {
        var bands = [MixerBand](repeating: MixerBand(), count: 8)
        bands[2].core = [11.25, 33.75]          // half and one and a half of the default
        let arc = ColorEngine.bandArcs(bands)[2]
        let d = ColorEngine.defaultArc(2)
        XCTAssertEqual(arc.coreBelow, Swift.max(d.coreBelow * 0.5, ColorEngine.bandCoreMinDegrees),
                       accuracy: 1e-12)
        XCTAssertEqual(arc.coreAbove, d.coreAbove * 1.5, accuracy: 1e-12)
    }

    func testWireHandlesInvertBandArcs() {
        for i in 0..<8 {
            let target = ColorEngine.BandArc(centre: ColorEngine.bandHueCentres[i],
                                             coreBelow: 9, coreAbove: 30,
                                             featherBelow: 40, featherAbove: 25)
            var bands = [MixerBand](repeating: MixerBand(), count: 8)
            let wire = ColorEngine.wireHandles(for: target, band: i)
            bands[i].core = wire.core
            bands[i].feather = wire.feather
            let back = ColorEngine.bandArcs(bands)[i]
            XCTAssertEqual(back.coreBelow, target.coreBelow, accuracy: 1e-9)
            XCTAssertEqual(back.coreAbove, target.coreAbove, accuracy: 1e-9)
            XCTAssertEqual(back.featherBelow, target.featherBelow, accuracy: 1e-9)
            XCTAssertEqual(back.featherAbove, target.featherAbove, accuracy: 1e-9)
            // The default round-trips to the exact wire default.
            let d = ColorEngine.wireHandles(for: ColorEngine.defaultArc(i), band: i)
            XCTAssertEqual(d.core, MixerBand.defaultCore)
            XCTAssertEqual(d.feather, MixerBand.defaultFeather)
        }
    }

    /// The B&W mix stays on the legacy grid: WS-31 moved only the Mixer.
    func testTheLegacyGridTheBlackAndWhiteMixUsesIsUnchanged() {
        for i in 0..<8 {
            XCTAssertEqual(ColorEngine.uniformBandHueCentres[i],
                           Num.wrapHue(29.23 + 45 * Double(i)), accuracy: 1e-12)
            XCTAssertEqual(ColorEngine.uniformArcs[i].coreBelow, 22.5)
            XCTAssertEqual(ColorEngine.uniformArcs[i].featherAbove, 15)
        }
    }
}
