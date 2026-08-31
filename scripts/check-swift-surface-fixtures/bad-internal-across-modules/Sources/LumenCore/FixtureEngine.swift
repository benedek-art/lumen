public enum FixtureEngine {
    /// No `public`: internal, so LumenApp cannot see it. This is the shape that cost a
    /// macOS round when `PipelineRenderer.maskSourceFingerprint` was reached from the
    /// app layer.
    static func secretRatio(of value: Double) -> Double { value * 2 }
    public static func openRatio(of value: Double) -> Double { value * 3 }
}
