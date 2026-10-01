// PSFEstimateTests.swift
// `SpatialOps.estimatePSFSigma`, the auto-radius for capture sharpening — the σ readout
// docs/06 sells as the trust device ("σ 0.58 on the 35/1.8") against Lightroom's
// constant 40.
//
// It had no test of any kind (W2/E2-03), and two defects that any test would have found:
//
//   1. THE INVERSE WAS RawTherapee's, for RawTherapee's geometry. A Gaussian of width σ
//      gives a point source a peak-to-neighbour ratio of `exp(d²/2σ²)`. RT measures CFA
//      green neighbours at d = √2, where that is `exp(1/σ²)` and `σ = sqrt(1/ln r)` is
//      right. This function measures the luminance plane at d = 1, where it is
//      `exp(1/2σ²)` — so every σ came back √2 too large.
//   2. EVERY SMOOTH BUMP WAS COUNTED AS A POINT SOURCE. A local maximum of ordinary
//      texture has a ratio of `1 + curvature/2`, nearly 1. They outnumbered real point
//      sources so badly that the 99.5th percentile landed among them and the function
//      returned its 2.0 px ceiling on almost every photograph-like frame.
//
// The function has no shipping caller yet (K-075 / K-088 — capture sharpening runs in
// Apple's decoder). These tests are what makes "wire it" safe when that decision is made.

import XCTest
@testable import LumenCore

final class PSFEstimateTests: XCTestCase {

    /// A dark field of isolated point sources, each a pixel-centred Gaussian of width
    /// `sigma` sampled at integer offsets — so a peak's neighbour one pixel away is
    /// exactly `exp(−1/2σ²)` of it, the geometry the estimator's formula assumes.
    /// Amplitudes vary so most peaks sit under the estimator's clip guard (95% of the
    /// frame's maximum), as real speculars and stars do.
    private func pointSources(sigma: Double, spacing: Int = 13, count: Int = 12) -> Plane {
        let size = spacing * count
        var plane = Plane(width: size, height: size)
        for j in 0..<count {
            for i in 0..<count {
                let cx = i * spacing + spacing / 2
                let cy = j * spacing + spacing / 2
                let amplitude = 0.35 + 0.6 * Double((i * 7 + j * 3) % 11) / 10
                for y in (cy - 5)...(cy + 5) {
                    for x in (cx - 5)...(cx + 5) {
                        let d2 = Double((x - cx) * (x - cx) + (y - cy) * (y - cy))
                        plane.values[y * size + x] += Float(amplitude * exp(-d2 / (2 * sigma * sigma)))
                    }
                }
            }
        }
        return plane
    }

    /// THE INVERSE. Known σ in, the same σ out, within the histogram's resolution.
    /// Under `σ = sqrt(1/ln r)` this reads 1.41× at every σ.
    func testAPointSourceBlurredByAKnownSigmaReportsThatSigma() {
        for sigma in [0.5, 0.8, 1.2] {
            let estimate = SpatialOps.estimatePSFSigma(pointSources(sigma: sigma))
            XCTAssertEqual(estimate / sigma, 1, accuracy: 0.10,
                           "σ \(sigma) reported as \(estimate)")
        }
    }

    /// THE CEILING IS NOT AN ANSWER. Smooth texture with no point-like detail carries no
    /// evidence about the lens, so the estimator must fall back to its stated default
    /// rather than report the widest σ it allows — which is what it did on 8 of 9
    /// photograph-like frames, because every gentle bump was counted as a point source.
    func testSmoothTextureIsNotReadAsTheWidestLens() {
        let size = 160
        var plane = Plane(width: size, height: size)
        for y in 0..<size {
            for x in 0..<size {
                let u = Double(x), v = Double(y)
                var t = 0.5
                for (k, f) in [0.031, 0.057, 0.093, 0.141, 0.207].enumerated() {
                    let a = 0.08 / Double(k + 1)
                    t += a * sin(f * u * 6.283 + Double(k)) * cos(f * 0.8 * v * 6.283 + 0.5 * Double(k))
                }
                plane.values[y * size + x] = Float(t)
            }
        }
        let estimate = SpatialOps.estimatePSFSigma(plane)
        XCTAssertNotEqual(estimate, SpatialOps.maxPSFSigma,
                          "texture with no point sources reported the 2.0 px ceiling")
        XCTAssertEqual(estimate, 0.8, accuracy: 1e-12,
                       "too little evidence must return the stated default")
    }

    /// The point sources still win when they share the frame with texture: the
    /// qualifying floor removes the bumps, not the evidence.
    func testPointSourcesOnTextureStillReportTheirSigma() {
        let sigma = 0.8
        var plane = pointSources(sigma: sigma)
        for y in 0..<plane.height {
            for x in 0..<plane.width {
                let t = 0.03 * sin(Double(x) * 0.21) * cos(Double(y) * 0.17)
                plane.values[y * plane.width + x] += Float(0.06 + t)
            }
        }
        let estimate = SpatialOps.estimatePSFSigma(plane)
        XCTAssertEqual(estimate / sigma, 1, accuracy: 0.15,
                       "σ \(sigma) on texture reported as \(estimate)")
    }
}

/// `DetailEngine.captureSharpen` and the on switch (W2/E2-07).
///
/// `CaptureSharpen.strengthFraction` exists so the two readers of the toggle cannot
/// disagree: the RAW decoder once recomputed `100 / 100 == 1` with `auto == false` and
/// rendered capture sharpening at full strength while the panel said it was off. The
/// reference engine kept its own copy of that expression, guarded on `auto || radius !=
/// nil`, so a recipe carrying the toggle off and a radius left over from another build
/// sharpened at full strength here. Unwired today; this is what keeps "wire it" from
/// landing the inverted-off bug a second time.
final class CaptureSharpenSwitchTests: XCTestCase {

    /// A soft edge with something to deconvolve.
    private func softEdge() -> ImageBuffer {
        ImageBuffer(width: 48, height: 24) { u, _ in
            let t = 1 / (1 + exp(-(u * 48 - 24) / 1.2))
            return RGB(gray: 0.05 + 0.4 * t)
        }
    }

    func testTheToggleOffIsTheIdentityWhateverRadiusTheRecipeCarries() {
        let frame = softEdge()
        let off = DetailEngine.captureSharpen(frame, CaptureSharpen(auto: false, radius: 1.2))
        XCTAssertEqual(off.pixels, frame.pixels,
                       "capture sharpening rendered with its toggle off")
    }

    /// The positive control, so the identity above is not the function doing nothing.
    func testTheToggleOnSharpens() {
        let frame = softEdge()
        let on = DetailEngine.captureSharpen(frame, CaptureSharpen(auto: true, radius: 1.2))
        XCTAssertNotEqual(on.pixels, frame.pixels)
    }
}
