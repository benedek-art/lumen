import Foundation
import CoreImage
import LumenCore
import LumenPipeline
let url=URL(fileURLWithPath:"/Users/AUDIT_USER/Documents/Codex/2026-09-22/ca/work/audit/ui/photos/A7401502.ARW")
let source=try! AppleRawSource(url:url)
let recipe=Recipe()
for target in [512.0,2560,2560,2560,2560] {
 let native=source.nativeLongEdge
 let scale=min(1,target/native)
 let image=source.decode(recipe:recipe,draft:false,scaleFactor:scale)!
 let obj:[String:Any]=["target":target,"nativeBefore":native,"scale":scale,"outputWidth":image.extent.width,"outputHeight":image.extent.height,"nativeAfter":source.nativeLongEdge,"pixelWidthAfter":source.nativePixelSize.width,"pixelHeightAfter":source.nativePixelSize.height]
 print(String(data:try! JSONSerialization.data(withJSONObject:obj,options:[.sortedKeys]),encoding:.utf8)!)
}
