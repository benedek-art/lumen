// ProofRecord.swift
//
// The committed result of measuring one control (docs/20 §"The record").
//
// The point of writing these to disk is that a behaviour change becomes visible in a
// diff. Every defect docs/19 found was invisible until somebody thought to measure, and
// none of them would have surfaced in a code review — Texture at a twenty-fifth of its
// reference, Blacks moving 2.9 of 255 levels, thirteen of twenty Sharpen Radius settings
// rendering byte-identical. A committed number is the cheapest way to make the next one
// of those show up as a red line in a pull request instead of a discovery months later.
//
// Records are compared with a tolerance, not for equality. These come out of float
// arithmetic through a baked LUT; glibc dispatches exp/log/pow to FMA-using variants
// when the CPU has them, so the same source on a different runner returns results a few
// ulp apart. `scripts/gen-fixtures.py --check` learned that the hard way — it once
// failed on 163 values whose worst deviation was 8e-15 relative — and this file uses the
// same discipline: a tolerance six orders of magnitude below anything a real change
// produces.

import Foundation

/// One control's measured behaviour, as committed to `Tests/LumenCoreTests/Proof/records`.
struct ProofRecord: Codable, Equatable {
    /// Stable identifier, e.g. `tone.exposure`. Matches `ControlSpec.id`.
    var id: String
    /// The panel a photographer finds it in.
    var panel: String
    /// Which `ProofFrames` frame it was swept on. A record whose frame does not contain
    /// the control's subject is an INVALID PROBE, not a result.
    var frame: String
    /// Travel actually swept, in the control's own units.
    var travelLow: Double
    var travelHigh: Double

    // MARK: P2 — alive
    /// Steps in the sweep that produced no change at all.
    var deadSteps: Int
    /// Smallest step that did move the picture, in code values.
    var smallestLiveStep: Double

    // MARK: P3 — authority
    /// Peak separation between the ends of the travel, in sRGB code values (0…255).
    var authority: Double
    /// Mean separation over the frame, same units.
    var meanSeparation: Double
    /// Share of the total effect delivered by the first half of the travel.
    var frontLoading: Double

    // MARK: P4 — well-behaved
    var isMonotone: Bool
    /// Worst excursion beyond the input's own range, in code values. Nil where the
    /// control cannot produce one (a global tone move legitimately leaves the range).
    var overshoot: Double?
    /// Largest hue rotation over the sweep, degrees. Nil where not applicable.
    var hueRotation: Double?

    // MARK: P1 — reaches
    /// `file:line` of a reader on the shipping path. The proof that catches an inert
    /// control, and the one this project has failed most often.
    var shippingReader: String

    // MARK: P6 — baseline
    /// Which tier the competitive claim rests on: `a` an open implementation, `b` a
    /// published standard or paper, `c` behaviour observed in docs/02 or docs/03.
    /// Nil until a baseline has actually been measured — deliberately not defaulted,
    /// because an unmeasured control claiming tier (c) is exactly the overstatement
    /// docs/20 exists to prevent.
    var baselineTier: String?
    var baselineNote: String?

    /// Records agree when every number agrees to within a tolerance far below any real
    /// behaviour change. 1e-6 code values is a billionth of a level.
    func agrees(with other: ProofRecord, tolerance: Double = 1e-6) -> Bool {
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= tolerance }
        func near(_ a: Double?, _ b: Double?) -> Bool {
            switch (a, b) {
            case (nil, nil): return true
            case let (x?, y?): return near(x, y)
            default: return false
            }
        }
        return id == other.id && frame == other.frame
            && deadSteps == other.deadSteps
            && near(smallestLiveStep, other.smallestLiveStep)
            && near(authority, other.authority)
            && near(meanSeparation, other.meanSeparation)
            && near(frontLoading, other.frontLoading)
            && isMonotone == other.isMonotone
            && near(overshoot, other.overshoot)
            && near(hueRotation, other.hueRotation)
    }

    /// One line, for a failure message a human can read without opening the JSON.
    var summary: String {
        // Interpolation rather than `String(format:)`. The `%@` conversion takes an
        // Objective-C object, and a Swift `String` is only bridged to one where the
        // ObjC runtime exists — so the same call that reads correctly on macOS can drop
        // its text on Linux. It happens to work on the toolchain in use, verified by
        // reading the output; it is still the wrong construct to leave inside a FAILURE
        // MESSAGE, where losing the control's name would make a red test unreadable
        // exactly when someone needs to read it.
        func f(_ v: Double, _ places: Int) -> String {
            let scale = pow(10.0, Double(places))
            return String((v * scale).rounded() / scale)
        }
        // The shape word is computed OUTSIDE the interpolation on purpose.
        // `scripts/check-swift-surface.py` blanks string bodies so that prose cannot
        // invent symbols, and a string literal nested inside an interpolation —
        // `\(flag ? "a" : "b")` — defeats its quote tracking: the text between the
        // inner quotes reads as code. The first draft said "NOT monotone" there and the
        // checker duly reported `NOT` as an identifier declared nowhere in-tree.
        let shape = isMonotone ? "monotone" : "not monotone"
        return "\(id)  authority \(f(authority, 2))  mean \(f(meanSeparation, 3))"
            + "  front \(f(frontLoading * 100, 0))%  dead \(deadSteps)  \(shape)"
    }
}

enum ProofRecordStore {
    static var directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("records", isDirectory: true)

    static func url(for id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    static func write(_ record: ProofRecord) throws {
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        // Sorted keys and pretty printing, so a diff of a record reads as a change in
        // one number rather than a reshuffled blob.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: url(for: record.id))
    }

    static func read(_ id: String) -> ProofRecord? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return try? JSONDecoder().decode(ProofRecord.self, from: data)
    }
}
