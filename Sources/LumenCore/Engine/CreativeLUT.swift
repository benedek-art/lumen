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
//     converted back.
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
    /// 0…1 — the recipe's 0…100 Amount, clamped.
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

    public init(tap: LUTReference.Tap, amount percent: Double, cube: LUT3D, ref: String = "") {
        self.tap = tap
        self.amount = Num.clamp(percent.isFinite ? percent : 0, 0, 100) / 100
        self.cube = cube
        self.ref = ref
    }

    /// Whether the blend can be skipped: at full Amount the output IS the mapped value,
    /// and skipping the mix keeps it exact on both paths rather than `x + (y − x)·1`.
    public var isFullStrength: Bool { amount >= 1 }

    /// The stage, per pixel. `c` is working-space linear: scene-referred at the log tap,
    /// display-linear at the display tap.
    public func apply(_ c: RGB) -> RGB {
        let mapped = map(c)
        if isFullStrength { return mapped }
        return c + (mapped - c) * amount
    }

    /// The cube in its declared space, with no blend.
    public func map(_ c: RGB) -> RGB {
        switch tap {
        case .log:
            return LumenLog.decode(cube.sample(LumenLog.encode(c)))
        case .display:
            let display = Self.workingToDisplay.apply(c).map(Num.saturate)
            let encoded = TransferFunction.srgb.encode(display)
            let looked = cube.sample(encoded)
            return Self.displayToWorking.apply(TransferFunction.srgb.decode(looked))
        }
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
