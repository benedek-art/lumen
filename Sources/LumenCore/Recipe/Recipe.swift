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
///
/// 2 — `look.bw.enabled` (docs/audit COLOR-20). Version 1 spelled "black and white is
/// off" by deleting the whole `look.bw` slot, so the mix could not be stored while
/// switched off and the panel kept it in view state instead. Version 2 keeps the mix in
/// the recipe and switches it with a boolean.
///
/// No version-1 recipe renders differently under version 2, so this bump needs no
/// badged per-photo migration: the absent key decodes as `true` (see `BlackAndWhite`),
/// which is precisely what version 1 meant by the slot being there. What it buys is the
/// reverse direction — a version-2 recipe can express "off, mix kept", which a version-1
/// reader would render as black and white. The version is what tells the two apart.
public let currentPipelineVersion = 2

public struct Recipe: Codable, Equatable, Sendable {
    public var pipelineVersion: Int
    public var develop: Develop
    public var look: Look
    public var masks: [Mask]
    /// The folders masks can sit in. Order is the panel's order; a mask names one by id.
    public var maskGroups: [MaskGroup]

    public init(
        pipelineVersion: Int = currentPipelineVersion,
        develop: Develop = Develop(),
        look: Look = Look(),
        masks: [Mask] = [],
        maskGroups: [MaskGroup] = []
    ) {
        self.pipelineVersion = pipelineVersion
        self.develop = develop
        self.look = look
        self.masks = masks
        self.maskGroups = maskGroups
    }

    /// This recipe with `source`'s masks and folders APPENDED.
    ///
    /// "Paste Masks" across a sequence — put this sky mask on the rest of the shoot —
    /// and appending rather than replacing is the whole difference between it and Paste
    /// Settings. Those two mean "make this photograph like that one"; this one means
    /// "also do this", and replacing would silently delete whatever local work each
    /// target already had. It is also the gesture people use to build a stack up mask by
    /// mask across a sequence, which replacing makes impossible.
    ///
    /// THE IDS. A mask's id is per-photograph, so a collision only happens when the same
    /// mask has already been pasted here — and then a naive append produces two masks
    /// with one id, which every `firstIndex(where:)` in the application resolves to the
    /// first. Colliding ids are re-issued, and the whole batch is remapped TOGETHER, so
    /// a `maskRef` between two pasted masks still points at its partner rather than at
    /// the copy that was already here. A reference to a mask that is NOT in the batch is
    /// left alone: it names something on the source photograph, and inventing a target
    /// for it would be a selection nobody asked for.
    public func appendingMasks(from source: Recipe) -> Recipe {
        var copy = self
        let takenMasks = Set(masks.map(\.id))
        let takenGroups = Set(maskGroups.map(\.id))
        var maskIDs: [String: String] = [:]
        var groupIDs: [String: String] = [:]
        for mask in source.masks where takenMasks.contains(mask.id) {
            maskIDs[mask.id] = UUID().uuidString
        }
        for group in source.maskGroups where takenGroups.contains(group.id) {
            groupIDs[group.id] = UUID().uuidString
        }
        for group in source.maskGroups {
            var moved = group
            moved.id = groupIDs[group.id] ?? group.id
            copy.maskGroups.append(moved)
        }
        for mask in source.masks {
            var moved = mask
            moved.id = maskIDs[mask.id] ?? mask.id
            if let g = moved.group { moved.group = groupIDs[g] ?? g }
            moved.components = moved.components.map { component in
                var c = component
                if let ref = c.maskRef, let landed = maskIDs[ref] { c.maskRef = landed }
                return c
            }
            copy.masks.append(moved)
        }
        return copy
    }

    /// What a group's settings do to one of its members, resolved in ONE place.
    ///
    /// Both renderers and the panel ask this rather than each folding the two levels
    /// themselves, because a group is the first thing in this format where a mask's
    /// effective state is not a property of the mask. Two implementations of that would
    /// be two answers to "is this mask on".
    ///
    /// A mask naming a group that is not in the list is UNGROUPED, not hidden: a folder
    /// deleted by hand out of a sidecar must not silently take its members' edits with
    /// it.
    public func effective(_ mask: Mask) -> (enabled: Bool, amount: Double) {
        guard let id = mask.group,
              let group = maskGroups.first(where: { $0.id == id })
        else { return (mask.enabled, mask.amount) }
        return (mask.enabled && group.enabled,
                mask.amount * Num.clamp(group.amount, 0, 200) / 100)
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
    /// A switched-off black-and-white mix goes the same way, for the same reason. It is
    /// eight numbers no pixel reads, kept so the photographer gets them back; hashing
    /// them would make "turn the treatment off" a different picture as far as every
    /// cache is concerned — a full re-render of a frame that did not change — and would
    /// make the library call a photo edited when it renders exactly as it was shot.
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
        // Groups go through the same projection, and their ids CANNOT be blanked the
        // way a mask's is: a mask names its group by id, so erasing the id would fold
        // every folder into one and make "member of A" and "member of B" hash alike.
        // What is cosmetic about a group is its name and whether it is open — opening a
        // folder must not re-render 45 megapixels, which is the whole reason
        // `withoutCosmetics` exists.
        copy.maskGroups = maskGroups.map(\.withoutCosmetics)
        if copy.look.bw?.enabled == false { copy.look.bw = nil }
        // A creative grain at Amount 0 goes the same way, and for the same reason the
        // line above exists: it is three numbers no pixel reads. `CreativeGrain
        // .normalized` keeps every writer in the app from producing one, so this is here
        // for the sidecars that were not written by this app — a hand-edited
        // `{"grain":{"size":90}}` renders exactly like a recipe with no grain key and
        // must not be handed a different `recipe_fp`, which would throw away every
        // cached preview of that photograph to produce identical bytes.
        if copy.look.grain?.isIdentity == true { copy.look.grain = nil }
        // `look.lut` goes the same way, for a blunter reason: NO STAGE READS IT.
        // `LUTReference` round-trips through the recipe, the sidecar and the catalog,
        // and there is no reader on any path — not `RenderGraph`, not `export`, not the
        // reference renderer. `LUT3D.fromCubeFile` exists and has only test callers.
        //
        // So two recipes differing only in a LUT render the same picture, and this
        // projection is defined as "what actually reaches a pixel". Leaving it in meant
        // a hand-edited sidecar carrying `look.lut` got a different `recipe_fp`, threw
        // away every cached preview and artifact for that photo, re-rendered the frame,
        // and produced identical bytes — and the library called it edited.
        //
        // WHEN A LUT STAGE IS BUILT, DELETE THIS LINE IN THE SAME COMMIT. A LUT that
        // renders but is not hashed is the mirror defect: the user drags Amount and the
        // cache hands back the previous picture.
        // `testALookCarryingALUTRendersTheSamePictureAsOneWithout` fails the moment this
        // line is wrong in either direction, and says which.
        copy.look.lut = nil
        // `develop.heal` is the SAME situation and is deliberately handled the other
        // way: nothing writes it, nothing reads it, and it is left in this projection so
        // that it busts the cache on the day a heal stage lands. Both choices are safe
        // and the divergence is not an oversight, but it would read as one, so: the
        // tripwire above is the better of the two patterns and heal should adopt it when
        // somebody is next in that code. Leaving a dead field in costs a cache miss
        // every time a sidecar happens to carry it, forever, to buy protection against a
        // mistake on a day that may never come — where a test that fails the moment the
        // stage lands buys the same protection and costs nothing until then.
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case pipelineVersion, develop, look, masks, maskGroups
    }

    /// Tolerant of a recipe written before any of these keys existed. `pipelineVersion`
    /// is the one fallback here that is a claim rather than a value: an absent version
    /// means a document nobody's writer produced — every writer this format has had
    /// forces the key in, sparse or not — so it reads as the current vocabulary, which
    /// is what `Recipe()` itself says. A version that IS present is never overwritten,
    /// and `testARecipeWrittenAtAnOlderVersionStillReportsThatVersion` is what keeps a
    /// stray `??` from stamping today's number onto every old recipe in the catalog.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.pipelineVersion = try c.decodeIfPresent(Int.self, forKey: .pipelineVersion)
            ?? currentPipelineVersion
        self.develop = try c.decodeIfPresent(Develop.self, forKey: .develop) ?? Develop()
        self.look = try c.decodeIfPresent(Look.self, forKey: .look) ?? Look()
        self.masks = try c.decodeIfPresent([Mask].self, forKey: .masks) ?? []
        self.maskGroups = try c.decodeIfPresent([MaskGroup].self, forKey: .maskGroups)
            ?? []
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

    private enum CodingKeys: String, CodingKey {
        case raw, tone, zones, curve, color, mixer, pointColors, detail, denoise,
             geometry, heal
    }

    /// Tolerant of a recipe written before any of these keys existed: each falls
    /// back to the default in the memberwise initializer above. See RecipeDecoding.swift.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.raw = try c.decodeIfPresent(RawParams.self, forKey: .raw) ?? RawParams()
        self.tone = try c.decodeIfPresent(Tone.self, forKey: .tone) ?? Tone()
        self.zones = try c.decodeIfPresent(Zones.self, forKey: .zones) ?? Zones()
        self.curve = try c.decodeIfPresent(CurveSet.self, forKey: .curve) ?? CurveSet()
        self.color = try c.decodeIfPresent(ColorAdjust.self, forKey: .color)
            ?? ColorAdjust()
        self.mixer = try c.decodeIfPresent(Mixer.self, forKey: .mixer) ?? Mixer()
        self.pointColors = try c.decodeIfPresent([PointColor].self, forKey: .pointColors)
            ?? []
        self.detail = try c.decodeIfPresent(Detail.self, forKey: .detail) ?? Detail()
        self.denoise = try c.decodeIfPresent(Denoise.self, forKey: .denoise) ?? Denoise()
        self.geometry = try c.decodeIfPresent(Geometry.self, forKey: .geometry)
            ?? Geometry()
        self.heal = try c.decodeIfPresent(Heal.self, forKey: .heal) ?? Heal()
    }
}

/// Vibrance and Saturation on the H-K-aware UCS model (D21), plus the two dials that
/// make Saturation behave like stacked dye instead of like a channel spread.
///
/// `density` blends Saturation's additive push against its subtractive one, and only a
/// push has anything to blend.
///
/// `protectSkin` attenuates Vibrance at both signs and Saturation's PUSH. It does not
/// attenuate a negative Saturation: "−100 reaches true B&W" is a contract, and a guard
/// that stops a pull short of its own endpoint is not a preference, it is a defect. It
/// used to, and at the default of 70 that left skin at 30% chroma in a frame the
/// photographer had taken all the way to black and white.
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

    /// Whether moving `density` can change a single pixel at these settings.
    ///
    /// The subtractive branch is a per-channel gamma above 1: it densifies a colour as
    /// it intensifies. There is no such thing to blend on the way DOWN — a negative
    /// Saturation is a plain walk toward the neutral axis, and `ColorEngine` guards the
    /// blend on `satAmount > 0` accordingly. That guard is right; what was wrong is that
    /// nothing said so. The panel drew a live bipolar dial over half a slider's range
    /// where it did exactly nothing, which is the same class of thing as a dead control
    /// and is worse, because it looks like it is working.
    ///
    /// This is the predicate the panel disables the row on, and
    /// `testDensityIsLiveExactlyWhereItChangesThePicture` is what stops it drifting from
    /// the engine's own guard.
    public var densityIsLive: Bool { saturation > 0 }

    /// The colour stage a MASK's sub-recipe runs: the mask's own Sat/Vibrance, with
    /// density and protectSkin INHERITED from the global colour panel.
    ///
    /// Those two used to come from this type's defaults — 50 and 70 — which no mask
    /// control can see or move, so a masked Sat −100 on a face was 70%-skin-protected
    /// by an invisible constant with no way to turn it off (COLOR-27). Inheriting the
    /// global values turns the constant into the photographer's own setting: the mask
    /// panel still offers no override (that is a wire-format change, recorded in the
    /// dossier), but the global Protect Skin and Density sliders now govern masked
    /// saturation the way they govern global saturation, which is what "a mask's
    /// sub-recipe is a delta over the global parameters" has meant everywhere else.
    /// On a recipe whose global colour panel is untouched, nothing renders
    /// differently: the inherited values ARE 50 and 70.
    public static func local(vibrance: Double, saturation: Double,
                             inheriting global: ColorAdjust) -> ColorAdjust {
        ColorAdjust(vibrance: vibrance, saturation: saturation,
                    density: global.density, protectSkin: global.protectSkin)
    }

    private enum CodingKeys: String, CodingKey {
        case vibrance, saturation, density, protectSkin
    }

    /// Tolerant of a recipe written before any of these keys existed: each falls
    /// back to the default in the memberwise initializer above. See RecipeDecoding.swift.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.vibrance = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0
        self.saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        self.density = try c.decodeIfPresent(Double.self, forKey: .density) ?? 50
        self.protectSkin = try c.decodeIfPresent(Double.self, forKey: .protectSkin) ?? 70
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

    private enum CodingKeys: String, CodingKey {
        case decoder, decoderVersion, temp, tint
    }

    /// Tolerant of a recipe written before any of these keys existed: each falls
    /// back to the default in the memberwise initializer above. See RecipeDecoding.swift.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.decoder = try c.decodeIfPresent(String.self, forKey: .decoder) ?? "apple"
        self.decoderVersion = try c.decodeIfPresent(Int.self, forKey: .decoderVersion)
        self.temp = try c.decodeIfPresent(Double.self, forKey: .temp)
        self.tint = try c.decodeIfPresent(Double.self, forKey: .tint)
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

    private enum CodingKeys: String, CodingKey {
        case exposure, contrast, contrastPivot, highlights, shadows, whites, blacks
    }

    /// Tolerant of a recipe written before any of these keys existed: each falls
    /// back to the default in the memberwise initializer above. See RecipeDecoding.swift.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        self.contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        self.contrastPivot = try c.decodeIfPresent(Double.self, forKey: .contrastPivot)
            ?? 0
        self.highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        self.shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        self.whites = try c.decodeIfPresent(Double.self, forKey: .whites) ?? 0
        self.blacks = try c.decodeIfPresent(Double.self, forKey: .blacks) ?? 0
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

    /// The documented pivot EVs (docs/04: −4 / −2 / 0 / +2 / +4 around mid-grey),
    /// expressed on the normalized axis THROUGH the engine's own default anchors —
    /// so the constants and the documentation cannot drift apart again. The old
    /// hand-written values [0.08, 0.25, 0.5, 0.75, 0.92] were plausible-looking
    /// fractions that put "Mids" at scene −2 EV and "Darks" at −7.9 EV, where the
    /// display toe has nothing to show: the slider dossier's #1 defect, caught by
    /// reading the numbers back through the axis they are used in
    /// (`AccuracyProbeTests.testTheDefaultZonePivotsSitAtTheirDocumentedEVs`).
    public static let defaultPivots: [Double] = [-4.0, -2.0, 0.0, 2.0, 4.0].map {
        ($0 - ToneEngine.defaultBlackAnchorEV)
            / (ToneEngine.defaultWhiteAnchorEV - ToneEngine.defaultBlackAnchorEV)
    }

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

    private enum CodingKeys: String, CodingKey {
        case pivots, dark, shadow, mid, light, bright, global
    }

    /// Tolerant of a recipe written before any of these keys existed: each falls
    /// back to the default in the memberwise initializer above. See RecipeDecoding.swift.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.pivots = RecipeWire.fixedLength(
            try c.decodeIfPresent([Double].self, forKey: .pivots),
            default: Zones.defaultPivots)
        self.dark = try c.decodeIfPresent(ZoneAdjust.self, forKey: .dark) ?? ZoneAdjust()
        self.shadow = try c.decodeIfPresent(ZoneAdjust.self, forKey: .shadow)
            ?? ZoneAdjust()
        self.mid = try c.decodeIfPresent(ZoneAdjust.self, forKey: .mid) ?? ZoneAdjust()
        self.light = try c.decodeIfPresent(ZoneAdjust.self, forKey: .light)
            ?? ZoneAdjust()
        self.bright = try c.decodeIfPresent(ZoneAdjust.self, forKey: .bright)
            ?? ZoneAdjust()
        self.global = try c.decodeIfPresent(ZoneAdjust.self, forKey: .global)
            ?? ZoneAdjust()
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

    private enum CodingKeys: String, CodingKey {
        case ev, wheel, sat, falloff
    }

    /// Tolerant of a recipe written before any of these keys existed: each falls
    /// back to the default in the memberwise initializer above. See RecipeDecoding.swift.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.ev = try c.decodeIfPresent(Double.self, forKey: .ev) ?? 0
        self.wheel = RecipeWire.fixedLength(
            try c.decodeIfPresent([Double].self, forKey: .wheel),
            default: [0, 0])
        self.sat = try c.decodeIfPresent(Double.self, forKey: .sat) ?? 0
        self.falloff = try c.decodeIfPresent(Double.self, forKey: .falloff) ?? 0.5
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

    private enum CodingKeys: String, CodingKey {
        case parametric, point, r, g, b, luma, preserveLuminance
    }

    /// Tolerant of a recipe written before any of these keys existed: each falls
    /// back to the default in the memberwise initializer above. See RecipeDecoding.swift.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.parametric = try c.decodeIfPresent(ParametricCurve.self, forKey: .parametric)
            ?? ParametricCurve()
        self.point = try c.decodeIfPresent([[Double]].self, forKey: .point)
        self.r = try c.decodeIfPresent([[Double]].self, forKey: .r)
        self.g = try c.decodeIfPresent([[Double]].self, forKey: .g)
        self.b = try c.decodeIfPresent([[Double]].self, forKey: .b)
        self.luma = try c.decodeIfPresent([[Double]].self, forKey: .luma)
        self.preserveLuminance = try c.decodeIfPresent(Bool.self, forKey: .preserveLuminance)
            ?? true
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

    private enum CodingKeys: String, CodingKey {
        case highlights, lights, darks, shadows, splits
    }

    /// Tolerant of a recipe written before any of these keys existed: each falls
    /// back to the default in the memberwise initializer above. See RecipeDecoding.swift.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        self.lights = try c.decodeIfPresent(Double.self, forKey: .lights) ?? 0
        self.darks = try c.decodeIfPresent(Double.self, forKey: .darks) ?? 0
        self.shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        self.splits = RecipeWire.fixedLength(
            try c.decodeIfPresent([Double].self, forKey: .splits),
            default: [0.25, 0.5, 0.75])
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

    private enum CodingKeys: String, CodingKey {
        case bands, uniformity
    }

    /// Tolerant of a recipe written before any of these keys existed: each falls
    /// back to the default in the memberwise initializer above. See RecipeDecoding.swift.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.bands = RecipeWire.fixedLength(
            try c.decodeIfPresent([MixerBand].self, forKey: .bands),
            default: Array(repeating: MixerBand(), count: 8))
        self.uniformity = try c.decodeIfPresent(Double.self, forKey: .uniformity) ?? 0
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

    private enum CodingKeys: String, CodingKey {
        case hue, sat, lum, core, feather
    }

    /// Tolerant of a recipe written before `core` and `feather` existed — which is every
    /// recipe written before the inner and outer ring handles shipped, and which is the
    /// decode failure that took a whole folder's catalog registration down with it. The
    /// two arc pairs fall back to the engine's own canonical geometry, so a band whose
    /// handles were never stored reaches exactly as far as it always did.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.hue = try c.decodeIfPresent(Double.self, forKey: .hue) ?? 0
        self.sat = try c.decodeIfPresent(Double.self, forKey: .sat) ?? 0
        self.lum = try c.decodeIfPresent(Double.self, forKey: .lum) ?? 0
        self.core = RecipeWire.fixedLength(
            try c.decodeIfPresent([Double].self, forKey: .core),
            default: MixerBand.defaultCore)
        self.feather = RecipeWire.fixedLength(
            try c.decodeIfPresent([Double].self, forKey: .feather),
            default: MixerBand.defaultFeather)
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

    private enum CodingKeys: String, CodingKey {
        case sample, range, variance, shift
    }

    /// Tolerant of an absent key, with one fallback that the memberwise initializer above
    /// does not supply: `sample` has no default there because a swatch with no sampled
    /// colour is not a swatch. A neutral triple is the safe reading of one that arrives
    /// without it — `ColorEngine.compiledSwatches` skips a swatch whose shift is zero and
    /// clamps what it selects, so a black reference costs at most one dead swatch, where
    /// throwing costs the photograph's whole edit. The fixed length matters more than the
    /// value: `ColorPanel` reads `sample[0…2]` with no guard at all.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sample = RecipeWire.fixedLength(
            try c.decodeIfPresent([Double].self, forKey: .sample),
            default: [0, 0, 0])
        self.range = try c.decodeIfPresent(Double.self, forKey: .range) ?? 50
        self.variance = try c.decodeIfPresent(Double.self, forKey: .variance) ?? 0
        self.shift = try c.decodeIfPresent(HSLShift.self, forKey: .shift) ?? HSLShift()
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

    private enum CodingKeys: String, CodingKey {
        case h, s, l
    }

    /// Tolerant of a recipe written before any of these keys existed: each falls
    /// back to the default in the memberwise initializer above. See RecipeDecoding.swift.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.h = try c.decodeIfPresent(Double.self, forKey: .h) ?? 0
        self.s = try c.decodeIfPresent(Double.self, forKey: .s) ?? 0
        self.l = try c.decodeIfPresent(Double.self, forKey: .l) ?? 0
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

    private enum CodingKeys: String, CodingKey {
        case capture, texture, clarity, dehaze, sharpen
    }

    /// Tolerant of a recipe written before any of these keys existed: each falls
    /// back to the default in the memberwise initializer above. See RecipeDecoding.swift.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.capture = try c.decodeIfPresent(CaptureSharpen.self, forKey: .capture)
            ?? CaptureSharpen()
        self.texture = try c.decodeIfPresent(Double.self, forKey: .texture) ?? 0
        self.clarity = try c.decodeIfPresent(Double.self, forKey: .clarity) ?? 0
        self.dehaze = try c.decodeIfPresent(Double.self, forKey: .dehaze) ?? 0
        self.sharpen = try c.decodeIfPresent(ManualSharpen.self, forKey: .sharpen)
            ?? ManualSharpen()
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

    private enum CodingKeys: String, CodingKey {
        case auto, radius, amount
    }

    /// Tolerant of a recipe written before any of these keys existed: each falls
    /// back to the default in the memberwise initializer above. See RecipeDecoding.swift.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.auto = try c.decodeIfPresent(Bool.self, forKey: .auto) ?? true
        self.radius = try c.decodeIfPresent(Double.self, forKey: .radius)
        self.amount = try c.decodeIfPresent(Double.self, forKey: .amount)
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
    /// suppression had no expression in a stock unsharp mask at all — an edge gate and
    /// an asymmetric overshoot clamp are per-pixel decisions the filter does not offer.
    /// All three reach the GPU as their own kernel arguments now.
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

    private enum CodingKeys: String, CodingKey {
        case amount, radius, detail, masking, haloSuppression
    }

    /// Tolerant of a recipe written before any of these keys existed: each falls
    /// back to the default in the memberwise initializer above. See RecipeDecoding.swift.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0
        self.radius = try c.decodeIfPresent(Double.self, forKey: .radius) ?? 1.0
        self.detail = try c.decodeIfPresent(Double.self, forKey: .detail) ?? 25
        self.masking = try c.decodeIfPresent(Double.self, forKey: .masking) ?? 0
        self.haloSuppression = try c.decodeIfPresent(Double.self, forKey: .haloSuppression)
            ?? 0
    }
}

/// Creative grain: the grain stage's parameters for a photograph with no film stock on
/// it (`look.grain`).
///
/// WHY THIS EXISTS AT ALL, since the app already has a grain: the model was reachable
/// only through the Film Lab. `RenderPlan` builds a `FilmChain` under
/// `if let film = look.filmLab, film.amount > 0, FilmStock.named(film.stock) != nil`,
/// and every grain reader on both paths was gated on that chain — so grain on a
/// photograph meant "load an emulsion, keep its colour rendering at some strength above
/// zero, and take that stock's crystal size". The owner's words: *"there's no ability to
/// make creative kinds of grain on the image, which is kind of sad."* Grain is a
/// darkroom-and-print instinct, not a property of an emulsion you happen to be
/// emulating, and a photographer who wants texture on a digital frame should not have to
/// buy a colour rendering to get it.
///
/// NOTHING HERE IS A SECOND GRAIN. Every one of these three numbers lands on
/// `FilmGrainProfile`, the density-domain model `docs/14 §5.7` specifies and the Film Lab
/// already uses: amplitude ∝ √(p(1−p)) so it peaks at mid densities and vanishes at both
/// Dmin and Dmax, three decorrelated layers on a colour picture, one plate on a
/// monochrome one, the same deterministic value-noise generator and the same kernel on
/// the GPU. What is new is a way to state the profile without a stock, which is
/// `FilmGrainProfile.init(creative:monochrome:)` and nothing else.
///
/// THE NAMES ARE LIGHTROOM'S — Amount, Size, Roughness — because that is the vocabulary
/// a photographer already has for this control, and where a name would have been a lie
/// it is not used. What each one really moves, stated here so the panel's help and the
/// engine cannot drift apart:
///
///   · **Amount** is the film path's Amount, unchanged: 0…100 scaled to the profile's
///     normalized `amount`, which the stage multiplies by
///     `FilmGrainProfile.densityScale` (0.12 density units at peak). Identical
///     denomination to `FilmGrain.amount`, so a stock at grain 45 and a creative grain
///     at 45 lay down the same amplitude.
///   · **Size** is the grain's PITCH AT THE GATE in micrometres, mapped geometrically —
///     `7 · 2^(3·size/100)`, so 0 → 7 µm, 50 → 19.8 µm, 100 → 56 µm, and the pitch
///     doubles every 33 points. It is denominated on a 35 mm gate
///     (`FilmGrainProfile.creativeGateLongEdgeMM`), which is the only honest reading
///     when there is no negative: the shipped stocks run 6 µm (Velvia) to 18 µm
///     (Tri-X), so the slider's lower half sits among real emulsions and its top reaches
///     past all of them, which is what a creative control is for. Like the film path's
///     Size it is anchored at the gate, so the grain is the same fraction of the picture
///     at every delivery size.
///   · **Roughness** is the plate's octave PERSISTENCE — the amplitude ratio between
///     successive octaves of the value noise `FilmGrainProfile.plate` sums — mapped
///     `0.25 + 0.005·roughness`, so 0 → 0.25, **50 → 0.5, which is exactly the plate
///     every film stock has always been given**, and 100 → 0.75. Low persistence puts
///     the energy in the coarsest octave: an even, regular, almost dithered field. High
///     persistence feeds the fine octaves: an irregular, clumpy, gritty one. The plate
///     is renormalized to exact unit variance after the octaves are summed, so
///     Roughness changes the CHARACTER and never secretly changes the Amount — which is
///     the property that makes it a third control rather than a second strength.
///
/// Defaults are Amount 0 (off), Size 50, Roughness 50 — so an untouched recipe is
/// byte-identical to one written before this struct existed, the sparse serializer
/// prunes the whole subtree, and no fingerprint in any catalog moves.
public struct CreativeGrain: Codable, Equatable, Sendable {
    public var amount: Double      // 0…100, 0 = off
    public var size: Double        // 0…100 → 4…32 µm pitch at a 35 mm gate
    public var roughness: Double   // 0…100 → 0.25…0.75 octave persistence

    public init(amount: Double = 0, size: Double = 50, roughness: Double = 50) {
        self.amount = amount
        self.size = size
        self.roughness = roughness
    }

    /// True when this grain lays nothing down, so the plan can skip the stage and the
    /// plate before either costs anything.
    public var isIdentity: Bool { !(amount > 0) }

    /// The slot after an edit: nil whenever the value is back at its defaults.
    ///
    /// "No creative grain" has to have ONE spelling on the wire. `Look.grain` is
    /// optional, so nil and a present-but-default `CreativeGrain()` would render the
    /// same picture and hash differently — and `recipe_fp` keys every preview and
    /// artifact in the catalog, so the second spelling throws away a 45-megapixel
    /// render to produce identical bytes and then reports the photograph as edited.
    /// That is the `look.lut` defect exactly, and `Recipe.renderIdentity` carries the
    /// argument at length. Every writer of this field goes through here, and
    /// `renderIdentity` strips an amount-0 grain as a backstop for the sidecars that
    /// did not.
    public static func normalized(_ grain: CreativeGrain?) -> CreativeGrain? {
        guard let grain, grain != CreativeGrain() else { return nil }
        return grain
    }

    private enum CodingKeys: String, CodingKey {
        case amount, size, roughness
    }

    /// Tolerant of a recipe written before any of these keys existed: each falls back to
    /// the default in the memberwise initializer above. See RecipeDecoding.swift.
    ///
    /// `size` and `roughness` fall back to 50 rather than to 0, for the reason
    /// `Look.vignetteFeather` falls back to 50 rather than to 0: a middle is what the
    /// control means by neutral, and an absent key must decode to the rendering an older
    /// sidecar had — which, with `amount` at 0, is no grain at all whatever these two
    /// say, and with `amount` set by hand in a foreign sidecar is the middle of both
    /// axes rather than the finest possible grain with the smoothest possible plate.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0
        self.size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 50
        self.roughness = try c.decodeIfPresent(Double.self, forKey: .roughness) ?? 50
    }
}

/// Two-tier denoise (D26). `ai` results are cached artifacts, never files (docs/07).
///
/// Tier 1 — the `classic` block — runs in the graph at S3: a profiled variance-stabilizing
/// transform and à-trous shrinkage, `ClassicalDenoise`, driven by the capture ISO's own
/// noise model. Tier 2 does not exist yet; `amount` reaches the RAW decoder's own
/// denoise through `appleStandIn` as a stand-in, and the panel says so.
///
/// `appleStandIn` exists as a named, tested mapping because the wiring was wrong in a
/// way the panel hid: in `.ai` mode the stage read `classic.luma` and `classic.chroma`,
/// which the panel does not show in that mode, and ignored `amount`, which is the only
/// slider it does show. Switching Classic → AI changed nothing, and dragging the AI
/// Amount slider changed nothing.
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
    /// **Classic now hands the decoder nothing.** Tier 1 runs in the graph — a profiled
    /// VST plus à-trous shrinkage, `ClassicalDenoise` — and leaving Apple's stage on
    /// underneath it would denoise the frame twice, once with a model of the sensor and
    /// once with somebody else's guess, with the two smoothings compounding where they
    /// agree. docs/07 §2 calls the decoder's properties a "Milestone-1 stopgap until
    /// this stage ships". It has shipped, so the stopgap comes out.
    ///
    /// It also makes the two Classic sliders cheap: they are no longer part of
    /// `AppleRawSource`'s decode key, so dragging Luminance stopped forcing a full
    /// re-demosaic of a 45-megapixel frame per frame of the drag.
    ///
    /// Off is off. AI follows `amount`, which is the ONLY slider the AI panel shows —
    /// and which the wiring previously ignored in favour of two hidden Classic values,
    /// so the mode switch and the visible slider were both inert. That mapping is still
    /// a stand-in, not a model: Tier 2 is a cached artifact that does not exist yet.
    public var appleStandIn: (luma: Double, chroma: Double) {
        func fraction(_ v: Double) -> Double {
            Num.clamp(v.isFinite ? v : 0, 0, 100) / 100
        }
        switch mode {
        case .off, .classic:
            return (0, 0)
        case .ai:
            let blend = fraction(amount)
            return (blend * 0.6, blend)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case mode, amount, model, classic
    }

    /// Tolerant of a recipe written before any of these keys existed: each falls
    /// back to the default in the memberwise initializer above. See RecipeDecoding.swift.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .classic
        self.amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 50
        self.model = try c.decodeIfPresent(String.self, forKey: .model)
        self.classic = try c.decodeIfPresent(ClassicNR.self, forKey: .classic)
            ?? ClassicNR()
    }
}

/// Tier 1's seven controls (docs/07 §2.1), all of them on the wire.
///
/// Four of these — Luminance Detail, Luminance Contrast, Colour Detail, Colour
/// Smoothness — were engine parameters with no wire format, so `ClassicalDenoise`
/// took them from hardcoded defaults and the panel could not show them. The names,
/// ranges and 50/50 sub-defaults are Lightroom's manual NR contract on purpose: it is
/// muscle memory for every refugee and there is no better parameterization to invent.
///
/// Decoding is tolerant of a recipe written before these existed: the four new keys
/// decode to their documented defaults rather than failing, so an older sidecar still
/// opens and renders what it always rendered.
public struct ClassicNR: Codable, Equatable, Sendable {
    public var luma: Double             // 0…100
    public var chroma: Double           // 0…100, default mild (docs/07)
    public var hotPixels: Double        // 0…100 (D26, single-pixel control)
    /// Shrinkage threshold multiplier on luma: higher preserves texture (and noise).
    public var lumaDetail: Double       // 0…100, default 50
    /// Biases shrinkage away from the coarse luma bands — preserves luminance
    /// contrast at the cost of mottling, LR's own tradeoff.
    public var lumaContrast: Double     // 0…100, default 0
    /// Spatially protects thin colour edges from chroma shrinkage.
    public var colorDetail: Double      // 0…100, default 50
    /// Extends chroma shrinkage into the coarsest bands, where blotches live.
    public var colorSmoothness: Double  // 0…100, default 50

    /// Whether the photographer set `luma` / `chroma` by hand, as opposed to inheriting
    /// the ISO-adaptive resolution at import.
    ///
    /// docs/07 §2.1 and docs/14 both specify that switching to AI Denoise drops the
    /// Tier-1 masters to zero — the noise they were compensating for is gone —
    /// **"unless the user has hand-set them, in which case their values are respected"**.
    /// That sentence needs a bit per master and there was none, so `ISODefaults.classic`
    /// took them as parameters defaulting to `false` and `RenderPlan` called it without
    /// arguments. The exception could not fire: switching to AI zeroed a hand-set
    /// Luminance every time, silently, and the only trace was a default argument at a
    /// call site nobody reads.
    ///
    /// They are `false` by default and serialize sparsely, so no recipe already in a
    /// catalog or a sidecar changes its canonical form or its fingerprint. A photo
    /// edited before this existed is treated as never hand-set, which is what the
    /// coupling assumed about every photo until now.
    public var lumaUserSet: Bool        // default false
    public var chromaUserSet: Bool      // default false

    public init(luma: Double = 0, chroma: Double = 25, hotPixels: Double = 0,
                lumaDetail: Double = 50, lumaContrast: Double = 0,
                colorDetail: Double = 50, colorSmoothness: Double = 50,
                lumaUserSet: Bool = false, chromaUserSet: Bool = false) {
        self.luma = luma
        self.chroma = chroma
        self.hotPixels = hotPixels
        self.lumaDetail = lumaDetail
        self.lumaContrast = lumaContrast
        self.colorDetail = colorDetail
        self.colorSmoothness = colorSmoothness
        self.lumaUserSet = lumaUserSet
        self.chromaUserSet = chromaUserSet
    }

    private enum CodingKeys: String, CodingKey {
        case luma, chroma, hotPixels, lumaDetail, lumaContrast
        case colorDetail, colorSmoothness, lumaUserSet, chromaUserSet
    }

    /// Tolerant of the three-field form this struct used to have. Every recipe already
    /// in a catalog or a sidecar was written before the four sub-sliders existed, and a
    /// strict decode would fail on all of them — the four keys fall back to the
    /// documented defaults, which are exactly the values the engine hardcoded before.
    /// So an old recipe renders what it always rendered.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.luma = try c.decodeIfPresent(Double.self, forKey: .luma) ?? 0
        self.chroma = try c.decodeIfPresent(Double.self, forKey: .chroma) ?? 25
        self.hotPixels = try c.decodeIfPresent(Double.self, forKey: .hotPixels) ?? 0
        self.lumaDetail = try c.decodeIfPresent(Double.self, forKey: .lumaDetail) ?? 50
        self.lumaContrast = try c.decodeIfPresent(Double.self, forKey: .lumaContrast) ?? 0
        self.colorDetail = try c.decodeIfPresent(Double.self, forKey: .colorDetail) ?? 50
        self.colorSmoothness = try c.decodeIfPresent(Double.self,
                                                     forKey: .colorSmoothness) ?? 50
        self.lumaUserSet = try c.decodeIfPresent(Bool.self, forKey: .lumaUserSet) ?? false
        self.chromaUserSet = try c.decodeIfPresent(Bool.self,
                                                   forKey: .chromaUserSet) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(luma, forKey: .luma)
        try c.encode(chroma, forKey: .chroma)
        try c.encode(hotPixels, forKey: .hotPixels)
        try c.encode(lumaDetail, forKey: .lumaDetail)
        try c.encode(lumaContrast, forKey: .lumaContrast)
        try c.encode(colorDetail, forKey: .colorDetail)
        try c.encode(colorSmoothness, forKey: .colorSmoothness)
        try c.encode(lumaUserSet, forKey: .lumaUserSet)
        try c.encode(chromaUserSet, forKey: .chromaUserSet)
    }
}

/// Geometry (docs/09).
///
/// `crop` is normalized to the USABLE frame — the largest axis-aligned rectangle inside
/// the source rotated by `angle`, centred on it (`CropGeometry.usableSize`) — and not to
/// the source frame. The two are the same thing at angle 0, which is why this said
/// "normalized to the source frame" for as long as it did: every uncropped, unstraightened
/// photograph agrees with both readings, and only a straightened one tells them apart.
///
/// Masks are stored in source coordinates and reproject through geometry changes
/// (docs/09 invariant).
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

    private enum CodingKeys: String, CodingKey {
        case crop, angle, flipH, upright, lens
    }

    /// Tolerant of a recipe written before any of these keys existed: each falls
    /// back to the default in the memberwise initializer above. See RecipeDecoding.swift.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.crop = try c.decodeIfPresent(Crop.self, forKey: .crop) ?? Crop()
        self.angle = try c.decodeIfPresent(Double.self, forKey: .angle) ?? 0
        self.flipH = try c.decodeIfPresent(Bool.self, forKey: .flipH) ?? false
        self.upright = try c.decodeIfPresent(Upright.self, forKey: .upright)
        self.lens = try c.decodeIfPresent(LensCorrections.self, forKey: .lens)
            ?? LensCorrections()
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

    private enum CodingKeys: String, CodingKey {
        case x, y, w, h
    }

    /// Tolerant of a recipe written before any of these keys existed: each falls
    /// back to the default in the memberwise initializer above. See RecipeDecoding.swift.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        self.y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        self.w = try c.decodeIfPresent(Double.self, forKey: .w) ?? 1
        self.h = try c.decodeIfPresent(Double.self, forKey: .h) ?? 1
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

    private enum CodingKeys: String, CodingKey {
        case vertical, horizontal, rotate, aspect, scale, offsetX, offsetY, strength
    }

    /// Tolerant of a recipe written before any of these keys existed: each falls
    /// back to the default in the memberwise initializer above. See RecipeDecoding.swift.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.vertical = try c.decodeIfPresent(Double.self, forKey: .vertical) ?? 0
        self.horizontal = try c.decodeIfPresent(Double.self, forKey: .horizontal) ?? 0
        self.rotate = try c.decodeIfPresent(Double.self, forKey: .rotate) ?? 0
        self.aspect = try c.decodeIfPresent(Double.self, forKey: .aspect) ?? 0
        self.scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 100
        self.offsetX = try c.decodeIfPresent(Double.self, forKey: .offsetX) ?? 0
        self.offsetY = try c.decodeIfPresent(Double.self, forKey: .offsetY) ?? 0
        self.strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? 100
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

    private enum CodingKeys: String, CodingKey {
        case profile, removeCA, defringe
    }

    /// Tolerant of a recipe written before any of these keys existed: each falls
    /// back to the default in the memberwise initializer above. See RecipeDecoding.swift.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.profile = try c.decodeIfPresent(Bool.self, forKey: .profile) ?? true
        self.removeCA = try c.decodeIfPresent(Bool.self, forKey: .removeCA) ?? true
        self.defringe = try c.decodeIfPresent(Defringe.self, forKey: .defringe)
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

    private enum CodingKeys: String, CodingKey {
        case purpleAmount, purpleHueLo, purpleHueHi, greenAmount, greenHueLo,
             greenHueHi
    }

    /// Tolerant of a recipe written before any of these keys existed: each falls
    /// back to the default in the memberwise initializer above. See RecipeDecoding.swift.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.purpleAmount = try c.decodeIfPresent(Double.self, forKey: .purpleAmount) ?? 0
        self.purpleHueLo = try c.decodeIfPresent(Double.self, forKey: .purpleHueLo) ?? 30
        self.purpleHueHi = try c.decodeIfPresent(Double.self, forKey: .purpleHueHi) ?? 70
        self.greenAmount = try c.decodeIfPresent(Double.self, forKey: .greenAmount) ?? 0
        self.greenHueLo = try c.decodeIfPresent(Double.self, forKey: .greenHueLo) ?? 40
        self.greenHueHi = try c.decodeIfPresent(Double.self, forKey: .greenHueHi) ?? 60
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

    private enum CodingKeys: String, CodingKey {
        case strokesRef, count
    }

    /// Tolerant of a recipe written before any of these keys existed: each falls
    /// back to the default in the memberwise initializer above. See RecipeDecoding.swift.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.strokesRef = try c.decodeIfPresent(String.self, forKey: .strokesRef)
        self.count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
    }
}
