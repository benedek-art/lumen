// RawDenoiseCacheTests.swift
// The raw-denoise cache key is a file name that must stay put across launches,
// machines and toolchains, and must move whenever the network's input or weights do.
// Golden strings come from Denoise/scripts/gen_swift_fixtures_packing.py (hashlib).

import XCTest
@testable import LumenCore

final class RawDenoiseCacheTests: XCTestCase {

    private let golden = RawDenoiseCacheKey(
        sourceIdentity: "xxh64:0123456789abcdef", modelID: "lumen-denoise-v3",
        calibDigest: "xxh64:fedcba9876543210", k: 3.25e-4, readVar: 1.5e-7)

    func testSHA256MatchesHashlib() {
        XCTAssertEqual(RawDenoiseSHA256.hex([]),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(RawDenoiseSHA256.hex(Array("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        // Multi-block, and a length whose padding spills into an extra block.
        XCTAssertEqual(RawDenoiseSHA256.hex(Array(repeating: UInt8(ascii: "a"), count: 1000)),
                       "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    func testStableStringAndDigestAreGolden() {
        XCTAssertEqual(golden.stableString, """
            lumen.raw-denoise.cache/v1
            source=22:xxh64:0123456789abcdef
            model=16:lumen-denoise-v3
            calib=22:xxh64:fedcba9876543210
            k=3f354c985f06f694
            readVar=3e8421f5f40d8376

            """)
        XCTAssertEqual(golden.digest,
                       "7379abb1419121dc59a948a7c7aa9db9de91d35cdbfda727196e5dc16ff118f5")
    }

    /// Strength is a post-blend on the cached full-strength result; a slider drag must
    /// never invalidate the cache. The key has no strength field at all — this pins
    /// that the stable form never grows one by accident.
    func testStrengthIsNotPartOfTheKey() {
        XCTAssertFalse(golden.stableString.lowercased().contains("strength"))
        let mirror = Mirror(reflecting: golden).children.compactMap(\.label)
        XCTAssertEqual(mirror, ["sourceIdentity", "modelID", "calibDigest", "k", "readVar"])
    }

    func testEveryFieldMovesTheDigest() {
        var variants: [RawDenoiseCacheKey] = []
        var v = golden; v.sourceIdentity += "0"; variants.append(v)
        v = golden; v.modelID = "lumen-denoise-v4"; variants.append(v)
        v = golden; v.calibDigest = "xxh64:fedcba9876543211"; variants.append(v)
        v = golden; v.k = golden.k.nextUp; variants.append(v)
        v = golden; v.readVar = golden.readVar.nextDown; variants.append(v)
        let digests = Set(variants.map(\.digest) + [golden.digest])
        XCTAssertEqual(digests.count, variants.count + 1)
    }

    func testLengthPrefixPreventsFieldBoundaryForgery() {
        let a = RawDenoiseCacheKey(sourceIdentity: "a\nmodel=1:b", modelID: "c",
                                   calibDigest: "d", k: 1, readVar: 1)
        let b = RawDenoiseCacheKey(sourceIdentity: "a", modelID: "b\nmodel=1:c",
                                   calibDigest: "d", k: 1, readVar: 1)
        XCTAssertNotEqual(a.digest, b.digest)
    }

    func testSignedZeroSharesAKey() {
        var neg = golden; neg.readVar = -0.0
        var pos = golden; pos.readVar = 0.0
        XCTAssertEqual(neg.digest, pos.digest)
    }

    func testCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(golden)
        XCTAssertEqual(try JSONDecoder().decode(RawDenoiseCacheKey.self, from: data), golden)
    }

    func testFeatureFlagOverride() {
        let saved = RawDenoiseFeature.override
        defer { RawDenoiseFeature.override = saved }
        RawDenoiseFeature.override = true
        XCTAssertTrue(RawDenoiseFeature.isEnabled)
        RawDenoiseFeature.override = false
        XCTAssertFalse(RawDenoiseFeature.isEnabled)
        RawDenoiseFeature.override = nil
        let env = ProcessInfo.processInfo.environment[RawDenoiseFeature.environmentKey]
        XCTAssertEqual(RawDenoiseFeature.isEnabled, env == "1")
    }
}
