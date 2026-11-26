// DNGRawPlanes.swift
// Whether a DNG's main raw image is one plane of linear samples (a monochrome sensor
// with no colour filter array), read from the TIFF structure alone.
//
// macOS 15's CIRAWFilter decodes the Leica M Monochrom (Typ 246) DNG to an all-zero
// frame (raw-corpus file 1087), so `AppleRawSource` probes such files before showing
// them. This is the cheap gate that keeps the probe off every other file.

import Foundation

public enum DNGRawPlanes {

    /// The main raw image's layout, or nil when `prefix` is not a DNG or its raw IFD
    /// is not inside `prefix`.
    public struct Layout: Equatable, Sendable {
        public let photometric: Int
        public let samplesPerPixel: Int

        /// PhotometricInterpretation 34892 (LinearRaw) with one sample per pixel.
        public var isSinglePlaneLinear: Bool {
            photometric == 34892 && samplesPerPixel == 1
        }

        public init(photometric: Int, samplesPerPixel: Int) {
            self.photometric = photometric
            self.samplesPerPixel = samplesPerPixel
        }
    }

    private struct Entry {
        let type: Int
        let count: Int
        let valueAt: Int
    }

    public static func layout(prefix: Data) -> Layout? {
        let bytes = [UInt8](prefix)
        guard bytes.count >= 8 else { return nil }
        let little: Bool
        switch (bytes[0], bytes[1]) {
        case (0x49, 0x49): little = true
        case (0x4D, 0x4D): little = false
        default: return nil
        }
        func u16(_ at: Int) -> Int? {
            guard at >= 0, at + 2 <= bytes.count else { return nil }
            let a = Int(bytes[at]), b = Int(bytes[at + 1])
            return little ? a | b << 8 : a << 8 | b
        }
        func u32(_ at: Int) -> Int? {
            guard let lo = u16(little ? at : at + 2), let hi = u16(little ? at + 2 : at)
            else { return nil }
            return lo | hi << 16
        }
        guard u16(2) == 42, let first = u32(4) else { return nil }

        func entries(_ at: Int) -> [Int: Entry]? {
            guard let n = u16(at), n > 0, n <= 1024 else { return nil }
            var out: [Int: Entry] = [:]
            for i in 0..<n {
                let e = at + 2 + 12 * i
                guard e + 12 <= bytes.count, let tag = u16(e), let type = u16(e + 2),
                      let count = u32(e + 4) else { return nil }
                let size = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8,
                            11: 4, 12: 8, 13: 4][type] ?? 1
                let inline = size * count <= 4
                guard let valueAt = inline ? e + 8 : u32(e + 8) else { return nil }
                out[tag] = Entry(type: type, count: count, valueAt: valueAt)
            }
            return out
        }
        func integer(_ entry: Entry?, index: Int = 0) -> Int? {
            guard let entry, index < entry.count else { return nil }
            switch entry.type {
            case 3: return u16(entry.valueAt + 2 * index)
            case 4, 13: return u32(entry.valueAt + 4 * index)
            case 1, 7: return entry.valueAt + index < bytes.count
                ? Int(bytes[entry.valueAt + index]) : nil
            default: return nil
            }
        }

        guard let ifd0 = entries(first), ifd0[0xC612] != nil else { return nil }
        // The raw image is the IFD with NewSubfileType 0: IFD0 itself, or a SubIFD.
        var candidates: [[Int: Entry]] = [ifd0]
        if let subs = ifd0[0x014A] {
            for index in 0..<Swift.min(subs.count, 16) {
                if let at = integer(subs, index: index), let ifd = entries(at) {
                    candidates.append(ifd)
                }
            }
        }
        for ifd in candidates where (integer(ifd[0x00FE]) ?? 0) == 0 {
            guard let photometric = integer(ifd[0x0106]) else { continue }
            return Layout(photometric: photometric,
                          samplesPerPixel: integer(ifd[0x0115]) ?? 1)
        }
        return nil
    }
}
