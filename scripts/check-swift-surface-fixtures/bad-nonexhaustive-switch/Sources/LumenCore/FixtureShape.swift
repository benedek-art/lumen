enum FixtureShape {
    case round
    case square
    case hexagon
}

enum FixtureNaming {
    /// `hexagon` is missing and there is no `default`, which is a compile error on the
    /// target this checker exists to stand in for.
    static func name(_ shape: FixtureShape) -> String {
        switch shape {
        case .round: return "round"
        case .square: return "square"
        }
    }
}
