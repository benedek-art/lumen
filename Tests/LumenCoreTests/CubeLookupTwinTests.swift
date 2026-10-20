// CubeLookupTwinTests.swift
// The GPU's table fetch must interpolate the way the reference renderer does.
//
// Every plan table — finish, grade, tone gain, local pre/post, the local curve — and
// every creative LUT reaches the picture on the GPU through one kernel,
// `KernelLibrary.cubeLookup`, and on the CPU through `LUT3D.sample`. The CPU was
// tetrahedral and the kernel was trilinear, and the difference is not a rounding
// footnote: the display transform tone-maps max(r, g, b), which has a kink on the
// neutral axis, and trilinear reads the six off-axis corners that tetrahedral never
// touches for a grey. Over a neutral ramp through the default finish table the GPU came
// out up to 6.6 sRGB codes darker than the exact maths at the 33-knot preview size and
// 3.5 at the 65-knot export size, in a ripple with the knot period, where the CPU's
// sample of the very same table stays inside 3.5 and 0.9. Two renderers, one recipe,
// two different greys.
//
// It reads `Kernels.swift` as text because `LumenPipeline` is `#if os(macOS)` and does
// not build on the Linux lane (the same reason `KernelRosterTests` does). What it holds
// the kernel to is not a pattern someone typed into this file but `LUT3D.sample`'s own
// source: the branch conditions, their order and tie-breaks, and the three corner
// differences each tetrahedron blends. Change one sampler and not the other and this
// fails. `ColorCubePrecisionTests` then holds the compiled kernel to the CPU's numbers
// on a Mac.

import XCTest
@testable import LumenCore

final class CubeLookupTwinTests: XCTestCase {

    /// One step of a sampler's interpolation: a branch condition, an `else`, or the
    /// three corner differences a tetrahedron weights by r, g and b.
    private enum SamplerStep: Equatable, CustomStringConvertible {
        case branch(String), orBranch(String), otherwise, blend(String, String, String)
        var description: String {
            switch self {
            case .branch(let c): return "if \(c)"
            case .orBranch(let c): return "else if \(c)"
            case .otherwise: return "else"
            case .blend(let a, let b, let c): return "blend(\(a), \(b), \(c))"
            }
        }
    }

    func testTheGPUCubeFetchIsTheReferencesTetrahedralInterpolant() throws {
        let cpu = try Self.cpuSteps()
        // Six tetrahedra under five conditions: if this does not hold, the parser has
        // stopped reading `LUT3D.sample` and the comparison below would be vacuous.
        XCTAssertEqual(cpu.filter { if case .blend = $0 { return true }; return false }.count,
                       6, "could not read LUT3D.sample's six tetrahedra: \(cpu)")

        let kernel = try Self.kernelBody()
        let gpu = Self.gpuSteps(kernel)
        XCTAssertEqual(gpu, cpu,
                       "`lumenCubeLookup` does not interpolate the way `LUT3D.sample` does, "
                       + "so every GPU table fetch departs from the reference renderer.\n"
                       + "  CPU: \(cpu)\n  GPU: \(gpu)")
        // And nothing trilinear left over: a stray `mix` chain after the branches would
        // pass the comparison above while still deciding the pixel.
        XCTAssertFalse(kernel.contains("mix("),
                       "`lumenCubeLookup` still blends with `mix`, the trilinear form")
    }

    /// The kernel addresses its cell differently from `LUT3D.sample` at the top edge —
    /// lower corner clamped to n − 2 so f reaches 1, where the CPU clamps the UPPER index
    /// and leaves f = 0 — and claims that is the same value. This is that claim, checked:
    /// the kernel's addressing with the shared six tetrahedra, against `sample`, on the
    /// faces, edges and corners where the two addressings differ and on interior points.
    func testTheKernelsTopEdgeAddressingLandsOnTheSameValueAsTheReferences() {
        for n in [2, 17, LUT3D.interactiveSize] {
            let lut = LUT3D(size: n) { c in
                RGB(0.05 + 0.8 * c.r * c.r, 0.1 + 0.7 * c.g * (0.5 + 0.5 * c.b),
                    0.2 + 0.6 * (c.r + c.b) / 2 + 0.3 * c.g * c.r)
            }
            var inputs: [RGB] = []
            let edges = [0.0, 0.37, 1.0, 1.3, -0.2]
            for r in edges { for g in edges { for b in edges { inputs.append(RGB(r, g, b)) } } }
            var state: UInt64 = 11
            func next() -> Double {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Double(state >> 40) / Double(1 << 24)
            }
            for _ in 0..<300 { inputs.append(RGB(next(), next(), next())) }
            for _ in 0..<100 { inputs.append(RGB(1, next(), next())) }
            for _ in 0..<100 { inputs.append(RGB(next(), 1, 1)) }
            for c in inputs {
                let kernel = Self.kernelAddressed(lut, c)
                let reference = lut.sample(c)
                XCTAssertLessThan(kernel.maxAbsDifference(reference), 1e-12,
                                  "n=\(n) at \(c): kernel addressing \(kernel), "
                                  + "LUT3D.sample \(reference)")
            }
        }
    }

    // MARK: - the kernel's addressing, restated

    /// `lumenCubeLookup`'s lattice step in Swift: clamp to the unit cube, lower corner
    /// `min(floor(p), n − 2)`, fractions against it, then the six tetrahedra.
    private static func kernelAddressed(_ lut: LUT3D, _ c: RGB) -> RGB {
        let n = lut.size
        func at(_ r: Int, _ g: Int, _ b: Int) -> RGB {
            let i = ((b * n + g) * n + r) * 4
            return RGB(Double(lut.data[i]), Double(lut.data[i + 1]), Double(lut.data[i + 2]))
        }
        func axis(_ v: Double) -> (Int, Double) {
            let p = Num.saturate(v) * Double(n - 1)
            let i0 = Swift.min(p.rounded(.down), Double(n - 2))
            return (Int(i0), p - i0)
        }
        let (r0, fr) = axis(c.r), (g0, fg) = axis(c.g), (b0, fb) = axis(c.b)
        let c000 = at(r0, g0, b0), c100 = at(r0 + 1, g0, b0)
        let c010 = at(r0, g0 + 1, b0), c110 = at(r0 + 1, g0 + 1, b0)
        let c001 = at(r0, g0, b0 + 1), c101 = at(r0 + 1, g0, b0 + 1)
        let c011 = at(r0, g0 + 1, b0 + 1), c111 = at(r0 + 1, g0 + 1, b0 + 1)
        func blend(_ a: RGB, _ b: RGB, _ c: RGB) -> RGB { c000 + a * fr + b * fg + c * fb }
        if fr >= fg {
            if fg >= fb { return blend(c100 - c000, c110 - c100, c111 - c110) }
            if fr >= fb { return blend(c100 - c000, c111 - c101, c101 - c100) }
            return blend(c101 - c001, c111 - c101, c001 - c000)
        }
        if fb > fg { return blend(c111 - c011, c011 - c001, c001 - c000) }
        if fb > fr { return blend(c111 - c011, c010 - c000, c011 - c010) }
        return blend(c110 - c010, c010 - c000, c111 - c110)
    }

    // MARK: - reading the two samplers

    private static func root() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func lines(_ text: Substring) -> [String] {
        text.split(separator: "\n").map {
            var line = String($0)
            if let comment = line.range(of: "//") { line = String(line[..<comment.lowerBound]) }
            return line.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }

    /// Spaces out, and each sampler's fraction names mapped onto plain r, g, b.
    private static func normalized(_ s: Substring) -> String {
        s.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: "f.r", with: "r").replacingOccurrences(of: "f.g", with: "g")
            .replacingOccurrences(of: "f.b", with: "b")
            .replacingOccurrences(of: "tr", with: "r").replacingOccurrences(of: "tg", with: "g")
            .replacingOccurrences(of: "tb", with: "b")
    }

    /// `LUT3D.sample`, from its `blend` helper to the end of the function.
    private static func cpuSteps() throws -> [SamplerStep] {
        let source = try String(contentsOf: root().appendingPathComponent(
            "Sources/LumenCore/Color/LUT.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "public func sample(_ input: RGB) -> RGB {"))
        let rest = source[start.upperBound...]
        let helper = try XCTUnwrap(rest.range(of: "func blend("))
        let tail = rest[helper.upperBound...]
        let end = try XCTUnwrap(tail.range(of: "\n    }\n"))
        var steps: [SamplerStep] = []
        for line in lines(tail[..<end.lowerBound]) {
            if line.hasPrefix("} else if "), line.hasSuffix("{") {
                steps.append(.orBranch(normalized(line.dropFirst(10).dropLast())))
            } else if line.hasPrefix("if "), line.hasSuffix("{") {
                steps.append(.branch(normalized(line.dropFirst(3).dropLast())))
            } else if line == "} else {" {
                steps.append(.otherwise)
            } else if line.hasPrefix("return blend("), line.hasSuffix(")") {
                let args = line.dropFirst(13).dropLast().split(separator: ",")
                guard args.count == 3 else { continue }
                steps.append(.blend(normalized(args[0]), normalized(args[1]),
                                    normalized(args[2])))
            }
        }
        return steps
    }

    /// The text of `lumenCubeLookup`, from its declaration to the string's close.
    private static func kernelBody() throws -> String {
        let source = try String(contentsOf: root().appendingPathComponent(
            "Sources/LumenPipeline/Kernels.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "kernel vec4 lumenCubeLookup("))
        let rest = source[start.lowerBound...]
        let end = try XCTUnwrap(rest.range(of: "\"\"\""))
        return String(rest[..<end.lowerBound])
    }

    /// The kernel's branches and its `o = c000 + (A) * f.r + (B) * f.g + (C) * f.b;`
    /// assignments, in order.
    private static func gpuSteps(_ body: String) -> [SamplerStep] {
        var steps: [SamplerStep] = []
        for line in lines(Substring(body)) {
            if line.hasPrefix("} else if ("), line.hasSuffix(") {") {
                steps.append(.orBranch(normalized(line.dropFirst(11).dropLast(3))))
            } else if line.hasPrefix("if ("), line.hasSuffix(") {") {
                steps.append(.branch(normalized(line.dropFirst(4).dropLast(3))))
            } else if line == "} else {" {
                steps.append(.otherwise)
            } else if line.hasPrefix("o = c000 + ("), line.hasSuffix(";") {
                let terms = line.dropFirst(11).dropLast().components(separatedBy: " + ")
                guard terms.count == 3 else { continue }
                let suffixes = [" * f.r", " * f.g", " * f.b"]
                guard zip(terms, suffixes).allSatisfy({ $0.hasSuffix($1) }) else { continue }
                let corners = zip(terms, suffixes).map { normalized(Substring($0.dropLast($1.count))) }
                steps.append(.blend(corners[0], corners[1], corners[2]))
            }
        }
        return steps
    }
}
