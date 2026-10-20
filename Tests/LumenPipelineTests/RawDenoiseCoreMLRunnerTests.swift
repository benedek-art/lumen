// The raw-denoise pre-pass and Core ML runner, tested without a network wherever the
// thing under test does not need one: the cache file format and its refusal of torn or
// foreign files, one computation per key however many ask, a cancelled request leaving
// without taking the others down, cancellation reaching the runner between tiles, the
// memory budget, the strength blend after retrieval, and the MLMultiArray plumbing
// (half conversion, padded output strides). The one test that needs the real exported
// model skips unless LUMEN_DENOISE_MLMODEL points at it.
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
        return packed.map { $0 * 0.5 + 0.25 }
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

private final class PrepassProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Double] = []
    func append(_ v: Double) { lock.lock(); _values.append(v); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return _values }
}

final class RawDenoiseCoreMLRunnerTests: XCTestCase {

    private func planes(width: Int = 3, height: Int = 2, seed: Float = 0) -> RawDenoisePlanes {
        let n = 4 * width * height
        return RawDenoisePlanes(planes: (0..<n).map { Float($0) / Float(n) + seed - 0.01 },
                                width: width, height: height)
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
        XCTAssertEqual(first.planes, planes().planes.map { $0 * 0.5 + 0.25 })
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
        XCTAssertEqual(result.planes, planes().planes.map { $0 * 0.5 + 0.25 })
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
        let denoised = RawDenoisePlanes(planes: original.planes.map { $0 * 0.5 + 0.25 },
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
        let values: [Float] = (0..<(4 * 3 * 5)).map { Float($0) / 7 - 1.5 }
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
        XCTAssertEqual(values, (0..<c).flatMap { ci in (0..<h).flatMap { y in (0..<w).map { x in Float(100 * ci + 10 * y + x) } } })
        XCTAssertThrowsError(try RawDenoiseCoreMLRunner.readArray(array, shape: [1, 4, 3, 2]))
    }

    // MARK: - Real model (opt-in)

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
            packed[i] = 0.2 + 0.3 * Float(i % w) / Float(w) + 0.02 * u
        }
        let params = RawDenoiseNoiseParams(k: 1.6536e-7 * 3200, readVar: 1e-5)
        let whole = try runner.denoise(packed: packed, width: w, height: h, params: params, tile: 1024, overlap: 64)
        XCTAssertEqual(whole.count, packed.count)
        XCTAssertTrue(whole.allSatisfy { $0.isFinite })
        let meanAbsResidual = zip(whole, packed).map { abs($0 - $1) }.reduce(0, +) / Float(packed.count)
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
