// RawDenoiseNoiseTable.swift
// The per-camera ISO -> (K, read variance) table that conditions the raw AI denoiser.
// A Swift port of Denoise/lumen_denoise/train.py `NoiseTable` plus the ISO clamp in
// infer.py `Engine.noise_params`; it reads Denoise/weights/calib.json unchanged.
//
// Why a port must be bit-faithful rather than "a reasonable interpolation": the network
// was trained on std maps built from exactly these numbers. A table that interpolates
// linearly in ISO instead of log-log, or extrapolates past the calibrated range instead
// of clamping, hands the model a noise level it never saw and it under- or over-smooths
// with no visible error anywhere. The goldens in RawDenoiseNoiseTableTests come from the
// real Python (Denoise/scripts/gen_swift_fixtures_noise.py).
//
// Units: K and read variance are in the normalised raw domain, (raw - black)/(white -
// black), per packed Bayer plane. They are NOT the S3 `NoiseProfile` (a, b), which lives
// in the linear working image after white balance; the two must not be mixed.

import Foundation

/// Shot gain and read variance for one (camera, ISO): `variance = k·signal + readVar`.
public struct RawDenoiseNoiseParams: Sendable, Equatable {
    public var k: Double
    public var readVar: Double

    public init(k: Double, readVar: Double) {
        self.k = k
        self.readVar = readVar
    }
}

public struct RawDenoiseNoiseTable: Sendable, Equatable {

    public struct Entry: Sendable, Equatable {
        public var iso: Double
        public var k: Double
        public var readVar: Double

        public init(iso: Double, k: Double, readVar: Double) {
            self.iso = iso
            self.k = k
            self.readVar = readVar
        }
    }

    public enum ParseError: Error, Equatable {
        /// A row is not three numbers.
        case badRow(model: String, index: Int)
        /// A value is non-finite or <= 0: Python takes its log, so it would be -inf/NaN
        /// there and silently poison every interpolation that touches it.
        case nonPositive(model: String, index: Int)
        /// No rows: `np.interp` raises on an empty table.
        case empty(model: String)
    }

    /// Camera model (rawpy's `model` string, e.g. "ILCE-7M4") -> rows sorted by ISO.
    public let cameras: [String: [Entry]]

    public init(cameras: [String: [Entry]]) {
        self.cameras = cameras.mapValues(Self.sorted)
    }

    /// Parses calib.json: `{model: [[iso, K, read_var], ...]}`. Decoding failures of the
    /// shape surface as `DecodingError`; content problems as `ParseError`.
    public init(jsonData: Data) throws {
        let root = try JSONDecoder().decode([String: [[Double]]].self, from: jsonData)
        var cams: [String: [Entry]] = [:]
        for (model, rows) in root {
            if rows.isEmpty { throw ParseError.empty(model: model) }
            cams[model] = try rows.enumerated().map { i, v in
                guard v.count == 3 else { throw ParseError.badRow(model: model, index: i) }
                guard v.allSatisfy({ $0.isFinite && $0 > 0 }) else {
                    throw ParseError.nonPositive(model: model, index: i)
                }
                return Entry(iso: v[0], k: v[1], readVar: v[2])
            }
        }
        self.init(cameras: cams)
    }

    /// Python sorts the raw rows (`sorted(v)`), i.e. lexicographically by (iso, K, r).
    private static func sorted(_ rows: [Entry]) -> [Entry] {
        rows.sorted { a, b in
            if a.iso != b.iso { return a.iso < b.iso }
            if a.k != b.k { return a.k < b.k }
            return a.readVar < b.readVar
        }
    }

    public func isoRange(model: String) -> ClosedRange<Double>? {
        guard let rows = cameras[model], let lo = rows.first, let hi = rows.last else {
            return nil
        }
        return lo.iso...hi.iso
    }

    /// Noise parameters for `model` at `iso`, or nil for an uncalibrated camera (where
    /// infer.py falls back to estimating noise from the image itself — Lumen's caller
    /// decides what to do then). The ISO is clamped to the calibrated range first, as
    /// infer.py does; a non-finite ISO also returns nil rather than a NaN noise level.
    public func params(model: String, iso: Double) -> RawDenoiseNoiseParams? {
        guard !iso.isNaN, let rows = cameras[model], let range = isoRange(model: model)
        else { return nil }
        let x = Foundation.log(Swift.min(Swift.max(iso, range.lowerBound), range.upperBound))
        let xp = rows.map { Foundation.log($0.iso) }
        let k = Foundation.exp(Self.interp(x, xp, rows.map { Foundation.log($0.k) }))
        let r = Foundation.exp(Self.interp(x, xp, rows.map { Foundation.log($0.readVar) }))
        return RawDenoiseNoiseParams(k: k, readVar: r)
    }

    /// Scalar `np.interp(x, xp, fp)` with its default left/right (endpoint) values,
    /// following numpy's arr_interp branch for branch so ties and endpoints agree:
    /// xp[j] <= x < xp[j+1] by binary search, an exact hit returns fp[j], otherwise
    /// `slope·(x − xp[j]) + fp[j]`.
    static func interp(_ x: Double, _ xp: [Double], _ fp: [Double]) -> Double {
        let n = xp.count
        precondition(n > 0 && fp.count == n)
        if n == 1 { return fp[0] }
        if x > xp[n - 1] { return fp[n - 1] }
        if x < xp[0] { return fp[0] }
        if x == xp[n - 1] { return fp[n - 1] }
        // Largest j with xp[j] <= x (x < xp[n-1] here, so j <= n-2).
        var lo = 0, hi = n - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if xp[mid] <= x { lo = mid } else { hi = mid }
        }
        let j = lo
        if xp[j] == x { return fp[j] }
        let slope = (fp[j + 1] - fp[j]) / (xp[j + 1] - xp[j])
        var y = slope * (x - xp[j]) + fp[j]
        if y.isNaN {
            y = slope * (x - xp[j + 1]) + fp[j + 1]
            if y.isNaN && fp[j] == fp[j + 1] { y = fp[j] }
        }
        return y
    }
}
