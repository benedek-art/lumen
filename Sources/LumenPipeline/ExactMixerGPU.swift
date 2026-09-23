#if os(macOS)
import CoreImage
import Foundation
import LumenCore

/// NON-ENABLED prerequisite for an exact colour pipeline. Nothing in RenderGraph
/// selects this kernel yet: a Mixer-only fast path produced a large discontinuity
/// when another colour family became active. See EXECUTION-05-exact-mixer.md.
/// One compiled kernel and twenty-eight small uniform vectors; no recipe-specific
/// compilation or colour cube allocation.
enum ExactMixerGPU {
    private static func number(_ value: Double) -> String {
        String(format: "%.14g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func matrix(_ name: String, _ variable: String) -> String {
        "vec3(" + (0..<3).map { row in
            "dot(\(name)\(row),\(variable))"
        }.joined(separator: ",") + ")"
    }

    private static let matrixNames = ["rgbToLMS", "lmsToLab", "labToLMS", "lmsToRGB"]

    /// Matrices and photographic constants come from the CPU implementation. The
    /// independent tests compare actual pixels to `ColorEngine.apply`, not this
    /// generated source or a LUT baked from it.
    static let source: String = {
        let arguments = (0..<ColorEngine.bandCount).map {
            "vec4 arc\($0), vec3 move\($0)"
        } + matrixNames.flatMap { name in (0..<3).map { "vec3 \(name)\($0)" } }
        let weights = (0..<ColorEngine.bandCount).map { i in
            "float w\(i) = membership(h, \(number(ColorEngine.bandHueCentres[i])), arc\(i));"
        }.joined(separator: "\n")
        let sum = (0..<ColorEngine.bandCount).map { "w\($0)" }.joined(separator: "+")
        let moves = (0..<ColorEngine.bandCount).map { "w\($0)*move\($0)" }
            .joined(separator: "+")
        return """
        float membership(float h, float centre, vec4 arc) {
            float d = mod(h-centre+180.0,360.0)-180.0;
            float below = max(0.0,-d-arc.x);
            float above = max(0.0,d-arc.y);
            float t = max(below/arc.z,above/arc.w);
            return 0.5+0.5*cos(clamp(t,0.0,1.0)*3.141592653589793);
        }
        kernel vec4 exactMixer(__sample s, \(arguments.joined(separator: ", "))) {
            vec3 c = s.rgb;
            vec3 lms = \(matrix("rgbToLMS", "c"));
            vec3 n = sign(lms)*pow(abs(lms),vec3(0.3333333333333333));
            // Refine the GPU's approximate pow before the hue-selective operation.
            // Signed Newton iteration preserves negative cone responses and black.
            n = (2.0*n+lms/max(n*n,vec3(1e-30)))/3.0;
            vec3 lab = \(matrix("lmsToLab", "n"));
            float chroma = length(lab.gb);
            // Below the gate every move is exactly zero; preserve the original
            // pixel rather than deriving an arbitrary hue from a near-neutral.
            if (chroma <= \(number(ColorEngine.gateLoChroma))) { return s; }
            float h = atan(lab.b,lab.g)*57.29577951308232;
            if (h < 0.0) { h += 360.0; }
            \(weights)
            float total = \(sum);
            // Sanitized arcs always overlap. This guard is defensive only and
            // cannot be reached by finite values from the resolved parameters.
            if (total <= 0.0) { return s; }
            float gate = smoothstep(\(number(ColorEngine.gateLoChroma)),
                                    \(number(ColorEngine.gateHiChroma)),chroma);
            vec3 move = (\(moves))*(gate/total);
            float t = clamp(lab.r,0.0,\(number(ColorEngine.lumShapePeak)));
            float lightness = lab.r+move.b*\(number(ColorEngine.lumKappa))*t*(1.0-t);
            float saturation = chroma*max(0.0,1.0+move.g);
            float angle = (h+move.r)*0.017453292519943295;
            vec3 mapped = vec3(lightness,saturation*cos(angle),saturation*sin(angle));
            vec3 cone = \(matrix("labToLMS", "mapped"));
            vec3 cubic = cone*cone*cone;
            return vec4(\(matrix("lmsToRGB", "cubic")),s.a);
        }
        """
    }()

    static let kernel = CIColorKernel(source: source)

    static func apply(_ mixer: ExactMixer, to image: CIImage) -> CIImage? {
        var arguments: [Any] = [image]
        for band in mixer.bands {
            arguments.append(CIVector(x: band.arc.coreBelow, y: band.arc.coreAbove,
                                      z: band.arc.featherBelow, w: band.arc.featherAbove))
            arguments.append(CIVector(x: band.hue, y: band.saturation, z: band.luminance))
        }
        // CIKL's source-literal path loses several float ULPs on this platform,
        // even when given fourteen decimal digits. Near a signed LMS cancellation
        // that error is amplified by cbrt. Uniforms preserve the CPU's f32 values.
        let context = mixer.context
        for matrix in [context.rgbToLMS, OKLabTransform.lmsToLab,
                       OKLabTransform.labToLMS, context.lmsToRGB] {
            for row in matrix.m {
                arguments.append(CIVector(x: row[0], y: row[1], z: row[2]))
            }
        }
        return kernel?.apply(extent: image.extent, arguments: arguments)
    }
}
#endif
