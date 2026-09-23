import Foundation
import ImageIO
for path in CommandLine.arguments.dropFirst() {
    let source = CGImageSourceCreateWithURL(URL(fileURLWithPath:path) as CFURL,nil)!
    print("FILE: \(path)")
    print(CGImageSourceCopyPropertiesAtIndex(source,0,nil)!)
    if let metadata = CGImageSourceCopyMetadataAtIndex(source,0,nil),
       let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] {
        for tag in tags {
            print("TAG: \(CGImageMetadataTagCopyName(tag)!) = \(CGImageMetadataTagCopyValue(tag)!)")
        }
    }
}
