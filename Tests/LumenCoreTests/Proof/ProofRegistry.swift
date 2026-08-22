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
// codebase. The `shippingReader` field is what keeps that honest: it names the line on
// the real path, so a record cannot be filed for a control the GPU never reads.

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
    /// `file:line` of a reader on the SHIPPING path — `RenderGraph` or `export`.
    let shippingReader: String
    /// A floor under P3 authority, in sRGB code values. Below this the control is not
    /// visible on an 8-bit display and is therefore not a control.
    let authorityFloor: Double
    /// Whether the control may legitimately push pixels outside the input's own range.
    /// A global exposure move may; a local-contrast operator may not, and for those the
    /// overshoot is the halo measurement.
    let mayLeaveRange: Bool

    init(id: String, panel: String, displayName: String,
         low: Double, high: Double, neutral: Double = 0,
         frameName: String, frame: @escaping () -> ImageBuffer,
         shippingReader: String, authorityFloor: Double,
         mayLeaveRange: Bool = true,
         apply: @escaping (inout Recipe, Double) -> Void)
    {
        self.id = id; self.panel = panel; self.displayName = displayName
        self.low = low; self.high = high; self.neutral = neutral
        self.frameName = frameName; self.frame = frame
        self.shippingReader = shippingReader
        self.authorityFloor = authorityFloor
        self.mayLeaveRange = mayLeaveRange
        self.apply = apply
    }
}

enum ProofRegistry {

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
            id: "tone.exposure", panel: "Basic", displayName: "Exposure",
            low: -2, high: 2,
            frameName: "neutralRamp", frame: { ProofFrames.neutralRamp() },
            shippingReader: "Sources/LumenPipeline/RenderGraph.swift:86",
            authorityFloor: 120,
            apply: { r, v in r.develop.tone.exposure = v }),
        ControlSpec(
            id: "tone.contrast", panel: "Basic", displayName: "Contrast",
            low: -100, high: 100,
            frameName: "neutralRamp", frame: { ProofFrames.neutralRamp() },
            shippingReader: "Sources/LumenPipeline/RenderGraph.swift:486",
            authorityFloor: 55,
            apply: { r, v in r.develop.tone.contrast = v }),
        ControlSpec(
            id: "tone.highlights", panel: "Basic", displayName: "Highlights",
            low: -100, high: 100,
            frameName: "neutralRamp", frame: { ProofFrames.neutralRamp() },
            shippingReader: "Sources/LumenPipeline/RenderGraph.swift:486",
            authorityFloor: 35,
            apply: { r, v in r.develop.tone.highlights = v }),
        ControlSpec(
            id: "tone.shadows", panel: "Basic", displayName: "Shadows",
            low: -100, high: 100,
            frameName: "neutralRamp", frame: { ProofFrames.neutralRamp() },
            shippingReader: "Sources/LumenPipeline/RenderGraph.swift:486",
            authorityFloor: 30,
            apply: { r, v in r.develop.tone.shadows = v }),
        ControlSpec(
            id: "tone.whites", panel: "Basic", displayName: "Whites",
            low: -100, high: 100,
            frameName: "neutralRamp", frame: { ProofFrames.neutralRamp() },
            shippingReader: "Sources/LumenPipeline/RenderGraph.swift:486",
            authorityFloor: 30,
            apply: { r, v in r.develop.tone.whites = v }),
        ControlSpec(
            id: "tone.blacks", panel: "Basic", displayName: "Blacks",
            low: -100, high: 100,
            frameName: "neutralRamp", frame: { ProofFrames.neutralRamp() },
            shippingReader: "Sources/LumenPipeline/RenderGraph.swift:486",
            authorityFloor: 15,
            apply: { r, v in r.develop.tone.blacks = v }),
        ControlSpec(
            id: "tone.contrastPivot", panel: "Basic", displayName: "Contrast pivot",
            low: -100, high: 100,
            frameName: "neutralRamp", frame: { ProofFrames.neutralRamp() },
            shippingReader: "Sources/LumenPipeline/RenderGraph.swift:486",
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
            shippingReader: "Sources/LumenPipeline/RenderGraph.swift:98",
            authorityFloor: 40,
            apply: { r, v in r.develop.color.saturation = v }),
        ControlSpec(
            id: "color.vibrance", panel: "Colour", displayName: "Vibrance",
            low: -100, high: 100,
            frameName: "colourChart", frame: { ProofFrames.colourChart() },
            shippingReader: "Sources/LumenPipeline/RenderGraph.swift:98",
            authorityFloor: 20,
            apply: { r, v in r.develop.color.vibrance = v }),
        ControlSpec(
            id: "raw.temp", panel: "Basic", displayName: "Temperature",
            low: 3000, high: 9000, neutral: 5500,
            frameName: "colourChart", frame: { ProofFrames.colourChart() },
            shippingReader: "Sources/LumenPipeline/RenderGraph.swift:86",
            authorityFloor: 60,
            apply: { r, v in r.develop.raw.temp = v }),
        ControlSpec(
            id: "raw.tint", panel: "Basic", displayName: "Tint",
            low: -100, high: 100,
            frameName: "colourChart", frame: { ProofFrames.colourChart() },
            shippingReader: "Sources/LumenPipeline/RenderGraph.swift:86",
            authorityFloor: 25,
            apply: { r, v in r.develop.raw.tint = v }),
    ]

    static var all: [ControlSpec] { tone + colour }
}
