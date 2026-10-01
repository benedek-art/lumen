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

    // MARK: - Zones (Astra AI-07)

    /// The band of input tones the Zones clamp renders as one value, placed on the
    /// strip the panel draws.
    public struct ZoneFlattening: Equatable, Sendable {
        /// The engine's own report.
        public let flattening: ToneEngine.Flattening
        /// Where the band sits on the normalized tonal axis — the strip's x axis,
        /// `ToneEngine.normalizedAxis`, at the recipe's live anchors.
        public let lowX: Double
        public let highX: Double
        /// The line under the strip.
        public let caption: String
    }

    /// Nil while the Zones register renders exactly what it asks for.
    ///
    /// No floor under the engine's report. Measured with Darks alone at the default
    /// pivots, the clamp is idle through +1.25 EV and its first band (+1.5 EV) is
    /// already 1.03 EV wide and 0.08 EV off — there is no stretch of numerical dust to
    /// hide, and a floor would be a second definition of "flattened".
    public static func zoneFlattening(tone: Tone, zones: Zones) -> ZoneFlattening? {
        let engine = ToneEngine(tone: tone, zones: zones)
        guard let f = engine.zoneFlattening() else { return nil }
        let caption = "Flattened: input \(ev(f.lowEV))…\(ev(f.highEV)) EV renders as one "
            + "tone, up to \(magnitude(f.worstEV)) EV from what the zones ask."
        return ZoneFlattening(flattening: f,
                              lowX: engine.normalizedAxis(f.lowEV),
                              highX: engine.normalizedAxis(f.highEV),
                              caption: caption)
    }

    // MARK: - Formatting

    /// −3.53 / +0.08: signed, two places, a true minus.
    static func ev(_ v: Double) -> String {
        let s = String(format: "%+.2f", v)
        return s.replacingOccurrences(of: "-", with: "\u{2212}")
    }

    static func magnitude(_ v: Double) -> String { String(format: "%.2f", abs(v)) }
}
