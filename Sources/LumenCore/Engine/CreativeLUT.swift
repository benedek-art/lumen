// CreativeLUT.swift
// The creative-LUT stage: a user `.cube` file applied at one of the two taps docs/14
// §2.3 and docs/05 "LUT import" document, blended against its input by Amount.
//
// WHERE IT RUNS, and why there are two places:
//
//   · `.display` (the default) — after picture formation, in S15, AFTER the local
//     point curve and BEFORE grain. Docs/14 §2 lists S15 as "tone curve, local curve
//     tap, display-interpreted LUTs, soft clip", and grain composites at the end of
//     formation; the export path also lays grain down after its resize
//     (`PipelineRenderer.exportedImage`), so a LUT placed after grain in the graph
//     would sit on the other side of the grain on export than on preview. Before grain
//     is the only position both paths can agree on.
//   · `.log` — pre-transform, the last thing before S14: after the S13 vignette and
//     halation, on `LumenLog`, the fixed log encoding every baked table in this engine
//     already uses (LUT.swift). It is the spec's "Log-interpreted LUTs run pre-transform
//     on a fixed, documented log encoding of the working image".
//
// THE DECLARED SPACES. A creative LUT maps a space onto itself, so one declaration
// covers input and output, and `LUTReference.Tap` is that declaration:
//
//   · `.display`: input and output are sRGB-encoded, display-referred, IEC 61966-2-1
//     primaries and transfer, D65, nominal [0,1] = SDR black to SDR white. The
//     display-linear Rec.2020 picture is converted to sRGB primaries, clamped to the
//     cube's unit domain (an SDR-referred LUT has nothing to say about a value outside
//     it — HDR headroom above white included), encoded, looked up, decoded and
//     converted back, and the part the clamp removed is added back (`apply`).
//   · `.log`: input and output are `LumenLog`-encoded linear Rec.2020 — the domain is
//     the shaper's own ±12 stops around 0.18.
//
// ONE FUNCTION, TWO RENDERERS. `apply` below is the reference. The GPU graph runs the
// same five steps with the same matrices (`RenderGraph.applyCreativeLUT`), and the user's
// cube is sampled at its own resolution on both paths — it is never re-baked into a
// second table, so there is no second interpolation error between the file and the
// picture.

import Foundation

public struct CreativeLUTStage: Sendable, Equatable {

    /// Where the stage runs and what space the cube expects.
    public let tap: LUTReference.Tap
    /// 0…2 — the recipe's 0…200 Amount, clamped.
    public let amount: Double
    /// The parsed cube, exactly as the file defines it.
    public let cube: LUT3D
    /// The reference this stage was built from — what a GPU cache keys the uploaded
    /// cube bytes on, since the bytes behind a content-addressed ref never change.
    public let ref: String

    /// Working (Rec.2020, linear) → sRGB primaries, linear. Same white, so no adaptation.
    public static let workingToDisplay: Mat3 = RGBColorSpace.rec2020.matrix(to: .srgb)
    /// And back.
    public static let displayToWorking: Mat3 = RGBColorSpace.srgb.matrix(to: .rec2020)

    /// The stage a recipe's `look.lut` asks for, or nil when nothing should run.
    ///
    /// NIL IS THE WHOLE IDENTITY GUARANTEE. Every recipe with no LUT, an empty ref, an
    /// Amount at or below zero, or a ref whose bytes this machine does not have resolves
    /// to nil, and both renderers skip the stage outright on nil — no matrix, no clamp,
    /// no blend at zero — so those recipes run exactly the code they ran before this
    /// stage existed. `CreativeLUTTests` pins that byte for byte.
    public init?(reference: LUTReference?, library: CreativeLUTLibrary = .shared) {
        guard let reference, !reference.ref.isEmpty,
              reference.amount.isFinite, reference.amount > 0,
              let cube = library.cube(for: reference.ref) else { return nil }
        self.init(tap: reference.tap, amount: reference.amount, cube: cube,
                  ref: reference.ref)
    }

    /// What Amount may ask for, in percent: 0 is no LUT, 100 the file as it was made,
    /// 200 twice its departure from the input — Lightroom's profile Amount range, and
    /// the same reading (WS-30 SPEC L4). Stated once; the panel's slider reads it.
    public static let amountRange: ClosedRange<Double> = 0...200

    public init(tap: LUTReference.Tap, amount percent: Double, cube: LUT3D, ref: String = "") {
        self.tap = tap
        self.amount = Num.clamp(percent.isFinite ? percent : 0,
                                Self.amountRange.lowerBound, Self.amountRange.upperBound) / 100
        self.cube = cube
        self.ref = ref
    }

    /// Whether the stage is at the file's own strength.
    public var isFullStrength: Bool { amount == 1 }

    /// The stage, per pixel. `c` is working-space linear: scene-referred at the log tap,
    /// display-linear at the display tap.
    ///
    /// THE BLEND IS IN THE CUBE'S OWN ENCODING, not in linear light. Amount scales the
    /// departure the file makes, `L(e) − e`, measured in the coordinates its author
    /// graded in (sRGB code values at the display tap, `LumenLog` at the log tap), so
    /// 50% is half the look as a viewer judges it and 200% is twice it. A linear-light
    /// blend weighted every mix toward the brighter end and, extrapolated past 100, ran
    /// away: a 1.25× log-contrast cube at 150% put a +3-stop highlight at 255× linear.
    ///
    /// AND WHAT THE CUBE CANNOT SEE IS HANDED BACK UNTOUCHED. A cube's domain is the unit
    /// cube of its encoding. The part of a value outside it — a P3 or Rec.2020 colour
    /// beyond sRGB, EDR headroom above SDR white, a scene value past the shaper's ±12
    /// stops — is carried around the lookup as a residual `d − u` and added back, so an
    /// identity cube is the identity on EVERY value (it used to clip a wide-gamut red
    /// to sRGB on a P3 screen and flatten HDR highlights to white), and a creative cube
    /// changes such a pixel exactly as it changes the nearest value it can see.
    ///
    /// NON-FINITE IN, FINITE OUT, as before the residual existed: a NaN channel reads as
    /// 0 and an infinite one as the domain edge it points past, and neither contributes
    /// a residual — one poisoned channel must not take a whole pixel, or a render, with
    /// it. (The reference only: the GPU graph has no finite-test kernel; WS-30 NEEDS.md.)
    public func apply(_ c: RGB) -> RGB {
        switch tap {
        case .log:
            let e = Self.finite(LumenLog.encode(c))
            // The cube's OWN domain, which a `.cube` file may widen past [0,1]
            // (DOMAIN_MIN/MAX); `sample` maps it onto the lattice.
            let u = RGB(Num.clamp(e.r, cube.domainMin.r, cube.domainMax.r),
                        Num.clamp(e.g, cube.domainMin.g, cube.domainMax.g),
                        Num.clamp(e.b, cube.domainMin.b, cube.domainMax.b))
            let looked = cube.sample(u)
            return LumenLog.decode(e + (looked - u) * amount)
        case .display:
            // Sanitized BEFORE the matrix, which would spread one NaN channel into all
            // three and black out the whole pixel.
            let d = Self.workingToDisplay.apply(Self.finite(c))
            // The cube's own DOMAIN, in linear: a narrower one is honoured and a wider one
            // above code 1 is read. Floored at 0 — the sRGB curve is not extended below
            // black the same way by both renderers, and no display LUT means it.
            let low = Self.domainLinear(cube.domainMin).map { Swift.max($0, 0) }
            let high = Self.domainLinear(cube.domainMax)
            let u = RGB(Num.clamp(d.r, low.r, high.r), Num.clamp(d.g, low.g, high.g),
                        Num.clamp(d.b, low.b, high.b))
            let e = TransferFunction.srgb.encode(u)
            let looked = cube.sample(e)
            // Floored at code 0, the one bound an extrapolated Amount can cross that has
            // no meaning: there is no light below black. No ceiling — a code above 1 is
            // headroom, and both decoders extend the curve the same way above 1.
            let blended = (e + (looked - e) * amount).map { Swift.max($0, 0) }
            return Self.displayToWorking.apply(TransferFunction.srgb.decode(blended) + (d - u))
        }
    }

    /// A display cube's domain bound (sRGB code) as display-linear. Unit domain: 0 and 1.
    public static func domainLinear(_ code: RGB) -> RGB { TransferFunction.srgb.decode(code) }

    /// NaN → 0, +∞ → 1, −∞ → 0: the unit domain's own values, so neither leaves a
    /// residual to add back.
    static func finite(_ c: RGB) -> RGB {
        c.map { v in v.isNaN ? 0 : (v.isInfinite ? (v > 0 ? 1 : 0) : v) }
    }

    /// The cube in its declared space at full strength.
    public func map(_ c: RGB) -> RGB {
        CreativeLUTStage(tap: tap, amount: 100, cube: cube, ref: ref).apply(c)
    }
}

// MARK: - Where cubes come from

/// The parsed cubes a render can reach, by blob reference.
///
/// A recipe names a LUT by content hash (`blob:xxh64:<16 hex>`); the bytes live in the
/// catalog's `BlobStore` beside the brush strokes, so `BlobStore.backUp` and `restore`
/// carry them with no change. What this adds is the parse, done once per ref and kept:
/// the bytes behind a content-addressed name never change, so neither does the cube.
///
/// A PROCESS-WIDE SHELF rather than another argument threaded through every render
/// entry point. `strokeSets` is threaded, and costs a parameter on a dozen signatures in
/// three modules; a cube is immutable, keyed by its own hash and shared by every
/// photograph that uses it, which is exactly the shape a shared cache can hold safely.
/// The app attaches its blob store when a catalog opens (`attach`); tests build their
/// own library and pass it, so no test depends on another's state.
public final class CreativeLUTLibrary: @unchecked Sendable {

    public static let shared = CreativeLUTLibrary()

    private let lock = NSLock()
    private var fetch: (@Sendable (String) -> Data?)?
    private var parsed: [String: LUT3D] = [:]
    /// Refs whose bytes were present and did not parse — remembered so a bad file costs
    /// one parse, not one per frame.
    private var rejected: Set<String> = []

    public init() {}

    /// Where to read bytes the shelf does not hold yet. Replacing the source forgets
    /// every miss, so a catalog opened after a failed lookup gets its chance.
    public func attach(_ fetch: @escaping @Sendable (String) -> Data?) {
        lock.lock()
        self.fetch = fetch
        rejected.removeAll()
        lock.unlock()
    }

    /// Put a cube on the shelf directly — the import path, which has just parsed it.
    public func register(_ cube: LUT3D, for ref: String) {
        lock.lock()
        parsed[ref] = cube
        rejected.remove(ref)
        lock.unlock()
    }

    public func cube(for ref: String) -> LUT3D? {
        lock.lock()
        if let hit = parsed[ref] {
            lock.unlock()
            return hit
        }
        let source = fetch
        let known = rejected.contains(ref)
        lock.unlock()
        guard !known, let data = source?(ref) else { return nil }
        guard let cube = CreativeLUTImport.parse(data) else {
            lock.lock()
            rejected.insert(ref)
            lock.unlock()
            return nil
        }
        register(cube, for: ref)
        return cube
    }
}

// MARK: - Import

public enum CreativeLUTImport {

    public enum Failure: Error, Equatable {
        /// The file is not a 3-D `.cube` this parser accepts: a 1-D cube, a size out of
        /// range, a short triple or a wrong sample count. `LUT3D.fromCubeFile` says
        /// which forms those are.
        case notACube
    }

    /// The bytes as a cube, or nil. UTF-8 first; Latin-1 as the fallback, because a
    /// `TITLE` line written on Windows is the one place a non-ASCII byte turns up in a
    /// file whose numbers are all ASCII.
    public static func parse(_ data: Data) -> LUT3D? {
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        guard let text else { return nil }
        return LUT3D.fromCubeFile(text)
    }

    /// Store a `.cube` file's bytes and return the reference a recipe should carry.
    ///
    /// Parsed BEFORE it is stored, so nothing that cannot render ever gets a blob. The
    /// bytes are stored verbatim — the hash is the file's own, so importing the same
    /// file twice, on two photographs or two machines, is one blob and one ref.
    public static func importCube(_ data: Data, named name: String,
                                  into blobs: BlobStore,
                                  library: CreativeLUTLibrary = .shared) throws -> LUTReference {
        guard let cube = parse(data) else { throw Failure.notACube }
        let ref = try blobs.store(data)
        library.register(cube, for: ref)
        return LUTReference(ref: ref, name: name, tap: .display, amount: 100)
    }
}
