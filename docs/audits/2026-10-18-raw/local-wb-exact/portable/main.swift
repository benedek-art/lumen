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
let patches=[RGB(-0.01,0.18,0.3),RGB(0.18,0.3,0.5),RGB(1024,128,256)]
let balanced=WhiteBalanceEngine.Neutral(kelvin:5500,tint:0)
for mode in ["relative","absolute"] { for contrast in [0.0,30.0] {
    for amount in [1e-8,1.0,100.0] { for size in [33,65] {
        var adjust=LocalAdjust()
        if mode=="absolute" {adjust.kelvin=3200;adjust.kelvinTint=17}
        else {adjust.temp=20;adjust.tint=13}
        let scale=amount/100
        let tone=ToneEngine(tone:Tone(contrast:contrast*scale))
        let balance=ReferenceRenderer.LocalWhiteBalance.resolve(adjust,amount:scale,balanced:balanced,space:.rec2020)
        func toneValue(_ c:RGB)->RGB {
            c*tone.gain(at:Num.safeLog2(max(RGBColorSpace.rec2020.luminance(c),0)/0.18))
        }
        let old=LUT3D(size:size) {LumenLog.encode(balance.apply(toneValue(LumenLog.decode($0))))}
        let newTone: LUT3D?=tone.isIdentity ? nil:LUT3D(size:size) {LumenLog.encode(toneValue(LumenLog.decode($0)))}
        var records:[[String:Any]]=[]
        for p in patches {
            let historical=LumenLog.decode(tri(old,LumenLog.encode(p)))
            let toneOnly=newTone.map {LumenLog.decode(tri($0,LumenLog.encode(p)))} ?? p
            let candidate=balance.apply(toneOnly)
            let direct=balance.apply(toneValue(p))
            records.append(["input":[p.r,p.g,p.b],"old":[historical.r,historical.g,historical.b],
                "new":[candidate.r,candidate.g,candidate.b],"cpu":[direct.r,direct.g,direct.b],
                "oldVsNew":historical.maxAbsDifference(candidate),"oldVsCPU":historical.maxAbsDifference(direct),
                "newVsCPU":candidate.maxAbsDifference(direct)])
        }
        let record:[String:Any]=["mode":mode,"contrast":contrast,"amount":amount,"cube":size,"patches":records,
            "nativeGPUExecution":false,"savedLookIdentityClaim":false]
        let json=try JSONSerialization.data(withJSONObject:record,options:[.sortedKeys])
        var line=Data("LOCAL-WB-PORTABLE ".utf8);line.append(json);line.append(10)
        FileHandle.standardOutput.write(line)
    }}
}}
