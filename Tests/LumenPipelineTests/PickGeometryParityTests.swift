// PickGeometryParityTests.swift — LumenCore's `PickGeometry` is the twin of the renderer's
// own click mapping (docs/quality/lanes/WS-02/SPEC.md F2).
//
// `PipelineRenderer.sourceNormalized` / `displayedNormalized` invert the very
// `geometryRects` `applyGeometry` draws with, and they are the authority. The twin exists
// so the convention can be tested on Linux; this holds the two equal on the same grid the
// Linux tests sweep, so a change to one that is not made to the other fails here.

#if os(macOS)

import CoreGraphics
import XCTest
@testable import LumenCore
@testable import LumenPipeline

final class PickGeometryParityTests: XCTestCase {

    func testTheCoreTwinMatchesTheRenderersMapping() {
        let angles: [Double] = [-45, -30, -7.3, 0, 0.5, 12, 30, 45]
        let crops = [Crop(), Crop(x: 0.1, y: 0.2, w: 0.5, h: 0.6),
                     Crop(x: 0, y: 0, w: 0.05, h: 0.05),
                     Crop(x: 0.7, y: 0.65, w: 0.3, h: 0.35)]
        let sources: [(Double, Double)] = [(6000, 4000), (4000, 6000), (3, 2)]
        let grid = (0...10).map { Double($0) / 10 }
        var worst = 0.0
        var worstCase = ""
        for angle in angles {
            for flip in [false, true] {
                for crop in crops {
                    for (w, h) in sources {
                        let geo = Geometry(crop: crop, angle: angle, flipH: flip)
                        let size = CGSize(width: w, height: h)
                        for u in grid {
                            for v in grid {
                                let core = PickGeometry.sourcePoint(
                                    displayedX: u, displayedY: v, geometry: geo,
                                    sourceWidth: w, sourceHeight: h)
                                let renderer = PipelineRenderer.sourceNormalized(
                                    displayedX: u, displayedY: v, geometry: geo,
                                    sourceSize: size)
                                let coreBack = PickGeometry.displayedPoint(
                                    sourceX: u, sourceY: v, geometry: geo,
                                    sourceWidth: w, sourceHeight: h)
                                let rendererBack = PipelineRenderer.displayedNormalized(
                                    sourceX: u, sourceY: v, geometry: geo,
                                    sourceSize: size)
                                let error = max(abs(core.x - Double(renderer.x)),
                                                abs(core.y - Double(renderer.y)),
                                                abs(coreBack.x - Double(rendererBack.x)),
                                                abs(coreBack.y - Double(rendererBack.y)))
                                if error > worst {
                                    worst = error
                                    worstCase = "angle \(angle) flip \(flip) crop \(crop) "
                                        + "\(w)x\(h) at (\(u), \(v))"
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertLessThan(worst, 1e-9, "PickGeometry and PipelineRenderer disagree by "
                              + "\(worst) at \(worstCase)")
    }
}

#endif
