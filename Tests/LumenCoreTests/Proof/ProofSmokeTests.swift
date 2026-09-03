// The per-push tripwire (docs/23, M0). The full 111-control drift sweep costs 80
// minutes and is moving to a nightly lane; this is what stands guard on every push
// instead: eight sentinel controls, one per region of the engine a photographer
// touches first, measured at five steps in about a minute.
//
// This is a SMOKE test, not the drift check. It asserts the two properties whose loss
// is a catastrophe rather than a drift — the control is alive across its travel, and
// its authority clears the registry's floor — and leaves exact-number comparison to
// the nightly `testTheCommittedRecordsStillDescribeWhatTheEngineDoes`. A five-step
// sweep measures a different (smaller-or-equal) peak than the recorded 21-step one, so
// comparing against the committed record here would be comparing two different
// questions; the floor, by contrast, was set as a property of the control and holds at
// any step count for a monotone control because both travel ends are always sampled.
//
// The sentinels deliberately have `declaredPlateauSteps == 0` — a guard asserts that,
// so nobody adds a plateaued sentinel and then wonders why deadSteps == 0 fails.
import XCTest
@testable import LumenCore

final class ProofSmokeTests: XCTestCase {

    /// One per engine region: tone gain, tone shelf, white balance, global colour,
    /// parametric curve, mixer, presence, denoise.
    private static let sentinels: Set<String> = [
        "tone.exposure",
        "tone.highlights",
        "raw.temp",
        "color.saturation",
        "curve.highlights",
        "mixer.red.hue",
        "detail.clarity",
        "denoise.luma",
    ]

    func testSentinelControlsAreAliveWithVisibleAuthority() {
        var seen = [String]()
        for spec in ProofRegistry.all where Self.sentinels.contains(spec.id) {
            seen.append(spec.id)
            XCTAssertEqual(spec.declaredPlateauSteps, 0,
                "\(spec.id) declares a plateau, so it cannot be a smoke sentinel — "
                    + "pick a control whose whole travel is live")
            let record = ProofRunner.measure(spec, steps: 5)
            XCTAssertEqual(record.deadSteps, 0,
                "\(spec.id) has a dead step at five-step granularity — a fifth of its "
                    + "travel changes nothing. That is not drift, that is a dead control.")
            XCTAssertGreaterThanOrEqual(record.authority, spec.authorityFloor,
                "\(spec.id) moved the picture \(record.authority) code values across its "
                    + "travel, under its floor of \(spec.authorityFloor). The full sweep "
                    + "would call this drift; at smoke granularity it is a broken control.")
        }
        XCTAssertEqual(seen.sorted(), Self.sentinels.sorted(),
            "The registry no longer carries every sentinel — if a control was renamed, "
                + "rename it here in the same commit")
    }
}
