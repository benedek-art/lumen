// RenameTemplate.swift
// Ingest rename/folder templates (D38, docs/10 §ingest): Photo Mechanic's variables
// scoped to a solo shooter — about a dozen tokens, savable presets, no code replacements.
//
// Tokens: {orig} {seq} {seq:N} {date} {year} {month} {day} {time} {hour} {minute}
//         {camera} {serial} {iso} {job}
// Unknown tokens are an error at template-save time (never silently passed through).

import Foundation

public struct RenameContext: Sendable {
    public var originalBasename: String   // without extension
    public var captureDate: DateComponents // year/month/day/hour/minute/second
    public var camera: String?
    public var cameraSerial: String?
    public var iso: Int?
    public var job: String?

    public init(originalBasename: String, captureDate: DateComponents,
                camera: String? = nil, cameraSerial: String? = nil,
                iso: Int? = nil, job: String? = nil) {
        self.originalBasename = originalBasename
        self.captureDate = captureDate
        self.camera = camera
        self.cameraSerial = cameraSerial
        self.iso = iso
        self.job = job
    }
}

public enum RenameTemplate {

    public static let knownTokens: Set<String> = [
        "orig", "seq", "date", "year", "month", "day",
        "time", "hour", "minute", "camera", "serial", "iso", "job",
    ]

    /// Validate a template: returns the unknown token names (empty = valid).
    /// `{seq:N}` with N in 1…9 is valid; malformed forms are reported verbatim.
    public static func unknownTokens(in template: String) -> [String] {
        var bad: [String] = []
        for token in tokens(in: template) {
            if knownTokens.contains(token) { continue }
            if let width = seqWidth(of: token), (1...9).contains(width) { continue }
            bad.append(token)
        }
        return bad
    }

    /// Render a template. `seq` is the 1-based position in the ingest batch.
    public static func render(_ template: String, context: RenameContext, seq: Int) -> String {
        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "}") else {
                out += rest[open...]
                return sanitize(out)
            }
            let token = String(rest[afterOpen..<close])
            out += expand(token, context: context, seq: seq)
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        return sanitize(out)
    }

    // MARK: - internals

    static func tokens(in template: String) -> [String] {
        var found: [String] = []
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "}") else { break }
            found.append(String(rest[afterOpen..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return found
    }

    static func seqWidth(of token: String) -> Int? {
        guard token.hasPrefix("seq:") else { return nil }
        return Int(token.dropFirst(4))
    }

    static func expand(_ token: String, context: RenameContext, seq: Int) -> String {
        let c = context.captureDate
        func pad(_ v: Int?, _ width: Int) -> String {
            guard let v else { return "" }
            return String(format: "%0\(width)d", v)
        }
        switch token {
        case "orig": return context.originalBasename
        case "seq": return String(format: "%04d", seq)
        case "date":
            return pad(c.year, 4) + pad(c.month, 2) + pad(c.day, 2)
        case "year": return pad(c.year, 4)
        case "month": return pad(c.month, 2)
        case "day": return pad(c.day, 2)
        case "time": return pad(c.hour, 2) + pad(c.minute, 2) + pad(c.second, 2)
        case "hour": return pad(c.hour, 2)
        case "minute": return pad(c.minute, 2)
        case "camera": return context.camera ?? ""
        case "serial": return context.cameraSerial ?? ""
        case "iso": return context.iso.map(String.init) ?? ""
        case "job": return context.job ?? ""
        default:
            if let width = seqWidth(of: token), (1...9).contains(width) {
                return String(format: "%0\(width)d", seq)
            }
            return "" // unknown tokens render empty; validation rejects them at save
        }
    }

    /// Filesystem hygiene: strip path separators and control characters,
    /// collapse whitespace runs to single spaces, trim.
    static func sanitize(_ s: String) -> String {
        var cleaned = ""
        for ch in s {
            if ch == "/" || ch == ":" || ch == "\\" { cleaned.append("-") }
            else if let scalar = ch.unicodeScalars.first, scalar.value < 0x20 { continue }
            else { cleaned.append(ch) }
        }
        let parts = cleaned.split(separator: " ", omittingEmptySubsequences: true)
        return parts.joined(separator: " ")
    }
}
