// GrainPlateTests.swift
// The plate — the one object the CPU reference and the GPU graph each build for
// themselves, and therefore the one most likely to be built two different ways.
//
// That is not a hypothetical risk in this file's neighbourhood; it is the recorded
// history of it. `FilmGrainProfile.defaultPlateSeed` exists because the GPU plate used
// 0x5DEECE66D while the reference defaulted to a different constant, so one recipe made
// two different grains and no golden could ever compare them.
// `FilmGrainProfile.plateEncodeScale` exists because the store packed with 0.25 and the
// kernel recovered with ×2, so the GPU laid down half the amplitude the reference
// defines — in every preview and every export — and clamped away the strongest 3.4% of
// the grains on the way.
//
// There are now TWO CIImage plate builders: `PipelineRenderer.grainPlate`, which the
// film path has always used, and `RenderGraph.creativeGrainPlate`, which the creative
// grain needs because the file the first one lives in was not this change's to edit.
// Neither can be run on this lane. What CAN be run, and what this file does, is pin
// every input the two share — the noise itself, the seeds, the packing arithmetic and
// the cell size — so that if the two ever disagree it is about CoreImage plumbing and
// not about what the grain is. When somebody merges them, these assertions are the
// statement of what must not change in the merge.

import XCTest
@testable import LumenCore

final class GrainPlateTests: XCTestCase {

    /// `GrainPlan.plate` is exactly the call `PipelineRenderer.grainPlate` makes by
    /// hand for a film stock: same generator, same size, same per-channel seed, unit
    /// sigma, and — since a stock's profile carries the default persistence — the same
    /// octave weights.
    ///
    /// This is the assertion that makes the two builders' noise identical by
    /// construction rather than by inspection.
    func testTheFilmPlateIsTheSameNoiseTheHandRolledCallProduces() {
        let chain = FilmChain(FilmChain.defaultRecipe(for: .portra400),
                              displayWhite: 1.0)
        let plan = GrainPlan.film(chain)
        for channel in 0..<3 {
            let viaPlan = plan.plate(channel: channel)
            // The literal expression the GPU builder writes out.
            let handRolled = FilmGrainProfile.plate(
                size: 128,
                seed: chain.grain.plateSeed(channel: channel),
                sigma: 1)
            XCTAssertEqual(viaPlan, handRolled,
                           "channel \(channel)'s plate differs between the plan and the "
                               + "hand-rolled call the GPU builder makes — one recipe, "
                               + "two grains")
        }
        XCTAssertEqual(GrainPlan.plateSize, 128,
                       "128 is the plate edge both builders have always used; a plate of "
                           + "a different size is a different grain")
    }

    /// A creative plate is NOT the same noise as a film plate at the same seed unless
    /// its Roughness is 50 — which is the whole point of the persistence parameter, and
    /// the check that it is actually reaching the generator.
    func testRoughnessReachesThePlateThePlatesAreBuiltFrom() {
        let neutral = GrainPlan.creative(CreativeGrain(amount: 50, roughness: 50),
                                         monochrome: false)
        let rough = GrainPlan.creative(CreativeGrain(amount: 50, roughness: 95),
                                       monochrome: false)
        XCTAssertEqual(neutral.plate(channel: 1),
                       FilmGrainProfile.plate(size: 128,
                                              seed: neutral.profile.plateSeed(channel: 1),
                                              sigma: 1),
                       "Roughness 50 must be the plate every stock gets")
        XCTAssertNotEqual(neutral.plate(channel: 1), rough.plate(channel: 1),
                          "Roughness is not reaching the generator")
    }

    /// The packing arithmetic, both directions, on the real plate rather than on a
    /// hand-made array.
    ///
    /// The GPU stores `plate / plateEncodeScale + 0.5` into an RGBAf texture and
    /// `lumenGrain` recovers `(stored − 0.5) × plateEncodeScale`. Both builders write
    /// that first half out longhand; this pins that the pair is exact and that the
    /// stored values stay inside 0…1 without a clamp — 8 is chosen so a 4σ plate fits,
    /// and the clamp that used to be there flattened precisely the strongest grains.
    func testThePackingRoundTripsAndNeedsNoClamp() {
        let plan = GrainPlan.creative(CreativeGrain(amount: 100, size: 50, roughness: 50),
                                      monochrome: false)
        var worstError = 0.0
        var lowest = Double.infinity
        var highest = -Double.infinity
        var beyondTwoSigma = 0
        let values = plan.plate(channel: 1)
        for v in values {
            let stored = Double(v) / FilmGrainProfile.plateEncodeScale + 0.5
            lowest = Swift.min(lowest, stored)
            highest = Swift.max(highest, stored)
            let recovered = (stored - 0.5) * FilmGrainProfile.plateEncodeScale
            worstError = Swift.max(worstError, abs(recovered - Double(v)))
            if abs(Double(v)) > 2 { beyondTwoSigma += 1 }
        }
        XCTAssertLessThan(worstError, 1e-9,
                          "the store/recover pair is not exact — the GPU is laying down "
                              + "a different amplitude from the reference")
        XCTAssertGreaterThan(lowest, 0,
                             "the packed plate went below 0 at \(lowest); a texture "
                                 + "clamp would flatten it")
        XCTAssertLessThan(highest, 1,
                          "the packed plate went above 1 at \(highest); a texture clamp "
                              + "would flatten it")
        XCTAssertGreaterThan(beyondTwoSigma, 0,
                             "this plate has no grains beyond 2σ, so it cannot show "
                                 + "whether the headroom is needed")
    }

    /// The plate is exactly unit variance and zero mean, at every roughness, because it
    /// is rescaled by measurement rather than by trusting the octave arithmetic — which
    /// is what lets Roughness change the character without touching the Amount.
    func testThePlateIsUnitVarianceAtEveryRoughness() {
        for roughness in stride(from: 0.0, through: 100.0, by: 20.0) {
            let plate = FilmGrainProfile.plate(
                size: 128, seed: 7, sigma: 1,
                persistence: FilmGrainProfile.creativePersistence(roughness: roughness))
            let values = plate.map(Double.init)
            let mean = values.reduce(0, +) / Double(values.count)
            let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +)
                / Double(values.count)
            XCTAssertEqual(mean, 0, accuracy: 1e-6, "mean at roughness \(roughness)")
            XCTAssertEqual(variance.squareRoot(), 1, accuracy: 1e-6,
                           "sigma at roughness \(roughness)")
        }
    }

    /// A hand-edited persistence outside the control's own bounds is clamped rather
    /// than trusted: 0 would leave a single octave standing and a negative one would
    /// alternate the sign of every other octave. Neither is a grain, and a sidecar can
    /// say either.
    func testAnAbsurdPersistenceIsClampedRatherThanTrusted() {
        let sane = FilmGrainProfile.plate(size: 32, seed: 3, sigma: 1, persistence: 0.05)
        let absurd = FilmGrainProfile.plate(size: 32, seed: 3, sigma: 1,
                                            persistence: -12)
        XCTAssertEqual(sane, absurd, "a persistence below the floor must clamp to it")
        let ceiling = FilmGrainProfile.plate(size: 32, seed: 3, sigma: 1,
                                             persistence: 0.95)
        let past = FilmGrainProfile.plate(size: 32, seed: 3, sigma: 1, persistence: 40)
        XCTAssertEqual(ceiling, past, "a persistence above the ceiling must clamp to it")
        let nonFinite = FilmGrainProfile.plate(size: 32, seed: 3, sigma: 1,
                                               persistence: .nan)
        XCTAssertEqual(nonFinite,
                       FilmGrainProfile.plate(size: 32, seed: 3, sigma: 1),
                       "a non-finite persistence must fall back to the default plate, "
                           + "not produce a frame of NaN")
    }

    /// The cell size the two builders scale their tiles by is one function, and it is
    /// the profile's — not a number either of them derives. Per channel, because the
    /// blue record is coarsest and a builder that forgot the channel argument would
    /// produce a plate with no chromatic structure at all, which is the exact defect
    /// `plateScale(…, channel:)` was written for and then went uncalled.
    func testTheCellSizeIsPerChannelAndComesFromTheProfile() {
        let plan = GrainPlan.creative(CreativeGrain(amount: 60, size: 80),
                                      monochrome: false)
        let r = plan.plateScale(longEdgePixels: 6000, channel: 0)
        let g = plan.plateScale(longEdgePixels: 6000, channel: 1)
        let b = plan.plateScale(longEdgePixels: 6000, channel: 2)
        XCTAssertEqual(r / g, 0.8, accuracy: 1e-9)
        XCTAssertEqual(b / g, 2.0, accuracy: 1e-9)
        XCTAssertEqual(g, plan.profile.plateScale(
            longEdgePixels: 6000,
            printSizeInches: plan.printLongEdgeInches, channel: 1), accuracy: 1e-12,
                       "the plan's cell size must be the profile's, not a second "
                           + "derivation of it")

        // A monochrome plan has no dye layers, so its three "records" share one size —
        // and share one seed, which is what keeps a black-and-white photograph from
        // acquiring coloured speckle.
        let mono = GrainPlan.creative(CreativeGrain(amount: 60, size: 80),
                                      monochrome: true)
        XCTAssertEqual(mono.plateScale(longEdgePixels: 6000, channel: 0),
                       mono.plateScale(longEdgePixels: 6000, channel: 2), accuracy: 1e-12)
        XCTAssertEqual(mono.plate(channel: 0), mono.plate(channel: 2))
    }

    /// The half-pixel floor, which is the reason the Size slider starts where it does:
    /// there is nothing to draw finer than half a pixel, so `plateScale` refuses. Size 0
    /// lands exactly on that floor at the interactive working resolution — 0.5 × 36000 ÷
    /// 2560 = 7.03 µm against the 7 µm minimum — so no part of the slider's travel
    /// renders one identical picture.
    func testSizeZeroSitsAtTheHalfPixelFloorRatherThanUnderIt() {
        let finest = GrainPlan.creative(CreativeGrain(amount: 50, size: 0),
                                        monochrome: true)
        let interactiveLongEdge = 2560
        let cells = finest.plateScale(longEdgePixels: interactiveLongEdge, channel: 1)
        XCTAssertEqual(cells, 0.5, accuracy: 0.01,
                       "Size 0 measures \(cells) px at the working resolution; if it "
                           + "drops well under the 0.5 floor the bottom of the slider "
                           + "renders one identical picture")
        // And one step up is genuinely coarser, at the same resolution.
        let next = GrainPlan.creative(CreativeGrain(amount: 50, size: 20),
                                      monochrome: true)
        XCTAssertGreaterThan(next.plateScale(longEdgePixels: interactiveLongEdge,
                                             channel: 1), cells)
    }
}
