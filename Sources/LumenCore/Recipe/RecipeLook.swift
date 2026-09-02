// RecipeLook.swift
// The Look layer: the portable creative subtree of the recipe (D4).
// "Apply this Look to 800 frames" copies exactly this struct (plus look-tagged masks).
// Format authority: docs/15-catalog.md §15.4; feature specs: docs/05-spec-color.md.

import Foundation

public struct Look: Codable, Equatable, Sendable {
    public var wheels: GradingWheels
    public var printerLights: PrinterLights
    public var filmLab: FilmLab?
    public var primaries: Primaries
    public var bw: BlackAndWhite?
    /// EV at the frame's corner; 0 = off. −4.00…+2.00, widened from docs/06 §12's
    /// −3.00…+1.00 by the measurement on `DetailEngine.vignetteAmountRange` — the old
    /// bounds cut the control off while it was still delivering 73% (negative) and 81%
    /// (positive) of its rate at zero. Every stored recipe is inside the old range, so
    /// the widening moves no existing pixel.
    public var vignette: Double
    /// Vignette feather, 0…100. How gradually the burn arrives: 0 is a tight ring at
    /// the frame's outer quarter, 100 a falloff spanning the whole frame from the
    /// centre. The DEFAULT is the geometry the engine always had — the docs/06 §12
    /// disclosure default the renderers carried as a constant — so every recipe
    /// written before the field existed renders byte-identically
    /// (`DetailEngine.vignetteInnerRadius(feather:)` holds the mapping, and
    /// `VignetteFeatherTests` pins the identity).
    public var vignetteFeather: Double
    /// Creative grain — the grain stage for a photograph carrying no film stock. It is
    /// in `look` and not in `develop` because it is an expression of intent about a set
    /// of frames rather than a fact about this one, which is the D4 test and the reason
    /// `LookSubset` carries it with no change: a saved look that dropped its grain would
    /// apply a different picture than it saved. See `CreativeGrain` for the whole
    /// mapping and for why it is not a second grain implementation.
    ///
    /// It does NOT replace `filmLab.grain`. A loaded stock's grain is the stock's, and
    /// while the film chain is live that is what renders; this is what renders when
    /// there is no chain — which includes the case a photographer actually hits, Film
    /// Lab Strength pulled to 0 for the texture without the palette, where the answer
    /// used to be no grain at all and a caption apologizing for it.
    ///
    /// OPTIONAL, like `filmLab`, `bw` and `lut` beside it, and nil means "this
    /// photograph has never had creative grain on it". A photograph that has never seen
    /// the control should not carry three numbers, and a non-optional field would put a
    /// `grain` block into the canonical form of the DEFAULT recipe — which is a wire
    /// format change for every photograph in every catalog rather than for the ones a
    /// photographer grained. `CreativeGrain.normalized` is what keeps nil the only
    /// spelling of "off", so two recipes that render the same picture still hash the
    /// same.
    public var grain: CreativeGrain?
    public var render: RenderParams
    /// A creative LUT. **Stored and never applied** — see `LUTReference`.
    public var lut: LUTReference?

    /// The feather value that reproduces the fixed geometry recipes have always
    /// rendered with. Named once, here, because the decoder, the panel's default, the
    /// section's Reset and the engine's constant fallback all have to agree on it.
    public static let vignetteFeatherDefault: Double = 50

    public init(wheels: GradingWheels = GradingWheels(),
                printerLights: PrinterLights = PrinterLights(),
                filmLab: FilmLab? = nil,
                primaries: Primaries = Primaries(),
                bw: BlackAndWhite? = nil,
                vignette: Double = 0,
                vignetteFeather: Double = Look.vignetteFeatherDefault,
                grain: CreativeGrain? = nil,
                render: RenderParams = RenderParams(),
                lut: LUTReference? = nil) {
        self.wheels = wheels
        self.printerLights = printerLights
        self.filmLab = filmLab
        self.primaries = primaries
        self.bw = bw
        self.vignette = vignette
        self.vignetteFeather = vignetteFeather
        self.grain = grain
        self.render = render
        self.lut = lut
    }

    /// Whether the black-and-white treatment renders.
    ///
    /// Stated once because two places have to agree about it — the panel's toggle and
    /// the colour stage that reads it — and they used to agree by both testing the slot
    /// for nil, which is exactly the test that stopped being the right one when the mix
    /// gained somewhere to live while switched off.
    public var blackAndWhiteIsOn: Bool { bw?.enabled == true }

    private enum CodingKeys: String, CodingKey {
        case wheels, printerLights, filmLab, primaries, bw, vignette, vignetteFeather,
             grain, render, lut
    }

    /// Tolerant of a recipe written before any of these keys existed: each falls
    /// back to the default in the memberwise initializer above. See RecipeDecoding.swift.
    /// `vignetteFeather`'s default is NOT zero — it is the fixed geometry every older
    /// sidecar was rendered with, so an absent key keeps yesterday's pixels.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.wheels = try c.decodeIfPresent(GradingWheels.self, forKey: .wheels)
            ?? GradingWheels()
        self.printerLights = try c.decodeIfPresent(PrinterLights.self, forKey: .printerLights)
            ?? PrinterLights()
        self.filmLab = try c.decodeIfPresent(FilmLab.self, forKey: .filmLab)
        self.primaries = try c.decodeIfPresent(Primaries.self, forKey: .primaries)
            ?? Primaries()
        self.bw = try c.decodeIfPresent(BlackAndWhite.self, forKey: .bw)
        self.vignette = try c.decodeIfPresent(Double.self, forKey: .vignette) ?? 0
        self.vignetteFeather = try c.decodeIfPresent(Double.self, forKey: .vignetteFeather)
            ?? Look.vignetteFeatherDefault
        // Absent means no creative grain, so every sidecar written before this key
        // existed renders byte-identically. `CreativeGrain`'s own decoder is what makes
        // a PARTIAL block (a hand-edited `{"amount":40}`) land on the middle of the
        // other two axes rather than on zero.
        self.grain = try c.decodeIfPresent(CreativeGrain.self, forKey: .grain)
        self.render = try c.decodeIfPresent(RenderParams.self, forKey: .render)
            ?? RenderParams()
        self.lut = try c.decodeIfPresent(LUTReference.self, forKey: .lut)
    }
}

/// The display transform's user-facing parameters (D8). Overrides are optional so a
/// recipe that just says "Punchy" stays one word on the wire and follows the preset
/// if the preset is ever retuned — while an explicit tweak pins itself forever.
public struct RenderParams: Codable, Equatable, Sendable {
    public var preset: String            // "Neutral" | "Soft" | "Punchy" | "Film Base" | "Linear"
    public var contrast: Double?         // 0.1…10, log-scaled slider
    public var skew: Double?             // −1…+1
    public var huePreservation: Double?  // 0…100
    public var blackTarget: Double?      // 0…15 % of SDR white
    /// % of SDR white. nil = follow the display's live EDR headroom (docs/14 §7).
    public var whiteTarget: Double?

    public init(preset: String = "Neutral", contrast: Double? = nil, skew: Double? = nil,
                huePreservation: Double? = nil, blackTarget: Double? = nil,
                whiteTarget: Double? = nil) {
        self.preset = preset
        self.contrast = contrast
        self.skew = skew
        self.huePreservation = huePreservation
        self.blackTarget = blackTarget
        self.whiteTarget = whiteTarget
    }

    /// Resolve to engine parameters, preset first, explicit overrides on top.
    public func resolved(displayWhiteTarget: Double? = nil) -> DisplayTransformParams {
        var p = DisplayTransformParams.preset(named: preset)
        if let contrast { p.contrast = contrast }
        if let skew { p.skew = skew }
        if let huePreservation { p.huePreservation = huePreservation }
        if let blackTarget { p.blackTarget = blackTarget }
        if let whiteTarget {
            p.whiteTarget = whiteTarget
        } else if let displayWhiteTarget {
            p.whiteTarget = displayWhiteTarget
        }
        return p
    }

    private enum CodingKeys: String, CodingKey {
        case preset, contrast, skew, huePreservation, blackTarget, whiteTarget
    }

    /// Tolerant of a recipe written before any of these keys existed: each falls
    /// back to the default in the memberwise initializer above. See RecipeDecoding.swift.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.preset = try c.decodeIfPresent(String.self, forKey: .preset) ?? "Neutral"
        self.contrast = try c.decodeIfPresent(Double.self, forKey: .contrast)
        self.skew = try c.decodeIfPresent(Double.self, forKey: .skew)
        self.huePreservation = try c.decodeIfPresent(Double.self, forKey: .huePreservation)
        self.blackTarget = try c.decodeIfPresent(Double.self, forKey: .blackTarget)
        self.whiteTarget = try c.decodeIfPresent(Double.self, forKey: .whiteTarget)
    }
}

/// A user `.cube` LUT applied at one of the two documented taps (docs/14 §2.3):
/// `display` = after the transform (the common case for SDR-referred LUT packs),
/// `log` = before it, on a fixed log encoding.
/// A creative LUT, as the wire format will name one — **and nothing renders it.**
///
/// This is a reserved slot, not a feature. There is no stage that reads it on any path:
/// not `RenderGraph`, not `export`, not `ReferenceRenderer`. `LUT3D.fromCubeFile` can
/// parse a `.cube` and has only test callers, and there is no UI that would ever set
/// `Look.lut` — the only way a recipe acquires one is a hand-edited sidecar, and that
/// sidecar renders exactly like one without it.
///
/// Said here, at the definition, because a `Codable` field that survives the recipe, the
/// sidecar and the catalog looks from every one of those three places like a capability.
/// `Recipe.renderIdentity` strips it, so the inertness is mechanical rather than a
/// promise in a comment: two recipes differing only in a LUT are equal to the fingerprint
/// and to `rendersSameAs`, which is the truth about the pixels they produce.
///
/// `tap` and `amount` describe how a LUT WOULD be applied — after the display transform
/// or in log, blended by percent. They are design, not behaviour, and they will only
/// start meaning something when a stage reads them.
public struct LUTReference: Codable, Equatable, Sendable {
    public enum Tap: String, Codable, Sendable { case display, log }
    public var ref: String        // "blob:xxh64:<hash>" or a bundled LUT id
    public var name: String
    public var tap: Tap
    public var amount: Double     // 0…100

    public init(ref: String, name: String = "", tap: Tap = .display, amount: Double = 100) {
        self.ref = ref
        self.name = name
        self.tap = tap
        self.amount = amount
    }

    private enum CodingKeys: String, CodingKey {
        case ref, name, tap, amount
    }

    /// Tolerant of an absent key. `ref` has no default in the memberwise initializer —
    /// a LUT reference with nothing to reference is meaningless — and falls back to the
    /// empty string here, which is the reading that costs least: no stage reads this slot
    /// on any path, and an empty ref would resolve to no LUT on the day one does.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.ref = try c.decodeIfPresent(String.self, forKey: .ref) ?? ""
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.tap = try c.decodeIfPresent(Tap.self, forKey: .tap) ?? .display
        self.amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 100
    }
}

/// Three-way grading wheels + global, with VISIBLE, adjustable zone pivots (D15).
public struct GradingWheels: Codable, Equatable, Sendable {
    public var global: Wheel
    public var shadows: Wheel
    public var mid: Wheel
    public var high: Wheel
    public var blending: Double     // 0…100, zone crossover softness
    public var balance: Double      // −100…+100, shifts zone boundaries
    public var pivots: [Double]     // two boundaries on the normalized tonal axis
    /// The advanced disclosure (docs/05 §D15): master hue shift + vibrance, and
    /// chroma / saturation / brilliance across the same three zones. Engine and maths:
    /// `ColorBalanceGrid` in GradeEngine.swift.
    ///
    /// Note the name. `balance` above is the ZONE balance — which way the two pivots
    /// slide — and has nothing to do with darktable's colour balance rgb. Two fields
    /// one letter apart would have been the next bug in this file.
    public var colorBalance: ColorBalanceParams

    public static let defaultPivots: [Double] = [0.33, 0.67]

    public init(global: Wheel = Wheel(), shadows: Wheel = Wheel(),
                mid: Wheel = Wheel(), high: Wheel = Wheel(),
                blending: Double = 50, balance: Double = 0,
                pivots: [Double] = GradingWheels.defaultPivots,
                colorBalance: ColorBalanceParams = ColorBalanceParams()) {
        self.global = global
        self.shadows = shadows
        self.mid = mid
        self.high = high
        self.blending = blending
        self.balance = balance
        self.pivots = pivots
        self.colorBalance = colorBalance
    }

    private enum CodingKeys: String, CodingKey {
        case global, shadows, mid, high, blending, balance, pivots, colorBalance
    }

    /// Tolerant of a recipe written before any of these keys existed: each falls
    /// back to the default in the memberwise initializer above. See RecipeDecoding.swift.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.global = try c.decodeIfPresent(Wheel.self, forKey: .global) ?? Wheel()
        self.shadows = try c.decodeIfPresent(Wheel.self, forKey: .shadows) ?? Wheel()
        self.mid = try c.decodeIfPresent(Wheel.self, forKey: .mid) ?? Wheel()
        self.high = try c.decodeIfPresent(Wheel.self, forKey: .high) ?? Wheel()
        self.blending = try c.decodeIfPresent(Double.self, forKey: .blending) ?? 50
        self.balance = try c.decodeIfPresent(Double.self, forKey: .balance) ?? 0
        self.pivots = RecipeWire.fixedLength(
            try c.decodeIfPresent([Double].self, forKey: .pivots),
            default: GradingWheels.defaultPivots)
        self.colorBalance = try c.decodeIfPresent(ColorBalanceParams.self, forKey: .colorBalance)
            ?? ColorBalanceParams()
    }
}

public struct Wheel: Codable, Equatable, Sendable {
    public var hue: Double      // 0…360 degrees
    public var sat: Double      // 0…1, distance from wheel center
    public var lum: Double      // −1…+1, per-wheel luminance

    public init(hue: Double = 0, sat: Double = 0, lum: Double = 0) {
        self.hue = hue
        self.sat = sat
        self.lum = lum
    }

    private enum CodingKeys: String, CodingKey {
        case hue, sat, lum
    }

    /// Tolerant of a recipe written before any of these keys existed: each falls
    /// back to the default in the memberwise initializer above. See RecipeDecoding.swift.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.hue = try c.decodeIfPresent(Double.self, forKey: .hue) ?? 0
        self.sat = try c.decodeIfPresent(Double.self, forKey: .sat) ?? 0
        self.lum = try c.decodeIfPresent(Double.self, forKey: .lum) ?? 0
    }
}

extension GradingWheels {

    /// True when every wheel is at its neutral, whatever the zone geometry says.
    ///
    /// Pivots, blending and balance describe WHERE the zones sit, not how hard they
    /// push, so a grade with moved pivots and untouched wheels is still the identity
    /// and must not cost a table.
    ///
    /// Tested on magnitude rather than by comparing against `Wheel()`, because hue with
    /// no saturation behind it is not a colour. A full-equality test also breaks
    /// `scalingShift(by: 0)`, which zeroes `sat` and `lum` and deliberately keeps
    /// `hue` — a mask at zero Amount would have declared itself non-identity and paid
    /// for a table that computes nothing.
    /// The advanced grid is part of this test, not beside it: `LocalPlan` and
    /// `GradeEngine.isIdentity` both consult `isNeutral` to decide whether to bake a
    /// table at all, so a grade whose only move is +40 Brilliance has to answer false
    /// here or it renders its input and the disclosure is inert inside every mask.
    public var isNeutral: Bool {
        func neutral(_ w: Wheel) -> Bool { w.sat == 0 && w.lum == 0 }
        return neutral(global) && neutral(shadows) && neutral(mid) && neutral(high)
            && colorBalance.isZero
    }

    /// The per-mask Amount, applied to a grade.
    ///
    /// `sat` and `lum` are magnitudes and scale. `hue` is an ANGLE and does not:
    /// scaling it would rotate the grade toward red as the mask weakened rather than
    /// weaken it, so a mask at 50% would be a different colour rather than half as
    /// much of the same one. Zone geometry is left alone for the reason above.
    public func scalingShift(by scale: Double) -> GradingWheels {
        guard scale != 1, scale.isFinite else { return self }
        func scaled(_ w: Wheel) -> Wheel {
            Wheel(hue: w.hue, sat: w.sat * scale, lum: w.lum * scale)
        }
        var copy = self
        copy.global = scaled(global)
        copy.shadows = scaled(shadows)
        copy.mid = scaled(mid)
        copy.high = scaled(high)
        // The grid scales too, including its hue shift — see `ColorBalanceParams.scaled`
        // for why that angle scales where a wheel's does not. Leaving it out would have
        // reproduced, one disclosure lower, the exact bug `PointColor.scalingShift`
        // exists to fix: a mask at Amount 0 whose grid still pushed at full strength.
        copy.colorBalance = colorBalance.scaled(by: scale)
        return copy
    }

    /// This grade with ITS colour moves inside the GLOBAL wheels' tonal windows —
    /// pivots, blending and balance taken from `global`, everything else kept.
    ///
    /// This is the contract docs/08 §8.4 states and `ZoneWindows.init(wheels:)`
    /// documents — "a mask gets no tonal-zone definition of its own" — and for the
    /// wheels' whole life both render paths quietly violated it: a masked grade was
    /// built from the MASK's own wheels value, whose window fields no mask control
    /// can write, so the photographer who dragged the global pivots onto their
    /// picture's real shadow boundary got a masked grade zoned by the factory
    /// defaults instead (COLOR-16). The rule is stated once, here, so the two paths
    /// cannot re-diverge about it.
    public func adoptingWindows(from global: GradingWheels) -> GradingWheels {
        var copy = self
        copy.pivots = global.pivots
        copy.blending = global.blending
        copy.balance = global.balance
        return copy
    }
}

/// Printer lights (D16): master exposure + per-channel trims in log space,
/// denominated in points of 1/12 stop, keyboard-steppable. Neutral = 0.
public struct PrinterLights: Codable, Equatable, Sendable {
    public var master: Int
    public var r: Int
    public var g: Int
    public var b: Int

    public init(master: Int = 0, r: Int = 0, g: Int = 0, b: Int = 0) {
        self.master = master
        self.r = r
        self.g = g
        self.b = b
    }

    private enum CodingKeys: String, CodingKey {
        case master, r, g, b
    }

    /// Tolerant of a recipe written before any of these keys existed: each falls
    /// back to the default in the memberwise initializer above. See RecipeDecoding.swift.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.master = try c.decodeIfPresent(Int.self, forKey: .master) ?? 0
        self.r = try c.decodeIfPresent(Int.self, forKey: .r) ?? 0
        self.g = try c.decodeIfPresent(Int.self, forKey: .g) ?? 0
        self.b = try c.decodeIfPresent(Int.self, forKey: .b) ?? 0
    }
}

/// The Film Lab (D18): preset-first; a stock parameterizes the display-transform
/// slot (docs/14 §S14) with halation/grain as its spatial layers.
public struct FilmLab: Codable, Equatable, Sendable {
    public var stock: String        // e.g. "lumen/portra400"
    public var amount: Double       // 0…100 blend with the neutral rendering
    /// Pre-curve exposure INTO the stock, −2…+3 EV. Not the same control as Develop's
    /// Exposure: the characteristic curves live in log exposure, so shifting the scene
    /// along that axis moves it into a different part of the stock's latitude — the
    /// pastel highlights of an overexposed negative, the thick shadows of a pulled one.
    /// docs/05 calls this the thing no preset pack can express, and it is exactly why
    /// it cannot be emulated by putting Exposure ahead of the film stage.
    public var exposure: Double
    public var pushPull: Double     // −1…+2 stops (couples curve+grain+crossover, docs/05)
    public var halation: Double     // 0…100
    /// The halo's RADIUS against the stock's own, 0.5…2.0. 1.0 is the emulsion's
    /// measured 65 µm at the gate.
    ///
    /// `HalationProfile.init` has taken this and used it for real — `sigma1 = 65µm/1000
    /// × size / gate × px` — since it was written, and both of its callers passed the
    /// default. Two working controls, no way to reach them: every stock's halo was the
    /// same radius scaled only by its gate, so CineStill's large red bloom could not be
    /// asked for (C2-05). Denominated at the GATE like grain's Size, so the halo is the
    /// same fraction of the picture at every delivery size.
    ///
    /// OPTIONAL, like `printSize` and `halationRedness` beside it, and for a reason
    /// this file's sparse-serialization contract makes load-bearing: `look.filmLab` is
    /// itself nil on a default `Recipe`, so `CanonicalJSON.sparse` has no default
    /// subtree to diff a present film lab against and EVERY non-optional key in it
    /// serializes. A plain `Double = 1.0` would therefore have written a new key into
    /// every recipe that has ever loaded a stock. Nil means 1.0 — read it through
    /// `effectiveHalationSize`.
    public var halationSize: Double?
    /// How far the halo is pulled toward pure red, 0…100, or nil for the stock's own
    /// measured `halationRedness`.
    ///
    /// Optional rather than defaulted to a number because "the emulsion's" is a real
    /// answer and not a value: a stock's redness is a property of its anti-halation
    /// layer, and writing 15 into every recipe that loads Portra would silently pin it
    /// if the stock were ever re-measured.
    public var halationRedness: Double?
    public var grain: FilmGrain
    public var printSize: String?   // grain anchor, e.g. "8x10"; nil = long-edge default

    public init(stock: String, amount: Double = 100, exposure: Double = 0,
                pushPull: Double = 0,
                halation: Double = 0,
                halationSize: Double? = nil, halationRedness: Double? = nil,
                grain: FilmGrain = FilmGrain(),
                printSize: String? = nil) {
        self.stock = stock
        self.amount = amount
        self.exposure = exposure
        self.pushPull = pushPull
        self.halation = halation
        self.halationSize = halationSize
        self.halationRedness = halationRedness
        self.grain = grain
        self.printSize = printSize
    }

    /// The halo radius multiplier the engine uses: the recipe's, or the emulsion's own
    /// 1.0. One accessor, so no caller spells the fallback for itself.
    public var effectiveHalationSize: Double { halationSize ?? 1.0 }

    private enum CodingKeys: String, CodingKey {
        case stock, amount, exposure, pushPull, halation
        case halationSize, halationRedness
        case grain, printSize
    }

    /// Tolerant of an absent key. `stock` has no default in the memberwise initializer,
    /// because a film lab with no stock is not a film lab; it falls back to the empty
    /// string, which `FilmStock.named` answers with nil, so the stage renders nothing
    /// rather than picking a stock the photographer never chose.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.stock = try c.decodeIfPresent(String.self, forKey: .stock) ?? ""
        self.amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 100
        self.exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        self.pushPull = try c.decodeIfPresent(Double.self, forKey: .pushPull) ?? 0
        self.halation = try c.decodeIfPresent(Double.self, forKey: .halation) ?? 0
        // Both absent from every recipe written before they existed, and both stay
        // absent from one that never sets them: they are optional precisely so that a
        // present `filmLab` — whose keys all serialize, since a default `Recipe` has no
        // film lab to diff against — does not gain two on the way back out.
        self.halationSize = try c.decodeIfPresent(Double.self, forKey: .halationSize)
        self.halationRedness = try c.decodeIfPresent(Double.self, forKey: .halationRedness)
        self.grain = try c.decodeIfPresent(FilmGrain.self, forKey: .grain) ?? FilmGrain()
        self.printSize = try c.decodeIfPresent(String.self, forKey: .printSize)
    }
}

public struct FilmGrain: Codable, Equatable, Sendable {
    public var size: Double     // relative grain pitch, 1.0 = stock default
    public var amount: Double   // 0…100

    public init(size: Double = 1.0, amount: Double = 0) {
        self.size = size
        self.amount = amount
    }

    private enum CodingKeys: String, CodingKey {
        case size, amount
    }

    /// Tolerant of a recipe written before any of these keys existed: each falls
    /// back to the default in the memberwise initializer above. See RecipeDecoding.swift.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 1.0
        self.amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0
    }
}

/// Primaries panel (D19): input primary remap. All defaults 0 = identity.
public struct Primaries: Codable, Equatable, Sendable {
    public var rHue: Double
    public var rPurity: Double
    public var gHue: Double
    public var gPurity: Double
    public var bHue: Double
    public var bPurity: Double
    public var tintHue: Double
    public var tintPurity: Double

    public init(rHue: Double = 0, rPurity: Double = 0, gHue: Double = 0,
                gPurity: Double = 0, bHue: Double = 0, bPurity: Double = 0,
                tintHue: Double = 0, tintPurity: Double = 0) {
        self.rHue = rHue
        self.rPurity = rPurity
        self.gHue = gHue
        self.gPurity = gPurity
        self.bHue = bHue
        self.bPurity = bPurity
        self.tintHue = tintHue
        self.tintPurity = tintPurity
    }

    private enum CodingKeys: String, CodingKey {
        case rHue, rPurity, gHue, gPurity, bHue, bPurity, tintHue, tintPurity
    }

    /// Tolerant of a recipe written before any of these keys existed: each falls
    /// back to the default in the memberwise initializer above. See RecipeDecoding.swift.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.rHue = try c.decodeIfPresent(Double.self, forKey: .rHue) ?? 0
        self.rPurity = try c.decodeIfPresent(Double.self, forKey: .rPurity) ?? 0
        self.gHue = try c.decodeIfPresent(Double.self, forKey: .gHue) ?? 0
        self.gPurity = try c.decodeIfPresent(Double.self, forKey: .gPurity) ?? 0
        self.bHue = try c.decodeIfPresent(Double.self, forKey: .bHue) ?? 0
        self.bPurity = try c.decodeIfPresent(Double.self, forKey: .bPurity) ?? 0
        self.tintHue = try c.decodeIfPresent(Double.self, forKey: .tintHue) ?? 0
        self.tintPurity = try c.decodeIfPresent(Double.self, forKey: .tintPurity) ?? 0
    }
}

/// B&W treatment (D20): 8-band mix, same band order as Mixer.
///
/// `enabled` is what makes the mix survive, and it is the difference between this
/// struct and the one that shipped. Before it existed, "off" was spelled by deleting
/// the whole slot, so the eight numbers a photographer had built had nowhere to live
/// across a toggle except the panel's own view state — which belongs to a view, not to
/// a photo. Toggling off on one frame and on again on another wrote the first frame's
/// mix into the second frame's recipe, every photo of a multi-selection got the same
/// transplant, and quitting threw the mix away. The mix lives here now, per photo, and
/// the toggle moves one boolean.
///
/// `bw == nil` still means "this photo has never had a black-and-white mix". The
/// section's Reset restores that, and it is the only thing that discards a mix.
public struct BlackAndWhite: Codable, Equatable, Sendable {
    public var bands: [Double]      // 8 luminance contributions, −100…+100
    /// Whether the treatment renders. `false` means "off, and here is the mix I had".
    public var enabled: Bool

    public init(bands: [Double] = Array(repeating: 0, count: 8), enabled: Bool = true) {
        self.bands = bands
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case bands, enabled
    }

    /// Decode tolerance for every recipe written before `enabled` existed (pipeline
    /// version 1): back then the PRESENCE of the slot was the treatment being on, so an
    /// absent key reads as `true`. Reading it as `false` would turn every
    /// black-and-white photo in an existing catalog back to colour on first open, which
    /// is the same class of silent loss the field exists to end. `bands` is tolerant for
    /// the reason `Mask` states above its own decoder: a recipe is user work, and losing
    /// it to one absent key is not an acceptable failure mode.
    /// `bands` is tolerant of a WRONG LENGTH as well, which absence alone did not
    /// cover. `ColorEngine` reads eight of them and the panel draws eight rows; a mix
    /// that arrived with five would have survived this decoder and been read past its
    /// end downstream — the same lost work as a thrown error, minus the error. See
    /// `RecipeWire.fixedLength`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.bands = RecipeWire.fixedLength(
            try c.decodeIfPresent([Double].self, forKey: .bands),
            default: Array(repeating: 0, count: 8))
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    /// The `look.bw` slot after the treatment toggle is set to `on`.
    ///
    /// The whole state rule, in one place, because it is a rule about a recipe and not
    /// about a panel — which is what made the old version wrong. It ran inside a
    /// SwiftUI view, over a stash that named no photo, in a target with no tests to
    /// notice. Stated here it is a pure function of one photo's own slot, so applying it
    /// across a multi-selection gives every photo back its OWN mix.
    ///
    /// Turning it on with nothing stored starts from a flat mix rather than from
    /// whatever the previous photo happened to be set to. Turning it off keeps the mix
    /// — unless there is no mix, in which case the slot goes away again rather than
    /// leaving eight zeroes behind. A photo the user switched on, changed nothing in
    /// and switched off is a photo that was never edited, and every "is this modified"
    /// question in the app compares against a default recipe.
    public static func toggled(_ current: BlackAndWhite?, on: Bool) -> BlackAndWhite? {
        guard var next = current else { return on ? BlackAndWhite() : nil }
        if !on && !next.hasMix { return nil }
        next.enabled = on
        return next
    }

    /// Whether the eight bands say anything. A flat mix is not a mix — it is the plain
    /// luminance conversion — so there is nothing in it worth giving back.
    ///
    /// The invariant this buys, which the panel reads: a non-nil, switched-off slot
    /// always carries a real mix.
    public var hasMix: Bool { bands.contains { $0 != 0 } }
}
