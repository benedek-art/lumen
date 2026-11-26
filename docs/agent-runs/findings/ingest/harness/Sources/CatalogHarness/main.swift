// Sidebar persistence harness: albums, target album, smart albums, keywords, synonyms and
// stacks through LumenCore's real CatalogStore on a real SQLite file, then the store is
// dropped and a NEW CatalogStore is opened on the same files (what a relaunch does) and
// everything is read back. Prints PASS/FAIL lines.
import Foundation
import LumenCore

var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () throws -> String = "") {
    if ok { passed += 1; print("PASS " + name) }
    else { failed += 1; print("FAIL " + name + " :: " + ((try? detail()) ?? "?")) }
}
let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
              : NSTemporaryDirectory() + "lumen-sidebar-" + UUID().uuidString)
try? FileManager.default.removeItem(at: dir)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let dbPath = dir.appendingPathComponent("lumen.db").path
let cachePath = dir.appendingPathComponent("cache.db").path

func albumCount(_ s: CatalogStore, _ id: Int64) throws -> Int {
    var q = PhotoQuery(); q.albumID = id; return try s.countPhotos(matching: q)
}

var ids: [Int64] = []
var folderID: Int64 = 0
var selects: Int64 = 0, dupName: Int64 = 0, smart: Int64 = 0, stackID: Int64 = 0
do {
    let s = try CatalogStore(path: dbPath, cachePath: cachePath)
    folderID = try s.registerFolder(path: "/Volumes/Shoots/2026-11-26")
    let files = (1...12).map { ScannedFile(filename: String(format: "DSC%05d.ARW", $0),
                                           fileSize: Int64(20_000_000 + $0),
                                           fileMTime: 1_764_000_000 + Int64($0), ext: "arw") }
    _ = try s.scan(folderID: folderID, files: files)
    ids = try files.compactMap { try s.photo(folderID: folderID, filename: $0.filename)?.id }
    check("seeded 12 photos", ids.count == 12)

    // Albums
    selects = try s.createCollection(name: "Selects")
    try s.setTargetCollection(selects)
    try s.addToCollection(selects, photoIDs: Array(ids[0..<5]))
    try s.addToCollection(selects, photoIDs: Array(ids[3..<6]))   // B pressed again on overlap
    check("album count after B on 5 then on 3 overlapping = 6 (no double count)",
          try albumCount(s, selects) == 6, "\(try albumCount(s, selects))")
    dupName = try s.createCollection(name: "Selects")
    let names = try s.collections().map(\.name)
    print("  note: two albums named \"Selects\" can coexist: \(names)")
    check("rename album", try s.renameCollection(id: selects, to: "Keepers"))
    try s.removeFromCollection(selects, photoIDs: [ids[0]])
    check("remove 1 from album -> 5", try albumCount(s, selects) == 5)
    try s.deleteCollection(id: dupName)
    var all = PhotoQuery()
    check("deleting an album leaves all 12 photos", try s.countPhotos(matching: all) == 12)

    // Smart album: 3 stars or more
    for (i, id) in ids.enumerated() { try s.setRating(i < 4 ? 3 : 1, photoID: id) }
    var f = LibraryFilter(); f.minRating = 3
    smart = try s.createCollection(name: "3 stars", kind: CollectionRow.smartKind,
                                   query: f.savedJSON(), scope: CollectionQueryScope.currentFolder.storedName,
                                   scopeID: CollectionQueryScope.currentFolder.storedID, pinned: true)
    func smartCount(_ s: CatalogStore) throws -> Int {
        let row = try s.collection(id: smart)!
        let filter = LibraryFilter(savedJSON: row.query!)!
        var q = filter.query(sortKey: .captureTime, ascending: true, albumID: nil)
        q.sourceScope = try CollectionQueryScope(stored: row.scope, id: row.scopeID)
        return try s.countPhotos(matching: q, folderID: folderID)
    }
    check("smart album 3★+ counts 4", try smartCount(s) == 4, "\(try smartCount(s))")
    try s.setRating(5, photoID: ids[10])
    check("rating a 5th photo 5★ makes the smart album count 5", try smartCount(s) == 5)

    // Keywords
    _ = try s.addKeyword("Travel > Japan > Kyoto", photoIDs: Array(ids[0..<10]))
    _ = try s.addKeyword("sunset", photoIDs: [ids[0], ids[1]])
    try s.removeKeyword("sunset", photoIDs: [ids[0], ids[5]])   // ids[5] never had it
    check("hierarchical keyword on photo 3", try s.keywords(photoID: ids[2]).contains { $0.contains("Kyoto") },
          "\(try s.keywords(photoID: ids[2]))")
    check("remove from mixed selection removes only where present",
          try !s.keywords(photoID: ids[0]).contains("sunset") && s.keywords(photoID: ids[1]).contains("sunset"))
    _ = try s.addSynonym("Kioto", toKeyword: "Travel > Japan > Kyoto")
    var kq = PhotoQuery(); kq.keywords = ["Kioto"]
    print("  keyword query via synonym 'Kioto' counts: \(try s.countPhotos(matching: kq))")
    _ = try s.addKeyword("travel/japan/kyoto", photoIDs: [ids[11]])
    print("  'travel/japan/kyoto' typed with slashes is stored as: \(try s.keywords(photoID: ids[11]))")

    // Stacks
    stackID = try s.createStack(origin: "manual", photoIDs: Array(ids[4..<10]), pickPhotoID: ids[4])
    try s.setStackPick(ids[7], stackID: stackID)
    try s.setStackCollapsed(true, stackID: stackID)
    check("stack has 6 members", try s.stackMembers(stackID: stackID).count == 6)
    var tops = PhotoQuery(); tops.stackState = .collapsedTopsOnly
    print("  collapsed-tops query count: \(try s.countPhotos(matching: tops)) (12 photos, one 6-stack)")
    print("  album 'Keepers' count with 2 of its members inside a collapsed stack: \(try albumCount(s, selects))")
    all = PhotoQuery()
    _ = all
}
// ---------------- relaunch: a fresh store on the same files
do {
    let s = try CatalogStore(path: dbPath, cachePath: cachePath)
    let rows = try s.collections()
    print("  after reopen collections: \(rows.map { "\($0.name)[\($0.kind)] target=\($0.isTarget)" })")
    check("relaunch: renamed album survives", rows.contains { $0.id == selects && $0.name == "Keepers" })
    check("relaunch: deleted album stays deleted (by name)", !rows.contains { $0.name == "Selects" })
    print("  note: deleted album id \(dupName); smart album created after it got id \(smart) (rowid reuse: \(dupName == smart))")
    check("relaunch: target album survives", try s.targetCollectionID() == selects)
    check("relaunch: album membership survives (5)", try albumCount(s, selects) == 5)
    check("relaunch: smart album survives", rows.contains { $0.id == smart && $0.kind == CollectionRow.smartKind })
    check("relaunch: keywords survive", try s.keywords(photoID: ids[2]).contains { $0.contains("Kyoto") })
    check("relaunch: synonyms survive", try s.synonyms(ofKeyword: "Travel > Japan > Kyoto").contains("Kioto"),
          "\(try s.synonyms(ofKeyword: "Travel > Japan > Kyoto"))")
    let st = try s.stack(containing: ids[5])
    check("relaunch: stack, pick and collapsed survive",
          st?.id == stackID && st?.pickPhotoID == ids[7] && st?.collapsed == true, "\(String(describing: st))")
    try s.dissolveStack(id: stackID)
    check("unstack dissolves", try s.stack(containing: ids[5]) == nil)
    var all = PhotoQuery()
    check("unstack keeps all photos", try s.countPhotos(matching: all) == 12)
    _ = all
    // deleting a photo from the catalog drops it from album counts
    _ = try s.deletePhoto(id: ids[1])
    check("album count follows a removed photo (5 -> 4)", try albumCount(s, selects) == 4)
    all = PhotoQuery()
}
print("\n\(passed)/\(passed + failed) catalog checks passed")
