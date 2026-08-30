struct FixtureBox {
    let w: Int
    init(width: Int) { w = width }
}

func fixtureMakeBox() -> FixtureBox {
    FixtureBox(breadth: 3)
}
