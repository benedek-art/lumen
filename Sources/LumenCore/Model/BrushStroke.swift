// BrushStroke.swift
// The brush stroke blob (docs/08 §8.2, §8.9): the parametric truth behind a brush
// mask component's `strokesRef: "blob:xxh64:<hash>"`. A stroke is a timestamped point
// list with pressure plus the five brush parameters in force while it was drawn —
// never a raster. Rasterization (Catmull-Rom centerline, stamped radial-falloff discs)
// lives in Image/MaskRaster.swift, so the same blob renders identically at loupe,
// export, and thumbnail resolution.
//
// Two invariants make that work:
//  · Coordinates and Size are SOURCE-NORMALIZED — x/y are fractions of the image
//    extent, Size is a diameter as a fraction of the image LONG EDGE. Storing the
//    screen pixels of §8.2's "1–4000 px" slider would change a stroke's width at
//    export resolution, and geometry edits would orphan the stroke (docs/09).
//  · The eraser is a stroke flag, not a separate component: erase strokes fold into
//    the same accumulation buffer in draw order (`A ← A·(1 − F'·s)`).
//
// Wire form is JSON here. docs/08 §8.9's shipping form is the same schema delta-encoded
// and zstd-compressed (1–30 KB, base64 in the XMP `lumen:` namespace); that packing is
// a transport detail layered on this schema, not a different schema.

import Foundation

/// One sampled point of a stroke centerline. Serialized as a compact array
/// `[x, y, pressure, t]` — a stroke carries thousands of these, and keyed objects
/// would triple the blob for no readability gain. Trailing members are optional on
/// read, so `[x, y]` from a mouse-only recorder decodes to full pressure at t = 0.
public struct BrushPoint: Codable, Equatable, Sendable {
    /// Source-normalized x, fraction of image width (0…1, may drift outside on overdraw).
    public var x: Double
    /// Source-normalized y, fraction of image height.
    public var y: Double
    /// NSEvent pressure, 0…1. Mouse and trackpad input records 1.
    public var pressure: Double
    /// Milliseconds since the first point of the stroke (docs/08's "timestamped point lists").
    public var t: Int

    public init(x: Double, y: Double, pressure: Double = 1, t: Int = 0) {
        self.x = x
        self.y = y
        self.pressure = pressure
        self.t = t
    }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        let px = try c.decode(Double.self)
        let py = try c.decode(Double.self)
        var pp: Double = 1
        var pt: Int = 0
        if !c.isAtEnd { pp = try c.decode(Double.self) }
        if !c.isAtEnd { pt = try c.decode(Int.self) }
        self.x = px
        self.y = py
        self.pressure = pp
        self.t = pt
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x)
        try c.encode(y)
        try c.encode(pressure)
        try c.encode(t)
    }
}

/// One stroke: its centerline plus the brush state it was drawn with. Defaults match
/// docs/08 §8.2's control defaults (Feather 50, Flow 100, Density 100, Automask off).
public struct BrushStroke: Codable, Equatable, Sendable {
    /// Centerline samples in source-normalized coordinates, in draw order.
    public var points: [BrushPoint]
    /// Stamp diameter as a fraction of the image long edge (§8.2's "px on-screen" is
    /// the UI unit only; the stored unit is resolution-independent).
    public var size: Double
    /// 0…100 hardness falloff of the stamp; hardness `h = 1 − feather/100`.
    public var feather: Double
    /// 1…100 per-stamp deposition rate.
    public var flow: Double
    /// 0…100 opacity ceiling — never exceeded regardless of how many passes cross a pixel.
    public var density: Double
    /// Eraser stroke: composites multiplicatively toward zero instead of toward density.
    public var erase: Bool
    /// Per-stamp OKLab color-similarity gate against the stamp-center sample (§8.2 "Automask").
    public var automask: Bool

    /// Default size: 5% of the long edge — a stand-in for §8.2's 200 px default, which
    /// is a screen measurement and therefore not expressible in the stored unit.
    public static let defaultSize: Double = 0.05

    public init(points: [BrushPoint] = [],
                size: Double = BrushStroke.defaultSize,
                feather: Double = 50,
                flow: Double = 100,
                density: Double = 100,
                erase: Bool = false,
                automask: Bool = false) {
        self.points = points
        self.size = size
        self.feather = feather
        self.flow = flow
        self.density = density
        self.erase = erase
        self.automask = automask
    }

    private enum CodingKeys: String, CodingKey {
        case points, size, feather, flow, density, erase, automask
    }

    /// Every scalar has a default, so a truncated or older blob decodes rather than
    /// throwing — a stroke list is user work, and losing it to a missing key is not
    /// an acceptable failure mode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.points = try c.decodeIfPresent([BrushPoint].self, forKey: .points) ?? []
        self.size = try c.decodeIfPresent(Double.self, forKey: .size) ?? BrushStroke.defaultSize
        self.feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? 50
        self.flow = try c.decodeIfPresent(Double.self, forKey: .flow) ?? 100
        self.density = try c.decodeIfPresent(Double.self, forKey: .density) ?? 100
        self.erase = try c.decodeIfPresent(Bool.self, forKey: .erase) ?? false
        self.automask = try c.decodeIfPresent(Bool.self, forKey: .automask) ?? false
    }

    /// Sparse encode (docs/15 rule 2): the two flags only appear when set.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(points, forKey: .points)
        try c.encode(size, forKey: .size)
        try c.encode(feather, forKey: .feather)
        try c.encode(flow, forKey: .flow)
        try c.encode(density, forKey: .density)
        if erase { try c.encode(erase, forKey: .erase) }
        if automask { try c.encode(automask, forKey: .automask) }
    }
}

/// The whole blob: every stroke of one brush component, in draw order, plus the schema
/// version so a format change is self-describing rather than silently misread.
public struct BrushStrokeSet: Codable, Equatable, Sendable {

    /// Version written by this build. Bumped only for a wire-incompatible change.
    public static let schemaVersion: Int = 1

    public var version: Int
    public var strokes: [BrushStroke]

    public init(strokes: [BrushStroke] = [], version: Int = BrushStrokeSet.schemaVersion) {
        self.strokes = strokes
        self.version = version
    }

    private enum CodingKeys: String, CodingKey {
        case version, strokes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decodeIfPresent(Int.self, forKey: .version) ?? BrushStrokeSet.schemaVersion
        self.strokes = try c.decodeIfPresent([BrushStroke].self, forKey: .strokes) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(strokes, forKey: .strokes)
    }

    /// A future version decodes best-effort (unknown keys are ignored, missing keys
    /// take defaults); this reports whether the payload is one this build authored.
    public var isCurrentVersion: Bool { version == BrushStrokeSet.schemaVersion }

    // MARK: - Blob codec

    /// The blob payload. Keys are sorted so the same stroke list always produces the
    /// same bytes — content addressing depends on it.
    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Decode a blob payload.
    public static func decode(_ data: Data) throws -> BrushStrokeSet {
        try JSONDecoder().decode(BrushStrokeSet.self, from: data)
    }

    /// Decode without throwing — the read-path posture of docs/15 §15.7: a corrupt
    /// blob yields an empty stroke set (an empty mask with a badge), never a crash.
    public static func decodeOrEmpty(_ data: Data) -> BrushStrokeSet {
        (try? decode(data)) ?? BrushStrokeSet()
    }

    /// The content-addressed reference a `MaskComponent.strokesRef` stores:
    /// `blob:xxh64:<16 hex>` over the canonical payload bytes (Recipe/Fingerprint.swift
    /// records why the engine ships XXH64 where docs/15 names xxh3).
    public func blobRef() throws -> String {
        let bytes = [UInt8](try encode())
        return "blob:xxh64:" + String(format: "%016llx", XXH64.hash(bytes))
    }

    /// The same reference for an already-serialized payload.
    public static func blobRef(for data: Data) -> String {
        "blob:xxh64:" + String(format: "%016llx", XXH64.hash([UInt8](data)))
    }
}
