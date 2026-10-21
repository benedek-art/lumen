// WS-06 engine probe: every SPEC line that is a property of ToneEngine / RenderPlan
// rather than of a rendered photo. Linked against the RELEASE LumenCore objects, so it
// measures the code that is in the tree, not a Python port of it.
//
// Built and run by run_all.sh:
//   swiftc -O -I $BUILD/Modules -Xcc -fmodule-map-file=Sources/CSQLite3/module.modulemap \
//          -I Sources/CSQLite3 probe.swift $BUILD/LumenCore.build/*.o -lsqlite3 -o probe
//
// Output: one line per item, `KEY value [detail]`, parsed by run_all.sh.

import Foundation
import LumenCore

func out(_ key: String, _ value: Double, _ detail: String = "") {
    print(String(format: "%@ %.6f %@", key as NSString, value, detail as NSString))
}

let whitesGrid: [Double] = [-100, 0, 67, 100]
let blacksGrid: [Double] = [-100, 0, 100]
let pivotGrid: [Double] = [-4, -3, -2, -1.3, 0, 2, 2.37, 3, 3.5, 4]
let contrastGrid: [Double] = stride(from: -100.0, through: 100, by: 5).filter { $0 != 0 }

// ---- S1 identity ---------------------------------------------------------------
do {
    var mismatches = 0, notIdentity = 0
    for pv in pivotGrid { for w in whitesGrid { for b in blacksGrid {
        let e = ToneEngine(tone: Tone(contrast: 0, contrastPivot: pv, whites: w, blacks: b))
        var t = -LumenLog.maxEV
        while t <= LumenLog.maxEV {
            if e.contrastMapped(t) != t { mismatches += 1 }   // bitwise, not approx
            t += 0.001
        }
        if w == 0 && b == 0 {
            if !e.isIdentity { notIdentity += 1 }
            var r = Recipe(); r.develop.tone.contrastPivot = pv
            if !RenderPlan(recipe: r).toneIsIdentity { notIdentity += 1 }
            if e.bakeGainLUT().samples != ToneEngine().bakeGainLUT().samples { notIdentity += 1 }
        }
    }}}
    out("S1_identity_mismatches", Double(mismatches + notIdentity),
        "(contrast 0: contrastMapped(t)!=t samples + non-identity plans/LUTs)")
}

// ---- S2 monotone, S3 fixed points ------------------------------------------------
do {
    var minDer = 1e9, minAt = ""
    var minDerPos = 1e9, minPosAt = ""
    var fixedErr = 0.0, fixedAt = ""
    var outsideErr = 0.0
    var fullScaleInversions = 0
    for c in contrastGrid { for pv in pivotGrid { for w in whitesGrid { for b in blacksGrid {
        let e = ToneEngine(tone: Tone(contrast: c, contrastPivot: pv, whites: w, blacks: b))
        let lo = e.blackAnchorEV, hi = e.whiteAnchorEV
        let h = 1e-3
        var t = lo
        var prev = e.contrastMapped(t)
        while t + h <= hi {
            let v = e.contrastMapped(t + h)
            let d = (v - prev) / h
            if d < minDer { minDer = d; minAt = "c \(c) pivot \(pv) whites \(w) blacks \(b) t \(String(format: "%.3f", t))" }
            if c > 0 && d < minDerPos { minDerPos = d; minPosAt = "c \(c) pivot \(pv) whites \(w) blacks \(b) t \(String(format: "%.3f", t))" }
            prev = v; t += h
        }
        let p = min(max(pv, max(-4, lo)), min(4, hi))
        for x in [p, lo, hi] {
            let err = abs(e.contrastMapped(x) - x)
            if err > fixedErr { fixedErr = err; fixedAt = "c \(c) pivot \(pv) w \(w) b \(b) x \(x)" }
        }
        for x in [hi + 0.01, hi + 1, hi + 4, lo - 0.01, lo - 1, lo - 3] {
            outsideErr = max(outsideErr, abs(e.contrastMapped(x) - x))
        }
        var q = -LumenLog.maxEV, pq = e.contrastMapped(q)
        while q <= LumenLog.maxEV { let v = e.contrastMapped(q); if v < pq { fullScaleInversions += 1 }; pq = v; q += 0.01 }
    }}}}
    out("S2_min_derivative", minDer, "at " + minAt)
    out("S2_min_derivative_positive_c", minDerPos, "(shoulder/toe margin, c > 0) at " + minPosAt)
    out("S2_full_scale_inversions", Double(fullScaleInversions), "(±maxEV, 0.01 EV)")
    out("S3_fixed_point_error", max(fixedErr, outsideErr), "max |m(x)-x| at pivot/anchors/beyond anchors; worst " + fixedAt)
}

// ---- S4 slope law ----------------------------------------------------------------
func slopeAtPivot(_ c: Double, _ tone: Tone = Tone()) -> Double {
    var t = tone; t.contrast = c
    let e = ToneEngine(tone: t)
    let p = e.tone.contrastPivot
    return (e.contrastMapped(p + 1e-4) - e.contrastMapped(p - 1e-4)) / 2e-4
}
do {
    let sp = slopeAtPivot(100), sm = slopeAtPivot(-100)
    out("S4_slope_plus100", sp)
    out("S4_slope_minus100", sm)
    out("S4_slope_plus50", slopeAtPivot(50))
    out("S4_slope_minus50", slopeAtPivot(-50))
    out("S4_log2_asymmetry_100", log2(sp) + log2(sm), "log2 s(+100) + log2 s(-100); 0 = reciprocal ends")
    // monotone in c at unit steps
    var nonInc = 0
    var prev = slopeAtPivot(-100)
    for c in stride(from: -99.0, through: 100, by: 1) { let s = slopeAtPivot(c); if s <= prev { nonInc += 1 }; prev = s }
    out("S4_slope_nonincreasing_steps", Double(nonInc), "(slope at pivot must rise with every unit of the slider)")
    // contrast is never scaled by the zonal limiter
    let a = slopeAtPivot(100, Tone(highlights: -100, shadows: 100))
    let b = slopeAtPivot(-100, Tone(highlights: -100, shadows: 100, whites: -100, blacks: 100))
    out("S4_limiter_touches_contrast", max(abs(a - sp), abs(b - sm)), "|slope with zonal sliders - alone|")
    // deep-shadow and top-stop displacement at +100, pivot 0
    let e = ToneEngine(tone: Tone(contrast: 100))
    out("S5_shift_minus6EV_c100", e.contrastMapped(-6) + 6, "EV moved at -6 EV")
    out("S5_shift_minus7EV_c100", e.contrastMapped(-7) + 7, "EV moved at -7 EV")
    out("S5_log_span_2to4_c100", e.contrastMapped(4) - e.contrastMapped(2), "EV of output spanned by +2..+4 EV input (2.0 = identity)")
}

// ---- S6 zonal limiter (the trade table) -------------------------------------------
do {
    func scale(_ t: Tone) -> Double { ToneEngine(tone: t).zonalScale }
    out("S6_hl-100_at_c+100", ToneEngine(tone: Tone(contrast: 100, highlights: -100)).effectiveHighlights / -1)
    out("S6_sh+100_at_c-100", ToneEngine(tone: Tone(contrast: -100, shadows: 100)).effectiveShadows)
    var paired = 1.0
    for c in [100.0, -100] { for v in [-100.0, 100] {
        paired = min(paired, scale(Tone(contrast: c, highlights: v)), scale(Tone(contrast: c, shadows: v)),
                     scale(Tone(contrast: c, whites: v)), scale(Tone(contrast: c, blacks: v)))
    }}
    out("S6_worst_paired_scale", paired)
    var four = 1.0
    for c in [80.0, 100] { for h in [-100.0, 0, 100] { for s in [-100.0, 0, 100] { for w in [-100.0, 100] { for b in [-100.0, 100] {
        four = min(four, scale(Tone(contrast: c, highlights: h, shadows: s, whites: w, blacks: b)))
    }}}}}
    out("S6_four_way_corner_scale", four)
    var moderate = 1.0
    for c in stride(from: -60.0, through: 60, by: 20) { for h in stride(from: -60.0, through: 60, by: 20) {
        for s in stride(from: -60.0, through: 60, by: 20) { for w in stride(from: -40.0, through: 40, by: 20) {
            for b in stride(from: -40.0, through: 40, by: 20) {
                moderate = min(moderate, scale(Tone(contrast: c, highlights: h, shadows: s, whites: w, blacks: b)))
    }}}}}
    out("S6_moderate_band_scale", moderate)
    // composed tone map (WS-05 non-regression): t + stops(t)
    var worst = 1e9
    for c in stride(from: -100.0, through: 100, by: 25) { for pv in [-4.0, -2, 0, 2, 4] {
        for h in [-100.0, 0, 100] { for s in [-100.0, 0, 100] { for w in [-100.0, 0, 100] { for b in [-100.0, 0, 100] {
            let e = ToneEngine(tone: Tone(contrast: c, contrastPivot: pv, highlights: h, shadows: s, whites: w, blacks: b))
            var t = -9.0, prev = t + e.stops(at: t)
            while t < 5 { t += 0.01; let v = t + e.stops(at: t); worst = min(worst, (v - prev) / 0.01); prev = v }
    }}}}}}
    out("S6_composed_min_derivative", worst)
}

// ---- S7 CPU == GPU source: the baked LUT is stops() --------------------------------
do {
    var err = 0.0, lutMismatch = 0
    for c in [-100.0, -37, 50, 100] { for pv in [-3.0, 0, 2.5] {
        var r = Recipe(); r.develop.tone.contrast = c; r.develop.tone.contrastPivot = pv
        let plan = RenderPlan(recipe: r)
        if plan.toneGainLUT != plan.tone.bakeGainLUT() { lutMismatch += 1 }
        let n = plan.toneGainLUT.samples.count
        for i in 0..<n {
            let y = Double(i) / Double(n - 1)
            let t = log2(max(LumenLog.decode(y), 1e-30) / 0.18)
            guard t.isFinite else { continue }
            err = max(err, abs(log2(plan.toneGainLUT.samples[i]) - plan.tone.stops(at: t)))
        }
    }}
    out("S7_lut_vs_stops_max_err_EV", err + Double(lutMismatch), "(plan LUT == tone.bakeGainLUT, and each sample == 2^stops(t))")

    // The GPU reads the gain through a gray cube of 32 (interactive) or 65 (export)
    // knots on the same shaper axis, interpolated linearly between knots. A sharper
    // curve costs parity there, so measure what the knot spacing loses against the
    // 1024-sample LUT (in stops), over the photographic range of the shaper axis.
    for knots in [32, 65] {
        var worst = 0.0, at = ""
        for c in [-100.0, -50, 50, 100] { for pv in [-3.0, 0, 3] {
            var r = Recipe(); r.develop.tone.contrast = c; r.develop.tone.contrastPivot = pv
            let lut = RenderPlan(recipe: r).toneGainLUT
            let yLo = LumenLog.encode(0.18 * exp2(-9)), yHi = LumenLog.encode(0.18 * exp2(5))
            var y = yLo
            while y <= yHi {
                let k = y * Double(knots - 1), i = min(Int(k), knots - 2), f = k - Double(i)
                let g0 = lut.evaluate(Double(i) / Double(knots - 1))
                let g1 = lut.evaluate(Double(i + 1) / Double(knots - 1))
                let e = abs(log2((g0 + (g1 - g0) * f) / lut.evaluate(y)))
                if e > worst { worst = e; at = "c \(c) pivot \(pv) t \(String(format: "%.2f", log2(LumenLog.decode(y) / 0.18)))" }
                y += 1e-4
            }
        }}
        out("S7_cube\(knots)_interp_err_EV", worst, "at " + at)
    }
    // The case ToneShippingGoldenTests (macOS GPU parity) drives: contrast +60, pivot 0.
    do {
        var r = Recipe(); r.develop.tone.contrast = 60
        let lut = RenderPlan(recipe: r).toneGainLUT
        for knots in [32, 65] {
            var worst = 0.0
            var y = LumenLog.encode(0.18 * exp2(-9))
            while y <= LumenLog.encode(0.18 * exp2(5)) {
                let k = y * Double(knots - 1), i = min(Int(k), knots - 2), f = k - Double(i)
                let g0 = lut.evaluate(Double(i) / Double(knots - 1)), g1 = lut.evaluate(Double(i + 1) / Double(knots - 1))
                worst = max(worst, abs(log2((g0 + (g1 - g0) * f) / lut.evaluate(y))))
                y += 1e-4
            }
            out("S7_golden_c60_cube\(knots)_interp_err_EV", worst)
        }
    }
}

// ---- S8 proof authority replica (ProofRunner on ProofFrames.neutralRamp) -----------
func linearToSRGB(_ x: Double) -> Double {
    let v = min(max(x, 0), 1)
    return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
}
let ramp = ImageBuffer(width: 256, height: 32) { u, _ in RGB(gray: 0.18 * exp2(-8 + 13 * u)) }
func codes(_ apply: (inout Recipe) -> Void) -> [Double] {
    var r = Recipe(); apply(&r)
    let img = ReferenceRenderer.render(ramp, plan: RenderPlan(recipe: r, lutSize: LUT3D.exportSize))
    var o = [Double](); o.reserveCapacity(img.width * img.height * 3)
    for y in 0..<img.height { for x in 0..<img.width {
        let c = img[x, y]; o.append(linearToSRGB(c.r) * 255); o.append(linearToSRGB(c.g) * 255); o.append(linearToSRGB(c.b) * 255)
    }}
    return o
}
func peak(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).reduce(0) { max($0, abs($1.0 - $1.1)) } }
do {
    var renders = [[Double]]()
    for i in 0..<21 { let c = -100 + 10 * Double(i); renders.append(codes { $0.develop.tone.contrast = c }) }
    var steps = [Double](), cum = [Double]()
    for i in 1..<21 { steps.append(peak(renders[i - 1], renders[i])); cum.append(peak(renders[0], renders[i])) }
    let authority = cum.last!
    out("S8_authority_tone.contrast", authority, "(committed record 68.38, floor 55)")
    out("S8_frontLoading_tone.contrast", cum[cum.count / 2] / authority)
    out("S8_deadSteps_tone.contrast", Double(steps.filter { $0 < 1e-9 }.count))
    out("S8_step_peak_ratio", steps.max()! / steps.min()!, "max/min per-10-unit peak step on the proof ramp")
    for (lo, hi) in [(-4.0, 4.0), (-3.0, 3.0)] {
        let a = codes { $0.develop.tone.contrast = 50; $0.develop.tone.contrastPivot = lo }
        let b = codes { $0.develop.tone.contrast = 50; $0.develop.tone.contrastPivot = hi }
        out("S8_authority_pivot_\(Int(lo))_\(Int(hi))", peak(a, b), "(contrast 50; floor 20)")
    }
}

// ---- S9 pivot: no dead travel inside the drag range --------------------------------
do {
    var minMove = 1e9, at = ""
    for w in [0.0, 100] { for b in [-100.0, 0, 100] {
        var pv = -3.0
        while pv < 3.0 - 1e-9 {
            let a = ToneEngine(tone: Tone(contrast: 50, contrastPivot: pv, whites: w, blacks: b))
            let c = ToneEngine(tone: Tone(contrast: 50, contrastPivot: pv + 0.25, whites: w, blacks: b))
            var m = 0.0, t = -9.0
            while t < 5 { m = max(m, abs(a.contrastMapped(t) - c.contrastMapped(t))); t += 0.01 }
            if m < minMove { minMove = m; at = "pivot \(pv)->\(pv + 0.25) whites \(w) blacks \(b)" }
            pv += 0.25
        }
    }}
    out("S9_min_move_per_quarter_EV_pivot_in_pm3", minMove, "EV; at " + at)
    // typed-only travel above a lowered white anchor (accepted): pivot 3.5 vs 4 at Whites +100
    let a = ToneEngine(tone: Tone(contrast: 50, contrastPivot: 3.5, whites: 100))
    let c = ToneEngine(tone: Tone(contrast: 50, contrastPivot: 4.0, whites: 100))
    var m = 0.0, t = -9.0
    while t < 5 { m = max(m, abs(a.contrastMapped(t) - c.contrastMapped(t))); t += 0.01 }
    out("S9_info_pivot3.5_vs_4_at_whites100", m, "EV (dead, typed-only range, accepted)")
}
