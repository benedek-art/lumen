// SoftProofTransform.swift
// The proof transform, solved once and applied per pixel (docs/11 §Soft proofing:
// "the proof transform is a cached LUT").
//
// `SoftProof` has been in the tree since the export model landed and had no caller at
// all: the struct, its warning colour and `isOutOfGamut` were declared, tested, and
// reached no pixel on any path. This is the half that was missing — the composed
// display-linear → display-linear function, plus the cached matrices and gamut
// boundary it needs so that building it is not per-pixel work.
//
// DOMAIN AND RANGE, stated because getting this wrong is the units bug in another
// dress: both are display-linear values in the WORKING space's primaries, relative to
// display white, so 1.0 is white and 0.18 is mid-grey. That is exactly what S14+S15
// produce before `finishScale` is re-applied, which is why the proof composes onto the
// end of the finish table rather than needing a stage of its own. It is NOT
// scene-referred and NOT log-encoded — a threshold in stops has no meaning here.

import Foundation

extension SoftProof {

    /// Paper white, as a fraction of the display's white.
    ///
    /// A print is a reflective object under room light and a monitor is a light source;
    /// a good sheet under gallery lighting returns roughly 88% of what the screen
    /// emits, which is why an unproofed image always looks brighter than its print.
    /// One documented constant rather than a per-paper number, because Lumen has no ICC
    /// profile behind this toggle yet and inventing a paper-specific value would claim a
    /// precision the app cannot back up.
    public static let paperWhite: Double = 0.88

    /// Ink black, as a fraction of display white. A glossy inkjet black at Dmax ≈ 1.7
    /// reflects about 2%; it is the floor the print cannot go below.
    public static let inkBlack: Double = 0.02

    /// Out-of-gamut tolerance, in destination-primary units. One part in 4096 is a
    /// quarter of a 12-bit code — below anything an encoder can carry, and above the
    /// float noise a 3×3 round trip leaves behind.
    public static let gamutEpsilon: Double = 1.0 / 4096.0

    /// Build the solved transform. Nil when proofing is off, so a caller cannot
    /// accidentally pay for one, or apply one it did not ask for.
    public func transform(working: RGBColorSpace = .rec2020) -> SoftProofTransform? {
        guard enabled else { return nil }
        return SoftProofTransform(self, working: working)
    }
}

/// One solved proof: the two matrices, the intent, and — for the perceptual intent —
/// the destination gamut's own boundary in its own OKLab context.
///
/// Solved once per plan. `RGBColorSpace.matrix(to:)` inverts a 3×3 on every call and
/// `Gamut.Boundary` costs ~15 000 colour conversions to build, so doing either inside
/// the finish table's closure would be tens of thousands of matrix inversions per
/// slider frame.
public struct SoftProofTransform: Sendable {

    public let settings: SoftProof
    public let workingToProof: Mat3
    public let proofToWorking: Mat3

    /// Only built for the perceptual intent; the colorimetric intent clips and needs no
    /// boundary at all.
    private let context: OKLabTransform.Context?
    private let boundary: Gamut.Boundary?

    public init(_ settings: SoftProof, working: RGBColorSpace = .rec2020) {
        self.settings = settings
        let proof = settings.space.space
        self.workingToProof = working.matrix(to: proof)
        self.proofToWorking = proof.matrix(to: working)
        switch settings.intent {
        case .perceptual:
            self.context = ProofGamut.context(settings.space)
            self.boundary = ProofGamut.boundary(settings.space)
        case .relativeColorimetric:
            self.context = nil
            self.boundary = nil
        }
    }

    /// True when this colour falls outside the destination gamut — when the exported
    /// file cannot hold it and something will have to give.
    public func isOutOfGamut(_ displayLinear: RGB) -> Bool {
        guard displayLinear.isFinite else { return false }
        let inProof = workingToProof.apply(displayLinear)
        return inProof.minComponent < -SoftProof.gamutEpsilon
            || inProof.maxComponent > 1 + SoftProof.gamutEpsilon
    }

    /// The picture half of the proof, as one pure display-linear → display-linear
    /// function: convert into the destination, map what does not fit by the chosen
    /// intent, convert back.
    ///
    /// Separate from the warning on purpose, and this split is the whole reason the two
    /// can both be exact. The simulation is smooth, so baking it into the finish table
    /// costs nothing measurable — the table's error with the proof composed in is the
    /// same 0.134 it already had without it. The WARNING is a discontinuity, and a
    /// trilinear table cannot hold one: measured at the interactive table size, the flag's
    /// edge landed a mean of 0.017 OKLCh chroma away from the true gamut boundary and
    /// disagreed with the exact answer on 6% of a realistic hue/chroma sweep. A flag that
    /// is wrong about one colour in sixteen is not an instrument. So the map is baked and
    /// the flag is computed per pixel, from the value BEFORE the map — after the map
    /// nothing is out of gamut, by construction.
    public func mapped(_ displayLinear: RGB) -> RGB {
        guard displayLinear.isFinite else { return displayLinear }
        let inProof = workingToProof.apply(displayLinear)

        var mapped: RGB
        if let context, let boundary {
            // Perceptual: compress chroma toward the destination boundary along a line
            // of constant hue and lightness, so a saturated blue desaturates instead of
            // rotating toward purple the way a per-channel clip makes it.
            mapped = Gamut.softClip(inProof, boundary: boundary, context: context)
        } else {
            mapped = inProof
        }
        // Both intents end in a clip: `softClip` approaches the boundary asymptotically
        // for in-range lightness and leaves values above display white alone, and a file
        // can store neither.
        mapped = mapped.clamped(0, 1)

        if settings.simulatePaperWhite {
            // The print's dynamic range, mapped over the screen's: white comes down to
            // the paper's reflectance and black comes up to the ink's. This is what
            // makes a proof look flat, and looking flat is the honest part — it is the
            // difference the photographer is being asked to compensate for.
            let low = SoftProof.inkBlack
            let high = SoftProof.paperWhite
            mapped = RGB(low + mapped.r * (high - low),
                         low + mapped.g * (high - low),
                         low + mapped.b * (high - low))
        }

        let back = proofToWorking.apply(mapped)
        return back.isFinite ? back : displayLinear
    }

    /// The flag, applied on top of an already-mapped pixel.
    ///
    /// `unmapped` is the display-linear value BEFORE the proof's gamut map — the only
    /// place the "does the destination have this colour" question can still be asked.
    /// Both render paths hold on to it for exactly this.
    public func flagged(_ mappedValue: RGB, unmapped: RGB) -> RGB {
        guard settings.showGamutWarning, isOutOfGamut(unmapped) else { return mappedValue }
        return SoftProof.warningColor
    }

    /// Map and flag in one call — the whole proof for a single pixel, for callers that
    /// have the original value in hand and no table in between.
    public func apply(_ displayLinear: RGB) -> RGB {
        flagged(mapped(displayLinear), unmapped: displayLinear)
    }
}

/// The destination gamuts' OKLab contexts and boundaries, built at most once each.
///
/// Static `let`s rather than a dictionary behind a lock: Swift initializes each of these
/// lazily and exactly once, which is the whole requirement, and five named constants are
/// easier to read than a cache that has to explain its own thread safety.
enum ProofGamut {

    static let srgbContext = OKLabTransform.Context(space: .srgb)
    static let displayP3Context = OKLabTransform.Context(space: .displayP3)
    static let adobeRGBContext = OKLabTransform.Context(space: .adobeRGB)
    static let rec2020Context = OKLabTransform.Context(space: .rec2020)
    static let proPhotoContext = OKLabTransform.Context(space: .proPhoto)

    static let srgbBoundary = Gamut.Boundary(context: srgbContext)
    static let displayP3Boundary = Gamut.Boundary(context: displayP3Context)
    static let adobeRGBBoundary = Gamut.Boundary(context: adobeRGBContext)
    static let rec2020Boundary = Gamut.Boundary(context: rec2020Context)
    static let proPhotoBoundary = Gamut.Boundary(context: proPhotoContext)

    static func context(_ space: ExportColorSpace) -> OKLabTransform.Context {
        switch space {
        case .srgb: return srgbContext
        case .displayP3: return displayP3Context
        case .adobeRGB: return adobeRGBContext
        case .rec2020: return rec2020Context
        case .proPhoto: return proPhotoContext
        }
    }

    static func boundary(_ space: ExportColorSpace) -> Gamut.Boundary {
        switch space {
        case .srgb: return srgbBoundary
        case .displayP3: return displayP3Boundary
        case .adobeRGB: return adobeRGBBoundary
        case .rec2020: return rec2020Boundary
        case .proPhoto: return proPhotoBoundary
        }
    }
}
