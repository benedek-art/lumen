// The tone mask's two failure modes, pinned from either side (docs/23 M1b).
//
// The mask behind Highlights/Shadows/Whites/Blacks and every Zone is a self-guided
// filter whose ε is a contrast threshold — and it shipped at 0.004 on the LumenLog
// plane, which is √0.004 × 24 = 1.52 EV: "anything flatter than a stop and a half is
// one surface". Measured on a 4 EV shadow/midtone edge, Shadows +100 lifted the bright
// side by 0.497 EV — a half-stop halo beside every backlit subject, the fifth instance
// of the units bug BUILDING.md keeps a section about. The naive ÷24² correction fails
// the OTHER way: at ±0.2 EV of high-ISO noise the mask follows the grain (σ 0.090 EV)
// and the tone gains re-print it. The shipped threshold, 0.375 EV, is the measured
// knee: halo 0.052 EV, noise σ 0.010 EV, roughly 2x margin to each bar below.
//
// WS-07 moved the threshold to 0.12 EV and took the mask's variance from the guide
// smoothed at half the radius (`ReferenceRenderer.toneMask`). The 4 EV edge was never
// the hard case: a guided filter halos worst at edges about 2√ε tall, and at 0.375 EV
// a 1 EV step under the HDR combo got a 0.12 EV counter-ramp a radius wide.
// `testShadowsDoNotHaloAcrossAModerateEdge` pins that one. The smoothed variance is what
// lets the threshold drop without the mask following grain, which the noise test
// still guards, now through the real mask function.
//
// Every test reads the REAL constants, so a future edit in either direction turns
// one of them red with a message naming the failure a photographer would see.
import XCTest
@testable import LumenCore

final class ToneMaskEdgeTests: XCTestCase {

    private func stepFrame(baseEV: Double, deltaEV: Double, noise: Double = 0,
                           width: Int = 1024, height: Int = 64) -> ImageBuffer {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func jitter() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return (Double(seed >> 11) / Double(UInt64.max >> 11) - 0.5) * 2 * noise
        }
        return ImageBuffer(width: width, height: height) { u, _ in
            let ev = (u < 0.5 ? baseEV : baseEV + deltaEV) + jitter()
            let v = 0.18 * pow(2.0, ev)
            return RGB(v, v, v)
        }
    }

    /// Shadows +100 on a deep-shadow/midtone edge: the bright side must not lift.
    /// This is the halo a photographer sees beside every backlit subject, through the
    /// real stage at the real radius.
    func testShadowsDoNotHaloAcrossAShadowEdge() {
        var recipe = Recipe()
        recipe.develop.tone.shadows = 100
        let plan = RenderPlan(recipe: recipe)
        let frame = stepFrame(baseEV: -5, deltaEV: 4)
        let radius = Swift.max(Int(Double(frame.width) * 0.02), 2)

        let rendered = ReferenceRenderer.applyTone(frame, plan: plan,
                                                   longEdge: frame.width,
                                                   space: .rec2020)
        let y = frame.height / 2
        let far = Double(rendered[frame.width - 8, y].g)
        var haloEV = 0.0
        for x in (frame.width / 2 + 1)...(frame.width / 2 + 3 * radius) {
            let lum = Double(rendered[x, y].g)
            if lum > 0, far > 0 {
                haloEV = Swift.max(haloEV, abs(log2(lum / far)))
            }
        }
        XCTAssertLessThan(haloEV, 0.1,
            "Shadows +100 moved the BRIGHT side of a 4 EV edge by \(haloEV) EV within "
                + "the mask's reach — a halo beside every backlit subject. The shipped "
                + "ε=0.004 measured 0.497 EV here; the mask's contrast threshold has "
                + "drifted loose again.")
    }

    /// A flat frame under ±0.2 EV of per-pixel noise — ISO 6400 shadows before
    /// denoise: the mask must not follow the grain, or the tone gains re-print it.
    func testTheMaskDoesNotFollowHighISONoise() {
        let frame = stepFrame(baseEV: -1, deltaEV: 0, noise: 0.20)
        let luminance = frame.luminancePlane(space: .rec2020)
        let log = luminance.map { LumenLog.encode(Swift.max($0, 0)) }
        let mask = ReferenceRenderer.toneMask(log, longEdge: frame.width)

        let y = frame.height / 2
        var mean = 0.0, count = 0.0
        for x in 8..<(frame.width - 8) { mean += Double(mask[x, y]); count += 1 }
        mean /= count
        var variance = 0.0
        for x in 8..<(frame.width - 8) {
            let d = Double(mask[x, y]) - mean
            variance += d * d
        }
        let sigmaEV = (variance / count).squareRoot() * LumenLog.range
        XCTAssertLessThan(sigmaEV, 0.02,
            "the tone mask carries \(sigmaEV) EV of ripple on a flat frame under "
                + "±0.2 EV noise — the gains will re-print the grain. The naive ÷24² "
                + "threshold measured 0.090 EV here; over-tightening ε, or measuring "
                + "the variance on the unsmoothed guide, is how that happens.")
    }

    /// Shadows +100 on a 1 EV shadow/midtone step, the kind of edge a treeline makes
    /// against an overcast sky: neither side may carry a ramp toward the edge. This
    /// is the guided filter's worst case, an edge about 2√ε tall, where `a` sits near
    /// 0.5 and the mask ramps across the whole window. At the old 0.375 EV threshold
    /// it measured 0.12 EV here.
    func testShadowsDoNotHaloAcrossAModerateEdge() {
        var recipe = Recipe()
        recipe.develop.tone.shadows = 100
        recipe.develop.tone.highlights = -100
        let plan = RenderPlan(recipe: recipe)
        let frame = stepFrame(baseEV: -2.5, deltaEV: 1)
        let radius = ReferenceRenderer.toneMaskRadius(longEdge: frame.width)
        let rendered = ReferenceRenderer.applyTone(frame, plan: plan,
                                                   longEdge: frame.width,
                                                   space: .rec2020)
        let y = frame.height / 2
        let edge = frame.width / 2
        func gain(_ x: Int) -> Double {
            log2(Double(rendered[x, y].g) / Double(frame[x, y].g))
        }
        let farDark = gain(8), farBright = gain(frame.width - 8)
        var haloEV = 0.0
        for d in 3...(3 * radius) {
            haloEV = Swift.max(haloEV, abs(gain(edge - 1 - d) - farDark),
                               abs(gain(edge + d) - farBright))
        }
        XCTAssertGreaterThan(farDark - farBright, 0.3,
            "the frame no longer exercises the mask: the two sides get gains only "
                + "\(farDark - farBright) EV apart")
        XCTAssertLessThan(haloEV, 0.06,
            "Highlights −100 / Shadows +100 put a \(haloEV) EV ramp beside a 1 EV edge "
                + "within the mask's reach: the glow along a treeline. The 0.375 EV "
                + "threshold measured 0.12 EV here.")
    }
}
