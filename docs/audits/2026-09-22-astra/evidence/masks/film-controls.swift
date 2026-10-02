import Foundation
import CoreImage
@testable import LumenCore
@testable import LumenPipeline

let context=CIContext(options:[.workingColorSpace:NSNull(),.outputColorSpace:NSNull(),.workingFormat:CIFormat.RGBAf])
func emit(_ name:String,_ values:[String:Double]) { var d:[String:Any]=values;d["probe"]=name;print(String(data:try! JSONSerialization.data(withJSONObject:d,options:.sortedKeys),encoding:.utf8)!) }
func ci(_ b:ImageBuffer)->CIImage { b.pixels.withUnsafeBytes { CIImage(bitmapData:Data($0),bytesPerRow:b.width*16,size:CGSize(width:b.width,height:b.height),format:.RGBAf,colorSpace:nil) } }
var recipe=FilmChain.defaultRecipe(for:.portra400)
recipe.halation=100
let chain=FilmChain(recipe)
let profile=chain.halation(longEdgePixels:256)
for value in [0.125,0.25,0.5,1.0,2.0,4.0] {
    let image=ImageBuffer(width:256,height:128) { _,_ in RGB(gray:value) }
    let output=PipelineRenderer.buffer(from:RenderGraph().applyHalation(ci(image),film:chain,longEdge:256),context:context)!
    let cpuGlow=profile.highlightEnergy(RGB(gray:value)).r*profile.strength.r*profile.weightSum
    let gpuGlow=output[128,64].r-value
    emit("halation.gate.\(value)",["cpuPredictedFlatRedGlow":cpuGlow,"gpuMeasuredFlatRedGlow":gpuGlow,"gpuToCPU":gpuGlow/max(cpuGlow,1e-12)])
}
for stock in FilmStock.all {
    var f=FilmChain.defaultRecipe(for:stock);f.halation=100
    let c=FilmChain(f)
    emit("halation.stock.\(stock.id)",["amount":c.halationAmount,"redStrength":c.halation(longEdgePixels:1024).strength.r])
}
let exposureLow=FilmChain(recipe,filmExposure:-2)
let exposureHigh=FilmChain(recipe,filmExposure:3)
emit("filmExposure.halationParameters",["lowClip":exposureLow.halation(longEdgePixels:256).clipLevel,"highClip":exposureHigh.halation(longEdgePixels:256).clipLevel,"lowThreshold":exposureLow.halation(longEdgePixels:256).threshold,"highThreshold":exposureHigh.halation(longEdgePixels:256).threshold])
var small=recipe;small.halationSize=0.5;var large=recipe;large.halationSize=2
emit("halation.size",["smallSigma":FilmChain(small).halation(longEdgePixels:1024).sigmas[0],"largeSigma":FilmChain(large).halation(longEdgePixels:1024).sigmas[0]])
var yellow=recipe;yellow.halationRedness=0;var red=recipe;red.halationRedness=100
emit("halation.redness",["yellowGreenStrength":FilmChain(yellow).halation(longEdgePixels:1024).strength.g,"redGreenStrength":FilmChain(red).halation(longEdgePixels:1024).strength.g])
