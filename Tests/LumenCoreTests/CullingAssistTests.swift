// CullingAssistTests.swift
// The culling-assist arithmetic (docs/10 §10.6), pinned on Linux.
//
// The scene is a continuous function of position (soft-edged discs, a grating, bars, a
// gradient), rendered with 2 × 2 supersampling, so "the same picture at another
// resolution" really is the same picture and resolution invariance is a property of the
// scorer, not of a fixture drawn to match. Blur is a Gaussian whose sigma is a FRACTION OF
// THE LONG EDGE wherever two resolutions are compared, so one blur is one optical defocus.
//
// Most cases run the scorer's own arithmetic at a 512 px analysis edge (the parameter
// exists for exactly this) because Gaussian blurs on multi-megapixel planes are slow in a
// debug build; the production 1024 px edge is exercised by the ranking case.

import XCTest
@testable import LumenCore

final class CullingAssistTests: XCTestCase {

    // MARK: - Fixtures

    /// A 3:2 scene. `u` and `v` are 0…1 across width and height; distances are measured
    /// in long-edge units so discs stay round. Values stay inside 0.25…0.75, so added
    /// noise never clips — clipping eats noise and would flatter the noise floor.
    static func scene(_ u: Double, _ v: Double, shift: Double = 0) -> Double {
        let x = u + shift, y = v * 2 / 3
        var value = 0.40 + 0.15 * u
        let edge = 0.0015
        func step(_ d: Double) -> Double { 0.5 + 0.5 * tanh(d / edge) }
        // Discs on a grid in the centre — the "subject". Nearest disc only.
        let i = min(4, max(0, Int(((x - 0.32) / 0.09).rounded())))
        let j = min(3, max(0, Int(((y - 0.20) / 0.09).rounded())))
        let cx = 0.32 + Double(i) * 0.09, cy = 0.20 + Double(j) * 0.09
        let r = ((x - cx) * (x - cx) + (y - cy) * (y - cy)).squareRoot()
        value += 0.14 * step(0.03 - r) * ((i + j).isMultiple(of: 2) ? 1.0 : -1.0)
        // A grating patch, upper left.
        if x > 0.05 && x < 0.22 && y > 0.05 && y < 0.2 {
            value += 0.06 * sin(2 * .pi * x * 70)
        }
        // Bars along the bottom.
        if y > 0.55 && y < 0.62 {
            value += 0.1 * step(sin(2 * .pi * x * 18) * 0.01)
        }
        return value
    }

    /// Renders are pure functions of (width, shift) and the slowest part of a debug run,
    /// so each is made once per process. XCTest runs these cases serially.
    private static var renders: [String: Plane] = [:]

    static func render(width: Int, shift: Double = 0) -> Plane {
        let key = "\(width)/\(shift)"
        if let cached = renders[key] { return cached }
        let plane = renderUncached(width: width, shift: shift)
        renders[key] = plane
        return plane
    }

    private static func renderUncached(width: Int, shift: Double) -> Plane {
        let height = width * 2 / 3
        let ss = 2
        var values = [Float](repeating: 0, count: width * height)
        for py in 0..<height {
            for px in 0..<width {
                var acc = 0.0
                for sy in 0..<ss {
                    for sx in 0..<ss {
                        let u = (Double(px) + (Double(sx) + 0.5) / Double(ss)) / Double(width)
                        let v = (Double(py) + (Double(sy) + 0.5) / Double(ss)) / Double(height)
                        acc += scene(u, v, shift: shift)
                    }
                }
                values[py * width + px] = Float(acc / Double(ss * ss))
            }
        }
        return Plane(width: width, height: height, values: values)
    }

    static func blurred(_ plane: Plane, pixels sigma: Double) -> Plane {
        SpatialOps.gaussianBlur(plane, sigma: sigma)
    }

    static func blurred(_ plane: Plane, fraction: Double) -> Plane {
        blurred(plane, pixels: fraction * Double(max(plane.width, plane.height)))
    }

    /// Deterministic Gaussian noise (Box–Muller over a fixed LCG).
    static func noisy(_ plane: Plane, sigma: Double, seed: UInt64 = 0x5EED) -> Plane {
        var state = seed
        func uniform() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (Double(state >> 11) + 0.5) / Double(UInt64(1) << 53)
        }
        var out = plane
        for i in out.values.indices {
            let n = (-2 * log(uniform())).squareRoot() * cos(2 * .pi * uniform())
            out.values[i] = Float(Double(out.values[i]) + sigma * n)
        }
        return out
    }

    private func score(_ plane: Plane, edge: Int = 512) -> Double {
        SharpnessScorer.measure(plane, analysisLongEdge: edge).score
    }

    // MARK: - Sharpness: monotone under blur

    /// More defocus, lower score — strictly, at every step. Measured at the analysis
    /// scale itself so no resample sits between the blur and the measure.
    func testTheScoreFallsStrictlyAsBlurGrows() {
        let sharp = Self.render(width: 512)
        let sigmas = [0.0, 0.5, 0.8, 1.2, 1.6, 2.2, 3.0, 4.5, 6.0]
        let scores = sigmas.map { $0 == 0 ? score(sharp) : score(Self.blurred(sharp, pixels: $0)) }
        for k in 1..<scores.count {
            XCTAssertLessThan(scores[k], scores[k - 1],
                              "blur σ \(sigmas[k]) px scored \(scores[k]), not below "
                              + "σ \(sigmas[k - 1]) px's \(scores[k - 1])")
        }
        XCTAssertGreaterThan(scores[0], 3 * scores.last!,
                             "six pixels of defocus should read far softer than crisp")
    }

    // MARK: - Sharpness: the production scale

    /// The production configuration (1024 px analysis edge, default arguments): a sharp
    /// frame ranks above its blurred copy, and the soft-focus chip's default threshold
    /// (`PhotoQuery.softFocusThreshold`) sits between crisp and visibly defocused.
    func testASharpFrameRanksAboveItsBlurredCopyAndTheThresholdSitsBetween() {
        let threshold = PhotoQuery().softFocusThreshold
        let sharp = Self.render(width: 1024)
        let a = SharpnessScorer.measure(sharp)
        let slight = SharpnessScorer.measure(Self.blurred(sharp, pixels: 0.5))
        let soft = SharpnessScorer.measure(Self.blurred(sharp, pixels: 2.5))
        let defocused = SharpnessScorer.measure(Self.blurred(sharp, pixels: 4.5))
        XCTAssertEqual(a.analysedLongEdge, SharpnessScorer.analysisLongEdge)
        XCTAssertFalse(a.resolutionLimited)
        XCTAssertGreaterThan(a.score, soft.score + 0.1,
                             "sharp \(a.score) vs blurred \(soft.score)")
        XCTAssertGreaterThan(a.score, threshold)
        XCTAssertGreaterThan(slight.score, threshold, "half a pixel of blur is not soft focus")
        XCTAssertLessThan(defocused.score, threshold,
                          "4.5 px of defocus at the analysis scale is (\(defocused.score))")
    }

    // MARK: - Sharpness: resolution

    /// One scene, three preview sizes with non-integer factors to the analysis edge: the
    /// score agrees within 0.05 and the physical RMS within 15 %, sharp and blurred alike,
    /// and every sharp reading is above every blurred one.
    func testTheScoreIsInvariantToPreviewResolution() {
        let widths = [768, 1000, 1280]
        var sharpScores: [Double] = [], softScores: [Double] = []
        var sharpRMS: [Double] = [], softRMS: [Double] = []
        for width in widths {
            let plane = Self.render(width: width)
            let a = SharpnessScorer.measure(plane, analysisLongEdge: 512)
            let b = SharpnessScorer.measure(Self.blurred(plane, fraction: 0.003),
                                            analysisLongEdge: 512)
            XCTAssertEqual(a.analysedLongEdge, 512)
            sharpScores.append(a.score); sharpRMS.append(a.laplacianRMS)
            softScores.append(b.score); softRMS.append(b.laplacianRMS)
        }
        for list in [sharpScores, softScores] {
            XCTAssertLessThan(list.max()! - list.min()!, 0.05, "scores \(list)")
        }
        for list in [sharpRMS, softRMS] {
            XCTAssertLessThan(list.max()! / list.min()!, 1.15, "RMS \(list)")
        }
        XCTAssertGreaterThan(sharpScores.min()!, softScores.max()!)
    }

    /// The negative control for the test above: WITHOUT the resample to one analysis edge
    /// the same scene's score moves a lot with resolution. If this ever stops holding,
    /// the invariance test above has stopped being able to fail.
    func testWithoutTheResampleTheRawMeasureIsNotInvariant() {
        let small = SharpnessScorer.measure(Self.render(width: 768), analysisLongEdge: 768)
        let large = SharpnessScorer.measure(Self.render(width: 1280), analysisLongEdge: 1280)
        XCTAssertGreaterThan(small.laplacianRMS / large.laplacianRMS, 1.3)
    }

    func testASmallPreviewSaysItIsResolutionLimited() {
        let m = SharpnessScorer.measure(Self.render(width: 300), analysisLongEdge: 512)
        XCTAssertTrue(m.resolutionLimited)
        XCTAssertEqual(m.analysedLongEdge, 300, "never upscaled")
    }

    // MARK: - Sharpness: noise

    /// Grain is high-frequency energy. Without the floor, a defocused high-ISO frame reads
    /// as sharp as a clean one. With it, noise moves a frame's score by little, and a
    /// blurred noisy frame never overtakes the clean sharp one.
    func testNoiseDoesNotMakeABlurredFrameReadSharp() {
        let sharp = Self.render(width: 768)
        let soft = Self.blurred(sharp, fraction: 0.004)
        let clean = score(sharp), cleanSoft = score(soft)
        let noisySharp = score(Self.noisy(sharp, sigma: 0.02))
        let noisySoft = score(Self.noisy(soft, sigma: 0.02, seed: 7))
        XCTAssertLessThan(noisySoft, clean - 0.2,
                          "a defocused high-ISO frame overtook the clean sharp one")
        XCTAssertEqual(noisySoft, cleanSoft, accuracy: 0.05,
                       "grain moved a defocused frame's score")
        XCTAssertEqual(noisySharp, clean, accuracy: 0.05,
                       "grain moved a sharp frame's score")
    }

    /// The floor estimator on its own: zero on a clean plane, and on pure Gaussian noise
    /// it recovers the Laplacian's variance (20σ² for white noise) within 10 %.
    func testTheNoiseFloorMeasuresNoiseAndOnlyNoise() {
        let flat = Plane(width: 300, height: 200, fill: 0.5)
        XCTAssertEqual(SharpnessScorer.laplacianNoiseFloor(flat), 0)
        XCTAssertEqual(SharpnessScorer.laplacianNoiseFloor(Self.render(width: 512)), 0,
                       accuracy: 1e-6, "a clean scene's smooth quarter has no noise")
        let sigma = 0.02
        let floor = SharpnessScorer.laplacianNoiseFloor(Self.noisy(flat, sigma: sigma))
        XCTAssertEqual(floor / (20 * sigma * sigma), 1, accuracy: 0.1)
    }

    // MARK: - Sharpness: where the subject is

    /// Shallow depth of field on purpose: a sharp subject off-centre on a soft background
    /// must outscore the same frame with nothing in focus — by a margin, not a hair.
    func testASharpSubjectOnBokehOutscoresAFrameWithNothingInFocus() {
        let sharp = Self.render(width: 512)
        let soft = Self.blurred(sharp, pixels: 4)
        // Sharp only in a tile-sized patch, lower right of centre.
        var subject = soft
        for y in 220..<300 {
            for x in 330..<430 {
                subject.values[y * 512 + x] = sharp.values[y * 512 + x]
            }
        }
        XCTAssertGreaterThan(score(subject), score(soft) + 0.15)
    }

    /// A face region measures the face: sharp crop against blurred crop of one frame.
    func testARegionReadingMeasuresOnlyThatRegion() throws {
        let sharp = Self.render(width: 512)
        var mixed = Self.blurred(sharp, pixels: 3)
        let region = NormalizedRect(x: 0.4, y: 0.3, width: 0.2, height: 0.3)
        for y in 102..<205 {
            for x in 204..<308 { mixed.values[y * 512 + x] = sharp.values[y * 512 + x] }
        }
        let inside = try XCTUnwrap(SharpnessScorer.measure(mixed, region: region,
                                                            analysisLongEdge: 512))
        let outside = try XCTUnwrap(SharpnessScorer.measure(
            mixed, region: NormalizedRect(x: 0.05, y: 0.6, width: 0.2, height: 0.3),
            analysisLongEdge: 512))
        XCTAssertGreaterThan(inside.score, outside.score + 0.2)
        XCTAssertNil(SharpnessScorer.measure(mixed, region: NormalizedRect(
            x: 0.5, y: 0.5, width: 0.001, height: 0.001), analysisLongEdge: 512))
    }

    func testTheScoreMapIsMonotoneAndBounded() {
        var last = -1.0
        for k in 0...200 {
            let s = SharpnessScorer.score(forRMS: Double(k) * 0.0002)
            XCTAssertGreaterThanOrEqual(s, 0)
            XCTAssertLessThan(s, 1)
            XCTAssertGreaterThan(s, last)
            last = s
        }
        XCTAssertEqual(SharpnessScorer.score(forRMS: .nan), 0)
    }

    // MARK: - The plane

    func testTheAreaResampleKeepsTheMeanAndAConstant() {
        let plane = Self.render(width: 999)
        let small = plane.resampled(width: 317, height: 211)
        let mean = { (p: Plane) in p.values.reduce(0.0) { $0 + Double($1) } / Double(p.values.count) }
        XCTAssertEqual(mean(small), mean(plane), accuracy: 2e-4)
        let flat = Plane(width: 97, height: 61, fill: 0.3).resampled(width: 40, height: 25)
        XCTAssertTrue(flat.values.allSatisfy { abs($0 - 0.3) < 1e-5 })
        XCTAssertEqual(plane.fitted(longEdge: 2000).width, 999, "fitted never upscales")
    }

    func testLumaFromBytesIsRec709AndHonoursByteOrder() {
        // One pure-green pixel, as RGBA and as BGRA.
        let rgba = Plane(rgba8: [0, 255, 0, 255], width: 1, height: 1, bytesPerRow: 4)
        XCTAssertEqual(Double(rgba.values[0]), 0.7152, accuracy: 1e-4)
        let bgra = Plane(rgba8: [255, 0, 0, 255], width: 1, height: 1, bytesPerRow: 4,
                         redOffset: 2, greenOffset: 1, blueOffset: 0)
        XCTAssertEqual(Double(bgra.values[0]), 0.0722, accuracy: 1e-4)
    }

    // MARK: - Perceptual hash

    func testTheHashIsStableAcrossResolutionBlurAndExposure() {
        let base = PerceptualHash.hash(Self.render(width: 768))
        XCTAssertLessThanOrEqual(PerceptualHash.distance(base,
            PerceptualHash.hash(Self.render(width: 1100))), 4, "resolution")
        XCTAssertLessThanOrEqual(PerceptualHash.distance(base,
            PerceptualHash.hash(Self.blurred(Self.render(width: 768), pixels: 3))), 6, "blur")
        var brighter = Self.render(width: 768)
        for i in brighter.values.indices { brighter.values[i] += 0.05 }
        XCTAssertLessThanOrEqual(PerceptualHash.distance(base, PerceptualHash.hash(brighter)),
                                 4, "exposure")
        XCTAssertLessThanOrEqual(PerceptualHash.distance(base,
            PerceptualHash.hash(Self.noisy(Self.render(width: 768), sigma: 0.02))), 6, "noise")
    }

    func testTheHashSeparatesDifferentPictures() {
        let base = PerceptualHash.hash(Self.render(width: 768))
        // The same elements, recomposed: a large pan.
        let panned = PerceptualHash.hash(Self.render(width: 768, shift: 0.25))
        XCTAssertGreaterThan(PerceptualHash.distance(base, panned),
                             BurstGrouper.maxHashDistance)
        // A different picture altogether.
        let other = PerceptualHash.hash(Plane(width: 768, height: 512) { u, v in
            0.5 + 0.3 * sin(9 * u) * cos(7 * v)
        })
        XCTAssertGreaterThan(PerceptualHash.distance(base, other),
                             BurstGrouper.maxHashDistance)
        XCTAssertEqual(PerceptualHash.distance(0, .max), 64)
    }

    // MARK: - Burst grouping

    private func frame(_ id: Int64, _ t: Double?, hash: UInt64? = 0, camera: String? = "A",
                       sharp: Double? = nil) -> BurstCandidate {
        BurstCandidate(photoID: id, captureTime: t, camera: camera, hash: hash,
                       sharpness: sharp)
    }

    func testFramesWithinTheGapThatLookAlikeGroup() {
        let groups = BurstGrouper.group([frame(1, 10.0), frame(2, 10.1), frame(3, 10.3),
                                         frame(4, 20), frame(5, 21.9), frame(6, 30)])
        XCTAssertEqual(groups.map(\.members), [[1, 2, 3], [4, 5]])
    }

    func testTheGapIsMeasuredFromTheLastFrameNotTheFirst() {
        // A 5 s burst at 1 fps is one burst: each frame is a second after the last.
        let groups = BurstGrouper.group((0..<6).map { frame(Int64($0), Double($0)) })
        XCTAssertEqual(groups.map(\.members), [[0, 1, 2, 3, 4, 5]])
        XCTAssertTrue(BurstGrouper.group([frame(1, 0), frame(2, 2.01)]).isEmpty)
    }

    func testADifferentPictureSplitsTheBurstEvenInsideTheGap() {
        let far: UInt64 = 0xFFFF_FFFF_0000_0000
        let groups = BurstGrouper.group([frame(1, 0, hash: 0), frame(2, 0.2, hash: 0),
                                         frame(3, 0.4, hash: far), frame(4, 0.6, hash: far)])
        XCTAssertEqual(groups.map(\.members), [[1, 2], [3, 4]])
    }

    func testTwoBodiesInterleavedAreTwoBursts() {
        let groups = BurstGrouper.group([frame(1, 0, camera: "A"), frame(2, 0.1, camera: "B"),
                                         frame(3, 0.2, camera: "A"), frame(4, 0.3, camera: "B")])
        XCTAssertEqual(groups.map(\.members), [[1, 3], [2, 4]])
    }

    func testFramesWithoutATimeOrAHashAreNeverGrouped() {
        XCTAssertTrue(BurstGrouper.group([frame(1, nil), frame(2, nil)]).isEmpty)
        XCTAssertEqual(BurstGrouper.group([frame(1, 0), frame(2, 0.1, hash: nil),
                                           frame(3, 0.2)]).map(\.members), [[1, 3]])
    }

    func testTheEvidenceOrderIsSharpestFirstWithUnscoredLast() {
        let groups = BurstGrouper.group([frame(1, 0, sharp: 0.4), frame(2, 0.1, sharp: nil),
                                         frame(3, 0.2, sharp: 0.9), frame(4, 0.3, sharp: 0.4)])
        XCTAssertEqual(groups.first?.ranked, [3, 1, 4, 2])
        XCTAssertEqual(groups.first?.id, 1)
    }

    // MARK: - Eyes

    private func ellipse(a: Double, b: Double, rotation: Double = 0,
                         points: Int = 16) -> [(x: Double, y: Double)] {
        (0..<points).map { k in
            let t = 2 * Double.pi * Double(k) / Double(points)
            let x = a * cos(t), y = b * sin(t)
            return (x: 100 + x * cos(rotation) - y * sin(rotation),
                    y: 50 + x * sin(rotation) + y * cos(rotation))
        }
    }

    func testTheAspectRatioOfAnEyeOutlineIsItsAxisRatioAtAnyRoll() throws {
        for rotation in [0.0, 0.3, 1.2, -0.7] {
            let ratio = try XCTUnwrap(EyeOpenness.aspectRatio(
                ellipse(a: 20, b: 7, rotation: rotation, points: 64)))
            XCTAssertEqual(ratio, 0.35, accuracy: 0.01, "roll \(rotation)")
        }
        let shut = try XCTUnwrap(EyeOpenness.aspectRatio(ellipse(a: 20, b: 0.5)))
        XCTAssertLessThan(shut, 0.05)
        XCTAssertNil(EyeOpenness.aspectRatio([(0, 0), (1, 1)]))
    }

    func testOpennessMapsTheRatioOntoZeroToOne() {
        XCTAssertEqual(EyeOpenness.openness(aspectRatio: 0.05), 0)
        XCTAssertEqual(EyeOpenness.openness(aspectRatio: 0.20), 0.5, accuracy: 1e-9)
        XCTAssertEqual(EyeOpenness.openness(aspectRatio: 0.40), 1)
        // A blink sits below the chip's default threshold; an open eye far above it.
        let threshold = PhotoQuery().closedEyesThreshold
        XCTAssertLessThan(EyeOpenness.openness(aspectRatio: 0.12), threshold)
        XCTAssertGreaterThan(EyeOpenness.openness(aspectRatio: 0.30), threshold)
    }

    func testAFaceReadsAsTheMoreOpenOfItsEyes() {
        XCTAssertEqual(EyeOpenness.faceOpenness(left: 0.1, right: 0.9), 0.9, "a wink is not a blink")
        XCTAssertEqual(EyeOpenness.faceOpenness(left: 0.1, right: nil), 0.1)
        XCTAssertNil(EyeOpenness.faceOpenness(left: nil, right: nil))
    }
}
