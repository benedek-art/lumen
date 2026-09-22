import Foundation
import CoreGraphics
import ImageIO
import LumenCore
import LumenPipeline

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let context = CGContext(data:nil,width:32,height:24,bitsPerComponent:8,bytesPerRow:0,
    space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(CGColor(red:0.3,green:0.4,blue:0.5,alpha:1)); context.fill(CGRect(x:0,y:0,width:32,height:24))
let sourceURL = root.appendingPathComponent("synthetic-metadata.jpg")
let sourceMetadata: [CFString:Any] = [
    kCGImagePropertyExifDictionary:[kCGImagePropertyExifDateTimeOriginal:"2000:01:02 03:04:05",
        kCGImagePropertyExifBodySerialNumber:"SYNTHETIC-BODY",kCGImagePropertyExifLensSerialNumber:"SYNTHETIC-LENS"],
    kCGImagePropertyExifAuxDictionary:[kCGImagePropertyExifAuxSerialNumber:"SYNTHETIC-AUX"],
    kCGImagePropertyGPSDictionary:[kCGImagePropertyGPSLatitude:31,kCGImagePropertyGPSLongitude:32,
        kCGImagePropertyGPSLatitudeRef:"N",kCGImagePropertyGPSLongitudeRef:"E"],
    kCGImagePropertyIPTCDictionary:[kCGImagePropertyIPTCKeywords:["source-tag"]],
    kCGImagePropertyTIFFDictionary:[kCGImagePropertyTIFFModel:"Synthetic Camera"]]
let dst = CGImageDestinationCreateWithURL(sourceURL as CFURL,"public.jpeg" as CFString,1,nil)!
CGImageDestinationAddImage(dst,context.makeImage()!,sourceMetadata as CFDictionary)
precondition(CGImageDestinationFinalize(dst))
let source = try RenderedImageSource(url:sourceURL)
let renderer = PipelineRenderer()
var recipe = Recipe(); recipe.develop.denoise.mode = .off
func summary(_ url:URL) -> [String:Any] {
    let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(url as CFURL,nil)!,0,nil)! as NSDictionary
    let exif = props[kCGImagePropertyExifDictionary] as? NSDictionary ?? [:]
    let aux = props[kCGImagePropertyExifAuxDictionary] as? NSDictionary ?? [:]
    let iptc = props[kCGImagePropertyIPTCDictionary] as? NSDictionary ?? [:]
    let tiff = props[kCGImagePropertyTIFFDictionary] as? NSDictionary ?? [:]
    return ["file":url.lastPathComponent,"GPSPresent":props[kCGImagePropertyGPSDictionary] != nil,
        "bodySerial":exif[kCGImagePropertyExifBodySerialNumber] ?? "absent",
        "lensSerial":exif[kCGImagePropertyExifLensSerialNumber] ?? "absent",
        "auxSerial":aux[kCGImagePropertyExifAuxSerialNumber] ?? "absent",
        "captureDate":exif[kCGImagePropertyExifDateTimeOriginal] ?? "absent",
        "keywords":iptc[kCGImagePropertyIPTCKeywords] ?? [],
        "copyright":iptc[kCGImagePropertyIPTCCopyrightNotice] ?? tiff[kCGImagePropertyTIFFCopyright] ?? "absent",
        "contact":iptc[kCGImagePropertyIPTCContact] ?? "absent",
        "DPIWidth":props[kCGImagePropertyDPIWidth] ?? "absent"]
}
print(String(data:try JSONSerialization.data(withJSONObject:summary(sourceURL),options:.sortedKeys),encoding:.utf8)!)
for format in ExportFormat.allCases {
    for keep in [true,false] {
        let url = root.appendingPathComponent("\(keep ? "keep" : "strip").\(format.fileExtension)")
        let policy = MetadataPolicy(includeEXIF:keep,includeCameraSerial:false,includeGPS:false,
                                    includeKeywords:keep,copyright:"Copyright Synthetic",contact:"contact@example.invalid")
        _ = try renderer.export(source:source,recipe:recipe,to:url,using:ExportRecipe(name:"audit",format:format,
            bitDepth:format == .tiff || format == .png ? 16 : 8,resolutionPPI:240,metadata:policy))
        print(String(data:try JSONSerialization.data(withJSONObject:summary(url),options:.sortedKeys),encoding:.utf8)!)
    }
}
