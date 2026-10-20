// RawDenoisePrepass.swift
// The background pre-pass that runs the raw denoiser once per photo and remembers the
// answer, so the Denoise toggle and Strength slider never wait on the network.
//
// Why a pre-pass and not a render stage: a full A7 IV frame is 12 tiles of 1024² through
// a UNet — seconds, not milliseconds — and Lumen's RAW stage is CIRAWFilter, which never
// exposes the mosaic (AppleRawSource.swift; docs/14 §4.1). So the network cannot run per
// frame or inside Apple's decode. It runs here, off the render actor, at background
// priority, and its output is cached:
//
//   · The cache holds the FULL-STRENGTH result, keyed by RawDenoiseCacheKey — source
//     pixels, model, calibration, noise parameters. Strength is NOT in the key: infer.py
//     applies it as `s·d + (1 − s)·p` afterwards, and so does `applyingStrength` here, so
//     dragging Strength is a blend over two buffers already in memory, never a re-run.
//   · Two tiers: an in-memory LRU under a byte budget (a 33 MP frame's planes are
//     ~130 MB as Float32), and files under a caches directory that survive relaunch.
//     The disk copy is Float16 by default: the network's own output is fp16 (Python's
//     too), so a second half rounding moves a value by at most half an fp16 ulp —
//     ≲ 4 DN at the top of a 14-bit range, the same order as Python's own output
//     quantisation (Denoise docs, MAP python §6). `.float32` is there for parity runs.
//   · One computation per key. A second request for a photo already in flight joins it
//     instead of starting another, and a request whose task is cancelled leaves without
//     disturbing the others; the computation itself is cancelled (between tiles) only
//     when no-one is waiting for it any more. Flicking through a burst therefore costs
//     at most the photos the user actually stopped on.
//
// What this file does NOT do yet, deliberately: decode a RAW file. How Lumen obtains
// the mosaic on macOS is the open decision (Denoise/docs/LUMEN_INTEGRATION.md — DNG CFA
// reader after Adobe DNG Converter, or LibRaw), so the source is a protocol,
// `RawCFAProvider`, with no concrete conformer. Nor does it feed the result to the
// render path: turning denoised planes back into something CIRAWFilter can open (a
// patched DNG) and swapping it in at RenderCoordinator.source(for:) is the documented
// follow-up. AppleRawSource is untouched.

#if os(macOS) && canImport(CoreML)

import Foundation
import LumenCore

// MARK: - Planes

/// Packed RGGB planes: channel-major 4·height·width Float32, normalised — the layout
/// infer.py's `denoise_packed` takes and returns. `width`/`height` are the PACKED
/// (half-resolution) dimensions.
public struct RawDenoisePlanes: Sendable, Equatable {
    public var planes: [Float]
    public var width: Int
    public var height: Int

    public init(planes: [Float], width: Int, height: Int) {
        precondition(width >= 0 && height >= 0 && planes.count == 4 * width * height,
                     "planes must hold 4·height·width values")
        self.planes = planes
        self.width = width
        self.height = height
    }

    /// Resident size, for the memory budget.
    public var byteCount: Int { planes.count * MemoryLayout<Float>.stride }
}

/// Where the pre-pass gets its input. A conformer must return exactly what infer.py
/// feeds the network: `to_rggb(pack(load(src).cfa), pattern)` — the visible CFA,
/// normalised `(raw − black[pattern position]) / (white − mean(black))` with no
/// clipping (RawDenoisePacking.normalize), cropped to even size, packed and permuted to
/// R, G1, G2, B (RawDenoisePacking.pack).
///
/// The main session must supply one. Lumen has no CFA reader today; the candidates
/// are a pure-Swift DNG raw-IFD reader fed by Adobe DNG Converter `-u` output, or a
/// LibRaw side-decode. Whichever it is, it must agree with rawpy's `raw_image_visible`
/// crop and 2×2 phase, because the network and the calibration table were built on it.
public protocol RawCFAProvider: Sendable {
    func packedRGGB(for source: URL) async throws -> RawDenoisePlanes
}

// MARK: - Pre-pass

public actor RawDenoisePrepass {

    public struct Configuration: Sendable {
        /// Root of the on-disk cache, normally under the app's Caches directory. `nil`
        /// keeps results in memory only.
        public var cacheDirectory: URL?
        /// In-memory LRU budget. Four full A7 IV frames at the default.
        public var memoryBudgetBytes: Int
        /// On-disk budget; oldest-touched files are deleted after each write. `nil` is
        /// unbounded (the host prunes).
        public var diskBudgetBytes: Int?
        public var diskEncoding: RawDenoiseCacheEncoding
        /// infer.py's defaults. Changing them changes the output, so a non-default
        /// value belongs in the cache key's `modelID`.
        public var tile: Int
        public var overlap: Int
        public var priority: TaskPriority

        public init(cacheDirectory: URL? = nil, memoryBudgetBytes: Int = 512 << 20,
                    diskBudgetBytes: Int? = nil, diskEncoding: RawDenoiseCacheEncoding = .float16,
                    tile: Int = 1024, overlap: Int = 64, priority: TaskPriority = .background) {
            self.cacheDirectory = cacheDirectory
            self.memoryBudgetBytes = memoryBudgetBytes
            self.diskBudgetBytes = diskBudgetBytes
            self.diskEncoding = diskEncoding
            self.tile = tile
            self.overlap = overlap
            self.priority = priority
        }
    }

    private struct Job {
        let generation: UInt64
        let task: Task<Void, Never>
        let progress: RawDenoiseProgressFanout
        var waiters: [UInt64: CheckedContinuation<RawDenoisePlanes, Error>]
    }

    private let runner: any RawDenoiseRunning
    public let configuration: Configuration

    private var memory: [String: RawDenoisePlanes] = [:]
    /// Least recently used first.
    private var recency: [String] = []
    private var memoryBytes = 0

    private var jobs: [String: Job] = [:]
    private var nextWaiterID: UInt64 = 0
    private var nextGeneration: UInt64 = 0

    public init(runner: any RawDenoiseRunning, configuration: Configuration = Configuration()) {
        self.runner = runner
        self.configuration = configuration
    }

    /// The full-strength denoised planes for `source`, from memory, disk, or a fresh run.
    ///
    /// The noise parameters are the key's `k`/`readVar` — the key is what the result is
    /// stored under, so it is also the one place they are read from; a caller cannot
    /// cache a result under parameters it did not compute with. `progress` gets the
    /// fraction of tiles done (1 at once on a cache hit). Throws `CancellationError`
    /// when the calling task is cancelled, whether or not the shared computation goes on.
    public func denoised(source: URL, key: RawDenoiseCacheKey, provider: any RawCFAProvider,
                         progress: (@Sendable (Double) -> Void)? = nil) async throws -> RawDenoisePlanes {
        let digest = key.digest
        if let hit = memoryHit(digest) {
            progress?(1)
            return hit
        }
        try Task.checkCancellation()
        let id = nextWaiterID
        nextWaiterID += 1
        return try await withTaskCancellationHandler {
            // The body runs synchronously on this actor (SE-0420 isolation inheritance),
            // so the waiter is registered before anything else can touch `jobs`.
            try await withCheckedThrowingContinuation { continuation in
                self.register(id: id, digest: digest, key: key, source: source,
                              provider: provider, progress: progress, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id, digest: digest) }
        }
    }

    /// A finished result without computing anything: memory, then disk.
    public func cachedResult(for key: RawDenoiseCacheKey) -> RawDenoisePlanes? {
        let digest = key.digest
        if let hit = memoryHit(digest) { return hit }
        guard let disk = diskCache, let planes = disk.read(digest: digest) else { return nil }
        insertMemory(digest, planes)
        return planes
    }

    public func isInFlight(_ key: RawDenoiseCacheKey) -> Bool { jobs[key.digest] != nil }

    /// Requests currently waiting on `key`'s computation (tests: dedupe and cancellation).
    func waiterCount(for key: RawDenoiseCacheKey) -> Int { jobs[key.digest]?.waiters.count ?? 0 }

    /// Abandons the computation for `key`; every waiter gets `CancellationError`.
    public func cancel(_ key: RawDenoiseCacheKey) {
        let digest = key.digest
        guard let job = jobs.removeValue(forKey: digest) else { return }
        job.task.cancel()
        for continuation in job.waiters.values { continuation.resume(throwing: CancellationError()) }
    }

    /// Drops the in-memory tier (memory pressure), and the disk tier too when asked.
    public func purge(includingDisk: Bool = false) {
        memory.removeAll()
        recency.removeAll()
        memoryBytes = 0
        if includingDisk, let dir = configuration.cacheDirectory {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Bytes resident in the in-memory tier.
    public var residentBytes: Int { memoryBytes }

    /// `strength · denoised + (1 − strength) · original` — infer.py's blend, applied to
    /// the cached full-strength result. `strength` is a fraction (the recipe's 0…100
    /// divided by 100), clamped to 0…1 here because this is the UI path and nothing
    /// good comes of extrapolating past the network's answer.
    public nonisolated static func applyingStrength(_ strength: Double, denoised: RawDenoisePlanes,
                                                    original: RawDenoisePlanes) -> RawDenoisePlanes {
        precondition(denoised.width == original.width && denoised.height == original.height,
                     "denoised and original planes differ in size")
        let s = Float(min(max(strength, 0), 1))
        let blended = RawDenoiseTiler.blend(denoised: denoised.planes, original: original.planes, strength: s)
        return RawDenoisePlanes(planes: blended, width: denoised.width, height: denoised.height)
    }

    // MARK: - Waiters and jobs

    private func register(id: UInt64, digest: String, key: RawDenoiseCacheKey, source: URL,
                          provider: any RawCFAProvider, progress: (@Sendable (Double) -> Void)?,
                          continuation: CheckedContinuation<RawDenoisePlanes, Error>) {
        // No memory re-check: `denoised` checked a moment ago and has not suspended since.
        if var job = jobs[digest] {
            job.waiters[id] = continuation
            if let progress { job.progress.add(id, progress) }
            jobs[digest] = job
            return
        }

        nextGeneration += 1
        let generation = nextGeneration
        let fanout = RawDenoiseProgressFanout()
        if let progress { fanout.add(id, progress) }
        let runner = self.runner
        let configuration = self.configuration
        let disk = diskCache
        let task = Task.detached(priority: configuration.priority) {
            let outcome: Result<RawDenoisePlanes, Error>
            do {
                outcome = .success(try await Self.produce(digest: digest, key: key, source: source,
                                                          provider: provider, runner: runner,
                                                          configuration: configuration, disk: disk,
                                                          progress: fanout))
            } catch {
                outcome = .failure(error)
            }
            await self.finish(digest: digest, generation: generation, outcome: outcome)
        }
        jobs[digest] = Job(generation: generation, task: task, progress: fanout, waiters: [id: continuation])
    }

    private func cancelWaiter(id: UInt64, digest: String) {
        // Absent means already answered: registration happens before the operation can
        // suspend, so this hop can never arrive ahead of it.
        guard var job = jobs[digest], let continuation = job.waiters.removeValue(forKey: id) else { return }
        job.progress.remove(id)
        continuation.resume(throwing: CancellationError())
        if job.waiters.isEmpty {
            job.task.cancel()
            jobs[digest] = nil
        } else {
            jobs[digest] = job
        }
    }

    private func finish(digest: String, generation: UInt64, outcome: Result<RawDenoisePlanes, Error>) {
        // A result is a result even if everyone stopped waiting for it in the meantime.
        if case .success(let planes) = outcome { insertMemory(digest, planes) }
        guard let job = jobs[digest], job.generation == generation else { return }
        jobs[digest] = nil
        for continuation in job.waiters.values { continuation.resume(with: outcome) }
    }

    /// The work itself, on the detached task: disk, else provider → runner → disk.
    private static func produce(digest: String, key: RawDenoiseCacheKey, source: URL,
                                provider: any RawCFAProvider, runner: any RawDenoiseRunning,
                                configuration: Configuration, disk: RawDenoiseDiskCache?,
                                progress: RawDenoiseProgressFanout) async throws -> RawDenoisePlanes {
        if let disk, let planes = disk.read(digest: digest) {
            progress.report(1)
            return planes
        }
        try Task.checkCancellation()
        let input = try await provider.packedRGGB(for: source)
        try Task.checkCancellation()
        let params = RawDenoiseNoiseParams(k: key.k, readVar: key.readVar)
        let output = try runner.denoise(packed: input.planes, width: input.width, height: input.height,
                                        params: params, tile: configuration.tile,
                                        overlap: configuration.overlap,
                                        progress: { progress.report($0) })
        let planes = RawDenoisePlanes(planes: output, width: input.width, height: input.height)
        if let disk {
            // A failed write costs a recompute next launch, nothing more.
            try? disk.write(planes, digest: digest)
            if let budget = configuration.diskBudgetBytes { disk.prune(toBytes: budget) }
        }
        return planes
    }

    // MARK: - Memory tier

    private var diskCache: RawDenoiseDiskCache? {
        configuration.cacheDirectory.map { RawDenoiseDiskCache(directory: $0, encoding: configuration.diskEncoding) }
    }

    private func memoryHit(_ digest: String) -> RawDenoisePlanes? {
        guard let planes = memory[digest] else { return nil }
        if let i = recency.firstIndex(of: digest) { recency.remove(at: i) }
        recency.append(digest)
        return planes
    }

    private func insertMemory(_ digest: String, _ planes: RawDenoisePlanes) {
        if let old = memory.removeValue(forKey: digest) {
            memoryBytes -= old.byteCount
            if let i = recency.firstIndex(of: digest) { recency.remove(at: i) }
        }
        // A frame larger than the whole budget is served from disk instead of evicting
        // everything else to make room for it.
        guard planes.byteCount <= configuration.memoryBudgetBytes else { return }
        while memoryBytes + planes.byteCount > configuration.memoryBudgetBytes, !recency.isEmpty {
            let victim = recency.removeFirst()
            if let gone = memory.removeValue(forKey: victim) { memoryBytes -= gone.byteCount }
        }
        memory[digest] = planes
        recency.append(digest)
        memoryBytes += planes.byteCount
    }
}

// MARK: - Progress

/// Several waiters' progress callbacks behind one runner callback. The runner reports
/// from the detached task's thread, synchronously, so this is a lock rather than an
/// actor hop — an actor would let tile 3's report overtake tile 2's.
final class RawDenoiseProgressFanout: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [UInt64: @Sendable (Double) -> Void] = [:]

    func add(_ id: UInt64, _ handler: @escaping @Sendable (Double) -> Void) {
        lock.lock(); handlers[id] = handler; lock.unlock()
    }

    func remove(_ id: UInt64) {
        lock.lock(); handlers[id] = nil; lock.unlock()
    }

    func report(_ fraction: Double) {
        lock.lock()
        let current = Array(handlers.values)
        lock.unlock()
        for handler in current { handler(fraction) }
    }
}

// MARK: - Disk tier

public enum RawDenoiseCacheEncoding: UInt32, Sendable {
    case float32 = 1
    case float16 = 2
}

/// The on-disk format: a 96-byte little-endian header, then the planes.
///
///     0   8  magic "LRDNCFA1"
///     8   4  format version (1)
///    12   4  encoding (RawDenoiseCacheEncoding)
///    16   4  channels (4)
///    20   4  height (packed)
///    24   4  width (packed)
///    28  64  key digest, ASCII hex — the file is refused if it is not the one asked for
///    92   4  zero
///    96      channels·height·width values, Float32 or IEEE half, little-endian
///
/// Anything that does not parse exactly is treated as a miss and deleted: a torn or
/// foreign file must cost a recompute, never a wrong picture.
enum RawDenoiseCacheFile {
    static let magic = Array("LRDNCFA1".utf8)
    static let version: UInt32 = 1
    static let headerSize = 96

    enum DecodeError: Error, Equatable {
        case truncated
        case badMagic
        case unsupportedVersion(UInt32)
        case unsupportedEncoding(UInt32)
        case badShape
        case digestMismatch
    }

    static func encode(_ planes: RawDenoisePlanes, digest: String, encoding: RawDenoiseCacheEncoding) -> Data {
        let count = planes.planes.count
        let valueSize = encoding == .float32 ? 4 : 2
        var data = Data(count: headerSize + count * valueSize)
        let digestBytes = Array(digest.utf8.prefix(64))
        data.withUnsafeMutableBytes { raw in
            for (i, b) in magic.enumerated() { raw[i] = b }
            raw.storeBytes(of: version.littleEndian, toByteOffset: 8, as: UInt32.self)
            raw.storeBytes(of: encoding.rawValue.littleEndian, toByteOffset: 12, as: UInt32.self)
            raw.storeBytes(of: UInt32(4).littleEndian, toByteOffset: 16, as: UInt32.self)
            raw.storeBytes(of: UInt32(planes.height).littleEndian, toByteOffset: 20, as: UInt32.self)
            raw.storeBytes(of: UInt32(planes.width).littleEndian, toByteOffset: 24, as: UInt32.self)
            for (i, b) in digestBytes.enumerated() { raw[28 + i] = b }
            planes.planes.withUnsafeBufferPointer { values in
                switch encoding {
                case .float32:
                    for i in 0..<count {
                        raw.storeBytes(of: values[i].bitPattern.littleEndian,
                                       toByteOffset: headerSize + 4 * i, as: UInt32.self)
                    }
                case .float16:
                    for i in 0..<count {
                        raw.storeBytes(of: RawDenoiseHalf.bits(from: values[i]).littleEndian,
                                       toByteOffset: headerSize + 2 * i, as: UInt16.self)
                    }
                }
            }
        }
        return data
    }

    static func decode(_ data: Data, expectedDigest: String) throws -> RawDenoisePlanes {
        guard data.count >= headerSize else { throw DecodeError.truncated }
        return try data.withUnsafeBytes { raw -> RawDenoisePlanes in
            func u32(_ offset: Int) -> UInt32 {
                UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            }
            guard Array(raw[0..<8]) == magic else { throw DecodeError.badMagic }
            let fileVersion = u32(8)
            guard fileVersion == version else { throw DecodeError.unsupportedVersion(fileVersion) }
            guard let encoding = RawDenoiseCacheEncoding(rawValue: u32(12)) else {
                throw DecodeError.unsupportedEncoding(u32(12))
            }
            let channels = Int(u32(16)), height = Int(u32(20)), width = Int(u32(24))
            guard channels == 4 else { throw DecodeError.badShape }
            guard Array(raw[28..<92]) == Array(expectedDigest.utf8.prefix(64)) else {
                throw DecodeError.digestMismatch
            }
            // A corrupt or foreign header can carry any UInt32 here; plain `*` would trap
            // on overflow before `read` gets to delete the file.
            let valueSize = encoding == .float32 ? 4 : 2
            let plane = height.multipliedReportingOverflow(by: width)
            let values4 = plane.partialValue.multipliedReportingOverflow(by: channels)
            let bytes = values4.partialValue.multipliedReportingOverflow(by: valueSize)
            guard !plane.overflow, !values4.overflow, !bytes.overflow,
                  data.count - headerSize == bytes.partialValue else { throw DecodeError.truncated }
            let count = values4.partialValue
            var values = [Float](repeating: 0, count: count)
            switch encoding {
            case .float32:
                for i in 0..<count {
                    values[i] = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(
                        fromByteOffset: headerSize + 4 * i, as: UInt32.self)))
                }
            case .float16:
                for i in 0..<count {
                    values[i] = RawDenoiseHalf.float(from: UInt16(littleEndian: raw.loadUnaligned(
                        fromByteOffset: headerSize + 2 * i, as: UInt16.self)))
                }
            }
            return RawDenoisePlanes(planes: values, width: width, height: height)
        }
    }
}

/// Files of `RawDenoiseCacheFile` under `directory/<first two hex>/<digest>.lrdn`.
struct RawDenoiseDiskCache: Sendable {
    static let fileExtension = "lrdn"
    let directory: URL
    let encoding: RawDenoiseCacheEncoding

    func url(for digest: String) -> URL {
        directory.appendingPathComponent(String(digest.prefix(2)), isDirectory: true)
            .appendingPathComponent(digest).appendingPathExtension(Self.fileExtension)
    }

    /// The cached planes, or nil. A file that fails to decode is deleted. A hit's
    /// modification date is bumped so `prune` evicts least-recently-USED, not oldest.
    func read(digest: String) -> RawDenoisePlanes? {
        let file = url(for: digest)
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        do {
            let planes = try RawDenoiseCacheFile.decode(data, expectedDigest: digest)
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return planes
        } catch {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
    }

    /// Atomic: a reader sees the old file or the whole new one, never a torn one.
    func write(_ planes: RawDenoisePlanes, digest: String) throws {
        let file = url(for: digest)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try RawDenoiseCacheFile.encode(planes, digest: digest, encoding: encoding)
            .write(to: file, options: .atomic)
    }

    func remove(digest: String) {
        try? FileManager.default.removeItem(at: url(for: digest))
    }

    /// Deletes least-recently-touched cache files until the total is within `limit`.
    func prune(toBytes limit: Int) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let walker = fm.enumerator(at: directory, includingPropertiesForKeys: keys) else { return }
        var files: [(url: URL, size: Int, date: Date)] = []
        for case let file as URL in walker where file.pathExtension == Self.fileExtension {
            let values = try? file.resourceValues(forKeys: Set(keys))
            files.append((file, values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast))
        }
        var total = files.reduce(0) { $0 + $1.size }
        for file in files.sorted(by: { $0.date < $1.date }) where total > limit {
            try? fm.removeItem(at: file.url)
            total -= file.size
        }
    }
}

// MARK: - Half precision

/// IEEE 754 binary16 ⇄ Float32 in software, round-to-nearest-even, NaN kept NaN.
/// Swift's `Float16` is unavailable on x86_64 macOS, and this file must build there.
/// Checked bit-for-bit against `Float16` over all 2³² Float32 patterns and all 2¹⁶
/// half patterns (RawDenoiseCoreMLRunnerTests spot-checks the edges).
enum RawDenoiseHalf {
    static func bits(from value: Float) -> UInt16 {
        let x = value.bitPattern
        let sign = UInt16(truncatingIfNeeded: (x >> 16) & 0x8000)
        let exponent = Int((x >> 23) & 0xFF)
        let mantissa = x & 0x7F_FFFF
        if exponent == 0xFF {
            // Inf stays Inf; NaN keeps a quiet bit so it cannot collapse to Inf.
            return sign | 0x7C00 | (mantissa != 0 ? 0x0200 | UInt16(truncatingIfNeeded: mantissa >> 13) : 0)
        }
        let e = exponent - 112  // rebias 127 → 15
        if e >= 0x1F { return sign | 0x7C00 }
        if e <= 0 {
            // Half subnormal (or zero): m = full · 2^(e − 14), rounded to nearest even.
            if e < -10 { return sign }
            let full = mantissa | 0x80_0000
            let shift = UInt32(14 - e)
            var m = full >> shift
            let rem = full & ((UInt32(1) << shift) - 1)
            let halfway = UInt32(1) << (shift - 1)
            if rem > halfway || (rem == halfway && (m & 1) == 1) { m += 1 }
            return sign | UInt16(truncatingIfNeeded: m)
        }
        // A carry out of the mantissa rolls into the exponent, and out of 30 into Inf —
        // both exactly what rounding should do.
        var h = (UInt32(e) << 10) | (mantissa >> 13)
        let rem = mantissa & 0x1FFF
        if rem > 0x1000 || (rem == 0x1000 && (h & 1) == 1) { h += 1 }
        return sign | UInt16(truncatingIfNeeded: h)
    }

    static func float(from bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = UInt32(bits >> 10) & 0x1F
        let mantissa = UInt32(bits & 0x3FF)
        if exponent == 0 {
            let magnitude = Float(mantissa) * 0x1p-24
            return sign != 0 ? -magnitude : magnitude
        }
        if exponent == 0x1F { return Float(bitPattern: sign | 0x7F80_0000 | (mantissa << 13)) }
        return Float(bitPattern: sign | ((exponent + 112) << 23) | (mantissa << 13))
    }
}

#endif
