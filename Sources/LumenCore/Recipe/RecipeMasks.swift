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
    /// Whole-mask invert (docs/08 §8.1: "Invert mask — whole-mask, after combine").
    ///
    /// Distinct from `MaskComponent.invert`, which flips ONE component before the
    /// fold. This flips the folded alpha of the whole stack, and it does so BEFORE
    /// the refinement chain, so Refine still snaps to the picture's edges, Edge Shift
    /// still grows the boundary of what is now selected, and Levels still remaps the
    /// density the user can see. Inverting after the chain would make Edge Shift run
    /// backwards, which is the one ordering a photographer would notice.
    public var invert: Bool
    public var amount: Double          // 0…200 multiplier over the whole adjust set (D29)
    public var components: [MaskComponent]
    public var refine: MaskRefine
    public var adjust: LocalAdjust
    /// How this mask's result combines with the picture underneath. See `MaskBlend`.
    public var blend: MaskBlend

    public init(id: String = UUID().uuidString, name: String = "",
                enabled: Bool = true, invert: Bool = false, amount: Double = 100,
                components: [MaskComponent] = [],
                refine: MaskRefine = MaskRefine(),
                adjust: LocalAdjust = LocalAdjust(),
                blend: MaskBlend = .normal) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.invert = invert
        self.amount = amount
        self.components = components
        self.refine = refine
        self.adjust = adjust
        self.blend = blend
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, enabled, invert, amount, components, refine, adjust, blend
    }

    /// Every field has a default, so a mask written by a build that did not have
    /// `invert` — or a hand-edited sidecar missing a key — still decodes into a mask
    /// instead of failing the whole recipe. A mask is user work; losing an hour of it
    /// to one absent boolean is not an acceptable failure mode, and the sparse form
    /// this format uses prunes at the recipe level, never inside a mask.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.invert = try c.decodeIfPresent(Bool.self, forKey: .invert) ?? false
        self.amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 100
        self.components = try c.decodeIfPresent([MaskComponent].self,
                                                forKey: .components) ?? []
        self.refine = try c.decodeIfPresent(MaskRefine.self, forKey: .refine)
            ?? MaskRefine()
        self.adjust = try c.decodeIfPresent(LocalAdjust.self, forKey: .adjust)
            ?? LocalAdjust()
        self.blend = try c.decodeIfPresent(MaskBlend.self, forKey: .blend) ?? .normal
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

/// How a mask's adjusted pixels combine with the ones underneath (docs/36 §3, bet 1).
///
/// Photoshop, Affinity and ON1 give a layer a blend mode; Capture One does not, and it
/// has been an open request there for years. No raw editor with this much depth per
/// mask has one, and the reason to want it is specific rather than general: **a mask in
/// Luminosity mode moves tone and leaves colour exactly alone**, which is the whole of
/// dodging and burning skin without shifting it.
///
/// THREE MODES, NOT SIX, AND THE MISSING THREE ARE A HONESTY PROBLEM RATHER THAN A
/// SCOPE ONE. Multiply, Screen and Soft Light are defined on a display-referred [0,1]
/// domain; the local stage is scene-referred, where "1" is not white and values run
/// past it. Shipping them here would give three controls whose behaviour did not match
/// the name every other application has taught. Normal, Luminosity and Colour are
/// exactly the three that are well defined on scene-linear values — each is a
/// luminance-ratio rescale, which is a pure operation at any exposure.
///
/// Both renderers implement this in `applyLocalBlend`, once, so the CPU reference and
/// the GPU path cannot disagree about it.
public enum MaskBlend: String, Codable, Sendable, CaseIterable {
    /// The adjusted pixel, as computed. What every mask did before this existed.
    case normal
    /// The adjusted pixel's BRIGHTNESS, over the original's colour.
    case luminosity
    /// The adjusted pixel's COLOUR, over the original's brightness.
    case color

    public var label: String {
        switch self {
        case .normal: return "Normal"
        case .luminosity: return "Brightness only"
        case .color: return "Colour only"
        }
    }

    /// One line each, for the control that offers them. Says what is LEFT ALONE, which
    /// is the half a photographer is choosing on.
    public var explanation: String {
        switch self {
        case .normal: return "The whole edit, tone and colour together"
        case .luminosity: return "Moves brightness and leaves colour exactly as it was"
        case .color: return "Moves colour and leaves brightness exactly as it was"
        }
    }
}

/// Which end of the tone scale a luminosity component selects (docs/36 §3, bet 2).
///
/// Tony Kuyper's series, the thing Photoshop users buy Lumenzia to generate: a set of
/// SELF-FEATHERING selections that are smooth functions of the luminance channel rather
/// than bands with edges. Lights n is `L^n`, Darks n is `(1−L)^n`, and each higher level
/// is the previous one intersected with the first — which is why the family tightens
/// toward its end of the scale without ever acquiring a boundary. No raw editor ships
/// this natively.
public enum LuminositySeries: String, Codable, Sendable, CaseIterable {
    case lights
    case darks
    case midtones

    public var label: String {
        switch self {
        case .lights: return "Lights"
        case .darks: return "Darks"
        case .midtones: return "Midtones"
        }
    }

    /// One line, for the picker tile. Not a tooltip and not a paragraph: the roster is
    /// chosen by recognition, and these three need the one word that distinguishes them.
    public var explanation: String {
        switch self {
        case .lights: return "The bright end, weighted — brighter pixels selected more"
        case .darks: return "The dark end, weighted — darker pixels selected more"
        case .midtones: return "Everything that is neither, peaking at middle grey"
        }
    }
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
    /// Another mask on this photograph, folded into this one (docs/36 §3, bet 3).
    ///
    /// Component algebra was only ever available INSIDE one mask, so "Sky ∩ Person"
    /// meant rebuilding both stacks in a third mask and keeping three copies in step by
    /// hand. Photoshop loads a selection from any layer mask; Capture One's Combine
    /// Masks merges sources into one layer rather than referencing one. Neither gives
    /// you a live reference — change the Sky mask and the intersection follows.
    case maskRef
    /// A self-feathering luminosity selection — Kuyper's series (docs/36 §3, bet 2).
    ///
    /// It is deliberately NOT a band. A band is a plateau with two shoulders and it
    /// cannot express `L^n`, which is the whole point of the family: there is no
    /// boundary anywhere in it to feather, at any level. It reads the same six channels
    /// and the same fixed −10…+4 EV axis Brightness Range reads, so the two agree about
    /// what "bright" means.
    case luminosity

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
        case .lumaRange, .colorRange, .similarity, .similarityLine, .luminosity:
            return true
        case .aiSubject, .aiSky, .aiBackground, .aiObject, .aiPerson, .aiLandscape,
             .depthRange:
            // These read a cached matte rather than the picture. Listed explicitly
            // rather than caught by a `default`, so adding a kind is a compile error
            // here instead of a silently empty mask.
            return false
        case .maskRef:
            // It reads whatever the mask it names reads, and `combine` resolves that by
            // evaluating the referenced stack — so the answer for THIS component alone
            // is no. `maskSource` asks the whole recipe, not one component, which is
            // why that is the right answer rather than a convenient one.
            return false
        }
    }

    /// True when this kind needs an AI matte supplied alongside it.
    public var needsMatte: Bool { matteProvider != .none }

    /// WHERE that matte can come from, which is not the same question and used to be
    /// conflated with it — the panel filed all seven under "requires a model" when
    /// three of them are served by an OS framework that needs no download at all.
    public enum MatteProvider: String, Sendable {
        /// Rasterized from geometry or from the picture; no matte involved.
        case none
        /// Apple's Vision framework: on-device, no download, no bundled weights.
        case vision
        /// A Core ML model that is not bundled. These render empty and say so.
        case model
    }

    public var matteProvider: MatteProvider {
        switch self {
        case .brush, .linear, .radial, .lumaRange, .colorRange, .similarity,
             .similarityLine, .maskRef, .luminosity:
            // A reference needs no matte of its OWN. Whether it ends up needing one is a
            // property of the mask it names, and `VisionMattes.kinds(in:)` walks the
            // whole recipe, so that question is already answered where it belongs.
            return .none
        case .aiSubject, .aiBackground, .aiPerson:
            // Foreground instances and person instances both come out of Vision.
            // Background is deliberately the COMPLEMENT of the subject rather than a
            // second model: two models can disagree, and a complement cannot
            // (docs/08 §8.3).
            return .vision
        case .aiSky, .aiObject, .aiLandscape, .depthRange:
            // Sky segmentation, SAM and Depth Anything. None is bundled; the panel
            // says so rather than implying a pass that is not running.
            return .model
        }
    }
}

/// Which signal a Brightness Range measures (docs/36 §3, bet 2).
///
/// The whole Photoshop luminosity-mask tradition — Kuyper's series, and the panels
/// people buy to generate it — is built on CHANNELS, not on luminance alone. Selecting
/// on the red channel finds skin and sunset cloud that a luma band cannot separate;
/// selecting on Min finds where every channel is dark, which is the mask for recovering
/// a shadow without touching a colour cast. ON1 ships luminosity masks; we shipped one
/// luma band.
///
/// EVERY CHANNEL HERE IS A SCENE-LINEAR VALUE ON THE SAME FIXED −10…+4 EV AXIS, which is
/// what lets one band control serve all six and lets a band mean the same thing when the
/// channel is changed under it. Saturation is deliberately absent: it is a ratio in
/// [0,1], not a scene-linear quantity, so it would need its own axis and the handles
/// would silently change units — and a control whose units move is the defect this
/// rebuild is for.
public enum MaskChannel: String, Codable, Sendable, CaseIterable {
    case luma, red, green, blue, max, min

    public var label: String {
        switch self {
        case .luma: return "Brightness"
        case .red: return "Red"
        case .green: return "Green"
        case .blue: return "Blue"
        case .max: return "Brightest channel"
        case .min: return "Darkest channel"
        }
    }

    /// The scalar this channel measures, in scene-linear units.
    public func value(_ c: RGB, weights: RGB) -> Double {
        switch self {
        case .luma: return weights.r * c.r + weights.g * c.g + weights.b * c.b
        case .red: return c.r
        case .green: return c.g
        case .blue: return c.b
        case .max: return Swift.max(c.r, Swift.max(c.g, c.b))
        case .min: return Swift.min(c.r, Swift.min(c.g, c.b))
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
    /// Which signal the band measures. Absent means `.luma`, which is what every recipe
    /// written before this field means, so a band keeps selecting what it selected.
    public var channel: MaskChannel?

    // color range / similarity: sampled references + selectivity
    public var samples: [[Double]]?    // sampled working-space RGB triples
    /// Similarity POINTS — the spatial half of the U-Point mechanic (docs/08 §8.2).
    ///
    /// One entry per sample, by index: `[x, y, radius, sign]`, all source-normalized,
    /// `radius` as a fraction of the LONG edge (the unit `BrushStroke.size` uses, so a
    /// point keeps its reach through a crop), `sign` positive to extend the selection
    /// and negative to carve it back.
    ///
    /// ABSENT means the gate evaluates over the whole frame, which is what shipped and
    /// what every existing recipe means. So the field is additive in the strict sense:
    /// a recipe written before it renders identically after it. Present, it is what
    /// makes "Colour Pick" the tool it is named after rather than a Gaussian colour
    /// range — DxO's control point is similarity WITHIN A RADIUS, with negative points,
    /// and we shipped only the similarity.
    public var points: [[Double]]?
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

    /// `maskRef`: the id of the mask this component folds in.
    public var maskRef: String?

    // luminosity series
    /// Which end of the tone scale. Absent means `.lights`.
    public var series: LuminositySeries?
    /// How far down the series, 1…5 — and CONTINUOUS rather than the five discrete
    /// steps Photoshop's channel arithmetic forces, because `L^2.5` is perfectly well
    /// defined and just as self-feathering. Dragging it is the generator: no five
    /// pre-baked channels, no panel to buy, nothing in the mask list you did not ask
    /// for. Absent means 1, which is the plain luminance channel.
    public var level: Double?

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
        case .maskRef:
            guard let maskRef, !maskRef.isEmpty else {
                return "this component needs a mask to point at"
            }
        case .luminosity:
            // Both fields default rather than fail: `series` absent is Lights and
            // `level` absent is 1, which is the plain luminance channel and a
            // perfectly good selection. A kind whose default state selects something
            // does not need the photographer to fill a form in before it works.
            break
        case .aiSubject, .aiSky, .aiBackground, .aiPerson, .aiLandscape:
            break // one-click kinds; model id recorded at generation time
        }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case op, kind, amount, invert, strokesRef, line, center, radii, rotation,
             feather, lo, hi, smooth, channel, samples, points, rangeAmount, chromaSel, lumaSel,
             model, prompt, personParts, classes, depthLo, depthHi, maskRef,
             series, level
    }

    /// Tolerant of an absent key, including the two that say what the component IS.
    /// `op` and `kind` have no default in the memberwise initializer above, and the pair
    /// chosen here is the one that cannot invent a selection: a `brush` carrying no
    /// strokes rasterizes empty — that is what an unpainted component already is — and
    /// `add` folds an empty plane in as `max(acc, 0)`, which is the identity. `intersect`
    /// would have zeroed the whole stack. `validationError()` then reports the component
    /// as a brush with no strokesRef, so it is visible rather than merely harmless.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.op = try c.decodeIfPresent(MaskOp.self, forKey: .op) ?? .add
        self.kind = try c.decodeIfPresent(MaskKind.self, forKey: .kind) ?? .brush
        self.amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 100
        self.invert = try c.decodeIfPresent(Bool.self, forKey: .invert) ?? false
        self.strokesRef = try c.decodeIfPresent(String.self, forKey: .strokesRef)
        self.line = try c.decodeIfPresent([Double].self, forKey: .line)
        self.center = try c.decodeIfPresent([Double].self, forKey: .center)
        self.radii = try c.decodeIfPresent([Double].self, forKey: .radii)
        self.rotation = try c.decodeIfPresent(Double.self, forKey: .rotation)
        self.feather = try c.decodeIfPresent(Double.self, forKey: .feather)
        self.lo = try c.decodeIfPresent(Double.self, forKey: .lo)
        self.hi = try c.decodeIfPresent(Double.self, forKey: .hi)
        self.smooth = try c.decodeIfPresent(Double.self, forKey: .smooth)
        self.channel = try c.decodeIfPresent(MaskChannel.self, forKey: .channel)
        self.samples = try c.decodeIfPresent([[Double]].self, forKey: .samples)
        self.points = try c.decodeIfPresent([[Double]].self, forKey: .points)
        self.rangeAmount = try c.decodeIfPresent(Double.self, forKey: .rangeAmount)
        self.chromaSel = try c.decodeIfPresent(Double.self, forKey: .chromaSel)
        self.lumaSel = try c.decodeIfPresent(Double.self, forKey: .lumaSel)
        self.model = try c.decodeIfPresent(String.self, forKey: .model)
        self.prompt = try c.decodeIfPresent([[Double]].self, forKey: .prompt)
        self.personParts = try c.decodeIfPresent([String].self, forKey: .personParts)
        self.classes = try c.decodeIfPresent([String].self, forKey: .classes)
        self.depthLo = try c.decodeIfPresent(Double.self, forKey: .depthLo)
        self.depthHi = try c.decodeIfPresent(Double.self, forKey: .depthHi)
        self.maskRef = try c.decodeIfPresent(String.self, forKey: .maskRef)
        self.series = try c.decodeIfPresent(LuminositySeries.self, forKey: .series)
        self.level = try c.decodeIfPresent(Double.self, forKey: .level)
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

    private enum CodingKeys: String, CodingKey {
        case feather, edge, blur, levelsLo, levelsHi, levelsGamma
    }

    /// Tolerant of a recipe written before any of these keys existed: each falls
    /// back to the default in the memberwise initializer above. See RecipeDecoding.swift.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? 0
        self.edge = try c.decodeIfPresent(Double.self, forKey: .edge) ?? 0
        self.blur = try c.decodeIfPresent(Double.self, forKey: .blur) ?? 0
        self.levelsLo = try c.decodeIfPresent(Double.self, forKey: .levelsLo) ?? 0
        self.levelsHi = try c.decodeIfPresent(Double.self, forKey: .levelsHi) ?? 100
        self.levelsGamma = try c.decodeIfPresent(Double.self, forKey: .levelsGamma) ?? 1
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
    /// ABSOLUTE white balance for this mask, in the same units the global row uses:
    /// Kelvin 2000…50000 and tint −150…+150. nil — the default, and what every recipe
    /// written before this field decodes to — leaves `temp`/`tint` in charge.
    ///
    /// Two spellings of one control, never two stacked controls. When `kelvin` is set
    /// the relative shift is IGNORED for white balance, because a mask carrying both a
    /// "+30 warmer" and a "5600 K" would be the owner's two-inverts complaint in a new
    /// costume. The panel presents it as a unit switch on one row.
    ///
    /// What "absolute" is measured from is the only interesting question here, and the
    /// answer is the neutral the picture is already balanced TO when the local stage
    /// runs — `develop.raw.temp` when it is set, the file's own as-shot neutral when it
    /// is not. So 5600 K on a mask means "this region is lit at 5600 K", and it renders
    /// the same whatever the global row says, which is the property that makes it worth
    /// having: a window mask stays correct when the global balance is dragged.
    public var kelvin: Double?
    public var kelvinTint: Double?
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
                temp: Double = 0, tint: Double = 0,
                kelvin: Double? = nil, kelvinTint: Double? = nil,
                hue: Double = 0, sat: Double = 0,
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
        self.kelvin = kelvin
        self.kelvinTint = kelvinTint
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

    private enum CodingKeys: String, CodingKey {
        case exposure, contrast, highlights, shadows, whites, blacks, temp, tint,
             kelvin, kelvinTint,
             hue, sat, vibrance, texture, clarity, dehaze, sharpness, noise,
             noiseChroma, moire, defringe, grainAmount, colorTint, colorTintStrength,
             pointColors, curve, wheels
    }

    /// Tolerant of a recipe written before any of these keys existed: each falls
    /// back to the default in the memberwise initializer above. See RecipeDecoding.swift.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        self.contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        self.highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        self.shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        self.whites = try c.decodeIfPresent(Double.self, forKey: .whites) ?? 0
        self.blacks = try c.decodeIfPresent(Double.self, forKey: .blacks) ?? 0
        self.temp = try c.decodeIfPresent(Double.self, forKey: .temp) ?? 0
        self.tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        self.kelvin = try c.decodeIfPresent(Double.self, forKey: .kelvin)
        self.kelvinTint = try c.decodeIfPresent(Double.self, forKey: .kelvinTint)
        self.hue = try c.decodeIfPresent(Double.self, forKey: .hue) ?? 0
        self.sat = try c.decodeIfPresent(Double.self, forKey: .sat) ?? 0
        self.vibrance = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0
        self.texture = try c.decodeIfPresent(Double.self, forKey: .texture) ?? 0
        self.clarity = try c.decodeIfPresent(Double.self, forKey: .clarity) ?? 0
        self.dehaze = try c.decodeIfPresent(Double.self, forKey: .dehaze) ?? 0
        self.sharpness = try c.decodeIfPresent(Double.self, forKey: .sharpness) ?? 0
        self.noise = try c.decodeIfPresent(Double.self, forKey: .noise) ?? 0
        self.noiseChroma = try c.decodeIfPresent(Double.self, forKey: .noiseChroma) ?? 0
        self.moire = try c.decodeIfPresent(Double.self, forKey: .moire) ?? 0
        self.defringe = try c.decodeIfPresent(Double.self, forKey: .defringe) ?? 0
        self.grainAmount = try c.decodeIfPresent(Double.self, forKey: .grainAmount) ?? 0
        self.colorTint = try c.decodeIfPresent([Double].self, forKey: .colorTint)
        self.colorTintStrength = try c.decodeIfPresent(Double.self, forKey: .colorTintStrength)
            ?? 0
        self.pointColors = try c.decodeIfPresent([PointColor].self, forKey: .pointColors)
            ?? []
        self.curve = try c.decodeIfPresent(CurveSet.self, forKey: .curve)
        self.wheels = try c.decodeIfPresent(GradingWheels.self, forKey: .wheels)
    }
}

// MARK: - What a delivered file needs before its brush masking can be honoured

/// The blob references a recipe's masking will actually ask the rasterizer for, and
/// what to say when they cannot be produced.
///
/// Batch export used to build its jobs from a memory-only stroke cache, filled by a
/// detached task at catalog open. An export that raced that load — or that hit a blob
/// which could not be read at all, a catalog copied without its blob store, a recipe
/// arriving from another machine — rasterized every brush component EMPTY and wrote the
/// file anyway, with nothing in the file or beside it to say the masking was missing.
/// That is the `.lrcat-data` black-mask failure docs/08 §8.7 exists to prevent, and it
/// is worse than a refusal precisely because the photographer cannot see it: the frame
/// looks like a frame.
///
/// The walk lives here rather than in the app layer because it is a rule about a
/// recipe — which blobs the render will ask for, in what order, without duplicates —
/// and because the app layer has no tests to state it in.
public enum BrushStrokes {

    /// Every brush blob reference this recipe's masking depends on, in stack order and
    /// deduplicated.
    ///
    /// Disabled masks are excluded because `RenderPlan` excludes them: refusing to
    /// deliver a file over a mask the photographer has already switched off would be a
    /// refusal with no picture behind it. A brush component carrying no reference is
    /// not a missing blob either — it is a component nobody has painted into yet, and
    /// it rasterizes empty because that is what it is.
    public static func references(in recipe: Recipe) -> [String] {
        var out: [String] = []
        for mask in recipe.masks where mask.enabled {
            for component in mask.components where component.kind == .brush {
                guard let ref = component.strokesRef, !ref.isEmpty,
                      !out.contains(ref) else { continue }
                out.append(ref)
            }
        }
        return out
    }

    /// The references `isResolved` cannot account for, in the same order.
    ///
    /// The predicate is passed in because reading a blob is the app's business — it
    /// owns the session cache and the blob store — while deciding WHICH components have
    /// to be asked about is this rule. A component with no reference is never put to
    /// the predicate: "no strokes yet" and "the bytes could not be read" are the two
    /// cases this whole enum exists to keep apart.
    ///
    /// Asked once per REFERENCE, not once per component. The predicate reaches the disk
    /// on a miss, and two masks sharing one blob — which is what subtracting the same
    /// painted region from a second mask looks like — would otherwise pay for it twice.
    public static func unresolvedReferences(
        in recipe: Recipe, isResolved: (MaskComponent) -> Bool
    ) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for mask in recipe.masks where mask.enabled {
            for component in mask.components where component.kind == .brush {
                guard let ref = component.strokesRef, !ref.isEmpty,
                      seen.insert(ref).inserted else { continue }
                if !isResolved(component) { out.append(ref) }
            }
        }
        return out
    }

    /// Why a delivery must be refused, or nil when nothing is missing.
    ///
    /// A count rather than a list of hashes: `blob:xxh64:00c41b0000000000` tells a
    /// photographer nothing, and the actionable fact is that this photo's brush masking
    /// would have been absent from the file.
    public static func refusal(unresolved: [String]) -> String? {
        guard !unresolved.isEmpty else { return nil }
        let n = unresolved.count
        return "\(n) brush stroke set\(n == 1 ? "" : "s") could not be read — "
            + "the masking would have exported empty"
    }
}
