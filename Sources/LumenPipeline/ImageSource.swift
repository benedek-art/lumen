// ImageSource.swift
// The seam between "a file on disk" and "scene-linear pixels the graph can eat".
//
// This existed only as `AppleRawSource`, and `RenderCoordinator` constructed that type
// by name, so the develop pipeline could open a camera RAW and nothing else. A JPEG,
// HEIC or TIFF browsed and thumbnailed fine — the grid reads embedded previews and
// never decodes — and then the loupe threw `.undecodable` and showed the embedded
// preview labelled "no RAW decoder for this file", with every slider in the develop
// column moving values that reached no pixels. Opening an exported frame, a phone
// photo, or a scan was not a degraded path; it was not a path.
//
// Two conformers, one contract: both hand back a CIImage in the working space with
// mid-grey at 0.18, and both answer the same questions about the file behind it.

#if os(macOS)

import CoreGraphics
import CoreImage
import Foundation
import LumenCore

/// What the renderer needs from a file, whatever kind of file it is.
///
/// `scaleFactor` is not optional here: Swift protocols cannot carry default argument
/// values, and adding a defaulted overload in an extension alongside a conformer whose
/// method already defaults the same parameter is how you get two different functions
/// that look identical at the call site.
public protocol ImageSource: AnyObject {
    var url: URL { get }
    var nativeLongEdge: Double { get }
    var nativePixelSize: (width: Int, height: Int) { get }

    /// The neutral the white balance stage adapts *from*. A camera file reports what
    /// the body recorded; a rendered file has no such thing and answers with a fixed
    /// reference, which makes its Temp/Tint sliders relative rather than absolute.
    var asShotTemperature: Double { get }
    var asShotTint: Double { get }

    var captureMetadata: CaptureMetadata { get }

    func decode(recipe: Recipe, draft: Bool, scaleFactor: Double) -> CIImage?
}

/// Already-rendered files: JPEG, HEIC/HEIF, PNG, TIFF.
///
/// Colour handling is deliberately Core Image's. The file carries a profile, the
/// context works in linear Rec.2020, and CI converts on the way in — which lands
/// mid-grey exactly where the pipeline expects it, because sRGB's ~0.466 code value
/// decodes to 0.18 linear by construction. No hand-rolled inverse EOTF is needed and
/// none is written here.
///
/// What this path cannot recover is headroom and the curve already baked in. A camera
/// RAW arrives scene-referred and unbounded; a JPEG is clipped at display white and has
/// a tone curve applied once already, so Lumen's display transform is a *second* one.
/// The honest setting for such a file is the Linear render preset, which exists for
/// exactly this reason (docs/04's escape hatch). This TYPE does not pick it — a source
/// that rewrote a recipe would be reaching well outside its job — but `AppState
/// .startingRecipe(for:)` does, for any file `PhotoFormats.isRendered` recognises, so an
/// unedited JPEG opens on Linear rather than on a second S-curve. A starting point, not
/// a lock: the picker still offers the other four and a saved recipe wins.
public final class RenderedImageSource: ImageSource {

    public let url: URL
    private let image: CIImage

    /// A rendered file records no camera neutral, so the stage needs a reference to
    /// adapt from. D65-ish daylight at zero tint means an untouched recipe — `temp` and
    /// `tint` nil, "as shot" — adapts 5500 K to 5500 K and changes nothing, while
    /// moving a slider warms or cools the file *relative* to how it was delivered.
    /// That is docs/04's stated fallback for non-raw input.
    public let asShotTemperature: Double = 5500
    public let asShotTint: Double = 0

    public init(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RawSourceError.unreadable(url)
        }
        // Orientation applied on load: EXIF-rotated phone photos otherwise decode
        // sideways while their embedded thumbnail — which the grid already showed
        // upright — does not, so the loupe would disagree with the cell it came from.
        guard let loaded = CIImage(contentsOf: url,
                                   options: [.applyOrientationProperty: true]) else {
            throw RawSourceError.undecodable(url)
        }
        self.url = url
        self.image = loaded
    }

    public var nativePixelSize: (width: Int, height: Int) {
        (width: Int(image.extent.width.rounded()),
         height: Int(image.extent.height.rounded()))
    }

    public var nativeLongEdge: Double {
        Double(Swift.max(image.extent.width, image.extent.height))
    }

    public func decode(recipe: Recipe, draft: Bool, scaleFactor: Double = 1.0) -> CIImage? {
        // `draft` is the RAW decoder's cheap-demosaic switch and has no analogue here:
        // the pixels are already demosaiced. Scale is the only lever, and it is the one
        // that actually pays — the graph's cost is per-pixel.
        let scale = Num.clamp(scaleFactor, 0.01, 1.0)
        guard scale < 1.0 else { return image }
        return image.transformed(by: CGAffineTransform(scaleX: CGFloat(scale),
                                                       y: CGFloat(scale)))
    }

    public var captureMetadata: CaptureMetadata {
        CaptureMetadata(asShotTemperature: asShotTemperature,
                        asShotTint: asShotTint,
                        decoderVersion: nil,
                        pixelSize: nativePixelSize)
    }
}

#endif
