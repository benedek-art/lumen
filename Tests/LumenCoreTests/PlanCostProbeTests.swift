// What `RenderPlan` costs to construct — the CPU half of a frame, on the free lane.
//
// Every performance instrument this project has is macOS-only (`PerfProbeTests`,
// `DragProbeTests`), which means the CPU side of the render loop has only ever been
// measured on the scarce runner, in whatever build that lane happens to use. It does
// not need to be: `RenderPlan` is pure LumenCore, it is constructed once per frame on
// the render actor IN FRONT of the GPU work, and the thing that dominates it — a 33³
// colour table, ~36 000 evaluations of a transform holding three cube roots, an
// `atan2`, a sine and a cosine — is arithmetic Linux can time perfectly well.
//
// WHAT THIS PROBE IS FOR, concretely. The interesting number is not the cost, it is the
// GAP between the two paths:
//
//   · DRAFT (`allowStaleTables: true`) is what every frame of a slider drag pays. It
//     serves the newest table the cache holds and lets the exact bake for this event's
//     key land in the background, so the frame never blocks on one.
//   · SETTLE (`allowStaleTables: false`) is what the single frame after the hand stops
//     pays. It blocks on the exact bake, which is the whole reason the picture at rest
//     is exact.
//
// If those two are ever the same number for Whites, Blacks, the curve, the mixer, the
// wheels or Saturation, stale-while-bake has stopped working and every frame of those
// drags is cold-baking a colour cube on the render actor. That is a defect no eye can
// diagnose and no existing test can see, and it is the shape the first version of
// `DragProbeTests` accidentally measured and misreported as a drag's cost.
//
// It PRINTS and asserts only a sanity ceiling: a shared runner's CPU is not the owner's,
// and a threshold tuned to one fails spuriously on the other. Read the ratios.
import XCTest
@testable import LumenCore

final class PlanCostProbeTests: XCTestCase {

    /// A photograph that already has work on it: an empty recipe short-circuits half
    /// the identity checks and would price a plan nobody builds.
    private func base() -> Recipe {
        var r = Recipe()
        r.develop.tone.exposure = 0.4
        r.develop.tone.contrast = 20
        r.develop.tone.highlights = -40
        r.develop.tone.shadows = 25
        r.develop.raw.temp = 5200
        r.develop.color.vibrance = 10
        r.develop.detail.clarity = 25
        r.develop.detail.sharpen.amount = 60
        r.develop.denoise.mode = .classic
        return r
    }

    /// Which control the hand is on, and what each one invalidates.
    private static let controls: [(name: String, move: (inout Recipe, Double) -> Void)] = [
        // Re-keys the tone gain cube only.
        ("exposure", { r, t in r.develop.tone.exposure = -1 + 2 * t }),
        // Moves the tone ANCHORS, so it re-keys the finish table as well.
        ("whites", { r, t in r.develop.tone.whites = -60 + 120 * t }),
        // Re-keys the colour+grade table.
        ("saturation", { r, t in r.develop.color.saturation = -50 + 100 * t }),
        // Re-keys nothing: presence is not a table. The floor every other row is
        // measured against.
        ("texture", { r, t in r.develop.detail.texture = 100 * t }),
    ]

    private func percentile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let i = Swift.min(sorted.count - 1,
                          Swift.max(0, Int((Double(sorted.count - 1) * q).rounded())))
        return sorted[i]
    }

    func testPrintPlanConstructionCostPerControl() {
        let events = 60
        #if DEBUG
        print("PLANPROBE build: DEBUG — a table bake is inflated roughly 10× against "
                + "the shipping build. Read the DRAFT/SETTLE ratio, not the absolutes.")
        #else
        print("PLANPROBE build: RELEASE")
        #endif

        for (name, move) in Self.controls {
            for stale in [true, false] {
                // One warm construction so the cache has something to be stale FROM;
                // the first request for a slot bakes synchronously by design.
                var warm = base()
                move(&warm, 0.5)
                _ = RenderPlan(recipe: warm, lutSize: LUT3D.interactiveSize,
                               allowStaleTables: stale)

                var samples: [Double] = []
                samples.reserveCapacity(events)
                for i in 0..<events {
                    var recipe = base()
                    move(&recipe, (Double(i) + 0.5) / Double(events))
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    _ = RenderPlan(recipe: recipe, lutSize: LUT3D.interactiveSize,
                                   allowStaleTables: stale)
                    samples.append(
                        Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
                }
                let sorted = samples.sorted()
                let path = stale ? "draft " : "settle"
                let label = path + " " + name
                    + String(repeating: " ", count: Swift.max(0, 11 - name.count))
                print(String(format: "PLANPROBE %@ p50 %7.2f  p95 %7.2f  max %7.2f ms",
                             label, percentile(sorted, 0.5), percentile(sorted, 0.95),
                             sorted.last ?? 0))
                XCTAssertLessThan(sorted.last ?? 0, 30_000,
                                  "\(label): building one plan took over thirty "
                                      + "seconds — broken, not merely slow")
            }
        }
    }

    /// The property the drag depends on, as an assertion rather than a printed number:
    /// dragging a control that re-keys a colour table must NOT cost what the settle
    /// costs. This is what `PlanTableCache.tableAllowingStale` is for, and if it ever
    /// stops being true, every frame of a Whites or Saturation drag cold-bakes ~36 000
    /// samples on the render actor and the slider steps at the bake's rate.
    ///
    /// Stated as a ratio against the same machine's own settle measurement, so it holds
    /// on a fast runner and a slow one alike.
    func testATableRekeyingDragDoesNotPayTheBakePerFrame() {
        for control in ["whites", "saturation"] {
            guard let move = Self.controls.first(where: { $0.name == control })?.move
            else { return XCTFail("fixture names a control that is not in the table") }

            func cost(stale: Bool) -> Double {
                var warm = base()
                move(&warm, 0.5)
                _ = RenderPlan(recipe: warm, lutSize: LUT3D.interactiveSize,
                               allowStaleTables: stale)
                var samples: [Double] = []
                for i in 0..<12 {
                    var recipe = base()
                    move(&recipe, (Double(i) + 0.5) / 12)
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    _ = RenderPlan(recipe: recipe, lutSize: LUT3D.interactiveSize,
                                   allowStaleTables: stale)
                    samples.append(
                        Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
                }
                return percentile(samples.sorted(), 0.5)
            }

            let settle = cost(stale: false)
            let draft = cost(stale: true)
            // Deliberately loose. The claim is "a draft does not bake", and a bake is
            // an order of magnitude, not a few percent — a tight bound here would be a
            // flaky test rather than a stronger one.
            XCTAssertLessThan(
                draft, settle / 4,
                "dragging \(control) re-keys a colour table on every event; the draft "
                    + "path must serve the newest table and bake off the render path "
                    + "(draft \(String(format: "%.1f", draft)) ms vs settle "
                    + "\(String(format: "%.1f", settle)) ms)")
        }
    }
}
