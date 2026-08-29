// PhotoFormats.swift
// What Lumen will browse, as a table of file extensions.
//
// Moved here from `LumenApp/AppState.swift` unchanged. It is a fact about files, not
// about the UI: the folder scan reads it, the ingest planner counts with it, and
// `LibraryFilter`'s RAW-only chip compiles to `PhotoQuery.fileTypes` from it. That last
// caller is the reason it had to leave LumenApp — the filter grammar is tested on
// Linux, and everything the grammar reaches has to build there too.

import Foundation

public enum PhotoFormats {
    /// Everything CIRAWFilter will decode. The short list this started as made a
    /// Hasselblad, Phase One, Leica or Minolta file invisible in the grid and uncounted
    /// by the ingest planner — not an error the user could act on, just an empty folder
    /// where their shoot was.
    public static let raw: Set<String> = [
        "arw", "sr2", "srf", "arq",              // Sony
        "cr2", "cr3", "crw",                     // Canon
        "nef", "nrw",                            // Nikon
        "orf",                                   // Olympus / OM
        "pef", "dng",                            // Pentax, and the open format
        "raf",                                   // Fujifilm
        "rw2",                                   // Panasonic
        "rwl",                                   // Leica
        "srw",                                   // Samsung
        "erf",                                   // Epson
        "x3f",                                   // Sigma
        "3fr", "fff",                            // Hasselblad
        "iiq", "cap",                            // Phase One
        "mrw",                                   // Minolta
        "dcr", "kdc",                            // Kodak
        "mef",                                   // Mamiya
        "raw",                                   // generic
    ]
    public static let rendered: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff",
    ]
    public static let browsable: Set<String> = raw.union(rendered)

    public static func isRaw(_ url: URL) -> Bool {
        raw.contains(url.pathExtension.lowercased())
    }

    /// Already-rendered files, which decode through `RenderedImageSource` rather than
    /// the RAW stage. A sibling of `isRaw` so callers do not each write the
    /// lowercase-the-extension dance and drift apart on the one that forgets.
    public static func isRendered(_ url: URL) -> Bool {
        rendered.contains(url.pathExtension.lowercased())
    }
}
