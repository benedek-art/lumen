// One function, two bindings named `found`: an optional TUPLE early on and a
// `let found: FixtureDigest` later. The values pass sees only capitalised annotations,
// so before the fix it read every `found.x` in the function as a FixtureDigest member
// and reported `found.url` / `found.digest` (docs/audit-2026-10/streams/P1-ingest.md).
struct FixtureDigest: Equatable {
    let byteCount: Int
    let hash: UInt64
}

func fixtureLand(_ candidates: [String], digest: (String) -> FixtureDigest) -> Int {
    var total = 0
    if !candidates.isEmpty {
        var found: (url: String, digest: FixtureDigest)?
        for c in candidates where found == nil {
            found = (c, digest(c))
        }
        if let found {
            total += found.url.count + found.digest.byteCount
        }
    }
    let found: FixtureDigest
    found = digest("landed")
    return total + found.byteCount
}
