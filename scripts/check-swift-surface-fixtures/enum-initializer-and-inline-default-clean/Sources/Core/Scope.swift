enum ScopedFixture {
    case alpha
    case beta(Int)
    case gamma
    init?(name: String?, code: Int?) {
        switch (name, code) {
        case (nil, nil): self = .alpha
        case ("beta"?, let value?): self = .beta(value)
        default: return nil
        }
    }
    var number: Int? {
        switch self { case .alpha: return nil; case .beta(let value): return value; default: return nil }
    }
}
enum ScopeNaming {
    static func name(_ scope: ScopedFixture) -> String {
        switch scope {
        case .alpha: return "alpha"
        case .beta: return "beta"
        case .gamma: return "gamma"
        }
    }
}
