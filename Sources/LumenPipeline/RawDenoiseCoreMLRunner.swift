// RawDenoiseCoreMLRunner.swift
// The Lumen Denoise network (Denoise/lumen_denoise/model.py `Denoiser`, residual) run
// natively through Core ML — the piece that lets the raw-domain denoiser live inside
// Lumen with no Python on the machine.
//
// It is deliberately thin. Everything that decides WHICH numbers reach the network —
// the tile plan, the reflect pad to a multiple of 16, the std map on the padded tile,
// the feather ramps, the Σweight normalisation — is LumenCore code (RawDenoiseTiler,
// RawDenoiseStdMap) with golden fixtures generated from the real infer.py. This file
// only moves a padded tile into an MLMultiArray, calls `prediction(from:)`, and moves
// the answer back out. Keeping the parity-critical arithmetic out of here is the point:
// this file only compiles on the macOS CI runner, so anything subtle in it would be
// tested late; anything subtle in LumenCore is tested on every Linux run.
//
// The model contract (Denoise/docs/LUMEN_INTEGRATION.md, the export script on the Mac):
//   inputs  "noisy" (1, 4, H, W) packed RGGB, normalised (raw − black)/(white − black)
//           "std"   (1, 1, H, W) RawDenoiseStdMap of that same padded tile
//   output  "denoised" (1, 4, H, W)
//   H, W multiples of 16 with a flexible range up to the tile size, because a photo
//   smaller than one tile (or a short edge tile) is NOT padded up to 1024 — padding
//   would change the per-tile scale s = mean(std) the network divides by.
// The exported graph wraps `Denoiser.forward` INCLUDING the residual scale, so this
// file never has to know `s`.
//
// Precision. The model is Float16 inside. The std map is computed here in Float32 and
// only rounded to half on the way in: at ISO 100 on the A7 IV, K·sig and r are ~1e-7,
// fp16 SUBNORMALS, and Python's MPS path (which computes the map in fp16) quantises them
// coarsely; the square root lifts std to ~5e-4, a normal half, so rounding after the
// root loses nothing. Float16 is unavailable to Swift on x86_64 macOS, so half values are
// converted in software (`RawDenoiseHalf`, exhaustively checked against Float16 on
// arm64) instead of through `Float16` — the same file builds and behaves identically on
// both architectures. Input arrays are created in whatever type the model declares, so
// Core ML never has to guess a conversion.

#if os(macOS) && canImport(CoreML)

import CoreML
import Foundation
import LumenCore

/// Anything that can turn normalised packed RGGB planes into denoised ones. The Core ML
/// runner is the real one; the pre-pass is written against this protocol so its cache,
/// dedupe and cancellation can be tested without a model.
public protocol RawDenoiseRunning: Sendable {
    /// `packed`: channel-major 4·height·width, RGGB order, normalised. Returns the same
    /// layout at FULL strength — the strength blend is the caller's cheap post-step.
    /// `progress` receives the fraction of tiles finished, 0…1. Implementations check
    /// task cancellation between tiles and throw `CancellationError`.
    func denoise(packed: [Float], width: Int, height: Int, params: RawDenoiseNoiseParams,
                 tile: Int, overlap: Int,
                 progress: (@Sendable (Double) -> Void)?) throws -> [Float]
}

public enum RawDenoiseCoreMLError: Error, Equatable, CustomStringConvertible {
    case missingInput(String)
    case missingOutput(String)
    case unexpectedOutputShape(expected: [Int], actual: [Int])
    case unsupportedDataType(String)

    public var description: String {
        switch self {
        case .missingInput(let name):
            return "Core ML model has no multi-array input named \"\(name)\""
        case .missingOutput(let name):
            return "Core ML model produced no multi-array output named \"\(name)\""
        case .unexpectedOutputShape(let expected, let actual):
            return "Core ML output shape \(actual), expected \(expected)"
        case .unsupportedDataType(let type):
            return "Core ML multi-array data type \(type) is not supported"
        }
    }
}

/// Runs the exported Lumen Denoise model tile by tile with infer.py's tiling.
///
/// `@unchecked Sendable`: the only mutable thing it touches is the MLModel, and every
/// prediction goes through `lock`. Core ML documents prediction as thread-safe, but the
/// pre-pass runs one photo at a time anyway and serialising costs nothing — while two
/// concurrent 1024² predictions on the Neural Engine would only fight over it.
public final class RawDenoiseCoreMLRunner: RawDenoiseRunning, @unchecked Sendable {

    /// The Core ML feature names. Fixed by the export script; changing one is a model
    /// format change and belongs in `modelID` too.
    public enum FeatureName {
        public static let noisy = "noisy"
        public static let std = "std"
        public static let denoised = "denoised"
    }

    public let model: MLModel
    /// The compiled model actually loaded (an .mlmodelc directory).
    public let compiledModelURL: URL
    private let noisyType: MLMultiArrayDataType
    private let stdType: MLMultiArrayDataType
    private let lock = NSLock()

    /// Loads `modelURL`, compiling it first when it is an .mlpackage / .mlmodel source.
    ///
    /// Compiling takes seconds, so when `compiledCacheDirectory` is given the compiled
    /// .mlmodelc is kept there under a name derived from the source's path, size and
    /// modification date, and reused on the next launch. Without it the compiled model
    /// lives in Core ML's temporary directory for this process only.
    ///
    /// `computeUnits`: `.all` lets Core ML use the Neural Engine. `.cpuAndGPU` is the
    /// escape hatch if the ANE's fp16 path proves numerically unsafe for this network
    /// (activation overflow is a known failure for similar UNets — docs/audit-2026-09/
    /// w1/r6-denoise-decision.md) — the parity run on the Mac decides.
    public convenience init(modelURL: URL, computeUnits: MLComputeUnits = .all,
                compiledCacheDirectory: URL? = nil) async throws {
        let compiled = try await Self.compiledURL(for: modelURL, cacheDirectory: compiledCacheDirectory)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        let model = try MLModel(contentsOf: compiled, configuration: configuration)
        try self.init(model: model, compiledModelURL: compiled)
    }

    /// Wraps an already-loaded model (tests, or a host that manages loading itself).
    public init(model: MLModel, compiledModelURL: URL) throws {
        let inputs = model.modelDescription.inputDescriptionsByName
        guard let noisy = inputs[FeatureName.noisy]?.multiArrayConstraint else {
            throw RawDenoiseCoreMLError.missingInput(FeatureName.noisy)
        }
        guard let std = inputs[FeatureName.std]?.multiArrayConstraint else {
            throw RawDenoiseCoreMLError.missingInput(FeatureName.std)
        }
        self.model = model
        self.compiledModelURL = compiledModelURL
        self.noisyType = noisy.dataType
        self.stdType = std.dataType
    }

    private static func compiledURL(for source: URL, cacheDirectory: URL?) async throws -> URL {
        if source.pathExtension == "mlmodelc" { return source }
        let fm = FileManager.default
        var cached: URL?
        if let dir = cacheDirectory {
            let attributes = try fm.attributesOfItem(atPath: source.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let identity = "\(source.standardizedFileURL.path)|\(size)|\(modified)"
            let name = source.deletingPathExtension().lastPathComponent + "-"
                + String(identity.hashValueStable, radix: 16) + ".mlmodelc"
            let target = dir.appendingPathComponent(name, isDirectory: true)
            if fm.fileExists(atPath: target.path) { return target }
            cached = target
        }
        let temporary = try await MLModel.compileModel(at: source)
        guard let target = cached else { return temporary }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fm.moveItem(at: temporary, to: target)
        } catch {
            // Another process won the race to the same name; theirs is the same model.
            if fm.fileExists(atPath: target.path) { return target }
            throw error
        }
        return target
    }

    // MARK: - Denoising

    /// infer.py `Engine.denoise_packed`: feathered tiles over the whole packed frame.
    public func denoise(packed: [Float], width: Int, height: Int, params: RawDenoiseNoiseParams,
                        tile: Int = 1024, overlap: Int = 64,
                        progress: (@Sendable (Double) -> Void)? = nil) throws -> [Float] {
        let total = RawDenoiseTilePlan(width: width, height: height, tile: tile, overlap: overlap).tiles.count
        var done = 0
        return try RawDenoiseTiler.run(packed: packed, width: width, height: height,
                                       tile: tile, overlap: overlap) { padded, ph, pw in
            // Between tiles is the only place a cancel can take effect: a prediction in
            // flight cannot be interrupted, and one tile is well under a second.
            try Task.checkCancellation()
            let std = RawDenoiseStdMap.compute(packed: padded, width: pw, height: ph, params: params)
            let out = try self.predictTile(padded: padded, std: std, height: ph, width: pw)
            done += 1
            progress?(total > 0 ? Double(done) / Double(total) : 1)
            return out
        }
    }

    /// One padded tile through the network: (4·ph·pw, ph·pw) in, 4·ph·pw out.
    public func predictTile(padded: [Float], std: [Float], height ph: Int, width pw: Int) throws -> [Float] {
        precondition(padded.count == 4 * ph * pw && std.count == ph * pw, "tile buffers do not match \(ph)×\(pw)")
        let noisyArray = try Self.makeArray(padded, shape: [1, 4, ph, pw], dataType: noisyType)
        let stdArray = try Self.makeArray(std, shape: [1, 1, ph, pw], dataType: stdType)
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            FeatureName.noisy: MLFeatureValue(multiArray: noisyArray),
            FeatureName.std: MLFeatureValue(multiArray: stdArray),
        ])
        lock.lock()
        defer { lock.unlock() }
        let result = try model.prediction(from: provider)
        guard let output = result.featureValue(for: FeatureName.denoised)?.multiArrayValue else {
            throw RawDenoiseCoreMLError.missingOutput(FeatureName.denoised)
        }
        return try Self.readArray(output, shape: [1, 4, ph, pw])
    }

    // MARK: - MLMultiArray conversion

    /// A dense 4-D array of `values` (row-major over `shape`) in `dataType`. Writes go
    /// through the array's own strides: a freshly allocated array is contiguous today,
    /// but nothing in the API promises it.
    static func makeArray(_ values: [Float], shape: [Int], dataType: MLMultiArrayDataType) throws -> MLMultiArray {
        precondition(shape.count == 4 && values.count == shape.reduce(1, *))
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: dataType)
        let c = shape[1], h = shape[2], w = shape[3]
        try array.withUnsafeMutableBytes { raw, strides in
            let s1 = strides[1], s2 = strides[2], s3 = strides[3]
            switch dataType {
            case .float32:
                let p = raw.bindMemory(to: Float.self)
                for ci in 0..<c { for y in 0..<h { for x in 0..<w {
                    p[ci * s1 + y * s2 + x * s3] = values[(ci * h + y) * w + x]
                } } }
            case .float16:
                let p = raw.bindMemory(to: UInt16.self)
                for ci in 0..<c { for y in 0..<h { for x in 0..<w {
                    p[ci * s1 + y * s2 + x * s3] = RawDenoiseHalf.bits(from: values[(ci * h + y) * w + x])
                } } }
            case .double:
                let p = raw.bindMemory(to: Double.self)
                for ci in 0..<c { for y in 0..<h { for x in 0..<w {
                    p[ci * s1 + y * s2 + x * s3] = Double(values[(ci * h + y) * w + x])
                } } }
            default:
                throw RawDenoiseCoreMLError.unsupportedDataType(String(describing: dataType.rawValue))
            }
        }
        return array
    }

    /// The array's values as dense row-major Float32, honouring its strides — Core ML
    /// output buffers are often row-padded for the Neural Engine, so reading
    /// `count` contiguous values would silently shear the image.
    static func readArray(_ array: MLMultiArray, shape: [Int]) throws -> [Float] {
        let actual = array.shape.map { $0.intValue }
        guard actual == shape else {
            throw RawDenoiseCoreMLError.unexpectedOutputShape(expected: shape, actual: actual)
        }
        let strides = array.strides.map { $0.intValue }
        let c = shape[1], h = shape[2], w = shape[3]
        let s1 = strides[1], s2 = strides[2], s3 = strides[3]
        var out = [Float](repeating: 0, count: c * h * w)
        let dataType = array.dataType
        try array.withUnsafeBytes { raw in
            switch dataType {
            case .float32:
                let p = raw.bindMemory(to: Float.self)
                for ci in 0..<c { for y in 0..<h { for x in 0..<w {
                    out[(ci * h + y) * w + x] = p[ci * s1 + y * s2 + x * s3]
                } } }
            case .float16:
                let p = raw.bindMemory(to: UInt16.self)
                for ci in 0..<c { for y in 0..<h { for x in 0..<w {
                    out[(ci * h + y) * w + x] = RawDenoiseHalf.float(from: p[ci * s1 + y * s2 + x * s3])
                } } }
            case .double:
                let p = raw.bindMemory(to: Double.self)
                for ci in 0..<c { for y in 0..<h { for x in 0..<w {
                    out[(ci * h + y) * w + x] = Float(p[ci * s1 + y * s2 + x * s3])
                } } }
            default:
                throw RawDenoiseCoreMLError.unsupportedDataType(String(describing: dataType.rawValue))
            }
        }
        return out
    }
}

private extension String {
    /// FNV-1a over UTF-8 — `hashValue` is seeded per process, useless for a file name
    /// that must be found again on the next launch.
    var hashValueStable: UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return h
    }
}

#endif
