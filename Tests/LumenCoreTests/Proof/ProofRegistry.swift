// ProofRegistry.swift
//
// One entry per control, declaring what it is, where it lives, what frame it acts on,
// and which reader on the shipping path proves it is not inert (docs/20 P1).
//
// The registry is deliberately data rather than a pile of hand-written tests. A test per
// control is how you end up with 86 controls and two of them dead behind a green suite:
// each test asserts whatever its author happened to think of, nobody can see the gaps,
// and a control added later gets no test at all because nothing says it should have one.
// A registry inverts that — a control absent from this file is a visible omission, and
// every control present gets the same six questions asked of it.
//
// WHAT THESE RECORDS MEASURE, said plainly. The sweeps run through `ReferenceRenderer`,
// which renders no user pixels. That is not a mistake and it is not sufficient on its
// own: the reference is the mathematics, and P5 — the GPU-versus-reference golden on the
// macOS lane — is the separate proof that the shipping path still tracks it. A control
// with a good record here and no P5 is proven correct in theory and unproven in the
// photograph, which is exactly the split docs/21 found running through this whole
// codebase.
//
// THERE IS NO `shippingReader` FIELD ANY MORE, and the note has to say why (docs/31
// round two; docs/32 Stream H item 3). The field claimed to tie each proof to the line
// on the shipping path that reads the control — and no assertion ever read it, while 58
// of its 59 entries pointed at a comment, a brace or a blank line. It could not have
// been made real: most controls reach the GPU as BAKED artifacts (plan tables, the
// finish cube), so there is no single reading line to name. The guards that actually
// hold the shipping path are gpu-parity and the kernel goldens, per stage; an inert
// field wearing a guard's clothes is worse than no field, because it is cited instead
// of them.

import Foundation
import LumenCore

struct ControlSpec {
    let id: String
    let panel: String
    let displayName: String
    let low: Double
    let high: Double
    /// Where the control sits when it is doing nothing.
    let neutral: Double
    /// Name of the `ProofFrames` frame this control acts on, and how to build it.
    let frameName: String
    let frame: () -> ImageBuffer
    /// Write a setting into a recipe.
    let apply: (inout Recipe, Double) -> Void
    /// A floor under P3 authority, in sRGB code values. Below this the control is not
    /// visible on an 8-bit display and is therefore not a control.
    let authorityFloor: Double
    /// Whether the control may legitimately push pixels outside the input's own range.
    /// A global exposure move may; a local-contrast operator may not, and for those the
    /// overshoot is the halo measurement.
    let mayLeaveRange: Bool
    /// A bar under the overshoot, in code values, where one has been AGREED.
    ///
    /// Nil means measure and record without asserting, and that is not a loophole — it
    /// is the difference between a number nobody has argued about yet and a promise.
    /// Texture and Clarity rim the shipping path by known amounts (DETAIL-01, DETAIL-11)
    /// and that work is deliberately parked until there is a GPU to verify a fix on;
    /// asserting a ceiling there would paint a red test over a decision already taken,
    /// while recording the number keeps it visible and makes the day it improves a
    /// diff rather than a rediscovery.
    let overshootCeiling: Double?

    /// A control whose travel closes on itself — a grading wheel's Hue, where 0° and
    /// 360° are the same setting.
    ///
    /// docs/20 P4 exempts these from end-to-end authority and requires a different
    /// metric, for a reason this repository paid for: "a grading wheel's hue was
    /// reported dead for months because 0° and 360° are the same setting". Measuring
    /// `render(360) − render(0)` on a circle does not measure a weak control, it
    /// measures a tautology, and it returns zero however strong the control is.
    ///
    /// The sweep still runs the WHOLE circle, because that is the only way a dead arc
    /// somewhere in the middle shows up. What changes is where authority is read: at
    /// the ANTIPODE, the setting half a turn away, which is the largest separation a
    /// circular control can produce and the only pair of settings on a circle that is
    /// canonically "the two ends". `frontLoading` records 0 for these and means
    /// nothing — half a circle is not "the first half of the travel" — and `isMonotone`
    /// records false by construction, since the cumulative response rises to the
    /// antipode and falls back to zero. Neither is a defect and neither is asserted.
    let isCircular: Bool

    /// The ISO whose noise profile every threshold in the denoise stage is denominated
    /// in. Nil is the renderer's own default (base ISO).
    ///
    /// Not cosmetic: `RenderPlan` builds `ClassicalDenoise` from
    /// `NoiseProfile.forISO(captureISO ?? 100)`, so sweeping a denoise slider against
    /// `noisyISO6400` without this measures an ISO 100 threshold set against ISO 6400
    /// noise — a probe scoring a denoiser against noise it was never told about, which
    /// `ProofFrames.noisyChromaEdge` already says proves nothing about the slider.
    let captureISO: Double?

    /// Whether the classical denoise stage runs on the frame before the render.
    ///
    /// `ReferenceRenderer.render` starts at S6 and S3 is not inside it; on the shipping
    /// reference path `PipelineRenderer` applies `plan.classicalDenoise` to the decoded
    /// buffer first (PipelineRenderer.swift:1468), and the GPU graph does the same at
    /// the head of its chain. A denoise control swept without this renders through a
    /// stage that never ran and measures dead — an INVALID PROBE with the frame in the
    /// right place and the pipeline in the wrong one.
    let denoisedFirst: Bool

    /// Steps of the sweep that render identically to the step before them, where the
    /// control has a plateau it DECLARES.
    ///
    /// docs/20 P2 is precise about this and the precision is the point: "every step
    /// changes the render. No dead zone, no plateau the control does not declare." An
    /// undeclared plateau is a defect; a declared one is a fact about the control that
    /// the record has to carry, or the harness has only two answers — silence and red —
    /// for a measurement that has three.
    ///
    /// It is asserted as an EQUALITY, not a ceiling. A plateau that grows is a
    /// regression and a plateau that disappears is a fix, and both have to be argued for
    /// in a commit message rather than absorbed by a bound with slack in it — the same
    /// discipline the committed records already impose on every other number.
    let declaredPlateauSteps: Int
    /// Code values this control legitimately hands back over its travel, where it moves
    /// a BOUNDARY rather than a magnitude.
    ///
    /// A pivot, a blending window's edge and a grain cell's size all relocate where an
    /// effect acts rather than scaling how much it acts, so the rendered picture can come
    /// back toward neutral at the far end with nothing wrong. Exempting those would be
    /// the easy answer and would throw the number away; DECLARING it pins the number, so
    /// a reversal that grows is a regression somebody has to own — the same reasoning
    /// `declaredPlateauSteps` is asserted as an equality for.
    ///
    /// Nil means the ordinary ceiling applies: a slider whose top half undoes part of its
    /// bottom half is doing two things and the photographer can only see one.
    let declaredReversal: Double?

    init(id: String, panel: String, displayName: String,
         low: Double, high: Double, neutral: Double = 0,
         frameName: String, frame: @escaping () -> ImageBuffer,
         authorityFloor: Double,
         mayLeaveRange: Bool = true, overshootCeiling: Double? = nil,
         isCircular: Bool = false, captureISO: Double? = nil,
         denoisedFirst: Bool = false, declaredPlateauSteps: Int = 0,
         declaredReversal: Double? = nil,
         apply: @escaping (inout Recipe, Double) -> Void)
    {
        self.declaredPlateauSteps = declaredPlateauSteps
        self.declaredReversal = declaredReversal
        self.overshootCeiling = overshootCeiling
        self.id = id; self.panel = panel; self.displayName = displayName
        self.low = low; self.high = high; self.neutral = neutral
        self.frameName = frameName; self.frame = frame
        self.authorityFloor = authorityFloor
        self.mayLeaveRange = mayLeaveRange
        self.isCircular = isCircular
        self.captureISO = captureISO
        self.denoisedFirst = denoisedFirst
        self.apply = apply
    }

    /// The setting authority is read against. The far end of the travel, except on a
    /// circle, where the far end is the setting you started from.
    var authorityEnd: Double { isCircular ? (low + high) / 2 : high }
}

enum ProofRegistry {

    // NOTE ON THE FLOORS ADDED WITH THE DAILY-EDIT CONTROLS.
    //
    // The eleven original entries carry floors derived from docs/19's measured numbers.
    // The curve, presence, sharpen and mixer entries do not yet: their floors are
    // conservative estimates, written before the sweep that measures them, and they are
    // deliberately LOW. A floor that is too low fails to catch a control going weak; a
    // floor that is too high turns the suite red on an estimate rather than on a defect,
    // which teaches everyone to ignore it. Between those two failures the first is
    // recoverable by tightening a number and the second costs the assertion its meaning.
    //
    // They get tightened to just under the measured authority once the sweep records
    // them, in a commit that says what each number became and why.

    /// The six tone sliders plus the contrast pivot.
    ///
    /// The authority floors come from docs/19's second measurement — the one taken after
    /// the zonal windows were rebuilt as shelves — rounded DOWN to leave room for
    /// ordinary retuning without inviting a silent collapse. docs/19 measured
    /// Exposure 169.5, Contrast 81.6, Highlights 55.8, Shadows 46.8, Whites 47.6,
    /// Blacks 23.1; the floors below sit a comfortable margin under each.
    ///
    /// Blacks is the one worth explaining. It measured 2.9 of 255 levels before the fix
    /// — below the visible threshold on an 8-bit display, a control the photographer
    /// could not see — and every structural test in the suite passed throughout. A floor
    /// of 15 says "this must stay a control", which is the assertion that was missing.
    static let tone: [ControlSpec] = [
        ControlSpec(
            // The PANEL's range, not a subset of it. This swept ±2 while the row
            // ships ±5 (hard ±10), so the record covered 40% of the drag — and it was
            // the only tone control not swept over its own panel range, which reads as
            // an oversight rather than a decision. Every number in this record moved
            // when it was widened; the control did not.
            id: "tone.exposure", panel: "Basic", displayName: "Exposure",
            low: -5, high: 5,
            frameName: "neutralRamp", frame: { ProofFrames.neutralRamp() },
            authorityFloor: 120,
            apply: { r, v in r.develop.tone.exposure = v }),
        ControlSpec(
            id: "tone.contrast", panel: "Basic", displayName: "Contrast",
            low: -100, high: 100,
            frameName: "neutralRamp", frame: { ProofFrames.neutralRamp() },
            authorityFloor: 55,
            apply: { r, v in r.develop.tone.contrast = v }),
        ControlSpec(
            id: "tone.highlights", panel: "Basic", displayName: "Highlights",
            low: -100, high: 100,
            frameName: "neutralRamp", frame: { ProofFrames.neutralRamp() },
            authorityFloor: 35,
            apply: { r, v in r.develop.tone.highlights = v }),
        ControlSpec(
            id: "tone.shadows", panel: "Basic", displayName: "Shadows",
            low: -100, high: 100,
            frameName: "neutralRamp", frame: { ProofFrames.neutralRamp() },
            authorityFloor: 30,
            apply: { r, v in r.develop.tone.shadows = v }),
        ControlSpec(
            id: "tone.whites", panel: "Basic", displayName: "Whites",
            low: -100, high: 100,
            frameName: "neutralRamp", frame: { ProofFrames.neutralRamp() },
            authorityFloor: 30,
            apply: { r, v in r.develop.tone.whites = v }),
        ControlSpec(
            id: "tone.blacks", panel: "Basic", displayName: "Blacks",
            low: -100, high: 100,
            frameName: "neutralRamp", frame: { ProofFrames.neutralRamp() },
            authorityFloor: 15,
            apply: { r, v in r.develop.tone.blacks = v }),
        // The pivot is denominated in EV, not in slider units: the panel offers -4…4
        // (BasicPanel.swift:229) and the engine clamps to the same (ToneEngine.swift:347).
        //
        // The first version of this entry swept -100…100 and the harness reported 18 of
        // 20 steps dead. That was the PROBE, not the control — the same mistake docs/19
        // recorded three times, most memorably driving a plus-or-minus-60-degree Point
        // Colour Hue slider to 100 and calling the clamp a dead zone. A control that
        // saturates outside its own range is not a dead control, and the registry is
        // where that fact has to be got right.
        ControlSpec(
            id: "tone.contrastPivot", panel: "Basic", displayName: "Contrast pivot",
            low: -4, high: 4,
            frameName: "neutralRamp", frame: { ProofFrames.neutralRamp() },
            authorityFloor: 20,
            apply: { r, v in
                // A pivot does nothing without contrast to pivot. Measuring it at
                // contrast 0 would report a dead control and be the probe's fault —
                // the same mistake docs/19 recorded three times.
                r.develop.tone.contrast = 50
                r.develop.tone.contrastPivot = v
            }),
    ]

    /// Global colour controls that act on a chart rather than a ramp.
    static let colour: [ControlSpec] = [
        ControlSpec(
            id: "color.saturation", panel: "Colour", displayName: "Saturation",
            low: -100, high: 100,
            frameName: "colourChart", frame: { ProofFrames.colourChart() },
            authorityFloor: 40,
            apply: { r, v in r.develop.color.saturation = v }),
        ControlSpec(
            id: "color.vibrance", panel: "Colour", displayName: "Vibrance",
            low: -100, high: 100,
            frameName: "colourChart", frame: { ProofFrames.colourChart() },
            authorityFloor: 20,
            apply: { r, v in r.develop.color.vibrance = v }),
        // The slider the owner's first session reported as immovable. It is gated —
        // `ColorAdjust.densityIsLive` is false at Saturation ≤ 0, the panel disables
        // the row — and it had NO record, so nothing measured what it does where it is
        // live. The companion puts it where it is live, same reasoning as the contrast
        // pivot's companion: measuring it at saturation 0 would report a dead control
        // and be the probe's fault.
        ControlSpec(
            id: "color.density", panel: "Colour", displayName: "Density",
            low: 0, high: 100, neutral: 50,
            frameName: "colourChart", frame: { ProofFrames.colourChart() },
            authorityFloor: 24,
            apply: { r, v in
                r.develop.color.saturation = 60
                r.develop.color.density = v
            }),
        // Attenuates Vibrance (both signs) and Saturation's push inside the skin band;
        // the companion gives it a push to attenuate. The chart's orange patches are
        // the skin territory it acts on.
        ControlSpec(
            id: "color.protectSkin", panel: "Colour", displayName: "Protect Skin",
            low: 0, high: 100, neutral: 70,
            frameName: "colourChart", frame: { ProofFrames.colourChart() },
            authorityFloor: 9,
            apply: { r, v in
                r.develop.color.vibrance = 80
                r.develop.color.protectSkin = v
            }),
        ControlSpec(
            // Swept over the PHOTOGRAPHIC range, not the control's full 2000…50000 K.
            // Sweeping the declared range would report a control delivering ~97% of its
            // effect in the first fifteenth of its travel — which is true, and was
            // TONE-09 (the slider is linear in Kelvin where it should be reciprocal),
            // a defect in the SLIDER's scale rather than in what the engine does. Two
            // separate facts deserve two separate measurements; this one is the engine's.
            //
            // TONE-09 is now fixed: the panel passes `SliderScale.reciprocal`, and
            // `SliderScaleTests` measures the other fact — that the track's travel is
            // spent where the change is. This spec is deliberately unchanged, because
            // widening it would fold the two measurements back into one number.
            id: "raw.temp", panel: "Basic", displayName: "Temperature",
            low: 3000, high: 9000, neutral: 5500,
            frameName: "colourChart", frame: { ProofFrames.colourChart() },
            authorityFloor: 60,
            apply: { r, v in r.develop.raw.temp = v }),
        ControlSpec(
            // ±150 is the panel's soft range; this swept ±100, so a third of the row
            // went unmeasured. That third is now where the interesting behaviour is:
            // `ColorTemperature.tintLimit` bounds the magenta half, and at the 5500 K
            // neutral `RenderPlan` adapts from, the bound is +156 — so the whole of
            // ±150 is admissible here and this measures real travel throughout rather
            // than running into a clamp.
            id: "raw.tint", panel: "Basic", displayName: "Tint",
            low: -150, high: 150,
            frameName: "colourChart", frame: { ProofFrames.colourChart() },
            authorityFloor: 25,
            apply: { r, v in r.develop.raw.tint = v }),
    ]


    /// The parametric curve's four regions.
    ///
    /// Swept on the ramp, because a curve is a statement about tone and nothing else.
    /// `testParametricSlidersStayAliveOverTheirWholeTravel` already asserts each region
    /// is alive and linear in its setting on the BAKED TABLE; these records measure what
    /// the same settings do to a rendered picture, which is the question the table
    /// cannot answer.
    static let curve: [ControlSpec] = {
        let regions: [(String, String, WritableKeyPath<ParametricCurve, Double>)] = [
            ("shadows", "Shadows", \.shadows),
            ("darks", "Darks", \.darks),
            ("lights", "Lights", \.lights),
            ("highlights", "Highlights", \.highlights),
        ]
        return regions.map { id, name, path in
            ControlSpec(
                id: "curve.\(id)", panel: "Curve", displayName: name,
                low: -100, high: 100,
                frameName: "neutralRamp", frame: { ProofFrames.neutralRamp() },
                // 70% of the weakest region measured (highlights, 50.70). One floor for
                // four controls, set by the weakest, because a loop cannot carry four.
                authorityFloor: 35,
                apply: { r, v in r.develop.curve.parametric[keyPath: path] = v })
        }
    }()

    /// Presence. Each one swept on a frame that contains what it acts on — the lesson
    /// docs/19 recorded three times, and the reason `dehaze` is not measured on texture.
    ///
    /// `overshootCeiling` is nil for all three ON PURPOSE. They rim the shipping path by
    /// known amounts and that work is parked until there is a GPU to verify a fix on
    /// (DETAIL-01, DETAIL-11). The rim is measured into every record so the day it
    /// improves is a diff; asserting a bar would only paint a red test over a decision
    /// already taken.
    static let presence: [ControlSpec] = [
        ControlSpec(
            id: "detail.texture", panel: "Presence", displayName: "Texture",
            low: -100, high: 100,
            frameName: "fineTexture", frame: { ProofFrames.fineTexture() },
            authorityFloor: 27, mayLeaveRange: false,
            apply: { r, v in r.develop.detail.texture = v }),
        ControlSpec(
            id: "detail.clarity", panel: "Presence", displayName: "Clarity",
            low: -100, high: 100,
            frameName: "fineTexture", frame: { ProofFrames.fineTexture() },
            authorityFloor: 13, mayLeaveRange: false,
            apply: { r, v in r.develop.detail.clarity = v }),
        ControlSpec(
            id: "detail.dehaze", panel: "Presence", displayName: "Dehaze",
            low: -100, high: 100,
            frameName: "hazySky", frame: { ProofFrames.hazySky() },
            authorityFloor: 68, mayLeaveRange: false,
            apply: { r, v in r.develop.detail.dehaze = v }),
    ]

    /// Creative sharpening, on a hard edge — which is both what it acts on and where its
    /// artifact lives. docs/19 found Radius was a seven-position switch across its whole
    /// range and Detail ran backwards; these records are what would have caught both.
    ///
    /// ON 2048 px FRAMES, and that migration is half of E2-04's landing rather than a
    /// tidy-up. S12's radius is denominated in the frame — `radius × longEdge / 2560`,
    /// `SpatialOps.frameDenominatedSigma` — so at the 128 px `stepEdge` these five used,
    /// Radius's whole 0.5…3.0 travel scaled to σ = 0.025…0.15 and `SpatialOps.gaussianBlur`
    /// returned the plane untouched under its own `sigma > 0.05` floor. Every render in
    /// the Radius and Halo Suppression sweeps came back byte-identical: authority
    /// 0.0000 with 20 dead steps, on two controls that work. The 256 px `fineTexture`
    /// the other two used is the same story one octave up.
    ///
    /// This is the frame mistake docs/20 names, arriving through SIZE rather than
    /// content — the same one `ProofFrames`' film-gate paragraph records for halation at
    /// σ = 0.23 px and for a grain cell under the half-pixel floor, and the same one the
    /// masking entry below records for a control swept on a frame with nothing to
    /// withhold. `wideStepEdge` and `wideFineTexture` are the same two frames at 2048 px:
    /// same step, same four frequencies, one axis changed. `SharpeningFrameTests` asserts
    /// the arithmetic against these specs so a frame cannot quietly shrink back.
    ///
    /// THE RECORDS MOVE WITH THEM, AND NOT ONLY BECAUSE OF THEM. This paragraph used to
    /// say the movement "is the frame and not a behaviour change: a number taken here is
    /// a number taken on more pixels of the same picture". That is wrong, and it is worth
    /// leaving the correction rather than the sentence, because the two halves of E2-04
    /// landed thirty-three minutes apart and whoever wrote it had only seen one.
    ///
    /// `8880982` wired `SpatialOps.frameDenominatedSigma` into `DetailEngine.applySharpen`
    /// and `RenderGraph.applySharpen` — the unsharp radius stopped being a pixel count
    /// and became `radius x longEdge / 2560`. `c11772d`, later the same night, swapped
    /// these five specs onto the wide frames. The sweep renders through
    /// `ReferenceRenderer`, which calls `DetailEngine.applySharpen`, so BOTH changes are
    /// on the path these records measure, and the sigma change is the identity only at
    /// 2560 px. None of the four frames is 2560.
    ///
    /// The second change is also WHY the first was necessary. On the old 128 px
    /// `stepEdge` the new sigma is 0.025...0.15 px, under `gaussianBlur`'s 0.05 support
    /// floor, so the stage falls silent: measured there, `radius` and `haloSuppression`
    /// came back at 0.0000 authority with 20 dead steps, `amount` at 16.19 against a
    /// floor of 29, `masking` at 4.04 against 10. Frame held constant, engine changed —
    /// which is the demonstration that the behaviour moved, not merely the measurement.
    /// Only `detail` passed there, and it passed by reading HIGHER than it should: a dead
    /// unsharp term made its cross-fade look authoritative.
    ///
    /// So a re-pin here has to say both halves. Saying only "the frame changed" would
    /// describe a measurement that got wider and hide a control that got fixed.
    static let sharpen: [ControlSpec] = [
        ControlSpec(
            id: "sharpen.amount", panel: "Detail", displayName: "Sharpen amount",
            low: 0, high: 150,
            frameName: "wideStepEdge", frame: { ProofFrames.wideStepEdge() },
            authorityFloor: 29, mayLeaveRange: false,
            apply: { r, v in r.develop.detail.sharpen.amount = v }),
        ControlSpec(
            id: "sharpen.radius", panel: "Detail", displayName: "Sharpen radius",
            low: 0.5, high: 3.0, neutral: 1.0,
            frameName: "wideStepEdge", frame: { ProofFrames.wideStepEdge() },
            authorityFloor: 17, mayLeaveRange: false,
            apply: { r, v in
                // Radius does nothing without amount to apply at that radius.
                r.develop.detail.sharpen.amount = 100
                r.develop.detail.sharpen.radius = v
            }),
        ControlSpec(
            id: "sharpen.detail", panel: "Detail", displayName: "Sharpen detail",
            low: 0, high: 100,
            frameName: "wideFineTexture", frame: { ProofFrames.wideFineTexture() },
            authorityFloor: 3, mayLeaveRange: false,
            apply: { r, v in
                r.develop.detail.sharpen.amount = 100
                r.develop.detail.sharpen.detail = v
            }),
        // Masking is swept on TEXTURE, not on the step edge, and the first version of
        // this entry got it wrong. Masking's whole job is to withhold sharpening from
        // flat areas — so on a frame that is flat plus one hard edge there is nothing
        // for it to withhold, both ends of its travel sharpen the same single edge, and
        // it measured 2.65 code values: indistinguishable from the dead-control reading
        // docs/19 recorded for Blacks. On a frame carrying detail at several spatial
        // frequencies the gate has something to act on and the number means something.
        //
        // Third time this exact mistake has been caught in this repository, twice by
        // this harness against its own author. A control swept on a frame that does not
        // contain its subject is an INVALID PROBE, not a result (docs/20).
        ControlSpec(
            id: "sharpen.masking", panel: "Detail", displayName: "Sharpen masking",
            low: 0, high: 100,
            frameName: "wideFineTexture", frame: { ProofFrames.wideFineTexture() },
            authorityFloor: 10, mayLeaveRange: false,
            apply: { r, v in
                r.develop.detail.sharpen.amount = 100
                r.develop.detail.sharpen.masking = v
            }),
        // Suppression measures on the same hard edge Amount rims, with Amount pushed
        // so there is a halo to suppress — its whole visible effect is taking the
        // overshoot back down, which is small by nature and still a control.
        ControlSpec(
            id: "sharpen.haloSuppression", panel: "Detail",
            displayName: "Halo suppression",
            low: 0, high: 100,
            frameName: "wideStepEdge", frame: { ProofFrames.wideStepEdge() },
            authorityFloor: 25, mayLeaveRange: false,
            apply: { r, v in
                r.develop.detail.sharpen.amount = 120
                r.develop.detail.sharpen.haloSuppression = v
            }),
    ]

    /// The colour mixer: eight bands, three controls each, on the chart.
    ///
    /// Twenty-four entries rather than a sampled few, because "HSL" is one line on
    /// docs/19's list of what a photographer touches on an ordinary edit, and a band
    /// that has gone dead is invisible in any sample that does not include it. That is
    /// the whole argument for a registry over a test per control.
    static let mixer: [ControlSpec] = {
        let bands = ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"]
        let axes: [(String, WritableKeyPath<MixerBand, Double>, Double)] = [
            // 70% of the weakest band on each axis, re-measured on the corrected
            // inset (the reversed matrix had been INFLATING saturated-band numbers):
            // blue hue 24.50, green sat 51.39, green lum 101.96. Blue hue fell from
            // aqua's old 46.05 and was the one existing control the re-measurement
            // put under its own floor. Per-axis rather than per-band, because what
            // this catches is a band falling to the level of the current weakest.
            ("hue", \.hue, 17), ("sat", \.sat, 35), ("lum", \.lum, 71),
        ]
        var out = [ControlSpec]()
        for (index, band) in bands.enumerated() {
            for (axis, path, floor) in axes {
                out.append(ControlSpec(
                    id: "mixer.\(band).\(axis)", panel: "Colour Mixer",
                    displayName: "\(band.capitalized) \(axis)",
                    low: -100, high: 100,
                    frameName: "colourChart", frame: { ProofFrames.colourChart() },
                    authorityFloor: floor,
                    apply: { r, v in r.develop.mixer.bands[index][keyPath: path] = v }))
            }
        }
        // Uniformity (D13, hue convergence): pulls every hue toward its band centre.
        // The panel's twenty-fifth mixer slider, found recordless by the coverage
        // audit (docs/27). No companion — convergence acts on the chart's own spread.
        out.append(ControlSpec(
            id: "mixer.uniformity", panel: "Colour Mixer", displayName: "Uniformity",
            low: 0, high: 100,
            frameName: "colourChart", frame: { ProofFrames.colourChart() },
            authorityFloor: 7,
            apply: { r, v in r.develop.mixer.uniformity = v }))
        return out
    }()

    // MARK: - Look: where the Develop panel ends and the Look panel begins

    /// The three-way grading wheels, on the tonal colour wedge.
    ///
    /// **The frame is the whole argument, so it is made once, here.** A wheel is a tint
    /// weighted by a ZONE WINDOW, and the windows are denominated on the normalized
    /// tonal axis between `ToneEngine`'s anchors — −9…+5 EV by default, with the shadow
    /// zone below about −4.4 and the highlight zone above about +0.4. `colourChart`
    /// spans roughly −2.5…+2.2 EV, so on the chart the shadows and highlights wheels
    /// would be measured through windows nearly shut over every pixel in the frame.
    /// `RobustnessTests.testAGradingWheelsHueIsContinuousAndClosed` records making
    /// exactly that mistake and fixing it: "the shadows wheel had almost nothing to act
    /// on and a 180° rotation moved the probes by 0.007, so the test failed for want of
    /// a shadow rather than for want of a working control."
    /// `ProofFrames.tonalColourWedge` is the chart's chroma over the ramp's tonal span,
    /// which is what all of these need.
    ///
    /// Hue is CIRCULAR and says so. Sweeping 0…360 and reading the ends is how a hue
    /// wheel gets reported dead for months — see `ControlSpec.isCircular`.
    static let grade: [ControlSpec] = {
        let zones: [(String, String, WritableKeyPath<GradingWheels, Wheel>)] = [
            ("global", "Global", \.global),
            ("shadows", "Shadows", \.shadows),
            ("mid", "Midtones", \.mid),
            ("high", "Highlights", \.high),
        ]
        // One floor per AXIS, set by the weakest of the four zones — the shadows wheel
        // on all three, which is not a weakness in the control. The shadow zone lives
        // below about −4.4 EV and an 8-bit display has about thirty code values left
        // down there to move, so a shadows wheel measures small for the same reason a
        // shadow is dark. Per-axis rather than per-zone for the reason the mixer's are:
        // what a shared floor catches is a zone falling to the level of the current
        // weakest, and four floors set from four measurements would each catch only
        // their own.
        //
        // Measured: sat 69.46 / 20.06 / 58.26 / 69.46, lum 135.93 / 55.18 / 135.10 /
        // 103.76, hue 101.04 / 20.62 / 70.24 / 100.15, global / shadows / mid / high.
        var out = [ControlSpec]()
        for (id, name, path) in zones {
            out.append(ControlSpec(
                // The wheel's radius: 0…1 in the recipe, in the engine's clamp
                // (`WheelTint.init`) and on the pad (`LumenColorWheel`).
                id: "grade.\(id).sat", panel: "Grade", displayName: "\(name) saturation",
                low: 0, high: 1,
                frameName: "tonalColourWedge", frame: { ProofFrames.tonalColourWedge() },
                authorityFloor: 11,
                // Global and Highlights hand back 3.914 of ~49.7 under the corrected
                // inset (proof #16): a saturation push at the top of its travel walks
                // colour into the gamut boundary, and softClip eases it back — the
                // slider saturating against the display's own edge, pinned so growth
                // is a regression. Shadows and mid never reach the boundary.
                declaredReversal: (id == "global" || id == "high") ? 3.915 : nil,
                apply: { r, v in r.look.wheels[keyPath: path].sat = v }))
            out.append(ControlSpec(
                // Per-wheel Luminance: −1…+1, which `GradeEngine.lumRangeStops` makes
                // ±0.5 stops of perceptual lightness.
                id: "grade.\(id).lum", panel: "Grade", displayName: "\(name) luminance",
                low: -1, high: 1,
                frameName: "tonalColourWedge", frame: { ProofFrames.tonalColourWedge() },
                authorityFloor: 37,
                apply: { r, v in r.look.wheels[keyPath: path].lum = v }))
            out.append(ControlSpec(
                id: "grade.\(id).hue", panel: "Grade", displayName: "\(name) hue",
                low: 0, high: 360,
                frameName: "tonalColourWedge", frame: { ProofFrames.tonalColourWedge() },
                authorityFloor: 11, isCircular: true,
                apply: { r, v in
                    // A hue with no saturation behind it is not a colour: `WheelTint`
                    // makes `sat == 0` a bit-exact no-op, so a hue swept at the default
                    // radius measures dead at all 21 settings and the reading is the
                    // probe's. 0.6 is the radius
                    // `testAGradingWheelsHueIsContinuousAndClosed` probes at, so the two
                    // measurements are of one control at one deflection.
                    r.look.wheels[keyPath: path].sat = 0.6
                    r.look.wheels[keyPath: path].hue = v
                }))
        }
        return out
    }()

    /// The zone GEOMETRY: how soft the crossover is, which way Balance slides it, and
    /// where the two pivots sit.
    ///
    /// All four need the same companion, and it is not optional. Geometry says WHERE the
    /// zones are, not how hard they push, and `GradingWheels.isNeutral` states the
    /// consequence in as many words — "a grade with moved pivots and untouched wheels is
    /// still the identity and must not cost a table". With no wheels set `RenderPlan`
    /// swaps the whole stage out and all four measure dead on controls that work. The
    /// companion is two OPPOSED tints, shadows against highlights, because a boundary
    /// between two zones graded identically is not visible either.
    static let gradeGeometry: [ControlSpec] = {
        func opposedTints(_ r: inout Recipe) {
            r.look.wheels.shadows = Wheel(hue: 30, sat: 0.8, lum: 0)
            r.look.wheels.high = Wheel(hue: 210, sat: 0.8, lum: 0)
        }
        return [
            ControlSpec(
                id: "grade.blending", panel: "Grade", displayName: "Zone blending",
                low: 0, high: 100, neutral: 50,
                frameName: "tonalColourWedge", frame: { ProofFrames.tonalColourWedge() },
                authorityFloor: 26,
                // Blending widens the crossfade between zones, and past the point where
                // the mid zone's weight would go negative the request is eased onto a
                // ceiling — so the far end of the travel returns toward the shape the
                // near end already reached. Measured, pinned, not exempted.
                declaredReversal: 13.783,
                apply: { r, v in opposedTints(&r); r.look.wheels.blending = v }),
            ControlSpec(
                id: "grade.balance", panel: "Grade", displayName: "Zone balance",
                low: -100, high: 100,
                frameName: "tonalColourWedge", frame: { ProofFrames.tonalColourWedge() },
                authorityFloor: 44,
                apply: { r, v in opposedTints(&r); r.look.wheels.balance = v }),
            // The two pivots, on the normalized tonal axis, over the travel the PANEL
            // allows: `LookPanel.movePivot` clamps each handle against its neighbour by
            // `ZoneWindows.minimumPivotGap` (0.02), so with the other pivot at its
            // default the shadow handle travels 0…0.65 and the highlight handle 0.35…1.
            // Sweeping either 0…1 would drive it through the other and measure the
            // collision — the Point-Colour-Hue-at-±100 mistake in a different panel.
            ControlSpec(
                id: "grade.pivot.shadow", panel: "Grade", displayName: "Shadow pivot",
                low: 0, high: 0.65, neutral: 0.33,
                frameName: "tonalColourWedge", frame: { ProofFrames.tonalColourWedge() },
                // Re-anchored from 57 at proof #16: the corrected inset moved the
                // wedge's rendered colours, and the shadow pivot's visible share of
                // its boundary walk fell to 48.95. 70% of what is.
                authorityFloor: 34,
                apply: { r, v in
                    opposedTints(&r)
                    r.look.wheels.pivots = [v, GradingWheels.defaultPivots[1]]
                }),
            ControlSpec(
                id: "grade.pivot.highlight", panel: "Grade",
                displayName: "Highlight pivot",
                low: 0.35, high: 1, neutral: 0.67,
                frameName: "tonalColourWedge", frame: { ProofFrames.tonalColourWedge() },
                authorityFloor: 52,
                apply: { r, v in
                    opposedTints(&r)
                    r.look.wheels.pivots = [GradingWheels.defaultPivots[0], v]
                }),
        ]
    }()

    /// Printer lights, on the ramp.
    ///
    /// The ramp rather than a colour frame, deliberately: a printer light is an exposure
    /// trim in log space, judged in a darkroom on a grey card, and what has to be true of
    /// the three trims is that they move a NEUTRAL off neutral by a stated number of
    /// twelfths of a stop. A chart would answer a different question less clearly. The
    /// ramp also makes Master's number directly comparable with Exposure's, which is
    /// what Master is.
    ///
    /// The ranges are the wire limits `GradeEngine` clamps to and `LookPanel.applyPoints`
    /// enforces — ±48 points master (±4 stops), ±24 per channel (±2 stops), one point
    /// being one twelfth of a stop exactly. The field is an `Int`, and a 21-step sweep
    /// of either range lands on 21 distinct integers rather than resolving into a
    /// staircase with dead treads.
    static let printerLights: [ControlSpec] = {
        let trims: [(String, String, WritableKeyPath<PrinterLights, Int>)] = [
            ("r", "Red / Cyan", \.r), ("g", "Green / Magenta", \.g),
            ("b", "Blue / Yellow", \.b),
        ]
        var out: [ControlSpec] = [
            ControlSpec(
                id: "printer.master", panel: "Printer Lights", displayName: "Master",
                low: -GradeEngine.masterPointLimit, high: GradeEngine.masterPointLimit,
                frameName: "neutralRamp", frame: { ProofFrames.neutralRamp() },
                authorityFloor: 168,
                apply: { r, v in r.look.printerLights.master = Int(v.rounded()) }),
        ]
        for (id, name, path) in trims {
            out.append(ControlSpec(
                id: "printer.\(id)", panel: "Printer Lights", displayName: name,
                low: -GradeEngine.trimPointLimit, high: GradeEngine.trimPointLimit,
                frameName: "neutralRamp", frame: { ProofFrames.neutralRamp() },
                // One floor for the three trims, set by the weakest — green at 152.63,
                // against red 163.16 and blue 153.22. They measure within 7% of each
                // other, which is what four stops of channel gain on a grey ramp ought
                // to look like.
                authorityFloor: 106,
                apply: { r, v in r.look.printerLights[keyPath: path] = Int(v.rounded()) }))
        }
        return out
    }()

    /// Primaries: three hues, three purities, and the shadow tint's two axes.
    ///
    /// On the wedge, and the tint is the reason. The remap is a matrix and would read on
    /// any saturated frame, but Shadows Tint rides a window PINNED at −3 EV with a 1.5 EV
    /// half-width (`ColorEngine.tintPivotEV`, `tintHalfWidthEV`) — deliberately not the
    /// user's grading pivot. `colourChart`'s darkest patch sits about −2.5 EV from
    /// mid-grey, at the very foot of that window, so the chart would measure the tint
    /// through a gate that is nearly closed and report a weak control that is not weak.
    /// One frame for all eight keeps the six remap numbers comparable with the two tint
    /// numbers, which is the comparison a Primaries panel is read as.
    ///
    /// All eight are ±100 in the panel and in `primariesMatrix`'s own clamp. At full
    /// deflection a hue is a 20° rotation of a primary's chromaticity about the white
    /// point and a purity is a 50% rescale of its distance from it.
    /// Two floors, not one and not eight. The six remap axes share the weakest of their
    /// own — green purity at 63.35 — and the two tint axes share theirs, tint hue at
    /// 23.39, because the tint acts through a window pinned to the shadows and is a
    /// different control wearing the same panel. One floor across all eight would be the
    /// tint's, and the remap's six could each lose two thirds of their authority without
    /// anything going red.
    ///
    /// Measured: rHue 102.24, rPurity 77.96, gHue 90.24, gPurity 63.35, bHue 130.69,
    /// bPurity 114.68, tintHue 23.39, tintPurity 42.17.
    ///
    /// **`rPurity` declares a plateau, and the reason is worth reading before anyone
    /// tries to widen it.** Rec.2020's red primary sits at x + y = 1.000, exactly on the
    /// line `safeChromaticity` refuses to cross, so pushing red further from the white
    /// point has nowhere to go: the bisection shrinks the offset back to nothing and the
    /// positive half of that slider is a clamp. It delivers 100% of its travel by about
    /// +10 and renders one step byte-identical to the one before it. Green has some
    /// headroom (x + y = 0.967) and blue runs into `y > 0.002` instead; both saturate
    /// too, at 96% and 92% front-loading, without quite producing an identical pair.
    /// Recorded rather than fixed — see PROOF-03 in docs/audit/found-while-fixing.md.
    static let primaries: [ControlSpec] = {
        let axes: [(String, String, WritableKeyPath<Primaries, Double>, Double, Int)] = [
            ("rHue", "Red hue", \.rHue, 44, 0),
            ("rPurity", "Red purity", \.rPurity, 44, 1),
            ("gHue", "Green hue", \.gHue, 44, 0),
            ("gPurity", "Green purity", \.gPurity, 44, 0),
            ("bHue", "Blue hue", \.bHue, 44, 0),
            ("bPurity", "Blue purity", \.bPurity, 44, 0),
            ("tintHue", "Shadow tint hue", \.tintHue, 16, 0),
            ("tintPurity", "Shadow tint purity", \.tintPurity, 16, 0),
        ]
        return axes.map { id, name, path, floor, plateau in
            ControlSpec(
                id: "primaries.\(id)", panel: "Primaries", displayName: name,
                low: -100, high: 100,
                frameName: "tonalColourWedge", frame: { ProofFrames.tonalColourWedge() },
                authorityFloor: floor, declaredPlateauSteps: plateau,
                // Blue hue hands back 11.961 of ~108 since the inset fix (proof #16):
                // rotating the blue primary walks the wedge's blues through the
                // gamut-clip region PROOF-03 documents for this panel, and the far
                // end of the travel eases part of the picture back toward where the
                // near end had it. Pinned, not exempted — the other axes stay under
                // the ordinary 5% ceiling.
                declaredReversal: id == "bHue" ? 11.962 : nil,
                // No companion. The two tint axes are the two perpendicular components
                // of ONE offset, not a magnitude and a direction, so either alone is a
                // real move — which is why neither is written as the other's companion.
                apply: { r, v in r.look.primaries[keyPath: path] = v })
        }
    }()

    /// Point Colour, on the chart.
    ///
    /// The chart rather than the wedge, and this is the one place the wedge would be the
    /// worse frame. Point Colour is a SELECTIVE tool: its whole claim is that it moves
    /// one colour and leaves its neighbours alone, and the chart's twenty-four patches
    /// put three near-misses around the swatch: it sits on moderate red at patch 15,
    /// with the softer red at 9, orange at 7 and dark skin at 1 nearby. The wedge's eight
    /// columns are 45° apart, so a swatch on one of them has nothing close enough to
    /// spare or to catch, which is exactly what selectivity is. Range and
    /// Variance are measurements OF that selectivity and would have almost nothing to
    /// read on a frame whose colours are that far apart.
    ///
    /// **The sample is the companion, and without it every one of these is dead.** A
    /// swatch selects by distance from `PointColor.sample` in OKLCh; a sample that names
    /// a colour the frame does not contain has weight zero at every pixel. So the sample
    /// is taken FROM the frame, through `ProofFrames.chartPatchColour`, and cannot drift
    /// away from it.
    ///
    /// Ranges are the panel's and the engine's, which agree: Hue ±60
    /// (`ColorEngine.pointHueShiftLimit`, and the ±60 slider docs/19 drove to ±100 before
    /// calling the clamp a dead zone), Saturation and Luminance ±100, Range 0…100 with a
    /// default of 50, Variance ±100.
    static let pointColour: [ControlSpec] = {
        /// Patch 15, moderate red — saturated enough to have an unambiguous hue, and
        /// with three near neighbours on the chart for Range to reach into. Read once:
        /// `apply` runs twenty-odd times per sweep and this builds the whole chart.
        let target = ProofFrames.chartPatchColour(15)
        func swatch(range: Double, h: Double = 0, s: Double = 0, l: Double = 0,
                    variance: Double = 0) -> PointColor {
            PointColor(sample: [target.r, target.g, target.b], range: range,
                       variance: variance, shift: HSLShift(h: h, s: s, l: l))
        }
        return [
            ControlSpec(
                id: "pointColor.hue", panel: "Point Colour", displayName: "Hue",
                low: -60, high: 60,
                frameName: "colourChart", frame: { ProofFrames.colourChart() },
                // Measured 141.57. Five hand-written entries, so five floors at 70% of
                // their own numbers rather than one at 70% of the weakest: a shared
                // floor is what a LOOP needs, and these five are five different
                // controls that happen to share a panel.
                authorityFloor: 99,
                apply: { r, v in r.develop.pointColors = [swatch(range: 50, h: v)] }),
            ControlSpec(
                id: "pointColor.saturation", panel: "Point Colour",
                displayName: "Saturation",
                low: -100, high: 100,
                frameName: "colourChart", frame: { ProofFrames.colourChart() },
                // Measured 83.39.
                authorityFloor: 58,
                apply: { r, v in r.develop.pointColors = [swatch(range: 50, s: v)] }),
            ControlSpec(
                id: "pointColor.luminance", panel: "Point Colour",
                displayName: "Luminance",
                low: -100, high: 100,
                frameName: "colourChart", frame: { ProofFrames.colourChart() },
                // Measured 158.82.
                authorityFloor: 111,
                apply: { r, v in r.develop.pointColors = [swatch(range: 50, l: v)] }),
            ControlSpec(
                // Range is how much of the picture the swatch claims, so it needs a
                // shift to claim it WITH: at every shift of zero the swatch is skipped
                // before a pixel is touched (`compiledSwatches` drops it), and Range
                // would measure dead across its whole travel on a working control.
                id: "pointColor.range", panel: "Point Colour", displayName: "Range",
                low: 0, high: 100, neutral: 50,
                frameName: "colourChart", frame: { ProofFrames.colourChart() },
                // Measured 66.10.
                authorityFloor: 46,
                apply: { r, v in r.develop.pointColors = [swatch(range: v, h: 40)] }),
            ControlSpec(
                // Variance needs a range to work inside for the same reason, and
                // nothing else: it is its own move, compressing (−) or expanding (+)
                // the deviation of what is selected from the swatch's own colour, so it
                // is measured with the three shifts at zero and only the selection set.
                id: "pointColor.variance", panel: "Point Colour", displayName: "Variance",
                low: -100, high: 100,
                frameName: "colourChart", frame: { ProofFrames.colourChart() },
                // Measured 77.10.
                authorityFloor: 53,
                apply: { r, v in
                    r.develop.pointColors = [swatch(range: 50, variance: v)]
                }),
        ]
    }()

    /// The Zones panel: five zone exposures, a global trim, and the five pivots.
    ///
    /// On the ramp, because a zone exposure is a statement about tone and the ramp spans
    /// −8…+5 EV of it. The travel is the SLIDER's −3…+3 stops rather than the ±5 hard
    /// range a drag can reach: the hard range is an overshoot for a photographer who
    /// means it, and a proof measures the control the panel offers.
    static let zones: [ControlSpec] = {
        // A floor each, at 70% of that zone's own measurement, because the six numbers
        // are an order of magnitude apart and a single floor set by the weakest would
        // let Global lose 97% of its authority without anything going red. Measured at
        // the EV-derived default pivots (proof #6's own sweep): dark 75.52,
        // shadow 163.97, mid 194.19, light 129.34, bright 43.23, global 215.25.
        //
        // **PROOF-04 is closed by measurement.** Dark's floor used to be 3, under a
        // control that moved 4.74 of 255 code values — below the visible threshold,
        // because the old pivot put the Dark zone at −7.88 EV where an 8-bit display
        // has a couple of code values left. The EV-derived pivots put Dark at −4 EV
        // and its measured authority went 4.74 → 75.52, a 16× recovery and the single
        // largest product effect of the pivot fix. The cost lands where the shoulder
        // is: Light (+2 EV) and Bright (+4 EV) now live in display compression and
        // measure lower than the old placements did — that is the transform being
        // honest about highlights, not the controls going dead, and their floors are
        // re-anchored at 70% of the new measurements like everyone else's.
        let bands: [(String, String, WritableKeyPath<Zones, ZoneAdjust>, Double)] = [
            ("dark", "Dark", \.dark, 52), ("shadow", "Shadow", \.shadow, 114),
            ("mid", "Mid", \.mid, 135), ("light", "Light", \.light, 90),
            ("bright", "Bright", \.bright, 30), ("global", "Global", \.global, 150),
        ]
        var out: [ControlSpec] = bands.map { id, name, path, floor in
            ControlSpec(
                id: "zones.\(id).ev", panel: "Zones", displayName: "\(name) EV",
                low: -3, high: 3,
                frameName: "neutralRamp", frame: { ProofFrames.neutralRamp() },
                authorityFloor: floor,
                apply: { r, v in r.develop.zones[keyPath: path].ev = v })
        }
        // The five pivots. A pivot with every zone at zero moves a boundary between two
        // identical zones and does nothing at all — the same companion problem the
        // contrast pivot has, and the same answer: give it something to be the boundary
        // OF. The alternating ±2 EV pattern puts a four-stop seam at every one of the
        // five pivots at once, so one companion serves all five and no pivot is measured
        // through a boundary its neighbours happened not to make visible.
        func alternatingZones(_ r: inout Recipe) {
            r.develop.zones.dark.ev = 2
            r.develop.zones.shadow.ev = -2
            r.develop.zones.mid.ev = 2
            r.develop.zones.light.ev = -2
            r.develop.zones.bright.ev = 2
        }
        // Each pivot's travel, clamped against its neighbours by `ZonesPanel.movePivot`
        // with a minimum gap of 0.02 — the same reasoning as the grading pivots above.
        // Floors at 70% of each pivot's own measurement at the EV-derived defaults
        // (proof #6): 12.61, 94.45, 155.59, 37.18, 44.30. The upper two dropped hard —
        // their boundaries moved up into the display shoulder, where a seam between
        // two zones is compressed like everything else — and the dark pivot RECOVERED
        // for the same reason the dark zone did: its boundary now lives where the
        // display still has code values to move.
        let travels: [(Int, String, Double, Double, Double)] = [
            (0, "Dark", 0, 0.23, 8), (1, "Shadow", 0.10, 0.48, 66),
            (2, "Mid", 0.27, 0.73, 108), (3, "Light", 0.52, 0.90, 26),
            (4, "Bright", 0.77, 1.0, 31),
        ]
        for (index, name, lo, hi, floor) in travels {
            out.append(ControlSpec(
                id: "zones.pivot.\(index)", panel: "Zones",
                displayName: "\(name) pivot",
                low: lo, high: hi, neutral: Zones.defaultPivots[index],
                frameName: "neutralRamp", frame: { ProofFrames.neutralRamp() },
                authorityFloor: floor,
                // A pivot moves WHERE its zone acts, so sweeping one walks that zone
                // across the tonal axis and eventually past the region being measured,
                // after which the picture returns toward neutral. Only the Light pivot
                // travels far enough on this ramp for that to register. Re-pinned at
                // proof #6's measurement (was 16.250 at the old defaults): the reversal
                // SHRANK with the EV-derived pivots, which is the fix direction.
                declaredReversal: index == 3 ? 5.158 : nil,
                apply: { r, v in
                    alternatingZones(&r)
                    var pivots = Zones.defaultPivots
                    pivots[index] = v
                    r.develop.zones.pivots = pivots
                }))
        }
        return out
    }()

    /// The black-and-white mix: eight bands, on the chart.
    ///
    /// **The wedge was tried first and is the wrong frame here, which took measuring to
    /// find out.** The argument for it was good: one floor covers eight bands, docs/20
    /// sets it by the weakest member, and on the chart the weakest is whichever hue the
    /// ColorChecker happens to represent worst — a fact about a test chart rather than
    /// about the control. But a full-negative band takes its hue to BLACK (`gain =
    /// 1 + w·gate·band/100·bwKappa` reaches zero at −100), and the wedge carries rows up
    /// to +5 EV that render at the code-value ceiling. So the peak the authority metric
    /// reports is one clipped pixel going from 255 to 0, for every band: red measured
    /// 254.92 and orange 254.50, four hundredths of a level apart, on a metric whose job
    /// is to tell them apart. A floor set from those would catch a band that had died
    /// and nothing short of it.
    ///
    /// On the chart every patch sits inside the display range, so the peak is the gain
    /// rather than the clip. It is also the frame the twenty-four MIXER records already
    /// use, and the B&W mix is the same eight-band model at canonical geometry
    /// (`applyBlackAndWhite` calls the same `bandWeights`) — so these eight numbers can
    /// be read beside those twenty-four instead of only beside each other. Comparability
    /// across controls is what docs/20's fixed frame set is FOR.
    ///
    /// `enabled` is the companion and it is not optional: `applyBlackAndWhite` returns
    /// the pixel untouched unless it is set, so a band swept on `BlackAndWhite(enabled:
    /// false)` measures dead at all 21 settings while carrying the photographer's whole
    /// mix. That distinction is the reason the field exists.
    static let blackAndWhite: [ControlSpec] = {
        let names = ["red", "orange", "yellow", "green", "aqua", "blue", "purple",
                     "magenta"]
        return names.enumerated().map { index, band in
            ControlSpec(
                id: "bw.\(band)", panel: "Black & White",
                displayName: "\(band.capitalized) band",
                low: -100, high: 100,
                frameName: "colourChart", frame: { ProofFrames.colourChart() },
                // One floor for the eight, set by the weakest — aqua at 153.13, against blue
                // 161.53, purple 161.23, magenta 167.93, red 168.99, green 202.48,
                // orange 206.91 and yellow 211.85. Aqua is the weakest band on the
                // MIXER's hue axis too (46.05), which is the ColorChecker having one
                // cyan patch rather than the two bands sharing a defect.
                authorityFloor: 107,
                apply: { r, v in
                    var bw = BlackAndWhite()
                    bw.bands[index] = v
                    r.look.bw = bw
                })
        }
    }()

    /// The Film Lab: six stocks, and the five controls that shape one.
    ///
    /// **Strength is measured once per stock and the other four only on Portra 400.**
    /// A stock is not a slider — it is a choice between six parameter sets, and the
    /// question a proof can ask of a choice is whether it reaches the picture at all.
    /// That is P1 wearing a number: `FilmStock.named` returning nil, or a stock whose
    /// characteristic curve had collapsed to the neutral rendering, would show up here
    /// as a Strength slider with no authority and nowhere else in the suite. Sweeping
    /// all five controls on all six stocks would be thirty records answering the same
    /// question six times over at four minutes each, and docs/20's argument for
    /// measuring what an ordinary edit touches applies to a sweep's own budget.
    ///
    /// The wedge is the frame for the tonal three. A stock is a display transform: its
    /// characteristic curve is tonal, its crossover and couplers are chromatic, and
    /// Tri-X is monochrome. A grey ramp cannot see a stock desaturate and a mid-tone
    /// chart cannot see a toe or a shoulder; the wedge has both axes.
    ///
    /// Halation and grain are SPATIAL and get their own frames — see each entry.
    static let film: [ControlSpec] = {
        let stocks: [(String, String)] = [
            ("portra400", "Portra 400"), ("gold200", "Gold 200"),
            ("ektar100", "Ektar 100"), ("velvia50", "Velvia 50"),
            ("cine250d", "Cine 250D"), ("trix400", "Tri-X 400"),
        ]
        // One floor for the six, set by the weakest — Cine 250D at 149.10, against
        // Ektar 167.29, Gold 166.10, Portra 160.97, Velvia 159.24 and Tri-X 194.61.
        // Six stocks measuring within 30% of each other is the answer to the question
        // this loop asks: every one of them reaches the picture, and none is a preset
        // that renders as the neutral transform.
        var out: [ControlSpec] = stocks.map { id, name in
            ControlSpec(
                // Strength is the blend against the neutral rendering, 0…100 in the
                // panel and in `FilmLab.amount`. At 0 `RenderPlan` builds no film chain
                // at all, so the bottom of this travel is the picture without the stock
                // — which is what the slider means, and why the sweep starts there.
                id: "film.\(id).strength", panel: "Film Lab",
                displayName: "\(name) strength",
                low: 0, high: 100, neutral: 0,
                frameName: "tonalColourWedge", frame: { ProofFrames.tonalColourWedge() },
                // One floor for the five colour stocks, at 70% of the weakest —
                // Portra 400 at 84.55 since the inset fix (proof #16 convicted the
                // old 104 on all five: a film curve's authority is mostly its colour,
                // and the corrected desaturation direction softened every stock).
                authorityFloor: 59,
                apply: { r, v in r.look.filmLab = FilmLab(stock: "lumen/\(id)", amount: v) })
        }
        /// Portra 400 at full strength — the stock the other five controls shape.
        func portra() -> FilmLab { FilmLab(stock: "lumen/portra400", amount: 100) }
        out.append(ControlSpec(
            // Film Exposure is not Develop's Exposure: it shifts the scene along the
            // stock's log-exposure axis, into a different part of its latitude. −2…+3 EV
            // in the panel and in `FilmChain`'s own clamp.
            id: "film.exposure", panel: "Film Lab", displayName: "Film exposure",
            low: -2, high: 3,
            frameName: "tonalColourWedge", frame: { ProofFrames.tonalColourWedge() },
            // Measured 186.01.
            authorityFloor: 130,
            apply: { r, v in
                var film = portra()
                film.exposure = v
                r.look.filmLab = film
            }))
        out.append(ControlSpec(
            id: "film.pushPull", panel: "Film Lab", displayName: "Push / pull",
            low: -1, high: 2,
            frameName: "tonalColourWedge", frame: { ProofFrames.tonalColourWedge() },
            // Measured 31.84.
            authorityFloor: 22,
            apply: { r, v in
                var film = portra()
                film.pushPull = v
                r.look.filmLab = film
            }))
        out.append(ControlSpec(
            // Halation is highlight energy scattering off the film base and coming back,
            // so it is measured on a STEP EDGE: a bright field beside a dark one is
            // where a glow reads as a glow rather than as a uniform lift, and the step
            // edge's bright side sits about half a stop under the halation clip while
            // its dark side sits four under — exactly straddling `highlightEnergy`'s
            // gate.
            //
            // On the WIDE step edge, because the kernel is 65 µm at a 36 mm gate and
            // therefore a fixed fraction of the long edge. At `stepEdge`'s 128 px that
            // is a σ of 0.23 pixels — no light crosses the edge at all — and the control
            // measured 4.31 code values, which is a reading of the frame's resolution
            // and not of the slider.
            id: "film.halation", panel: "Film Lab", displayName: "Halation",
            low: 0, high: 100,
            frameName: "wideStepEdge", frame: { ProofFrames.wideStepEdge() },
            // Measured 24.71 on the wide edge, against 4.31 on the narrow one.
            authorityFloor: 17,
            apply: { r, v in
                var film = portra()
                film.halation = v
                r.look.filmLab = film
            }))
        out.append(ControlSpec(
            // Grain's amplitude envelope is √(p(1−p)) in DENSITY, so it peaks at mid
            // densities and vanishes at both ends: the frame is a ramp because a frame
            // at one density measures one point of a curve. It is a 4096-px ramp because
            // the plate scale is a pitch on the PRINT converted to this render's pixels,
            // floored at half a pixel — see `ProofFrames.grainField`. Both grain
            // controls sit on it so their two numbers are of the same grain.
            id: "film.grain.amount", panel: "Film Lab", displayName: "Grain",
            low: 0, high: 100,
            frameName: "grainField", frame: { ProofFrames.grainField() },
            // Measured 19.43, then 16.32 once the dye layers stopped laying their
            // noise at full independence (C2-02) — the same per-channel measurement
            // effect `film.grain.size` explains at length below, a third of the size
            // because this control sweeps amount at one pitch rather than sweeping the
            // pitch itself. It still clears its floor with room.
            authorityFloor: 13,
            apply: { r, v in
                var film = portra()
                film.grain = FilmGrain(size: 1.0, amount: v)
                r.look.filmLab = film
            }))
        out.append(ControlSpec(
            // Grain size is the plate's pitch and does nothing to a picture with no
            // grain in it — the companion is the same one Sharpen Radius needs from
            // Sharpen Amount. 0.5…2.0 is the panel's range.
            //
            // On `grainField` and not the ramp, and this one is the reason that frame
            // exists. `FilmGrainProfile.plateScale` floors a plate cell at half a pixel,
            // and on a 256-px ramp the whole 0.5…2.0 travel evaluates to 0.04…0.17 —
            // under the floor at every setting. It measured authority 0.00 with twenty
            // dead steps of twenty, which reads exactly like an inert control and is
            // not one. PROOF-06 records what that same arithmetic says about the
            // control at PREVIEW resolution, which is a real finding rather than a
            // probe error.
            id: "film.grain.size", panel: "Film Lab", displayName: "Grain size",
            low: 0.5, high: 2.0, neutral: 1.0,
            frameName: "grainField", frame: { ProofFrames.grainField() },
            // Measured 40.69, against 0.00 on the ramp; 40.13 after the plate was
            // band-limited (C2-01b); **26.19** after the dye layers stopped laying
            // their noise at full independence (C2-02), which is where both numbers
            // below now come from.
            //
            // THE FLOOR MOVED BECAUSE THE METRIC MOVED, not because the control did.
            // `authority` is measured in sRGB code values, which is per-CHANNEL
            // movement — and C2-02 deliberately removed the part of that movement that
            // was colour. The grain a photographer SEES is luminance grain and it is
            // held to within 0.04% (`FilmGrainProfile.noiseMixWeights`); what left the
            // measurement is the coloured speckle that only ever reached the delivered
            // file. The floor is restated at the same fraction of the measurement it
            // was set at — 28 of 40.69 is 0.69, and 0.69 of 26.19 is 18 — so it still
            // means "this control has visibly stopped working" and not "this control
            // was changed".
            //
            // The evidence that the drop is the speckle and nothing else is one line of
            // the record: `hueRotation` went **179.99° → 0**. Sweeping grain SIZE used
            // to rotate the frame's hue half a turn. It no longer moves it at all.
            authorityFloor: 18,
            // A grain cell's footprint is a boundary too: past the size where one cell
            // spans more than the measured field's own detail, the pattern coarsens back
            // toward flat rather than continuing to add structure.
            //
            // 15.462 → 21.183 for a reason that is the same change seen from the other
            // side. Three near-independent layers made the sweep a walk in three
            // dimensions, where excursions partly cancel; one shared luminance field
            // makes it a walk in ONE, where they do not. Same wandering boundary, fewer
            // dimensions to wander in, so a larger share of the travel is spent going
            // back. The fraction it declares is now 81% of its authority against 37%,
            // which is high and is what a boundary control on a random field looks like
            // when its randomness is one-dimensional.
            declaredReversal: 21.183,
            apply: { r, v in
                var film = portra()
                film.grain = FilmGrain(size: v, amount: 100)
                r.look.filmLab = film
            }))
        return out
    }()

    /// The two classical denoise masters.
    ///
    /// Three things had to be right at once for these to measure anything, and each of
    /// them has produced a fake reading somewhere in this repository's history.
    ///
    /// **The frame carries noise.** Obvious, and `noisyISO6400` is the frame docs/20
    /// names for every denoise control. Colour gets `noisyChromaEdge` instead, because
    /// `noisyISO6400`'s clean twin is neutral: a colour denoiser has chroma noise to
    /// remove there but no chroma SIGNAL to be measured against, and
    /// `DenoiseQualityTests` records that a residual score on that frame is a tautology
    /// a stage which annihilates every chroma band passes perfectly.
    ///
    /// **The thresholds are denominated in the right noise.** `captureISO: 6400`, or
    /// `RenderPlan` builds the stage from an ISO 100 profile and the sweep measures an
    /// instrument calibrated for a different sensor.
    ///
    /// **The stage actually runs.** `ReferenceRenderer.render` starts at S6 and S3 is
    /// not inside it; `denoisedFirst` is what puts it back where the shipping reference
    /// path has it (PipelineRenderer.swift:1468). Without that flag both of these
    /// measure exactly zero — a dead reading produced by rendering through a pipeline
    /// missing the stage under test, which is the frame mistake with the frame right.
    ///
    /// The travel is 0…100 for both, in the panel and in `ClassicNR`. Neither gets a
    /// companion beyond the mode: `ISODefaults.classic(for:)` returns a zeroed block
    /// unless the mode is Classic, so Off would report both as dead.
    static let denoise: [ControlSpec] = [
        ControlSpec(
            id: "denoise.luma", panel: "Detail", displayName: "Luminance denoise",
            low: 0, high: 100,
            frameName: "noisyISO6400", frame: { ProofFrames.noisyISO6400() },
            // Measured 9.60 — see PROOF-07.
            authorityFloor: 6, mayLeaveRange: false,
            captureISO: 6400, denoisedFirst: true,
            apply: { r, v in
                r.develop.denoise.mode = .classic
                r.develop.denoise.classic.luma = v
            }),
        ControlSpec(
            id: "denoise.chroma", panel: "Detail", displayName: "Colour denoise",
            low: 0, high: 100,
            frameName: "noisyChromaEdge", frame: { ProofFrames.noisyChromaEdge() },
            // Measured 22.02 before the inset orientation fix; 16.16 after it.
            authorityFloor: 11, mayLeaveRange: false,
            captureISO: 6400, denoisedFirst: true,
            apply: { r, v in
                r.develop.denoise.mode = .classic
                r.develop.denoise.classic.chroma = v
            }),
        // The five disclosure sliders, found recordless by the coverage audit
        // (docs/27). Each rides its master as a companion — a threshold multiplier
        // measured with the master at zero would be the contrast-pivot mistake again.
        // The luma pair works against the master's own frame; the colour pair against
        // the chroma edge for the reason the header gives; Hot Pixels against the
        // frame that actually contains its subject.
        ControlSpec(
            id: "denoise.lumaDetail", panel: "Detail", displayName: "Luminance detail",
            low: 0, high: 100, neutral: 50,
            frameName: "noisyISO6400", frame: { ProofFrames.noisyISO6400() },
            authorityFloor: 4, mayLeaveRange: false,
            captureISO: 6400, denoisedFirst: true,
            apply: { r, v in
                r.develop.denoise.mode = .classic
                r.develop.denoise.classic.luma = 60
                r.develop.denoise.classic.lumaDetail = v
            }),
        ControlSpec(
            id: "denoise.lumaContrast", panel: "Detail",
            displayName: "Luminance contrast",
            low: 0, high: 100,
            frameName: "noisyISO6400", frame: { ProofFrames.noisyISO6400() },
            // Measured 0.75 of 255 — at the threshold of visibility on this frame,
            // the weakest live control in the registry. Recorded rather than hidden
            // (the Blacks-at-2.9 shape): either the shrinkage bias needs a stronger
            // mapping or this probe needs a frame with coarser luma structure for
            // the bias to preserve. Queued in docs/23's audit fix queue; the floor
            // is 70% of what is, not of what is wished.
            authorityFloor: 0.5, mayLeaveRange: false,
            captureISO: 6400, denoisedFirst: true,
            apply: { r, v in
                r.develop.denoise.mode = .classic
                r.develop.denoise.classic.luma = 60
                r.develop.denoise.classic.lumaContrast = v
            }),
        ControlSpec(
            id: "denoise.colorDetail", panel: "Detail", displayName: "Colour detail",
            low: 0, high: 100, neutral: 50,
            frameName: "noisyChromaEdge", frame: { ProofFrames.noisyChromaEdge() },
            authorityFloor: 8, mayLeaveRange: false,
            captureISO: 6400, denoisedFirst: true,
            apply: { r, v in
                r.develop.denoise.mode = .classic
                r.develop.denoise.classic.chroma = 60
                r.develop.denoise.classic.colorDetail = v
            }),
        ControlSpec(
            id: "denoise.colorSmoothness", panel: "Detail",
            displayName: "Colour smoothness",
            low: 0, high: 100, neutral: 50,
            frameName: "noisyChromaEdge", frame: { ProofFrames.noisyChromaEdge() },
            authorityFloor: 4, mayLeaveRange: false,
            captureISO: 6400, denoisedFirst: true,
            apply: { r, v in
                r.develop.denoise.mode = .classic
                r.develop.denoise.classic.chroma = 60
                r.develop.denoise.classic.colorSmoothness = v
            }),
        ControlSpec(
            id: "denoise.hotPixels", panel: "Detail", displayName: "Hot pixels",
            low: 0, high: 100,
            frameName: "hotPixels", frame: { ProofFrames.hotPixels() },
            // A THRESHOLD control, and the record says so: authority 171 (removing
            // an impulse moves that pixel a long way) with 19 of 20 steps dead —
            // the whole job happens at the bottom of the travel and the rest of the
            // slider holds the result. Declared, per the plateau rule: a plateau
            // that GROWS to 20 means the control died, one that shrinks means the
            // response gained a ramp, and either way somebody argues it in a commit.
            authorityFloor: 119, mayLeaveRange: false,
            captureISO: 6400, denoisedFirst: true,
            declaredPlateauSteps: 19,
            apply: { r, v in
                r.develop.denoise.mode = .classic
                r.develop.denoise.classic.hotPixels = v
            }),
    ]

    /// The Colour Balance grid (docs/05's headline claim over Lightroom): two master
    /// moves plus chroma / saturation / brilliance across (global, shadows, mid, high).
    /// Fourteen draggable sliders that shipped with no record — found by the
    /// every-slider coverage audit (docs/27), the same class of gap as Density's.
    ///
    /// On the wedge, like the wheels, because the grid grades the same three zones the
    /// wheels do and a chart with no tonal spread would starve the zone fields of the
    /// pixels they act on. Hue shift is circular: −180° and +180° are the same setting,
    /// so authority reads at the antipode per docs/20 P4.
    static let colourBalance: [ControlSpec] = {
        var out: [ControlSpec] = [
            ControlSpec(
                id: "cb.hueShift", panel: "Colour Balance", displayName: "Hue shift",
                low: -180, high: 180,
                frameName: "tonalColourWedge", frame: { ProofFrames.tonalColourWedge() },
                authorityFloor: 133, isCircular: true,
                apply: { r, v in r.look.wheels.colorBalance.hueShift = v }),
            ControlSpec(
                id: "cb.vibrance", panel: "Colour Balance", displayName: "CB vibrance",
                low: -100, high: 100,
                frameName: "tonalColourWedge", frame: { ProofFrames.tonalColourWedge() },
                authorityFloor: 71,
                apply: { r, v in r.look.wheels.colorBalance.vibrance = v }),
        ]
        let axes: [(String, String, WritableKeyPath<ColorBalanceParams, ColorBalanceAxis>)] = [
            ("chroma", "Chroma", \.chroma),
            ("saturation", "Saturation", \.saturation),
            ("brilliance", "Brilliance", \.brilliance),
        ]
        let zones: [(String, String, WritableKeyPath<ColorBalanceAxis, Double>)] = [
            ("global", "Global", \.global),
            ("shadows", "Shadows", \.shadows),
            ("mid", "Midtones", \.mid),
            ("high", "Highlights", \.high),
        ]
        // 70% of each field's own first measurement (the recorder run on the
        // corrected inset). Shadow zones measure a third of their siblings for the
        // reason every shadow control does; global and high match on this wedge
        // because the high zone dominates its bright half.
        //
        // THE TWO BRILLIANCE FIGURES THAT MOVED, and why a floor coming DOWN is not a
        // goalpost being moved. These were 91 and 174 — 70% of 130.28 and of 249.87,
        // measurements taken BEFORE the grading wheels got their limiter. That limiter
        // is the fix for the Luminance inversion: the wheels scale OKLab L, whose
        // linear value is L cubed, so the realised response is 1 + 3*scale*slope while
        // the old solve used 1 + scale*slope — 2.85x too permissive, with 345 of 810
        // sampled combinations INVERTING the tone they claimed to lift, and
        // Brilliance's own worst case measuring 226.7 sRGB codes of reversal.
        //
        // So the number those two floors were 70% OF was the authority of a control
        // that could run the picture backwards. Correcting it cost brilliance a
        // quarter to a third of its measured travel — shadows 130.28 -> 80.82, mid
        // 249.87 -> 159.72 — and that is the defect leaving, not the control
        // weakening. The floors are re-derived by the rule this comment already
        // states, applied to the corrected engine: 70% of 80.82 and of 159.72.
        //
        // The engine change shipped without visiting this file, which is why it took a
        // COMPLETED Proof sweep to surface: every sweep between that commit and this
        // one was cancelled by the next push, so the lane that would have caught it
        // the same day never finished. A deliberate behaviour change owes this file a
        // visit, and the cancelled lanes are why nothing said so.
        //
        // `brilliance.high` measured 189.93 and still clears its 178, so it KEEPS the
        // tighter floor rather than being loosened to 70% of its own new figure: a
        // floor a control provably clears is worth more than a consistent formula.
        let floors: [String: Double] = [
            "chroma.global": 111, "chroma.shadows": 38,
            "chroma.mid": 109, "chroma.high": 111,
            "saturation.global": 112, "saturation.shadows": 37,
            "saturation.mid": 108, "saturation.high": 112,
            "brilliance.global": 178, "brilliance.shadows": 56,
            "brilliance.mid": 111, "brilliance.high": 178,
        ]
        for (axisId, axisName, axisPath) in axes {
            for (zoneId, zoneName, zonePath) in zones {
                out.append(ControlSpec(
                    id: "cb.\(axisId).\(zoneId)", panel: "Colour Balance",
                    displayName: "\(axisName) \(zoneName)",
                    low: -100, high: 100,
                    frameName: "tonalColourWedge",
                    frame: { ProofFrames.tonalColourWedge() },
                    authorityFloor: floors["\(axisId).\(zoneId)"] ?? 3,
                    apply: { r, v in
                        r.look.wheels.colorBalance[keyPath: axisPath][keyPath: zonePath] = v
                    }))
            }
        }
        return out
    }()

    /// The Effects panel's vignette: EV at the corner, applied on scene-linear data
    /// before the display transform (the panel's own caption), ellipse from the crop.
    ///
    /// The travel is READ from the engine rather than restated, and it has moved —
    /// −3…+1 to −4…+2, with the measurement on `DetailEngine.vignetteAmountRange`. A
    /// registry holding its own copy of a range is the failure this harness's own
    /// assertion message warns about in as many words ("a large dead count is far more
    /// often a probe driven past a control's own bounds"); the mirror of it is a probe
    /// driven only part way along the bounds, which reports an authority the control
    /// exceeds and a front-loading measured over the wrong interval. The committed
    /// record moves with the range, which is the whole point of committing records: a
    /// deliberate widening shows up as a changed travel and a risen authority, where an
    /// accidental one would show up as neither.
    static let effects: [ControlSpec] = [
        ControlSpec(
            id: "look.vignette", panel: "Effects", displayName: "Vignette",
            low: DetailEngine.vignetteAmountRange.lowerBound,
            high: DetailEngine.vignetteAmountRange.upperBound,
            frameName: "neutralRamp", frame: { ProofFrames.neutralRamp() },
            authorityFloor: 84,
            apply: { r, v in r.look.vignette = v }),
    ]

    /// THE NINE THIS REGISTRY DID NOT HAVE, found by `SliderEvidenceTests` — the join
    /// between the control keys the develop panels bind and the ids this file declares.
    ///
    /// Three of them were not merely missed. `docs/27` §3 dispositioned the Effects grain
    /// rows with "Same recipe fields as `film.grain.*` (both panels bind
    /// `look.filmLab.grain`)". They do not: `EffectsPanel.swift:252` says the stock rows
    /// bind `film.grain.*` and "the creative row twenty lines down used the identical
    /// string for a different field". `look.grain` is `CreativeGrain`, and it carries a
    /// Roughness that `FilmGrain` has no counterpart for at all, so "measured twice"
    /// could never have covered it.
    ///
    /// EVERY ONE OF THESE SWEEPS A SHAPE CONTROL, and docs/20 P2's frame rule is the
    /// whole difficulty: "a control must be swept on a frame containing what it acts on."
    /// A halation RADIUS measures nothing without halation to resize; a grain SIZE
    /// measures nothing without grain. So each shape control's `apply` pushes its own
    /// master to full before writing the swept field, and the master's own record
    /// (`film.halation`, `look.grain.amount`) is what proves the master.
    static let halationShape: [ControlSpec] = {
        func glowing(_ v: Double, _ set: (inout FilmLab) -> Void) -> FilmLab {
            var film = FilmLab(stock: "lumen/portra400", amount: 100)
            // Halation at full, because these two shape a glow rather than make one.
            film.halation = 100
            set(&film)
            return film
        }
        return [
            ControlSpec(
                // The kernel's radius, as a multiple of the emulsion's measured 65 µm.
                // `wideStepEdge` for the reason `film.halation` gives at its own site:
                // the bounce is a fixed fraction of the long edge, so at the narrow
                // edge's 128 px the σ is 0.23 px and the reading is of the frame's
                // resolution rather than of the slider.
                id: "film.halationSize", panel: "Film Lab", displayName: "Halo size",
                low: 0.5, high: 2.0, neutral: 1.0,
                frameName: "wideStepEdge", frame: { ProofFrames.wideStepEdge() },
                // Measured 16.20 with halation at full.
                authorityFloor: 11,
                apply: { r, v in r.look.filmLab = glowing(v) { $0.halationSize = v } }),
            ControlSpec(
                // The bounce's colour. Same frame and the same reason.
                id: "film.halationRedness", panel: "Film Lab",
                displayName: "Halo redness",
                low: 0, high: 100, neutral: 50,
                frameName: "wideStepEdge", frame: { ProofFrames.wideStepEdge() },
                // Measured 7.96 — the weakest of the nine, and it is a COLOUR move on
                // a bounce that is already only a few code values wide, so a small
                // number here is the control being what it is rather than being faint.
                // Recorded rather than argued about; if it ever wants raising, the
                // record is the thing that would show it moving.
                authorityFloor: 5,
                apply: { r, v in r.look.filmLab = glowing(v) { $0.halationRedness = v } }),
        ]
    }()

    /// Creative grain — `look.grain`, NOT `look.filmLab.grain`. No film stock is set on
    /// these recipes, because `GrainPlan.filmOwnsTheGrain` is what decides which of the
    /// two grain paths runs and a stock would route the sweep through the other one.
    static let creativeGrain: [ControlSpec] = [
        ControlSpec(
            // `grainField` is the 4096-px ramp both stock grain controls sit on, so
            // these four numbers are all of the same grain at the same plate scale.
            // Grain's amplitude envelope is √(p(1−p)) in density: a frame at one
            // density measures one point of a curve.
            id: "look.grain.amount", panel: "Effects", displayName: "Grain",
            low: 0, high: 100, neutral: 0,
            frameName: "grainField", frame: { ProofFrames.grainField() },
            // Measured 14.77, monotone, nothing given back.
            authorityFloor: 10,
            apply: { r, v in r.look.grain = CreativeGrain(amount: v) }),
        ControlSpec(
            id: "look.grain.size", panel: "Effects", displayName: "Grain size",
            low: 0, high: 100, neutral: 50,
            frameName: "grainField", frame: { ProofFrames.grainField() },
            // Measured 28.26.
            authorityFloor: 19,
            // A BOUNDARY CONTROL ON A RANDOM FIELD, and it declares the reversal for
            // exactly the reason `film.grain.size` does forty lines up — that spec
            // declares 21.183, which is 81% of its own authority, and its comment is
            // the argument: past the size where one grain cell spans more than the
            // measured field's own detail, the pattern coarsens back toward flat
            // rather than continuing to add structure. Changing SIZE regenerates the
            // field, so consecutive settings differ by decorrelation as much as by
            // trend, and `smallestLiveStep` of 18.18 against Amount's 0.72 on the same
            // frame is that effect measured.
            //
            // 14.62 is 52% of authority against the film control's 81% — lower
            // because this is one luminance field where that one is a stock's dye
            // layers. Declared, not asserted away: if it ever climbs, the record moves
            // and the reversal test says so at 1.05x.
            declaredReversal: 14.623,
            // Amount at full: a size control on a field with no grain in it is the
            // INVALID PROBE docs/20 §P2 names, not a dead control.
            apply: { r, v in r.look.grain = CreativeGrain(amount: 100, size: v) }),
        ControlSpec(
            // Octave persistence, 0.25…0.75 with 50 mapping to 0.5 exactly. The control
            // `FilmGrain` does not have, and the one docs/27's "measured twice"
            // disposition could not have been describing.
            id: "look.grain.roughness", panel: "Effects", displayName: "Grain roughness",
            low: 0, high: 100, neutral: 50,
            frameName: "grainField", frame: { ProofFrames.grainField() },
            // Measured 12.37, monotone, nothing given back — and that it IS monotone
            // where Size is not is the evidence that Size's reversal is the boundary
            // rather than the harness: same frame, same field, same sweep length.
            authorityFloor: 8,
            apply: { r, v in
                r.look.grain = CreativeGrain(amount: 100, roughness: v)
            }),
    ]

    /// The four Display Transform overrides. Each is `Double?` on the wire, nil meaning
    /// "follow the preset", so `neutral` is the PRESET's own value rather than a
    /// constant — a sweep whose neutral is not where the control rests measures its
    /// travel from the wrong place.
    static let displayTransform: [ControlSpec] = {
        let base = DisplayTransformParams.preset(named: "Neutral")
        return [
            ControlSpec(
                id: "render.contrast", panel: "Display Transform",
                displayName: "Contrast",
                low: 0.1, high: 10, neutral: base.contrast,
                frameName: "neutralRamp", frame: { ProofFrames.neutralRamp() },
                // Measured 129.68 — the strongest of the nine by a wide margin, which
                // is what an override on the display transform's own contrast should
                // be. `frontLoading` records 0.964: almost the whole move is spent in
                // the first half of a 0.1…10 travel, which is what a LOG-scaled
                // parameter swept LINEARLY looks like from the outside.
                //
                // That number is about THIS SWEEP and not about the row any more, and
                // the distinction matters now that K-039 has landed. A proof sweeps the
                // recipe field across its declared range at even steps, which is the
                // right way to ask what the control is worth; the slider presents the
                // same range on `SliderScale.log`, so a hand moving evenly along the
                // track does NOT produce this distribution. Reading 0.964 as "the row
                // is front-loaded" would be reading the probe.
                authorityFloor: 90,
                apply: { r, v in r.look.render.contrast = v }),
            ControlSpec(
                id: "render.skew", panel: "Display Transform", displayName: "Skew",
                low: -1, high: 1, neutral: base.skew,
                frameName: "neutralRamp", frame: { ProofFrames.neutralRamp() },
                // Measured 18.46.
                authorityFloor: 12,
                apply: { r, v in r.look.render.skew = v }),
            ControlSpec(
                // CHROMA, not a ramp. Hue preservation is a statement about coloured
                // pixels; swept on `neutralRamp` it would render identically at every
                // setting and record a dead control that is not dead — docs/20 §P2's
                // INVALID PROBE, and the exact trap `film.halation` fell into on the
                // narrow edge.
                id: "render.hue", panel: "Display Transform", displayName: "Hue keep",
                low: 0, high: 100, neutral: base.huePreservation,
                frameName: "tonalColourWedge", frame: { ProofFrames.tonalColourWedge() },
                // Measured 28.73 on the wedge. The frame choice is load-bearing and
                // the number is the proof: this control is a statement about coloured
                // pixels, and on `neutralRamp` it would have recorded a dead control.
                authorityFloor: 20,
                apply: { r, v in r.look.render.huePreservation = v }),
            ControlSpec(
                id: "render.black", panel: "Display Transform",
                displayName: "Black target",
                low: 0, high: 9, neutral: base.blackTarget,
                frameName: "neutralRamp", frame: { ProofFrames.neutralRamp() },
                // Measured 84.61.
                authorityFloor: 59,
                apply: { r, v in r.look.render.blackTarget = v }),
        ]
    }()

    static var all: [ControlSpec] {
        tone + colour + curve + presence + sharpen + mixer
            + grade + gradeGeometry + printerLights + primaries + pointColour
            + zones + blackAndWhite + film + denoise + colourBalance + effects
            + halationShape + creativeGrain + displayTransform
    }
}
