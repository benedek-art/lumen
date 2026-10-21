// MaskRangeCostBenchTests.swift
// Lane M9b: what a range mask costs per frame, on the GPU path and on the CPU raster it
// replaced, at the draft and settle sizes. Prints, asserts nothing about time: it runs
// on whatever macOS runner CI hands out, and the numbers are for the lane report
// (docs/quality/lanes/M9b/REPORT.md). Lines start with "M9b-bench" so a log grep finds
// them.

#if os(macOS)

import CoreImage
import Metal
import XCTest
@testable import LumenCore
@testable import LumenPipeline

final class MaskRangeCostBenchTests: XCTestCase {

    private func picture(_ w: Int, _ h: Int) -> ImageBuffer {
        ImageBuffer(width: w, height: h) { u, v in
            let l = pow(2, -11 + 13 * u)
            let t = 2 * Double.pi * v
            let grain = 1 + 0.08 * sin(977 * u * v + 31 * u)
            return RGB(l * grain * (0.55 + 0.4 * cos(t)),
                       l * grain * (0.55 + 0.4 * cos(t - 2.1)),
                       l * grain * (0.55 + 0.4 * cos(t + 2.1)))
        }
    }

    private func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        return s[s.count / 2]
    }

    func testRangeMaskCostPerFrame() throws {
        try XCTSkipUnless(KernelLibrary.rangeMasksAvailable)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let context = CIContext(mtlDevice: device,
                                options: [.workingColorSpace: NSNull(),
                                          .outputColorSpace: NSNull(),
                                          .workingFormat: CIFormat.RGBAh])
        let queue = try XCTUnwrap(device.makeCommandQueue())

        var band = MaskComponent(op: .add, kind: .lumaRange)
        band.lo = 0.35; band.hi = 0.7; band.smooth = 40
        var colour = MaskComponent(op: .add, kind: .colorRange)
        let masks: [(String, (ImageBuffer) -> Mask)] = [
            ("luminance range", { _ in Mask(id: "b", components: [band]) }),
            ("colour range, 3 samples", { p in
                colour.samples = [0.2, 0.5, 0.8].map { f in
                    let c = p[Int(Double(p.width) * f), Int(Double(p.height) * f)]
                    return [c.r, c.g, c.b]
                }
                return Mask(id: "c", components: [colour])
            }),
        ]

        for (w, h) in [(1024, 683), (2048, 1365), (4096, 2731)] {
            let buffer = picture(w, h)
            let source = buffer.pixels.withUnsafeBytes {
                CIImage(bitmapData: Data($0), bytesPerRow: w * 16,
                        size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: nil)
            }
            let extent = CGRect(x: 0, y: 0, width: w, height: h)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
            descriptor.usage = [.shaderWrite, .shaderRead, .renderTarget]
            let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            for (name, build) in masks {
                let mask = build(buffer)
                var gpu: [Double] = []
                for run in 0..<6 {
                    let start = Date()
                    let alpha = try XCTUnwrap(MaskGPU.alpha(for: mask, extent: extent,
                                                            source: source))
                    let commands = try XCTUnwrap(queue.makeCommandBuffer())
                    let destination = CIRenderDestination(mtlTexture: texture,
                                                          commandBuffer: commands)
                    _ = try context.startTask(toRender: alpha, to: destination)
                    commands.commit()
                    commands.waitUntilCompleted()
                    if run > 0 { gpu.append(Date().timeIntervalSince(start) * 1000) }
                }
                var cpu: [Double] = []
                for _ in 0..<(w > 2048 ? 1 : 3) {
                    let start = Date()
                    _ = MaskRaster.combine(mask: mask, size: (width: w, height: h),
                                           source: buffer)
                    cpu.append(Date().timeIntervalSince(start) * 1000)
                }
                print(String(format: "M9b-bench %@ %dx%d radius %d: GPU %.2f ms, CPU raster %.1f ms",
                             name, w, h,
                             MaskRaster.rangeMeasurementRadius(longEdge: w),
                             median(gpu), median(cpu)))
            }
        }
    }
}

#endif
