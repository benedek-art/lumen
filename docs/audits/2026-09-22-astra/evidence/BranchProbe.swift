import Foundation

// Exact common-prefix loop in AppState.commonParent on a6e6941.
// Inputs represent selected files, so their last path component is removed.
func auditedCommonParent(_ urls:[URL]) -> URL? {
    guard let first=urls.first else{return nil}
    var common=first.deletingLastPathComponent().standardizedFileURL.pathComponents
    for url in urls.dropFirst() {
        let parts=url.deletingLastPathComponent().standardizedFileURL.pathComponents
        var shared:[String]=[]
        for (a,b) in zip(common,parts) where a == b {shared.append(a)}
        common=shared
    }
    guard !common.isEmpty else{return nil}
    return URL(fileURLWithPath:NSString.path(withComponents:common),isDirectory:true)
}
let paths=["/audit/day1/photos/DSC0001.ARW","/audit/day2/photos/DSC0002.ARW"]
let result=auditedCommonParent(paths.map{URL(fileURLWithPath:$0)})!.path
print("INPUT",paths)
print("ACTUAL",result)
print("EXPECTED /audit")
print("BOTH_INPUTS_DESCEND_FROM_RESULT",paths.allSatisfy{$0.hasPrefix(result+"/")})
