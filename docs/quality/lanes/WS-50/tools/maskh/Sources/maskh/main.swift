// maskh — rasterize Mask JSON through MaskRaster.combine on an .lfi, write float alphas.
// usage: maskh jobs.json   where jobs.json = {input, longEdge, outDir, masks:[{name, mask}], refs:[Mask]}
import Foundation
import LumenCore

struct Job: Decodable { let name: String; let mask: Mask }
struct Jobs: Decodable { let input: String; let longEdge: Int; let outDir: String; let masks: [Job]; let refs: [Mask]? }

func loadLFI(_ path: String) -> ImageBuffer {
    let d = [UInt8](FileManager.default.contents(atPath: path)!)
    func u32(_ o: Int) -> Int { Int(UInt32(d[o]) | UInt32(d[o+1]) << 8 | UInt32(d[o+2]) << 16 | UInt32(d[o+3]) << 24) }
    let w = u32(4), h = u32(8)
    var px = [Float](repeating: 1, count: w * h * 4)
    d.withUnsafeBytes { raw in
        let f = raw.baseAddress!.advanced(by: 16).assumingMemoryBound(to: Float.self)
        for i in 0..<(w*h) { px[i*4] = f[i*3]; px[i*4+1] = f[i*3+1]; px[i*4+2] = f[i*3+2] }
    }
    return ImageBuffer(width: w, height: h, pixels: px)
}

func downsample(_ im: ImageBuffer, _ longEdge: Int) -> ImageBuffer {
    let le = max(im.width, im.height)
    guard longEdge > 0, longEdge < le else { return im }
    let s = Double(le) / Double(longEdge)
    let w = Int((Double(im.width) / s).rounded()), h = Int((Double(im.height) / s).rounded())
    var px = [Float](repeating: 1, count: w * h * 4)
    for y in 0..<h { for x in 0..<w {
        let x0 = Int(Double(x) * s), x1 = max(x0 + 1, Int(Double(x + 1) * s))
        let y0 = Int(Double(y) * s), y1 = max(y0 + 1, Int(Double(y + 1) * s))
        var acc = [Double](repeating: 0, count: 3); var n = 0.0
        for yy in y0..<min(y1, im.height) { for xx in x0..<min(x1, im.width) {
            let i = (yy * im.width + xx) * 4
            acc[0] += Double(im.pixels[i]); acc[1] += Double(im.pixels[i+1]); acc[2] += Double(im.pixels[i+2]); n += 1 } }
        let o = (y * w + x) * 4
        px[o] = Float(acc[0]/n); px[o+1] = Float(acc[1]/n); px[o+2] = Float(acc[2]/n)
    } }
    return ImageBuffer(width: w, height: h, pixels: px)
}

let jobs = try! JSONDecoder().decode(Jobs.self, from: FileManager.default.contents(atPath: CommandLine.arguments[1])!)
let src = downsample(loadLFI(jobs.input), jobs.longEdge)
try? FileManager.default.createDirectory(atPath: jobs.outDir, withIntermediateDirectories: true)
// source RGB too, for overlays
do {
    var out = Data(); var w32 = UInt32(src.width), h32 = UInt32(src.height), c32 = UInt32(3)
    out.append(contentsOf: "LFI1".utf8)
    withUnsafeBytes(of: &w32) { out.append(contentsOf: $0) }; withUnsafeBytes(of: &h32) { out.append(contentsOf: $0) }; withUnsafeBytes(of: &c32) { out.append(contentsOf: $0) }
    var f = [Float](); f.reserveCapacity(src.count * 3)
    for i in 0..<src.count { f.append(src.pixels[i*4]); f.append(src.pixels[i*4+1]); f.append(src.pixels[i*4+2]) }
    f.withUnsafeBytes { out.append(contentsOf: $0) }
    FileManager.default.createFile(atPath: jobs.outDir + "/_source.lfi", contents: out)
}
let all = (jobs.refs ?? []) + jobs.masks.map { $0.mask }
for j in jobs.masks {
    let t0 = Date()
    let p = MaskRaster.combine(mask: j.mask, size: (width: src.width, height: src.height), source: src, masks: all)
    var out = Data(); var w32 = UInt32(p.width), h32 = UInt32(p.height)
    withUnsafeBytes(of: &w32) { out.append(contentsOf: $0) }; withUnsafeBytes(of: &h32) { out.append(contentsOf: $0) }
    p.values.withUnsafeBytes { out.append(contentsOf: $0) }
    FileManager.default.createFile(atPath: jobs.outDir + "/" + j.name + ".f32", contents: out)
    print(j.name, p.width, p.height, String(format: "%.2fs", Date().timeIntervalSince(t0)))
}
