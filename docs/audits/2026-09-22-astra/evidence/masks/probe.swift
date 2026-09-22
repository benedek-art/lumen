import Foundation
import CoreImage
@testable import LumenCore
@testable import LumenPipeline

let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .workingFormat: CIFormat.RGBAf])
let plan = RenderPlan(recipe: Recipe(), lutSize: 17)
let space = RGBColorSpace.rec2020
func ci(_ b: ImageBuffer) -> CIImage {
    var a = [Float](); a.reserveCapacity(b.width*b.height*4)
    for y in 0..<b.height { for x in 0..<b.width { let c=b[x,y]; a += [Float(c.r),Float(c.g),Float(c.b),1] } }
    return a.withUnsafeBytes { CIImage(bitmapData: Data($0), bytesPerRow: b.width*16, size: CGSize(width:b.width,height:b.height), format:.RGBAf,colorSpace:nil) }
}
func row(_ key:String,_ values:[String:Double]) {
    var object:[String:Any] = values; object["probe"] = key
    print(String(data:try! JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]),encoding:.utf8)!)
}
let flat = ImageBuffer(width:16,height:16) { _,_ in RGB(0.30,0.18,0.11) }
let alpha = Plane(width:16,height:16,fill:1)
for mode in [MaskBlend.normal, .luminosity, .color] {
    var m=Mask(id:"curve",blend:mode)
    m.adjust.curve=CurveSet(r:[[0,0],[0.5,0.8],[1,1]],preserveLuminance:false)
    let out=ReferenceRenderer.applyLocalCurves(flat,alphas:[(m,alpha)],plan:plan,space:space)[0,0]
    row("curve_blend_\(mode.rawValue)",["beforeY":space.luminance(flat[0,0]),"afterY":space.luminance(out),"beforeRG":flat[0,0].r/flat[0,0].g,"afterRG":out.r/out.g])
}
for n in [256,1024,4096] {
    let b=ImageBuffer(width:n,height:8) { u,_ in RGB(gray:0.18+0.03*sin(u*2*Double.pi*32)) }
    var m=Mask(id:"blur");m.adjust.sharpness = -100
    let out=ReferenceRenderer.applyLocalAdjust(b,mask:m,plan:plan,space:space)
    let gpu=PipelineRenderer.buffer(from:RenderGraph.applyLocalAdjust(ci(b),mask:m,plan:plan,longEdge:n,lutSize:17),context:context)!
    func amp(_ a:ImageBuffer)->Double { let row=(32..<(n-32)).map { a[$0,4].r }; return (row.max()!-row.min()!)/2 }
    row("negative_sharpness_\(n)",["cpuContrastRetention":amp(out)/amp(b),"gpuContrastRetention":amp(gpu)/amp(b)])
}
row("ramp_gamma",["gammaHalf":MaskRaster.levels(0.5,lo:0,hi:100,gamma:0.5),"gammaOne":MaskRaster.levels(0.5,lo:0,hi:100,gamma:1),"gammaTwo":MaskRaster.levels(0.5,lo:0,hi:100,gamma:2)])

final class Synthetic:ImageSource {
    let url=URL(fileURLWithPath:"/tmp/lumen-independent-mask-audit.tif")
    let nativeLongEdge=256.0
    let nativePixelSize=(width:256,height:128)
    let asShotTemperature=5500.0, asShotTint=0.0
    let captureMetadata=CaptureMetadata(asShotTemperature:5500,asShotTint:0,decoderVersion:nil,pixelSize:(width:256,height:128))
    let statisticsProvenance=RawTruth.provenance(isRenderedFile:true)
    let image:CIImage
    init() { image=ci(ImageBuffer(width:256,height:128) { u,_ in RGB(gray:pow(2,-8+u*10)) }) }
    func decode(recipe:Recipe,draft:Bool,scaleFactor:Double)->CIImage? { image.transformed(by:CGAffineTransform(scaleX:scaleFactor,y:scaleFactor)) }
}
let source=Synthetic()
var a=MaskComponent(op:.add,kind:.lumaRange);a.lo=0.4;a.hi=0.75;a.smooth=0
let donor=Mask(id:"donor",enabled:false,components:[a])
var ref=MaskComponent(op:.add,kind:.maskRef);ref.maskRef="donor"
var borrower=Mask(id:"borrower",components:[ref]);borrower.adjust.exposure=1
var recipe=Recipe();recipe.develop.denoise.mode = .off;recipe.masks=[donor,borrower]
let renderer=PipelineRenderer()
let borrowed=renderer.renderMaskAlpha(source:source,recipe:recipe,maskID:"borrower")!
var active=recipe;active.masks[0].enabled=true
let activeAlpha=renderer.renderMaskAlpha(source:source,recipe:active,maskID:"borrower")!
row("disabled_luma_donor",["disabledDonorMaxAlpha":Double(borrowed.values.max()!),"enabledDonorMaxAlpha":Double(activeAlpha.values.max()!)])
var invertedDonor=recipe;invertedDonor.masks[0].invert=true
let invertedMissing=renderer.renderMaskAlpha(source:source,recipe:invertedDonor,maskID:"borrower")!
row("disabled_inverted_luma_donor",["minAlpha":Double(invertedMissing.values.min()!),"maxAlpha":Double(invertedMissing.values.max()!)])

var geom=MaskComponent(op:.add,kind:.polygon);geom.path=[[0.05,0.05],[0.45,0.05],[0.45,0.95],[0.05,0.95]]
recipe.masks[0].components=[geom]
let held=PipelineRenderer()
let exportRecipe=ExportRecipe(name:"Audit")
let first=try! held.exportedImage(source:source,recipe:recipe,using:exportRecipe)
let before=PipelineRenderer.buffer(from:first,context:context)!
recipe.masks[0].components[0].path=[[0.55,0.05],[0.95,0.05],[0.95,0.95],[0.55,0.95]]
let stale=PipelineRenderer.buffer(from:try! held.exportedImage(source:source,recipe:recipe,using:exportRecipe),context:context)!
let fresh=PipelineRenderer.buffer(from:try! PipelineRenderer().exportedImage(source:source,recipe:recipe,using:exportRecipe),context:context)!
var repeatDiff=0.0, freshDiff=0.0
for y in 0..<before.height { for x in 0..<before.width { repeatDiff=max(repeatDiff,abs(before[x,y].r-stale[x,y].r));freshDiff=max(freshDiff,abs(fresh[x,y].r-stale[x,y].r)) } }
row("reference_cache_small_export",["changedDonorRepeatedRendererDiff":repeatDiff,"freshRendererVsStaleDiff":freshDiff])

let uniform=ci(ImageBuffer(width:256,height:128) { _,_ in RGB(gray:0.18) })
var vigRecipe=Recipe();vigRecipe.develop.geometry.crop=Crop(x:0.1,y:0.1,w:0.35,h:0.7)
func vignetted(_ r:Recipe)->ImageBuffer {
    let v=RenderGraph().applyVignette(uniform,ev:-2,feather:75,crop:r.develop.geometry.crop,dithered:false)
    return PipelineRenderer.buffer(from:PipelineRenderer.applyGeometry(v,recipe:r),context:context)!
}
let unflipped=vignetted(vigRecipe)
vigRecipe.develop.geometry.flipH=true
vigRecipe.develop.geometry.crop.x=1-0.1-0.35
let flipped=vignetted(vigRecipe)
row("vignette_after_crop_flip",["beforeCenter":unflipped[unflipped.width/2,unflipped.height/2].r,"afterCenter":flipped[flipped.width/2,flipped.height/2].r,"beforeMax":Double(unflipped.pixels.enumerated().filter{$0.offset%4==0}.map{$0.element}.max()!),"afterMax":Double(flipped.pixels.enumerated().filter{$0.offset%4==0}.map{$0.element}.max()!)])
for value in [60.0,1.0/60.0,3.0] {
    let c=CropGeometry.refit(Crop(),aspect:value,sourceWidth:6000,sourceHeight:4000,degrees:0)
    row("crop_requested_\(value)",["requested":value,"actual":CropGeometry.displayedAspect(c,sourceWidth:6000,sourceHeight:4000,degrees:0)!])
}
for value in [0.0,1.0,100.0] {
    var f=FilmChain.defaultRecipe(for:.portra400);f.amount=value
    let chain=FilmChain(f)
    row("film_strength_\(value)",["grainAmplitude":chain.grainAmount,"halationRed":chain.halation(longEdgePixels:1024).strength.r])
}
var absolute=LocalAdjust();absolute.kelvin=3200
for strength in [0.0,1.0,2.0] {
    let balance=ReferenceRenderer.LocalWhiteBalance.resolve(absolute,amount:strength,balanced:plan.balancedNeutral,space:space)
    let v=balance.apply(RGB(gray:0.18))
    row("absoluteWB_strength_\(strength)",["red":v.r,"green":v.g,"blue":v.b])
}
let patterned=ImageBuffer(width:128,height:128) { u,v in RGB(gray:0.18*pow(2,0.2*(sin(u*2*Double.pi*17)+cos(v*2*Double.pi*13)))) }
for key in ["texture","clarity"] {
    var mask=Mask(id:"strength");if key=="texture" { mask.adjust.texture=100 } else { mask.adjust.clarity=100 }
    let cpu100=ReferenceRenderer.applyLocalAdjust(patterned,mask:mask,plan:plan,space:space)
    let gpu100=PipelineRenderer.buffer(from:RenderGraph.applyLocalAdjust(ci(patterned),mask:mask,plan:plan,longEdge:128,lutSize:17),context:context)!
    mask.amount=200
    let cpu200=ReferenceRenderer.applyLocalAdjust(patterned,mask:mask,plan:plan,space:space)
    let gpu200=PipelineRenderer.buffer(from:RenderGraph.applyLocalAdjust(ci(patterned),mask:mask,plan:plan,longEdge:128,lutSize:17),context:context)!
    var cpuDiff=0.0,gpuDiff=0.0
    for y in 0..<128 { for x in 0..<128 { cpuDiff=max(cpuDiff,abs(cpu100[x,y].r-cpu200[x,y].r));gpuDiff=max(gpuDiff,abs(gpu100[x,y].r-gpu200[x,y].r)) } }
    row("mask_strength_100_to_200_\(key)",["cpuMaxDelta":cpuDiff,"gpuMaxDelta":gpuDiff])
}
