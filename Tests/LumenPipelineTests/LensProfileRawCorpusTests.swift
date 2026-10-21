#if os(macOS)

import CoreImage
import Foundation
import LumenCore
@testable import LumenPipeline
import XCTest

/// WS-28 DIAGNOSTIC: what does Apple's decode correct when `isLensCorrectionEnabled` is
/// on, measured rather than assumed. Runs in the RAW corpus lane (the class name matches
/// its `--filter RawCorpusTests`), and like that suite it skips when LUMEN_RAW_CORPUS is
/// unset.
///
/// `testLensProfileToggleDiagnostic` already showed the A7 IV and GX85 decodes DIFFER
/// with the profile on, and that the corner/centre luminance ratio barely moves. This
/// says what the difference is, per supported file, at decode scale 0.5:
///
///   geometry   green(on) against green(off), radial displacement fitted as
///              k0·r + k2·r³ and reported in native px at r = 0.5, 0.75, 1 — distortion.
///   lateral CA R−G and B−G radial misregistration in each decode, native px at
///              r = 0.75 and 1 — whether Apple also removes lateral CA.
///   vignetting mean luminance ratio on/off per radial ring — whether Apple lifts the
///              corners; beside it the fall-off the file's own record encodes, where
///              there is one (`EmbeddedLensProfile`, Sony).
///
/// Logged as `lens-probe:` lines. Nothing is asserted about Apple: the answer is the
/// output, and docs/quality/lanes/WS-28/REPORT.md records it.
final class LensProfileRawCorpusTestsProbe: XCTestCase {

    func testWhatAppleCorrects() throws {
        let raw = ProcessInfo.processInfo.environment["LUMEN_RAW_CORPUS"] ?? ""
        guard !raw.isEmpty else { throw XCTSkip("LUMEN_RAW_CORPUS unset") }
        let dir = URL(fileURLWithPath: raw)
        let files = try FileManager.default.contentsOfDirectory(at: dir,
                                                                includingPropertiesForKeys: nil)
            .filter { ["arw", "rw2", "orf", "nef", "dng", "cr2", "cr3", "pef"]
                .contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var probed = 0
        for url in files {
            guard let fresh = CIRAWFilter(imageURL: url), fresh.isLensCorrectionSupported
            else { continue }
            guard let source = try? AppleRawSource(url: url) else { continue }
            var off = Recipe()
            off.develop.geometry.lens.profile = false
            guard let onImage = source.decode(recipe: Recipe(), draft: false, scaleFactor: 0.5)
                    .flatMap({ PipelineRenderer.buffer(from: $0, context: DecodeMaterializer.context) }),
                  let offImage = source.decode(recipe: off, draft: false, scaleFactor: 0.5)
                    .flatMap({ PipelineRenderer.buffer(from: $0, context: DecodeMaterializer.context) })
            else {
                emit("\(url.lastPathComponent) decode failed")
                continue
            }
            _ = source.releaseDecodes()
            probed += 1
            let name = url.lastPathComponent
            let half = 0.5 * (Double(onImage.width * onImage.width
                                     + onImage.height * onImage.height)).squareRoot()
            let toNative = 2.0   // decode scale 0.5

            // Geometry: green(on) as "red", green(off) as green.
            if onImage.width == offImage.width, onImage.height == offImage.height {
                var pair = offImage
                for i in 0..<(pair.width * pair.height) {
                    pair.pixels[i * 4] = onImage.pixels[i * 4 + 1]
                    pair.pixels[i * 4 + 2] = onImage.pixels[i * 4 + 1]
                }
                if let samples = LateralCAEstimator.measure(pair),
                   let fit = LateralCAEstimator.fit(samples, \.redShift) {
                    let at = [0.5, 0.75, 1.0].map { fmt(fit.shift(at: $0) * half * toNative) }
                    emit("\(name) geometry on-vs-off radial px (native) r=0.5/0.75/1: "
                         + at.joined(separator: " / ") + " tiles=\(samples.count)")
                } else {
                    emit("\(name) geometry: not measurable (too few shared edges)")
                }
            } else {
                emit("\(name) geometry: extents differ on=\(onImage.width)x\(onImage.height) "
                     + "off=\(offImage.width)x\(offImage.height)")
            }

            // Lateral CA in each decode.
            for (label, image) in [("off", offImage), ("on", onImage)] {
                if let samples = LateralCAEstimator.measure(image),
                   let red = LateralCAEstimator.fit(samples, \.redShift),
                   let blue = LateralCAEstimator.fit(samples, \.blueShift) {
                    emit("\(name) lateral CA profile-\(label) native px R r=0.75/1: "
                         + "\(fmt(red.shift(at: 0.75) * half * toNative)) / "
                         + "\(fmt(red.shift(at: 1) * half * toNative))  B: "
                         + "\(fmt(blue.shift(at: 0.75) * half * toNative)) / "
                         + "\(fmt(blue.shift(at: 1) * half * toNative)) tiles=\(samples.count)")
                } else {
                    emit("\(name) lateral CA profile-\(label): not measurable")
                }
            }

            // Vignetting: ring means on/off.
            let embedded = EmbeddedLensProfile.read(url: url)
            var rings: [String] = []
            for (lo, hi) in [(0.0, 0.2), (0.4, 0.6), (0.6, 0.8), (0.8, 0.9), (0.9, 1.0)] {
                let a = ringMean(onImage, lo, hi), b = ringMean(offImage, lo, hi)
                let ratio = b > 0 ? a / b : .nan
                var part = "r\(lo)-\(hi) on/off=\(fmt(ratio, 4))"
                if let e = embedded {
                    part += " record=\(fmt(1 / e.falloff(at: (lo + hi) / 2), 3))"
                }
                rings.append(part)
            }
            emit("\(name) vignetting " + rings.joined(separator: "  ")
                 + (embedded == nil ? "  (no embedded record)" : "  (record = 1/fall-off the file encodes)"))
        }
        emit("summary: probed \(probed) lens-correction-supported file(s)")
        XCTAssertGreaterThan(probed, 0, "LUMEN_RAW_CORPUS is set but no file reports "
                             + "isLensCorrectionSupported; the probe saw nothing.")
    }

    private func ringMean(_ b: ImageBuffer, _ lo: Double, _ hi: Double) -> Double {
        let cx = Double(b.width) / 2, cy = Double(b.height) / 2
        let half = 0.5 * (Double(b.width * b.width + b.height * b.height)).squareRoot()
        var sum = 0.0, n = 0
        for y in stride(from: 0, to: b.height, by: 2) {
            for x in stride(from: 0, to: b.width, by: 2) {
                let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
                let r = (dx * dx + dy * dy).squareRoot() / half
                guard r >= lo, r < hi else { continue }
                let i = (y * b.width + x) * 4
                sum += 0.2627 * Double(b.pixels[i]) + 0.678 * Double(b.pixels[i + 1])
                    + 0.0593 * Double(b.pixels[i + 2])
                n += 1
            }
        }
        return n > 0 ? sum / Double(n) : 0
    }

    private func fmt(_ v: Double, _ digits: Int = 2) -> String {
        v.isFinite ? String(format: "%.\(digits)f", v) : "-"
    }

    private func emit(_ line: String) {
        print("lens-probe: " + line)
    }
}

#endif
