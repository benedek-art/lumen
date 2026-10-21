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

/// Measured per file and kept: the lateral-CA model and the embedded vignetting record
/// (from the file's bytes, read once).
///
/// The CA model is re-measured when a decode at least 1.5× larger than the one it came
/// from arrives, up to `maximumMeasureLongEdge`. The estimate is scale-consistent for
/// lens CA (a CA injected into a CA-free A7 IV frame reads back within 0.2·10⁻⁴ of the
/// half-diagonal at 1×, ½× and ⅓×), but a photograph's own colour structure reads
/// larger when downsampled: 1840 measured 0.79 px of red CA at 4000 px and 0.48 px at
/// its native 8256, and the independent tool's residual crosses zero at 0.46. So the
/// finest decode wins, and an export, which decodes at full size, measures for itself.
public final class LensInputsCache: @unchecked Sendable {
    public static let shared = LensInputsCache()

    /// Below this decode long edge the CA measurement is too coarse to trust; such a
    /// render uses what an earlier, larger decode measured, or nothing.
    public static let minimumMeasureLongEdge: CGFloat = 1200
    /// The readback cap: a 6144 px long edge is about 25 MP of RGBA float, 400 MB
    /// transient, once per photograph; a larger decode is downsampled to it first.
    public static let maximumMeasureLongEdge: CGFloat = 6144

    private struct Entry {
        var inputs: LensInputs
        var measuredLongEdge: CGFloat
    }

    private let lock = NSLock()
    private var held: [URL: Entry] = [:]
    private var vignettes: [URL: VignetteGain?] = [:]
    private var order: [URL] = []
    private let limit = 64

    public func inputs(url: URL, decoded: CIImage, context: CIContext) -> LensInputs {
        let extent = decoded.extent
        let long = Swift.min(Swift.max(extent.width, extent.height), Self.maximumMeasureLongEdge)

        lock.lock()
        let cachedVignette = vignettes[url]
        let entry = held[url]
        lock.unlock()

        let vignette: VignetteGain?
        if let cachedVignette {
            vignette = cachedVignette
        } else {
            vignette = EmbeddedLensProfile.read(url: url)?.gainPolynomial
            lock.lock()
            vignettes[url] = .some(vignette)
            lock.unlock()
        }

        if let entry, long < entry.measuredLongEdge * 1.5 { return entry.inputs }
        guard long >= Self.minimumMeasureLongEdge else {
            return entry?.inputs ?? LensInputs(lateralCA: nil, vignette: vignette)
        }

        var image = decoded.transformed(by: CGAffineTransform(
            translationX: -extent.origin.x, y: -extent.origin.y))
        let full = Swift.max(extent.width, extent.height)
        if full > long {
            let s = long / full
            image = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        let ca = PipelineRenderer.buffer(from: image, context: context)
            .flatMap(LateralCAEstimator.estimate)
        let result = LensInputs(lateralCA: ca, vignette: vignette)

        lock.lock()
        // A preview's measurement that finishes after an export's must not replace it:
        // the finer measurement wins whichever lands last.
        if let current = held[url], current.measuredLongEdge > long {
            lock.unlock()
            return current.inputs
        }
        held[url] = Entry(inputs: result, measuredLongEdge: long)
        order.removeAll { $0 == url }
        order.append(url)
        while order.count > limit {
            let oldest = order.removeFirst()
            held.removeValue(forKey: oldest)
            vignettes.removeValue(forKey: oldest)
        }
        lock.unlock()
        return result
    }

    public func forget(_ url: URL) {
        lock.lock()
        held.removeValue(forKey: url)
        vignettes.removeValue(forKey: url)
        order.removeAll { $0 == url }
        lock.unlock()
    }
}

#endif
