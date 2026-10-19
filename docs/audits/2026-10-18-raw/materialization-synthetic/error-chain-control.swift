import Foundation
func boundedErrorChain(_ error: NSError, includeDescriptions: Bool) -> [String: Any] {
        var current: NSError? = error
        var seen = Set<ObjectIdentifier>()
        var nodes: [[String: Any]] = []
        var termination = "none"
        while let next = current {
            if nodes.count == 4 { termination = "depth-limit"; break }
            guard seen.insert(ObjectIdentifier(next)).inserted else {
                termination = "cycle"; break
            }
            let underlying = next.userInfo[NSUnderlyingErrorKey]
            let nested = underlying as? NSError
            nodes.append(["level": nodes.count, "domain": next.domain, "code": next.code,
                "underlyingPresent": underlying != nil, "underlyingIsNSError": nested != nil,
                "description": includeDescriptions ? next.localizedDescription : "withheld"])
            if underlying != nil && nested == nil { termination = "non-error-underlying" }
            current = nested
        }
        return ["errorChain": nodes, "errorChainTermination": termination,
                "errorChainTruncated": termination == "depth-limit" || termination == "cycle"]
    }

let secret="synthetic-private-path-not-for-output"
var error=NSError(domain:"leaf",code:7,userInfo:[NSLocalizedDescriptionKey:secret,"unrelatedPrivateValue":secret])
for level in 0..<6 { error=NSError(domain:"level",code:level,userInfo:[NSUnderlyingErrorKey:error,NSLocalizedDescriptionKey:secret]) }
let r=boundedErrorChain(error,includeDescriptions:false)
precondition((r["errorChain"] as! [[String:Any]]).count==4)
precondition(r["errorChainTermination"] as! String == "depth-limit")
let redacted=try JSONSerialization.data(withJSONObject:r)
precondition(redacted.range(of:Data(secret.utf8)) == nil)
let disclosed=try JSONSerialization.data(withJSONObject:boundedErrorChain(error,includeDescriptions:true))
precondition(disclosed.range(of:Data(secret.utf8)) != nil)
print("Foundation error-chain control PASS: four levels, depth limit, redacted secret absent, explicit disclosure present")
