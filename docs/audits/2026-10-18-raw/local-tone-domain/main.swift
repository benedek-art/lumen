import Foundation
import LumenCore
// Explicit trilinear evaluation of ACTUAL LUT3D.data matches the shipping lookup
// interpolant. Core LUT3D.sample uses tetrahedra and is deliberately not used.
func tri(_ table: LUT3D, _ input: RGB) -> RGB {
    let n=table.size
    func axis(_ value: Double)->(Int,Double) {
        let p=min(max(value,0),1)*Double(n-1)
        let lo=min(Int(floor(p)),n-2)
        return(lo,p-Double(lo))
    }
    let (r,u)=axis(input.r),(g,v)=axis(input.g),(b,w)=axis(input.b)
    func at(_ x:Int,_ y:Int,_ z:Int)->RGB {
        let k=((z*n+y)*n+x)*4
        return RGB(Double(table.data[k]),Double(table.data[k+1]),Double(table.data[k+2]))
    }
    let a=at(r,g,b).mix(at(r+1,g,b),u).mix(at(r,g+1,b).mix(at(r+1,g+1,b),u),v)
    let c=at(r,g,b+1).mix(at(r+1,g,b+1),u).mix(at(r,g+1,b+1).mix(at(r+1,g+1,b+1),u),v)
    return a.mix(c,w)
}
let patches: [(String, RGB)] = [
    ("signed-positive-Y", RGB(-0.01, 0.18, 0.3)),
    ("all-negative-floor", RGB(-0.01, -0.02, -0.03)),
    ("HDR-above-axis", RGB(2048, 1024, 512)),
    ("ordinary-positive", RGB(0.18, 0.3, 0.5))]
let weights = RGBColorSpace.rec2020.luminanceWeights
var finite = true, exactZero = true, records = 0
for kind in ["contrast60", "highlights60"] {
    for amount in [0.0, 1e-8, 1.0, 100.0] { for size in [33, 65] {
        let scale = amount / 100
        let tone = ToneEngine(tone: Tone(contrast: kind == "contrast60" ? 60 * scale : 0,
                                        highlights: kind == "highlights60" ? 60 * scale : 0))
        let table: LUT3D? = tone.isIdentity ? nil : LUT3D(size: size) { encoded in
            let c = LumenLog.decode(encoded)
            let y = max(RGBColorSpace.rec2020.luminance(c), 0)
            return LumenLog.encode(c * tone.gain(at: Num.safeLog2(y / 0.18)))
        }
        var rows: [[String: Any]] = []
        for (label, c) in patches {
            // Independent luminance row arithmetic and scalar multiplication;
            // only the declared ToneEngine gain function supplies creative math.
            let y = weights.r*c.r + weights.g*c.g + weights.b*c.b
            let ev = log2(max(max(y, 0) / 0.18, pow(2.0, -20.0)))
            let gain = tone.gain(at: ev)
            let direct = RGB(c.r*gain, c.g*gain, c.b*gain)
            let coreY = max(RGBColorSpace.rec2020.luminance(c), 0)
            let coreGain = tone.gain(at: Num.safeLog2(coreY / 0.18))
            let directCore = c * coreGain
            let original = table.map { LumenLog.decode(tri($0, LumenLog.encode(c))) } ?? c
            let projected = LumenLog.decode(RGB(min(max(LumenLog.encode(c.r),0),1),
                min(max(LumenLog.encode(c.g),0),1), min(max(LumenLog.encode(c.b),0),1)))
            finite = finite && original.isFinite && direct.isFinite && directCore.isFinite
            if amount == 0 { exactZero = exactZero && original == c && direct == c }
            precondition(direct.maxAbsDifference(directCore) < 1e-12,
                         "independent row arithmetic must agree with the actual Core local-tone equation")
            rows.append(["patch": label, "input": [c.r,c.g,c.b], "inputY": y, "inputEV": ev,
                "directGain": gain, "originalCube": [original.r,original.g,original.b],
                "directCoreEquation": [direct.r,direct.g,direct.b],
                "inputProjectedToCube": [projected.r,projected.g,projected.b],
                "maximumError": original.maxAbsDifference(direct),
                "independentEquationError": direct.maxAbsDifference(directCore)])
        }
        let record: [String: Any] = ["tap":"case", "kind":kind, "amount":amount, "cube":size,
            "toneIdentity":tone.isIdentity,"patches":rows,"parityAcceptance":false,
            "nativeGPUExecution":false]
        let data=try JSONSerialization.data(withJSONObject:record,options:[.sortedKeys])
        var line=Data("LOCAL-TONE-DOMAIN ".utf8);line.append(data);line.append(10)
        FileHandle.standardOutput.write(line); records += 1
    }}
}
let summary:[String:Any] = ["tap":"summary","records":records,"finite":finite,
    "exactZero":exactZero,"parityAcceptance":false,"productionRemedyImplemented":false]
let data=try JSONSerialization.data(withJSONObject:summary,options:[.sortedKeys])
var line=Data("LOCAL-TONE-DOMAIN ".utf8);line.append(data);line.append(10)
FileHandle.standardOutput.write(line)
precondition(records == 16 && finite && exactZero)
