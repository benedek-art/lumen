// QuickSignature.swift
// `photo.quick_sig` (docs/15 §15.9): the cheap content identity that turns a rename or
// a move into a RELOCATION instead of a fresh row with an orphaned rating.
//
// The column, the index (`photo_sig`) and the whole relocation branch of
// `CatalogStore.scan` shipped with no producer: every `ScannedFile` was built without
// a signature, so the match at scan time always saw nil, fell through to an insert, and
// marked the original `missing = 1`. Rating, flag, label, album and stack membership,
// history and every edit row stayed stranded on the row nobody would ever see again.
// Renaming a folder of RAWs threw the work away silently, which is the one thing this
// project says it will never do.
//
// WHAT IS HASHED, and why it is not the whole file. The first `prefixByteCount` bytes
// plus the file's length, in that order, as one buffer. A RAW is 25–80 MB and a shoot
// is thousands of them; hashing every byte of a card would be minutes of I/O for an
// answer that a megabyte already gives. One megabyte of a RAW covers the header, the
// maker notes and the start of the embedded preview — bytes that differ between any two
// frames a camera has ever written — and the length is appended so that two files
// sharing a prefix (a truncated copy, a same-header sibling) cannot share a signature.
//
// The length participates as eight little-endian bytes rather than as text: the buffer
// is bytes, and formatting a number into it would make the signature depend on a locale
// and a format string.
//
// This is an identity hint, NOT a checksum and NOT a security primitive. A collision
// costs a wrong relocation, which is why `scan` also requires the candidate row to have
// disappeared from its folder or to be marked missing before it will move anything.

import Foundation

public enum QuickSignature {

    /// How much of the head of the file the signature reads. docs/15 §15.9 says 1 MB.
    public static let prefixByteCount = 1 << 20

    /// The signature of the file at `url`, or a throw if it cannot be read.
    ///
    /// Reads at most `prefixByteCount` bytes however large the file is, and takes the
    /// length from the same open handle rather than from a separate `stat`, so the two
    /// halves of the signature describe the same moment of the same file.
    public static func compute(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: prefixByteCount) ?? Data()
        let size = Int64(bitPattern: try handle.seekToEnd())
        return signature(prefix: head, fileSize: size)
    }

    /// The pure half: bytes in, signature out. Separated so the format has a test that
    /// does not need a filesystem, and so the caller that already holds the head of a
    /// file — an ingest copy engine reading it anyway — need not read it twice.
    ///
    /// Prefixed `"xxh64:"` for exactly the reason `recipe_fp` is (Fingerprint.swift):
    /// the algorithm stays self-describing, so a future move to xxh3 is a value that
    /// announces itself rather than a silent reinterpretation of sixteen hex digits.
    public static func signature(prefix: Data, fileSize: Int64) -> String {
        var bytes = [UInt8](prefix)
        let length = UInt64(bitPattern: fileSize).littleEndian
        withUnsafeBytes(of: length) { bytes.append(contentsOf: $0) }
        return "xxh64:" + XXH64.hexDigest(bytes)
    }
}
