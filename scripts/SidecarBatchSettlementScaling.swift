// Synthetic actual-store old/new comparison; no CatalogService/RAW/UI execution.
import Foundation
import Dispatch
import LumenCore
func require(_ condition: Bool) { precondition(condition) }
func timed(_ f: () throws -> Void) rethrows -> Double {let s=DispatchTime.now().uptimeNanoseconds;try f();return Double(DispatchTime.now().uptimeNanoseconds-s)/1e6}
let root=FileManager.default.temporaryDirectory.appendingPathComponent("lumen-batch-settle-scaling-\(UUID())")
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
defer {try? FileManager.default.removeItem(at:root)}
let bytes=Data("<synthetic-public-sidecar/>".utf8)
let digest="synthetic-exact-written-bytes-digest"
print("pending\tjson_bytes\told_guard_file_observation_settle_ms\tchunk64_guard_file_atomic_observation_settle_ms")
for n in [40,200,500,1000] {
 func seed(_ arm:String) throws -> (CatalogStore,[UnsavedSidecarRecord]) {
  let folderURL=root.appendingPathComponent("\(n)-\(arm)");try FileManager.default.createDirectory(at:folderURL,withIntermediateDirectories:true)
  let store=try CatalogStore(path:folderURL.appendingPathComponent("catalog.db").path)
  let folder=try store.registerFolder(path:folderURL.path)
  let files=(0..<n).map {ScannedFile(filename:String(format:"frame%06d.JPG",$0),fileSize:1,fileMTime:1,ext:"jpg")}
  _=try store.scan(folderID:folder,files:files)
  let records=try files.map {file -> UnsavedSidecarRecord in
   let id=try store.photo(folderID:folder,filename:file.filename)!.id
   return UnsavedSidecarRecord(photoPath:folderURL.appendingPathComponent(file.filename).path,photoID:id,stated:[.recipe,.strokes],generation:UUID().uuidString)
  }
  try store.setMetaValue(UnsavedSidecarRecord.metaKey,UnsavedSidecarRecord.encode(records))
  return (store,records)
 }
 let (old,a)=try seed("old"),(batch,b)=try seed("new")
 let jsonBytes=try old.metaValue(UnsavedSidecarRecord.metaKey)!.utf8.count
 let oldMs=try timed {for r in a {
  let owed=try UnsavedSidecarRecord.decodeValidated(old.metaValue(UnsavedSidecarRecord.metaKey))
  let current=owed.first {$0.photoPath==r.photoPath}
  require(current?.photoID==r.photoID && current?.generation==r.generation)
  try bytes.write(to:URL(fileURLWithPath:r.photoPath+".xmp"),options:.atomic)
  try old.setSidecarMTime(1,photoID:r.photoID!)
  try old.setMetaValue(SidecarIntentPublication.observationKey(photoID:r.photoID!),digest)
  require(try old.settleSidecarIntent(photoPath:r.photoPath,generation:r.generation))
 }}
 let batchMs=try timed {for start in stride(from:0,to:b.count,by:64) {
  // Mirrors a fresh final catalog-queue block. No snapshot survives this block.
  let owed=try UnsavedSidecarRecord.decodeValidated(batch.metaValue(UnsavedSidecarRecord.metaKey))
  let byPath=Dictionary(uniqueKeysWithValues:owed.map {($0.photoPath,$0)})
  var published:[SidecarIntentPublication]=[]
  for r in b[start..<min(start+64,b.count)] {
   guard let current=byPath[r.photoPath],current.photoID==r.photoID,current.generation==r.generation else {fatalError("unexpected stale synthetic generation")}
   try bytes.write(to:URL(fileURLWithPath:r.photoPath+".xmp"),options:.atomic)
   published.append(SidecarIntentPublication(photoPath:r.photoPath,photoID:r.photoID,generation:r.generation,observation:.init(modificationTime:1,digest:digest)))
  }
  let settled=try batch.settleSidecarIntents(published)
  require(settled.settled.count==published.count)
 }}
 for (store,records) in [(old,a),(batch,b)] {
  require(try store.metaValue(UnsavedSidecarRecord.metaKey)==nil)
  for r in records {
   require(try Data(contentsOf:URL(fileURLWithPath:r.photoPath+".xmp"))==bytes)
   require(try store.photo(id:r.photoID!)?.sidecarMTime==1)
   require(try store.metaValue(SidecarIntentPublication.observationKey(photoID:r.photoID!))==digest)
  }
 }
 print(String(format:"%d\t%d\t%.3f\t%.3f",n,jsonBytes,oldMs,batchMs))
 old.close();batch.close()
}
