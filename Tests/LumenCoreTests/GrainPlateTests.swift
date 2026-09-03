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
// There is now ONE CIImage plate builder, `RenderGraph.grainPlate`, and the history of
// how it got there is the reason this file is written the way it is. There were two —
// the film path had its own copy in `PipelineRenderer` — and the assertion below used
// to pin them together by comparing the noise each one asks for. It compared the
// UNLIMITED plates, because that is the call the hand-rolled copy made, and so it went
// on passing after the plate learned to band-limit itself to the resolution it is about
// to be sampled at (C2-01b): the reference renderer band-limited, the film path's GPU
// copy did not, and a stock's grain on screen and in the exported file went back to
// carrying the aliasing that fix had just removed. Nothing failed.
//
// The builders are one now, so they cannot drift. What this file pins instead is the
// property that made the duplicate dangerous: that a plate built for a render is NOT
// the unlimited plate, so a caller reaching past the plan for a raw one is making a
// different grain and can be seen to be.

import XCTest
@testable import LumenCore

final class GrainPlateTests: XCTestCase {

    /// A plate built for a RENDER is not the unlimited plate, and the difference is
    /// exactly what a second builder that forgot to band-limit would hand the GPU.
    ///
    /// This is the assertion the version it replaces could not make. That one compared
    /// `GrainPlan.plate()` — no scale, every octave — against the same unlimited call
    /// written out by hand, which is true of any two callers who both ask for the
    /// unlimited plate and says nothing about the one the renderer actually samples.
    func testAPlateBuiltForARenderIsNotTheUnlimitedPlate() {
        let chain = FilmChain(FilmChain.defaultRecipe(for: .portra400),
                              displayWhite: 1.0)
        let plan = GrainPlan.film(chain)

        // A 2560 px working render. Portra's cells are 0.68 / 0.85 / 1.71 px and the
        // plate's four octaves span 16 / 8 / 4 / 2 texels, so the finest octave covers
        // 1.37 / 1.71 / 3.41 render pixels — under two for the red and green records,
        // which is past Nyquist and is aliasing rather than grain, and comfortably over
        // it for the blue.
        //
        // So the answer is TWO of three, and the third is the half of the contract that
        // matters just as much: the limit removes what cannot be seen and never more.
        // (An earlier draft of this test asserted three and was wrong about the blue
        // record, which is a fair warning about how easily this arithmetic is guessed.)
        func plate(_ channel: Int, at longEdge: Int) -> [Float] {
            plan.plate(channel: channel,
                       renderPixelsPerCell: plan.plateScale(longEdgePixels: longEdge,
                                                            channel: channel))
        }
        for (name, channel) in [("red", 0), ("green", 1)] {
            XCTAssertNotEqual(plan.plate(channel: channel), plate(channel, at: 2560),
                              "the \(name) record's plate at a 2560 px render is "
                                  + "bit-identical to the unlimited one — either "
                                  + "band-limiting has stopped happening, or a caller is "
                                  + "reaching past `GrainPlan` for a raw plate, which is "
                                  + "the shape of the bug that survived C2-01b for a day")
        }
        XCTAssertEqual(plan.plate(channel: 2), plate(2, at: 2560),
                       "the blue record's finest octave is 3.4 render pixels across at "
                           + "2560 — it resolves, and dropping it would be the limit "
                           + "eating grain the screen can show")

        // And at an EXPORT size every octave resolves on every layer, so all three
        // plates are the unlimited bytes again.
        for channel in 0..<3 {
            XCTAssertEqual(plan.plate(channel: channel), plate(channel, at: 12000),
                           "channel \(channel)'s plate is being band-limited at a size "
                               + "that resolves every octave — the limit is eating grain "
                               + "the delivered file can carry")
        }

        XCTAssertEqual(GrainPlan.plateSize, 128,
                       "128 is the plate edge every builder has always used; a plate of "
                           + "a different size is a different grain")
    }

    /// AND THERE IS ONE BUILDER. Read as text, because `Sources/LumenPipeline` is
    /// `#if os(macOS)` and no test in this package can call into it — the same reason
    /// `SettleGateTests` reads the viewer's settle gate.
    ///
    /// A second builder is not a style problem. The one that existed produced identical
    /// bytes for a year and then silently stopped, because band-limiting was added to
    /// the plan and the copy did not go through the plan.
    func testThereIsOneGPUPlateBuilderAndItAsksThePlanForItsScale() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LumenPipeline")
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else {
            return XCTFail("Sources/LumenPipeline not found")
        }
        var builders: [String] = []
        var buildsRawPlates: [String] = []
        for name in names.filter({ $0.hasSuffix(".swift") }).sorted() {
            guard let text = try? String(
                contentsOf: root.appendingPathComponent(name), encoding: .utf8) else {
                continue
            }
            for (offset, line) in text.split(separator: "\n",
                                             omittingEmptySubsequences: false).enumerated() {
                let code = line.contains("//") ? line[..<line.range(of: "//")!.lowerBound]
                                               : line[...]
                if code.contains("func ") && code.contains("GrainPlate") {
                    builders.append("\(name):\(offset + 1): \(code.trimmingCharacters(in: .whitespaces))")
                }
                if code.contains("func grainPlate(") {
                    builders.append("\(name):\(offset + 1): \(code.trimmingCharacters(in: .whitespaces))")
                }
                // The raw generator, reached around the plan: the plan is what carries
                // the persistence, the seed base and — the point of this test — the
                // render scale.
                if code.contains("FilmGrainProfile.plate(") {
                    buildsRawPlates.append("\(name):\(offset + 1): \(code.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertEqual(builders.count, 1,
                       "\(builders.count) GPU plate builders in Sources/LumenPipeline — "
                           + "there is one, and a second one is how the film path kept "
                           + "an unlimited plate after C2-01b:\n"
                           + builders.joined(separator: "\n"))
        XCTAssertTrue(buildsRawPlates.isEmpty,
                      "a caller in Sources/LumenPipeline is building a plate straight "
                          + "from FilmGrainProfile instead of through GrainPlan, so it "
                          + "carries neither the profile's persistence nor the render's "
                          + "band limit:\n" + buildsRawPlates.joined(separator: "\n"))
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
        // The plan's cell size must be the PROFILE's, per channel — that is the
        // plumbing this test exists to check, and it is unchanged.
        //
        // What changed is the profile it is checked against. Creative grain is one
        // field at one crystal size now (see `CreativeGrainTests`): three independently
        // seeded layers at this control's 56 µm pitch is exactly what the owner
        // reported as "rainbow splotches". So the per-channel SPREAD is asserted on a
        // stock's profile, where a few-micron pitch keeps all three sub-pixel, and the
        // creative plan is asserted to have no spread at all.
        let plan = GrainPlan.creative(CreativeGrain(amount: 60, size: 80),
                                      monochrome: false)
        let r = plan.plateScale(longEdgePixels: 6000, channel: 0)
        let g = plan.plateScale(longEdgePixels: 6000, channel: 1)
        let b = plan.plateScale(longEdgePixels: 6000, channel: 2)
        XCTAssertEqual(r / g, 1.0, accuracy: 1e-9)
        XCTAssertEqual(b / g, 1.0, accuracy: 1e-9)
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
