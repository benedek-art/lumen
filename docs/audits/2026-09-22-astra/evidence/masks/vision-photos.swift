import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import LumenCore
@testable import LumenPipeline

let outDir="/Users/AUDIT_USER/Documents/Codex/2026-09-22/ca/work/audit/masks/"
let ctx=CIContext()
let renderer=PipelineRenderer()
func writePNG(_ image:CGImage,_ filename:String) {
    let destination=CGImageDestinationCreateWithURL(URL(fileURLWithPath:outDir+filename) as CFURL,UTType.png.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(destination,image,nil)
    precondition(CGImageDestinationFinalize(destination))
}
for name in ["A7401502","A7401654","A7401693"] {
    do {
        let source=try AppleRawSource(url:URL(fileURLWithPath:"/Users/AUDIT_USER/Documents/Codex/2026-09-22/ca/work/audit/ui/photos/"+name+".ARW"))
        let before=Date()
        guard let original=renderer.matteSourceImage(source:source,maxLongEdge:1024) else { print("missing neutral \(name)");continue }
        let neutralMS=Date().timeIntervalSince(before)*1000
        writePNG(original,name+"-neutral.png")
        let base=CIImage(cgImage:original)
        let red=CIImage(color:CIColor(red:1,green:0.12,blue:0.02)).cropped(to:base.extent)
        for (label,kinds) in [("subject",Set([MaskKind.aiSubject,MaskKind.aiBackground])),("people",Set([MaskKind.aiPerson]))] {
            let start=Date()
            let planes=VisionMattes.generate(image:original,kinds:kinds)
            let elapsed=Date().timeIntervalSince(start)*1000
            var record:[String:Any]=["photo":name,"kind":label,"neutralMilliseconds":neutralMS,"visionMilliseconds":elapsed,"inputWidth":original.width,"inputHeight":original.height,"keys":planes.keys.sorted()]
            if let plane=planes[label == "subject" ? MaskKind.aiSubject.rawValue:MaskKind.aiPerson.rawValue] {
                record["matteWidth"]=plane.width;record["matteHeight"]=plane.height
                record["maximum"]=Double(plane.values.max() ?? 0)
                record["meanCoverage"]=plane.values.reduce(0.0){$0+Double($1)}/Double(plane.values.count)
                record["fractionAboveHalf"]=Double(plane.values.filter{$0>0.5}.count)/Double(plane.values.count)
                if let background=planes[MaskKind.aiBackground.rawValue] {
                    record["complementMaxError"]=zip(plane.values,background.values).map{abs(Double($0+$1)-1)}.max() ?? -1
                }
                if let alpha=PipelineRenderer.image(from:plane.map{$0*0.4},targetExtent:base.extent) {
                    let greyAlpha=alpha.applyingFilter("CIColorMatrix",parameters:["inputRVector":CIVector(x:1,y:0,z:0,w:0),"inputGVector":CIVector(x:1,y:0,z:0,w:0),"inputBVector":CIVector(x:1,y:0,z:0,w:0)])
                    let overlay=red.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:base,kCIInputMaskImageKey:greyAlpha])
                    if let result=ctx.createCGImage(overlay,from:base.extent) {writePNG(result,name+"-"+label+"-overlay.png")}
                }
                if let mask=PipelineRenderer.image(from:plane,targetExtent:base.extent) {
                    let grey=mask.applyingFilter("CIColorMatrix",parameters:["inputRVector":CIVector(x:1,y:0,z:0,w:0),"inputGVector":CIVector(x:1,y:0,z:0,w:0),"inputBVector":CIVector(x:1,y:0,z:0,w:0)])
                    if let result=ctx.createCGImage(grey,from:base.extent) {writePNG(result,name+"-"+label+"-matte.png")}
                }
            }
            print(String(data:try! JSONSerialization.data(withJSONObject:record,options:.sortedKeys),encoding:.utf8)!)
            fflush(stdout)
        }
    } catch { print("\(name): \(error)") }
}
