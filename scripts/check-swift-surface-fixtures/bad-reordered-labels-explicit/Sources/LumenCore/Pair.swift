struct FixturePair {
    let a: Int
    let b: Int
    init(alpha: Int, beta: Int) {
        a = alpha
        b = beta
    }
}

func fixtureMakePair() -> FixturePair {
    FixturePair(beta: 2, alpha: 1)
}
