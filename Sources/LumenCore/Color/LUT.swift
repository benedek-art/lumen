// LUT.swift
// The shaper encoding and the lookup tables the GPU stages consume.
//
// The pipeline's per-pixel colour maths — printer lights, colour tools, grade, film
// chain, display transform, tone curve — are all pure RGB→RGB functions. Rather than
// port each one into a shader (nine chances to diverge from the reference), the engine
// evaluates the composed function in Swift, bakes it into one 3-D lookup table over a
// log-encoded domain, and lets the GPU do a trilinear fetch. Shader-side there is one
// small shaper kernel and one stock cube filter; reference-side there is one
// implementation, which is also the one the goldens test.
//
// The cost is interpolation error, bounded by table size (§tolerances in the tests):
// 33³ for interaction, 65³ for export — the same ladder colour-managed film pipelines
// have used for twenty years.

import Foundation

// MARK: - Shaper

/// Log encoding used as the LUT domain: a log2 curve over ±12 stops around mid-grey
/// with a linear toe so that zero and small negatives survive the round trip.
///
/// The domain deliberately extends 12 stops above mid-grey (≈ 737× mid-grey, ≈ 2.6
/// stops above the brightest specular a camera records) and 12 below — no real scene
/// value is clipped by the shaper itself.
public enum LumenLog: Sendable {
    public static let midGrey: Double = 0.18
    public static let minEV: Double = -12
    public static let maxEV: Double = 12

    public static let range: Double = maxEV - minEV
    public static let invRange: Double = 1.0 / range

    /// Linear/log crossover: 1.5 stops above the bottom of the domain.
    public static let linearCut: Double = midGrey * pow(2, minEV + 1.5)

    public static let toeSlope: Double = invRange / (linearCut * log(2.0))
    /// The toe must MEET the log branch at the crossover. The encoded value there is
    /// `(log2(cut/grey) − minEV)·invRange = 1.5·invRange`, so the offset is measured
    /// from 1.5 stops, not from `minEV + 1.5`. Getting that wrong shifts the whole toe
    /// down by half the domain: encode and decode stay each other's inverse, so a
    /// round-trip test still passes, while every value below the crossover — and every
    /// negative — lands outside [0,1] and is clamped to index 0 by the cube stages.
    public static let toeOffset: Double = 1.5 * invRange - toeSlope * linearCut

    @inlinable public static func encode(_ x: Double) -> Double {
        if x >= linearCut {
            return (log2(x / midGrey) - minEV) * invRange
        }
        return toeSlope * x + toeOffset
    }

    @inlinable public static func decode(_ y: Double) -> Double {
        let cutY = toeSlope * linearCut + toeOffset
        if y >= cutY {
            return midGrey * pow(2, y * range + minEV)
        }
        return (y - toeOffset) / toeSlope
    }

    public static func encode(_ c: RGB) -> RGB { c.map(encode) }
    public static func decode(_ c: RGB) -> RGB { c.map(decode) }

    /// The shaper as Core Image kernel source. Kept beside the Swift reference so the
    /// two can never drift silently — a test renders this kernel and compares.
    public static var encodeKernelSource: String {
        """
        kernel vec4 lumenLogEncode(__sample s) {
            vec3 c = s.rgb;
            vec3 lo = vec3(\(fmt(toeSlope))) * c + vec3(\(fmt(toeOffset)));
            vec3 hi = (log2(max(c, vec3(1e-9)) / vec3(\(fmt(midGrey)))) - vec3(\(fmt(minEV)))) * vec3(\(fmt(invRange)));
            vec3 useHi = step(vec3(\(fmt(linearCut))), c);
            return vec4(mix(lo, hi, useHi), s.a);
        }
        """
    }

    public static var decodeKernelSource: String {
        let cutY = toeSlope * linearCut + toeOffset
        return """
        kernel vec4 lumenLogDecode(__sample s) {
            vec3 c = s.rgb;
            vec3 lo = (c - vec3(\(fmt(toeOffset)))) / vec3(\(fmt(toeSlope)));
            vec3 hi = vec3(\(fmt(midGrey))) * exp2(c * vec3(\(fmt(range))) + vec3(\(fmt(minEV))));
            vec3 useHi = step(vec3(\(fmt(cutY))), c);
            return vec4(mix(lo, hi, useHi), s.a);
        }
        """
    }

    private static func fmt(_ v: Double) -> String {
        String(format: "%.10g", v)
    }
}

// MARK: - 1-D LUT

/// A sampled 1-D function over [0,1] with linear interpolation and clamped ends.
public struct LUT1D: Equatable, Sendable {
    public let samples: [Double]

    public init(samples: [Double]) {
        precondition(samples.count >= 2, "LUT1D needs at least 2 samples")
        self.samples = samples
    }

    public init(size: Int = 1024, _ f: (Double) -> Double) {
        precondition(size >= 2)
        var s = [Double](repeating: 0, count: size)
        for i in 0..<size { s[i] = f(Double(i) / Double(size - 1)) }
        self.samples = s
    }

    public var count: Int { samples.count }

    @inlinable public func evaluate(_ x: Double) -> Double {
        let n = samples.count
        // Scene-referred data legitimately carries values above 1 and below 0, and a
        // matrix with negative off-diagonals turns an infinity into a NaN. `saturate`
        // does not sanitise one — every comparison against NaN is false — so it would
        // reach `Int()` and trap. Non-finite means "no information": read index 0.
        if !x.isFinite { return samples[0] }
        if x <= 0 { return samples[0] }
        if x >= 1 { return samples[n - 1] }
        let p = x * Double(n - 1)
        let i = Int(p)
        let t = p - Double(i)
        if i >= n - 1 { return samples[n - 1] }
        return samples[i] + (samples[i + 1] - samples[i]) * t
    }

    public var floats: [Float] { samples.map(Float.init) }

    /// Identity check with tolerance — lets stages skip a no-op LUT upload.
    public func isIdentity(tolerance: Double = 1e-6) -> Bool {
        for (i, v) in samples.enumerated() {
            if abs(v - Double(i) / Double(samples.count - 1)) > tolerance { return false }
        }
        return true
    }

    public func maxAbsDifference(_ other: LUT1D) -> Double {
        let n = Swift.min(samples.count, other.samples.count)
        var d = 0.0
        for i in 0..<n {
            let x = Double(i) / Double(n - 1)
            d = Swift.max(d, abs(evaluate(x) - other.evaluate(x)))
        }
        return d
    }
}

// MARK: - 3-D LUT

/// A cube of RGB→RGB samples over the unit domain, trilinearly interpolated.
/// Layout matches Core Image's `CIColorCube`: red varies fastest, then green, then
/// blue, four floats (RGBA) per entry.
public struct LUT3D: Equatable, Sendable {

    /// Interactive size — ~36k samples, a few milliseconds to bake.
    public static let interactiveSize = 33
    /// Export size — ~275k samples; interpolation error below any visible step.
    public static let exportSize = 65

    public let size: Int
    public let data: [Float]     // size³ × 4

    public init(size: Int, data: [Float]) {
        precondition(size >= 2)
        precondition(data.count == size * size * size * 4, "LUT3D data size mismatch")
        self.size = size
        self.data = data
    }

    /// Bake `transform` over the unit cube. The transform receives the cube's
    /// coordinate (the *encoded* value) and returns the output value it maps to.
    public init(size: Int = LUT3D.interactiveSize, transform: (RGB) -> RGB) {
        precondition(size >= 2)
        let n = size
        var out = [Float](repeating: 0, count: n * n * n * 4)
        let denom = Double(n - 1)
        var index = 0
        for bi in 0..<n {
            let b = Double(bi) / denom
            for gi in 0..<n {
                let g = Double(gi) / denom
                for ri in 0..<n {
                    let r = Double(ri) / denom
                    let v = transform(RGB(r, g, b))
                    out[index] = Float(v.r)
                    out[index + 1] = Float(v.g)
                    out[index + 2] = Float(v.b)
                    out[index + 3] = 1
                    index += 4
                }
            }
        }
        self.size = n
        self.data = out
    }

    @inlinable public func sample(_ c: RGB) -> RGB {
        let n = size
        let maxIndex = n - 1
        // Same reasoning as LUT1D.evaluate: a NaN survives `saturate` and traps at
        // `Int()`. One poisoned pixel must not take down a render.
        func coordinate(_ v: Double) -> Double {
            v.isFinite ? Num.saturate(v) * Double(maxIndex) : 0
        }
        let fr = coordinate(c.r)
        let fg = coordinate(c.g)
        let fb = coordinate(c.b)
        let r0 = Swift.min(Int(fr), maxIndex), r1 = Swift.min(r0 + 1, maxIndex)
        let g0 = Swift.min(Int(fg), maxIndex), g1 = Swift.min(g0 + 1, maxIndex)
        let b0 = Swift.min(Int(fb), maxIndex), b1 = Swift.min(b0 + 1, maxIndex)
        let tr = fr - Double(r0), tg = fg - Double(g0), tb = fb - Double(b0)

        func at(_ r: Int, _ g: Int, _ b: Int) -> RGB {
            let i = ((b * n + g) * n + r) * 4
            return RGB(Double(data[i]), Double(data[i + 1]), Double(data[i + 2]))
        }

        let c000 = at(r0, g0, b0), c100 = at(r1, g0, b0)
        let c010 = at(r0, g1, b0), c110 = at(r1, g1, b0)
        let c001 = at(r0, g0, b1), c101 = at(r1, g0, b1)
        let c011 = at(r0, g1, b1), c111 = at(r1, g1, b1)

        let c00 = c000.mix(c100, tr), c10 = c010.mix(c110, tr)
        let c01 = c001.mix(c101, tr), c11 = c011.mix(c111, tr)
        return c00.mix(c10, tg).mix(c01.mix(c11, tg), tb)
    }

    /// Identity cube — the fast path when a recipe has no colour work at all.
    public static func identity(size: Int = LUT3D.interactiveSize) -> LUT3D {
        LUT3D(size: size) { $0 }
    }

    public func maxAbsDifference(_ other: LUT3D) -> Double {
        guard size == other.size else { return .infinity }
        var d = 0.0
        for i in 0..<data.count { d = Swift.max(d, abs(Double(data[i] - other.data[i]))) }
        return d
    }

    /// Serialize as an Iridas/Resolve `.cube` file — the interchange format every
    /// grading tool reads, and how a Lumen Look leaves the building.
    public func cubeFileContents(title: String) -> String {
        var s = "TITLE \"\(title)\"\nLUT_3D_SIZE \(size)\nDOMAIN_MIN 0.0 0.0 0.0\nDOMAIN_MAX 1.0 1.0 1.0\n"
        var i = 0
        while i < data.count {
            s += String(format: "%.6f %.6f %.6f\n", data[i], data[i + 1], data[i + 2])
            i += 4
        }
        return s
    }

    /// Parse an Iridas/Resolve `.cube` file. Returns nil on anything malformed —
    /// a user's LUT collection is untrusted input.
    public static func fromCubeFile(_ text: String) -> LUT3D? {
        var size = 0
        var values: [Float] = []
        var domainMin = RGB(0, 0, 0)
        var domainMax = RGB(1, 1, 1)
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: " ").filter { !$0.isEmpty }
            guard let head = parts.first else { continue }
            switch head {
            case "TITLE":
                continue
            case "LUT_3D_SIZE":
                guard parts.count >= 2, let n = Int(parts[1]), n >= 2, n <= 129 else { return nil }
                size = n
            case "LUT_1D_SIZE":
                return nil      // 1-D cubes are a different animal; not supported
            case "DOMAIN_MIN":
                guard parts.count >= 4, let r = Double(parts[1]), let g = Double(parts[2]),
                      let b = Double(parts[3]) else { return nil }
                domainMin = RGB(r, g, b)
            case "DOMAIN_MAX":
                guard parts.count >= 4, let r = Double(parts[1]), let g = Double(parts[2]),
                      let b = Double(parts[3]) else { return nil }
                domainMax = RGB(r, g, b)
            default:
                guard parts.count >= 3, let r = Float(parts[0]), let g = Float(parts[1]),
                      let b = Float(parts[2]) else { return nil }
                values.append(r)
                values.append(g)
                values.append(b)
                values.append(1)
            }
        }
        guard size >= 2, values.count == size * size * size * 4 else { return nil }
        guard domainMin == RGB(0, 0, 0), domainMax == RGB(1, 1, 1) else {
            // Rescale a non-unit domain into ours rather than rejecting the file.
            let lut = LUT3D(size: size, data: values)
            return LUT3D(size: size) { c in
                lut.sample(RGB((c.r - domainMin.r) / (domainMax.r - domainMin.r),
                               (c.g - domainMin.g) / (domainMax.g - domainMin.g),
                               (c.b - domainMin.b) / (domainMax.b - domainMin.b)))
            }
        }
        return LUT3D(size: size, data: values)
    }
}
