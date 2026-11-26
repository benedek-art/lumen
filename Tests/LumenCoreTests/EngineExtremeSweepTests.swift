// EngineExtremeSweepTests.swift
// Extreme recipes through the reference renderer on frames built from the inputs that
// break colour maths: black, white, saturated primaries, 1e3 and 1e-6 scene-linear,
// and the negative values a wide-gamut source carries. Every pixel out must be finite
// and inside the display range.

import XCTest
@testable import LumenCore

final class EngineExtremeSweepTests: XCTestCase {

    /// One pixel per hostile input, laid out on a strip so the spatial stages see
    /// them as neighbours of one another.
    static let hostilePixels: [RGB] = {
        var p: [RGB] = []
        for v in [0.0, 1e-6, 1e-4, 0.01, 0.18, 1, 4, 16, 100, 1e3] {
            p.append(RGB(gray: v))
        }
        for level in [1e-6, 0.05, 1.0, 100, 1e3] {
            p.append(RGB(level, 0, 0))
            p.append(RGB(0, level, 0))
            p.append(RGB(0, 0, level))
            p.append(RGB(0, level, level))
            p.append(RGB(level, 0, level))
            p.append(RGB(level, level, 0))
        }
        // Negative components: ProPhoto / AP0 primaries carried into Rec.2020, a
        // white balance with negative off-diagonals, and an all-negative pixel.
        p += [RGB(-0.05, 0.3, 0.8), RGB(1.2, -0.1, -0.02), RGB(-0.02, 0.9, -0.05),
              RGB(-0.1, -0.05, 1.4), RGB(-0.5, -0.5, -0.5), RGB(-1e-6, 0, 0),
              RGB(-1e3, 1e3, 0), RGB(1e3, -0.2, -0.2), RGB(-0.001, -0.001, 0.002),
              RGB(5, -1, -1), RGB(0.4, 0.2, -0.3)]
        return p
    }()

    static func hostileFrame(width: Int = 16) -> ImageBuffer {
        let pixels = hostilePixels
        let height = (pixels.count + width - 1) / width
        var image = ImageBuffer(width: width, height: height)
        for i in 0..<(width * height) {
            image[i % width, i / width] = pixels[i % pixels.count]
        }
        return image
    }

    struct Breakage: CustomStringConvertible {
        var label: String
        var worst: RGB
        var input: RGB
        var why: String
        var description: String { "\(label): \(why) out \(worst) for in \(input)" }
    }

    /// Finite, at or above black, at or below display white (plus grain headroom).
    static func check(_ label: String, plan: RenderPlan, frame: ImageBuffer,
                      headroom: Double = 1.0) -> Breakage? {
        let out = ReferenceRenderer.render(frame, plan: plan)
        let white = plan.finishScale
        for y in 0..<out.height {
            for x in 0..<out.width {
                let c = out[x, y]
                let input = frame[x, y]
                if !c.isFinite {
                    return Breakage(label: label, worst: c, input: input, why: "non-finite")
                }
                if c.minComponent < -1e-4 {
                    return Breakage(label: label, worst: c, input: input, why: "below black")
                }
                if c.maxComponent > white * headroom + 1e-4 {
                    return Breakage(label: label, worst: c, input: input, why: "above white")
                }
            }
        }
        return nil
    }

    func testEverySingleControlAtBothEndsRendersAFinitePicture() {
        let frame = Self.hostileFrame()
        var broken: [String] = []
        for spec in ProofRegistry.all {
            for v in [spec.low, spec.high] {
                var recipe = Recipe()
                spec.apply(&recipe, v)
                let grain = recipe.look.grain.map { !$0.isIdentity } ?? false
                    || (recipe.look.filmLab?.grain.amount ?? 0) > 0
                if let b = Self.check("\(spec.id)=\(v)", plan: RenderPlan(recipe: recipe, lutSize: 17),
                                      frame: frame, headroom: grain ? 1.2 : 1.0) {
                    broken.append(b.description)
                }
            }
        }
        XCTAssertTrue(broken.isEmpty, broken.joined(separator: "\n"))
    }

    struct SplitMix {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }

    static func extremeRecipe(_ rng: inout SplitMix, density: Double) -> Recipe {
        var recipe = Recipe()
        for spec in ProofRegistry.all.shuffled(using: &rng) where rng.unit() < density {
            let pick = rng.unit()
            let v = pick < 0.45 ? spec.low : (pick < 0.9 ? spec.high
                : spec.low + (spec.high - spec.low) * rng.unit())
            spec.apply(&recipe, v)
        }
        return recipe
    }

    func testAllLowAllHighAndRandomExtremeCombinations() {
        let frame = Self.hostileFrame()
        var broken: [String] = []
        var low = Recipe(), high = Recipe()
        for spec in ProofRegistry.all {
            spec.apply(&low, spec.low)
            spec.apply(&high, spec.high)
        }
        for (name, r) in [("all-low", low), ("all-high", high)] {
            if let b = Self.check(name, plan: RenderPlan(recipe: r, lutSize: 17), frame: frame,
                                  headroom: 1.2) { broken.append(b.description) }
        }
        var rng = SplitMix(state: 0x5EED)
        for i in 0..<40 {
            let r = Self.extremeRecipe(&rng, density: i % 2 == 0 ? 0.08 : 0.3)
            if let b = Self.check("combo\(i)", plan: RenderPlan(recipe: r, lutSize: 17), frame: frame,
                                  headroom: 1.2) {
                broken.append(b.description + "\n   " + Self.describe(r))
            }
        }
        XCTAssertTrue(broken.isEmpty, broken.joined(separator: "\n"))
    }

    static func describe(_ r: Recipe) -> String {
        guard let data = try? JSONEncoder().encode(r),
              let any = try? JSONSerialization.jsonObject(with: data),
              let base = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Recipe()))
        else { return "?" }
        var diffs: [String] = []
        func walk(_ a: Any, _ b: Any?, _ path: String) {
            if let d = a as? [String: Any] {
                let bd = b as? [String: Any]
                for (k, v) in d.sorted(by: { $0.key < $1.key }) { walk(v, bd?[k], path + "." + k) }
            } else if let arr = a as? [Any] {
                let barr = b as? [Any]
                for (i, v) in arr.enumerated() {
                    walk(v, (barr?.count ?? 0) > i ? barr?[i] : nil, path + ".\(i)")
                }
            } else if "\(a)" != "\(b.map { "\($0)" } ?? "nil")" {
                diffs.append("\(path.dropFirst())=\(a)")
            }
        }
        walk(any, base, "")
        return diffs.joined(separator: " ")
    }

    static var densePixels: [RGB] {
        var out = hostilePixels
        for ev in stride(from: -20.0, through: 12.0, by: 0.5) {
            let v = 0.18 * pow(2, ev)
            for h in stride(from: 0.0, to: 360, by: 15) {
                let a = h * .pi / 180
                for sat in [0.2, 0.9, 1.4] {
                    out.append(RGB(v * (1 + sat * cos(a)), v * (1 + sat * cos(a - 2.094)),
                                   v * (1 + sat * cos(a + 2.094))))
                }
            }
        }
        return out
    }

    func testEachStageStaysFiniteOnHostileInput() {
        var rng = SplitMix(state: 0xC0105)
        let pixels = Self.densePixels
        let hostile = Set(Self.hostilePixels.map { "\($0)" })
        var broken: [String: Int] = [:]
        var examples: [String: String] = [:]
        for i in 0..<30 {
            let recipe = i == 0 ? Recipe() : Self.extremeRecipe(&rng, density: i % 2 == 0 ? 0.1 : 0.35)
            let plan = RenderPlan(recipe: recipe, lutSize: 9)
            let develop = recipe.develop, look = recipe.look
            let color = ColorEngine(mixer: develop.mixer, pointColors: develop.pointColors,
                                    color: develop.color, primaries: look.primaries, bw: look.bw)
            let grade = GradeEngine(wheels: look.wheels, printerLights: look.printerLights,
                                    whiteAnchorEV: plan.tone.whiteAnchorEV,
                                    blackAnchorEV: plan.tone.blackAnchorEV)
            let curve = CurveStack(develop.curve)
            func note(_ stage: String, _ input: RGB, _ out: RGB) {
                broken[stage, default: 0] += 1
                if examples[stage] == nil {
                    examples[stage] = "in \(input) -> \(out)  recipe \(Self.describe(recipe))"
                }
            }
            for p in pixels {
                var c = plan.linear.apply(p)
                if !plan.toneIsIdentity { c = c * plan.toneStageGain(c, space: .rec2020) }
                if !c.isFinite { note("tone", p, c); continue }
                let exact = plan.colorStage.apply(c)
                if !exact.isFinite { note("colorStage", c, exact) }
                let analytic = color.apply(c)
                if !analytic.isFinite { note("colorEngine", c, analytic) }
                let g = grade.apply(exact)
                if !g.isFinite { note("grade", exact, g); continue }
                let formed = plan.filmChain.map { $0.apply(g) }
                    ?? plan.displayTransform.apply(g, gamut: RenderPlan.sharedGamutBoundary)
                if !formed.isFinite { note("display", g, formed); continue }
                if formed.minComponent < -1e-9 || formed.maxComponent > plan.displayWhite * 1.0001 {
                    note("display-range", g, formed)
                }
                let fin = curve.apply(formed, white: plan.displayWhite)
                if !fin.isFinite { note("curve", formed, fin) }
                guard hostile.contains("\(p)") else { continue }
                let ex = plan.exactColor(p)
                if !ex.isFinite { note("exactColor", p, ex) }
                if ex.minComponent < -1e-9 || ex.maxComponent > plan.displayWhite * 1.0001 {
                    note("exactColor-range", p, ex)
                }
            }
        }
        let report = broken.keys.sorted().map { "\($0): \(broken[$0]!)  e.g. \(examples[$0]!)" }
        XCTAssertTrue(broken.isEmpty, report.joined(separator: "\n"))
    }

    /// Every local slider at its end, at Amount 200, through each blend mode and on an
    /// HDR white. No local curve: its Amount above 100 extrapolates by contract
    /// (`testLocalCurveAmountScalesTheDisplacement`) and leaves the range by design.
    func testMasksAtTheirExtremesRenderAFinitePicture() {
        let frame = Self.hostileFrame()
        var rng = SplitMix(state: 0xBEEF)
        var broken: [String] = []
        for i in 0..<12 {
            var recipe = Self.extremeRecipe(&rng, density: 0.15)
            var component = MaskComponent(op: .add, kind: .radial)
            component.center = [0.5, 0.5]
            component.radii = [0.9, 0.9]
            component.feather = 20
            var mask = Mask(name: "m")
            mask.components = [component]
            let e = i % 2 == 0 ? 1.0 : -1.0
            mask.amount = 200
            mask.adjust.exposure = 4 * e
            mask.adjust.contrast = 100 * e
            mask.adjust.highlights = -100 * e
            mask.adjust.shadows = 100 * e
            mask.adjust.whites = 100 * e
            mask.adjust.blacks = -100 * e
            mask.adjust.sat = 100 * e
            mask.adjust.vibrance = 100 * e
            mask.adjust.hue = 180 * e
            if i % 3 == 0 {
                mask.adjust.kelvin = i % 2 == 0 ? 2000 : 50000
                mask.adjust.kelvinTint = 150 * e
            } else {
                mask.adjust.temp = 100 * e
                mask.adjust.tint = 100 * e
            }
            if i % 4 < 2 {
                mask.adjust.colorTint = [0.9, 0.1, 0.05]
                mask.adjust.colorTintStrength = 100
            }
            if i % 5 == 0 {
                var wheels = recipe.look.wheels
                wheels.mid.sat = 1
                wheels.mid.lum = e
                mask.adjust.wheels = wheels
            }
            mask.blend = [MaskBlend.normal, .luminosity, .color][i % 3]
            recipe.masks = [mask]
            let white: Double? = i % 4 == 0 ? 400 : nil
            let plan = RenderPlan(recipe: recipe, displayWhiteTarget: white, lutSize: 17)
            if let b = Self.check("mask\(i) blend \(mask.blend) white \(white ?? 100)",
                                  plan: plan, frame: frame, headroom: 1.25) {
                broken.append(b.description + "\n   " + Self.describe(recipe))
            }
        }
        XCTAssertTrue(broken.isEmpty, broken.joined(separator: "\n"))
    }
}

extension EngineExtremeSweepTests.SplitMix: RandomNumberGenerator {}
