import Foundation
import CoreImage
import CoreGraphics
import LumenCore
import LumenPipeline
let base="/Users/AUDIT_USER/Documents/Codex/2026-09-22/ca/work/audit/image"
let url=URL(fileURLWithPath:"/Users/AUDIT_USER/Documents/Codex/2026-09-22/ca/work/audit/ui/photos/A7401502.ARW")
let working=CGColorSpace(name:CGColorSpace.extendedLinearITUR_2020)!
let display=CGColorSpace(name:CGColorSpace.sRGB)!
let context=CIContext(options:[.workingColorSpace:working,.workingFormat:CIFormat.RGBAf,.cacheIntermediates:false])
func save(_ image:CIImage,_ name:String) {
 let rect=image.extent;let w=Int(rect.width);let h=Int(rect.height)
 var bytes=[Float](repeating:0,count:w*h*4)
 context.render(image,toBitmap:&bytes,rowBytes:w*16,bounds:rect,format:.RGBAf,colorSpace:working)
 var means=[Double](repeating:0,count:3);var nonpositive=0;var n=0
 for i in stride(from:0,to:bytes.count,by:4) {for c in 0..<3 {means[c]+=Double(bytes[i+c])};if bytes[i]<=0 || bytes[i+1]<=0 || bytes[i+2]<=0 {nonpositive+=1};n+=1}
 means=means.map{$0/Double(n)}
 print(name,"extent",rect,"mean",means,"nonpositiveFraction",Double(nonpositive)/Double(n),"center",Array(bytes[((h/2)*w+w/2)*4..<((h/2)*w+w/2)*4+4]))
 try! context.writePNGRepresentation(of:image,to:URL(fileURLWithPath:base+"/"+name+".png"),format:.RGBA8,colorSpace:display)
}
func fresh()->CIRAWFilter {let f=CIRAWFilter(imageURL:url)!;f.scaleFactor=Float(512/max(f.nativeSize.width,f.nativeSize.height));return f}
let defaults=fresh();print("original",defaults.decoderVersion.rawValue,defaults.supportedDecoderVersions.map{$0.rawValue},defaults.neutralTemperature,defaults.neutralTint)
save(defaults.outputImage!,"apple-default")
let flat=fresh();flat.boostAmount=0;flat.boostShadowAmount=0;flat.localToneMapAmount=0;flat.isGamutMappingEnabled=false;flat.contrastAmount=0;flat.exposure=0;flat.extendedDynamicRangeAmount=1;flat.luminanceNoiseReductionAmount=0;flat.colorNoiseReductionAmount=0
save(flat.outputImage!,"apple-flat")
for version in defaults.supportedDecoderVersions {
 let f=fresh();f.decoderVersion=version
 f.boostAmount=0;f.boostShadowAmount=0;f.localToneMapAmount=0;f.isGamutMappingEnabled=false;f.contrastAmount=0;f.exposure=0;f.extendedDynamicRangeAmount=1;f.luminanceNoiseReductionAmount=0;f.colorNoiseReductionAmount=0
 save(f.outputImage!,"apple-flat-v"+version.rawValue)
 f.neutralTemperature=defaults.neutralTemperature;f.neutralTint=defaults.neutralTint
 save(f.outputImage!,"apple-flat-written-wb-v"+version.rawValue)
}
let source=try! AppleRawSource(url:url);print("lumenAsShot",source.asShotTemperature,source.asShotTint,source.pinnedDecoderVersion as Any)
let recipe=Recipe();let decoded=source.decode(recipe:recipe,draft:false,scaleFactor:512/source.nativeLongEdge)!
save(decoded,"lumen-decoded")
var noDenoise=recipe;noDenoise.develop.denoise.mode = .off
let plan=RenderPlan(recipe:noDenoise,asShotKelvin:source.asShotTemperature,asShotTint:source.asShotTint)
print("plan",plan.toneIsIdentity,plan.colorGradeIsIdentity,plan.linear.matrix.m)
let rendered=RenderGraph().build(decoded,plan:plan,options:RenderGraph.Options(longEdge:512))
save(rendered,"lumen-render-no-denoise")
let defaultPlan=RenderPlan(recipe:recipe,asShotKelvin:source.asShotTemperature,asShotTint:source.asShotTint,captureISO:source.captureISO)
save(RenderGraph().build(decoded,plan:defaultPlan,options:RenderGraph.Options(longEdge:512)),"lumen-render-default")
for name in ["A7401654","A7401693"] {
 let otherURL=url.deletingLastPathComponent().appendingPathComponent(name+".ARW")
 let orig=CIRAWFilter(imageURL:otherURL)!;print("other",name,"default",orig.decoderVersion.rawValue,"supported",orig.supportedDecoderVersions.map{$0.rawValue})
 for version in [orig.decoderVersion,orig.supportedDecoderVersions.last!] {
  let f=CIRAWFilter(imageURL:otherURL)!;f.decoderVersion=version;f.scaleFactor=Float(512/max(f.nativeSize.width,f.nativeSize.height))
  f.boostAmount=0;f.boostShadowAmount=0;f.localToneMapAmount=0;f.isGamutMappingEnabled=false;f.contrastAmount=0;f.exposure=0;f.extendedDynamicRangeAmount=1;f.luminanceNoiseReductionAmount=0;f.colorNoiseReductionAmount=0
  save(f.outputImage!,name+"-flat-v"+version.rawValue)
 }
}
