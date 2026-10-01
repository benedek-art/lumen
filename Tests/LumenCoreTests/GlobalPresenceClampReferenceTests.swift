import XCTest
@testable import LumenCore

/// The reference renderer's half of the global Texture/Clarity clamp, on the Linux lane.
/// The graph's half is `GlobalPresenceClampTests` (macOS); both must render a
/// hand-edited sidecar's ±250 exactly as ±100.
final class GlobalPresenceClampReferenceTests: XCTestCase {
    private var input: ImageBuffer {
        ImageBuffer(width: 64, height: 64) { u, v in
            let value = 0.18 + 0.04 * sin(2 * .pi * 8 * u) * cos(2 * .pi * 5 * v)
                + 0.015 * sin(2 * .pi * 3 * u)
            return RGB(value * 0.9, value, value * 1.1)
        }
    }

    private func render(_ detail: Detail) -> [Float] {
        // `ReferenceRenderer` S8 hands `plan.detail` to exactly this call.
        let node = DetailEngine.Decomposition(image: input, workingRadius: 3)
        return DetailEngine.apply(input, detail: detail, decomposition: node).pixels
    }

    func testReferenceClampsGlobalTextureAndClarityAtOneHundred() {
        let neutral = render(Detail())
        for texture in [true, false] {
            for sign in [-1.0, 1] {
                var atLimit = Detail()
                var beyond = Detail()
                if texture { atLimit.texture = 100 * sign; beyond.texture = 250 * sign }
                else { atLimit.clarity = 100 * sign; beyond.clarity = 250 * sign }
                let limit = render(atLimit)
                XCTAssertNotEqual(limit, neutral, "the limit must move the picture")
                XCTAssertEqual(render(beyond), limit,
                               "\(texture ? "texture" : "clarity") \(sign): ±250 must render as ±100")
            }
        }
    }
}
