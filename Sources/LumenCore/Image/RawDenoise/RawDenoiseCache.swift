// RawDenoiseCache.swift
// The identity of a cached AI raw-denoise result, and the feature flag meant to gate the
// raw-denoise path (defined here; nothing consults it yet — see RawDenoiseFeature).
//
// The pre-pass is seconds of Core ML work per frame, so its output — the denoised CFA
// at FULL strength — is cached and the recipe's strength is applied afterwards as the
// cheap blend `s*d + (1-s)*p` (infer.py). That is why strength is deliberately NOT in
// the key: dragging the slider must never invalidate the cache. Everything that changes
// the network's input or weights IS in the key: which source pixels, which model, which
// calibration table, and the resolved noise parameters (so an edited calib.json row
// for one ISO invalidates only that ISO's frames even if the digest scheme is coarse).
//
// SHA-256 rather than the recipe's XXH64 (Fingerprint.swift): this key names files on
// disk that outlive any one catalog, shared between machines; 64 bits is fine for a
// recipe cache but the cost of a 256-bit digest here is nil. LumenCore has no SHA-256
// and CryptoKit is Apple-only, so a small FIPS 180-4 implementation lives below,
// verified against Python's hashlib in RawDenoiseCacheTests.
//
// What fills the string fields (one scheme everywhere; export_coreml.py is the source):
//  · modelID = "<model_id>/t<tile>o<overlap>", e.g. "0123456789abcdef/t1024o64".
//    `model_id` is the 16-hex digest of the .pt weights plus the export config, written by
//    export_coreml.py into lumen_denoise.coreml.json and into the mlpackage's
//    creatorDefinedKey metadata as `com.lumen.denoise.model_id`; the runner reads it
//    from the loaded model, never from the file name. Tile and overlap are part of it
//    because they change the blended output (RawDenoiseTiling) for the same weights.
//  · calibDigest = full lowercase sha256 hex of calib.json (metadata key
//    `com.lumen.denoise.calib_digest`). k/readVar stay in the key as well, see above.
//  · sourceIdentity = the catalog's CONFIRMED content fingerprint / quick signature of
//    the RAW. A SourceFileIdentity (path, size, mtime…) is only a trigger to re-verify
//    that fingerprint; it is never the key itself, so a touched-but-unchanged file (or a
//    moved one) keeps its cache.

import Foundation

public struct RawDenoiseCacheKey: Hashable, Sendable, Codable {
    /// Identity of the source RAW's pixels: the catalog's confirmed content fingerprint /
    /// quick signature (not a SourceFileIdentity, which only triggers re-verification).
    public var sourceIdentity: String
    /// `"<model_id>/t<tile>o<overlap>"`: the 16-hex model digest from the model's
    /// `com.lumen.denoise.model_id` metadata plus the tiling it was run with.
    public var modelID: String
    /// Full sha256 hex of calib.json (`com.lumen.denoise.calib_digest`).
    public var calibDigest: String
    public var k: Double
    public var readVar: Double

    public init(sourceIdentity: String, modelID: String, calibDigest: String,
                k: Double, readVar: Double) {
        self.sourceIdentity = sourceIdentity
        self.modelID = modelID
        self.calibDigest = calibDigest
        self.k = k
        self.readVar = readVar
    }

    /// Canonical, field-ordered, locale-independent form. Strings are length-prefixed
    /// (UTF-8 bytes) so no value can forge a field boundary; doubles are their IEEE-754
    /// bit pattern in hex, which no locale or float-printing change can alter.
    /// Mirrored by `cache_stable_string` in Denoise/scripts/gen_swift_fixtures_packing.py.
    public var stableString: String {
        func s(_ name: String, _ v: String) -> String { "\(name)=\(v.utf8.count):\(v)\n" }
        func d(_ name: String, _ v: Double) -> String {
            // +0 and -0 are the same parameter; do not let them split the cache.
            let bits = (v == 0 ? 0.0 : v).bitPattern
            let hex = String(bits, radix: 16)
            return "\(name)=\(String(repeating: "0", count: 16 - hex.count))\(hex)\n"
        }
        return "lumen.raw-denoise.cache/v1\n"
            + s("source", sourceIdentity) + s("model", modelID) + s("calib", calibDigest)
            + d("k", k) + d("readVar", readVar)
    }

    /// Lowercase SHA-256 hex of `stableString` — safe as a file name.
    public var digest: String { RawDenoiseSHA256.hex(Array(stableString.utf8)) }
}

/// The raw-denoise feature flag. Off unless the environment sets LUMEN_RAW_DENOISE=1;
/// tests (and a future preference) force it with `override`. Defined but not yet
/// consulted by any code path: wiring it in lands with DenoisedRawSource / the UI.
public enum RawDenoiseFeature {
    public static let environmentKey = "LUMEN_RAW_DENOISE"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedOverride: Bool?

    /// `nil` defers to the environment.
    public static var override: Bool? {
        get { lock.lock(); defer { lock.unlock() }; return storedOverride }
        set { lock.lock(); storedOverride = newValue; lock.unlock() }
    }

    public static var isEnabled: Bool {
        if let forced = override { return forced }
        return ProcessInfo.processInfo.environment[environmentKey] == "1"
    }
}

/// FIPS 180-4 SHA-256 over bytes. Internal: only the cache key needs it.
enum RawDenoiseSHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                           0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var data = message
        let bitLength = UInt64(message.count) &* 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for i in (0..<8).reversed() { data.append(UInt8(truncatingIfNeeded: bitLength >> (UInt64(i) * 8))) }

        @inline(__always) func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: data.count, by: 64) {
            for t in 0..<16 {
                let b = chunk + 4 * t
                w[t] = UInt32(data[b]) << 24 | UInt32(data[b + 1]) << 16
                    | UInt32(data[b + 2]) << 8 | UInt32(data[b + 3])
            }
            for t in 16..<64 {
                let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
                let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
                w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for t in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[t] &+ w[t]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1
                d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return h.flatMap { v in (0..<4).map { UInt8(truncatingIfNeeded: v >> (24 - 8 * UInt32($0))) } }
    }

    static func hex(_ message: [UInt8]) -> String {
        let digits = Array("0123456789abcdef")
        var out = ""
        out.reserveCapacity(64)
        for byte in hash(message) {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0f)])
        }
        return out
    }
}
