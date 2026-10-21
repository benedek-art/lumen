// probe in.lfi recipe.json kelvin tint iso(or 0) out.raw display|scene -- float32 RGB out.
// display: the reference render, display-linear, converted to sRGB linear and clamped.
// scene: DetailEngine.vignette alone (scene-linear Rec.2020). Written by the WS-41
// verifier (round 1) and kept here so the amended float measurements reproduce.
import Foundation
import LumenCore
// probe in.lfi recipe.json kelvin tint iso(or 0) out.raw mode(display|scene)
let a = CommandLine.arguments
let data = FileManager.default.contents(atPath: a[1])!
let bytes = [UInt8](data)
func u32(_ o: Int) -> Int { Int(UInt32(bytes[o]) | UInt32(bytes[o+1]) << 8 | UInt32(bytes[o+2]) << 16 | UInt32(bytes[o+3]) << 24) }
let w = u32(4), h = u32(8)
var px = [Float](repeating: 1, count: w*h*4)
bytes.withUnsafeBufferPointer { raw in
  var o = 16
  for i in 0..<(w*h) { for c in 0..<3 {
    let bits = UInt32(raw[o]) | UInt32(raw[o+1]) << 8 | UInt32(raw[o+2]) << 16 | UInt32(raw[o+3]) << 24
    px[i*4+c] = Float(bitPattern: bits); o += 4 } }
}
let img = ImageBuffer(width: w, height: h, pixels: px)
let recipe = try! JSONDecoder().decode(Recipe.self, from: FileManager.default.contents(atPath: a[2])!)
let iso = Double(a[5])!
let plan = RenderPlan(recipe: recipe, asShotKelvin: Double(a[3])!, asShotTint: Double(a[4])!,
                      lutSize: LUT3D.interactiveSize, captureISO: iso > 0 ? iso : nil, bandMeanHues: nil)
var outImg: ImageBuffer
if a[7] == "scene" {
  outImg = DetailEngine.vignette(img, plan.vignette, geometry: plan.recipe.develop.geometry)
} else {
  outImg = ReferenceRenderer.render(img, plan: plan)
}
// display: convert rec2020 display-linear -> srgb linear, clamp
let m = RGBColorSpace.rec2020.matrix(to: .srgb).m
var out = [Float](repeating: 0, count: w*h*3)
for i in 0..<(w*h) {
  let r = Double(outImg.pixels[i*4]), g = Double(outImg.pixels[i*4+1]), b = Double(outImg.pixels[i*4+2])
  if a[7] == "scene" { out[i*3] = Float(r); out[i*3+1] = Float(g); out[i*3+2] = Float(b); continue }
  for k in 0..<3 {
    let v = m[k][0]*r + m[k][1]*g + m[k][2]*b
    out[i*3+k] = Float(v.isFinite ? min(max(v, 0), 1) : 0)
  }
}
out.withUnsafeBufferPointer { FileManager.default.createFile(atPath: a[6], contents: Data(buffer: $0)) }
print(w, h)
