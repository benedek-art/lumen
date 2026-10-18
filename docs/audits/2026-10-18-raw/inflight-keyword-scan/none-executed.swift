import Foundation
import LumenCore
final class ImportWitness {
    static func importKeywords(from sidecar: SidecarContent?, photoID: Int64,
                                       store: CatalogStore) {
        guard let words = sidecar?.keywords, !words.isEmpty else { return }
        do {
            // Against the catalog's LEAVES: the sidecar is flat, and "Iceland" in it is
            // the "Places > Iceland" the catalog already has.
            let missing = SidecarKeywordImport.missing(
                fromCatalog: try store.keywords(photoID: photoID).map(KeywordPath.leaf),
                sidecar: words)
            for word in missing {
                _ = try store.addKeyword(word, photoIDs: [photoID])
            }
        } catch {
            NSLog("Lumen catalog: could not import sidecar keywords — %@",
                  String(describing: error))
        }
    }
}
let root=FileManager.default.temporaryDirectory.appendingPathComponent("inflight-keyword-witness-\(UUID())")
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
defer {try? FileManager.default.removeItem(at:root)}
let store=try CatalogStore(path:root.appendingPathComponent("catalog.db").path)
defer {store.close()}
let folder=try store.registerFolder(path:root.path)
_=try store.scan(folderID:folder,files:[ScannedFile(filename:"frame.JPG",fileSize:1,fileMTime:1,ext:"jpg")])
let row=try store.photo(folderID:folder,filename:"frame.JPG")!
let file=root.appendingPathComponent("frame.JPG")
let legacy=CommandLine.arguments.contains("--legacy")
_=try store.addKeyword("Kept",photoIDs:[row.id])
if !legacy {_=try store.addKeyword("Private",photoIDs:[row.id])}
let record=UnsavedSidecarRecord(photoPath:file.path,photoID:row.id,stated:[.keywords],keywordEdit:legacy ? SidecarKeywordEdit(added:["Removed"]) : SidecarKeywordEdit(removed:["Private"]),generation:legacy ? nil : UUID().uuidString)
if legacy {try store.setMetaValue(UnsavedSidecarRecord.metaKey,UnsavedSidecarRecord.encode([record]))}
else {_=try store.withSidecarIntent {try store.removeKeyword("Private",photoIDs:[row.id]);return((),[record])}}
let pendingSidecars:[URL:(content:SidecarContent,stated:SidecarStatedFields)]=[:]
let unsavedSidecars=[file.path:record]
let sidecarLock=NSLock()
var external=SidecarContent();external.keywords=legacy ? ["Kept"] : ["Private","Kept"]
var sidecar:SidecarContent?=external
                        sidecarLock.lock()
                        // An explicit flush temporarily owns the pending entry.
                        // Its committed delta still governs imports until settled.
                        let owedKeywordEdit = unsavedSidecars[file.path].flatMap {
                            $0.photoID == row.id ? $0.keywordEdit : nil
                        }
                        let pendingKeywordEdit = pendingSidecars[file]?.content.keywordEdit ?? owedKeywordEdit
                        sidecarLock.unlock()
                        if let pendingKeywordEdit, !pendingKeywordEdit.isEmpty, var projected = sidecar {
                            // Match recovery's outlived-intent policy, including
                            // legacy records: do not revive an obsolete addition
                            // or replay a removal after the tag was added again.
                            let leaves = Set(try store.keywords(photoID: row.id).map(KeywordPath.leaf))
                            let currentEdit = SidecarKeywordEdit(
                                added: pendingKeywordEdit.added.filter { leaves.contains($0) },
                                removed: pendingKeywordEdit.removed.filter { !leaves.contains($0) })
                            projected.keywords = currentEdit.apply(to: projected.keywords ?? [])
                            sidecar = projected
                        }

ImportWitness.importKeywords(from:sidecar,photoID:row.id,store:store)
// The legacy startup-recovery policy filters the obsolete addition to an empty
// queued delta before the flush removes its pending entry. This harness models
// that queued payload; the native test executes actual recovery and publication.
let published=(legacy ? SidecarKeywordEdit() : record.keywordEdit!).apply(to:external.keywords!)
_=try store.settleSidecarIntents([SidecarIntentPublication(photoPath:file.path,photoID:row.id,generation:record.generation)])
let actual=try store.keywords(photoID:row.id)
let owed=try UnsavedSidecarRecord.decodeValidated(store.metaValue(UnsavedSidecarRecord.metaKey))
print("catalog=\(actual) published=\(published) remainingDebt=\(owed.count)")
if actual != ["Kept"] || published != ["Kept"] || !owed.isEmpty {exit(1)}
