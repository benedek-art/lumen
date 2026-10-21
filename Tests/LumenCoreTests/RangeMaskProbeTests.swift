import Foundation
import XCTest
@testable import LumenCore

/// WS-47/48 audit probe: rasterize range-mask components over corpus frames and write
/// the alpha out, so the selection can be looked at and measured outside Swift.
///
/// Inert unless `LUMEN_MASK_PROBE` names a JSON job file:
///
///     [{"input": "a.lfi", "out": "a.f32", "component": { …MaskComponent JSON… },
///       "refine": { …MaskRefine JSON, optional… }}]
///
/// Each output is width·height little-endian Float32 alpha, preceded by two UInt32
/// (width, height). `scripts/proof/range_mask_probe.py` drives it.
final class RangeMaskProbeTests: XCTestCase {

    struct Job: Decodable {
        let input: String
        let out: String
        let component: MaskComponent
        let refine: MaskRefine?
    }

    func testProbeRangeMasks() throws {
        guard let path = ProcessInfo.processInfo.environment["LUMEN_MASK_PROBE"] else {
            throw XCTSkip("LUMEN_MASK_PROBE not set")
        }
        let jobs = try JSONDecoder().decode([Job].self,
                                            from: Data(contentsOf: URL(fileURLWithPath: path)))
        var cache: [String: ImageBuffer] = [:]
        for job in jobs {
            let src: ImageBuffer
            if let held = cache[job.input] {
                src = held
            } else {
                src = try Self.readLFI(job.input)
                cache = [job.input: src]
            }
            var mask = Mask(id: "probe", name: "probe", components: [job.component])
            if let refine = job.refine { mask.refine = refine }
            let start = Date()
            let alpha = MaskRaster.combine(mask: mask, size: (width: src.width, height: src.height),
                                           source: src)
            var data = Data()
            var w = UInt32(alpha.width).littleEndian
            var h = UInt32(alpha.height).littleEndian
            data.append(Data(bytes: &w, count: 4))
            data.append(Data(bytes: &h, count: 4))
            alpha.values.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
            try data.write(to: URL(fileURLWithPath: job.out))
            print("probe \(job.out) \(alpha.width)x\(alpha.height) "
                  + String(format: "%.2fs", Date().timeIntervalSince(start)))
        }
    }

    static func readLFI(_ path: String) throws -> ImageBuffer {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        func u32(_ o: Int) -> Int {
            Int(data.subdata(in: o..<(o + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        }
        let w = u32(4), h = u32(8)
        var img = ImageBuffer(width: w, height: h)
        data.withUnsafeBytes { raw in
            let f = raw.baseAddress!.advanced(by: 16).assumingMemoryBound(to: Float.self)
            for i in 0..<(w * h) {
                img.pixels[i * 4] = f[i * 3]
                img.pixels[i * 4 + 1] = f[i * 3 + 1]
                img.pixels[i * 4 + 2] = f[i * 3 + 2]
            }
        }
        return img
    }
}
