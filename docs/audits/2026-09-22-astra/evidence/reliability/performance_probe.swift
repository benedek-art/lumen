import Foundation
import CoreImage
import LumenCore
import LumenPipeline

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let renderer = PipelineRenderer()
let initStart = Date()
let source = try AppleRawSource(url:sourceURL)
let initMS = Date().timeIntervalSince(initStart)*1000
var recipe = Recipe.asImported(from: Recipe.SourceFile(isRendered:false,iso:source.captureISO.map(Int.init)))
func emit(_ values:[String:Any]) throws {
    print(String(data:try JSONSerialization.data(withJSONObject:values,options:.sortedKeys),encoding:.utf8)!)
    fflush(stdout)
}
func stats(_ values:[Double]) -> [String:Any] {
    let sorted = values.sorted()
    return ["samples":values.count,"minimumMS":sorted.first!,"medianMS":sorted[sorted.count/2],
            "p95MS":sorted[min(sorted.count-1,Int(ceil(Double(sorted.count)*0.95))-1)],"maximumMS":sorted.last!,
            "allMS":values]
}
try emit(["case":"environment","sourceInitializationMS":initMS,"nativeSize":[source.nativePixelSize.width,source.nativePixelSize.height],
          "kernelsMissing":renderer.unavailableKernels,"build":"Swift -O release objects","previewLongEdge":1536])
let coldStart = Date()
let cold = try renderer.renderPreviewDelivery(source:source,recipe:recipe,maxLongEdge:1536,draft:false,coarseDecode:false)
try emit(["case":"cold-preview","totalMS":Date().timeIntervalSince(coldStart)*1000,"decodeMS":cold.decodeMilliseconds,
          "deliveredSize":[cold.image.width,cold.image.height]])
var exposureTimes:[Double]=[]; var exposureDecodes:[Double]=[]
for index in 0..<20 {
    recipe.develop.tone.exposure = -1 + Double(index)/10
    let start = Date()
    let delivery = try renderer.renderPreviewDelivery(source:source,recipe:recipe,maxLongEdge:1536,draft:false,coarseDecode:false)
    exposureTimes.append(Date().timeIntervalSince(start)*1000); exposureDecodes.append(delivery.decodeMilliseconds)
}
try emit(["case":"warm-exposure-exact","timings":stats(exposureTimes),"decode":stats(exposureDecodes)])
recipe.develop.tone.exposure=0
var colorTimes:[Double]=[]
for index in 0..<20 {
    recipe.develop.mixer.bands[0].hue = Double(index-10)*2
    let start=Date()
    _ = try renderer.renderPreviewDelivery(source:source,recipe:recipe,maxLongEdge:1536,draft:false,coarseDecode:false)
    colorTimes.append(Date().timeIntervalSince(start)*1000)
}
try emit(["case":"warm-mixer-hue-exact","timings":stats(colorTimes)])
var draftTimes:[Double]=[]
PlanTableCache.resetStats()
for index in 0..<20 {
    recipe.develop.mixer.bands[0].hue = Double(index+1)
    let start=Date()
    _ = try renderer.renderPreviewDelivery(source:source,recipe:recipe,maxLongEdge:1536,draft:true,coarseDecode:false)
    draftTimes.append(Date().timeIntervalSince(start)*1000)
}
let settleStart=Date()
_ = try renderer.renderPreviewDelivery(source:source,recipe:recipe,maxLongEdge:1536,draft:false,coarseDecode:false)
let settleMS=Date().timeIntervalSince(settleStart)*1000
let cache = PlanTableCache.currentStats
try emit(["case":"warm-mixer-hue-drafts","timings":stats(draftTimes),"finalSettleMS":settleMS,
          "staleTableServes":cache.staleServes,"deferredBakes":cache.deferredBakes,"joinedBakes":cache.joinedBakes])
let exportStart=Date()
_ = try renderer.export(source:source,recipe:recipe,to:output,using:ExportRecipe(name:"benchmark",format:.jpeg,quality:90))
try emit(["case":"native-export-jpeg90","totalMS":Date().timeIntervalSince(exportStart)*1000,
          "bytes":(try FileManager.default.attributesOfItem(atPath:output.path)[.size] as! NSNumber).int64Value])
