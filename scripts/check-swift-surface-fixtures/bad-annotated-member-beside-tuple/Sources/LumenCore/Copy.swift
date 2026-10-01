// The tuple fix must not make the pass blind: a DIFFERENT name annotated with an
// in-tree type, in the same function as a tuple binding, is still checked.
struct FixtureDigest: Equatable {
    let byteCount: Int
    let hash: UInt64
}

func fixtureLand(_ candidates: [String], digest: (String) -> FixtureDigest) -> Int {
    var pair: (url: String, digest: FixtureDigest)?
    pair = (candidates[0], digest(candidates[0]))
    let landed: FixtureDigest
    landed = digest("landed")
    return (pair?.url.count ?? 0) + landed.byteSize
}
