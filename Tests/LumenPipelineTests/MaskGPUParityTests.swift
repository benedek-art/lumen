// MaskGPUParityTests.swift
// docs/36 §1.7 — "behind parity tests" was a phrase six times and never a harness.
//
// This is the harness. Every parametric mask shape × three resolutions, the GPU's
// closed-form path against `MaskRaster`'s f64 reference, on a worst-pixel tolerance.
// One of the three resolutions is deliberately not a power of two and not the same
// aspect as the others, because the two implementations agree trivially on a square
// 256 and disagree — if they are going to — on the long-edge normalization, which only
// a non-square, non-round extent exercises.
//
// The fast path exists to end the drag tail: a gradient evaluated in a shader never
// enters the raster cache, so it can never be served one gesture stale. It is only
// allowed to exist while this file is green, because a mask that is FAST and WRONG is
// strictly worse than the slow one it replaced.
//
// `testEveryEligibleShapeIsCovered` is the guard on the guard: add a parametric shape
// to `MaskGPU` without adding it to the table below and the suite fails, rather than
// shipping one shape nobody compared.

#if os(macOS)

import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

final class MaskGPUParityTests: XCTestCase {

    /// Square, wide-and-odd, and tall. The middle one is the one that matters.
    private let sizes: [(w: Int, h: Int)] = [(256, 256), (331, 197), (128, 320)]

    private let context = CIContext(options: [.workingColorSpace: NSNull(),
                                              .outputColorSpace: NSNull()])

    // MARK: - Fixtures

    private func linear(_ x0: Double, _ y0: Double,
                        _ x1: Double, _ y1: Double,
                        op: MaskOp = .add, invert: Bool = false,
                        amount: Double = 100) -> MaskComponent {
        var c = MaskComponent(op: op, kind: .linear, amount: amount, invert: invert)
        c.line = [x0, y0, x1, y1]
        return c
    }

    private func radial(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double,
                        rotation: Double = 0, feather: Double = 50,
                        op: MaskOp = .add, invert: Bool = false,
                        amount: Double = 100) -> MaskComponent {
        var c = MaskComponent(op: op, kind: .radial, amount: amount, invert: invert)
        c.center = [cx, cy]
        c.radii = [rx, ry]
        c.rotation = rotation
        c.feather = feather
        return c
    }

    /// The table. Each entry is one mask the fast path claims to evaluate exactly.
    private func cases() -> [(name: String, mask: Mask)] {
        var out: [(String, Mask)] = []
        out.append(("vertical gradient",
                    Mask(id: "a", components: [linear(0.5, 0.8, 0.5, 0.2)])))
        out.append(("diagonal gradient",
                    Mask(id: "b", components: [linear(0.15, 0.1, 0.85, 0.9)])))
        out.append(("degenerate gradient",
                    Mask(id: "c", components: [linear(0.4, 0.4, 0.4, 0.4)])))
        out.append(("circle, default feather",
                    Mask(id: "d", components: [radial(0.5, 0.5, 0.3, 0.3)])))
        out.append(("hard ellipse",
                    Mask(id: "e", components: [radial(0.4, 0.55, 0.28, 0.16,
                                                      feather: 0)])))
        out.append(("soft ellipse",
                    Mask(id: "f", components: [radial(0.5, 0.5, 0.3, 0.22,
                                                      feather: 100)])))
        // The rotation case is the one that catches a shader doing its trigonometry in
        // normalized coordinates instead of long-edge units: at 45° on a 331×197 frame
        // the two differ by degrees, not by rounding.
        out.append(("rotated ellipse",
                    Mask(id: "g", components: [radial(0.45, 0.5, 0.34, 0.15,
                                                      rotation: 45, feather: 40)])))
        out.append(("rotated the other way",
                    Mask(id: "h", components: [radial(0.5, 0.5, 0.3, 0.12,
                                                      rotation: -63, feather: 25)])))
        out.append(("tiny ellipse, pixel guard",
                    Mask(id: "i", components: [radial(0.5, 0.5, 0.004, 0.004,
                                                      feather: 100)])))
        out.append(("inverted component",
                    Mask(id: "j", components: [radial(0.5, 0.5, 0.3, 0.3,
                                                      invert: true)])))
        out.append(("partial amount",
                    Mask(id: "k", components: [radial(0.5, 0.5, 0.3, 0.3,
                                                      amount: 37)])))
        out.append(("union",
                    Mask(id: "l", components: [radial(0.35, 0.5, 0.2, 0.2),
                                               radial(0.65, 0.5, 0.2, 0.2)])))
        out.append(("subtract",
                    Mask(id: "m", components: [radial(0.5, 0.5, 0.35, 0.35),
                                               radial(0.5, 0.5, 0.15, 0.15,
                                                      op: .subtract)])))
        out.append(("intersect",
                    Mask(id: "n", components: [radial(0.4, 0.5, 0.25, 0.25),
                                               radial(0.6, 0.5, 0.25, 0.25,
                                                      op: .intersect)])))
        out.append(("stack opening with subtract stays empty",
                    Mask(id: "o", components: [radial(0.5, 0.5, 0.3, 0.3,
                                                      op: .subtract)])))
        out.append(("gradient intersected with an ellipse",
                    Mask(id: "p", components: [linear(0.2, 0.8, 0.8, 0.2),
                                               radial(0.5, 0.5, 0.3, 0.3,
                                                      op: .intersect)])))
        var inverted = Mask(id: "q", components: [radial(0.5, 0.5, 0.3, 0.3)])
        inverted.invert = true
        out.append(("whole-mask invert", inverted))
        var both = Mask(id: "r", components: [linear(0.5, 0.9, 0.5, 0.1),
                                              radial(0.5, 0.5, 0.25, 0.25,
                                                     op: .subtract, invert: true)])
        both.invert = true
        out.append(("everything at once", both))
        return out
    }

    // MARK: - The comparison

    /// The GPU alpha, read back as a plane at the same extent the reference used.
    private func gpuPlane(_ mask: Mask, _ size: (w: Int, h: Int)) throws -> Plane {
        let extent = CGRect(x: 0, y: 0, width: size.w, height: size.h)
        let image = try XCTUnwrap(MaskGPU.alpha(for: mask, extent: extent),
                                  "the fast path refused a mask the table says is eligible")
        var bytes = [Float](repeating: 0, count: size.w * size.h * 4)
        bytes.withUnsafeMutableBytes { raw in
            context.render(image, toBitmap: raw.baseAddress!,
                           rowBytes: size.w * 16, bounds: extent,
                           format: .RGBAf, colorSpace: nil)
        }
        var plane = Plane(width: size.w, height: size.h)
        for i in 0..<(size.w * size.h) { plane.values[i] = bytes[i * 4] }
        return plane
    }

    private func worst(_ a: Plane, _ b: Plane) -> (delta: Double, x: Int, y: Int) {
        var worst = 0.0, wx = 0, wy = 0
        for y in 0..<a.height {
            for x in 0..<a.width {
                let d = abs(a[x, y] - b[x, y])
                if d > worst { worst = d; wx = x; wy = y }
            }
        }
        return (worst, wx, wy)
    }

    func testEveryParametricShapeMatchesTheReferenceAtEveryResolution() throws {
        try XCTSkipUnless(KernelLibrary.parametricMasksAvailable, "kernels unavailable")
        for (name, mask) in cases() {
            for size in sizes {
                let reference = MaskRaster.combine(mask: mask,
                                                   size: (width: size.w, height: size.h))
                let gpu = try gpuPlane(mask, size)
                let (delta, x, y) = worst(reference, gpu)
                XCTAssertLessThan(delta, MaskGPU.parityTolerance,
                                  "\(name) at \(size.w)×\(size.h): worst \(delta) at "
                                      + "(\(x), \(y)) — reference \(reference[x, y]), "
                                      + "gpu \(gpu[x, y])")
            }
        }
    }

    /// A vertical gradient varies down the frame, so a mirrored read shows up as a
    /// difference of nearly 1 rather than as rounding. Asserted separately from the
    /// sweep because it is the failure this whole path is most likely to have, and a
    /// named test says so where a tolerance number does not.
    func testTheGPUAlphaIsNotVerticallyMirrored() throws {
        try XCTSkipUnless(KernelLibrary.parametricMasksAvailable, "kernels unavailable")
        let mask = Mask(id: "v", components: [linear(0.5, 0.9, 0.5, 0.1)])
        let size = (w: 64, h: 96)
        let reference = MaskRaster.combine(mask: mask, size: (width: size.w, height: size.h))
        let gpu = try gpuPlane(mask, size)
        let top = 4, bottom = size.h - 5
        XCTAssertGreaterThan(abs(reference[32, top] - reference[32, bottom]), 0.5,
                             "the fixture must vary down the frame, or this proves nothing")
        XCTAssertEqual(gpu[32, top], reference[32, top], accuracy: 0.01)
        XCTAssertEqual(gpu[32, bottom], reference[32, bottom], accuracy: 0.01)
    }

    /// The extent a render actually hands it does not start at the origin.
    func testAnOffsetExtentDoesNotShiftTheMask() throws {
        try XCTSkipUnless(KernelLibrary.parametricMasksAvailable, "kernels unavailable")
        let mask = Mask(id: "o", components: [radial(0.3, 0.4, 0.2, 0.25)])
        let size = (w: 96, h: 72)
        let reference = MaskRaster.combine(mask: mask, size: (width: size.w, height: size.h))
        let extent = CGRect(x: 37, y: -19, width: size.w, height: size.h)
        let image = try XCTUnwrap(MaskGPU.alpha(for: mask, extent: extent))
        var bytes = [Float](repeating: 0, count: size.w * size.h * 4)
        bytes.withUnsafeMutableBytes { raw in
            context.render(image, toBitmap: raw.baseAddress!,
                           rowBytes: size.w * 16, bounds: extent,
                           format: .RGBAf, colorSpace: nil)
        }
        var plane = Plane(width: size.w, height: size.h)
        for i in 0..<(size.w * size.h) { plane.values[i] = bytes[i * 4] }
        XCTAssertLessThan(worst(reference, plane).delta, MaskGPU.parityTolerance)
    }

    // MARK: - What the fast path must refuse

    func testAnythingNeedingThePictureOrTheChainIsRefused() {
        var luma = MaskComponent(op: .add, kind: .lumaRange)
        luma.lo = 0.2
        luma.hi = 0.8
        XCTAssertFalse(MaskGPU.isParametric(Mask(id: "x", components: [luma])),
                       "a band reads the picture; it is not a closed form")

        var brush = MaskComponent(op: .add, kind: .brush)
        brush.strokesRef = "blob:xxh64:0000000000000000"
        XCTAssertFalse(MaskGPU.isParametric(Mask(id: "y", components: [brush])))

        var refined = Mask(id: "z", components: [radial(0.5, 0.5, 0.3, 0.3)])
        refined.refine.feather = 10
        XCTAssertFalse(MaskGPU.isParametric(refined),
                       "the refinement chain is a guided filter and a distance "
                           + "transform; those legitimately need the CPU")

        var softened = Mask(id: "z2", components: [radial(0.5, 0.5, 0.3, 0.3)])
        softened.refine.blur = 5
        XCTAssertFalse(MaskGPU.isParametric(softened))

        XCTAssertFalse(MaskGPU.isParametric(Mask(id: "empty", components: [])),
                       "an empty stack has nothing to evaluate")

        var malformed = MaskComponent(op: .add, kind: .radial)
        malformed.center = [0.5, 0.5]
        malformed.radii = [0, 0]
        XCTAssertFalse(MaskGPU.isParametric(Mask(id: "bad", components: [malformed])))
    }

    /// Add a parametric shape to `MaskGPU` and forget the table, and this fails.
    func testEveryEligibleShapeIsCovered() {
        let covered = Set(cases().flatMap { $0.mask.components.map(\.kind) })
        for kind in MaskKind.allParametricCandidates {
            var probe = MaskComponent(op: .add, kind: kind)
            switch kind {
            case .linear: probe.line = [0.2, 0.2, 0.8, 0.8]
            case .radial:
                probe.center = [0.5, 0.5]
                probe.radii = [0.3, 0.3]
            default: break
            }
            guard MaskGPU.isParametric(Mask(id: "probe", components: [probe])) else {
                continue
            }
            XCTAssertTrue(covered.contains(kind),
                          "\(kind) is eligible for the fast path and has no case in "
                              + "this file's table — it would ship uncompared")
        }
    }
}

/// The kinds this file probes for eligibility. Every mask kind, so a new one that
/// happens to be accepted by `MaskGPU.isParametric` cannot escape the coverage test by
/// not being listed.
extension MaskKind {
    static var allParametricCandidates: [MaskKind] {
        [.brush, .linear, .radial, .lumaRange, .colorRange, .similarity, .similarityLine,
         .aiSubject, .aiSky, .aiBackground, .aiObject, .aiPerson, .aiLandscape,
         .depthRange, .maskRef]
    }
}

#endif
