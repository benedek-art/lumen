import Foundation
import LumenCore

let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try fm.createDirectory(at: root, withIntermediateDirectories: true)

func emit(_ name: String, _ values: [String: Any]) throws {
    let output: [String: Any] = ["case": name, "values": values]
    print(String(data: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), encoding: .utf8)!)
}

func ingestAlreadyShort() throws {
    let source = root.appendingPathComponent("source.RAF")
    let dest = root.appendingPathComponent("dest.RAF")
    try Data(repeating: 7, count: 100).write(to: source)
    try Data(repeating: 7, count: 100).write(to: dest)
    let plan = IngestPlan(copies: [IngestPlannedCopy(source: source, byteCount: 5000,
        destinations: [IngestPlannedDestination(url: dest, role: .primary)])])
    let report = VerifiedCopyDriver().run(plan)
    try emit("ingest-short-already-present", ["plannedBytes": 5000, "sourceBytes": try Data(contentsOf: source).count,
        "destinationBytes": try Data(contentsOf: dest).count, "allVerified": report.allVerified,
        "alreadyPresent": report.alreadyPresent.count, "reportedBytesCopied": report.bytesCopied,
        "summary": report.summary])
}

func sourceChange() throws {
    let store = try CatalogStore(path: root.appendingPathComponent("sourcechange.db").path,
                                 cachePath: root.appendingPathComponent("sourcechange-cache.db").path)
    defer { store.close() }
    let folder = try store.registerFolder(path: root.appendingPathComponent("photos").path)
    _ = try store.scan(folderID: folder, files: [ScannedFile(filename: "frame.jpg", fileSize: 100,
                   fileMTime: 10, quickSig: "old-original")])
    let id = try store.photo(folderID: folder, filename: "frame.jpg")!.id
    try store.recordPreview(PreviewRow(photoID: id, level: .thumb, path: "old-original.jpg", bytes: 30))
    let result = try store.scan(folderID: folder, files: [ScannedFile(filename: "frame.jpg", fileSize: 200,
                   fileMTime: 20, quickSig: nil)])
    let row = try store.photo(id: id)!
    let previews = try store.previews(photoID: id)
    let missingSigs = try store.photosMissingQuickSig(folderID: folder)
    let verdict = PreviewCache.decide(request: .thumb, fingerprint: "", stored: previews)
    try emit("changed-original-keeps-cache-and-signature", ["changed": result.changed, "id": id,
        "persistedQuickSignature": row.quickSig ?? "nil", "previewRows": previews.count,
        "previewDecision": String(describing: verdict), "signatureBackfillCandidates": missingSigs.count])
}

func sidecarNamingTransition() throws {
    let dng = root.appendingPathComponent("DSC_0001.DNG")
    let nef = root.appendingPathComponent("DSC_0001.NEF")
    var edited = Recipe()
    edited.develop.tone.exposure = 2
    let content = SidecarContent(rating: 5, recipeFingerprint: try RecipeFingerprint.fingerprint(edited),
                                 recipeJSON: try CanonicalJSON.canonicalRecipeJSON(edited))
    let initialSidecar = SidecarNaming.url(for: dng, isRaw: true, rawSiblingExtensions: [])
    try Data(XMPSidecar.serialize(content).utf8).write(to: initialSidecar)
    let dngAfter = SidecarNaming.url(for: dng, isRaw: true, rawSiblingExtensions: ["nef"])
    let nefAfter = SidecarNaming.url(for: nef, isRaw: true, rawSiblingExtensions: ["dng"])
    let incoming = try XMPSidecar.parse(Data(contentsOf: nefAfter))
    let resolution = SidecarMerge.resolve(catalog: SidecarMerge.State(), sidecar: incoming)
    try emit("dng-alone-then-nef", ["initialDNGSidecar": initialSidecar.lastPathComponent,
        "laterDNGSidecar": dngAfter.lastPathComponent, "laterNEFSidecar": nefAfter.lastPathComponent,
        "newNEFRating": resolution.state.rating, "newNEFExposure": resolution.state.recipe?.develop.tone.exposure ?? -999,
        "DNGSidecarExistsAfter": fm.fileExists(atPath: dngAfter.path)])
}

func sameSecondSidecarChange() throws {
    var old = Recipe(); old.develop.tone.exposure = 1
    var incoming = Recipe(); incoming.develop.tone.exposure = 2
    let state = SidecarMerge.State(recipe: old, recipeFingerprint: try RecipeFingerprint.fingerprint(old), sidecarMTime: 100)
    let sidecar = SidecarContent(recipeFingerprint: try RecipeFingerprint.fingerprint(incoming), recipeJSON: try CanonicalJSON.canonicalRecipeJSON(incoming))
    let result = SidecarMerge.resolve(catalog: state, sidecar: sidecar, sidecarMTime: 100)
    try emit("same-second-sidecar-change", ["catalogExposure": 1, "sidecarExposure": 2,
        "selectedExposure": result.state.recipe!.develop.tone.exposure, "decision": String(describing: result.decision)])
}

func lockedCatalogRecovery() throws {
    let path = root.appendingPathComponent("healthy-locked.db").path
    let cachePath = root.appendingPathComponent("healthy-locked-cache.db").path
    let backups = root.appendingPathComponent("locked-backups", isDirectory: true)
    try fm.createDirectory(at: backups, withIntermediateDirectories: true)
    let store = try CatalogStore(path: path, cachePath: cachePath)
    let folder = try store.registerFolder(path: root.appendingPathComponent("lock-photos").path)
    let id = try store.upsertPhoto(PhotoRow(folderID: folder, filename: "frame.jpg", rating: 1))
    try store.backup(to: backups.appendingPathComponent("lumen-2026-09-21.db").path)
    try store.setRating(5, photoID: id)
    store.close()
    let locking = try SQLiteDatabase(path: path)
    try locking.execute("PRAGMA locking_mode=EXCLUSIVE; BEGIN EXCLUSIVE;")
    let before = try locking.scalarInt("SELECT rating FROM photo WHERE id = ?", [.integer(id)])!
    let check = try SQLiteDatabase(path: path)
    var probeError = "none"
    do { _ = try check.scalarText("PRAGMA quick_check;") }
    catch { probeError = String(describing: error) }
    check.close()
    let recovery = CatalogStore.recoverIfNeeded(path: path, backupDirectory: backups.path)
    try locking.execute("ROLLBACK;")
    locking.close()
    let restored = try CatalogStore(path: path, cachePath: cachePath)
    defer { restored.close() }
    let after = try restored.photo(id: id)!.rating
    try emit("healthy-but-locked-recovery", ["beforeRating": before,
        "afterRating": after, "outcome": String(describing: recovery.outcome),
        "notice": recovery.notice ?? "nil", "probeError": probeError])
}

func latestRestrictedScanAndFalseRoot() throws {
    let store = try CatalogStore(path: root.appendingPathComponent("latest-subset.db").path,
                                 cachePath: root.appendingPathComponent("latest-subset-cache.db").path)
    defer { store.close() }
    let folder = try store.registerFolder(path: root.appendingPathComponent("subset-photos").path)
    let both = [ScannedFile(filename:"a.JPG",fileSize:100,fileMTime:10),
                ScannedFile(filename:"b.JPG",fileSize:200,fileMTime:10)]
    _ = try store.scan(folderID: folder, files: both)
    let a = try store.photo(folderID: folder, filename:"a.JPG")!.id
    let b = try store.photo(folderID: folder, filename:"b.JPG")!.id
    let album = try store.createCollection(name:"Both")
    try store.addToCollection(album, photoIDs:[a,b])
    var query = PhotoQuery(); query.albumID = album; query.includeMissing = false
    let albumBefore = try store.countPhotos(matching:query)
    let subset = try store.scan(folderID: folder, files:[both[0]])
    let albumAfter = try store.countPhotos(matching:query)
    try emit("latest-restricted-scan-marks-unselected-missing", ["missingIDs":subset.missing,
        "unselectedPhotoID":b,"unselectedMissing":try store.photo(id:b)!.missing,
        "albumCountBefore":albumBefore,"albumCountAfter":albumAfter])

    let falseRoot = root.appendingPathComponent("a/photos",isDirectory:true)
    let first = root.appendingPathComponent("a/day1/photos/DSC_0001.NEF")
    let second = root.appendingPathComponent("a/day2/photos/DSC_0001.NEF")
    let firstName = ScannedFile.catalogName(for:first,in:falseRoot)
    let secondName = ScannedFile.catalogName(for:second,in:falseRoot)
    let badFolder = try store.registerFolder(path:falseRoot.path)
    let scan = try store.scan(folderID:badFolder, files:[
        ScannedFile(filename:firstName,fileSize:100,fileMTime:10),
        ScannedFile(filename:secondName,fileSize:200,fileMTime:20)])
    let firstID = try store.photo(folderID:badFolder,filename:firstName)!.id
    let secondID = try store.photo(folderID:badFolder,filename:secondName)!.id
    var recipe = Recipe(); recipe.develop.tone.exposure = 1
    try store.saveRecipe(recipe,photoID:firstID,isCurrent:true)
    recipe.develop.tone.exposure = -2
    try store.saveRecipe(recipe,photoID:secondID,isCurrent:true)
    try emit("latest-false-root-collapses-originals", ["names":[firstName,secondName],
        "ids":[firstID,secondID],"addedIDs":scan.added,"rows":try store.photos(folderID:badFolder).count,
        "firstPhotoExposureAfterEditingSecond":try store.currentRecipe(photoID:firstID)!.develop.tone.exposure])
}

try ingestAlreadyShort()
try sourceChange()
try sidecarNamingTransition()
try sameSecondSidecarChange()
try lockedCatalogRecovery()
try latestRestrictedScanAndFalseRoot()
