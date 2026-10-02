import Foundation
import LumenCore

// Minimal app-model declarations consumed by the unchanged CatalogService.swift.
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

@main struct Probe {
    static func emit(_ name: String, _ values: [String: Any]) throws {
        print(String(data: try JSONSerialization.data(withJSONObject: ["case": name, "values": values],
                         options: [.sortedKeys]), encoding: .utf8)!)
        fflush(stdout)
    }
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let sizes = CommandLine.arguments.dropFirst(2).compactMap(Int.init)
        for count in (sizes.isEmpty ? [100,500,1000] : sizes) {
            let folder = root.appendingPathComponent("photos-\(count)", isDirectory: true)
            let catalog = root.appendingPathComponent("catalog-\(count)", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var files: [URL] = []
            for index in 0..<count {
                let file = folder.appendingPathComponent(String(format: "DSC_%05d.JPG", index))
                try Data([1,2,3]).write(to: file)
                files.append(file)
            }
            let service = try CatalogService(directory: catalog)
            service.onFailure = { print("FAILURE: \($0)") }
            for pass in 1...2 {
                let start = Date()
                let rows = service.registerAndLoad(folder: folder, files: files)
                try emit("register-no-sidecars", ["count": count, "pass": pass, "rows": rows.count,
                                                   "seconds": Date().timeIntervalSince(start)])
            }
            service.close()
        }
        let folder = root.appendingPathComponent("sidecar-transition", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let dng = folder.appendingPathComponent("DSC_0001.DNG")
        let nef = folder.appendingPathComponent("DSC_0001.NEF")
        try Data([1,2,3]).write(to: dng)
        let service = try CatalogService(directory: root.appendingPathComponent("sidecar-catalog"))
        let initial = service.registerAndLoad(folder: folder, files: [dng])[dng]!
        var recipe = Recipe(); recipe.develop.tone.exposure = 2
        service.saveRecipe(recipe, url: dng, catalogID: initial.catalogID)
        service.close()
        try Data([4,5,6]).write(to: nef)
        let reopened = try CatalogService(directory: root.appendingPathComponent("sidecar-catalog"))
        let rows = reopened.registerAndLoad(folder: folder, files: [dng,nef])
        try emit("service-sidecar-transition", ["dngExposure": rows[dng]?.recipe?.develop.tone.exposure ?? -999,
            "nefExposure": rows[nef]?.recipe?.develop.tone.exposure ?? -999,
            "sidecars": try fm.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".xmp") }])
        reopened.close()

        let blockedFolder = root.appendingPathComponent("blocked-sidecar", isDirectory: true)
        try fm.createDirectory(at: blockedFolder, withIntermediateDirectories: true)
        let blockedPhoto = blockedFolder.appendingPathComponent("photo.JPG")
        try Data([1,2,3]).write(to: blockedPhoto)
        let blockedPath = blockedPhoto.appendingPathExtension("xmp")
        try fm.createDirectory(at: blockedPath, withIntermediateDirectories: true)
        let blockedService = try CatalogService(directory: root.appendingPathComponent("blocked-catalog"))
        var errors: [String] = []
        blockedService.onFailure = { errors.append($0) }
        let blockedID = blockedService.registerAndLoad(folder: blockedFolder, files: [blockedPhoto])[blockedPhoto]!.catalogID
        blockedService.saveRecipe(recipe, url: blockedPhoto, catalogID: blockedID)
        blockedService.close()
        try emit("sidecar-write-failure-not-surfaced", ["reportedFailures":errors,
            "sidecarIsStillDirectory":(try blockedPath.resourceValues(forKeys: [.isDirectoryKey])).isDirectory ?? false])

        let blobCatalog = root.appendingPathComponent("blob-backup-catalog", isDirectory: true)
        let blobService = try CatalogService(directory: blobCatalog)
        let brush = BrushStrokeSet(strokes:[BrushStroke(points:[BrushPoint(x: 0.5,y: 0.5)])])
        let ref = try blobService.blobs.store(brush)
        let blobPhotoDirectory = root.appendingPathComponent("blob-photos", isDirectory: true)
        try fm.createDirectory(at: blobPhotoDirectory, withIntermediateDirectories: true)
        let blobPhoto = blobPhotoDirectory.appendingPathComponent("brush.JPG")
        try Data([1,2,3]).write(to: blobPhoto)
        let blobPhotoID = blobService.registerAndLoad(folder: blobPhotoDirectory, files: [blobPhoto])[blobPhoto]!.catalogID
        var brushComponent = MaskComponent(op: .add, kind: .brush)
        brushComponent.strokesRef = ref
        var paintedMask = Mask(id: "audit-brush", name: "Audit painting", components: [brushComponent])
        paintedMask.adjust.exposure = 1
        var paintedRecipe = Recipe()
        paintedRecipe.masks = [paintedMask]
        blobService.saveRecipe(paintedRecipe, url: blobPhoto, catalogID: blobPhotoID)
        let blobPath = blobService.blobs.url(for: ref)!
        try fm.setAttributes([.posixPermissions:0o000], ofItemAtPath: blobPath.path)
        var backupErrors: [String] = []
        blobService.onFailure = { backupErrors.append($0) }
        blobService.close()
        try fm.setAttributes([.posixPermissions:0o644], ofItemAtPath: blobPath.path)
        let backupDir = blobCatalog.appendingPathComponent("backups",isDirectory:true)
        let published = try fm.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "db" }
        let missingFromBackups = published.filter { backup in
            let blobs = backup.deletingPathExtension().appendingPathExtension("blobs")
            return !fm.fileExists(atPath: blobs.appendingPathComponent(blobPath.lastPathComponent).path)
        }
        try emit("failed-blob-backup-still-published", ["errors":backupErrors,
            "publishedBackups":published.map(\.lastPathComponent),
            "backupsMissingBlob":missingFromBackups.map(\.lastPathComponent), "blobReference":ref])

        // Restore only this failed backup into a fresh audit directory, as when the
        // live catalog/blob volume is unavailable. Originals and live audit catalog
        // remain untouched; no sidecar import is performed before measuring recovery.
        let freshDirectory = root.appendingPathComponent("restore-incomplete-backup", isDirectory: true)
        let freshBackups = freshDirectory.appendingPathComponent("backups", isDirectory: true)
        try fm.createDirectory(at: freshBackups, withIntermediateDirectories: true)
        for backup in published {
            try fm.copyItem(at: backup, to: freshBackups.appendingPathComponent(backup.lastPathComponent))
            let paired = backup.deletingPathExtension().appendingPathExtension("blobs")
            if fm.fileExists(atPath: paired.path) {
                try fm.copyItem(at: paired, to: freshBackups.appendingPathComponent(paired.lastPathComponent))
            }
        }
        try Data("synthetic damaged audit catalog".utf8).write(to: freshDirectory.appendingPathComponent("lumen.db"))
        let recoveredService = try CatalogService(directory: freshDirectory)
        let recoveredStore = try CatalogStore(path: freshDirectory.appendingPathComponent("lumen.db").path,
            cachePath: freshDirectory.appendingPathComponent("cache.db").path)
        let restoredRecipe = try recoveredStore.currentRecipe(photoID: blobPhotoID)!
        let restoredSets = recoveredService.blobs.strokeSets(for: restoredRecipe)
        let beforePlane = MaskRaster.combine(mask: paintedRecipe.masks[0], size: (width:128,height:128), source:nil, strokeSets:[ref:brush])
        let afterPlane = MaskRaster.combine(mask: restoredRecipe.masks[0], size: (width:128,height:128), source:nil, strokeSets:restoredSets)
        try emit("restore-incomplete-backup", ["recovery":String(describing:recoveredService.recovery.outcome),
            "restoredRecipeRef":restoredRecipe.masks.first?.components.first?.strokesRef ?? "none",
            "restoredPayloadCount":restoredSets.count,"beforeMaskSum":beforePlane.values.reduce(0,+),
            "afterMaskSum":afterPlane.values.reduce(0,+)])
        recoveredStore.close()
        recoveredService.close()
    }
}
