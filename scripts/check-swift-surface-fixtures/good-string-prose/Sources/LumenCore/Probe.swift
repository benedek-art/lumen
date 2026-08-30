struct FixtureExposure: Decodable {
    let pivots: [Double]
    let samples: [Double]
}

func fixtureReport() {
    print("FIXTURE -- per rung, FixtureExposure (draft path), budget 12 ms")
}
