struct FixtureKnob {
    let a: Int
    init(alpha: Int) { a = alpha }
}

func fixtureMakeKnob() -> FixtureKnob {
    FixtureKnob(alpha: 1, gamma: 2)
}
