// The other half: widening the table must not wave through a member SetAlgebra does
// NOT supply. `subtractingAll` is not a SetAlgebra member and this type declares no
// such thing, so the pass must still catch it.
struct FixtureFields: OptionSet, Sendable {
    let rawValue: Int
    static let alpha = FixtureFields(rawValue: 1 << 0)
    static let beta = FixtureFields(rawValue: 1 << 1)
}

func fixtureNarrow(_ stated: FixtureFields) -> FixtureFields {
    return stated.subtractingAll(.beta)
}
