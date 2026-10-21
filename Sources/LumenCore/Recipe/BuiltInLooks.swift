// BuiltInLooks.swift
// The looks Lumen ships: eight, built from the Look layer's own controls (no LUTs, no
// develop fields), so each one is an ordinary saved look that applies, blends at an
// Amount and pastes through exactly the doors a photographer's own looks use
// (`LookSubset.applied(to:)`). Lightroom ships Adobe Portrait / Landscape / Vivid /
// Vintage / B&W; this is the same idea held to fewer, better entries.
//
// Designed on six corpus frames (Sony A7 IV, Panasonic GX85 and GX80, Canon R5 and 77D,
// Fujifilm X-T10 low light) — docs/quality/lanes/WS-29/evidence/builtin-looks-*.png.
// Stored as the sparse canonical JSON the catalog's `look.subset` column holds, so the
// definitions are read by the same decoder as every saved look and cannot drift from it.

import Foundation

public struct BuiltInLook: Equatable, Sendable {
    public let name: String
    /// One line for the row's tooltip: what it does, in the photographer's words.
    public let summary: String
    /// Sparse canonical look JSON, as `CanonicalJSON.canonicalLookJSON` writes it.
    public let json: String

    /// The look, decoded through the catalog's own path.
    public func subset() throws -> LookSubset {
        try CanonicalJSON.decodeLookSubset(from: Data(json.utf8))
    }

    /// As a catalog row, so the panel's single apply door (`AppState.applyLook`) takes
    /// it unchanged. Negative ids: no catalog row ever has one, so rename and delete can
    /// never reach a built-in.
    public func row(index: Int) -> LookRow {
        LookRow(id: -Int64(index + 1), name: name, subsetJSON: json)
    }
}

public enum BuiltInLooks {
    public static let all: [BuiltInLook] = [
        BuiltInLook(name: "Natural Portrait",
                    summary: "Soft curve, a breath of warmth in the highlights, colour eased 8%. For skin.",
                    json: #"{"look":{"render":{"preset":"Soft"},"wheels":{"global":{"hue":60,"sat":0.03},"high":{"hue":70,"sat":0.04},"colorBalance":{"saturation":{"global":-8}}}}}"#),
        BuiltInLook(name: "Vivid Landscape",
                    summary: "Punchy curve with open shadows, vibrance +35. Clear and saturated, no hue shifts.",
                    json: #"{"look":{"render":{"preset":"Punchy","contrast":1.7,"skew":0.3},"wheels":{"colorBalance":{"vibrance":35,"saturation":{"global":5}}}}}"#),
        BuiltInLook(name: "Soft Matte",
                    summary: "Low contrast, lifted black, colour eased 18%.",
                    json: #"{"look":{"render":{"preset":"Soft","contrast":1.25,"blackTarget":0.8},"wheels":{"colorBalance":{"saturation":{"global":-18}}}}}"#),
        BuiltInLook(name: "Warm Film",
                    summary: "Portra 400 at 80% with fine grain.",
                    json: #"{"look":{"filmLab":{"stock":"lumen/portra400","amount":80},"grain":{"amount":15,"size":40,"roughness":50}}}"#),
        BuiltInLook(name: "Cool Cinema",
                    summary: "Film Base curve, faint teal shadows and warm highlights, vibrance −10.",
                    json: #"{"look":{"render":{"preset":"Film Base"},"wheels":{"shadows":{"hue":200,"sat":0.08},"high":{"hue":65,"sat":0.05},"colorBalance":{"vibrance":-10}}}}"#),
        BuiltInLook(name: "Faded Vintage",
                    summary: "Lifted black, green-cyan shadows, warm highlights, colour −30%, vignette and grain.",
                    json: #"{"look":{"render":{"preset":"Film Base","blackTarget":1.0},"wheels":{"shadows":{"hue":170,"sat":0.06},"high":{"hue":80,"sat":0.1},"colorBalance":{"saturation":{"global":-30}}},"vignette":-0.5,"grain":{"amount":30,"size":50,"roughness":55}}}"#),
        BuiltInLook(name: "B&W Classic",
                    summary: "Neutral black and white with a slight lift in reds and yellows; contrast 1.65.",
                    json: #"{"look":{"bw":{"enabled":true,"bands":[5,8,5,0,0,-5,0,0]},"render":{"preset":"Neutral","contrast":1.65}}}"#),
        BuiltInLook(name: "B&W High Contrast",
                    summary: "Punchy black and white, blues and skies darkened, light vignette.",
                    json: #"{"look":{"bw":{"enabled":true,"bands":[20,12,0,-5,-10,-25,-10,5]},"render":{"preset":"Punchy","contrast":1.85},"vignette":-0.25}}"#),
    ]
}
