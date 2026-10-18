from pathlib import Path
import argparse
import hashlib
parser=argparse.ArgumentParser()
parser.add_argument('--source-root',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
parser.add_argument('--mutant',choices=['none','no-fallback','no-filter'],default='none')
args=parser.parse_args()
root=args.source_root
s=(root/'Sources/LumenApp/CatalogService.swift').read_text()
a=s.index('    private static func importKeywords(');b=s.index('\n    }\n',a)+6
importer=s[a:b].replace('private static func','static func',1)
x=s.index('                        let pendingKeywordEdit =');a=s.rfind('                        sidecarLock.lock()',0,x);b=s.index('                        let resolution =',x)
overlay=s[a:b]
if args.mutant=='no-fallback':
 assert overlay.count(' ?? owedKeywordEdit')==1
 overlay=overlay.replace(' ?? owedKeywordEdit','',1)
elif args.mutant=='no-filter':
 assert overlay.count('projected.keywords = currentEdit.apply(')==1
 overlay=overlay.replace('projected.keywords = currentEdit.apply(', 'projected.keywords = pendingKeywordEdit.apply(',1)
body='''import Foundation
import LumenCore
final class ImportWitness {
'''+importer+'''\n}
let root=FileManager.default.temporaryDirectory.appendingPathComponent("inflight-keyword-witness-\\(UUID())")
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
'''+overlay+'''
ImportWitness.importKeywords(from:sidecar,photoID:row.id,store:store)
// The legacy startup-recovery policy filters the obsolete addition to an empty
// queued delta before the flush removes its pending entry. This harness models
// that queued payload; the native test executes actual recovery and publication.
let published=(legacy ? SidecarKeywordEdit() : record.keywordEdit!).apply(to:external.keywords!)
_=try store.settleSidecarIntents([SidecarIntentPublication(photoPath:file.path,photoID:row.id,generation:record.generation)])
let actual=try store.keywords(photoID:row.id)
let owed=try UnsavedSidecarRecord.decodeValidated(store.metaValue(UnsavedSidecarRecord.metaKey))
print("catalog=\\(actual) published=\\(published) remainingDebt=\\(owed.count)")
if actual != ["Kept"] || published != ["Kept"] || !owed.isEmpty {exit(1)}
'''
args.output.write_text(body)
print('importbodySHA',hashlib.sha256(importer.encode()).hexdigest(),'overlaySHA',hashlib.sha256(overlay.encode()).hexdigest())
