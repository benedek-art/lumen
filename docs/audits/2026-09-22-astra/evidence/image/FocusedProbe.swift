import Foundation
import LumenCore
func triple(_ c:RGB)->[Double]{[c.r,c.g,c.b]}
func emit(_ name:String,_ value:[String:Any]) { var v=value;v["probe"]=name;print(String(data:try! JSONSerialization.data(withJSONObject:v,options:[.sortedKeys]),encoding:.utf8)!) }
let ctx=OKLabTransform.working
func color(_ r:Recipe)->ColorEngine {ColorEngine(mixer:r.develop.mixer,pointColors:r.develop.pointColors,color:r.develop.color,primaries:r.look.primaries,bw:r.look.bw)}
let cases:[(String,RGB)]=[
 ("mixer_aqua_lum-100",RGB(0.38413364324424248,0.59591710513566343,0.64828909901873966)),
 ("saturation100",RGB(0.78994447795661316,0.51750730037644888,0.21031789665386302)),
 ("grade_saturation100",RGB(0.061569141392114113,0.57189140387496051,0.96720407933738384))]
for (name,c) in cases {
 var r=Recipe()
 if name == "mixer_aqua_lum-100" {r.develop.mixer.bands[4].lum = -100}
 if name == "saturation100" {r.develop.color.saturation=100}
 if name == "grade_saturation100" {r.look.wheels.colorBalance.saturation.global=100}
 let p=RenderPlan(recipe:r,lutSize:65)
 let cg=GradeEngine(wheels:r.look.wheels,printerLights:r.look.printerLights).apply(color(r).apply(c))
 let cgTable=LumenLog.decode(p.colorGradeLUT.sample(LumenLog.encode(c)))
 emit("table_mechanism",["setting":name,"input":triple(c),"exactColorGrade":triple(cg),"tableColorGrade":triple(cgTable),"exactFinished":triple(p.exactColor(c)),"tableFinished":triple(p.referenceColor(c))])
}
for b in [0.0,1,5,9,12,15] {
 var p=DisplayTransformParams();p.blackTarget=b;let d=DisplayTransform(p)
 emit("display_black_target",["request":b,"resolvedBlack":d.black,"blackPixel":triple(d.apply(.zero)),"smallPixel":triple(d.apply(RGB(gray:1e-8)))])
}
var rng:UInt64=774123
func random()->Double {rng = rng &* 6364136223846793005 &+ 1442695040888963407;return Double(rng >> 11)/9007199254740992}
let toWorking=RGBColorSpace.srgb.matrix(to:.rec2020)
let samples=(0..<700).map{_ in toWorking.apply(RGB(random(),random(),random()))}
for amount in [0.0,25,50,100] {
 var r=Recipe();r.look.wheels.colorBalance.saturation.global=amount
 let p=RenderPlan(recipe:r,lutSize:65)
 var worst=0.0;var means=0.0;var above3=0;var cgNeg=0;var worstInput=RGB.zero;var worstExact=RGB.zero;var worstTable=RGB.zero
 let eng=GradeEngine(wheels:r.look.wheels,printerLights:r.look.printerLights)
 for c in samples {
  let exact=TransferFunction.srgb.encode(p.exactColor(c));let table=TransferFunction.srgb.encode(p.referenceColor(c))
  let e=255*exact.maxAbsDifference(table);means+=e
  if e>3 {above3+=1};if eng.apply(c).minComponent<0 {cgNeg+=1}
  if e>worst {worst=e;worstInput=c;worstExact=exact;worstTable=table}
 }
 emit("srgb_source_moderate",["saturation":amount,"sampleCount":samples.count,"maxCodeError":worst,"meanCodeError":means/Double(samples.count),"above3Codes":above3,"negativeExactGrade":cgNeg,"worstInput":triple(worstInput),"worstExactEncoded":triple(worstExact),"worstTableEncoded":triple(worstTable)])
}
