// Synthetic portable persistence witness; not CatalogService or UI/RAW timings.
import Foundation
import Dispatch
import LumenCore
func require(_ condition: Bool) { precondition(condition) }
func timed(_ f: () throws -> Void) rethrows -> Double {
 let start=DispatchTime.now().uptimeNanoseconds;try f()
 return Double(DispatchTime.now().uptimeNanoseconds-start)/1e6
}
let root=FileManager.default.temporaryDirectory.appendingPathComponent("lumen-settlement-scaling-\(UUID())")
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
defer {try? FileManager.default.removeItem(at:root)}
let payload=Data("<synthetic-public-sidecar/>".utf8)
print("pending\tjson_bytes\tsettle_only_ms\tguard_and_settle_ms\tfile_observation_control_ms\tguard_file_observation_settle_ms")
for n in [40,200,500,1000] {
 func seeded(_ arm:String) throws -> (CatalogStore,[Int64],[UnsavedSidecarRecord]) {
  let folderURL=root.appendingPathComponent("\(n)-\(arm)");try FileManager.default.createDirectory(at:folderURL,withIntermediateDirectories:true)
  let store=try CatalogStore(path:folderURL.appendingPathComponent("catalog.db").path)
  let folder=try store.registerFolder(path:folderURL.path)
  let files=(0..<n).map {ScannedFile(filename:String(format:"frame%06d.JPG",$0),fileSize:1,fileMTime:1,ext:"jpg")}
  _=try store.scan(folderID:folder,files:files)
  let ids=try files.map {try store.photo(folderID:folder,filename:$0.filename)!.id}
  let records=zip(files,ids).map {UnsavedSidecarRecord(photoPath:folderURL.appendingPathComponent($0.0.filename).path,photoID:$0.1,stated:[.recipe,.strokes],generation:UUID().uuidString)}
  try store.setMetaValue(UnsavedSidecarRecord.metaKey,UnsavedSidecarRecord.encode(records))
  return (store,ids,records)
 }
 let (settle,_,a)=try seeded("settle"),(guarded,_,b)=try seeded("guarded"),(control,cids,c)=try seeded("control"),(full,fids,d)=try seeded("full")
 let bytes=try settle.metaValue(UnsavedSidecarRecord.metaKey)!.utf8.count
 let settleMs=try timed {for r in a {require(try settle.settleSidecarIntent(photoPath:r.photoPath,generation:r.generation))}}
 let guardMs=try timed {for r in b {
  let owed=try UnsavedSidecarRecord.decodeValidated(guarded.metaValue(UnsavedSidecarRecord.metaKey))
  require(owed.first {$0.photoPath==r.photoPath}?.generation==r.generation)
  require(try guarded.settleSidecarIntent(photoPath:r.photoPath,generation:r.generation))
 }}
 func observe(_ store:CatalogStore,_ id:Int64,_ r:UnsavedSidecarRecord) throws {
  try payload.write(to:URL(fileURLWithPath:r.photoPath+".xmp"),options:.atomic)
  try store.setSidecarMTime(1,photoID:id)
  try store.setMetaValue("sidecar_observation_\(id)","synthetic-observation-digest")
 }
 let controlMs=try timed {for (r,id) in zip(c,cids) {try observe(control,id,r)}}
 let fullMs=try timed {for (r,id) in zip(d,fids) {
  let owed=try UnsavedSidecarRecord.decodeValidated(full.metaValue(UnsavedSidecarRecord.metaKey))
  require(owed.first {$0.photoPath==r.photoPath}?.generation==r.generation)
  try observe(full,id,r)
  require(try full.settleSidecarIntent(photoPath:r.photoPath,generation:r.generation))
 }}
 require(try settle.metaValue(UnsavedSidecarRecord.metaKey)==nil)
 require(try guarded.metaValue(UnsavedSidecarRecord.metaKey)==nil)
 require(try full.metaValue(UnsavedSidecarRecord.metaKey)==nil)
 for r in d {require(try Data(contentsOf:URL(fileURLWithPath:r.photoPath+".xmp"))==payload)}
 print(String(format:"%d\t%d\t%.3f\t%.3f\t%.3f\t%.3f",n,bytes,settleMs,guardMs,controlMs,fullMs))
 settle.close();guarded.close();control.close();full.close()
}
