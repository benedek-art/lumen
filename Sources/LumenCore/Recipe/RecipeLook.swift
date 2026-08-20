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

    public static let defaultPivots: [Double] = [0.33, 0.67]

    public init(global: Wheel = Wheel(), shadows: Wheel = Wheel(),
                mid: Wheel = Wheel(), high: Wheel = Wheel(),
                blending: Double = 50, balance: Double = 0,
                pivots: [Double] = GradingWheels.defaultPivots) {
        self.global = global
        self.shadows = shadows
        self.mid = mid
        self.high = high
        self.blending = blending
        self.balance = balance
        self.pivots = pivots
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
    public var isNeutral: Bool {
        func neutral(_ w: Wheel) -> Bool { w.sat == 0 && w.lum == 0 }
        return neutral(global) && neutral(shadows) && neutral(mid) && neutral(high)
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

/// B&W treatment (D20): 8-band mix, same band order as Mixer. Non-nil = B&W on.
/// Mixer/band state is preserved when toggling treatments (fixes LR's state-loss bug).
public struct BlackAndWhite: Codable, Equatable, Sendable {
    public var bands: [Double]      // 8 luminance contributions, −100…+100

    public init(bands: [Double] = Array(repeating: 0, count: 8)) {
        self.bands = bands
    }
}
