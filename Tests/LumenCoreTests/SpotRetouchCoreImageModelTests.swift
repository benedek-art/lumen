// SpotRetouchCoreImageModelTests.swift
// S5 on the GPU, modelled on Linux: the spot kernels' arithmetic and the way Core Image
// evaluates and composites them, run against `SpotRetouch`.
//
// WHY THIS EXISTS. The first macOS run of `SpotRetouchGPUParityTests` found that a heal
// spot rewrote the WHOLE picture: 63,358 of the 65,207 pixels of a 331×197 frame outside
// the spot's box moved, and every case was 0.34–0.54 from the reference. Read off the
// lane's log, every moved pixel held the input value of the nearest pixel of the box
// grown by one pixel — pixel (0, 0) held (111, 77), pixel (330, 196) held (153, 119) for
// a box of x 112..<153, y 78..<119. That is a texture of the kernel's output over its
// extent plus a one-pixel margin, read clamp-to-edge across the frame and laid on as
// opaque. The `extent` a general `CIKernel` is applied over is its domain of definition:
// a promise that the image is clear outside it, which Core Image does not enforce. The
// kernel returned the opaque input pixel wherever the spot's alpha was 0 — including in
// that margin — and the `composited(over:)` that laid the spot on the picture spread the
// margin over everything.
//
// THE MODEL below is that behaviour, written down: the kernels transliterated line for
// line from `Kernels.swift` (Core Image's bottom-up frame, the `h − y` flip, linear
// samples at texel centres +0.5 through `clampedToExtent()`), evaluated over the extent
// plus one pixel, the result read clamp-to-edge, then source-over. It is anchored to the
// lane: with the shipped-then-broken shape it reproduces the lane's numbers to 1e-9
// (`testTheModelReproducesTheMacOSLane`), so it is a model of what Core Image did, not of
// what the code hoped. `testTheShippedSpotGraphLeavesThePictureOutsideItsSpots` then asks
// the model what the CURRENT source does — whether the kernel returns clear where alpha
// is 0, whether the graph crops to the box — read from `Kernels.swift` and
// `RenderGraph.swift` as text, because `LumenPipeline` is `#if os(macOS)` (the same
// reason `KernelRosterTests` reads `Kernels.swift`). Comments are stripped before the
// graph is scanned, so prose about the crop cannot satisfy it.
//
// WHAT THIS CANNOT SEE: Core Image itself. The macOS lane's `SpotRetouchGPUParityTests`
// is the check; this is the trace that let the fix be written without a Mac, and the
// tripwire that goes red on Linux if either guard is taken out of the source together.

import XCTest
@testable import LumenCore

final class SpotRetouchCoreImageModelTests: XCTestCase {

    // MARK: - The fixture and cases of SpotRetouchGPUParityTests, verbatim

    private func scene(_ w: Int, _ h: Int) -> ImageBuffer {
        ImageBuffer(width: w, height: h) { u, v in
            let aspect = Double(h) / Double(Swift.max(w, h))
            let width = Double(w) / Double(Swift.max(w, h))
            let first = hypot((u - 0.4) * width, (v - 0.5) * aspect) < 0.03
            let second = hypot((u - 0.12) * width, (v - 0.15) * aspect) < 0.025
            let blemish = first || second ? 0.3 : 0
            return RGB(0.25 + 0.15 * sin(9 * u) * cos(7 * v) + blemish,
                       0.3 + 0.1 * u - 0.05 * v + blemish * 0.5,
                       0.2 + 0.08 * cos(11 * v + 3 * u))
        }
    }

    private func cases() -> [(name: String, spots: [HealSpot])] {
        [
            ("heal, feathered, fractional offset",
             [HealSpot(id: "a", mode: .heal, x: 0.4, y: 0.5, sourceX: 0.613, sourceY: 0.437,
                       radius: 0.06, feather: 50, opacity: 100)]),
            ("clone, hard edge",
             [HealSpot(id: "b", mode: .clone, x: 0.4, y: 0.5, sourceX: 0.2, sourceY: 0.71,
                       radius: 0.05, feather: 0, opacity: 100)]),
            ("heal at half opacity, full feather",
             [HealSpot(id: "c", mode: .heal, x: 0.4, y: 0.5, sourceX: 0.55, sourceY: 0.62,
                       radius: 0.08, feather: 100, opacity: 50)]),
            ("heal sourced off the edge",
             [HealSpot(id: "d", mode: .heal, x: 0.12, y: 0.15, sourceX: 0.03, sourceY: 0.04,
                       radius: 0.05, feather: 40, opacity: 100)]),
            ("two overlapping spots",
             [HealSpot(id: "e", mode: .clone, x: 0.4, y: 0.5, sourceX: 0.7, sourceY: 0.5,
                       radius: 0.06, feather: 30, opacity: 100),
              HealSpot(id: "f", mode: .heal, x: 0.44, y: 0.52, sourceX: 0.3, sourceY: 0.3,
                       radius: 0.05, feather: 60, opacity: 90)]),
        ]
    }

    // MARK: - The model

    /// What the graph does about the domain-of-definition promise.
    struct Guards {
        /// `lumenSpotApply` returns `vec4(0.0)` where alpha is 0.
        var kernelClearOutsideDisc: Bool
        /// `RenderGraph.applySpot` crops the kernel's output to the box before compositing.
        var cropToBox: Bool
    }

    /// A frame in Core Image's orientation: row 0 at the BOTTOM, premultiplied RGBA.
    struct Frame {
        let width: Int, height: Int
        var rgb: [RGB]
        var alpha: [Double]

        init(_ buffer: ImageBuffer) {
            width = buffer.width; height = buffer.height
            rgb = []; alpha = []
            // `CIImage(bitmapData:)` puts the buffer's first row at the top of its extent.
            for j in 0..<height {
                for i in 0..<width { rgb.append(buffer[i, height - 1 - j]); alpha.append(1) }
            }
        }

        func buffer() -> ImageBuffer {
            var out = ImageBuffer(width: width, height: height)
            for y in 0..<height {
                for x in 0..<width { out[x, y] = rgb[(height - 1 - y) * width + x] }
            }
            return out
        }

        /// `sample(src, samplerTransform(src, p))` on `image.clampedToExtent()`, with the
        /// extent at the origin: linear, texel centres at +0.5, edges extended.
        func sample(_ x: Double, _ y: Double) -> RGB {
            func at(_ i: Int, _ j: Int) -> RGB {
                rgb[Swift.min(Swift.max(j, 0), height - 1) * width
                    + Swift.min(Swift.max(i, 0), width - 1)]
            }
            let fx = x - 0.5, fy = y - 0.5
            let i0 = Int(floor(fx)), j0 = Int(floor(fy))
            let tx = fx - Double(i0), ty = fy - Double(j0)
            let a = at(i0, j0).mix(at(i0 + 1, j0), tx)
            let b = at(i0, j0 + 1).mix(at(i0 + 1, j0 + 1), tx)
            return a.mix(b, ty)
        }
    }

    /// `lumenSpotBoundary` at output pixel k (ox = oy = 0).
    private func boundary(_ src: Frame, _ s: SpotRetouch.SpotGeometry, _ k: Int) -> RGB {
        let h = Double(src.height)
        let n = Double(SpotRetouch.boundarySamples), m = SpotRetouch.boundarySubsamples
        let arc = 6.283185307179586 / n
        var acc = RGB.zero
        for j in 0..<m {
            let theta = arc * (Double(k) + (Double(j) + 0.5) / Double(m) - 0.5)
            let ux = cos(theta) * s.radius, uy = sin(theta) * s.radius
            let dv = src.sample(s.cx + ux, h - (s.cy + uy))
            let sv = src.sample(s.sx + ux, h - (s.sy + uy))
            acc = acc + dv - sv
        }
        return acc / Double(m)
    }

    /// `lumenSpotApply` at `destCoord()` = (dx, dy): premultiplied RGBA.
    private func applyKernel(_ src: Frame, _ rim: [RGB], _ s: SpotRetouch.SpotGeometry,
                             _ dcx: Double, _ dcy: Double, _ guards: Guards)
        -> (RGB, Double) {
        let h = Double(src.height)
        let base = src.sample(dcx, dcy)
        let px = dcx, py = h - dcy
        let relx = (px - s.cx) / s.radius, rely = (py - s.cy) / s.radius
        let rho = (relx * relx + rely * rely).squareRoot()
        let a: Double
        if rho >= 1 { a = 0 } else if rho <= s.rin { a = s.opacity } else {
            let t = Swift.min(Swift.max((rho - s.rin) / Swift.max(1 - s.rin, 1e-12), 0), 1)
            a = s.opacity * (1 - t * t * (3 - 2 * t))
        }
        if guards.kernelClearOutsideDisc && a <= 0 { return (.zero, 0) }
        let spx = px + (s.sx - s.cx), spy = py + (s.sy - s.cy)
        var fill = src.sample(spx, h - spy)
        if s.heal && a > 0 {
            let arc = 6.283185307179586 / Double(SpotRetouch.boundarySamples)
            var acc = RGB.zero
            var total = 0.0
            for k in 0..<SpotRetouch.boundarySamples {
                let theta = arc * Double(k)
                let ddx = relx - cos(theta), ddy = rely - sin(theta)
                let w = 1 / Swift.max(ddx * ddx + ddy * ddy, 1e-6)
                acc = acc + rim[k] * w
                total += w
            }
            fill = fill + acc / total
        }
        return (base.mix(fill, a), 1)
    }

    /// `RenderGraph.applySpot`, as Core Image evaluates it.
    private func applySpot(_ image: Frame, _ s: SpotRetouch.SpotGeometry,
                           _ guards: Guards) -> Frame {
        let w = image.width, h = image.height
        let rim = s.heal ? (0..<SpotRetouch.boundarySamples).map { boundary(image, s, $0) }
                         : Array(repeating: RGB.zero, count: SpotRetouch.boundarySamples)
        // The box in Core Image's columns and rows (`ciRect` flips y).
        let bx0 = s.minX, bx1 = s.maxX, by0 = h - s.maxY, by1 = h - s.minY
        // The kernel is evaluated over its extent plus one pixel, kept as a texture.
        let tx0 = bx0 - 1, tx1 = bx1 + 1, ty0 = by0 - 1, ty1 = by1 + 1
        var texture: [[(RGB, Double)]] = []
        for j in ty0..<ty1 {
            texture.append((tx0..<tx1).map {
                applyKernel(image, rim, s, Double($0) + 0.5, Double(j) + 0.5, guards)
            })
        }
        var out = image
        for j in 0..<h {
            for i in 0..<w {
                let inBox = (bx0..<bx1).contains(i) && (by0..<by1).contains(j)
                let (src, sa): (RGB, Double)
                if guards.cropToBox && !inBox {
                    (src, sa) = (.zero, 0)
                } else {
                    // Clamp-to-edge on the texture: what the lane showed.
                    let ti = Swift.min(Swift.max(i, tx0), tx1 - 1) - tx0
                    let tj = Swift.min(Swift.max(j, ty0), ty1 - 1) - ty0
                    (src, sa) = texture[tj][ti]
                }
                // Source-over, premultiplied: S + D·(1 − Sa).
                let index = j * w + i
                out.rgb[index] = src + image.rgb[index] * (1 - sa)
                out.alpha[index] = sa + image.alpha[index] * (1 - sa)
            }
        }
        return out
    }

    private func gpuModel(_ input: ImageBuffer, _ spots: [HealSpot],
                          _ guards: Guards) -> ImageBuffer {
        var frame = Frame(input)
        for spot in spots {
            guard let s = SpotRetouch.resolve(spot, width: input.width,
                                              height: input.height) else { continue }
            frame = applySpot(frame, s, guards)
        }
        return frame.buffer()
    }

    /// True where no spot's alpha reaches: the reference leaves these pixels alone.
    private func untouched(_ x: Int, _ y: Int, _ spots: [HealSpot], _ w: Int, _ h: Int)
        -> Bool {
        spots.allSatisfy { spot in
            guard let s = SpotRetouch.resolve(spot, width: w, height: h) else { return true }
            let qx = (Double(x) + 0.5 - s.cx) / s.radius
            let qy = (Double(y) + 0.5 - s.cy) / s.radius
            return SpotRetouch.alpha(rho: (qx * qx + qy * qy).squareRoot(),
                                     rin: s.rin, opacity: s.opacity) <= 0
        }
    }

    /// Worst difference from the reference, and how many untouched pixels moved at all.
    private func measure(_ input: ImageBuffer, _ spots: [HealSpot], _ guards: Guards)
        -> (worst: Double, movedOutside: Int, gpu: ImageBuffer) {
        let reference = SpotRetouch.apply(input, spots: spots)
        let gpu = gpuModel(input, spots, guards)
        var worst = 0.0, moved = 0
        for y in 0..<input.height {
            for x in 0..<input.width {
                worst = Swift.max(worst, gpu[x, y].maxAbsDifference(reference[x, y]))
                if untouched(x, y, spots, input.width, input.height), gpu[x, y] != input[x, y] {
                    moved += 1
                }
            }
        }
        return (worst, moved, gpu)
    }

    // MARK: - The anchor

    /// The broken shape reproduces the macOS lane's own numbers, so the model is Core
    /// Image's behaviour and not a guess at it. Values from the lane log of 1c6ac52's
    /// parent run (docs/audit-2026-10/ci/ci-SpotRetouchGPUParityTests.txt).
    func testTheModelReproducesTheMacOSLane() throws {
        let broken = Guards(kernelClearOutsideDisc: false, cropToBox: false)
        // Every case the lane ran. The single-spot cases agree to 1e-9; the overlapping
        // pair to 1e-5, because its second spot reads the first one's GPU rounding.
        let lane: [String: Double] = [
            "heal, feathered, fractional offset@256": 0.40102419257164,
            "clone, hard edge@256": 0.39056654274463654,
            "heal at half opacity, full feather@256": 0.43079762160778046,
            "heal sourced off the edge@256": 0.3732494115829468,
            "two overlapping spots@256": 0.3681756854057312,
            "heal, feathered, fractional offset@331": 0.4131138473749161,
            "clone, hard edge@331": 0.40196533501148224,
            "heal at half opacity, full feather@331": 0.4344725012779236,
            "heal sourced off the edge@331": 0.41174502670764923,
            "two overlapping spots@331": 0.38346466422080994,
            "heal, feathered, fractional offset@128": 0.5099508911371231,
            "clone, hard edge@128": 0.48892004787921906,
            "heal at half opacity, full feather@128": 0.5351442769169807,
            "heal sourced off the edge@128": 0.4094025194644928,
            "two overlapping spots@128": 0.33870014548301697,
        ]
        for size in [(256, 256), (331, 197), (128, 320)] {
            let input = scene(size.0, size.1)
            for (name, spots) in cases() {
                let expected = try XCTUnwrap(lane["\(name)@\(size.0)"])
                XCTAssertEqual(measure(input, spots, broken).worst, expected,
                               accuracy: spots.count > 1 ? 1e-5 : 1e-9,
                               "\(name) @\(size.0)x\(size.1)")
            }
        }
        // The lane's corner pixels: the box's one-pixel margin, clamped outward.
        let input = scene(331, 197)
        let gpu = measure(input, cases()[0].spots, broken).gpu
        XCTAssertEqual(gpu[0, 0], input[111, 77])
        XCTAssertEqual(gpu[330, 0], input[153, 77])
        XCTAssertEqual(gpu[0, 196], input[111, 119])
        XCTAssertEqual(gpu[330, 196], input[153, 119])
        XCTAssertEqual(gpu[0, 0].r, 0.23477379977703094, accuracy: 1e-12, "lane log, (0, 0)")
    }

    /// Either guard alone keeps the promise; the source carries both.
    func testEitherGuardAloneKeepsThePictureOutsideItsSpots() {
        let input = scene(331, 197)
        for guards in [Guards(kernelClearOutsideDisc: true, cropToBox: false),
                       Guards(kernelClearOutsideDisc: false, cropToBox: true)] {
            for (name, spots) in cases() {
                let result = measure(input, spots, guards)
                XCTAssertEqual(result.movedOutside, 0, "\(name), \(guards)")
                XCTAssertLessThan(result.worst, 1e-6, "\(name), \(guards)")
            }
        }
    }

    // MARK: - The source, under the model

    func testTheShippedSpotGraphLeavesThePictureOutsideItsSpots() throws {
        let guards = try Self.shippedGuards()
        for size in [(256, 256), (331, 197), (128, 320)] {
            let input = scene(size.0, size.1)
            for (name, spots) in cases() {
                let result = measure(input, spots, guards)
                XCTAssertEqual(result.movedOutside, 0,
                               "\(name) @\(size.0)x\(size.1): pixels no spot reaches moved")
                // Same arithmetic as the reference on both sides of the flip: the model
                // is exact, so anything above rounding is a coordinate error.
                XCTAssertLessThan(result.worst, 1e-6,
                                  "\(name) @\(size.0)x\(size.1): \(result.worst) from the reference")
            }
        }
    }

    // MARK: - Reading the source

    private static func pipelineSource(_ file: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/LumenPipeline")
        return try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
    }

    /// Lines with their `//` comments removed. Kernel source has no `//` in it.
    private static func stripComments(_ text: Substring) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            guard let r = line.range(of: "//") else { return line }
            return line[..<r.lowerBound]
        }.joined(separator: "\n")
    }

    static func shippedGuards() throws -> Guards {
        let kernels = try pipelineSource("Kernels.swift")
        let start = try XCTUnwrap(kernels.range(of: "static let spotApplySource = \"\"\""))
        let rest = kernels[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "\"\"\""))
        let body = String(rest[..<end.lowerBound]).replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
        // The clear return must come after alpha is final and before anything is sampled
        // for the fill — i.e. it is what every alpha-0 pixel returns.
        var clear = false
        if let ret = body.range(of: "if(a<=0.0){returnvec4(0.0);}"),
           let fill = body.range(of: "vec3fill="),
           let alphaDone = body.range(of: "a=opacity*(1.0-t*t*(3.0-2.0*t));}") {
            clear = alphaDone.upperBound <= ret.lowerBound && ret.upperBound <= fill.lowerBound
        }

        let graph = try pipelineSource("RenderGraph.swift")
        let fn = try XCTUnwrap(graph.range(of: "static func applySpot("))
        let tail = graph[fn.upperBound...]
        let fnEnd = try XCTUnwrap(tail.range(of: "\n    }\n"))
        let code = stripComments(tail[..<fnEnd.lowerBound])
            .replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "")
        let crop = code.contains("returnapplied.cropped(to:box).composited(over:image)")
        return Guards(kernelClearOutsideDisc: clear, cropToBox: crop)
    }

    /// The scan is not vacuous: it finds both guards in today's source.
    func testTheScanFindsTheGuards() throws {
        let guards = try Self.shippedGuards()
        XCTAssertTrue(guards.kernelClearOutsideDisc, "lumenSpotApply is not clear at alpha 0")
        XCTAssertTrue(guards.cropToBox, "applySpot does not crop to the box")
    }
}
