// ws16probe — WS-16 S9 stage probe.
//
//   ws16probe stage VIB SAT DENS PROT [b0,b1,...,b7]
//       stdin, one sample per line: "L C h" (OKLCh in Lumen's working context:
//       Rec.2020 linear, OKLabTransform.working) or "rgb r g b" (working Rec.2020 linear).
//       With the 8-band list, look.bw is enabled with those bands.
//       stdout per line (15 numbers):
//         inR inG inB | engine L C h | twin L C h | engR engG engB | twinR twinG twinB
//       stderr: "identity engine=<Bool> stage=<Bool> passes=<n>"
//   ws16probe centres     prints ColorEngine.bandHueCentres (the 8 B&W band centres, degrees)
//   ws16probe glsl        prints ExactColorKernelSource.finish (the GPU kernel source)
//   ws16probe skinweight  stdin "rgb r g b" lines -> ColorEngine.skinWeight per line
import Foundation
import LumenCore

let a = CommandLine.arguments
let mode = a.count > 1 ? a[1] : "stage"
let ctx = OKLabTransform.working

func parse(_ line: Substring) -> RGB? {
    let p = line.split(separator: " ")
    guard !p.isEmpty else { return nil }
    if p.first == "rgb" { return RGB(Double(p[1])!, Double(p[2])!, Double(p[3])!) }
    return ctx.toRGB(OKLCh(L: Double(p[0])!, C: Double(p[1])!, h: Double(p[2])!))
}

switch mode {
case "glsl":
    print(ExactColorKernelSource.finish)
case "centres":
    print(ColorEngine.bandHueCentres.map { String(format: "%.9g", $0) }.joined(separator: " "))
case "skinweight":
    var out = ""
    while let line = readLine() {
        guard let c = parse(Substring(line)) else { continue }
        out += String(format: "%.9g\n", ColorEngine.skinWeight(c))
    }
    print(out, terminator: "")
default:
    let vib = Double(a[2])!, sat = Double(a[3])!, dens = Double(a[4])!, prot = Double(a[5])!
    var bw: BlackAndWhite? = nil
    if a.count > 6 { bw = BlackAndWhite(bands: a[6].split(separator: ",").map { Double($0)! }, enabled: true) }
    var color = ColorAdjust()
    color.vibrance = vib; color.saturation = sat; color.density = dens; color.protectSkin = prot
    let eng = ColorEngine(mixer: Mixer(), pointColors: [], color: color, primaries: Primaries(), bw: bw)
    let st = eng.exactStage
    FileHandle.standardError.write(
        "identity engine=\(eng.isIdentity) stage=\(st.isIdentity) passes=\(st.passes.count)\n".data(using: .utf8)!)
    var out = ""
    while let line = readLine() {
        guard let c = parse(Substring(line)) else { continue }
        let e = eng.apply(c), t = st.apply(c)
        let le = ctx.toLCh(e), lt = ctx.toLCh(t)
        out += String(format: "%.9g %.9g %.9g %.9g %.9g %.9g %.9g %.9g %.9g %.9g %.9g %.9g %.9g %.9g %.9g\n",
                      c.r, c.g, c.b, le.L, le.C, le.h, lt.L, lt.C, lt.h, e.r, e.g, e.b, t.r, t.g, t.b)
    }
    print(out, terminator: "")
}
