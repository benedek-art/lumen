import Foundation
struct Snapshot { let id: URL; let identity: Int? }
@inline(never) func old(_ targets: [Snapshot], primary: Snapshot) -> [URL: Int?] {
    Dictionary(uniqueKeysWithValues: Set(targets.map(\.id)).union([primary.id]).map { url in
        (url, url == primary.id ? primary.identity : targets.first(where: { $0.id == url })?.identity)
    })
}
@inline(never) func new(_ targets: [Snapshot], primary: Snapshot) -> [URL: Int?] {
    var first: [URL: Snapshot] = [:]
    for target in targets where first[target.id] == nil { first[target.id] = target }
    return Dictionary(uniqueKeysWithValues: Set(first.keys).union([primary.id]).map { url in
        (url, url == primary.id ? primary.identity : first[url]?.identity)
    })
}
func url(_ index: Int) -> URL { URL(fileURLWithPath: "/synthetic/\(index).png") }
let cases: [([Snapshot], Snapshot)] = [
    ([], Snapshot(id: url(0), identity: nil)),
    ([Snapshot(id: url(0), identity: 1)], Snapshot(id: url(0), identity: nil)),
    ([Snapshot(id: url(1), identity: nil), Snapshot(id: url(1), identity: 2)], Snapshot(id: url(0), identity: 3)),
    ([Snapshot(id: url(1), identity: 2), Snapshot(id: url(1), identity: nil)], Snapshot(id: url(0), identity: nil)),
    ([Snapshot(id: url(0), identity: nil), Snapshot(id: url(1), identity: 2)], Snapshot(id: url(0), identity: 9)),
]
for (targets, primary) in cases { precondition(old(targets, primary: primary) == new(targets, primary: primary)) }
print("exact projection equality passed5 cases: empty, duplicate nil/non-nil precedence, primary nil/non-nil override")
for count in [1000, 20000] {
    let targets = (0..<count).map { Snapshot(id: url($0), identity: $0.isMultiple(of: 3) ? nil : $0) }
    let primary = Snapshot(id: url(0), identity: 99)
    let start = Date()
    let before = old(targets, primary: primary)
    let middle = Date()
    let after = new(targets, primary: primary)
    let end = Date()
    precondition(before == after && after.count == count)
    print(String(format: "projection-only Linux Swift -O n=%d old=%.6fs indexed=%.6fs", count,
                 middle.timeIntervalSince(start), end.timeIntervalSince(middle)))
}
