struct FixtureRow {
    var title: String
    var weight: Double
}

enum FixtureRows {
    /// `fixtureGhost` is bound nowhere. This is the shape of the copy-paste that put
    /// `behaviour: behaviour` into `swatchSlider`.
    static func make(_ name: String) -> FixtureRow {
        FixtureRow(title: name, weight: fixtureGhost)
    }
}
