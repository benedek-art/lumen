import Foundation
import LumenCore

func emit(_ name: String, _ body: [String: Any]) {
    var v = body; v["probe"] = name
    let data = try! JSONSerialization.data(withJSONObject: v, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}
func triple(_ v: RGB) -> [Double] { [v.r,v.g,v.b] }
func engine(mixer: Mixer = Mixer(), points: [PointColor] = [], color: ColorAdjust = ColorAdjust(), primaries: Primaries = Primaries()) -> ColorEngine {
    ColorEngine(mixer: mixer, pointColors: points, color: color, primaries: primaries, bw: nil)
}
let ctx = OKLabTransform.working
let neutralWB = WhiteBalanceEngine(asShotKelvin: 5500, asShotTint: 0, targetKelvin: nil, targetTint: nil)
for tint in [-250.0,-180,0,150,200,250] {
    let target = WhiteBalanceEngine(asShotKelvin: 5500, asShotTint: 0, targetKelvin: 5500, targetTint: tint)
    let sample = target.matrix.inverse.apply(RGB(gray: 0.18))
    let solved = WhiteBalanceEngine.neutralizing(sample: sample, asShotKelvin: 5500, asShotTint: 0, current: neutralWB)
    let actual = WhiteBalanceEngine(asShotKelvin: 5500, asShotTint: 0, targetKelvin: solved.kelvin, targetTint: solved.tint).apply(sample)
    emit("wb_pipette", ["requestedTint":tint,"sample":triple(sample),"solvedKelvin":solved.kelvin,"solvedTint":solved.tint,"result":triple(actual),"resultChroma":ctx.toLCh(actual).C,"availableResultChroma":ctx.toLCh(target.apply(sample)).C])
}
let sample = ctx.toRGB(OKLCh(L: 0.60,C: 0.12,h: ColorEngine.bandHueCentres[0]))
for hue in [0.0,50,100] {
    var mixer = Mixer(); mixer.bands[0].hue = hue
    let base = engine(mixer: mixer).apply(sample)
    for range in [0.0,50,100] {
        let pc = PointColor(sample: triple(sample),range:range,shift:HSLShift(h:0,s:-100,l:0))
        let selected = engine(mixer:mixer,points:[pc]).apply(sample)
        let correctPC = PointColor(sample:triple(base),range:range,shift:HSLShift(h:0,s:-100,l:0))
        let correct = engine(mixer:mixer,points:[correctPC]).apply(sample)
        emit("point_picker_stage",["mixerRedHue":hue,"range":range,"baseC":ctx.toLCh(base).C,"actualC":ctx.toLCh(selected).C,"correctC":ctx.toLCh(correct).C,"sample":triple(sample),"base":triple(base)])
    }
}
for e in [1.0,2,4] {
    var z = Zones(); z.dark.ev=e
    let tone = ToneEngine(zones:z); let lut=tone.bakeGainLUT()
    var longest = 0.0; var runStart: Double?; var previous = -Double.infinity
    var mismatch = 0.0; var worstT=0.0
    for i in 0...14000 {
        let t = -9 + Double(i)*0.001; let y=0.18*pow(2,t)
        let mapped=t+log2(lut.evaluate(LumenLog.encode(y)))
        if mapped-previous < 0.0001 { if runStart == nil {runStart=t} }
        else if let start=runStart {longest=max(longest,t-start);runStart=nil}
        let error=abs(mapped-(t+tone.stops(at:t)))
        if error>mismatch {mismatch=error;worstT=t}
        previous=mapped
    }
    emit("zone_bake",["darkEV":e,"longestFlatEV":longest,"maxErrorEV":mismatch,"worstInputEV":worstT])
}
var curve = CurveSet(); curve.luma=[[0,0.2],[1,1]]
let stack=CurveStack(curve)
for v in [0.0,1e-8,1e-7,1e-6,1e-5] {emit("luma_black_lift",["input":v,"output":triple(stack.apply(RGB(gray:v)))])}
for c in [RGB(0.4,0.2,0.1),RGB(-0.05,0.2,0.4)] {
    var recipe=Recipe(); recipe.develop.color.saturation=0.001
    let p=RenderPlan(recipe:recipe,lutSize:33)
    emit("table_tiny_saturation",["input":triple(c),"exact":triple(engine(color:recipe.develop.color).apply(c)),"table":triple(LumenLog.decode(p.colorGradeLUT.sample(LumenLog.encode(c))))])
}

var lumaRecipe=Recipe(); lumaRecipe.develop.curve=curve
for size in [33,65] {
    let p=RenderPlan(recipe:lumaRecipe,lutSize:size)
    for v in [0.0,1e-8,1e-6,1e-5,1e-4,0.001] {
        emit("luma_black_pipeline",["lutSize":size,"input":v,"exact":triple(p.exactColor(RGB(gray:v))),"table":triple(p.referenceColor(RGB(gray:v)))])
    }
}

var rng:UInt64=774123
func random()->Double {rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Double(rng >> 11)/9007199254740992}
let colors=(0..<1500).map{_ in RGB(random(),random(),random())}
var recipes:[(String,Recipe)]=[]
var r=Recipe();r.develop.mixer.bands[0].hue=100;recipes.append(("mixer_red_hue100",r))
r=Recipe();r.develop.mixer.bands[4].lum = -100;recipes.append(("mixer_aqua_lum-100",r))
r=Recipe();r.develop.color.saturation=100;recipes.append(("saturation100",r))
r=Recipe();r.look.wheels.global=Wheel(hue:240,sat:100,lum:0);recipes.append(("global_wheel_blue100",r))
r=Recipe();r.look.wheels.colorBalance.hueShift=180;recipes.append(("grade_hue180",r))
r=Recipe();r.look.wheels.colorBalance.saturation.global=100;recipes.append(("grade_saturation100",r))
r=Recipe();r.look.primaries.rHue=100;r.look.primaries.gHue = -100;r.look.primaries.bPurity=100;recipes.append(("primaries_extreme",r))
for (name,recipe) in recipes {
    for size in [33,65] {
        let p=RenderPlan(recipe:recipe,lutSize:size)
        var maxError=0.0;var mean=0.0;var above=0;var worst=RGB(gray:0);var worstExact=worst;var worstTable=worst
        for c in colors {
            let exact=TransferFunction.srgb.encode(p.exactColor(c));let table=TransferFunction.srgb.encode(p.referenceColor(c))
            let error=exact.maxAbsDifference(table)*255;mean+=error
            if error>3 {above+=1}
            if error>maxError {maxError=error;worst=c;worstExact=exact;worstTable=table}
        }
        emit("render_table_error",["setting":name,"lutSize":size,"sampleCount":colors.count,"meanMaxCodeError":mean/Double(colors.count),"maxCodeError":maxError,"above3codes":above,"worstInput":triple(worst),"exactEncoded":triple(worstExact),"tableEncoded":triple(worstTable)])
    }
}

for (name,c) in [("sRGB_orange",RGB(1,0.5,0)),("sRGB_green",RGB(0,1,0)),("sRGB_yellow",RGB(1,1,0)),("sRGB_blue",RGB(0,0,1))] {
    let rgb=RGBColorSpace.srgb.matrix(to:.rec2020).apply(TransferFunction.srgb.decode(c))
    let lch=ctx.toLCh(rgb)
    emit("mixer_band_labels",["color":name,"oklchHue":lch.h,"weights":ColorEngine.bandWeights(hue:lch.h)])
}
