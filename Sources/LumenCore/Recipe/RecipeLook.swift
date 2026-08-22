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
    public var vignette: Double         // EV, −3.00…+1.00 (docs/06); 0 = off
    public var render: RenderParams
    public var lut: LUTReference?

    public init(wheels: GradingWheels = GradingWheels(),
                printerLights: PrinterLights = PrinterLights(),
                filmLab: FilmLab? = nil,
                primaries: Primaries = Primaries(),
                bw: BlackAndWhite? = nil,
                vignette: Double = 0,
                render: RenderParams = RenderParams(),
                lut: LUTReference? = nil) {
        self.wheels = wheels
        self.printerLights = printerLights
        self.filmLab = filmLab
        self.primaries = primaries
        self.bw = bw
        self.vignette = vignette
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
}

/// A user `.cube` LUT applied at one of the two documented taps (docs/14 §2.3):
/// `display` = after the transform (the common case for SDR-referred LUT packs),
/// `log` = before it, on a fixed log encoding.
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
    public var grain: FilmGrain
    public var printSize: String?   // grain anchor, e.g. "8x10"; nil = long-edge default

    public init(stock: String, amount: Double = 100, exposure: Double = 0,
                pushPull: Double = 0,
                halation: Double = 0, grain: FilmGrain = FilmGrain(),
                printSize: String? = nil) {
        self.stock = stock
        self.amount = amount
        self.exposure = exposure
        self.pushPull = pushPull
        self.halation = halation
        self.grain = grain
        self.printSize = printSize
    }
}

public struct FilmGrain: Codable, Equatable, Sendable {
    public var size: Double     // relative grain pitch, 1.0 = stock default
    public var amount: Double   // 0…100

    public init(size: Double = 1.0, amount: Double = 0) {
        self.size = size
        self.amount = amount
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
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.bands = try c.decodeIfPresent([Double].self, forKey: .bands)
            ?? Array(repeating: 0, count: 8)
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
