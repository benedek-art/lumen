// RenderGraph+Lens.swift
// WS-28: the GPU twin of `LensStage` (LumenCore/Engine/LensStage.swift) and the
// per-photograph inputs it needs. The kernel sources live in LumenCore beside their
// Swift twins (`LensKernelSource`); this file only compiles and chains them.

#if os(macOS)

import CoreImage
import Foundation
import LumenCore

extension KernelLibrary {
    // General: the warp samples R and B away from the pixel it writes, and the window
    // pass reads a neighbourhood. The other two read only their own pixel.
    public static let lensWarp = CIKernel(source: LensKernelSource.lens)
    public static let defringeLogLuma = CIColorKernel(source: LensKernelSource.defringeLogLuma)
    public static let defringeWindow = CIKernel(source: LensKernelSource.defringeWindow)
    public static let defringeApply = CIColorKernel(source: LensKernelSource.defringeApply)

    /// The lens kernels that failed to compile. Not yet on `unavailableKernels` (that
    /// roster is append-only and owned by WS-58; docs/quality/lanes/WS-28/NEEDS.md).
    public static var unavailableLensKernels: [String] {
        let all: [(String, CIKernel?)] = [
            ("lensWarp", lensWarp), ("defringeLogLuma", defringeLogLuma),
            ("defringeWindow", defringeWindow), ("defringeApply", defringeApply),
        ]
        return all.filter { $0.1 == nil }.map(\.0)
    }
}

extension RenderGraph {

    /// The lens stage, between S3 and S5. The twin of `LensStage.apply`.
    func applyLens(_ input: CIImage, plan: RenderPlan) -> CIImage {
        let lens = plan.recipe.develop.geometry.lens
        guard !LensStage.isIdentity(lens, inputs: lensInputs) else { return input }
        let extent = input.extent
        var image = input

        let ca = lens.removeCA ? lensInputs.lateralCA.flatMap { $0.isIdentity ? nil : $0 } : nil
        let vig = lens.profile ? lensInputs.vignette : nil
        if ca != nil || vig != nil {
            let model = ca ?? LateralCAModel()
            let halfDiagonal = 0.5 * (extent.width * extent.width
                                      + extent.height * extent.height).squareRoot()
            let reach = Int(model.maxShiftPixels(halfDiagonal: Double(halfDiagonal)).rounded(.up)) + 3
            let v = vig ?? VignetteGain(a: 0, b: 0, c: 0)
            if let warped = KernelLibrary.applyNeighbourhood(
                KernelLibrary.lensWarp, extent: extent, reach: CGFloat(reach),
                [Self.clamped(image),
                 CIVector(x: extent.midX, y: extent.midY),
                 Float(1 / halfDiagonal),
                 CIVector(x: CGFloat(model.red.k0), y: CGFloat(model.red.k2)),
                 CIVector(x: CGFloat(model.blue.k0), y: CGFloat(model.blue.k2)),
                 CIVector(x: CGFloat(v.a), y: CGFloat(v.b), z: CGFloat(v.c),
                          w: vig == nil ? 0 : 1)]) {
                image = warped
            }
        }

        if let d = lens.defringe {
            let p = DefringeParams(d, longEdge: Int(Swift.max(extent.width, extent.height)))
            if !p.isIdentity, let fringed = Self.applyDefringe(image, params: p) {
                image = fringed
            }
        }
        return image
    }

    static func applyDefringe(_ image: CIImage, params p: DefringeParams) -> CIImage? {
        let extent = image.extent
        guard let logY = KernelLibrary.apply(KernelLibrary.defringeLogLuma, extent: extent,
                                             [image]),
              let rows = KernelLibrary.applyNeighbourhood(
                KernelLibrary.defringeWindow, extent: extent, reach: CGFloat(p.radius),
                [clamped(logY), CIVector(x: 1, y: 0), Float(p.radius)]),
              let window = KernelLibrary.applyNeighbourhood(
                KernelLibrary.defringeWindow, extent: extent, reach: CGFloat(p.radius),
                [clamped(rows), CIVector(x: 0, y: 1), Float(p.radius)])
        else { return nil }
        return KernelLibrary.apply(KernelLibrary.defringeApply, extent: extent, [
            image, window,
            CIVector(x: CGFloat(p.purpleStrength), y: CGFloat(p.purpleLo),
                     z: CGFloat(p.purpleHi), w: 0),
            CIVector(x: CGFloat(p.greenStrength), y: CGFloat(p.greenLo),
                     z: CGFloat(p.greenHi), w: 0),
        ])
    }
}

// MARK: - Per-photograph inputs

/// Measured once per file and kept: the lateral-CA model and the embedded vignetting
/// record (from the file's bytes).
///
/// The CA model is MEASURED ON NATIVE PIXELS, whatever decode the render that asks
/// for it is using. Tiles are ranked on a small readback of that decode and measured on
/// native-resolution tiles rendered from a full-size decode the cache opens itself
/// (lazily evaluated, so only the few hundred tiles are ever developed). The estimate
/// is not scale-consistent on real photographs: 1840 read 0.48 px of red CA measured at
/// native size and 0.81 px measured on a 2560 or 6144 px decode, and the independent
/// tool's residual crosses zero at 0.46 (WS-28 REPORT, verifier round 1). Measuring at
/// one fixed scale also means a preview and its export are corrected by the same model.
public final class LensInputsCache: @unchecked Sendable {
    public static let shared = LensInputsCache()

    /// Below this decode long edge nothing is measured; the render uses what an
    /// earlier, larger decode measured, or nothing.
    public static let minimumMeasureLongEdge: CGFloat = 1200
    /// The ranking readback: tiles are chosen on this, measured elsewhere.
    public static let rankingLongEdge: CGFloat = 2048

    private let lock = NSLock()
    private var held: [URL: LensInputs] = [:]
    private var order: [URL] = []
    private let limit = 64

    public func inputs(url: URL, decoded: CIImage, context: CIContext) -> LensInputs {
        lock.lock()
        if let hit = held[url] { lock.unlock(); return hit }
        lock.unlock()

        let vignette = EmbeddedLensProfile.read(url: url)?.gainPolynomial
        let extent = decoded.extent
        let long = Swift.max(extent.width, extent.height)
        guard long >= Self.minimumMeasureLongEdge else {
            // Not cached: a bigger decode will come and measure.
            return LensInputs(lateralCA: nil, vignette: vignette)
        }
        let ca = Self.measure(url: url, decoded: decoded, context: context)
        let result = LensInputs(lateralCA: ca, vignette: vignette)

        lock.lock()
        // Two first renders can race here; both measured the same native pixels, so
        // whichever lands is the same model.
        held[url] = result
        order.removeAll { $0 == url }
        order.append(url)
        while order.count > limit { held.removeValue(forKey: order.removeFirst()) }
        lock.unlock()
        return result
    }

    static func measure(url: URL, decoded: CIImage, context: CIContext) -> LateralCAModel? {
        func zeroed(_ image: CIImage) -> CIImage {
            image.transformed(by: CGAffineTransform(translationX: -image.extent.origin.x,
                                                    y: -image.extent.origin.y))
        }
        // The native decode: the same kind of source the app opens for this file, at
        // scale 1, with the neutral recipe (camera-reference WB, profile on).
        let source: (any ImageSource)? = PhotoFormats.isRendered(url)
            ? try? RenderedImageSource(url: url) : try? AppleRawSource(url: url)
        defer { if let raw = source as? AppleRawSource { _ = raw.releaseDecodes() } }
        guard let full = source?.decode(recipe: Recipe(), draft: false, scaleFactor: 1.0)
        else {
            // No file behind the URL (a synthetic source): measure what was handed in.
            return PipelineRenderer.buffer(from: zeroed(decoded), context: context)
                .flatMap(LateralCAEstimator.estimate)
        }
        let native = zeroed(full)
        let width = Int(native.extent.width), height = Int(native.extent.height)
        let fullLong = CGFloat(Swift.max(width, height))
        let s = Swift.min(1, rankingLongEdge / fullLong)
        let small = native.transformed(by: CGAffineTransform(scaleX: s, y: s))
        guard let preview = PipelineRenderer.buffer(from: small, context: context) else { return nil }
        return LateralCAEstimator.estimate(nativeWidth: width, nativeHeight: height,
                                           preview: preview) { x, y, w, h in
            guard x >= 0, y >= 0, x + w <= width, y + h <= height else { return nil }
            // Top-left tile coordinates → Core Image's bottom-left extent.
            let rect = CGRect(x: x, y: height - y - h, width: w, height: h)
            return PipelineRenderer.buffer(from: native.cropped(to: rect), context: context)
        }
    }

    public func forget(_ url: URL) {
        lock.lock()
        held.removeValue(forKey: url)
        order.removeAll { $0 == url }
        lock.unlock()
    }
}

#endif
