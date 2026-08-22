// CaptureMetadataReader.swift
// EXIF off a file, without decoding it.
//
// `CGImageSourceCopyPropertiesAtIndex` reads the metadata block and stops. That is the
// whole reason this is a separate thing from the decode path: a folder of five thousand
// RAWs can have its capture times, bodies, lenses and exposures read in the time one of
// them would take to demosaic, and the grid is already on screen while it happens.
//
// Nothing here interprets. Values are copied across as the file states them, and where
// EXIF is ambiguous the ambiguity is resolved in `PhotoMetadata` — which is pure and
// testable — rather than here, where it would need a file to exercise.

#if os(macOS)

import Foundation
import ImageIO
import LumenCore

public enum CaptureMetadataReader {

    /// Read what the file says about how it was made. Returns an empty value rather
    /// than nil for a file that simply carries no EXIF, and nil only when the file
    /// cannot be opened at all — the caller treats those differently.
    public static func read(url: URL) -> PhotoMetadata? {
        // `kCGImageSourceShouldCache: false` because nothing here wants the pixels, and
        // caching them would put a five-thousand-photo folder's worth of decoded images
        // through memory for metadata that is a few hundred bytes each.
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary)
        else { return nil }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            source, 0, options as CFDictionary) as? [CFString: Any]
        else { return PhotoMetadata() }

        var out = PhotoMetadata()

        out.width = properties[kCGImagePropertyPixelWidth] as? Int
        out.height = properties[kCGImagePropertyPixelHeight] as? Int
        out.orientation = properties[kCGImagePropertyOrientation] as? Int

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let aux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

        // Body: Make and Model separately in TIFF, and every catalog in the world shows
        // them joined. "NIKON CORPORATION" + "NIKON Z 8" would read as a stutter, so a
        // model that already begins with the make is left alone.
        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?
            .trimmingCharacters(in: .whitespaces)
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?
            .trimmingCharacters(in: .whitespaces)
        out.camera = Self.joinCamera(make: make, model: model)
        out.cameraSerial = exif[kCGImagePropertyExifBodySerialNumber] as? String

        out.lens = (exif[kCGImagePropertyExifLensModel] as? String)
            ?? (aux[kCGImagePropertyExifAuxLensModel] as? String)

        // ISOSpeedRatings is an ARRAY in the standard, and a scalar in plenty of files.
        if let ratings = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int] {
            out.iso = ratings.first
        } else if let single = exif[kCGImagePropertyExifISOSpeedRatings] as? Int {
            out.iso = single
        }

        out.shutterSeconds = exif[kCGImagePropertyExifExposureTime] as? Double
        out.aperture = exif[kCGImagePropertyExifFNumber] as? Double
        out.focalMM = exif[kCGImagePropertyExifFocalLength] as? Double

        // DateTimeOriginal is when the shutter opened; DateTimeDigitized is when a
        // scanner or a card reader got to it. For a photograph the first is the one
        // that means anything, and the fallback only matters for scans.
        let stamp = (exif[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (exif[kCGImagePropertyExifDateTimeDigitized] as? String)
            ?? (tiff[kCGImagePropertyTIFFDateTime] as? String)
        if let stamp {
            let offsetText = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String
            let offset = offsetText.flatMap(PhotoMetadata.parseEXIFOffset) ?? 0
            out.captureAt = PhotoMetadata.parseEXIFDate(stamp, offsetSeconds: offset)
        }
        if let subsec = exif[kCGImagePropertyExifSubsecTimeOriginal] as? String {
            out.captureSubsec = Int(subsec)
        }

        // GPS is stored as a magnitude plus a hemisphere letter, so a photo taken in
        // Chile or Ireland comes back on the wrong side of the equator or the meridian
        // if the reference is ignored.
        if let latitude = gps[kCGImagePropertyGPSLatitude] as? Double {
            let south = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S"
            out.gpsLatitude = south ? -latitude : latitude
        }
        if let longitude = gps[kCGImagePropertyGPSLongitude] as? Double {
            let west = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W"
            out.gpsLongitude = west ? -longitude : longitude
        }

        return out
    }

    /// Make and model joined the way a catalog shows a body, without the stutter.
    static func joinCamera(make: String?, model: String?) -> String? {
        guard let model, !model.isEmpty else { return make?.isEmpty == false ? make : nil }
        guard let make, !make.isEmpty else { return model }
        // "NIKON CORPORATION" / "NIKON Z 8" -> "NIKON Z 8", by first word rather than by
        // whole string: no maker writes the same string in both fields.
        let firstWord = make.split(separator: " ").first.map(String.init) ?? make
        if model.lowercased().hasPrefix(firstWord.lowercased()) { return model }
        return "\(make) \(model)"
    }
}

#endif
