// ProofRunner.swift
//
// Sweeps one `ControlSpec` and produces its `ProofRecord`.
//
// Everything renders at `LUT3D.exportSize`. The interactive size is what a photographer
// sees while dragging, but a proof is a statement about what the control DOES, and at
// size 33 the baked table contributes up to 0.197 stops of its own — which would put a
// measurable slice of every authority number in this file down to interpolation error
// rather than to the control. docs/18 measured that ladder; this is it being used.

import Foundation
import LumenCore

enum ProofRunner {

    /// Measurements are cached across test methods.
    ///
    /// Not premature optimisation: a sweep is 21 renders and each one bakes a 65³ colour
    /// cube — 274,625 evaluations through the colour and grade engines — so measuring
    /// eleven controls once costs about a minute and measuring them four times, once per
    /// test method that wants them, costs more than the whole rest of the engine suite
    /// put together. The cache is keyed by control id and the specs are immutable, so
    /// every reader sees the same numbers the record was written from.
    private static var cache = [String: ProofRecord]()
    private static let cacheLock = NSLock()

    static func measured(_ spec: ControlSpec) -> ProofRecord {
        cacheLock.lock()
        if let hit = cache[spec.id] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        let fresh = measure(spec)
        cacheLock.lock(); cache[spec.id] = fresh; cacheLock.unlock()
        return fresh
    }

    /// Render one setting of one control.
    static func render(_ spec: ControlSpec, at setting: Double,
                       frame: ImageBuffer) -> ImageBuffer
    {
        var recipe = Recipe()
        spec.apply(&recipe, setting)
        return ReferenceRenderer.render(
            frame, plan: RenderPlan(recipe: recipe, lutSize: LUT3D.exportSize))
    }

    /// The neutral render — the control sitting where it does nothing.
    static func neutralRender(_ spec: ControlSpec, frame: ImageBuffer) -> ImageBuffer {
        render(spec, at: spec.neutral, frame: frame)
    }

    /// Measure a control end to end and produce its record.
    static func measure(_ spec: ControlSpec, steps: Int = 21) -> ProofRecord {
        let frame = spec.frame()
        let sweep = ProofMetrics.sweep(from: spec.low, to: spec.high, steps: steps) {
            render(spec, at: $0, frame: frame)
        }

        let lowEnd = render(spec, at: spec.low, frame: frame)
        let highEnd = render(spec, at: spec.high, frame: frame)
        let neutral = neutralRender(spec, frame: frame)

        // Overshoot is only a defect for an operator that claims to work within the
        // picture's own range. Asking it of Exposure would report "overshoot 120" and
        // mean nothing: raising exposure is SUPPOSED to leave the input's range.
        let overshoot: Double? = spec.mayLeaveRange
            ? nil
            : Swift.max(ProofMetrics.overshoot(highEnd, against: neutral),
                        ProofMetrics.overshoot(lowEnd, against: neutral))

        // Hue rotation is only defined where the frame carries chroma. On a grey ramp
        // every pixel is on the neutral axis and the angle is rounding error — the
        // unguarded-angle trap that hid the Protect Skin defect for months.
        let hueRotation: Double? = spec.frameName == "neutralRamp"
            ? nil
            : Swift.max(ProofMetrics.hueRotation(neutral, highEnd),
                        ProofMetrics.hueRotation(neutral, lowEnd))

        return ProofRecord(
            id: spec.id, panel: spec.panel, frame: spec.frameName,
            travelLow: spec.low, travelHigh: spec.high,
            deadSteps: sweep.deadSteps.count,
            smallestLiveStep: sweep.smallestLiveStep,
            authority: sweep.authority,
            meanSeparation: ProofMetrics.meanSeparation(lowEnd, highEnd),
            frontLoading: sweep.frontLoading,
            isMonotone: sweep.isMonotone,
            overshoot: overshoot,
            hueRotation: hueRotation,
            shippingReader: spec.shippingReader,
            baselineTier: nil, baselineNote: nil)
    }

    /// Render the three evidence frames for a control — full negative, neutral, full
    /// positive — as one contact sheet the owner can open and judge.
    static func evidence(_ spec: ControlSpec) -> ImageBuffer {
        let frame = spec.frame()
        return ProofEvidence.contactSheet([
            render(spec, at: spec.low, frame: frame),
            neutralRender(spec, frame: frame),
            render(spec, at: spec.high, frame: frame),
        ])
    }
}
