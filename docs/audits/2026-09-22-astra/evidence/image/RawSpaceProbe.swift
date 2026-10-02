import Foundation
import CoreImage
import CoreGraphics
let base="/Users/AUDIT_USER/Documents/Codex/2026-09-22/ca/work/audit/image/"
let url=URL(fileURLWithPath:"/Users/AUDIT_USER/Documents/Codex/2026-09-22/ca/work/audit/ui/photos/A7401502.ARW")
let outputSpace=CGColorSpace(name:CGColorSpace.extendedLinearITUR_2020)!
let display=CGColorSpace(name:CGColorSpace.sRGB)!
let versions=CIRAWFilter(imageURL:url)!.supportedDecoderVersions
let configs:[(String,CGColorSpace?)]=[("default",nil),("linear-srgb",CGColorSpace(name:CGColorSpace.extendedLinearSRGB)),("linear-p3",CGColorSpace(name:CGColorSpace.extendedLinearDisplayP3)),("linear-rec2020",outputSpace)]
for version in versions where version.rawValue != "7" {
 for (name,working) in configs {
  let f=CIRAWFilter(imageURL:url)!;f.decoderVersion=version;f.scaleFactor=Float(512/max(f.nativeSize.width,f.nativeSize.height));f.boostAmount=0;f.boostShadowAmount=0;f.localToneMapAmount=0;f.isGamutMappingEnabled=false;f.contrastAmount=0;f.exposure=0;f.extendedDynamicRangeAmount=1;f.luminanceNoiseReductionAmount=0;f.colorNoiseReductionAmount=0
  var options:[CIContextOption:Any]=[.workingFormat:CIFormat.RGBAf,.cacheIntermediates:false];if let working {options[.workingColorSpace]=working}
  let context=CIContext(options:options);let image=f.outputImage!;let rect=image.extent;let w=Int(rect.width);let h=Int(rect.height)
  var pixels=[Float](repeating:0,count:w*h*4)
  context.render(image,toBitmap:&pixels,rowBytes:w*16,bounds:rect,format:.RGBAf,colorSpace:outputSpace)
  var means=[Double](repeating:0,count:3);var bad=0
  for i in stride(from:0,to:pixels.count,by:4){for c in 0..<3 {means[c]+=Double(pixels[i+c])};if pixels[i]<=0 || pixels[i+1]<=0 || pixels[i+2]<=0 {bad+=1}}
  means=means.map{$0/Double(w*h)}
  let record:[String:Any]=["decoder":version.rawValue,"working":name,"meanRec2020":means,"nonpositiveFraction":Double(bad)/Double(w*h)]
  print(String(data:try! JSONSerialization.data(withJSONObject:record,options:[.sortedKeys]),encoding:.utf8)!)
  try! context.writePNGRepresentation(of:image,to:URL(fileURLWithPath:base+"raw-v"+version.rawValue+"-working-"+name+".png"),format:.RGBA8,colorSpace:display)
 }
}
