import Foundation
import AppKit
import ImageIO
import LumenCore

enum PhotoFlag { case none, picked, rejected }
enum ColorLabel: String, CaseIterable {
    case none, red, yellow, green, blue, purple
    var displayName: String { rawValue.capitalized }
}
struct PhotoItem {
    let id: URL
    var catalogID: Int64?
    var flag: PhotoFlag = .none
    var rating: Int = 0
    var label: ColorLabel = .none
}
struct CollectionItem { var id: Int64; var name: String; var count: Int; var isTarget: Bool }
enum PhotoFormats {
    static let raw: Set<String> = ["arw", "sr2", "srf", "arq", "cr2", "cr3", "crw", "nef", "nrw", "orf", "pef", "dng", "raf", "rw2", "rwl", "srw", "erf", "x3f", "3fr", "fff", "iiq", "cap", "mrw", "dcr", "kdc", "mef", "raw"]
    static let rendered: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff"]
    static func isRaw(_ url: URL) -> Bool { raw.contains(url.pathExtension.lowercased()) }
    static func isRendered(_ url: URL) -> Bool { rendered.contains(url.pathExtension.lowercased()) }
}

@main struct PreviewProbe {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let photos = root.appendingPathComponent("photos", isDirectory: true)
        try fm.createDirectory(at: photos, withIntermediateDirectories: true)
        let url = photos.appendingPathComponent("photo.jpg")
        try Data([1,2,3]).write(to: url)
        let service = try CatalogService(directory: root.appendingPathComponent("catalog"))
        let id = service.registerAndLoad(folder: photos, files: [url])[url]!.catalogID
        let cache = root.appendingPathComponent("previews", isDirectory: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let previews = PreviewStore(catalog: service, directory: cache)
        previews.register([url:id])
        let thumbnails = ThumbnailLoader()
        thumbnails.attach(previews: previews)
        var old = Recipe(); old.develop.tone.exposure = 0
        var newer = old; newer.develop.tone.exposure = 2
        service.saveRecipe(old, url: url, catalogID: id)
        _ = await service.previewState(photoID: id)
        let context = CGContext(data: nil, width: 2560, height: 8, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2560, height: 8))
        let oldPixels = context.makeImage()!
        // Both calls execute on one uninterrupted MainActor turn. recordDeveloped's
        // unstructured task cannot capture the catalog fingerprint until we yield.
        thumbnails.recordDeveloped(url: url, image: oldPixels)
        service.saveRecipe(newer, url: url, catalogID: id)
        var rows: [PreviewRow] = []
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            rows = await service.previewState(photoID: id)?.rows ?? []
            if !rows.isEmpty { break }
        }
        let oldFP = try RecipeFingerprint.fingerprint(old)
        let newFP = try RecipeFingerprint.fingerprint(newer)
        let payload = await previews.plan(for: url, pixels: 2560)?.payload
        let values: [String: Any] = ["oldExposure":0,"newExposure":2,"oldFingerprint":oldFP,
            "newFingerprint":newFP,"recordedFingerprints":rows.map(\.recipeFP),
            "recordedLevels":rows.map { $0.level.rawValue },"oldImageServedAsCurrent":payload?.recipeFP == newFP,
            "payloadPath":payload?.file.path ?? "none"]
        print(String(data: try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]), encoding: .utf8)!)
        service.close()
    }
}
