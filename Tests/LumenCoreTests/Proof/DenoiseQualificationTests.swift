import Foundation
import XCTest
@testable import LumenCore

/// Cross-camera noise mismatch is intentionally distinct from exact-model calibration.
/// These ground-truth probes measure it; they do not certify real-camera noise profiles.
final class DenoiseQualificationTests: XCTestCase {
    private let controls: [(String, WritableKeyPath<ClassicNR, Double>)] = [
        ("luma", \.luma), ("chroma", \.chroma), ("hotPixels", \.hotPixels),
        ("lumaDetail", \.lumaDetail), ("lumaContrast", \.lumaContrast),
        ("colorDetail", \.colorDetail), ("colorSmoothness", \.colorSmoothness)
    ]

    private func mse(_ a: ImageBuffer, _ b: ImageBuffer) -> Double {
        var sum = 0.0
        for i in stride(from: 0, to: a.pixels.count, by: 4) {
            for channel in 0..<3 {
                let d = Double(a.pixels[i + channel] - b.pixels[i + channel])
                sum += d * d
            }
        }
        return sum / Double(a.count * 3)
    }

    func testEveryDenoiseControlPreservesAFlatColourAcrossISO() {
        // Flat saturated and shadow fields expose tone/color shifts that noise-only
        // standard deviation cannot detect. No injected noise means smoothing has
        // nothing to improve. The unbiased inverse has a documented small
        // pedestal (asymptotically a/4), so allow that statistical correction
        // while rejecting blur-induced colour or brightness movement beyond it.
        for iso in [100.0, 6400.0, 25600.0] {
            for color in [RGB(gray: 0.02), RGB(gray: 0.18), RGB(0.12, 0.30, 0.06)] {
                let clean = ImageBuffer(width: 40, height: 40) { _, _ in color }
                for (name, key) in controls {
                    for endpoint in [0.0, 100.0] {
                        var settings = ClassicNR(luma: 50, chroma: 50)
                        settings[keyPath: key] = endpoint
                        let out = ClassicalDenoise(settings, profile: .forISO(iso)).apply(clean)
                        XCTAssertTrue(out.pixels.allSatisfy { $0.isFinite }, "\(name) \(endpoint), ISO \(iso)")
                        let allowedDrift = max(1e-5, NoiseProfile.forISO(iso).a * 0.5)
                        XCTAssertLessThan(mse(clean, out), allowedDrift * allowedDrift,
                                          "\(name) \(endpoint), ISO \(iso) changed a uniform known colour")
                    }
                }
            }
        }
    }

    func testProfileMismatchIsMeasuredAgainstCleanTextureRatherThanNoiseVariance() {
        let clean = ProofFrames.cleanISO6400(width: 64, height: 64)
        for iso in [400.0, 1600.0, 6400.0, 25600.0] {
            // More than one noise realization prevents a single lucky seed becoming
            // the entire evidence for a default. Ratios are logged for diagnosis;
            // mismatch is not required to outperform the exactly matched profile.
            for seed in [UInt64(17), UInt64(4099)] {
                let noisy = ProofFrames.noisyLumaFrame(width: 64, height: 64, seed: seed, iso: iso)
                let baseline = mse(clean, noisy)
                let assumed = NoiseProfile.forISO(iso)
                for scale in [0.5, 1.0, 2.0] {
                    let profile = NoiseProfile(a: assumed.a * scale, b: assumed.b * scale)
                    let out = ClassicalDenoise(ISODefaults.classic(forISO: iso), profile: profile).apply(noisy)
                    XCTAssertTrue(out.pixels.allSatisfy { $0.isFinite })
                    let ratio = mse(clean, out) / baseline
                    print("DENOISE-QUALIFICATION ISO=\(Int(iso)) seed=\(seed) varianceScale=\(scale) mseRatio=\(ratio)")
                    // Exact-model defaults must earn their existence. Mismatch data
                    // remains visible without disguising an unmeasured camera model
                    // as a calibrated assertion.
                    if scale == 1 {
                        XCTAssertLessThan(ratio, 1, "ISO \(iso) default increased ground-truth error")
                    }
                }
            }
        }
    }

    func testZeroMastersAndHotPixelsAreIdentityAcrossEverySubcontrolEndpoint() {
        let noisy = ProofFrames.noisyLumaFrame(width: 40, height: 40, iso: 25600)
        for (_, key) in controls.dropFirst(3) {
            for endpoint in [0.0, 100.0] {
                var settings = ClassicNR(luma: 0, chroma: 0, hotPixels: 0)
                settings[keyPath: key] = endpoint
                let out = ClassicalDenoise(settings, profile: .forISO(25600)).apply(noisy)
                XCTAssertEqual(out.pixels, noisy.pixels, "a subordinate control enabled a zero-strength stage")
            }
        }
    }
}
