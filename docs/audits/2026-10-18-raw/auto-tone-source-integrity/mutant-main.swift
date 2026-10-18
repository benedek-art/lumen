import Foundation
struct Tone {}
struct PhotoItem { let id: URL; let catalogID: Int64?; let sourceIdentity: SourceFileIdentity? }
final class AppState { var sourceRevision=1;var allPhotos:[PhotoItem]=[]
    struct AutoToneSourceContext: Sendable {
        struct Target: Sendable {
            let url: URL
            let catalogID: Int64?
            let identity: SourceFileIdentity?
        }
        let revision: Int
        let targets: [Target]
    }

    func captureAutoToneSourceContext(for targets: [PhotoItem]) -> AutoToneSourceContext? {
        var seen = Set<URL>()
        var captured: [AutoToneSourceContext.Target] = []
        for target in targets where seen.insert(target.id).inserted {
            let actual = SourceFileIdentity.read(target.id)
            if let expected = target.sourceIdentity {
                guard let actual,
                      SourceFileIdentity.sameGeneration(stored: expected.token, current: actual.token) else { return nil }
            }
            captured.append(.init(url: target.id, catalogID: target.catalogID, identity: actual))
        }
        guard !captured.isEmpty else { return nil }
        return AutoToneSourceContext(revision: sourceRevision, targets: captured)
    }

    func autoToneSourceIsCurrent(_ context: AutoToneSourceContext, suggestions: [URL: Tone]) -> Bool {
        guard context.revision == sourceRevision else { return false }
        let capturedURLs = Set(context.targets.map(\.url))
        guard Set(suggestions.keys).isSubset(of: capturedURLs) else { return false }
        var currentByURL: [URL: PhotoItem] = [:]
        for photo in allPhotos where currentByURL[photo.id] == nil { currentByURL[photo.id] = photo }
        return context.targets.allSatisfy { target in
            guard let photo = currentByURL[target.url], photo.catalogID == target.catalogID else { return false }
            let actual = SourceFileIdentity.read(target.url)
            switch (target.identity, actual) {
            case let (before?, after?):
                return SourceFileIdentity.sameGeneration(stored: before.token, current: after.token)
            case (nil, nil): return true // existing virtual/unknown-identity compatibility
            default: return false
            }
        }
    }


}
let root=FileManager.default.temporaryDirectory.appendingPathComponent("auto-context-witness-\(UUID())")
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
defer {try? FileManager.default.removeItem(at:root)}
let a=root.appendingPathComponent("a.png"),b=root.appendingPathComponent("b.png")
try Data([1]).write(to:a);try Data([2]).write(to:b)
let original=PhotoItem(id:a,catalogID:1,sourceIdentity:SourceFileIdentity.read(a))
let other=PhotoItem(id:b,catalogID:2,sourceIdentity:SourceFileIdentity.read(b))
let state=AppState();state.allPhotos=[original,other]
let request=state.captureAutoToneSourceContext(for:[original])!
var failures=0
func check(_ name:String,_ actual:Bool,_ expected:Bool) {print("\(name): accepted=\(actual), expected=\(expected)");if actual != expected {failures+=1}}
check("healthy",true,true)
check("unexpected suggestion",true,false)
state.sourceRevision=2;state.allPhotos=[other]
check("folder switch",true,false)
state.sourceRevision=1;state.allPhotos=[PhotoItem(id:a,catalogID:99,sourceIdentity:original.sourceIdentity)]
check("catalog remap",true,false)
state.allPhotos=[original,other]
try Data([9,8,7]).write(to:a,options:.atomic)
check("same URL replacement",true,false)
check("known stale preflight",state.captureAutoToneSourceContext(for:[original])==nil,true)
try FileManager.default.removeItem(at:a)
check("removed original",true,false)
let virtual=PhotoItem(id:root.appendingPathComponent("virtual"),catalogID:nil,sourceIdentity:nil)
state.allPhotos=[virtual]
let virtualRequest=state.captureAutoToneSourceContext(for:[virtual])!
check("unknown virtual compatibility",true,true)
print("failures=\(failures)");if failures>0 {exit(1)}
