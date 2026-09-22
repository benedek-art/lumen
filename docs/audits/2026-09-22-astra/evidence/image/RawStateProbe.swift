import Foundation
import CoreImage
let url=URL(fileURLWithPath:"/Users/AUDIT_USER/Documents/Codex/2026-09-22/ca/work/audit/ui/photos/A7401502.ARW")
for v in CIRAWFilter(imageURL:url)!.supportedDecoderVersions {
 let f=CIRAWFilter(imageURL:url)!;f.decoderVersion=v
 for draft in [false,true,false] {
  for scale:Float in [0.1,0.5,1] {
   f.isDraftModeEnabled=draft;f.scaleFactor=scale
   print("decoder",v.rawValue,"draft",draft,"scale",scale,"native-before",f.nativeSize,"output",f.outputImage?.extent as Any,"native-after",f.nativeSize)
  }
 }
}
