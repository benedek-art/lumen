// DemosaicedFrames.swift
// Test frames that went through what every frame S3 sees went through: an RGGB mosaic,
// per-photosite Poisson–Gaussian noise drawn from a `NoiseProfile`, and a demosaic
// (bilinear). Shared by ClassicNRDemosaicedTests and DenoiseQualityTests.
//
// Why it exists: white per-pixel noise is not what a demosaiced frame carries. The
// interpolation correlates neighbours, so noise leaves the finest band and piles up at
// 2–8 px, and an engine calibrated to that (ClassicalDenoise's `*BandNoise` tables)
// over-reads a white-noise frame — as an engine calibrated to white noise under-read
// every real one, which is the defect WS-19 fixed.

import Foundation
@testable import LumenCore

enum DemosaicedFrames {

    static func gaussian(x: Int, y: Int, seed: UInt64) -> Double {
        func mix(_ v: UInt64) -> UInt64 {
            var z = v &+ 0x9E3779B97F4A7C15
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        let base = mix(seed &+ UInt64(bitPattern: Int64(x &* 73_856_093))
                       &+ UInt64(bitPattern: Int64(y &* 19_349_663)))
        let u1 = Double(base >> 11) / Double(1 << 53)
        let u2 = Double(mix(base) >> 11) / Double(1 << 53)
        let r = (-2 * Foundation.log(Swift.max(u1, 1e-12))).squareRoot()
        return r * Foundation.cos(2 * Double.pi * u2)
    }

    /// RGGB site colour of a photosite.
    static func site(_ x: Int, _ y: Int) -> Int {
        switch (y & 1, x & 1) {
        case (0, 0): return 0
        case (1, 1): return 2
        default: return 1
        }
    }

    /// Sample `scene` onto an RGGB mosaic, add per-photosite Poisson–Gaussian noise from
    /// `profile` (none when nil), apply `defect` to the raw values, and demosaic
    /// bilinearly.
    static func make(_ scene: (Int, Int) -> RGB, width: Int, height: Int,
                     profile: NoiseProfile?, seed: UInt64 = 0xC0FFEE,
                     defect: ((Int, Int, Double) -> Double)? = nil) -> ImageBuffer {
        var raw = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var v = scene(x, y)[Self.site(x, y)]
                if let profile {
                    v += Self.gaussian(x: x, y: y, seed: seed) * profile.sigma(at: v)
                }
                if let defect { v = defect(x, y, v) }
                raw[y * width + x] = v
            }
        }
        func at(_ x: Int, _ y: Int) -> Double {
            raw[Swift.min(Swift.max(y, 0), height - 1) * width
                + Swift.min(Swift.max(x, 0), width - 1)]
        }
        var out = ImageBuffer(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                var c = RGB.zero
                for ch in 0..<3 {
                    if Self.site(x, y) == ch { c[ch] = at(x, y); continue }
                    var sum = 0.0
                    var n = 0.0
                    for dy in -1...1 {
                        for dx in -1...1 where dx != 0 || dy != 0 {
                            let sx = Swift.min(Swift.max(x + dx, 0), width - 1)
                            let sy = Swift.min(Swift.max(y + dy, 0), height - 1)
                            if Self.site(sx, sy) == ch && (ch != 1 || dx == 0 || dy == 0) {
                                sum += at(sx, sy)
                                n += 1
                            }
                        }
                    }
                    c[ch] = n > 0 ? sum / n : 0
                }
                out[x, y] = c
            }
        }
        return out
    }
}
