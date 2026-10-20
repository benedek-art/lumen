// CaptureInfo.swift
// What the loupe's `I` overlay prints: shutter, aperture, ISO and focal length for the
// frame on screen, in the notation a camera's own display uses.
//
// "Was that 1/500 or 1/2000?" is the question behind most motion blur in a soccer burst,
// and "how long, at what focal length?" behind most star trailing. The catalog had the
// numbers and nothing in the app printed them. The formatting is here, pure and tested;
// the overlay only reads the file and lays the lines out.

import Foundation

/// Lightroom's `I` cycle: one line of exposure, then the full card, then nothing.
public enum CaptureInfoMode: String, Sendable, CaseIterable {
    case off
    case exposure
    case full

    public var next: CaptureInfoMode {
        switch self {
        case .off: return .exposure
        case .exposure: return .full
        case .full: return .off
        }
    }

    /// What the status bar says after a press.
    public var statusText: String {
        switch self {
        case .off: return "Info overlay off"
        case .exposure: return "Info overlay: exposure"
        case .full: return "Info overlay: exposure, camera and lens"
        }
    }
}

public enum CaptureInfoFormat {

    /// `1/2000 s` below a quarter second, `0.5 s` / `1.3 s` up to ten, `30 s` beyond —
    /// the reciprocal stops being readable once the denominator is a single digit.
    public static func shutter(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        if seconds < 0.3 {
            let denominator = Int((1 / seconds).rounded())
            return "1/\(denominator) s"
        }
        if seconds < 10 {
            return trimmed(seconds) + " s"
        }
        return "\(Int(seconds.rounded())) s"
    }

    /// `f/2.8`, `f/8`, `f/11`.
    public static func aperture(_ fNumber: Double?) -> String? {
        guard let fNumber, fNumber.isFinite, fNumber > 0 else { return nil }
        return "f/" + trimmed(fNumber)
    }

    /// `200 mm`; a phone's `4.3 mm` keeps its decimal.
    public static func focalLength(_ millimetres: Double?) -> String? {
        guard let millimetres, millimetres.isFinite, millimetres > 0 else { return nil }
        if millimetres < 10 { return trimmed(millimetres) + " mm" }
        return "\(Int(millimetres.rounded())) mm"
    }

    public static func iso(_ value: Int?) -> String? {
        guard let value, value > 0 else { return nil }
        return "ISO \(value)"
    }

    /// `2026-10-18 14:32:07`, the wall clock the camera recorded.
    public static func captureTime(_ components: DateComponents?) -> String? {
        guard let c = components, let year = c.year, let month = c.month, let day = c.day
        else { return nil }
        var text = "\(year)-\(pad(month))-\(pad(day))"
        if let hour = c.hour, let minute = c.minute {
            text += " \(pad(hour)):\(pad(minute))"
            if let second = c.second { text += ":\(pad(second))" }
        }
        return text
    }

    /// The overlay's lines for one frame, top to bottom. The file name is always first
    /// so a line of numbers is never shown without saying which frame it describes.
    public static func lines(mode: CaptureInfoMode, fileName: String,
                             metadata: PhotoMetadata?,
                             captureTime: DateComponents? = nil) -> [String] {
        guard mode != .off else { return [] }
        var out: [String] = [fileName]
        let exposure = [shutter(metadata?.shutterSeconds),
                        aperture(metadata?.aperture),
                        iso(metadata?.iso),
                        focalLength(metadata?.focalMM)].compactMap { $0 }
        out.append(exposure.isEmpty ? "No exposure data" : exposure.joined(separator: " · "))
        guard mode == .full else { return out }
        let body = [metadata?.camera, metadata?.lens]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !body.isEmpty { out.append(body.joined(separator: " · ")) }
        if let time = self.captureTime(captureTime) { out.append(time) }
        return out
    }

    /// One decimal, with a trailing `.0` dropped.
    private static func trimmed(_ value: Double) -> String {
        let tenths = (value * 10).rounded()
        if tenths.truncatingRemainder(dividingBy: 10) == 0 {
            return "\(Int(tenths / 10))"
        }
        return String(format: "%.1f", tenths / 10)
    }

    private static func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
