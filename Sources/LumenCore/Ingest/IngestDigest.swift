// IngestDigest.swift
// The streaming half of XXH64, and the file digest a verified copy is built on
// (D38, docs/10 §10.7).
//
// `XXH64.hash` in Recipe/Fingerprint.swift takes the whole message as one array. That
// is right for a recipe — a few kilobytes of canonical JSON — and wrong for a card. A
// medium-format frame is several hundred megabytes and a card is tens of gigabytes, so
// an engine that had to materialise each file to hash it would hold a whole frame in
// memory to say something about bytes that were already streaming past it on their way
// to the destination. Hashing IN FLIGHT is the whole design: the read is the expensive
// part, the hash rides along on it for free.
//
// Hence the same algorithm in incremental form — accumulators carried across chunks, a
// buffer for the ragged tail of a chunk that does not end on a 32-byte stripe, and the
// identical finalisation. Two implementations of one hash function is a drift risk, and
// the answer to a drift risk is a test rather than a promise: `IngestCopyTests` hashes
// the same bytes both ways at every length that reaches a different branch of the
// finaliser, and at chunk sizes chosen to split stripes and 8-byte words, so a divergence
// between this and the fixture-verified one-shot fails there rather than in a photograph.

import Foundation

/// XXH64 over a stream of chunks. Same constants, same rounds and same finalisation as
/// `XXH64.hash`; only the shape differs.
public struct XXH64Stream {

    private static let prime1: UInt64 = 0x9E3779B185EBCA87
    private static let prime2: UInt64 = 0xC2B2AE3D27D4EB4F
    private static let prime3: UInt64 = 0x165667B19E3779F9
    private static let prime4: UInt64 = 0x85EBCA77C2B2AE63
    private static let prime5: UInt64 = 0x27D4EB2F165667C5

    private let seed: UInt64
    private var v1: UInt64
    private var v2: UInt64
    private var v3: UInt64
    private var v4: UInt64
    /// Bytes seen since the last complete 32-byte stripe. Never reaches 32: a full
    /// buffer is consumed the moment it fills, which is what keeps the state constant
    /// no matter how the caller chops the stream up.
    private var pending: [UInt8] = []
    private var total: UInt64 = 0

    public init(seed: UInt64 = 0) {
        self.seed = seed
        v1 = seed &+ Self.prime1 &+ Self.prime2
        v2 = seed &+ Self.prime2
        v3 = seed
        v4 = seed &- Self.prime1
        pending.reserveCapacity(32)
    }

    public mutating func update(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard !bytes.isEmpty else { return }
        total &+= UInt64(bytes.count)
        var index = 0

        // Finish the previous chunk's tail first. The copy into a local is not
        // ceremony: `absorbStripe` mutates `self`, so reading `self.pending`'s storage
        // across that call would be two overlapping accesses to the same variable.
        if !pending.isEmpty {
            let wanted = 32 - pending.count
            let take = min(wanted, bytes.count)
            for k in 0..<take { pending.append(bytes[k]) }
            index = take
            guard pending.count == 32 else { return }
            let stripe = pending
            pending.removeAll(keepingCapacity: true)
            stripe.withUnsafeBufferPointer { absorbStripe($0, at: 0) }
        }

        while index + 32 <= bytes.count {
            absorbStripe(bytes, at: index)
            index += 32
        }
        while index < bytes.count {
            pending.append(bytes[index])
            index += 1
        }
    }

    public mutating func update(_ data: Data) {
        update([UInt8](data))
    }

    public mutating func update(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { update($0) }
    }

    /// The digest of everything fed in so far. Non-mutating on purpose — asking for the
    /// value must not end the stream, because the copy loop asks once at the end and a
    /// caller debugging a mismatch may well ask twice.
    public func finish() -> UInt64 {
        pending.withUnsafeBufferPointer { tail -> UInt64 in
            var h: UInt64
            if total >= 32 {
                h = Self.rotl(v1, 1) &+ Self.rotl(v2, 7)
                    &+ Self.rotl(v3, 12) &+ Self.rotl(v4, 18)
                h = Self.mergeRound(h, v1)
                h = Self.mergeRound(h, v2)
                h = Self.mergeRound(h, v3)
                h = Self.mergeRound(h, v4)
            } else {
                h = seed &+ Self.prime5
            }
            h &+= total

            var index = 0
            while index + 8 <= tail.count {
                let k = Self.round(0, Self.read64(tail, index))
                h ^= k
                h = Self.rotl(h, 27) &* Self.prime1 &+ Self.prime4
                index += 8
            }
            if index + 4 <= tail.count {
                h ^= UInt64(Self.read32(tail, index)) &* Self.prime1
                h = Self.rotl(h, 23) &* Self.prime2 &+ Self.prime3
                index += 4
            }
            while index < tail.count {
                h ^= UInt64(tail[index]) &* Self.prime5
                h = Self.rotl(h, 11) &* Self.prime1
                index += 1
            }

            h ^= h >> 33
            h &*= Self.prime2
            h ^= h >> 29
            h &*= Self.prime3
            h ^= h >> 32
            return h
        }
    }

    /// Lowercase 16-digit hex, the wire form `XXH64.hexDigest` produces.
    public func hexDigest() -> String {
        String(format: "%016llx", finish())
    }

    // MARK: - internals

    private mutating func absorbStripe(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) {
        v1 = Self.round(v1, Self.read64(bytes, offset))
        v2 = Self.round(v2, Self.read64(bytes, offset + 8))
        v3 = Self.round(v3, Self.read64(bytes, offset + 16))
        v4 = Self.round(v4, Self.read64(bytes, offset + 24))
    }

    private static func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 {
        (x << r) | (x >> (64 - r))
    }

    private static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        var acc = acc &+ input &* prime2
        acc = rotl(acc, 31)
        return acc &* prime1
    }

    private static func mergeRound(_ acc: UInt64, _ val: UInt64) -> UInt64 {
        let v = round(0, val)
        return (acc ^ v) &* prime1 &+ prime4
    }

    private static func read64(_ b: UnsafeBufferPointer<UInt8>, _ i: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(b[i + k]) << (8 * UInt64(k)) }  // little-endian
        return v
    }

    private static func read32(_ b: UnsafeBufferPointer<UInt8>, _ i: Int) -> UInt32 {
        var v: UInt32 = 0
        for k in 0..<4 { v |= UInt32(b[i + k]) << (8 * UInt32(k)) }
        return v
    }
}

/// What a file hashed to, and how long it was.
///
/// The length is carried BESIDE the hash and compared with it rather than trusted to
/// be implied by it. A truncated copy is the failure this whole subsystem exists to
/// catch, and it is the one failure that shows up in the length directly — so the
/// verdict does not rest on 64 bits of hash alone when a free, exact check is sitting
/// right there.
public struct IngestDigest: Sendable, Equatable, CustomStringConvertible {
    public let hex: String
    public let byteCount: Int64

    public init(hex: String, byteCount: Int64) {
        self.hex = hex
        self.byteCount = byteCount
    }

    public var description: String { "xxh64:\(hex) (\(byteCount) bytes)" }
}

public enum IngestFileDigest {
    /// Four megabytes: large enough that the per-read overhead disappears against a
    /// card's ~90–900 MB/s, small enough that a frame is never in memory whole.
    public static let defaultChunkSize = 4 << 20

    /// Hash a file as it exists on disk right now.
    public static func digest(of url: URL,
                             chunkSize: Int = defaultChunkSize) throws -> IngestDigest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var stream = XXH64Stream()
        var total: Int64 = 0
        while true {
            guard let chunk = try handle.read(upToCount: max(1, chunkSize)),
                  !chunk.isEmpty else { break }
            total += Int64(chunk.count)
            stream.update(chunk)
        }
        return IngestDigest(hex: stream.hexDigest(), byteCount: total)
    }
}
