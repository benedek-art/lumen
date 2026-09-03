// An OptionSet reads `subtracting` off itself. It declares no such member: SetAlgebra
// supplies it through a protocol extension. Before PROTOCOL_MEMBERS the values pass
// reported this as a member the type does not have, which is a false positive on
// code that compiles — and a checker with false positives gets switched off.
struct FixtureFields: OptionSet, Sendable {
    let rawValue: Int
    static let alpha = FixtureFields(rawValue: 1 << 0)
    static let beta = FixtureFields(rawValue: 1 << 1)
}

func fixtureNarrow(_ stated: FixtureFields) -> FixtureFields {
    return stated.subtracting(.beta)
}
