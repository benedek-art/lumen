import Foundation

enum FixtureKernels {
    /// Ordinary identifiers, plus prose in a non-kernel literal that happens to contain
    /// the words `out` and `long` — which must not be mistaken for declarations.
    static let note = """
    A long note that goes out of its way to say `float out` in prose.
    """
    static let foldSource = """
    kernel vec4 fixtureFold(__sample acc, float amount, float w, float h) {
        float edge = max(w, h);
        float folded = acc.r * amount / edge;
        return vec4(folded, folded, folded, 1.0);
    }
    """
}
