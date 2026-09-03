// Dither.swift
// Ordered dither for the 8-bit quantize (docs/11 §Format: "8-bit targets are dithered
// from the f32 pipeline during quantization to prevent gradient banding").
//
// There was no dithering code anywhere in the repository, and a smooth sky quantized to
// 256 codes bands visibly — the artefact is worst in exactly the frames people care
// most about, because a clean gradient is what makes it visible.
//
// THE UNIT, stated first because this is the codebase's recurring bug in a new dress.
// A dither has to be one output CODE wide, and a code is not a fixed distance in linear
// light: with the sRGB transfer curve, code 1 is 0.0003 of display white and code 255 is
// 0.008 — a factor of 27 between the two ends. A constant linear amplitude is therefore
// wrong everywhere but one luminance: at 1/255 it would be 27 codes of noise in the
// shadows, and at 0.0003 it would be a thirtieth of a code in the highlights and do
// nothing at all. `codeStep` writes the conversion — encode, step one code, decode —
// rather than any number derived from it.

import Foundation

public enum Dither {

    /// Side of the ordered matrix. 8×8 is the standard Bayer size: large enough that
    /// the pattern does not read as texture at 100%, small enough to tile cheaply and
    /// to stay deterministic, which is what keeps two renders of one file identical.
    public static let matrixSide: Int = 8

    /// The recursion depth that produces `matrixSide`: 8 = 2³.
    private static let matrixBits: Int = 3

    /// The Bayer index at (x, y), in 0..<64. Every cell is distinct, which is the
    /// property that makes an ordered dither spread error evenly rather than clumping.
    ///
    /// The classic bit-interleave construction: the index is built by interleaving the
    /// bits of `y` with the bits of `x ^ y`, most significant first. That is the same
    /// matrix the recursive doubling produces, without materialising the recursion.
    public static func index(x: Int, y: Int) -> Int {
        let side = matrixSide
        // `%` is remainder, not modulo, and gives a negative answer for a negative
        // operand — which would index outside the matrix rather than wrapping it.
        let xw = ((x % side) + side) % side
        let yw = ((y % side) + side) % side
        let mixed = xw ^ yw
        var value = 0
        var bit = matrixBits - 1
        while bit >= 0 {
            value = (value << 1) | ((yw >> bit) & 1)
            value = (value << 1) | ((mixed >> bit) & 1)
            bit -= 1
        }
        return value
    }

    /// The dither offset at (x, y), in (−0.5, +0.5) — a fraction of ONE output code.
    ///
    /// Centred on zero, so the dither adds no bias: averaged over a tile it moves the
    /// picture nowhere, and what it does instead is decide the rounding direction of
    /// each pixel in proportion to how far between two codes the true value sits.
    public static func offset(x: Int, y: Int) -> Double {
        let cells = Double(matrixSide * matrixSide)
        return (Double(index(x: x, y: y)) + 0.5) / cells - 0.5
    }

    /// The width, in display-linear units, of one output code at this linear value.
    ///
    /// Written as the conversion — encode, take half a code either way, decode — and
    /// never as a constant, per BUILDING.md's rule. At the ends of the range the span
    /// is clipped to what exists, which is right: there is no code below 0 or above 1
    /// to dither toward.
    public static func codeStep(_ linear: Double, transfer: TransferFunction,
                                levels: Int) -> Double {
        guard levels > 1 else { return 0 }
        let half = 0.5 / Double(levels - 1)
        let encoded = transfer.encode(Num.saturate(linear))
        guard encoded.isFinite else { return 0 }
        let hi = transfer.decode(Swift.min(1, encoded + half))
        let lo = transfer.decode(Swift.max(0, encoded - half))
        let step = hi - lo
        return step.isFinite && step > 0 ? step : 0
    }

    /// One dithered display-linear value: the true value plus at most half a code of
    /// ordered offset, so that quantizing afterwards lands on the code below or the code
    /// above in the proportion the true value asks for.
    ///
    /// Applied in display-linear light because that is where the pipeline is when it
    /// hands its pixels to the encoder; the encoder is what applies `transfer` and
    /// rounds. Passing the transfer function in is what makes the amplitude one code
    /// rather than one arbitrary number.
    public static func apply(_ linear: Double, x: Int, y: Int,
                             transfer: TransferFunction, levels: Int) -> Double {
        guard linear.isFinite else { return linear }
        let step = codeStep(linear, transfer: transfer, levels: levels)
        guard step > 0 else { return linear }
        return linear + offset(x: x, y: y) * step
    }

    /// Number of codes an integer channel of this depth carries — and the number the
    /// dither's amplitude MUST be denominated in, which is the units rule at the top
    /// of this file wearing a third dress: half an 8-bit code on a 10-bit encode is
    /// two full codes of noise, four times what the encode needs to stop banding.
    /// The three rungs are the three depths Lumen writes: 8 (JPEG, 8-bit HEIC/TIFF/
    /// PNG), 10 (HEVC Main-10 HEIC), 16 (deep TIFF/PNG).
    public static func levels(bitDepth: Int) -> Int {
        if bitDepth >= 16 { return 65_536 }
        if bitDepth >= 10 { return 1_024 }
        return 256
    }

    /// Whether an encode at this depth is coarse enough to band. 16-bit's codes are
    /// 257× finer than the eye's threshold in the worst part of the curve, so it is
    /// written straight through; 10-bit is far better off than 8 but a long sky ramp
    /// can still step, and half a 10-bit code of ordered offset costs nothing.
    public static func isWorthwhile(bitDepth: Int) -> Bool { bitDepth < 16 }
}

extension ExportColorSpace {

    /// The transfer function the encoder will apply on the way to the file.
    ///
    /// Needed by the dither and by nothing else so far: the amplitude of one output code
    /// depends on the curve the encoder uses, and Adobe RGB's 2.2 and ProPhoto's 1.8 put
    /// their codes in visibly different places from sRGB's piecewise curve. Rec.2020
    /// files are tagged with the BT.709 curve by ImageIO, not with sRGB's.
    public var transfer: TransferFunction {
        switch self {
        case .srgb, .displayP3: return .srgb
        case .adobeRGB: return .gamma22
        case .rec2020: return .rec709
        case .proPhoto: return .gamma18
        }
    }
}
