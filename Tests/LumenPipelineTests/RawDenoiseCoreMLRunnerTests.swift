// The raw-denoise pre-pass and Core ML runner, tested without a network wherever the
// thing under test does not need one: the cache file format and its refusal of torn or
// foreign files, one computation per key however many ask, a cancelled request leaving
// without taking the others down, cancellation reaching the runner between tiles, the
// memory budget, the strength blend after retrieval, and the MLMultiArray plumbing
// (half conversion, padded output strides), the compiled-model cache name and the
// export-metadata identity. The tests that need the real exported model skip unless
// LUMEN_DENOISE_MLMODEL points at it; the parity-fixture test also needs
// LUMEN_DENOISE_FIXTURES (the directory holding the manifest.json that
// Denoise/scripts/coreml_parity.py writes).
#if os(macOS) && canImport(CoreML)
import CoreML
import Foundation
import XCTest
@testable import LumenCore
@testable import LumenPipeline

private let source = URL(fileURLWithPath: "/nonexistent/DSC00001.ARW")

// MARK: - Fakes

/// Halves the input and adds 0.25, so a result is distinguishable from its input and
/// from another key's. Optionally runs in `steps` cancellable steps.
private final class FakeDenoiseRunner: RawDenoiseRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var _steps = 0
    private var _threwCancellation = false
    private var _finished = false
    let steps: Int
    let stepDelay: TimeInterval

    init(steps: Int = 1, stepDelay: TimeInterval = 0) {
        self.steps = steps
        self.stepDelay = stepDelay
    }

    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    var completedSteps: Int { lock.lock(); defer { lock.unlock() }; return _steps }
    var threwCancellation: Bool { lock.lock(); defer { lock.unlock() }; return _threwCancellation }
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return _finished }

    func denoise(packed: [Float], width: Int, height: Int, params: RawDenoiseNoiseParams,
                 tile: Int, overlap: Int, progress: (@Sendable (Double) -> Void)?) throws -> [Float] {
        lock.lock(); _calls += 1; lock.unlock()
        defer { lock.lock(); _finished = true; lock.unlock() }
        for i in 0..<steps {
            do {
                try Task.checkCancellation()
            } catch {
                lock.lock(); _threwCancellation = true; lock.unlock()
                throw error
            }
            if stepDelay > 0 { Thread.sleep(forTimeInterval: stepDelay) }
            lock.lock(); _steps += 1; lock.unlock()
            progress?(Double(i + 1) / Double(steps))
        }
        return packed.map { (v: Float) -> Float in v * 0.5 + 0.25 }
    }
}

private actor PrepassLatch {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func waitUntilOpen() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        isOpen = true
        for w in waiting { w.resume() }
        waiting.removeAll()
    }
}

private final class FakeCFAProvider: RawCFAProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    let latch: PrepassLatch?
    let planes: RawDenoisePlanes

    init(planes: RawDenoisePlanes, latch: PrepassLatch? = nil) {
        self.planes = planes
        self.latch = latch
    }

    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }

    private func countCall() { lock.lock(); _calls += 1; lock.unlock() }

    func packedRGGB(for source: URL) async throws -> RawDenoisePlanes {
        countCall()
        if let latch { await latch.waitUntilOpen() }
        return planes
    }
}

// MARK: - Parity fixtures (Denoise/scripts/coreml_parity.py `write_fixtures`)

private struct FixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// manifest.json exactly as coreml_parity.py writes it. Only what the test uses is
/// decoded; per-case metrics and the descriptive strings are ignored.
private struct ParityManifest: Decodable {
    struct Tolerance: Decodable {
        let maxAbsVsExpectedCoreML: Double
        let minPSNRToneVsExpectedTorch32: Double
        enum CodingKeys: String, CodingKey {
            case maxAbsVsExpectedCoreML = "max_abs_vs_expected_coreml"
            case minPSNRToneVsExpectedTorch32 = "min_psnr_tone_vs_expected_torch32"
        }
    }
    /// `save_array`'s record: {"npy", "bin", "shape", "dtype": "float32-le"}, paths
    /// relative to the fixture directory.
    struct FileRef: Decodable {
        let npy: String
        let bin: String?
        let shape: [Int]
        let dtype: String?
    }
    struct Case: Decodable {
        let name: String
        /// "model": one prediction on (noisy, std); "tiled": the whole tiler on packed.
        let kind: String
        let k: Double
        let readVar: Double
        let tile: Int?
        let overlap: Int?
        let files: [String: FileRef]
        enum CodingKeys: String, CodingKey {
            case name, kind, tile, overlap, files
            case k = "K"
            case readVar = "read_var"
        }
    }
    let format: Int?
    let modelID: String?
    let calibDigest: String?
    let computeUnits: String?
    let suggestedTolerance: Tolerance
    let cases: [Case]
    enum CodingKeys: String, CodingKey {
        case format, cases
        case modelID = "model_id"
        case calibDigest = "calib_digest"
        case computeUnits = "compute_units"
        case suggestedTolerance = "suggested_tolerance"
    }
}

/// A float array read from a .npy file, dense C order.
private struct NpyArray {
    var shape: [Int]
    var values: [Float]
}

/// Minimal NumPy .npy reader (format versions 1–3): little-endian float32 ("<f4") or
/// float16 ("<f2"), C order only. Header: "\x93NUMPY", major, minor, a little-endian
/// header length (2 bytes in v1, 4 in v2/v3), then an ASCII Python dict literal such as
/// {'descr': '<f4', 'fortran_order': False, 'shape': (4, 32, 48), }.
private func readNpy(_ data: Data) throws -> NpyArray {
    let bytes = [UInt8](data)
    guard bytes.count >= 10, bytes[0] == 0x93, Array(bytes[1..<6]) == Array("NUMPY".utf8) else {
        throw FixtureError("not a .npy file")
    }
    let headerStart: Int, headerLength: Int
    switch bytes[6] {
    case 1:
        headerStart = 10
        headerLength = Int(bytes[8]) | Int(bytes[9]) << 8
    case 2, 3:
        guard bytes.count >= 12 else { throw FixtureError("truncated .npy header") }
        headerStart = 12
        headerLength = Int(bytes[8]) | Int(bytes[9]) << 8 | Int(bytes[10]) << 16 | Int(bytes[11]) << 24
    default:
        throw FixtureError(".npy format version \(bytes[6]) not supported")
    }
    let dataStart = headerStart + headerLength
    guard bytes.count >= dataStart else { throw FixtureError("truncated .npy header") }
    let header = String(decoding: bytes[headerStart..<dataStart], as: UTF8.self)

    /// The text after `'key':`, leading spaces dropped.
    func value(of key: String) throws -> Substring {
        guard let r = header.range(of: "'\(key)':") else { throw FixtureError(".npy header has no \(key): \(header)") }
        return header[r.upperBound...].drop(while: { $0 == " " })
    }
    let descrField = try value(of: "descr")
    guard descrField.first == "'", let close = descrField.dropFirst().firstIndex(of: "'") else {
        throw FixtureError("bad .npy descr: \(header)")
    }
    let descr = String(descrField[descrField.index(after: descrField.startIndex)..<close])
    guard try value(of: "fortran_order").hasPrefix("False") else {
        throw FixtureError("Fortran-order .npy not supported")
    }
    let shapeField = try value(of: "shape")
    guard shapeField.first == "(", let shapeClose = shapeField.firstIndex(of: ")") else {
        throw FixtureError("bad .npy shape: \(header)")
    }
    var shape: [Int] = []
    for part in shapeField[shapeField.index(after: shapeField.startIndex)..<shapeClose].split(separator: ",") {
        let trimmed = part.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue }
        guard let n = Int(trimmed), n >= 0 else { throw FixtureError("bad .npy shape: \(header)") }
        shape.append(n)
    }
    let count = shape.reduce(1, *)

    var values = [Float](repeating: 0, count: count)
    switch descr {
    case "<f4":
        guard bytes.count - dataStart >= 4 * count else { throw FixtureError("truncated .npy data") }
        for i in 0..<count {
            let o = dataStart + 4 * i
            let bits = UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
            values[i] = Float(bitPattern: bits)
        }
    case "<f2":
        guard bytes.count - dataStart >= 2 * count else { throw FixtureError("truncated .npy data") }
        for i in 0..<count {
            let o = dataStart + 2 * i
            values[i] = RawDenoiseHalf.float(from: UInt16(bytes[o]) | UInt16(bytes[o + 1]) << 8)
        }
    default:
        throw FixtureError(".npy dtype \(descr) not supported (little-endian <f4 / <f2 only)")
    }
    return NpyArray(shape: shape, values: values)
}

/// PSNR in train.tone() space, as coreml_parity.py `compare` computes it:
/// tone(x) = (max(x, 0) + 1e-3)^(1/2.2), peak 1, MSE over every element in Double.
private func tonePSNR(_ a: [Float], _ b: [Float]) -> Double {
    precondition(a.count == b.count && !a.isEmpty)
    func tone(_ x: Float) -> Double { pow(max(Double(x), 0) + 1e-3, 1 / 2.2) }
    var sum = 0.0
    for (x, y) in zip(a, b) {
        let d = tone(x) - tone(y)
        sum += d * d
    }
    let mse = sum / Double(a.count)
    return mse == 0 ? .infinity : 10 * log10(1 / mse)
}

/// coremltools ComputeUnit names, as the manifest's "compute_units" records them.
private func computeUnits(named name: String?) -> MLComputeUnits {
    switch name {
    case "CPU_ONLY": return .cpuOnly
    case "CPU_AND_GPU": return .cpuAndGPU
    case "CPU_AND_NE": return .cpuAndNeuralEngine
    default: return .all
    }
}

private final class PrepassProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Double] = []
    func append(_ v: Double) { lock.lock(); _values.append(v); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return _values }
}

final class RawDenoiseCoreMLRunnerTests: XCTestCase {

    private func planes(width: Int = 3, height: Int = 2, seed: Float = 0) -> RawDenoisePlanes {
        let n = 4 * width * height
        let values: [Float] = (0..<n).map { (i: Int) -> Float in Float(i) / Float(n) + seed - 0.01 }
        return RawDenoisePlanes(planes: values, width: width, height: height)
    }

    private func key(_ source: String = "photo-1") -> RawDenoiseCacheKey {
        RawDenoiseCacheKey(sourceIdentity: source, modelID: "lumen-denoise/test",
                           calibDigest: "calib", k: 1.6536e-5, readVar: 1.26e-7)
    }

    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-raw-denoise-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func eventually(timeout: TimeInterval = 5, _ message: String,
                            _ condition: () async -> Bool) async {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out: \(message)")
    }

    // MARK: - Half precision

    func testHalfConversionMatchesIEEEAtTheEdges() {
        let cases: [(Float, UInt16)] = [
            (0, 0x0000), (-0.0, 0x8000), (1, 0x3C00), (-2, 0xC000), (65504, 0x7BFF),
            (65520, 0x7C00),                 // rounds up past the largest half → Inf
            (0x1p-14, 0x0400),               // smallest normal
            (0x1p-24, 0x0001),               // smallest subnormal
            (0x1p-25, 0x0000),               // exact tie with zero → even (zero)
            (0x1.8p-25, 0x0001),             // above the tie → smallest subnormal
            (1 + 0x1p-11, 0x3C00),           // tie between 1 and 1+2⁻¹⁰ → even (1)
            (1 + 0x1.8p-10, 0x3C02),         // tie between odd and even → even (up)
            (.infinity, 0x7C00), (-.infinity, 0xFC00),
        ]
        for (value, bits) in cases {
            XCTAssertEqual(RawDenoiseHalf.bits(from: value), bits, "\(value)")
        }
        XCTAssertEqual(RawDenoiseHalf.float(from: 0x3555), 0.333251953125)
        XCTAssertEqual(RawDenoiseHalf.float(from: 0x0001), 0x1p-24)
        XCTAssertEqual(RawDenoiseHalf.float(from: 0x8000).sign, .minus)
        XCTAssertTrue(RawDenoiseHalf.float(from: 0x7E00).isNaN)
        XCTAssertTrue(RawDenoiseHalf.float(from: RawDenoiseHalf.bits(from: .nan)).isNaN,
                      "NaN must not collapse to Inf")
        // Every half survives a round trip through Float32 bit-for-bit.
        for h in UInt16.min...UInt16.max where (h & 0x7C00) != 0x7C00 || (h & 0x3FF) == 0 {
            XCTAssertEqual(RawDenoiseHalf.bits(from: RawDenoiseHalf.float(from: h)), h)
        }
    }

    // MARK: - Cache file

    func testCacheFileRoundTripsFloat32BitForBit() throws {
        let p = planes(width: 5, height: 3)
        let data = RawDenoiseCacheFile.encode(p, digest: key().digest, encoding: .float32)
        XCTAssertEqual(data.count, RawDenoiseCacheFile.headerSize + 4 * 60)
        XCTAssertEqual(try RawDenoiseCacheFile.decode(data, expectedDigest: key().digest), p)
    }

    func testCacheFileFloat16StoresTheNearestHalf() throws {
        var p = planes(width: 4, height: 2)
        p.planes[0] = -0.003   // below black: normalisation does not clip, nor may the cache
        p.planes[1] = 1.02     // above white with mismatched per-channel blacks
        let data = RawDenoiseCacheFile.encode(p, digest: key().digest, encoding: .float16)
        XCTAssertEqual(data.count, RawDenoiseCacheFile.headerSize + 2 * 32)
        let back = try RawDenoiseCacheFile.decode(data, expectedDigest: key().digest)
        XCTAssertEqual(back.width, 4)
        XCTAssertEqual(back.height, 2)
        for (a, b) in zip(p.planes, back.planes) {
            XCTAssertEqual(b, RawDenoiseHalf.float(from: RawDenoiseHalf.bits(from: a)))
            XCTAssertEqual(a, b, accuracy: max(abs(a), 0x1p-14) * 0x1p-11)
        }
    }

    func testCacheFileRefusesAnotherKeyATornFileAndAForeignOne() {
        let p = planes()
        let data = RawDenoiseCacheFile.encode(p, digest: key("a").digest, encoding: .float16)
        XCTAssertThrowsError(try RawDenoiseCacheFile.decode(data, expectedDigest: key("b").digest)) {
            XCTAssertEqual($0 as? RawDenoiseCacheFile.DecodeError, .digestMismatch)
        }
        XCTAssertThrowsError(try RawDenoiseCacheFile.decode(data.dropLast(2), expectedDigest: key("a").digest)) {
            XCTAssertEqual($0 as? RawDenoiseCacheFile.DecodeError, .truncated)
        }
        var foreign = data
        foreign[0] = UInt8(ascii: "X")
        XCTAssertThrowsError(try RawDenoiseCacheFile.decode(foreign, expectedDigest: key("a").digest)) {
            XCTAssertEqual($0 as? RawDenoiseCacheFile.DecodeError, .badMagic)
        }
        // And the good one still decodes: the refusals above are not a broken decoder.
        XCTAssertNoThrow(try RawDenoiseCacheFile.decode(data, expectedDigest: key("a").digest))
    }

    func testDiskCacheDeletesACorruptFileAndReportsAMiss() throws {
        let disk = RawDenoiseDiskCache(directory: try temporaryDirectory(), encoding: .float32)
        let digest = key().digest
        try disk.write(planes(), digest: digest)
        XCTAssertEqual(disk.read(digest: digest), planes())
        try Data([1, 2, 3]).write(to: disk.url(for: digest))
        XCTAssertNil(disk.read(digest: digest))
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.url(for: digest).path),
                       "a file that does not decode must be removed, not re-read every launch")
    }

    func testDiskPruneKeepsTheMostRecentlyTouchedFilesWithinBudget() throws {
        let disk = RawDenoiseDiskCache(directory: try temporaryDirectory(), encoding: .float32)
        let p = planes()
        let fileSize = RawDenoiseCacheFile.headerSize + 4 * p.planes.count
        let digests = ["a", "b", "c"].map { key($0).digest }
        for (i, d) in digests.enumerated() {
            try disk.write(p, digest: d)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1000 + i))],
                                                  ofItemAtPath: disk.url(for: d).path)
        }
        disk.prune(toBytes: 2 * fileSize)
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.url(for: digests[0]).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: disk.url(for: digests[1]).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: disk.url(for: digests[2]).path))
    }

    // MARK: - Pre-pass

    func testResultIsTheRunnersFullStrengthOutputAndIsServedFromMemoryAfter() async throws {
        let runner = FakeDenoiseRunner()
        let provider = FakeCFAProvider(planes: planes())
        let prepass = RawDenoisePrepass(runner: runner)
        let first = try await prepass.denoised(source: source, key: key(), provider: provider)
        XCTAssertEqual(first.planes, planes().planes.map { (v: Float) -> Float in v * 0.5 + 0.25 })
        let second = try await prepass.denoised(source: source, key: key(), provider: provider)
        XCTAssertEqual(second, first)
        XCTAssertEqual(runner.calls, 1)
        XCTAssertEqual(provider.calls, 1)
        // A different photo is a different key and a different run.
        _ = try await prepass.denoised(source: source, key: key("photo-2"), provider: provider)
        XCTAssertEqual(runner.calls, 2)
    }

    func testConcurrentRequestsForOneKeyRunTheNetworkOnce() async throws {
        let latch = PrepassLatch()
        let runner = FakeDenoiseRunner()
        let provider = FakeCFAProvider(planes: planes(), latch: latch)
        let prepass = RawDenoisePrepass(runner: runner)
        let k = key()
        let a = Task { try await prepass.denoised(source: source, key: k, provider: provider) }
        let b = Task { try await prepass.denoised(source: source, key: k, provider: provider) }
        await eventually("both requests joined one job") { await prepass.waiterCount(for: k) == 2 }
        await latch.release()
        let ra = try await a.value
        let rb = try await b.value
        XCTAssertEqual(ra, rb)
        XCTAssertEqual(runner.calls, 1)
        XCTAssertEqual(provider.calls, 1)
        let inFlight = await prepass.isInFlight(k)
        XCTAssertFalse(inFlight)
    }

    func testASecondPrepassServesFromDiskWithoutRunning() async throws {
        let dir = try temporaryDirectory()
        let config = RawDenoisePrepass.Configuration(cacheDirectory: dir, diskEncoding: .float32)
        let provider = FakeCFAProvider(planes: planes())
        let first = try await RawDenoisePrepass(runner: FakeDenoiseRunner(), configuration: config)
            .denoised(source: source, key: key(), provider: provider)

        let runner = FakeDenoiseRunner()
        let relaunched = RawDenoisePrepass(runner: runner, configuration: config)
        let peek = await relaunched.cachedResult(for: key())
        XCTAssertEqual(peek, first)
        let again = try await RawDenoisePrepass(runner: runner, configuration: config)
            .denoised(source: source, key: key(), provider: provider)
        XCTAssertEqual(again, first)
        XCTAssertEqual(runner.calls, 0)
        XCTAssertEqual(provider.calls, 1, "a disk hit must not even decode the RAW")
    }

    func testCancellingTheOnlyWaiterAbandonsTheComputation() async throws {
        let latch = PrepassLatch()
        let runner = FakeDenoiseRunner()
        let provider = FakeCFAProvider(planes: planes(), latch: latch)
        let prepass = RawDenoisePrepass(runner: runner)
        let k = key()
        let task = Task { try await prepass.denoised(source: source, key: k, provider: provider) }
        await eventually("the job reached the provider") { provider.calls == 1 }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled request must throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let inFlight = await prepass.isInFlight(k)
        XCTAssertFalse(inFlight)
        await latch.release()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(runner.calls, 0, "the network must not start for a request nobody wants")
        let cached = await prepass.cachedResult(for: k)
        XCTAssertNil(cached)
    }

    func testCancellingOneWaiterLeavesTheOtherServed() async throws {
        let latch = PrepassLatch()
        let runner = FakeDenoiseRunner()
        let provider = FakeCFAProvider(planes: planes(), latch: latch)
        let prepass = RawDenoisePrepass(runner: runner)
        let k = key()
        let leaving = Task { try await prepass.denoised(source: source, key: k, provider: provider) }
        let staying = Task { try await prepass.denoised(source: source, key: k, provider: provider) }
        await eventually("both requests joined one job") { await prepass.waiterCount(for: k) == 2 }
        leaving.cancel()
        do {
            _ = try await leaving.value
            XCTFail("the cancelled request must throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        await latch.release()
        let result = try await staying.value
        XCTAssertEqual(result.planes, planes().planes.map { (v: Float) -> Float in v * 0.5 + 0.25 })
        XCTAssertEqual(runner.calls, 1)
    }

    func testCancellationReachesTheRunnerBetweenSteps() async throws {
        let runner = FakeDenoiseRunner(steps: 500, stepDelay: 0.002)
        let prepass = RawDenoisePrepass(runner: runner)
        let task = Task { try await prepass.denoised(source: source, key: key(), provider: FakeCFAProvider(planes: planes())) }
        await eventually("the runner started") { runner.completedSteps > 2 }
        task.cancel()
        await eventually("the runner stopped") { runner.finished }
        XCTAssertTrue(runner.threwCancellation)
        XCTAssertLessThan(runner.completedSteps, 500)
    }

    func testProgressIsMonotonicAndEndsAtOne() async throws {
        let log = PrepassProgressLog()
        let prepass = RawDenoisePrepass(runner: FakeDenoiseRunner(steps: 4))
        _ = try await prepass.denoised(source: source, key: key(), provider: FakeCFAProvider(planes: planes()),
                                       progress: { log.append($0) })
        XCTAssertEqual(log.values, [0.25, 0.5, 0.75, 1])
        let hitLog = PrepassProgressLog()
        _ = try await prepass.denoised(source: source, key: key(), provider: FakeCFAProvider(planes: planes()),
                                       progress: { hitLog.append($0) })
        XCTAssertEqual(hitLog.values, [1], "a cache hit is complete at once")
    }

    func testMemoryBudgetEvictsTheLeastRecentlyUsedResult() async throws {
        let p = planes()
        let prepass = RawDenoisePrepass(runner: FakeDenoiseRunner(),
                                        configuration: .init(memoryBudgetBytes: 2 * p.byteCount))
        let provider = FakeCFAProvider(planes: p)
        _ = try await prepass.denoised(source: source, key: key("a"), provider: provider)
        _ = try await prepass.denoised(source: source, key: key("b"), provider: provider)
        _ = try await prepass.denoised(source: source, key: key("a"), provider: provider)  // touch a
        _ = try await prepass.denoised(source: source, key: key("c"), provider: provider)
        let a = await prepass.cachedResult(for: key("a"))
        let b = await prepass.cachedResult(for: key("b"))
        let c = await prepass.cachedResult(for: key("c"))
        XCTAssertNotNil(a)
        XCTAssertNil(b, "b was least recently used")
        XCTAssertNotNil(c)
        let resident = await prepass.residentBytes
        XCTAssertEqual(resident, 2 * p.byteCount)
    }

    func testStrengthIsABlendOverTheCachedResultAndClamped() {
        let original = planes()
        let denoised = RawDenoisePlanes(planes: original.planes.map { (v: Float) -> Float in v * 0.5 + 0.25 },
                                        width: original.width, height: original.height)
        XCTAssertEqual(RawDenoisePrepass.applyingStrength(1, denoised: denoised, original: original), denoised)
        XCTAssertEqual(RawDenoisePrepass.applyingStrength(0, denoised: denoised, original: original), original)
        XCTAssertEqual(RawDenoisePrepass.applyingStrength(7, denoised: denoised, original: original), denoised)
        let half = RawDenoisePrepass.applyingStrength(0.5, denoised: denoised, original: original)
        for i in original.planes.indices {
            XCTAssertEqual(half.planes[i], 0.5 * denoised.planes[i] + 0.5 * original.planes[i], accuracy: 1e-7)
        }
    }

    // MARK: - MLMultiArray plumbing (no model needed)

    func testMultiArrayRoundTripsInEveryInputType() throws {
        let values: [Float] = (0..<(4 * 3 * 5)).map { (i: Int) -> Float in Float(i) / 7 - 1.5 }
        for type in [MLMultiArrayDataType.float32, .float16, .double] {
            let array = try RawDenoiseCoreMLRunner.makeArray(values, shape: [1, 4, 3, 5], dataType: type)
            XCTAssertEqual(array.dataType, type)
            let back = try RawDenoiseCoreMLRunner.readArray(array, shape: [1, 4, 3, 5])
            for (a, b) in zip(values, back) {
                let expected = type == .float16 ? RawDenoiseHalf.float(from: RawDenoiseHalf.bits(from: a)) : a
                XCTAssertEqual(b, expected, "\(type.rawValue)")
            }
        }
    }

    func testReadArrayHonoursRowPaddedStrides() throws {
        // Core ML output buffers are often row-padded for the Neural Engine: 4×2×3 values
        // laid out with a row stride of 8. Reading them as contiguous would shear.
        let c = 4, h = 2, w = 3, rowStride = 8
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: c * h * rowStride)
        storage.initialize(repeating: -99, count: c * h * rowStride)
        for ci in 0..<c { for y in 0..<h { for x in 0..<w {
            storage[ci * h * rowStride + y * rowStride + x] = Float(100 * ci + 10 * y + x)
        } } }
        let array = try MLMultiArray(dataPointer: storage, shape: [1, 4, 2, 3], dataType: .float32,
                                     strides: [NSNumber(value: c * h * rowStride), NSNumber(value: h * rowStride),
                                               NSNumber(value: rowStride), 1],
                                     deallocator: { $0.deallocate() })
        let values = try RawDenoiseCoreMLRunner.readArray(array, shape: [1, 4, 2, 3])
        var expected: [Float] = []
        for ci in 0..<c { for y in 0..<h { for x in 0..<w {
            let code: Int = 100 * ci + 10 * y + x
            expected.append(Float(code))
        } } }
        XCTAssertEqual(values, expected)
        XCTAssertThrowsError(try RawDenoiseCoreMLRunner.readArray(array, shape: [1, 4, 3, 2]))
    }

    // MARK: - Model identity and compiled-model cache (no model needed)

    func testModelIdentityReadsTheExportMetadata() {
        let id = "0123456789abcdef"
        let calib = String(repeating: "ab", count: 32)
        let stamped = RawDenoiseCoreMLRunner.identity(fromMetadata: [
            MLModelMetadataKey.creatorDefinedKey: [
                "com.lumen.denoise.model_id": id,
                "com.lumen.denoise.calib_digest": calib,
                "com.lumen.denoise.residual": "true",
            ],
        ])
        XCTAssertEqual(stamped.modelID, id)
        XCTAssertEqual(stamped.calibDigest, calib)
        // export_coreml.py writes an empty calib_digest when calib.json was missing.
        let noCalib = RawDenoiseCoreMLRunner.identity(fromMetadata: [
            MLModelMetadataKey.creatorDefinedKey: ["com.lumen.denoise.model_id": id,
                                                   "com.lumen.denoise.calib_digest": ""],
        ])
        XCTAssertEqual(noCalib.modelID, id)
        XCTAssertNil(noCalib.calibDigest)
        let bare = RawDenoiseCoreMLRunner.identity(fromMetadata: [:])
        XCTAssertNil(bare.modelID)
        XCTAssertNil(bare.calibDigest)
    }

    func testCompiledCacheNameFollowsThePackageContents() throws {
        let fm = FileManager.default
        let dir = try temporaryDirectory()
        let package = dir.appendingPathComponent("lumen_denoise.mlpackage", isDirectory: true)
        let weights = package.appendingPathComponent("Data/com.apple.CoreML/weights", isDirectory: true)
        try fm.createDirectory(at: weights, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: package.appendingPathComponent("Manifest.json"))
        let weightFile = weights.appendingPathComponent("weight.bin")
        try Data(repeating: 1, count: 64).write(to: weightFile)

        let first = try RawDenoiseCoreMLRunner.compiledCacheName(for: package)
        XCTAssertEqual(try RawDenoiseCoreMLRunner.compiledCacheName(for: package), first, "must be stable")
        XCTAssertTrue(first.hasPrefix("lumen_denoise-unidentified-"), first)
        XCTAssertTrue(first.hasSuffix(".mlmodelc"), first)

        // New weights deep inside the package: the package directory's own size and
        // date need not change, the cache name must.
        let packageDate = try fm.attributesOfItem(atPath: package.path)[.modificationDate] as? Date
        try Data(repeating: 2, count: 96).write(to: weightFile)
        if let packageDate {
            try fm.setAttributes([.modificationDate: packageDate], ofItemAtPath: package.path)
        }
        let swapped = try RawDenoiseCoreMLRunner.compiledCacheName(for: package)
        XCTAssertNotEqual(swapped, first)

        // The export sidecar names the model and is part of the identity.
        try Data(#"{"model_id": "0123456789abcdef", "exported_at": "2026-10-20T00:00:00+00:00"}"#.utf8)
            .write(to: dir.appendingPathComponent("lumen_denoise.coreml.json"))
        let named = try RawDenoiseCoreMLRunner.compiledCacheName(for: package)
        XCTAssertTrue(named.hasPrefix("lumen_denoise-0123456789abcdef-"), named)
        XCTAssertNotEqual(named, swapped)
        try Data(#"{"model_id": "0123456789abcdef", "exported_at": "2026-10-21T00:00:00+00:00"}"#.utf8)
            .write(to: dir.appendingPathComponent("lumen_denoise.coreml.json"))
        XCTAssertNotEqual(try RawDenoiseCoreMLRunner.compiledCacheName(for: package), named,
                          "a re-export of the same weights is a different compile")

        XCTAssertThrowsError(try RawDenoiseCoreMLRunner.compiledCacheName(
            for: dir.appendingPathComponent("missing.mlpackage")))
    }

    // MARK: - Fixture plumbing (no model needed)

    func testNpyReaderParsesFloat32AndFloat16() throws {
        func npy(_ descr: String, shape: String, payload: [UInt8]) -> Data {
            var header = "{'descr': '\(descr)', 'fortran_order': False, 'shape': \(shape), }"
            // numpy pads with spaces and a newline so the data starts 64-byte aligned.
            while (10 + header.utf8.count + 1) % 64 != 0 { header += " " }
            header += "\n"
            let n = header.utf8.count
            var bytes: [UInt8] = [0x93]
            bytes += Array("NUMPY".utf8)
            bytes += [1, 0, UInt8(n & 0xFF), UInt8(n >> 8)]
            bytes += Array(header.utf8)
            bytes += payload
            return Data(bytes)
        }
        let floats: [Float] = [1, -2.5, 0x1p-20, 3]
        let f4 = try readNpy(npy("<f4", shape: "(1, 2, 2)", payload: floats.flatMap { (v: Float) -> [UInt8] in
            (0..<4).map { (i: Int) -> UInt8 in UInt8(truncatingIfNeeded: v.bitPattern >> (8 * i)) }
        }))
        XCTAssertEqual(f4.shape, [1, 2, 2])
        XCTAssertEqual(f4.values, floats)
        let f2 = try readNpy(npy("<f2", shape: "(3,)", payload: [0x00, 0x3C, 0x00, 0xC0, 0x01, 0x00]))
        XCTAssertEqual(f2.shape, [3])
        XCTAssertEqual(f2.values, [1, -2, 0x1p-24])
        XCTAssertThrowsError(try readNpy(npy(">f4", shape: "(1,)", payload: [0, 0, 0, 0])))
        XCTAssertThrowsError(try readNpy(npy("<f4", shape: "(2,)", payload: [0, 0, 0, 0])), "truncated")
        XCTAssertEqual(tonePSNR([0.5, 0.25], [0.5, 0.25]), .infinity)
    }

    // MARK: - Real model (opt-in)

    /// The P6 parity fixtures: coreml_parity.py runs the same synthetic inputs through
    /// torch fp32 and Python → Core ML and writes both answers. This runs them through
    /// THIS runner — "model" cases as one prediction on the supplied noisy/std, "tiled"
    /// cases through `denoise(...tile:overlap:)` with Lumen's own fp32 std map — and holds
    /// it to the manifest's suggested_tolerance: max abs vs expected_coreml (2e-3: same
    /// model, inputs differ only by the std map seeing the fp16-rounded tile in Python and
    /// by compute-unit nondeterminism), and tone-space PSNR vs expected_torch32 at least
    /// the gate's min_psnr (50 dB).
    func testExportedModelMatchesTheParityFixtures() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let fixtures = environment["LUMEN_DENOISE_FIXTURES"], !fixtures.isEmpty else {
            throw XCTSkip("set LUMEN_DENOISE_FIXTURES to the coreml_parity.py fixture directory to run this")
        }
        guard let modelPath = environment["LUMEN_DENOISE_MLMODEL"], !modelPath.isEmpty else {
            throw XCTSkip("set LUMEN_DENOISE_MLMODEL to the exported Lumen Denoise model to run this")
        }
        let dir = URL(fileURLWithPath: fixtures, isDirectory: true)
        let manifest = try JSONDecoder().decode(ParityManifest.self,
                                                from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        if let format = manifest.format { XCTAssertEqual(format, 1, "manifest format") }
        XCTAssertFalse(manifest.cases.isEmpty, "manifest has no cases")

        let runner = try await RawDenoiseCoreMLRunner(modelURL: URL(fileURLWithPath: modelPath),
                                                      computeUnits: computeUnits(named: manifest.computeUnits))
        // Fixtures generated for another export would make every comparison meaningless.
        if let expected = manifest.modelID, !expected.isEmpty, let actual = runner.modelIdentity.modelID {
            XCTAssertEqual(actual, expected, "LUMEN_DENOISE_FIXTURES were generated for another model")
            XCTAssertEqual(runner.cacheModelID(tile: 1024, overlap: 64), "\(actual)/t1024o64")
        }
        if let expected = manifest.calibDigest, !expected.isEmpty, let actual = runner.modelIdentity.calibDigest {
            XCTAssertEqual(actual, expected, "the model was exported against another calib.json")
        }
        let maxAbsTolerance = manifest.suggestedTolerance.maxAbsVsExpectedCoreML
        let minPSNR = manifest.suggestedTolerance.minPSNRToneVsExpectedTorch32

        for c in manifest.cases {
            func load(_ role: String) throws -> NpyArray {
                guard let ref = c.files[role] else { throw FixtureError("\(c.name): no \"\(role)\" file") }
                let array = try readNpy(Data(contentsOf: dir.appendingPathComponent(ref.npy)))
                guard array.shape == ref.shape else {
                    throw FixtureError("\(c.name)/\(role): .npy shape \(array.shape), manifest says \(ref.shape)")
                }
                return array
            }
            let expectedCoreML = try load("expected_coreml")
            let expectedTorch = try load("expected_torch32")
            let output: [Float]
            let shape: [Int]
            switch c.kind {
            case "model":
                let noisy = try load("noisy")
                let std = try load("std")
                guard noisy.shape.count == 3, noisy.shape[0] == 4,
                      std.shape == [1, noisy.shape[1], noisy.shape[2]] else {
                    XCTFail("\(c.name): noisy \(noisy.shape) / std \(std.shape) are not (4,H,W) / (1,H,W)")
                    continue
                }
                shape = noisy.shape
                output = try runner.predictTile(padded: noisy.values, std: std.values,
                                                height: shape[1], width: shape[2])
            case "tiled":
                let packed = try load("packed")
                guard packed.shape.count == 3, packed.shape[0] == 4, let tile = c.tile, let overlap = c.overlap else {
                    XCTFail("\(c.name): packed \(packed.shape) is not (4,H,W) or tile/overlap missing")
                    continue
                }
                shape = packed.shape
                output = try runner.denoise(packed: packed.values, width: shape[2], height: shape[1],
                                            params: RawDenoiseNoiseParams(k: c.k, readVar: c.readVar),
                                            tile: tile, overlap: overlap)
            default:
                XCTFail("\(c.name): unknown case kind \"\(c.kind)\"")
                continue
            }
            XCTAssertEqual(expectedCoreML.shape, shape, c.name)
            XCTAssertEqual(expectedTorch.shape, shape, c.name)
            guard output.count == expectedCoreML.values.count, output.count == expectedTorch.values.count else {
                XCTFail("\(c.name): output has \(output.count) values")
                continue
            }
            XCTAssertTrue(output.allSatisfy { $0.isFinite }, "\(c.name): non-finite output")
            var maxAbs = 0.0
            for (a, b) in zip(output, expectedCoreML.values) {
                let d = abs(Double(a) - Double(b))
                maxAbs = d.isNaN ? .infinity : max(maxAbs, d)
            }
            XCTAssertLessThanOrEqual(maxAbs, maxAbsTolerance, "\(c.name): max abs vs expected_coreml")
            let psnr = tonePSNR(output, expectedTorch.values)
            XCTAssertGreaterThanOrEqual(psnr, minPSNR, "\(c.name): tone-space PSNR vs expected_torch32")
        }
    }

    /// Runs the exported model when LUMEN_DENOISE_MLMODEL names it (.mlpackage or
    /// .mlmodelc). Pins only what holds for any trained weights: shape, finiteness, the
    /// residual being small next to the signal, and tiling being invisible — a frame
    /// denoised in small overlapping tiles agrees with one denoised in a single tile
    /// away from the borders. Numeric parity with PyTorch is the Mac's parity script.
    func testExportedModelDenoisesASyntheticFrame() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUMEN_DENOISE_MLMODEL"], !path.isEmpty else {
            throw XCTSkip("set LUMEN_DENOISE_MLMODEL to an exported Lumen Denoise model to run this")
        }
        let runner = try await RawDenoiseCoreMLRunner(modelURL: URL(fileURLWithPath: path), computeUnits: .cpuAndGPU)
        let w = 160, h = 96
        // Deterministic hash noise around a smooth ramp (never the system RNG).
        var packed = [Float](repeating: 0, count: 4 * w * h)
        for i in packed.indices {
            var x = UInt64(i) &* 0x9E37_79B9_7F4A_7C15
            x ^= x >> 31; x &*= 0xBF58_476D_1CE4_E5B9; x ^= x >> 27
            let u = Float(x % 10_000) / 10_000 - 0.5
            let ramp: Float = Float(i % w) / Float(w)
            let base: Float = 0.2 + 0.3 * ramp
            packed[i] = base + 0.02 * u
        }
        let params = RawDenoiseNoiseParams(k: 1.6536e-7 * 3200, readVar: 1e-5)
        let whole = try runner.denoise(packed: packed, width: w, height: h, params: params, tile: 1024, overlap: 64)
        XCTAssertEqual(whole.count, packed.count)
        XCTAssertTrue(whole.allSatisfy { $0.isFinite })
        let absResiduals: [Float] = zip(whole, packed).map { (a: Float, b: Float) -> Float in abs(a - b) }
        let meanAbsResidual: Float = absResiduals.reduce(0, +) / Float(packed.count)
        XCTAssertLessThan(meanAbsResidual, 0.05)
        XCTAssertGreaterThan(meanAbsResidual, 0, "the model returned its input unchanged")

        let tiled = try runner.denoise(packed: packed, width: w, height: h, params: params, tile: 64, overlap: 16)
        var worst: Float = 0
        for c in 0..<4 { for y in 24..<(h - 24) { for x in 24..<(w - 24) {
            let i = (c * h + y) * w + x
            worst = max(worst, abs(tiled[i] - whole[i]))
        } } }
        // Tiles see different std-map means s, so they are not bit-identical; a seam
        // would show as an error on the order of the noise (0.02), not this.
        XCTAssertLessThan(worst, 0.01)
    }
}
#endif
