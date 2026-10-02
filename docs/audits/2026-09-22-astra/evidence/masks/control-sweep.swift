import Foundation
import CoreImage
@testable import LumenCore
@testable import LumenPipeline
let context=CIContext(options:[.workingColorSpace:NSNull(),.outputColorSpace:NSNull(),.workingFormat:CIFormat.RGBAf])
func emit(_ name:String,_ values:[String:Double]) { var d:[String:Any]=values;d["control"]=name;print(String(data:try! JSONSerialization.data(withJSONObject:d,options:.sortedKeys),encoding:.utf8)!) }
func ci(_ b:ImageBuffer)->CIImage { b.pixels.withUnsafeBytes { CIImage(bitmapData:Data($0),bytesPerRow:b.width*16,size:CGSize(width:b.width,height:b.height),format:.RGBAf,colorSpace:nil) } }
func difference(_ a:ImageBuffer,_ b:ImageBuffer)->Double { var s=0.0;for i in stride(from:0,to:a.pixels.count,by:4) { for c in 0..<3 { let v=Double(a.pixels[i+c]-b.pixels[i+c]);s += v*v } };return sqrt(s/Double(a.width*a.height*3)) }
let fixture=ImageBuffer(width:128,height:96) { u,v in
    let edge=u<0.5 ? 0.1:0.36
    let noise=0.022*sin(u*823+v*659)+0.015*cos(u*1491-v*1797)
    let texture=0.014*sin(u*263)*cos(v*241)
    return RGB(edge+texture+noise,edge+texture-noise*0.6,edge+texture+noise*0.2)
}
let input=ci(fixture)
let decomposition=DetailEngine.Decomposition(image:fixture,workingRadius:3)
let sharpenRows:[(String,WritableKeyPath<ManualSharpen,Double>,Double,Double)]=[("Amount",\.amount,0,150),("Radius",\.radius,0.5,3),("Detail",\.detail,0,100),("Masking",\.masking,0,100),("Halo Damping",\.haloSuppression,0,100)]
let sharpenFixture=ImageBuffer(width:1024,height:128) { u,v in
    let edge=u<0.5 ? 0.05:0.4
    return RGB(gray:edge+0.012*sin(u*1551)+0.008*cos(u*1327+v*679))
}
let sharpenInput=ci(sharpenFixture)
let sharpenDecomposition=DetailEngine.Decomposition(image:sharpenFixture,workingRadius:20)
for (name,key,lo,hi) in sharpenRows {
    var a=ManualSharpen(amount:100,radius:3);a[keyPath:key]=lo;var b=a;b[keyPath:key]=hi
    let ca=DetailEngine.applySharpen(sharpenFixture,params:a,decomposition:sharpenDecomposition),cb=DetailEngine.applySharpen(sharpenFixture,params:b,decomposition:sharpenDecomposition)
    let ga=PipelineRenderer.buffer(from:RenderGraph.applySharpen(sharpenInput,a,longEdge:1024),context:context)!,gb=PipelineRenderer.buffer(from:RenderGraph.applySharpen(sharpenInput,b,longEdge:1024),context:context)!
    emit("sharpen.\(name)",["cpuLoHiRMS":difference(ca,cb),"gpuLoHiRMS":difference(ga,gb),"cpuGpuHiRMS":difference(cb,gb)])
}
for (name,key) in [("Texture",\Detail.texture),("Clarity",\Detail.clarity),("Dehaze",\Detail.dehaze)] {
    var a=Detail();a[keyPath:key] = -100;var b=a;b[keyPath:key]=100
    let ca=DetailEngine.apply(fixture,detail:a,decomposition:decomposition),cb=DetailEngine.apply(fixture,detail:b,decomposition:decomposition)
    let ga=PipelineRenderer.buffer(from:RenderGraph.applyPresence(input,detail:a,longEdge:128),context:context)!,gb=PipelineRenderer.buffer(from:RenderGraph.applyPresence(input,detail:b,longEdge:128),context:context)!
    emit("presence.\(name)",["cpuLoHiRMS":difference(ca,cb),"gpuLoHiRMS":difference(ga,gb),"cpuGpuHiRMS":difference(cb,gb)])
}
let nrRows:[(String,WritableKeyPath<ClassicNR,Double>)]=[("Luminance",\.luma),("Luminance Detail",\.lumaDetail),("Luminance Contrast",\.lumaContrast),("Colour",\.chroma),("Colour Detail",\.colorDetail),("Colour Smoothness",\.colorSmoothness),("Hot Pixels",\.hotPixels)]
for (name,key) in nrRows {
    var a=ClassicNR(luma:75,chroma:75);a[keyPath:key]=0;var b=a;b[keyPath:key]=100
    let ca=ClassicalDenoise(a,profile:.forISO(3200)).apply(fixture),cb=ClassicalDenoise(b,profile:.forISO(3200)).apply(fixture)
    func gpu(_ p:ClassicNR)->ImageBuffer { var r=Recipe();r.develop.denoise.classic=p;let plan=RenderPlan(recipe:r,lutSize:17,captureISO:3200);return PipelineRenderer.buffer(from:RenderGraph().applyDenoise(input,plan:plan,options:.init(longEdge:128)),context:context)! }
    let ga=gpu(a),gb=gpu(b)
    emit("denoise.\(name)",["cpuLoHiRMS":difference(ca,cb),"gpuLoHiRMS":difference(ga,gb),"cpuGpuHiRMS":difference(cb,gb)])
}
for n in [256,512,1024,4096] {
    let dot=BrushStroke(points:[BrushPoint(x:0.5,y:0.5)],size:0.002,feather:0)
    let line=BrushStroke(points:[BrushPoint(x:0.1,y:0.5),BrushPoint(x:0.9,y:0.5)],size:0.01,feather:50,flow:10,density:80)
    let da=MaskRaster.accumulatedBrushPlane(strokes:BrushStrokeSet(strokes:[dot]),size:(width:n,height:n/2))
    let la=MaskRaster.accumulatedBrushPlane(strokes:BrushStrokeSet(strokes:[line]),size:(width:n,height:n/2))
    emit("brush.\(n)",["minimumDotMax":Double(da.values.max()!),"flow10Ceiling80LinePeak":Double(la.values.max()!)])
}
let src=ImageBuffer(width:128,height:64) { u,_ in u<0.5 ? RGB(0.6,0.05,0.02):RGB(0.02,0.15,0.6) }
let paint=BrushStroke(points:[BrushPoint(x:0.48,y:0.5)],size:0.3,feather:0,flow:100,density:100,automask:true)
let masked=MaskRaster.accumulatedBrushPlane(strokes:.init(strokes:[paint]),size:(width:128,height:64),source:src)
var plain=paint;plain.automask=false
let unmasked=MaskRaster.accumulatedBrushPlane(strokes:.init(strokes:[plain]),size:(width:128,height:64),source:src)
emit("brush.automask",["otherColorMasked":masked[70,32],"otherColorUnmasked":unmasked[70,32]])
for k in [0.0,1.0,25.0,50.0,100.0] {
    let stroke=BrushStroke(points:[BrushPoint(x:0.5,y:0.5)],size:0.3,feather:0,flow:25,density:k)
    let one=MaskRaster.accumulatedBrushPlane(strokes:.init(strokes:[stroke]),size:(width:128,height:64))
    let four=MaskRaster.accumulatedBrushPlane(strokes:.init(strokes:Array(repeating:stroke,count:4)),size:(width:128,height:64))
    emit("brush.ceiling.\(k)",["oneMax":Double(one.values.max()!),"fourMax":Double(four.values.max()!)])
}
