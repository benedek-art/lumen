// SidecarNaming.swift
// Which file a photograph's sidecar is — and when two photographs must not share one.
//
// The Adobe convention for a RAW is `NAME.xmp`, extension dropped, and every tool in the
// category reads it. It is right up to the moment a folder holds two RAWs with one
// basename, which is the ordinary state of a folder after Adobe DNG Converter, after a
// Lightroom "Convert to DNG" that keeps the original, and after a dual-format card
// import: `DSC_0001.NEF` beside `DSC_0001.DNG`. Both then address `DSC_0001.xmp`.
//
// Three losses follow and they compound. The later flush overwrites the earlier one's
// recipe. On the next open both rows read the same file with the same mtime; for the
// frame whose recorded mtime no longer matches, the merge decides `.sidecarWins` and
// writes the OTHER frame's recipe into this frame's catalog row — so the edit is gone
// from both copies, and undo cannot reach it because the catalog now agrees. And a brush
// painting made on one is claimed by the other's mask references.
//
// The rule is in LumenCore, pure, taking the neighbourhood as a value, for the reason
// every rule in `XMP/` is: `CatalogService` is `#if os(macOS)` and cannot be tested on
// the lane that runs on every push, and this is a rule about which file gets somebody's
// work.

import Foundation

public enum SidecarNaming {

    /// The sidecar for `photo`.
    ///
    /// - Parameters:
    ///   - isRaw: whether the photograph is a RAW — decided by the caller, because the
    ///     format table lives with the decoder.
    ///   - rawSiblingExtensions: the lowercased extensions of every OTHER RAW file in
    ///     the same directory sharing this photograph's basename (case-insensitively).
    ///     Empty for the ordinary folder.
    ///
    /// Non-RAW files get `NAME.EXT.xmp`, which is also Adobe's convention and is what
    /// keeps a RAW+JPEG pair apart. A RAW alone gets `NAME.xmp`.
    ///
    /// A RAW IN A COLLISION gets `NAME.EXT.xmp` — except for one frame, chosen by a rule
    /// that never has to guess. Adobe never writes a sidecar for a DNG (a DNG carries its
    /// metadata inside itself), so a bare `NAME.xmp` sitting beside a `NAME.DNG` is, by
    /// the convention every tool follows, the OTHER file's. If exactly one non-DNG RAW is
    /// in the collision, the bare name is its, and Lightroom's rating on it keeps being
    /// read. Two non-DNG RAWs with one basename (a NEF and a CR3, after a rename) have
    /// no such convention to lean on, so both are qualified and the bare file, if any,
    /// is left to whoever wrote it — it is somebody else's document.
    ///
    /// Deterministic in the inputs, so the same frame gets the same file on every
    /// launch, and nothing here ever renames or deletes a sidecar.
    public static func url(for photo: URL, isRaw: Bool,
                           rawSiblingExtensions: Set<String>) -> URL {
        guard isRaw else { return photo.appendingPathExtension("xmp") }
        let bare = photo.deletingPathExtension().appendingPathExtension("xmp")
        guard !rawSiblingExtensions.isEmpty else { return bare }

        let own = photo.pathExtension.lowercased()
        let nonDNG = rawSiblingExtensions.union([own]).filter { $0 != "dng" }
        if nonDNG.count == 1, own != "dng" { return bare }
        return photo.appendingPathExtension("xmp")
    }

    /// The sidecar for a photograph, given what is already on disk. Ownership decides.
    ///
    /// - Parameters:
    ///   - bare: the parsed `NAME.xmp`, nil when absent or unreadable.
    ///   - qualified: the parsed `NAME.EXT.xmp`, nil when absent or unreadable.
    ///
    /// The order matters, and the first rule is the one that was missing. darktable
    /// writes `NAME.EXT.xmp` beside every RAW it opens. A lone NEF whose Lumen edits
    /// live in `NAME.xmp` (owner `nef`) used to switch to darktable's file the moment
    /// it appeared, because "a qualified file exists" was tested before ownership.
    /// From then on Lumen read and spliced into darktable's document, and the portable
    /// copy of its own edits was orphaned. So:
    ///
    /// 1. A bare file Lumen wrote for THIS extension is this photo's. Nothing displaces it.
    /// 2. A qualified file Lumen wrote for this photo is honoured: once a frame has moved
    ///    to its qualified file, removing its neighbour does not move it back. A qualified
    ///    file with no owner tag but Lumen content is an older Lumen write; its name
    ///    already carries the extension.
    /// 3. A bare file owned by another extension is somebody else's: qualified.
    /// 4. Otherwise the September (K-015) rules, unchanged: an unowned Lumen document in a
    ///    collision cannot be assigned by Adobe's convention, and the rest is
    ///    `url(for:isRaw:rawSiblingExtensions:)`. A foreign qualified file (darktable's)
    ///    plays no part.
    public static func resolve(photo: URL, isRaw: Bool,
                               bare: SidecarContent?, qualified: SidecarContent?,
                               rawSiblingExtensions: Set<String>) -> URL {
        let qualifiedURL = photo.appendingPathExtension("xmp")
        guard isRaw else { return qualifiedURL }
        let own = photo.pathExtension.lowercased()
        let bareURL = photo.deletingPathExtension().appendingPathExtension("xmp")
        if bare?.sourceExtension?.lowercased() == own { return bareURL }
        if let qualified, isLumenDocument(qualified, ownedBy: own) { return qualifiedURL }
        if bare?.sourceExtension != nil { return qualifiedURL }
        if !rawSiblingExtensions.isEmpty, let bare,
           bare.recipeJSON != nil || bare.writeStamp != nil { return qualifiedURL }
        return url(for: photo, isRaw: true, rawSiblingExtensions: rawSiblingExtensions)
    }

    private static func isLumenDocument(_ content: SidecarContent, ownedBy own: String) -> Bool {
        if let owner = content.sourceExtension { return owner.lowercased() == own }
        return content.recipeJSON != nil || content.writeStamp != nil
    }

    /// The sibling set for `photo`, from a directory listing.
    ///
    /// Separated from `url(for:…)` so the pure rule can be tested against a hand-built
    /// set and the listing can be memoized by the caller: this is one pass over the
    /// names, and a ten-thousand-frame folder should pay it once, not per sidecar.
    public static func rawSiblingExtensions(of photo: URL, amongNames names: [String],
                                            isRawName: (String) -> Bool) -> Set<String> {
        let stem = photo.deletingPathExtension().lastPathComponent.lowercased()
        let own = photo.lastPathComponent.lowercased()
        var out: Set<String> = []
        for name in names {
            let lower = name.lowercased()
            guard lower != own, isRawName(name) else { continue }
            let url = URL(fileURLWithPath: name)
            guard url.deletingPathExtension().lastPathComponent.lowercased() == stem
            else { continue }
            out.insert(url.pathExtension.lowercased())
        }
        return out
    }
}
