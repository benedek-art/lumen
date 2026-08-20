// Recipe.swift
// The edit recipe: one declarative parameter document per photo version.
// Format authority: docs/15-catalog.md §15.4. Key names here ARE the wire format —
// changing one is a format change and needs a pipelineVersion / migration decision.
//
// Doctrine (docs/15 §15.4):
//  - Declarative state, never an operation log; render order is fixed by the pipeline.
//  - Rendering is a pure function of (original, recipe, pipelineVersion).
//  - Serialization is canonical + sparse (see CanonicalJSON.swift); `recipe_fp` keys every cache.
//  - The develop/look split (D4) is structural: `look` is the portable subtree.

import Foundation

/// The current recipe pipeline version. Bump only with an explicit, badged migration (D52).
public let currentPipelineVersion = 1

public struct Recipe: Codable, Equatable, Sendable {
    public var pipelineVersion: Int
    public var develop: Develop
    public var look: Look
    public var masks: [Mask]

    public init(
        pipelineVersion: Int = currentPipelineVersion,
        develop: Develop = Develop(),
        look: Look = Look(),
        masks: [Mask] = []
    ) {
        self.pipelineVersion = pipelineVersion
        self.develop = develop
        self.look = look
        self.masks = masks
    }

    /// Whether two recipes would render the same picture. Not every field in a recipe
    /// is a pixel: a mask's name is a label for the panel, and typing one should not
    /// re-render the frame and re-bin the scopes on every keystroke.
    public func rendersSameAs(_ other: Recipe) -> Bool {
        renderIdentity == other.renderIdentity
    }

    /// The recipe reduced to what actually reaches a pixel — what the fingerprint
    /// hashes, and what `rendersSameAs` compares.
    ///
    /// Masks lose their name AND their id. The name is a label for the panel. The id
    /// is a random UUID, and hashing it had two costs: renaming a mask changed
    /// `recipe_fp`, which keys every preview and artifact in the cache, so one
    /// keystroke in a text field threw away the 1:1 and fit renders of a 45-megapixel
    /// frame — and two photos given genuinely identical mask edits got different
    /// fingerprints, so they could never share a cached artifact. What the renderer
    /// needs to tell masks apart is their position in the stack, which survives here.
    ///
    /// The stored `edit.recipe` is still the full-fidelity recipe; this projection
    /// exists only to be hashed and compared.
    public var renderIdentity: Recipe {
        var copy = self
        copy.masks = masks.map { mask in
            var stripped = mask.withoutCosmetics
            stripped.id = ""
            return stripped
        }
        return copy
    }
}

// MARK: - Develop (per-image normalization, D4)

public struct Develop: Codable, Equatable, Sendable {
    public var raw: RawParams
    public var tone: Tone
    public var zones: Zones
    public var curve: CurveSet
    public var color: ColorAdjust
    public var mixer: Mixer
    public var pointColors: [PointColor]
    public var detail: Detail
    public var denoise: Denoise
    public var geometry: Geometry
    public var heal: Heal

    public init(
        raw: RawParams = RawParams(),
        tone: Tone = Tone(),
        zones: Zones = Zones(),
        curve: CurveSet = CurveSet(),
        color: ColorAdjust = ColorAdjust(),
        mixer: Mixer = Mixer(),
        pointColors: [PointColor] = [],
        detail: Detail = Detail(),
        denoise: Denoise = Denoise(),
        geometry: Geometry = Geometry(),
        heal: Heal = Heal()
    ) {
        self.raw = raw
        self.tone = tone
        self.zones = zones
        self.curve = curve
        self.color = color
        self.mixer = mixer
        self.pointColors = pointColors
        self.detail = detail
        self.denoise = denoise
        self.geometry = geometry
        self.heal = heal
    }
}

/// Vibrance and Saturation on the H-K-aware UCS model (D21), plus the two dials that
/// make Saturation behave like stacked dye instead of like a channel spread.
/// `density` blends additive ↔ subtractive behaviour; `protectSkin` attenuates BOTH
/// sliders inside the skin-tone tolerance band.
public struct ColorAdjust: Codable, Equatable, Sendable {
    public var vibrance: Double     // −100…+100, low-chroma weighted
    public var saturation: Double   // −100…+100, −100 reaches true B&W
    public var density: Double      // 0…100, default 50
    public var protectSkin: Double  // 0…100, default 70

    public init(vibrance: Double = 0, saturation: Double = 0,
                density: Double = 50, protectSkin: Double = 70) {
        self.vibrance = vibrance
        self.saturation = saturation
        self.density = density
        self.protectSkin = protectSkin
    }
}

/// Parameters consumed by the RAW decode stage (docs/14 S1–S5).
/// `temp`/`tint` nil means "as shot" (the decode's own neutral); when set, WB is a
/// CAT16 adaptation at pipeline stage S6, not a decode-time multiplier (docs/14 §2.1.4).
public struct RawParams: Codable, Equatable, Sendable {
    public var decoder: String        // "apple" | "lumen" (RawSource escape hatch, D50)
    public var decoderVersion: Int?   // pinned Apple decoder version; nil = not yet pinned
    public var temp: Double?          // Kelvin 2000…50000 (docs/04); nil = as shot
    public var tint: Double?          // −150…+150 soft, ±300 hard (docs/04); nil = as shot

    public init(decoder: String = "apple", decoderVersion: Int? = nil,
                temp: Double? = nil, tint: Double? = nil) {
        self.decoder = decoder
        self.decoderVersion = decoderVersion
        self.temp = temp
        self.tint = tint
    }
}

/// The six-slider tone contract (D6): identical names/ranges to Lightroom Classic.
/// exposure in EV (−5…+5); the rest −100…+100. contrastPivot is docs/04's
/// Contrast+Pivot anchor in EV relative to mid-gray (−4…+4, 0 = mid-gray).
public struct Tone: Codable, Equatable, Sendable {
    public var exposure: Double
    public var contrast: Double
    public var contrastPivot: Double
    public var highlights: Double
    public var shadows: Double
    public var whites: Double
    public var blacks: Double

    public init(exposure: Double = 0, contrast: Double = 0, contrastPivot: Double = 0,
                highlights: Double = 0, shadows: Double = 0, whites: Double = 0,
                blacks: Double = 0) {
        self.exposure = exposure
        self.contrast = contrast
        self.contrastPivot = contrastPivot
        self.highlights = highlights
        self.shadows = shadows
        self.whites = whites
        self.blacks = blacks
    }
}

/// The Zones panel (D7): five named zones + global over the normalized tonal axis,
/// with draggable pivots. Zone math reference: ZoneWeights.swift.
public struct Zones: Codable, Equatable, Sendable {
    /// Zone pivot positions on the normalized tonal axis [0,1], ascending.
    public var pivots: [Double]
    public var dark: ZoneAdjust
    public var shadow: ZoneAdjust
    public var mid: ZoneAdjust
    public var light: ZoneAdjust
    public var bright: ZoneAdjust
    public var global: ZoneAdjust

    public static let defaultPivots: [Double] = [0.08, 0.25, 0.5, 0.75, 0.92]

    public init(pivots: [Double] = Zones.defaultPivots,
                dark: ZoneAdjust = ZoneAdjust(), shadow: ZoneAdjust = ZoneAdjust(),
                mid: ZoneAdjust = ZoneAdjust(), light: ZoneAdjust = ZoneAdjust(),
                bright: ZoneAdjust = ZoneAdjust(), global: ZoneAdjust = ZoneAdjust()) {
        self.pivots = pivots
        self.dark = dark
        self.shadow = shadow
        self.mid = mid
        self.light = light
        self.bright = bright
        self.global = global
    }
}

/// Per-zone adjustment: exposure in stops, a color-wheel offset, saturation, falloff.
/// Wire note: `sat` stores UI-percent − 100 (docs/04 shows 0…200% default 100;
/// the wire form is the −100…+100 offset so the sparse default is 0).
public struct ZoneAdjust: Codable, Equatable, Sendable {
    public var ev: Double            // per-zone exposure, in stops (D7)
    public var wheel: [Double]       // [a, b] chroma offset in the working perceptual plane
    public var sat: Double           // −100…+100 (UI% − 100)
    public var falloff: Double       // 0…1 transition softness at this zone's edges (docs/04)

    public init(ev: Double = 0, wheel: [Double] = [0, 0], sat: Double = 0,
                falloff: Double = 0.5) {
        self.ev = ev
        self.wheel = wheel
        self.sat = sat
        self.falloff = falloff
    }
}

/// Tone curves (D10). Point curves are [[x,y],…] with x,y in [0,1], strictly
/// ascending x; interpolation is monotone cubic (MonotoneCubic.swift).
public struct CurveSet: Codable, Equatable, Sendable {
    public var parametric: ParametricCurve
    public var point: [[Double]]?
    public var r: [[Double]]?
    public var g: [[Double]]?
    public var b: [[Double]]?
    public var luma: [[Double]]?
    /// D10: luminance-preserving application is the default (LR "Refine Saturation 0"
    /// semantics). docs/04's continuous chroma-boost dial and per-end soft-clip
    /// controls are deferred format additions (pipelineVersion-gated when they land).
    public var preserveLuminance: Bool

    public init(parametric: ParametricCurve = ParametricCurve(),
                point: [[Double]]? = nil, r: [[Double]]? = nil, g: [[Double]]? = nil,
                b: [[Double]]? = nil, luma: [[Double]]? = nil,
                preserveLuminance: Bool = true) {
        self.parametric = parametric
        self.point = point
        self.r = r
        self.g = g
        self.b = b
        self.luma = luma
        self.preserveLuminance = preserveLuminance
    }
}

/// Four-region parametric curve with movable region splits (docs/04).
public struct ParametricCurve: Codable, Equatable, Sendable {
    public var highlights: Double   // −100…+100
    public var lights: Double
    public var darks: Double
    public var shadows: Double
    public var splits: [Double]     // three region boundaries, defaults 0.25/0.5/0.75

    public init(highlights: Double = 0, lights: Double = 0, darks: Double = 0,
                shadows: Double = 0, splits: [Double] = [0.25, 0.5, 0.75]) {
        self.highlights = highlights
        self.lights = lights
        self.darks = darks
        self.shadows = shadows
        self.splits = splits
    }
}

/// The 8-band Color Mixer (D13). Band order is fixed:
/// red, orange, yellow, green, aqua, blue, purple, magenta.
public struct Mixer: Codable, Equatable, Sendable {
    public var bands: [MixerBand]    // always 8
    public var uniformity: Double    // 0…100, hue convergence (D13)

    public init(bands: [MixerBand] = Array(repeating: MixerBand(), count: 8),
                uniformity: Double = 0) {
        self.bands = bands
        self.uniformity = uniformity
    }
}

public struct MixerBand: Codable, Equatable, Sendable {
    public var hue: Double    // −100…+100
    public var sat: Double
    public var lum: Double    // chroma-preserving luminance (D13)

    /// The two INNER ring handles: how far the band's core arc reaches below and above
    /// its canonical centre, in degrees. `[below, above]`, default `[22.5, 22.5]`.
    ///
    /// Asymmetric on purpose, and that asymmetry is the whole feature. docs/05 asks for
    /// an eyedropper that "re-centers the core range on the sampled hue"; a band centred
    /// at 29.2° whose core runs `[12.5, 32.5]` is a core arc centred on 39.2°, so
    /// re-centring needs no extra field and cannot disagree with the handles the user
    /// can see. `ColorEngine.BandArc.coreCentre` reads that midpoint back out, and
    /// Mixer Uniformity converges toward it.
    public var core: [Double]
    /// The two OUTER ring handles: falloff extent beyond the core, per side, in degrees.
    /// `[below, above]`, default `[15, 15]`. Capture One exposes one global Smoothness;
    /// this is the per-side version docs/05 claims as the improvement on it.
    public var feather: [Double]

    /// Wire defaults, derived from the engine's canonical geometry rather than
    /// transcribed — a recipe that said 22.5 while the engine said something else would
    /// be a band whose drawn arc and rendered reach disagreed.
    public static let defaultCore: [Double] =
        [ColorEngine.bandCoreDegrees, ColorEngine.bandCoreDegrees]
    public static let defaultFeather: [Double] =
        [ColorEngine.bandFeatherDegrees, ColorEngine.bandFeatherDegrees]

    public init(hue: Double = 0, sat: Double = 0, lum: Double = 0,
                core: [Double] = MixerBand.defaultCore,
                feather: [Double] = MixerBand.defaultFeather) {
        self.hue = hue
        self.sat = sat
        self.lum = lum
        self.core = core
        self.feather = feather
    }
}

/// A sampled Point Color swatch (D14).
public struct PointColor: Codable, Equatable, Sendable {
    public var sample: [Double]     // sampled color, working-space RGB [r,g,b] in [0,1]
    public var range: Double        // 0…100 master falloff
    public var variance: Double     // −100…+100 (negative converges, positive expands)
    public var shift: HSLShift

    public init(sample: [Double], range: Double = 50, variance: Double = 0,
                shift: HSLShift = HSLShift()) {
        self.sample = sample
        self.range = range
        self.variance = variance
        self.shift = shift
    }
}

extension PointColor {
    /// This swatch with its SHIFT scaled — what a mask's Amount is supposed to do to it.
    ///
    /// `Mask.amount` scales every other local adjustment and did not scale this one, on
    /// either path, so dragging a mask's Amount to 0 left its Point Colour shifts at
    /// full strength while everything around them faded out. The panel states that
    /// Amount "scales the adjustment deltas", and the shift IS the delta.
    ///
    /// `range` and `variance` are deliberately untouched: they describe WHICH colours
    /// the swatch selects, not how far it moves them, and fading a selection toward
    /// zero would change which pixels are affected rather than by how much.
    public func scalingShift(by scale: Double) -> PointColor {
        guard scale != 1, scale.isFinite else { return self }
        var copy = self
        copy.shift = HSLShift(h: shift.h * scale, s: shift.s * scale, l: shift.l * scale)
        return copy
    }
}

public struct HSLShift: Codable, Equatable, Sendable {
    public var h: Double
    public var s: Double
    public var l: Double

    public init(h: Double = 0, s: Double = 0, l: Double = 0) {
        self.h = h
        self.s = s
        self.l = l
    }
}

/// Presence + sharpening (docs/06).
public struct Detail: Codable, Equatable, Sendable {
    public var capture: CaptureSharpen
    public var texture: Double      // −100…+100
    public var clarity: Double
    public var dehaze: Double
    public var sharpen: ManualSharpen

    public init(capture: CaptureSharpen = CaptureSharpen(), texture: Double = 0,
                clarity: Double = 0, dehaze: Double = 0,
                sharpen: ManualSharpen = ManualSharpen()) {
        self.capture = capture
        self.texture = texture
        self.clarity = clarity
        self.dehaze = dehaze
        self.sharpen = sharpen
    }
}

/// Capture sharpening (D24): auto-radius RL deconvolution, on by default for raw.
public struct CaptureSharpen: Codable, Equatable, Sendable {
    public var auto: Bool
    public var radius: Double?      // manual override; nil = auto-estimated
    /// Manual strength override as a PERCENTAGE, 0…150, matching `ManualSharpen.amount`
    /// and every other amount in the recipe. `nil` = auto, which means 100.
    ///
    /// It has to be written down because the two readers disagreed: the engine divided
    /// by 100 while the RAW stage read the same number as a 0…1 fraction, so a recipe
    /// saying 25 meant a quarter to one of them and full strength to the other.
    public var amount: Double?

    /// The largest multiple of the auto strength the control will apply.
    public static let maxStrength: Double = 1.5

    /// What the measured capture-sharpening strength gets multiplied by.
    ///
    /// Here rather than in the RAW stage because the two branches were inverted there
    /// and nothing could see it: `auto == false` recomputed `100 / 100 == 1` and applied
    /// the full default strength, so turning capture sharpening off rendered the
    /// identical picture while the panel said it was off. `auto` is the ON switch.
    public var strengthFraction: Double {
        guard auto else { return 0 }
        // `Num.clamp` is `min(max(x, lo), hi)` on Swift's generic `Comparable` min/max,
        // which propagate NaN rather than the bound — every comparison against NaN is
        // false, so `max(nan, 0)` is nan. A NaN here would reach `sharpnessAmount` as
        // `Float.nan`. Recipes are user-editable and arrive from sidecars other tools
        // wrote, so this is reachable.
        let requested = amount ?? 100
        guard requested.isFinite else { return 1 }
        return Num.clamp(requested / 100, 0, CaptureSharpen.maxStrength)
    }

    public init(auto: Bool = true, radius: Double? = nil, amount: Double? = nil) {
        self.auto = auto
        self.radius = radius
        self.amount = amount
    }
}

/// Manual/creative sharpening surface (docs/06): LR contract + halo suppression.
/// Defaults to 0 on raw because capture sharpening owns the baseline.
public struct ManualSharpen: Codable, Equatable, Sendable {
    public var amount: Double       // 0…150
    public var radius: Double       // 0.5…3.0
    public var detail: Double       // 0…100
    public var masking: Double      // 0…100
    public var haloSuppression: Double // 0…100 (C1-inspired)

    public init(amount: Double = 0, radius: Double = 1.0, detail: Double = 25,
                masking: Double = 0, haloSuppression: Double = 0) {
        self.amount = amount
        self.radius = radius
        self.detail = detail
        self.masking = masking
        self.haloSuppression = haloSuppression
    }

    /// The radius a stock unsharp mask should use to stand in for `radius` + `detail`.
    ///
    /// The GPU path sharpens with `CIUnsharpMask`, which takes a radius and an
    /// intensity and nothing else — so `detail`, `masking` and `haloSuppression` were
    /// read by NOTHING there, while the panel shipped all three as live sliders and the
    /// reference implementation applied all three correctly.
    ///
    /// Detail is the one of the three a radius can honestly carry: on the reference
    /// path it weights the two finest wavelet bands, which is the same statement as
    /// "sharpen at a smaller scale". So Detail 100 pulls the radius toward its floor
    /// and Detail 0 leaves it where the Radius slider put it. Masking and halo
    /// suppression have no expression in a stock unsharp mask at all — an edge gate and
    /// an asymmetric overshoot clamp are per-pixel decisions the filter does not offer.
    ///
    /// Kept only as the FALLBACK radius. The GPU path now sharpens the way the
    /// reference does — a log-luminance delta with a real edge gate and a one-sided
    /// overshoot clamp — and reaches for a stock unsharp mask only if one of those
    /// kernels is unavailable, where a soft picture beats a stage that silently does
    /// nothing.
    public var unsharpRadius: Double {
        let base = Num.clamp(radius.isFinite ? radius : 1.0, 0.5, 3.0)
        let fine = Num.clamp(detail.isFinite ? detail : 0, 0, 100) / 100
        // Toward half the base radius at Detail 100 — the finest band the reference
        // weights is about one octave below the nominal one.
        return Num.clamp(base * (1 - 0.5 * fine), 0.2, 5)
    }
}

/// Two-tier denoise (D26). `ai` results are cached artifacts, never files (docs/07).
///
/// `appleStandIn` is what the RAW stage applies until Lumen's own Tier 1 and Tier 2
/// engines run in the graph. It exists as a named, tested mapping because the wiring was
/// wrong in a way the panel hid: in `.ai` mode the stage read `classic.luma` and
/// `classic.chroma`, which the panel does not show in that mode, and ignored `amount`,
/// which is the only slider it does show. Switching Classic → AI changed nothing, and
/// dragging the AI Amount slider changed nothing.
public struct Denoise: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable {
        case off, classic, ai
    }
    public var mode: Mode
    public var amount: Double       // AI blend 0…100; instant post-compute
    public var model: String?       // e.g. "nafnet/2.1"; nil = current default
    public var classic: ClassicNR

    public init(mode: Mode = .classic, amount: Double = 50, model: String? = nil,
                classic: ClassicNR = ClassicNR()) {
        self.mode = mode
        self.amount = amount
        self.model = model
        self.classic = classic
    }

    /// Luminance and colour fractions, 0…1, for the RAW decoder's own denoise stage.
    ///
    /// Off is off. Classic follows the two sliders the Classic panel shows. AI follows
    /// `amount`, which is the ONLY slider the AI panel shows — and which the wiring
    /// previously ignored in favour of two hidden Classic values, so the mode switch
    /// and the visible slider were both inert.
    ///
    /// The AI mapping is a stand-in, not the model: Tier 2 is a cached artifact that
    /// does not run in the graph yet. Weighting colour above luminance mirrors the
    /// Classic defaults, where chroma sits at 25 and luma at 0 — colour noise is the
    /// one every sensor has and the one a decoder can cheaply help with.
    public var appleStandIn: (luma: Double, chroma: Double) {
        func fraction(_ v: Double) -> Double {
            Num.clamp(v.isFinite ? v : 0, 0, 100) / 100
        }
        switch mode {
        case .off:
            return (0, 0)
        case .classic:
            return (fraction(classic.luma), fraction(classic.chroma))
        case .ai:
            let blend = fraction(amount)
            return (blend * 0.6, blend)
        }
    }
}

public struct ClassicNR: Codable, Equatable, Sendable {
    public var luma: Double         // 0…100
    public var chroma: Double       // 0…100, default mild (docs/07)
    public var hotPixels: Double    // 0…100 (D26, single-pixel control)

    public init(luma: Double = 0, chroma: Double = 25, hotPixels: Double = 0) {
        self.luma = luma
        self.chroma = chroma
        self.hotPixels = hotPixels
    }
}

/// Geometry (docs/09). Crop is normalized to the source frame; masks are stored in
/// source coordinates and reproject through geometry changes (docs/09 invariant).
public struct Geometry: Codable, Equatable, Sendable {
    public var crop: Crop
    public var angle: Double        // degrees, straighten
    public var flipH: Bool
    public var upright: Upright?
    public var lens: LensCorrections

    public init(crop: Crop = Crop(), angle: Double = 0, flipH: Bool = false,
                upright: Upright? = nil, lens: LensCorrections = LensCorrections()) {
        self.crop = crop
        self.angle = angle
        self.flipH = flipH
        self.upright = upright
        self.lens = lens
    }
}

public struct Crop: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double = 0, y: Double = 0, w: Double = 1, h: Double = 1) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

/// Manual/guided perspective (docs/09). Slider bounds are Lumen's own (docs/09 note).
public struct Upright: Codable, Equatable, Sendable {
    public var vertical: Double     // −100…+100
    public var horizontal: Double   // −100…+100
    public var rotate: Double       // −10…+10
    public var aspect: Double       // −100…+100
    public var scale: Double        // 50…150, default 100
    public var offsetX: Double
    public var offsetY: Double
    public var strength: Double     // 0…100 back-off of a guided solution (docs/09)

    public init(vertical: Double = 0, horizontal: Double = 0, rotate: Double = 0,
                aspect: Double = 0, scale: Double = 100,
                offsetX: Double = 0, offsetY: Double = 0, strength: Double = 100) {
        self.vertical = vertical
        self.horizontal = horizontal
        self.rotate = rotate
        self.aspect = aspect
        self.scale = scale
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.strength = strength
    }
}

public struct LensCorrections: Codable, Equatable, Sendable {
    public var profile: Bool        // built-in / profile geometric+vignetting corrections
    public var removeCA: Bool
    public var defringe: Defringe?

    public init(profile: Bool = true, removeCA: Bool = true, defringe: Defringe? = nil) {
        self.profile = profile
        self.removeCA = removeCA
        self.defringe = defringe
    }
}

/// Defringe with LR's exact defaults (docs/09): purple 30/70, green 40/60.
public struct Defringe: Codable, Equatable, Sendable {
    public var purpleAmount: Double  // 0…20
    public var purpleHueLo: Double
    public var purpleHueHi: Double
    public var greenAmount: Double   // 0…20
    public var greenHueLo: Double
    public var greenHueHi: Double

    public init(purpleAmount: Double = 0, purpleHueLo: Double = 30, purpleHueHi: Double = 70,
                greenAmount: Double = 0, greenHueLo: Double = 40, greenHueHi: Double = 60) {
        self.purpleAmount = purpleAmount
        self.purpleHueLo = purpleHueLo
        self.purpleHueHi = purpleHueHi
        self.greenAmount = greenAmount
        self.greenHueLo = greenHueLo
        self.greenHueHi = greenHueHi
    }
}

/// Heal/clone stroke vectors live in content-addressed blobs (docs/15 §15.4 rule 4).
public struct Heal: Codable, Equatable, Sendable {
    public var strokesRef: String?  // "blob:xxh64:<hash>"
    public var count: Int

    public init(strokesRef: String? = nil, count: Int = 0) {
        self.strokesRef = strokesRef
        self.count = count
    }
}
