// nrtool in.lfi out.lfi iso key=value...   applies S3 ClassicalDenoise (seed profile at ISO) at scale 1
import Foundation
import LumenCore
func readLFI(_ p: String) -> ImageBuffer {
    let d = try! Data(contentsOf: URL(fileURLWithPath: p))
    let w = Int(d.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) })
    let h = Int(d.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) })
    var img = ImageBuffer(width: w, height: h)
    d.withUnsafeBytes { raw in
        let f = raw.baseAddress!.advanced(by: 16).assumingMemoryBound(to: Float.self)
        for y in 0..<h { for x in 0..<w { let i = (y*w+x)*3
            img[x, y] = RGB(Double(f[i]), Double(f[i+1]), Double(f[i+2])) } }
    }
    return img
}
func writeLFI(_ img: ImageBuffer, _ p: String) {
    var d = Data("LFI1".utf8)
    for v in [UInt32(img.width), UInt32(img.height), 3] { var x = v; d.append(Data(bytes: &x, count: 4)) }
    var fl = [Float](); fl.reserveCapacity(img.width*img.height*3)
    for y in 0..<img.height { for x in 0..<img.width { let c = img[x, y]; fl += [Float(c.r), Float(c.g), Float(c.b)] } }
    fl.withUnsafeBytes { d.append(contentsOf: $0) }
    try! d.write(to: URL(fileURLWithPath: p))
}
let a = CommandLine.arguments
let iso = Double(a[3])!
var p = ISODefaults.classic(forISO: iso)
var mode = "classic"
for kv in a.dropFirst(4) {
    let s = kv.split(separator: "="); let k = String(s[0]); let v = String(s[1])
    switch k {
    case "luma": p.luma = Double(v)!; case "chroma": p.chroma = Double(v)!
    case "hot": p.hotPixels = Double(v)!; case "ld": p.lumaDetail = Double(v)!
    case "lc": p.lumaContrast = Double(v)!; case "cd": p.colorDetail = Double(v)!
    case "cs": p.colorSmoothness = Double(v)!; case "mode": mode = v
    default: fatalError("key \(k)") }
}
let img = readLFI(a[1])
let profile = NoiseProfile.forISO(iso)
FileHandle.standardError.write("params \(p) sigma(0.18)=\(profile.sigma(at: 0.18))\n".data(using: .utf8)!)
let out = mode == "off" ? img : ClassicalDenoise(p, profile: profile).apply(img)
writeLFI(out, a[2])
