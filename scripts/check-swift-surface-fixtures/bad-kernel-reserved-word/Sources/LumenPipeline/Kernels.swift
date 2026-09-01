import Foundation

enum FixtureKernels {
    /// `out` is a GLSL parameter qualifier; as a local it is a parse error the Swift
    /// compiler cannot see, because the kernel is a string.
    static let foldSource = """
    kernel vec4 fixtureFold(__sample acc, float amount) {
        float out;
        out = acc.r * amount;
        return vec4(out, out, out, 1.0);
    }
    """
}
