// ControlProofTests.swift
//
// Runs every control in `ProofRegistry` through the six proofs and commits the result.
//
// This is the test docs/19 said was missing. Its own words: "Clarity at 1/48 and Texture
// at 1/17 both sat behind green tests. That is not a reassuring hit rate." Every
// structural assertion in the suite passed while Blacks moved the picture by 2.9 of 255
// levels — below what an 8-bit display can show — because no assertion anywhere asked
// how MUCH a control does. These do.

import XCTest
import LumenCore

final class ControlProofTests: XCTestCase {

    /// Fill the measurement cache across cores before the first test that needs it.
    override class func setUp() {
        super.setUp()
        ProofRunner.measureAll(ProofRegistry.all)
    }

    /// Set to regenerate the committed records after a deliberate behaviour change.
    /// The drift test below is what makes an accidental one visible.
    private var isRecording: Bool {
        ProcessInfo.processInfo.environment["LUMEN_RECORD_PROOFS"] != nil
    }

    // MARK: - P2 and P3: every control is alive, and does enough to be seen

    func testEveryRegisteredControlIsAliveAcrossItsWholeTravel() {
        for spec in ProofRegistry.all {
            let record = ProofRunner.measured(spec)
            XCTAssertEqual(
                record.deadSteps, 0,
                "\(spec.id) is dead at \(record.deadSteps) of 20 steps — some part of "
                    + "its travel renders byte-identical to the step before it. Before "
                    + "concluding the control is dead, check that the registry's declared "
                    + "range matches the panel's and the engine's clamp: a large dead count "
                    + "is far more often a probe driven past a control's own bounds, which "
                    + "is what docs/19 found three times and what this harness found on its "
                    + "first run.")
            XCTAssertGreaterThan(
                record.smallestLiveStep, 0,
                "\(spec.id) never moved the picture at all")
        }
    }

    func testEveryRegisteredControlHasVisibleAuthority() {
        var report = [String]()
        for spec in ProofRegistry.all {
            let record = ProofRunner.measured(spec)
            report.append(record.summary)
            XCTAssertGreaterThanOrEqual(
                record.authority, spec.authorityFloor,
                "\(spec.id) moves the picture by \(String(format: "%.1f", record.authority)) "
                    + "of 255 levels over its whole travel, under its floor of "
                    + "\(spec.authorityFloor). This is the Blacks-at-2.9 failure: a "
                    + "control the photographer cannot see is not a control.")
        }
        print("\n=== control authority, sRGB code values over full travel ===")
        report.forEach { print("  " + $0) }
        print("")
    }

    // MARK: - P4: well-behaved

    func testNoControlLeavesTheRangeUnlessItIsEntitledTo() {
        for spec in ProofRegistry.all where !spec.mayLeaveRange {
            let record = ProofRunner.measured(spec)
            guard let overshoot = record.overshoot else {
                XCTFail("\(spec.id) declares it may not leave the range but recorded no "
                        + "overshoot measurement")
                continue
            }
            guard let ceiling = spec.overshootCeiling else { continue }
            XCTAssertLessThan(
                overshoot, ceiling,
                "\(spec.id) pushes pixels \(overshoot) code values beyond the input's "
                    + "own range, past its agreed ceiling of \(ceiling) — that is a rim "
                    + "beside every edge")
        }
    }

    // MARK: - The record

    func testTheCommittedRecordsStillDescribeWhatTheEngineDoes() throws {
        var drifted = [String]()
        for spec in ProofRegistry.all {
            let fresh = ProofRunner.measured(spec)
            if isRecording {
                try ProofRecordStore.write(fresh)
                continue
            }
            guard let committed = ProofRecordStore.read(spec.id) else {
                XCTFail("\(spec.id) has no committed record. Run the suite once with "
                        + "LUMEN_RECORD_PROOFS=1 and commit what it writes.")
                continue
            }
            if !fresh.agrees(with: committed) {
                drifted.append("  \(spec.id)\n    committed: \(committed.summary)"
                               + "\n    now:       \(fresh.summary)")
            }
        }
        XCTAssertTrue(
            drifted.isEmpty,
            "A control's measured behaviour moved. That is either a fix or a regression, "
                + "and the commit message has to say which:\n" + drifted.joined(separator: "\n"))
    }

    // MARK: - Evidence

    /// Not an assertion. Writes the pictures docs/20 exists to put in front of a human.
    func testWriteTheEvidenceSheets() throws {
        for spec in ProofRegistry.all {
            try ProofEvidence.write(ProofRunner.evidence(spec), named: "control-\(spec.id)")
        }
    }
}
