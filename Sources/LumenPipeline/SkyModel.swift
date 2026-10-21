// SkyModel.swift
// The optional Core ML sky segmenter behind Select Sky (WS-49).
//
// NOTHING IS BUNDLED AND NOTHING IS FETCHED BY DEFAULT. The sky models worth having are
// ADE20K-trained, and the easy-to-get weights carry licences an app cannot ship under:
// NVIDIA's SegFormer releases are non-commercial, and ADE20K's own terms are research
// use. `SkyDetector` (LumenCore, classical) is what Select Sky runs on every install.
// This file is the path by which a model the owner has cleared — converted with
// `docs/quality/lanes/WS-49/convert_sky_model.py`, hosted wherever they like — is
// downloaded, verified, compiled and used instead.
//
// THE MODEL CONTRACT, so any conforming conversion works without a code change:
//
//   · one image input (any name; the size and pixel format are read from the model's
//     own image constraint and Core ML scales the picture to it);
//   · one multi-array output, either
//       [1, C, H, W] / [C, H, W] class logits with C >= 3, sky at channel `skyChannel`
//       (2 in ADE20K's 150-class order: wall, building, sky, …), softmaxed here; or
//       [1, 2, H, W] two-class logits, not-sky then sky, softmaxed; or
//       [1, 1, H, W] / [H, W] sky probability or logit (logits are sigmoided when any
//       value falls outside [0, 1]).
//
// The answer is a low-resolution plane over the whole frame; `VisionMattes.skyPlane`
// refines it against the picture exactly as it does Vision's mattes.

#if os(macOS)

import CoreGraphics
import CoreML
import CryptoKit
import Foundation
import LumenCore
import Vision

public final class SkyModel: @unchecked Sendable {

    public static let shared = SkyModel()

    /// ADE20K class index of "sky" (0-based, 150 classes).
    public static let skyChannel = 2

    /// Where an installed model lives: one compiled bundle, replaced atomically.
    public static var installedURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Lumen/Models/LumenSky.mlmodelc",
                                           isDirectory: true)
    }

    private let lock = NSLock()
    private var cached: MLModel?
    private var triedLoad = false

    /// The installed model, loaded once. Nil when none is installed or it fails to
    /// load, in which case the caller uses `SkyDetector`.
    public func loaded() -> MLModel? {
        lock.lock()
        defer { lock.unlock() }
        if triedLoad { return cached }
        triedLoad = true
        guard FileManager.default.fileExists(atPath: Self.installedURL.path) else {
            return nil
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        cached = try? MLModel(contentsOf: Self.installedURL, configuration: config)
        return cached
    }

    public enum InstallError: Error {
        case checksumMismatch(expected: String, actual: String)
        case notAModel
    }

    /// Download a `.mlmodel` (or zipped-free `.mlpackage` file URL) from `source`,
    /// verify its SHA-256, compile it and install it at `installedURL`.
    ///
    /// Nothing calls this on its own: there is no default URL, by design (see the file
    /// header). A settings row the owner adds, once they have hosted a cleared model,
    /// passes the URL and checksum they published.
    public func install(from source: URL, sha256 expected: String) async throws {
        let (downloaded, _) = try await URLSession.shared.download(from: source)
        let data = try Data(contentsOf: downloaded, options: .mappedIfSafe)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected.lowercased() else {
            throw InstallError.checksumMismatch(expected: expected, actual: actual)
        }
        // `compileModel` wants the source extension to know what it is reading.
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(source.pathExtension.isEmpty
                                    ? "mlmodel" : source.pathExtension)
        try FileManager.default.moveItem(at: downloaded, to: staged)
        defer { try? FileManager.default.removeItem(at: staged) }
        let compiled = try await MLModel.compileModel(at: staged)
        defer { try? FileManager.default.removeItem(at: compiled) }
        guard (try? MLModel(contentsOf: compiled)) != nil else { throw InstallError.notAModel }

        let target = Self.installedURL
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: compiled)
        } else {
            try FileManager.default.moveItem(at: compiled, to: target)
        }
        lock.lock()
        cached = nil
        triedLoad = false
        lock.unlock()
    }

    /// Run the model on `image`. Nil on any mismatch with the contract above; the
    /// caller falls back to the classical detector rather than failing the mask.
    public static func predict(image: CGImage, model: MLModel) -> Plane? {
        let description = model.modelDescription
        guard let (inputName, input) = description.inputDescriptionsByName
            .first(where: { $0.value.type == .image }),
              let constraint = input.imageConstraint else { return nil }
        // Scale to fill, explicitly: the answer is laid over the WHOLE frame, so the
        // model must see the whole frame (a centre crop would misalign every edge).
        let options: [MLFeatureValue.ImageOption: Any] = [
            .cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue,
        ]
        guard let value = try? MLFeatureValue(cgImage: image, constraint: constraint,
                                              options: options),
              let provider = try? MLDictionaryFeatureProvider(
                  dictionary: [inputName: value]),
              let result = try? model.prediction(from: provider) else { return nil }

        guard let array = description.outputDescriptionsByName.keys.sorted()
            .lazy.compactMap({ result.featureValue(for: $0)?.multiArrayValue }).first
        else { return nil }
        return plane(from: array)
    }

    /// Decode any of the output layouts into a sky probability plane. Reads the
    /// storage through `withUnsafeBytes`, which locks a pixel-buffer-backed array for
    /// the duration (a bare `dataPointer` does not), and honours the strides.
    static func plane(from array: MLMultiArray) -> Plane? {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        guard shape.count >= 2 else { return nil }
        let h = shape[shape.count - 2], w = shape[shape.count - 1]
        let channels = shape.count >= 3 ? shape[shape.count - 3] : 1
        guard h > 0, w > 0, channels >= 1 else { return nil }
        let sy = strides[strides.count - 2], sx = strides[strides.count - 1]
        let sc = shape.count >= 3 ? strides[strides.count - 3] : 0
        let sky: Int
        switch channels {
        case 1: sky = 0
        case 2: sky = 1
        default:
            guard skyChannel < channels else { return nil }
            sky = skyChannel
        }
        let dataType = array.dataType
        guard dataType == .float32 || dataType == .double || dataType == .float16
        else { return nil }

        return array.withUnsafeBytes { raw -> Plane? in
            let read: (Int) -> Float
            switch dataType {
            case .float32:
                let p = raw.bindMemory(to: Float.self)
                read = { p[$0] }
            case .double:
                let p = raw.bindMemory(to: Double.self)
                read = { Float(p[$0]) }
            default:
                let p = raw.bindMemory(to: UInt16.self)
                read = { halfToFloat(p[$0]) }
            }
            var out = Plane(width: w, height: h)
            if channels >= 2 {
                for y in 0..<h {
                    for x in 0..<w {
                        let base = y * sy + x * sx
                        var peak = -Float.infinity
                        for c in 0..<channels { peak = Swift.max(peak, read(base + c * sc)) }
                        var sum: Float = 0
                        for c in 0..<channels { sum += expf(read(base + c * sc) - peak) }
                        out.values[y * w + x] = expf(read(base + sky * sc) - peak) / sum
                    }
                }
            } else {
                var outside = false
                for y in 0..<h {
                    for x in 0..<w {
                        let v = read(y * sy + x * sx)
                        if v < 0 || v > 1 { outside = true }
                        out.values[y * w + x] = v
                    }
                }
                if outside {
                    for i in 0..<out.values.count {
                        out.values[i] = 1 / (1 + expf(-out.values[i]))
                    }
                }
            }
            for i in 0..<out.values.count where !out.values[i].isFinite { out.values[i] = 0 }
            return out
        }
    }

    /// IEEE 754 binary16 → binary32, without the `Float16` type (unavailable on
    /// x86_64 macOS, which the package still compiles for).
    static func halfToFloat(_ h: UInt16) -> Float {
        let sign = UInt32(h & 0x8000) << 16
        let exponent = UInt32((h >> 10) & 0x1F)
        let mantissa = UInt32(h & 0x3FF)
        if exponent == 0 {
            // Zero or subnormal: mantissa × 2⁻²⁴.
            let magnitude = Float(mantissa) * 5.960_464_5e-8
            return sign == 0 ? magnitude : -magnitude
        }
        if exponent == 0x1F {
            return Float(bitPattern: sign | 0x7F80_0000 | (mantissa << 13))
        }
        return Float(bitPattern: sign | ((exponent + 112) << 23) | (mantissa << 13))
    }
}

#endif
