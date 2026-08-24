// ControlProofTests.swift
//
// Runs every control in `ProofRegistry` through the six proofs and commits the result.
//
// This is the test docs/19 said was missing. Its own words: "Clarity at 1/48 and Texture
// at 1/17 both sat behind green tests. That is not a reassuring hit rate." Every
// structural assertion in the suite passed while Blacks moved the picture by 2.9 of 255
// levels — below what an 8-bit display can show — because no assertion anywhere asked
// how MUCH a control does. These do.

import Foundation
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
    ///
    /// PRESENCE IS NOT ENOUGH, and this used to test for it. A CI `env:` block whose
    /// value comes from a `${{ }}` expression sets the variable to the EMPTY STRING
    /// when the expression is falsy rather than leaving it unset — so `!= nil` was true
    /// on every push, and the lane rewrote the records it existed to check. It went
    /// green for a full run on measurements that had really moved (tone.exposure
    /// measured 251.54 against a committed 169.07 and reported no drift).
    ///
    /// A check whose failure mode is "silently stops checking" has to be hard to turn
    /// on by accident, so it now wants a value that means yes.
    private var isRecording: Bool {
        guard let raw = ProcessInfo.processInfo.environment["LUMEN_RECORD_PROOFS"] else {
            return false
        }
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        return !["", "0", "false", "no", "off"].contains(value)
    }

    // MARK: - P2 and P3: every control is alive, and does enough to be seen

    func testEveryRegisteredControlIsAliveAcrossItsWholeTravel() {
        for spec in ProofRegistry.all {
            let record = ProofRunner.measured(spec)
            // Equality against the DECLARED plateau, which is zero for every control
            // that has not argued for one — so this is the same assertion it has always
            // been everywhere it has always been made. docs/20 P2 forbids "a plateau
            // the control does not declare", and `primaries.rPurity` is the first
            // control in this registry to declare one: Rec.2020's red primary already
            // sits on the x + y = 1 line, so `safeChromaticity` refuses to push it any
            // further out and the positive half of that slider is a clamp.
            //
            // The equality cuts both ways on purpose. A plateau that GROWS is a
            // regression, and a plateau that DISAPPEARS is a fix that has to say so in
            // a commit message rather than quietly widening a bound nobody re-reads.
            XCTAssertEqual(
                record.deadSteps, spec.declaredPlateauSteps,
                "\(spec.id) is dead at \(record.deadSteps) of 20 steps against "
                    + "\(spec.declaredPlateauSteps) declared — some part of "
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

    /// Share of its own authority a control may hand back over its travel.
    ///
    /// The bar exists because the boolean beside it cannot carry one. `isMonotone` asks
    /// whether the peak separation ever fell, at a tolerance of a billionth of a code
    /// value, and two of the mixer's controls answer no for reasons that are not
    /// defects: `mixer.magenta.sat` reverses only through the 65³ colour-grade table,
    /// whose own interpolation error on that patch is 4.8 code values against an engine
    /// response that is exactly linear in chroma; `mixer.red.hue` reverses with the
    /// tables removed as well, because a hue slider moves a colour along a curve and the
    /// peak chord from one end of a curve is not monotone in the angle. Neither is a
    /// control the photographer can see changing its mind. Both are recorded, honestly,
    /// as not monotone.
    ///
    /// What the property is worth asserting for is DETAIL-14's shape — Luminance giving
    /// back gain past ~50, a slider whose top half undoes part of its bottom half. That
    /// is a fraction of the control's effect, so it is asserted as one.
    ///
    /// 5% is set from the measurement and deliberately loose: the two controls above are
    /// the only ones in the registry that give anything back at all, at 0.53% and 0.88%,
    /// and the remaining forty-four give back exactly zero. A ceiling six times the
    /// worst reading leaves room for the table's error on a control nobody has swept yet
    /// while staying an order of magnitude below anything a photographer could see. It
    /// tightens when there is a reason to tighten it, and the records make the day that
    /// becomes possible a diff.
    static let reversalCeilingFraction = 0.05

    /// The assertion PROOF-01 left in an in-between state, now applied to every control
    /// in the registry — the mixer included, which is where the question came from.
    func testNoControlHandsBackASeeableShareOfItsOwnEffect() {
        var report = [String]()
        for spec in ProofRegistry.all {
            let record = ProofRunner.measured(spec)
            let ceiling = Self.reversalCeilingFraction * record.authority
            if record.givenBack > 0 {
                // Formatted OUTSIDE the interpolation. A string literal nested inside
                // `\( )` defeats `scripts/check-swift-surface.py`'s quote tracking —
                // `ProofRecord.summary` carries the note about the run that cost.
                let back = String(format: "%.4f", record.givenBack)
                let total = String(format: "%.2f", record.authority)
                let share = String(format: "%.3f",
                                   100 * record.givenBack / record.authority)
                report.append("\(spec.id)  gave back \(back) of \(total) code values "
                              + "(\(share)% of its authority)")
            }
            // A CIRCULAR control reverses by construction: sweep a hue wheel far
            // enough and it comes back where it started, so "hands back" is the shape
            // of the control, not a defect in it. This assertion was calibrated on 46
            // linear controls where 44 gave back exactly zero, and the registry has
            // since gained four grading hue wheels and the rotations around them.
            //
            // Same for a control that declares a plateau: `declaredPlateauSteps` is an
            // asserted equality elsewhere, so a boundary-mover that pauses is already
            // pinned by a stronger check than this one.
            //
            // Two agents building the same harness in parallel is how this arrived —
            // each was right about the controls it could see. The exemption is written
            // as a property of the SPEC rather than a list of ids, so the next circular
            // control added is covered without anybody remembering this.
            if spec.isCircular || spec.declaredPlateauSteps > 0 { continue }
            // A declared reversal is PINNED, not exempted: the control is allowed the
            // amount it was measured handing back and no more. A reversal that grows is
            // a regression; one that shrinks is a fix, and either way somebody has to
            // say which in a commit message.
            if let declared = spec.declaredReversal {
                XCTAssertLessThanOrEqual(
                    record.givenBack, declared * 1.05,
                    "\(spec.id) hands back \(record.givenBack), past the \(declared) it "
                        + "declares. It moves a boundary rather than a magnitude, so some "
                        + "reversal is expected — this is more than was measured.")
                continue
            }
            XCTAssertLessThan(
                record.givenBack, ceiling,
                "\(spec.id) hands back \(record.givenBack) of the "
                    + "\(record.authority) code values it moves the picture over its "
                    + "travel — past its ceiling of \(ceiling). A slider whose top half "
                    + "undoes part of its bottom half is doing two things and the "
                    + "photographer can only see one.")
        }
        print("\n=== controls that reverse at all, sRGB code values ===")
        if report.isEmpty { print("  none") } else { report.forEach { print($0) } }
        print("")
    }

    func testNoControlLeavesTheRangeUnlessItIsEntitledTo() {
        var report = [String]()
        defer {
            print("\n=== excursion beyond the frame's own range, sRGB code values ===")
            report.forEach { print("  " + $0) }
            print("")
        }
        for spec in ProofRegistry.all where !spec.mayLeaveRange {
            let record = ProofRunner.measured(spec)
            guard let overshoot = record.overshoot else {
                XCTFail("\(spec.id) declares it may not leave the range but recorded no "
                        + "overshoot measurement")
                continue
            }
            // Formatted outside the interpolation, per `ProofRecord.summary`.
            let above = String(format: "%.2f", record.overshootAbove ?? -1)
            let below = String(format: "%.2f", record.overshootBelow ?? -1)
            report.append("\(spec.id)  above \(above)  below \(below)")
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
                // Absent and undecodable are DIFFERENT problems and this message used
                // to conflate them, because `read` is a `try?` that returns nil either
                // way. Merging two harness changes produced 65 records that existed on
                // disk and could not be decoded, and the suite reported all 65 as
                // missing — a check telling a half-truth about its own failure, which
                // is the exact shape this audit has spent its time removing.
                let onDisk = FileManager.default.fileExists(
                    atPath: ProofRecordStore.url(for: spec.id).path)
                XCTFail(onDisk
                    ? "\(spec.id) HAS a committed record and it could not be decoded — "
                        + "the record's shape and ProofRecord's have diverged. Re-record "
                        + "with LUMEN_RECORD_PROOFS=1 and say in the commit why the shape "
                        + "changed."
                    : "\(spec.id) has no committed record. Run the suite once with "
                        + "LUMEN_RECORD_PROOFS=1 and commit what it writes, or paste "
                        + "the JSON below into "
                        + "Tests/LumenCoreTests/Proof/records/\(spec.id).json:\n"
                        + ControlProofTests.recordJSON(fresh))
                continue
            }
            if !fresh.agrees(with: committed) {
                drifted.append("  \(spec.id)\n    committed: \(committed.summary)"
                               + "\n    now:       \(fresh.summary)"
                               // The new record in full, byte-identical to what
                               // `ProofRecordStore.write` would put on disk, so a
                               // DELIBERATE change can be committed straight out of a
                               // red run's log. `summary` rounds, so it cannot serve;
                               // and the artifact upload cannot either from anywhere
                               // that can read the log but not reach the blob store it
                               // lands in. Both were tried before this.
                               + "\n    --- \(spec.id).json ---\n"
                               + ControlProofTests.recordJSON(fresh)
                               + "\n    --- end \(spec.id).json ---")
            }
        }
        XCTAssertTrue(
            drifted.isEmpty,
            "A control's measured behaviour moved. That is either a fix or a regression, "
                + "and the commit message has to say which:\n" + drifted.joined(separator: "\n"))
    }

    /// One record as the exact bytes `ProofRecordStore.write` would put on disk.
    ///
    /// Same encoder settings on purpose — pretty printed, sorted keys — so what a red
    /// run prints can be pasted into the records directory without reformatting, and a
    /// diff of the result reads as a change in one number rather than a reshuffled blob.
    static func recordJSON(_ record: ProofRecord) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(record),
              let text = String(data: data, encoding: .utf8)
        else {
            return "<record for \(record.id) could not be encoded>"
        }
        return text
    }

    // MARK: - Evidence

    /// Not an assertion. Writes the pictures docs/20 exists to put in front of a human.
    func testWriteTheEvidenceSheets() throws {
        for spec in ProofRegistry.all {
            try ProofEvidence.write(ProofRunner.evidence(spec), named: "control-\(spec.id)")
        }
    }
}
