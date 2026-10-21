// AppliedReadout.swift
// What the engines already measure about a control that is NOT doing what its slider
// says, turned into the one value (or the one line) a panel shows.
//
// Every number here was already computed by an engine and handed to nobody. The tone
// solve publishes `effectiveHighlights` and its three siblings "so the panel can show
// the applied value"; the grade solve publishes `lumScale · jointScale` and the grid's
// `appliedBrillianceScale`; `ToneEngine.zoneFlattening` reports the band the Zones
// clamp renders flat (Astra AI-07). None of them reached a panel. `BasicPanel`'s
// bounded-Tint caption is the one place the app already did this, and it is the idiom
// copied: a caption that is NIL while the slider and the render agree, so ordinary
// editing never grows a line, and that carries the number the render actually uses.
//
// The decisions live here rather than in the SwiftUI files for the reason
// `ScopeReadout` gives: they are arithmetic, or strings over arithmetic, and a decision
// a test can reach is a decision that stops drifting. Nothing here feeds a render — it
// constructs the same engines `RenderPlan` constructs and only reads them.

import Foundation

public enum AppliedReadout {

    /// The shared curve bake's applied strength, quiet while it rounds to 100%.
    /// This describes the combined parametric shift, not the point curve or a
    /// different estimate of individual region amplitudes.
    public static func parametricEasingCaption(appliedScale: Double) -> String? {
        guard appliedScale.isFinite, appliedScale >= 0, appliedScale < 0.995 else { return nil }
        let percent = Int((appliedScale * 100).rounded())
        return "Combined curve strength: \(percent)% — reduced to keep tones in order."
    }

    // MARK: - Zones (Astra AI-07)

    /// The band of input tones the Zones clamp renders as one value, placed on the
    /// strip the panel draws.
    public struct ZoneFlattening: Equatable, Sendable {
        /// The engine's own report.
        public let flattening: ToneEngine.Flattening
        /// Where the band sits on the strip's x axis, `ToneEngine.zoneAxis` — the
        /// default anchors, the axis the pivots are stored on, so Whites and Blacks do
        /// not slide the mark off the tones it names.
        public let lowX: Double
        public let highX: Double
        /// The line under the strip.
        public let caption: String
    }

    /// Nil while the bake's clamp moves nothing.
    ///
    /// A Zones-only recipe never reaches it now: `ToneEngine.appliedZoneEV` eases the
    /// zones first (reported by `zoneEasing`). What still can is the register combined
    /// with Contrast or the six sliders, because the ease does not see them —
    /// Contrast −100 with Darks +3 flattens a band below mid-grey.
    ///
    /// No floor under the engine's report: a floor would be a second definition of
    /// "flattened".
    public static func zoneFlattening(tone: Tone, zones: Zones) -> ZoneFlattening? {
        let engine = ToneEngine(tone: tone, zones: zones)
        guard let f = engine.zoneFlattening() else { return nil }
        let caption = "Flattened: input \(ev(f.lowEV))…\(ev(f.highEV)) EV renders as one "
            + "tone, up to \(magnitude(f.worstEV)) EV from what the zones ask."
        return ZoneFlattening(flattening: f,
                              lowX: ToneEngine.zoneAxis(f.lowEV),
                              highX: ToneEngine.zoneAxis(f.highEV),
                              caption: caption)
    }

    /// One zone the register applies at less than its slider asks, in stops.
    public struct ZoneEased: Equatable, Sendable {
        /// The register's own row name: Darks, Shadows, Midtones, Lights, Brights.
        public let name: String
        public let requested: Double
        public let applied: Double

        /// The line under that zone's slider.
        public var caption: String {
            "Applied \(AppliedReadout.ev(applied)) EV — eased so no brighter tone "
                + "renders darker."
        }
    }

    /// The register's row names, in pivot order. `ZonesPanel` titles its rows from this.
    public static let zoneNames = ["Darks", "Shadows", "Midtones", "Lights", "Brights"]

    /// Every zone `ToneEngine.appliedZoneEV` holds back by more than 0.005 EV — the
    /// half-step of the readout's two decimals, so a rounding difference never earns a
    /// line. Empty for any single zone inside ±0.75 EV at the default pivots.
    ///
    /// `tone` is taken so the call reads like its siblings and keeps reading right if
    /// the ease ever learns about the six sliders; today it does not consult it.
    public static func zoneEasing(tone: Tone, zones: Zones) -> [ZoneEased] {
        let applied = ToneEngine(tone: tone, zones: zones).appliedZoneEV
        let requested = [zones.dark.ev, zones.shadow.ev, zones.mid.ev, zones.light.ev,
                         zones.bright.ev]
        var out: [ZoneEased] = []
        for i in requested.indices where abs(requested[i] - applied[i]) > 0.005 {
            out.append(ZoneEased(name: zoneNames[i], requested: requested[i],
                                 applied: applied[i]))
        }
        return out
    }

    // MARK: - The four zonal Tone sliders

    /// One Tone slider the monotonicity solve is holding back.
    public struct Eased: Equatable, Sendable {
        public let name: String
        /// Slider units, −100…100.
        public let requested: Double
        public let applied: Double
    }

    /// Highlights, Shadows, Whites and Blacks whose applied amount sits at least half a
    /// slider unit short of the request — the same half-unit the Tint caption uses, so
    /// a rounding difference never earns a line.
    ///
    /// Whites and Blacks are reported as their TONE SHELF: the solve eases the shelf,
    /// never the anchor, so the white and black points themselves still move fully.
    public static func easedToneSliders(tone: Tone, zones: Zones = Zones()) -> [Eased] {
        let engine = ToneEngine(tone: tone, zones: zones)
        let rows: [(String, Double, Double)] = [
            ("Highlights", tone.highlights, engine.effectiveHighlights),
            ("Shadows", tone.shadows, engine.effectiveShadows),
            ("Whites (tone shelf)", tone.whites, engine.effectiveWhites),
            ("Blacks (tone shelf)", tone.blacks, engine.effectiveBlacks),
        ]
        var out: [Eased] = []
        for (name, raw, effective) in rows {
            let requested = Num.clamp(raw, -100, 100)
            let applied = effective * 100
            guard abs(requested - applied) >= 0.5 else { continue }
            out.append(Eased(name: name, requested: requested, applied: applied))
        }
        return out
    }

    /// The line under the Tone sliders, or nil when every one is applied as set.
    public static func toneEasingCaption(tone: Tone, zones: Zones = Zones()) -> String? {
        let eased = easedToneSliders(tone: tone, zones: zones)
        guard !eased.isEmpty else { return nil }
        let parts = eased.map {
            "\($0.name) \(signed($0.applied)) of \(signed($0.requested))"
        }
        return "Applied here: " + parts.joined(separator: ", ")
            + " — eased so no brighter tone renders darker."
    }

    // MARK: - Grading wheels and the Colour Balance grid

    /// The engine `RenderPlan` grades through, built the way it builds it: the wheels'
    /// windows hang off the TONE stage's live anchors, so Whites and Blacks change what
    /// the grade's limiter allows.
    private static func gradeEngine(_ recipe: Recipe) -> GradeEngine {
        let tone = ToneEngine(tone: recipe.develop.tone, zones: recipe.develop.zones)
        return GradeEngine(wheels: recipe.look.wheels,
                           printerLights: recipe.look.printerLights,
                           whiteAnchorEV: tone.whiteAnchorEV,
                           blackAnchorEV: tone.blackAnchorEV)
    }

    /// Shares below this are a rounding difference, not a held-back control.
    static let scaleFloor: Double = 0.995

    /// What the Shadows/Midtones/Highlights wheels' Luminance is multiplied by: their own
    /// solve times the joint correction with Brilliance. 1 when applied as set. The
    /// Global wheel's Luminance is not zone-weighted and is not scaled.
    public static func wheelLuminanceScale(_ recipe: Recipe) -> Double {
        let g = gradeEngine(recipe)
        return g.lumScale * g.jointScale
    }

    public static func wheelLuminanceCaption(_ recipe: Recipe) -> String? {
        let scale = wheelLuminanceScale(recipe)
        guard scale < scaleFloor else { return nil }
        return "The zone wheels' Luminance is applied at \(percent(scale)) here — more "
            + "would make a brighter tone render darker."
    }

    /// What the grid's Shadows/Midtones/Highlights Brilliance rows are multiplied by.
    /// Global Brilliance is not scaled.
    public static func brillianceScale(_ recipe: Recipe) -> Double {
        gradeEngine(recipe).colorBalance.appliedBrillianceScale
    }

    public static func brillianceCaption(_ recipe: Recipe) -> String? {
        let scale = brillianceScale(recipe)
        guard scale < scaleFloor else { return nil }
        return "The zone rows are applied at \(percent(scale)) here so no brighter tone "
            + "renders darker."
    }

    // MARK: - Formatting

    /// −3.53 / +0.08: signed, two places, a true minus.
    static func ev(_ v: Double) -> String {
        let s = String(format: "%+.2f", v)
        return s.replacingOccurrences(of: "-", with: "\u{2212}")
    }

    static func magnitude(_ v: Double) -> String { String(format: "%.2f", abs(v)) }

    /// Slider units, signed and whole, with a true minus; zero has no sign.
    static func signed(_ v: Double) -> String {
        let n = Int(v.rounded())
        if n == 0 { return "0" }
        return n > 0 ? "+\(n)" : "\u{2212}\(-n)"
    }

    static func percent(_ scale: Double) -> String {
        "\(Int((Num.saturate(scale) * 100).rounded()))%"
    }
}
