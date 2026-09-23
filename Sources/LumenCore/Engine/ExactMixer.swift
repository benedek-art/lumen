import Foundation

/// Resolved parameters for an isolated, non-enabled Mixer primitive. The CPU uses
/// the original engine; GPU tests consume the same band parameters and constants.
/// This value excludes other S9 families, but does not establish whole-pipeline
/// eligibility. It is not selected by any production renderer.
public struct ExactMixer: Sendable {
    public struct Band: Equatable, Sendable {
        public let arc: ColorEngine.BandArc
        /// Hue in degrees; saturation/luminance in normalized slider units.
        public let hue: Double
        public let saturation: Double
        public let luminance: Double
    }

    public let bands: [Band]
    private let engine: ColorEngine
    /// Preserve the engine's conversion basis, including non-default test contexts.
    public var context: OKLabTransform.Context { engine.context }

    init(engine: ColorEngine, bands: [Band]) {
        self.engine = engine
        self.bands = bands
    }

    /// Keep the direct CPU oracle independent of the shader implementation.
    public func apply(_ colour: RGB) -> RGB { engine.apply(colour) }
}
