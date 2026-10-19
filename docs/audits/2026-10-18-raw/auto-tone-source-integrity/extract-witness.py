from pathlib import Path
import sys
r=Path(sys.argv[1]).resolve()
s=(r/'Sources/LumenApp/AppStateActions.swift').read_text()
a=s.index('    struct AutoToneSourceContext:');b=s.index('    /// Auto sets VISIBLE',a)
helper=s[a:b].replace('private func autoToneSourceIsCurrent','func autoToneSourceIsCurrent',1)
pre='''import Foundation
struct Tone {}
struct PhotoItem { let id: URL; let catalogID: Int64?; let sourceIdentity: SourceFileIdentity? }
final class AppState { var sourceRevision=1;var allPhotos:[PhotoItem]=[]
'''
post='''
}
let root=FileManager.default.temporaryDirectory.appendingPathComponent("auto-context-witness-\\(UUID())")
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
defer {try? FileManager.default.removeItem(at:root)}
let a=root.appendingPathComponent("a.png"),b=root.appendingPathComponent("b.png")
try Data([1]).write(to:a);try Data([2]).write(to:b)
let original=PhotoItem(id:a,catalogID:1,sourceIdentity:SourceFileIdentity.read(a))
let other=PhotoItem(id:b,catalogID:2,sourceIdentity:SourceFileIdentity.read(b))
let state=AppState();state.allPhotos=[original,other]
let request=state.captureAutoToneSourceContext(for:[original])!
var failures=0
func check(_ name:String,_ actual:Bool,_ expected:Bool) {print("\\(name): accepted=\\(actual), expected=\\(expected)");if actual != expected {failures+=1}}
check("healthy",state.autoToneSourceIsCurrent(request,suggestions:[a:Tone()]),true)
check("unexpected suggestion",state.autoToneSourceIsCurrent(request,suggestions:[b:Tone()]),false)
state.sourceRevision=2;state.allPhotos=[other]
check("folder switch",state.autoToneSourceIsCurrent(request,suggestions:[a:Tone()]),false)
state.sourceRevision=1;state.allPhotos=[PhotoItem(id:a,catalogID:99,sourceIdentity:original.sourceIdentity)]
check("catalog remap",state.autoToneSourceIsCurrent(request,suggestions:[a:Tone()]),false)
state.allPhotos=[original,other]
try Data([9,8,7]).write(to:a,options:.atomic)
check("same URL replacement",state.autoToneSourceIsCurrent(request,suggestions:[a:Tone()]),false)
check("known stale preflight",state.captureAutoToneSourceContext(for:[original])==nil,true)
try FileManager.default.removeItem(at:a)
check("removed original",state.autoToneSourceIsCurrent(request,suggestions:[a:Tone()]),false)
let virtual=PhotoItem(id:root.appendingPathComponent("virtual"),catalogID:nil,sourceIdentity:nil)
state.allPhotos=[virtual]
let virtualRequest=state.captureAutoToneSourceContext(for:[virtual])!
check("unknown virtual compatibility",state.autoToneSourceIsCurrent(virtualRequest,suggestions:[virtual.id:Tone()]),true)
print("failures=\\(failures)");if failures>0 {exit(1)}
'''
p=Path(sys.argv[2]).resolve();p.mkdir(exist_ok=True)
(p/'main.swift').write_text(pre+helper+post)
# Remove only the use of validation; same helper/context capture still executes.
mutantpost=post.replace('state.autoToneSourceIsCurrent(request,suggestions:[a:Tone()])','true').replace('state.autoToneSourceIsCurrent(request,suggestions:[b:Tone()])','true').replace('state.autoToneSourceIsCurrent(virtualRequest,suggestions:[virtual.id:Tone()])','true')
(p/'mutant-main.swift').write_text(pre+helper+mutantpost)
