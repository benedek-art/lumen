import Foundation
import CoreImage
import ImageIO
let base="/Users/AUDIT_USER/Documents/Codex/2026-09-22/ca/work/audit/ui/photos/"
for name in ["A7401502","A7401654","A7401693"] {
 let url=URL(fileURLWithPath:base+name+".ARW")
 let src=CGImageSourceCreateWithURL(url as CFURL,nil)!
 let props=CGImageSourceCopyPropertiesAtIndex(src,0,nil)! as NSDictionary
 let w=props[kCGImagePropertyPixelWidth] ?? "nil"
 let h=props[kCGImagePropertyPixelHeight] ?? "nil"
 let exif=props[kCGImagePropertyExifDictionary] as? NSDictionary
 print(name,"ImageIO",w,h,"EXIF",exif?[kCGImagePropertyExifPixelXDimension] ?? "nil",exif?[kCGImagePropertyExifPixelYDimension] ?? "nil","imageCount",CGImageSourceGetCount(src))
 let orig=CIRAWFilter(imageURL:url)!
 print(name,"default",orig.decoderVersion.rawValue,"native",orig.nativeSize,"scale",orig.scaleFactor,"output",orig.outputImage?.extent as Any)
 for v in orig.supportedDecoderVersions {
  for lens in [false,true] {
   let f=CIRAWFilter(imageURL:url)!
   f.decoderVersion=v;f.scaleFactor=1;f.isDraftModeEnabled=false;f.isLensCorrectionEnabled=lens
   print(name,"decoder",v.rawValue,"lens",lens,"native",f.nativeSize,"scale",f.scaleFactor,"output",f.outputImage?.extent as Any)
  }
 }
}
