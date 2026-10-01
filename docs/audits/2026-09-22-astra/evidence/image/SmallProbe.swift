import Foundation
import LumenCore
func emit(_ n:String,_ v:[String:Any]) {var x=v;x["probe"]=n;print(String(data:try! JSONSerialization.data(withJSONObject:x,options:[.sortedKeys]),encoding:.utf8)!)}
for val in [25.0,50,100] {
 var c=CurveSet();c.parametric.lights=val;c.point=[[0,0],[0.60,0.7],[1,1]]
 let stack=CurveStack(c)
 emit("curve_handle_position",["parametricLights":val,"handleX":0.6,"handleY":0.7,"compositeTraceAtHandleX":stack.master(0.6),"pixelDistanceAt300px":300*abs(stack.master(0.6)-0.7)])
}
let context=OKLabTransform.working
for amount in [0.0,50,100] {
 let tone=ToneEngine(tone:Tone(contrast:amount));var params=DisplayTransformParams();tone.applyAnchors(to:&params);let display=DisplayTransform(params)
 for t in [2.0,3.5,4.5] {let y=0.18*pow(2,t);let out=display.tone(y*tone.gain(at:t));emit("contrast_clipping",["contrast":amount,"inputEV":t,"mappedEV":t+tone.stops(at:t),"output":out])}
}
for v in [-1.0,0,1] {
 let engine=GradeEngine(wheels:GradingWheels(global:Wheel(lum:v)),printerLights:PrinterLights())
 let out=engine.apply(RGB(gray:0.18));emit("wheel_luminance_units",["wheelLuminance":v,"actualSceneEV":log2(out.r/0.18)])
}
let sample=context.toRGB(OKLCh(L:0.6,C:0.12,h:29.23))
let point=PointColor(sample:[sample.r,sample.g,sample.b],range:100,variance:-100)
let engine=ColorEngine(mixer:Mixer(),pointColors:[point],color:ColorAdjust(),primaries:Primaries(),bw:nil)
for dh in [-5.0,0,5] {
 let c=context.toRGB(OKLCh(L:0.6,C:0.12,h:29.23+dh))
 emit("variance_texture",["inputHue":29.23+dh,"shippingOutputHue":context.toLCh(engine.apply(c)).h,"localMeanOutputHue":context.toLCh(engine.apply(c,localMean:sample)).h])
}
