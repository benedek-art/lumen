// ProofEvidence.swift
//
// Writes the rendered evidence frames docs/20 calls for: three pictures per control —
// neutral, full negative, full positive — that the owner can open and judge with his
// eyes rather than trusting a number he did not watch being taken.
//
// These are NOT assertions. Nothing here fails a test. Their whole job is to make a
// measured claim checkable by a human, because every defect docs/19 found was invisible
// until somebody looked, and half of them were invisible in a code review even then.
//
// PNG is written by hand, with DEFLATE "stored" blocks. Foundation on Linux exposes no
// compressor (`import Compression` is Apple-only), and taking a dependency to make test
// evidence smaller would trade a hermetic build for nothing that matters. A stored-block
// PNG is a completely valid PNG that any viewer opens; it is simply about as large as
// the raw pixels. At the sizes here that is tens of kilobytes.

import Foundation
import LumenCore

enum ProofEvidence {

    /// Where evidence lands. Overridable so a proof run can be pointed at a scratch
    /// directory rather than the repository.
    static var directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()          // Proof/
        .deletingLastPathComponent()          // LumenCoreTests/
        .appendingPathComponent("Proof/evidence", isDirectory: true)

    /// Write one display-linear render as an 8-bit sRGB PNG.
    @discardableResult
    static func write(_ image: ImageBuffer, named name: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        try encodePNG(image).write(to: url)
        return url
    }

    /// Lay several renders side by side with a gap, so a before/after is one file.
    /// A reviewer comparing two files flips between windows; a reviewer comparing two
    /// halves of one picture sees the difference.
    static func contactSheet(_ images: [ImageBuffer], gap: Int = 8) -> ImageBuffer {
        precondition(!images.isEmpty)
        let height = images.map(\.height).max() ?? 1
        let width = images.reduce(0) { $0 + $1.width } + gap * (images.count - 1)
        var sheet = ImageBuffer(width: width, height: height)
        // Mid-grey gutters: a black gutter reads as part of a dark picture.
        for y in 0..<height {
            for x in 0..<width { sheet[x, y] = RGB(gray: 0.5) }
        }
        var originX = 0
        for image in images {
            for y in 0..<image.height {
                for x in 0..<image.width { sheet[originX + x, y] = image[x, y] }
            }
            originX += image.width + gap
        }
        return sheet
    }

    // MARK: - PNG

    static func encodePNG(_ image: ImageBuffer) -> Data {
        var raw = Data()
        raw.reserveCapacity(image.height * (1 + image.width * 3))
        for y in 0..<image.height {
            raw.append(0)                       // filter type 0 (None), per scanline
            for x in 0..<image.width {
                let c = image[x, y]
                raw.append(byte(c.r)); raw.append(byte(c.g)); raw.append(byte(c.b))
            }
        }

        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        var ihdr = Data()
        ihdr.append(be32(UInt32(image.width)))
        ihdr.append(be32(UInt32(image.height)))
        ihdr.append(contentsOf: [8, 2, 0, 0, 0])   // 8-bit, truecolour, no interlace
        png.append(chunk("IHDR", ihdr))
        png.append(chunk("IDAT", zlibStored(raw)))
        png.append(chunk("IEND", Data()))
        return png
    }

    /// Display-linear → sRGB-encoded byte. Matches `ProofMetrics.linearToSRGB`, so the
    /// picture the owner looks at is on the same axis as the number in the record.
    private static func byte(_ v: Double) -> UInt8 {
        UInt8(Swift.max(0, Swift.min(255, (ProofMetrics.linearToSRGB(v) * 255).rounded())))
    }

    private static func be32(_ v: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16),
              UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)])
    }

    private static func chunk(_ type: String, _ payload: Data) -> Data {
        var out = be32(UInt32(payload.count))
        let body = Data(type.utf8) + payload
        out.append(body)
        out.append(be32(crc32(body)))
        return out
    }

    /// A zlib stream whose DEFLATE payload is stored (uncompressed) blocks.
    private static func zlibStored(_ raw: Data) -> Data {
        var out = Data([0x78, 0x01])            // CM=8, CINFO=7, FCHECK making it %31==0
        var offset = 0
        let maxBlock = 65535
        repeat {
            let length = Swift.min(maxBlock, raw.count - offset)
            let isFinal = (offset + length == raw.count)
            out.append(isFinal ? 1 : 0)         // BFINAL, BTYPE=00 (stored)
            out.append(UInt8(truncatingIfNeeded: length))
            out.append(UInt8(truncatingIfNeeded: length >> 8))
            let nlen = ~UInt16(truncatingIfNeeded: length)
            out.append(UInt8(truncatingIfNeeded: nlen))
            out.append(UInt8(truncatingIfNeeded: nlen >> 8))
            out.append(raw[raw.startIndex + offset ..< raw.startIndex + offset + length])
            offset += length
        } while offset < raw.count
        out.append(be32(adler32(raw)))
        return out
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    private static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }
}
