import Foundation
import CoreImage
@testable import LumenCore
@testable import LumenPipeline
let ctx=CIContext(options:[.workingColorSpace:CGColorSpace(name:CGColorSpace.extendedLinearITUR_2020)!, .workingFormat:CIFormat.RGBAf])
func rms(_ a:ImageBuffer,_ b:ImageBuffer)->Double { guard a.width==b.width && a.height==b.height else{return -1};var s=0.0;for i in stride(from:0,to:a.pixels.count,by:4){for c in 0..<3{let d=Double(a.pixels[i+c]-b.pixels[i+c]);s += d*d}};return sqrt(s/Double(a.width*a.height*3)) }
for name in ["A7401502.ARW","A7401654.ARW","A7401693.ARW"] {
    do {
        let source=try AppleRawSource(url:URL(fileURLWithPath:"/Users/AUDIT_USER/Documents/Codex/2026-09-22/ca/work/audit/ui/photos/"+name))
        var base=Recipe();base.develop.denoise.mode = .off;base.develop.detail.capture.auto=false
        let scale=512/source.nativeLongEdge
        func pixels(_ recipe:Recipe)->ImageBuffer? { guard let image=source.decode(recipe:recipe,draft:false,scaleFactor:scale) else{return nil};return PipelineRenderer.buffer(from:image,context:ctx) }
        guard let off=pixels(base) else{print("decode failed \(name)");continue}
        var capture=base;capture.develop.detail.capture.auto=true;capture.develop.detail.capture.amount=150
        var ai=base;ai.develop.denoise.mode = .ai;ai.develop.denoise.amount=100
        var lens=base;lens.develop.geometry.lens.profile=false
        let record:[String:Any]=["photo":name,"nativeLongEdge":source.nativeLongEdge,"ISO":source.captureMetadata.iso ?? -1,"capture0to150RMS":pixels(capture).map{rms(off,$0)} ?? -1,"aiOffTo100RMS":pixels(ai).map{rms(off,$0)} ?? -1,"lensOnOffRMS":pixels(lens).map{rms(off,$0)} ?? -1,"readPixels":off.width*off.height]
        print(String(data:try! JSONSerialization.data(withJSONObject:record,options:.sortedKeys),encoding:.utf8)!)
    } catch {print("\(name): \(error)")}
}
