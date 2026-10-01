import Foundation
import XCTest
@testable import LumenCore

/// E1-03 (September audit): `NoiseProfile.estimate(from:)` took each 8×8 block's raw
/// variance as noise, so a scene's own smooth slope inside a block was fitted as shot
/// noise. On the easiest possible input, a smooth ramp plus noise drawn from a known
/// profile, it recovered σ(0.18) at about 1.3× the truth, which as a denoise threshold
/// is 1.3× too strong.
///
/// The estimator still has no caller (wiring it, or deleting it and the "profiled"
/// claim, is the owner's call). These pin what it returns for a frame whose answer is
/// known, so whichever way that goes it does not ship a biased number.
final class NoiseProfileEstimateTests: XCTestCase {

    /// A Poisson-Gaussian frame: `signal(x, y)` plus noise of variance a·signal + b.
    private func frame(width: Int = 256, height: Int = 256, truth: NoiseProfile,
                       seed: UInt64, signal: (Int, Int) -> Double) -> Plane {
        var rng = SplitMix64(seed: seed)
        func uniform() -> Double {
            (Double(rng.next() >> 11) + 0.5) / Double(UInt64(1) << 53)
        }
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let s = signal(x, y)
                // Box-Muller; one normal per sample is plenty.
                let n = (-2 * log(uniform())).squareRoot() * cos(2 * Double.pi * uniform())
                values[y * width + x] = Float(s + truth.sigma(at: s) * n)
            }
        }
        return Plane(width: width, height: height, values: values)
    }

    private func ratio(_ estimate: NoiseProfile, _ truth: NoiseProfile, at level: Double) -> Double {
        estimate.sigma(at: level) / truth.sigma(at: level)
    }

    /// The finding's own test: the proof standard's ramp, 0.18·2^(−3+5v), down the frame.
    func testEstimateRecoversAKnownProfileFromASmoothRamp() {
        let truth = NoiseProfile.forISO(6400)
        let plane = frame(truth: truth, seed: 6400) { _, y in
            0.18 * exp2(-3 + 5 * Double(y) / 255)
        }
        let estimate = NoiseProfile.estimate(from: plane)
        for level in [0.18, 0.5] {
            let r = ratio(estimate, truth, at: level)
            XCTAssertEqual(r, 1, accuracy: 0.10,
                           "σ(\(level)) estimated at \(r)× the truth on a smooth ramp; "
                               + "the ramp's slope inside a block is being read as noise")
        }
    }

    /// The same ramp running ACROSS the frame, so a fix that only handled one axis fails.
    func testEstimateIsBlindToTheDirectionOfTheRamp() {
        let truth = NoiseProfile.forISO(3200)
        let plane = frame(truth: truth, seed: 3200) { x, _ in
            0.18 * exp2(-3 + 5 * Double(x) / 255)
        }
        let r = ratio(NoiseProfile.estimate(from: plane), truth, at: 0.18)
        XCTAssertEqual(r, 1, accuracy: 0.10, "σ(0.18) estimated at \(r)× on a horizontal ramp")
    }

    /// A flat plane is the case the old estimator already got right; the fix must not
    /// cost it.
    func testEstimateOfAFlatPlaneIsTheNoiseAtThatLevel() {
        let truth = NoiseProfile.forISO(6400)
        let plane = frame(truth: truth, seed: 18) { _, _ in 0.18 }
        let r = ratio(NoiseProfile.estimate(from: plane), truth, at: 0.18)
        XCTAssertEqual(r, 1, accuracy: 0.10, "σ(0.18) estimated at \(r)× on a flat plane")
    }
}
