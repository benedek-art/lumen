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

    public init(wheels: GradingWheels = GradingWheels(),
                printerLights: PrinterLights = PrinterLights(),
                filmLab: FilmLab? = nil,
                primaries: Primaries = Primaries(),
                bw: BlackAndWhite? = nil,
                vignette: Double = 0) {
        self.wheels = wheels
        self.printerLights = printerLights
        self.filmLab = filmLab
        self.primaries = primaries
        self.bw = bw
        self.vignette = vignette
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
    public var pushPull: Double     // −1…+2 stops (couples curve+grain+crossover, docs/05)
    public var halation: Double     // 0…100
    public var grain: FilmGrain
    public var printSize: String?   // grain anchor, e.g. "8x10"; nil = long-edge default

    public init(stock: String, amount: Double = 100, pushPull: Double = 0,
                halation: Double = 0, grain: FilmGrain = FilmGrain(),
                printSize: String? = nil) {
        self.stock = stock
        self.amount = amount
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
