// RecipeMasks.swift
// The mask model (D28/D29): a mask is an ordered stack of components combined with
// add / subtract / intersect, each individually invertible and individually scaled;
// the mask carries one set of local adjustments applied through its combined alpha.
// Format authority: docs/15-catalog.md §15.4; semantics: docs/08-spec-masking.md.
//
// Components are serialized as flat objects ({"op","kind","amount", …kind keys}) to
// match the wire format. In Swift they are one struct with optional kind-specific
// fields; `validate()` checks the fields required by each kind. A typed-enum
// refactor is deliberate future work once the Mac toolchain can police it.

import Foundation

public struct Mask: Codable, Equatable, Sendable {
    public var id: String              // UUID string
    public var name: String
    public var enabled: Bool
    public var amount: Double          // 0…200 multiplier over the whole adjust set (D29)
    public var components: [MaskComponent]
    public var refine: MaskRefine
    public var adjust: LocalAdjust

    public init(id: String = UUID().uuidString, name: String = "",
                enabled: Bool = true, amount: Double = 100,
                components: [MaskComponent] = [],
                refine: MaskRefine = MaskRefine(),
                adjust: LocalAdjust = LocalAdjust()) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.amount = amount
        self.components = components
        self.refine = refine
        self.adjust = adjust
    }

    /// The same mask with everything that is only a label removed. Renaming a mask
    /// must not be a reason to re-render 45 megapixels.
    public var withoutCosmetics: Mask {
        var copy = self
        copy.name = ""
        return copy
    }
}

public enum MaskOp: String, Codable, Sendable {
    case add, subtract, intersect
}

public enum MaskKind: String, Codable, Sendable {
    case brush
    case linear
    case radial
    case lumaRange
    case colorRange
    case similarity        // U-Point-style chroma/luma similarity point (docs/08)
    case similarityLine    // gradient gated by color similarity
    case aiSubject
    case aiSky
    case aiBackground
    case aiObject
    case aiPerson
    case aiLandscape
    case depthRange

    /// True when rasterizing this kind needs the picture, not just geometry.
    ///
    /// Stated once, here, because a renderer that fails to supply the stage input does
    /// not get an error from these components — they return an empty plane, the mask
    /// silently selects nothing, and `validationError()` has nothing to report because
    /// the recipe is perfectly valid. That is exactly how the GPU path shipped with
    /// Luma Range, Colour Range and both Similarity kinds doing nothing at all.
    public var readsSourceImage: Bool {
        switch self {
        case .brush, .linear, .radial:
            return false
        case .lumaRange, .colorRange, .similarity, .similarityLine:
            return true
        case .aiSubject, .aiSky, .aiBackground, .aiObject, .aiPerson, .aiLandscape,
             .depthRange:
            // These read a cached matte rather than the picture. Listed explicitly
            // rather than caught by a `default`, so adding a kind is a compile error
            // here instead of a silently empty mask.
            return false
        }
    }

    /// True when this kind needs an AI matte supplied alongside it. Nothing generates
    /// those yet, which is why the panel files them under "requires a model".
    public var needsMatte: Bool {
        switch self {
        case .brush, .linear, .radial, .lumaRange, .colorRange, .similarity,
             .similarityLine:
            return false
        case .aiSubject, .aiSky, .aiBackground, .aiObject, .aiPerson, .aiLandscape,
             .depthRange:
            return true
        }
    }
}

public struct MaskComponent: Codable, Equatable, Sendable {
    public var op: MaskOp
    public var kind: MaskKind
    public var amount: Double          // 0…100 per-component contribution (D29)
    public var invert: Bool

    // brush: stroke vectors in a content-addressed blob
    public var strokesRef: String?

    // linear gradient: [x0,y0,x1,y1] in source-normalized coords (docs/09 invariant:
    // masks live in source coordinates and reproject through geometry)
    public var line: [Double]?

    // radial: center + radii + rotation, source-normalized
    public var center: [Double]?       // [cx, cy]
    public var radii: [Double]?        // [rx, ry]
    public var rotation: Double?       // degrees
    public var feather: Double?        // radial feather 0…100

    // luma range: band with soft shoulders
    public var lo: Double?
    public var hi: Double?
    public var smooth: Double?

    // color range / similarity: sampled references + selectivity
    public var samples: [[Double]]?    // sampled working-space RGB triples
    public var rangeAmount: Double?    // color-range refine 0…100
    public var chromaSel: Double?      // similarity chroma selectivity 0…100
    public var lumaSel: Double?        // similarity luma selectivity 0…100

    // AI components
    public var model: String?          // model id used at generation, e.g. "skyseg/1.3"
    public var prompt: [[Double]]?     // click/box prompts, source-normalized
    public var personParts: [String]?  // aiPerson: which parts (faceSkin, hair, …)
    public var classes: [String]?      // aiLandscape: which classes (sky, water, …)

    // depth range
    public var depthLo: Double?
    public var depthHi: Double?

    public init(op: MaskOp, kind: MaskKind, amount: Double = 100, invert: Bool = false) {
        self.op = op
        self.kind = kind
        self.amount = amount
        self.invert = invert
    }

    /// Field requirements per kind. Returns a problem description or nil if valid.
    public func validationError() -> String? {
        switch kind {
        case .brush:
            if strokesRef == nil { return "brush component missing strokesRef" }
        case .linear:
            if line?.count != 4 { return "linear component needs line [x0,y0,x1,y1]" }
        case .radial:
            if center?.count != 2 || radii?.count != 2 {
                return "radial component needs center [cx,cy] and radii [rx,ry]"
            }
        case .lumaRange:
            guard let lo, let hi else { return "lumaRange needs lo/hi" }
            if !(lo <= hi) { return "lumaRange lo must be <= hi" }
        case .colorRange:
            if samples?.isEmpty ?? true { return "colorRange needs at least one sample" }
        case .similarity, .similarityLine:
            if samples?.isEmpty ?? true { return "similarity needs a sampled reference" }
            if kind == .similarityLine && line?.count != 4 {
                return "similarityLine needs line [x0,y0,x1,y1]"
            }
        case .aiObject:
            if prompt?.isEmpty ?? true { return "aiObject needs at least one prompt point/box" }
        case .depthRange:
            guard let depthLo, let depthHi else { return "depthRange needs depthLo/depthHi" }
            if !(depthLo <= depthHi) { return "depthRange lo must be <= hi" }
        case .aiSubject, .aiSky, .aiBackground, .aiPerson, .aiLandscape:
            break // one-click kinds; model id recorded at generation time
        }
        return nil
    }
}

/// Mask refinement chain (docs/08 §8.5). Wire-name mapping to the doc's controls:
/// `feather` = guided-filter edge-aware refinement ("Refine"), `edge` = boundary
/// shift ("Edge"), `blur` = gaussian softening ("Feather"), `levels*` = the density
/// remap ("Levels"). The wire names follow docs/15 §15.4's example.
public struct MaskRefine: Codable, Equatable, Sendable {
    public var feather: Double     // 0…100 guided-filter edge-aware refinement
    public var edge: Double        // −50…+50 boundary shift
    public var blur: Double        // 0…100 gaussian softness
    public var levelsLo: Double    // 0…100 density remap floor
    public var levelsHi: Double    // 0…100 density remap ceiling
    public var levelsGamma: Double // 0.2…5.0 density gamma

    public init(feather: Double = 0, edge: Double = 0, blur: Double = 0,
                levelsLo: Double = 0, levelsHi: Double = 100, levelsGamma: Double = 1) {
        self.feather = feather
        self.edge = edge
        self.blur = blur
        self.levelsLo = levelsLo
        self.levelsHi = levelsHi
        self.levelsGamma = levelsGamma
    }
}

/// The local adjustment set (docs/08 §local): the global subset applied through the
/// mask alpha — including the local point curve and local grading wheels (D29),
/// the two tools Lightroom Classic still lacks in 2026.
public struct LocalAdjust: Codable, Equatable, Sendable {
    public var exposure: Double
    public var contrast: Double
    public var highlights: Double
    public var shadows: Double
    public var whites: Double
    public var blacks: Double
    public var temp: Double        // relative WB shift
    public var tint: Double
    public var hue: Double         // −180…+180 hue shift (docs/08 §8.4)
    public var sat: Double
    public var vibrance: Double    // skin-protected saturation (docs/08 §8.4)
    public var texture: Double
    public var clarity: Double
    public var dehaze: Double
    public var sharpness: Double   // negative = blur
    public var noise: Double       // classical luma NR lift (docs/07)
    public var noiseChroma: Double // chroma NR lift (disclosure split, docs/08 §8.4)
    public var moire: Double
    public var defringe: Double
    public var grainAmount: Double
    public var colorTint: [Double]?      // colorize swatch, working-space RGB; nil = off
    public var colorTintStrength: Double // 0…100
    public var pointColors: [PointColor] // local Point Color swatches (docs/08 §8.4)
    public var curve: CurveSet?    // local point curve (D29)
    public var wheels: GradingWheels? // local grading wheels (D29)

    public init(exposure: Double = 0, contrast: Double = 0, highlights: Double = 0,
                shadows: Double = 0, whites: Double = 0, blacks: Double = 0,
                temp: Double = 0, tint: Double = 0, hue: Double = 0, sat: Double = 0,
                vibrance: Double = 0, texture: Double = 0, clarity: Double = 0,
                dehaze: Double = 0, sharpness: Double = 0, noise: Double = 0,
                noiseChroma: Double = 0, moire: Double = 0, defringe: Double = 0,
                grainAmount: Double = 0, colorTint: [Double]? = nil,
                colorTintStrength: Double = 0, pointColors: [PointColor] = [],
                curve: CurveSet? = nil, wheels: GradingWheels? = nil) {
        self.exposure = exposure
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
        self.whites = whites
        self.blacks = blacks
        self.temp = temp
        self.tint = tint
        self.hue = hue
        self.sat = sat
        self.vibrance = vibrance
        self.texture = texture
        self.clarity = clarity
        self.dehaze = dehaze
        self.sharpness = sharpness
        self.noise = noise
        self.noiseChroma = noiseChroma
        self.moire = moire
        self.defringe = defringe
        self.grainAmount = grainAmount
        self.colorTint = colorTint
        self.colorTintStrength = colorTintStrength
        self.pointColors = pointColors
        self.curve = curve
        self.wheels = wheels
    }
}
