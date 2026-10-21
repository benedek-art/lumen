// MaskRangeMeasure.swift
// Lane M9b: the range masks' measurement denoise, on the GPU.
//
// Lane M4 made `MaskRaster.rangeMeasured` part of the range masks' definition: before a
// luminance or colour range is thresholded, its measured plane goes through two
// self-guided passes at `rangeMeasurementRadius` (1 px per 800 of long edge), with ε per
// pixel from the frame's own noise at that brightness — a robust MAD of a 5 × 5
// high-pass, per half-stop bin. That is spatial and it reads a statistic of the whole
// frame, so M9's pointwise kernels could not match it at any production size, and the
// integrator sent range masks back to the CPU (84698be).
//
// Here it is the same arithmetic on the GPU, in three parts:
//
//  · `KernelLibrary.maskRangeResidual` writes, for each pixel the reference samples, the
//    |high-pass| of each plane and the pixel's level bin.
//  · `NoiseTableKernel`, a `CIImageProcessorKernel`, reduces that to the 46-bin σ² table
//    with a radix select — four histogram passes over the float bits — so the median is
//    the reference's exact k-th smallest, not a histogram estimate. Metal compute inside
//    the Core Image graph: no readback, no CPU in the frame. Without a Metal device it
//    runs `MaskRaster.rangeNoiseVariance` on the input's bytes instead.
//  · The two guided passes, four kernels each (`maskRangeBoxH` … `maskRangeApplyV`),
//    reading the table.
//
// The result is a CORRECTION image (denoised − raw measurement), never the measurement
// itself, because half-float intermediates hold a correction to 1e-4 EV and an EV level
// to 1/32 EV; the threshold kernels recompute the raw measurement from the stage pixel
// and add it. `Kernels.swift` has the precision argument at the kernels.

#if os(macOS)

import CoreImage
import Foundation
import LumenCore
import Metal

enum MaskRangeMeasure {

    /// What a range component measures. `colour` is the colour range's OKLab L, a, b
    /// (three planes, binned by luminance); otherwise one EV plane of `channel`.
    struct Spec: Hashable {
        var colour: Bool
        var channel: Int
    }

    /// The box radius at this extent, or nil when the GPU cannot run it.
    static func radius(longEdge: Int) -> Int? {
        let r = MaskRaster.rangeMeasurementRadius(longEdge: longEdge)
        return r <= KernelLibrary.rangeMaxRadius ? r : nil
    }

    /// The correction to add to the raw measurement: r for a luminance range, rgb for a
    /// colour range's L, a, b. A zero image where the reference's filter is off (radius
    /// 0, below 400 px). Nil when a kernel will not apply.
    static func correction(_ spec: Spec, source: CIImage, extent: CGRect) -> CIImage? {
        let zero = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
        let w = Int(extent.width), h = Int(extent.height)
        guard let r = radius(longEdge: Swift.max(w, h)) else { return nil }
        if r == 0 { return zero }
        let args = arguments(spec)
        let ext = CIVector(x: extent.origin.x, y: extent.origin.y,
                           z: extent.width, w: extent.height)
        guard let table = noiseTable(spec, source: source, extent: extent,
                                     args: args, ext: ext)
        else { return nil }
        let planes = spec.colour ? 3 : 1
        var corrections: [CIImage] = []
        for plane in 0..<planes {
            let sel = CIVector(x: spec.colour ? 1 : 0, y: CGFloat(spec.channel),
                               z: CGFloat(plane))
            guard let e = guided(source: source, extent: extent, table: table,
                                 sel: sel, args: args, ext: ext, radius: r, zero: zero)
            else { return nil }
            corrections.append(e)
        }
        if !spec.colour { return corrections[0] }
        return KernelLibrary.apply(KernelLibrary.maskRangeMerge, extent: extent,
                                   corrections)
    }

    /// The working-space numbers every measurement kernel takes after `sel`: the luminance
    /// weights, then the RGB→LMS and LMS→Lab rows.
    private static func arguments(_ spec: Spec) -> [Any] {
        let wts = RGBColorSpace.rec2020.luminanceWeights
        let rows = (OKLabTransform.working.rgbToLMS.m + OKLabTransform.lmsToLab.m).map {
            CIVector(x: CGFloat($0[0]), y: CGFloat($0[1]), z: CGFloat($0[2]))
        }
        return [CIVector(x: CGFloat(wts.r), y: CGFloat(wts.g), z: CGFloat(wts.b))] + rows
    }

    // MARK: - The noise table

    /// The 46 × 1 σ² table (r, g, b for planes 0, 1, 2), from `source`'s own noise.
    static func noiseTable(_ spec: Spec, source: CIImage, extent: CGRect) -> CIImage? {
        noiseTable(spec, source: source, extent: extent, args: arguments(spec),
                   ext: CIVector(x: extent.origin.x, y: extent.origin.y,
                                 z: extent.width, w: extent.height))
    }

    private static func noiseTable(_ spec: Spec, source: CIImage, extent: CGRect,
                                   args: [Any], ext: CIVector) -> CIImage? {
        let w = Int(extent.width), h = Int(extent.height)
        // `stride(from: 2, to: n - 2, by: 2)`'s count.
        let nx = Swift.max(0, (w - 3) / 2), ny = Swift.max(0, (h - 3) / 2)
        let bins = MaskRaster.rangeNoiseBins
        let tableExtent = CGRect(x: 0, y: 0, width: bins, height: 1)
        // No sample at all: every bin borrows nothing and is 0, as on the CPU.
        if nx == 0 || ny == 0 {
            return CIImage(color: CIColor(red: 0, green: 0, blue: 0))
                .cropped(to: tableExtent)
        }
        let sel = CIVector(x: spec.colour ? 1 : 0, y: CGFloat(spec.channel), z: 0)
        let residualExtent = CGRect(x: 0, y: 0, width: nx, height: ny)
        let srcExtent = source.extent
        guard let kernel = KernelLibrary.maskRangeResidual,
              let residual = kernel.apply(
                extent: residualExtent,
                roiCallback: { _, _ in srcExtent },
                arguments: [source, sel] + args + [ext])
        else { return nil }
        return try? NoiseTableKernel.apply(
            withExtent: tableExtent, inputs: [residual],
            arguments: ["planes": spec.colour ? 3 : 1,
                        "extent": CIVector(cgRect: residualExtent)])
            .samplingNearest()
    }

    // MARK: - The guided passes

    private static func guided(source: CIImage, extent: CGRect, table: CIImage,
                               sel: CIVector, args: [Any], ext: CIVector, radius: Int,
                               zero: CIImage) -> CIImage? {
        let reach = CGFloat(radius)
        let rad = Float(radius)
        let tableExtent = table.extent
        let common: [Any] = [sel] + args + [ext, rad]
        func run(_ kernel: CIKernel?, _ images: [CIImage], _ extra: [Any] = [],
                 tableIndex: Int = -1) -> CIImage? {
            guard let kernel else { return nil }
            return kernel.apply(
                extent: extent,
                roiCallback: { index, rect in
                    Int(index) == tableIndex ? tableExtent
                        : rect.insetBy(dx: -reach, dy: -reach)
                },
                arguments: images + common + extra)?.cropped(to: extent)
        }
        var e = zero
        for _ in 0..<MaskRaster.rangeMeasurementPasses {
            guard let hs = run(KernelLibrary.maskRangeBoxH, [source, e]),
                  let coef = run(KernelLibrary.maskRangeCoefV, [source, e, hs, table],
                                 [Float(MaskRaster.rangeNoiseFactor)], tableIndex: 3),
                  let h2 = run(KernelLibrary.maskRangeApplyH, [source, e, coef]),
                  let next = run(KernelLibrary.maskRangeApplyV, [source, e, h2])
            else { return nil }
            e = next
        }
        return e
    }
}

// MARK: - The reduction

/// The residual image → the per-bin σ² table, exactly as `MaskRaster.rangeNoiseTable`:
/// per bin, the k = n/2 smallest |residual| (0-based), σ = 1.4826 · MAD / √(24/25), bins
/// under 64 samples borrowing in `rangeNoiseVariance`'s order.
///
/// THE MEDIAN IS EXACT. A radix select over the IEEE bits of |r| (non-negative floats
/// order as their bit patterns do): four passes, each a 256-bucket histogram per (plane,
/// bin) of the next byte among the samples whose higher bytes match the prefix found so
/// far, then one thread per (plane, bin) walks its histogram to the k-th sample and
/// fixes that byte. After the fourth pass the prefix IS the k-th smallest value.
final class NoiseTableKernel: CIImageProcessorKernel {

    override class var outputFormat: CIFormat { .RGBAf }

    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAf }

    override class func roi(forInput input: Int32, arguments: [String: Any]?,
                            outputRect: CGRect) -> CGRect {
        (arguments?["extent"] as? CIVector)?.cgRectValue ?? outputRect
    }

    override class func process(with inputs: [CIImageProcessorInput]?,
                                arguments: [String: Any]?,
                                output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first else { throw NoiseTableError.noInput }
        let planes = Swift.min(Swift.max(arguments?["planes"] as? Int ?? 1, 1), 3)
        if let buffer = output.metalCommandBuffer,
           let source = input.metalTexture, let target = output.metalTexture,
           let pipelines = Pipelines.on(buffer.device) {
            try encode(buffer, pipelines, source: source, target: target,
                       width: Int(input.region.width), height: Int(input.region.height),
                       planes: planes)
            return
        }
        cpuFallbacks.increment()
        try cpu(input, output, planes: planes)
    }

    /// How many tables were reduced on the CPU branch, for the test that pins the frame
    /// to the GPU.
    static let cpuFallbacks = Counter()

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    enum NoiseTableError: Error { case noInput, noBuffers, noEncoder }

    // MARK: Metal

    static let metalSource = """
    #include <metal_stdlib>
    using namespace metal;

    #define BINS \(MaskRaster.rangeNoiseBins)u

    struct NoiseParams { uint planes; uint shift; uint pass; uint width; uint height; };

    kernel void lumenNoiseHistogram(texture2d<float, access::read> res [[texture(0)]],
                                    device atomic_uint *hist [[buffer(0)]],
                                    device const uint *prefix [[buffer(1)]],
                                    constant NoiseParams &p [[buffer(2)]],
                                    uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.width || gid.y >= p.height) return;
        float4 v = res.read(gid);
        if (!(v.w >= 0.0f)) return;
        uint bin = min(uint(v.w + 0.5f), BINS - 1u);
        uint high = p.pass == 0u ? 0u : (0xFFFFFFFFu << (32u - 8u * p.pass));
        for (uint c = 0u; c < p.planes; c++) {
            float r = fabs(v[c]);
            if (!isfinite(r)) continue;
            uint bits = as_type<uint>(r);
            uint slot = c * BINS + bin;
            if ((bits & high) != prefix[slot]) continue;
            atomic_fetch_add_explicit(&hist[slot * 256u + ((bits >> p.shift) & 255u)],
                                      1u, memory_order_relaxed);
        }
    }

    kernel void lumenNoiseSelect(device atomic_uint *hist [[buffer(0)]],
                                 device uint *prefix [[buffer(1)]],
                                 constant NoiseParams &p [[buffer(2)]],
                                 device uint *kth [[buffer(3)]],
                                 device uint *count [[buffer(4)]],
                                 uint tid [[thread_position_in_grid]]) {
        if (tid >= p.planes * BINS) return;
        device atomic_uint *h = hist + tid * 256u;
        if (p.pass == 0u) {
            uint n = 0u;
            for (uint b = 0u; b < 256u; b++) {
                n += atomic_load_explicit(&h[b], memory_order_relaxed);
            }
            count[tid] = n;
            kth[tid] = n / 2u;
        }
        if (count[tid] > 0u) {
            uint k = kth[tid];
            uint cum = 0u;
            uint chosen = 255u;
            for (uint b = 0u; b < 256u; b++) {
                uint c = atomic_load_explicit(&h[b], memory_order_relaxed);
                if (cum + c > k) { chosen = b; break; }
                cum += c;
            }
            kth[tid] = k - cum;
            prefix[tid] = prefix[tid] | (chosen << p.shift);
        }
        for (uint b = 0u; b < 256u; b++) {
            atomic_store_explicit(&h[b], 0u, memory_order_relaxed);
        }
    }

    kernel void lumenNoiseFinish(device const uint *prefix [[buffer(1)]],
                                 constant NoiseParams &p [[buffer(2)]],
                                 device const uint *count [[buffer(4)]],
                                 texture2d<float, access::write> out [[texture(0)]],
                                 uint tid [[thread_position_in_grid]]) {
        if (tid != 0u) return;
        float s2[3][BINS];
        for (uint c = 0u; c < 3u; c++) {
            for (uint b = 0u; b < BINS; b++) {
                s2[c][b] = 0.0f;
                if (c >= p.planes) continue;
                uint slot = c * BINS + b;
                if (count[slot] >= 64u) {
                    float mad = as_type<float>(prefix[slot]);
                    float s = 1.4826f * mad / sqrt(24.0f / 25.0f);
                    s2[c][b] = s * s;
                } else {
                    s2[c][b] = -1.0f;
                }
            }
            if (c >= p.planes) continue;
            for (uint b = 0u; b < BINS; b++) {
                if (s2[c][b] >= 0.0f) continue;
                float best = -1.0f;
                int distance = 1 << 30;
                for (uint o = 0u; o < BINS; o++) {
                    int dd = abs(int(o) - int(b));
                    if (s2[c][o] >= 0.0f && dd < distance) { best = s2[c][o]; distance = dd; }
                }
                s2[c][b] = max(best, 0.0f);
            }
        }
        for (uint b = 0u; b < BINS; b++) {
            out.write(float4(s2[0][b], s2[1][b], s2[2][b], 1.0f), uint2(b, 0u));
        }
    }
    """

    /// The three compute pipelines, built once per device. Nil when the library will
    /// not compile; then the CPU branch runs, which is the same table, slower.
    struct Pipelines {
        let histogram: MTLComputePipelineState
        let select: MTLComputePipelineState
        let finish: MTLComputePipelineState

        private static let lock = NSLock()
        private static var built: [UInt64: Pipelines?] = [:]

        static func on(_ device: MTLDevice) -> Pipelines? {
            lock.lock()
            defer { lock.unlock() }
            if let cached = built[device.registryID] { return cached }
            let made = make(device)
            built[device.registryID] = made
            return made
        }

        private static func make(_ device: MTLDevice) -> Pipelines? {
            guard let library = try? device.makeLibrary(source: metalSource, options: nil),
                  let h = library.makeFunction(name: "lumenNoiseHistogram"),
                  let s = library.makeFunction(name: "lumenNoiseSelect"),
                  let f = library.makeFunction(name: "lumenNoiseFinish"),
                  let hp = try? device.makeComputePipelineState(function: h),
                  let sp = try? device.makeComputePipelineState(function: s),
                  let fp = try? device.makeComputePipelineState(function: f)
            else { return nil }
            return Pipelines(histogram: hp, select: sp, finish: fp)
        }
    }

    /// Whether the Metal reduction builds on this machine's default device. The CPU
    /// branch covers a context without one, so this is diagnostics, not a gate.
    static var metalAvailable: Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return Pipelines.on(device) != nil
    }

    private struct Params {
        var planes: UInt32
        var shift: UInt32
        var pass: UInt32
        var width: UInt32
        var height: UInt32
    }

    private static func encode(_ buffer: MTLCommandBuffer, _ pipelines: Pipelines,
                               source: MTLTexture, target: MTLTexture,
                               width: Int, height: Int, planes: Int) throws {
        let device = buffer.device
        let slots = planes * MaskRaster.rangeNoiseBins
        func zeroed(_ count: Int) -> MTLBuffer? {
            let b = device.makeBuffer(length: Swift.max(count, 1) * 4,
                                      options: .storageModeShared)
            if let b { memset(b.contents(), 0, b.length) }
            return b
        }
        guard let hist = zeroed(slots * 256), let prefix = zeroed(slots),
              let kth = zeroed(slots), let count = zeroed(slots)
        else { throw NoiseTableError.noBuffers }
        // Core Image may hand out a command buffer that does not retain what it
        // references; the handler keeps the four buffers alive until it completes.
        buffer.addCompletedHandler { _ in _ = [hist, prefix, kth, count] }

        let w = Swift.min(width, source.width), h = Swift.min(height, source.height)
        let groups = MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        let selectGroups = MTLSize(width: (slots + 63) / 64, height: 1, depth: 1)
        let selectGroup = MTLSize(width: 64, height: 1, depth: 1)
        for pass in 0..<4 {
            var p = Params(planes: UInt32(planes), shift: UInt32(24 - 8 * pass),
                           pass: UInt32(pass), width: UInt32(w), height: UInt32(h))
            guard let encoder = buffer.makeComputeCommandEncoder()
            else { throw NoiseTableError.noEncoder }
            encoder.setComputePipelineState(pipelines.histogram)
            encoder.setTexture(source, index: 0)
            encoder.setBuffer(hist, offset: 0, index: 0)
            encoder.setBuffer(prefix, offset: 0, index: 1)
            encoder.setBytes(&p, length: MemoryLayout<Params>.stride, index: 2)
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: group)
            encoder.endEncoding()
            // A separate encoder, so the select reads a finished histogram.
            guard let walk = buffer.makeComputeCommandEncoder()
            else { throw NoiseTableError.noEncoder }
            walk.setComputePipelineState(pipelines.select)
            walk.setBuffer(hist, offset: 0, index: 0)
            walk.setBuffer(prefix, offset: 0, index: 1)
            walk.setBytes(&p, length: MemoryLayout<Params>.stride, index: 2)
            walk.setBuffer(kth, offset: 0, index: 3)
            walk.setBuffer(count, offset: 0, index: 4)
            walk.dispatchThreadgroups(selectGroups, threadsPerThreadgroup: selectGroup)
            walk.endEncoding()
        }
        var p = Params(planes: UInt32(planes), shift: 0, pass: 4,
                       width: UInt32(w), height: UInt32(h))
        guard let encoder = buffer.makeComputeCommandEncoder()
        else { throw NoiseTableError.noEncoder }
        encoder.setComputePipelineState(pipelines.finish)
        encoder.setBuffer(prefix, offset: 0, index: 1)
        encoder.setBytes(&p, length: MemoryLayout<Params>.stride, index: 2)
        encoder.setBuffer(count, offset: 0, index: 4)
        encoder.setTexture(target, index: 0)
        encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 1, height: 1,
                                                                    depth: 1))
        encoder.endEncoding()
    }

    // MARK: CPU

    /// The same table from the input's bytes, through `MaskRaster.rangeNoiseVariance`.
    private static func cpu(_ input: CIImageProcessorInput, _ output: CIImageProcessorOutput,
                            planes: Int) throws {
        let w = Int(input.region.width), h = Int(input.region.height)
        let bins = MaskRaster.rangeNoiseBins
        var residuals = [[[Float]]](repeating: [[Float]](repeating: [], count: bins),
                                    count: planes)
        let src = input.baseAddress
        let rowBytes = input.bytesPerRow
        for y in 0..<h {
            let row = src.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
            for x in 0..<w {
                let level = row[x * 4 + 3]
                guard level >= 0 else { continue }
                let bin = Swift.min(Int(level + 0.5), bins - 1)
                for c in 0..<planes {
                    let r = Swift.abs(row[x * 4 + c])
                    if r.isFinite { residuals[c][bin].append(r) }
                }
            }
        }
        var tables = [[Double]](repeating: [Double](repeating: 0, count: bins), count: 3)
        for c in 0..<planes { tables[c] = MaskRaster.rangeNoiseVariance(&residuals[c]) }
        let out = output.baseAddress.assumingMemoryBound(to: Float.self)
        let ox = Int(output.region.origin.x)
        for x in 0..<Int(output.region.width) {
            let b = Swift.min(Swift.max(x + ox, 0), bins - 1)
            out[x * 4] = Float(tables[0][b])
            out[x * 4 + 1] = Float(tables[1][b])
            out[x * 4 + 2] = Float(tables[2][b])
            out[x * 4 + 3] = 1
        }
    }
}

#endif
