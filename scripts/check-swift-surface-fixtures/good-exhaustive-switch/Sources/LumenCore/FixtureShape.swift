enum FixtureShape {
    case round
    case square
    case hexagon

    /// A NESTED enum, because reading the outer body whole gave `MaskKind` three cases
    /// it did not have and made every switch over it look broken.
    enum Fill {
        case solid
        case hollow
    }
}

enum FixtureNaming {
    static func name(_ shape: FixtureShape) -> String {
        switch shape {
        case .round: return "round"
        case .square: return "square"
        case .hexagon: return "hexagon"
        }
    }
}
