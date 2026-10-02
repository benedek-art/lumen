// ControlProbeHarness.swift
// One control, measured, as JSON on stdout — so an agent can ask about a slider without
// building anything.
//
// WHY THIS EXISTS AND WHAT IT IS NOT.
//
// The slider atlas run puts three agents on each of 187 controls. Every one of them needs
// numbers, and there were exactly two ways to get numbers out of this engine before this
// file: `swift test`, which costs ~100 seconds of SwiftPM planning and takes a build lock
// that blocks every other agent; or `--filter ControlProofTests`, whose `setUp` calls
// `ProofRunner.measureAll(ProofRegistry.all)` and therefore measures all 144 specs no
// matter which test method you asked for. Neither is a thing to do 561 times.
//
// So: this test runs the already-built binary, measures ONE spec, and prints.
//
//     LUMEN_PROBE_CONTROL=tone.contrast .build/debug/LumenPackageTests.xctest \
//         LumenCoreTests.ControlProbeHarness
//
// WHAT IT COSTS, because the first draft of this comment guessed and was wrong by two
// orders of magnitude. Starting the binary is ~0.02 s; the WORK is 29 renders, each of
// which bakes a 65³ cube, and one probe of `tone.exposure` takes **38 s**. It does not
// parallelise: four probes launched at once finished in 235 s rather than 57, because
// `LUT3D` already spreads a bake across every core (LUT.swift:223) and this box has four.
// So a fleet of agents probing at the same time gains nothing over one agent probing in a
// loop — the CPU is the queue, and the only real lever is rendering less per probe, which
// is why the per-step block below samples five settings and not twenty-one.
//
// IT IS INERT WITHOUT THE VARIABLE, deliberately and in the same shape `ControlProofTests`
// guards `LUMEN_RECORD_PROOFS`: absent, empty, "0", "false", "no" and "off" all mean no.
// That guard is not decoration — run 181 reported no drift while `tone.exposure` measured
// 251.54 against a committed 169.07, because GitHub sets an unset input to the empty
// string and a `!= nil` check read that as yes. Every CI lane runs this file and gets a
// skip.
//
// WHAT IT ADDS OVER THE COMMITTED RECORD. `ProofRecord` is a reduction: nine numbers for a
// whole sweep. `ProofMetrics.sweep` renders 21 images and keeps only the deltas between
// them (ProofMetrics.swift:165-178) — the images themselves are local and gone. An agent
// asking "does Highlights posterize at +80" or "which end clips first" cannot answer from
// the record. So this re-renders settings from the same sweep and reports, per step: the
// darkest and brightest code value, the mean, how many samples sit at 0 and at 255, and
// the peak separation from the control's own neutral. That last one is what makes a
// plateau visible as a plateau rather than as a small number, and the clipping counts are
// the shape of number A1-01 was found with — 34 of 256 ramp columns at exactly 255.
//
// THE SWEEP ITSELF IS `ProofRunner.measure`, not a reimplementation. Same 21 steps, same
// frame, same `LUT3D.exportSize`, so every number it prints is comparable to the committed
// record by construction — and it prints that comparison, because a harness whose sweep
// had drifted from the lane's sweep would be a very expensive way to be wrong 187 times.

import Foundation
import XCTest
@testable import LumenCore

final class ControlProbeHarness: XCTestCase {

    /// Absent, empty, "0", "false", "no", "off" → not probing. See the header.
    private static func flag(_ name: String) -> String? {
        guard let raw = ProcessInfo.processInfo.environment[name] else { return nil }
        let v = raw.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return nil }
        return ["0", "false", "no", "off"].contains(v.lowercased()) ? nil : v
    }

    /// THE WHOLE REGISTRY AS DATA, so nothing outside this target has to parse Swift to
    /// learn what a control declares.
    ///
    /// `ProofRegistry.all` is 144 specs built from 68 `ControlSpec` literals — twelve of
    /// them inside loops that interpolate a band or a zone name into the id — so a script
    /// that read the source would have to re-implement the loops to see the other 76.
    /// The atlas work list needs every declared low, high, neutral, frame and floor, and
    /// getting them by transcription is how a work list ends up describing controls that
    /// do not exist. This prints them from the array itself.
    ///
    /// Same guard shape as the probe below: nothing happens without the variable, so
    /// every lane skips it.
    func testDumpTheRegistry() throws {
        guard Self.flag("LUMEN_PROBE_DUMP_REGISTRY") != nil else {
            throw XCTSkip("set LUMEN_PROBE_DUMP_REGISTRY=1 to print ProofRegistry as JSON")
        }
        let specs: [[String: Any]] = ProofRegistry.all.map { spec in
            [
                "id": spec.id,
                "panel": spec.panel,
                "displayName": spec.displayName,
                "low": spec.low,
                "high": spec.high,
                "neutral": spec.neutral,
                "authorityEnd": spec.authorityEnd,
                "frame": spec.frameName,
                "authorityFloor": spec.authorityFloor,
                "mayLeaveRange": spec.mayLeaveRange,
                "overshootCeiling": spec.overshootCeiling as Any? ?? NSNull(),
                "isCircular": spec.isCircular,
                "captureISO": spec.captureISO as Any? ?? NSNull(),
                "denoisedFirst": spec.denoisedFirst,
                "declaredPlateauSteps": spec.declaredPlateauSteps,
                "declaredReversal": spec.declaredReversal as Any? ?? NSNull(),
                "hasCommittedRecord": ProofRecordStore.read(spec.id) != nil,
            ]
        }
        let data = try JSONSerialization.data(
            withJSONObject: ["count": specs.count, "specs": specs],
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print("REGISTRY_BEGIN")
        print(String(data: data, encoding: .utf8) ?? "{}")
        print("REGISTRY_END")
    }

    func testProbeOneControl() throws {
        guard let wanted = Self.flag("LUMEN_PROBE_CONTROL") else {
            throw XCTSkip("set LUMEN_PROBE_CONTROL=<control id> to probe one control")
        }
        guard let spec = ProofRegistry.all.first(where: { $0.id == wanted }) else {
            let near = ProofRegistry.all.map(\.id)
                .filter { $0.hasPrefix(String(wanted.prefix(4))) }.sorted()
            return XCTFail("no ControlSpec with id \"\(wanted)\". "
                + (near.isEmpty
                    ? "There are \(ProofRegistry.all.count) specs; none begins like that."
                    : "Did you mean one of: \(near.joined(separator: ", "))?"))
        }

        // Evidence goes wherever the caller says, so a run writes contact sheets into a
        // scratchpad instead of dirtying the repository. `ProofEvidence.directory` is a
        // `static var` for exactly this (ProofEvidence.swift:22-24).
        if let dir = Self.flag("LUMEN_PROBE_EVIDENCE_DIR") {
            ProofEvidence.directory = URL(fileURLWithPath: dir, isDirectory: true)
        }

        let steps = Int(Self.flag("LUMEN_PROBE_STEPS") ?? "") ?? 21
        let frame = spec.frame()
        let record = ProofRunner.measure(spec, steps: steps)
        let neutral = ProofRunner.neutralRender(spec, frame: frame)

        // Settings from the same sweep, re-rendered so the per-step statistics `measure`
        // throws away can be reported. FIVE OF THEM BY DEFAULT, NOT TWENTY-ONE, and the
        // reason is measured. Rendering all 21 here made a `tone.exposure` probe 57 s and
        // four concurrent probes 235 s; taking five brought one probe to 38 s. Every
        // render bakes a 65³ cube and `LUT3D` already spreads that bake over every core
        // (LUT.swift:223), so probing is CPU-bound and does not parallelise — with 187
        // controls to get through, sixteen extra renders each is an hour of wall clock
        // bought for detail that five samples carry.
        //
        // Five is low / quarter / neutral / three-quarter / high, which is where the
        // questions the record cannot answer actually live: what clips, at which end, and
        // whether the shape between the ends is a curve or a corner. `deadSteps` and
        // `smallestLiveStep` in the record above already speak for all 21.
        //
        // `LUMEN_PROBE_PERSTEP=full` renders all of them, for a control where the shape
        // is the question — a suspected plateau, or a step that only some settings take.
        let wantsFull = Self.flag("LUMEN_PROBE_PERSTEP")?.lowercased() == "full"
        let indices: [Int] = wantsFull
            ? Array(0..<steps)
            : Array(Set([0, (steps - 1) / 4, (steps - 1) / 2,
                         (steps - 1) * 3 / 4, steps - 1])).sorted()
        var perStep: [[String: Any]] = []
        for i in indices {
            let setting = spec.low
                + (spec.high - spec.low) * Double(i) / Double(steps - 1)
            let image = ProofRunner.render(spec, at: setting, frame: frame)
            perStep.append(Self.statistics(of: image, setting: setting,
                                           against: neutral))
        }

        // Anywhere else the caller wants to look — the settings a cartographer named as
        // interesting, which is usually where a formula is claimed to do something exact.
        var extra: [[String: Any]] = []
        if let list = Self.flag("LUMEN_PROBE_SETTINGS") {
            for text in list.split(separator: ",") {
                guard let setting = Double(text.trimmingCharacters(in: .whitespaces)) else {
                    return XCTFail("LUMEN_PROBE_SETTINGS has a value that is not a "
                        + "number: \"\(text)\"")
                }
                let image = ProofRunner.render(spec, at: setting, frame: frame)
                extra.append(Self.statistics(of: image, setting: setting,
                                             against: neutral))
            }
        }

        // Does this harness agree with the lane? If not, everything downstream of it is
        // measuring the harness rather than the engine, so it is reported first.
        var againstRecord: [String: Any] = ["committedRecordExists": false]
        if let committed = ProofRecordStore.read(spec.id) {
            againstRecord = [
                "committedRecordExists": true,
                "agrees": record.agrees(with: committed),
                "committedAuthority": committed.authority,
                "committedDeadSteps": committed.deadSteps,
                "committedSummary": committed.summary,
            ]
        }

        let evidence = try? ProofEvidence.write(ProofRunner.evidence(spec),
                                                named: "probe-\(spec.id)")

        let document: [String: Any] = [
            "id": spec.id,
            "displayName": spec.displayName,
            "panel": spec.panel,
            "declared": [
                "low": spec.low,
                "high": spec.high,
                "neutral": spec.neutral,
                "authorityEnd": spec.authorityEnd,
                "frame": spec.frameName,
                "frameWidth": frame.width,
                "frameHeight": frame.height,
                "authorityFloor": spec.authorityFloor,
                "mayLeaveRange": spec.mayLeaveRange,
                "overshootCeiling": spec.overshootCeiling as Any? ?? NSNull(),
                "isCircular": spec.isCircular,
                "captureISO": spec.captureISO as Any? ?? NSNull(),
                "denoisedFirst": spec.denoisedFirst,
                "declaredPlateauSteps": spec.declaredPlateauSteps,
                "declaredReversal": spec.declaredReversal as Any? ?? NSNull(),
            ],
            "sweep": Self.encoded(record),
            "steps": steps,
            "perStepIsFullSweep": wantsFull,
            "perStep": perStep,
            "extraSettings": extra,
            "againstCommittedRecord": againstRecord,
            "evidencePNG": evidence?.path as Any? ?? NSNull(),
        ]

        let data = try JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print("PROBE_BEGIN")
        print(String(data: data, encoding: .utf8) ?? "{}")
        print("PROBE_END")
    }

    // MARK: - helpers

    /// What one render looks like, in the same sRGB code values every other proof number
    /// is denominated in (`ProofMetrics` header). `atZero` and `at255` are counted with a
    /// half-code-value tolerance: a value that encodes to 254.9997 is at the ceiling for
    /// every purpose a photographer has, and counting only exact 255.0 hid the contrast
    /// burn in A1-01 for one draft of that investigation.
    private static func statistics(of image: ImageBuffer, setting: Double,
                                   against neutral: ImageBuffer) -> [String: Any]
    {
        let values = ProofMetrics.codeValues(image)
        var lo = Double.infinity, hi = -Double.infinity, total = 0.0
        var atZero = 0, at255 = 0, nonFinite = 0
        for v in values {
            guard v.isFinite else { nonFinite += 1; continue }
            if v < lo { lo = v }
            if v > hi { hi = v }
            total += v
            if v <= 0.5 { atZero += 1 }
            if v >= 254.5 { at255 += 1 }
        }
        let finite = values.count - nonFinite
        return [
            "setting": setting,
            "min": finite > 0 ? lo : Double.nan as Any,
            "max": finite > 0 ? hi : Double.nan as Any,
            "mean": finite > 0 ? total / Double(finite) : Double.nan as Any,
            "atZero": atZero,
            "at255": at255,
            "nonFinite": nonFinite,
            "samples": values.count,
            "deltaFromNeutral": ProofMetrics.authority(image, neutral),
        ]
    }

    /// The record as a dictionary, through its own `Codable` conformance so this cannot
    /// drift from what `ProofRecordStore.write` puts on disk.
    private static func encoded(_ record: ProofRecord) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(record),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else { return ["error": "ProofRecord did not encode"] }
        return dictionary
    }
}
