import Foundation
import CoreImage
let url=URL(fileURLWithPath:"/Users/AUDIT_USER/Documents/Codex/2026-09-22/ca/work/audit/ui/photos/A7401502.ARW")
for v in CIRAWFilter(imageURL:url)!.supportedDecoderVersions {
 let f=CIRAWFilter(imageURL:url)!;f.decoderVersion=v;f.isDraftModeEnabled=false
 for target in [512.0,2560,2560,2560,2560,2560] {
  let native=max(f.nativeSize.width,f.nativeSize.height)
  f.scaleFactor=Float(min(1,target/native))
  let image=f.outputImage!
  let obj:[String:Any]=["decoder":v.rawValue,"target":target,"nativeBefore":native,"scale":f.scaleFactor,"outputWidth":image.extent.width,"outputHeight":image.extent.height,"nativeAfter":max(f.nativeSize.width,f.nativeSize.height)]
  print(String(data:try! JSONSerialization.data(withJSONObject:obj,options:[.sortedKeys]),encoding:.utf8)!)
 }
}
