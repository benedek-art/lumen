// PreviewCache.swift
// The rules of the disk preview cache: which stored rung answers a request, when a
// stored preview stopped describing the photograph, where its payload lives, and how
// big the cache is allowed to get.
//
// Why these rules are HERE and not next to the ImageIO calls that use them. The disk
// cache is README goal #1 — "next photo in under 50 ms from a pre-decoded cache" — and
// it has sat unwired since the schema was written: `recordPreview`, `preview`,
// `touchPreview`, `invalidatePreviews` and `pruneCache` all existed, all worked, and
// had zero callers outside this file's tests. The audit's explanation for why it stayed
// unwired that long is the one that matters: the only place with a `CGImageSource` in
// scope is `LumenApp`, `LumenApp` has no test target and cannot even be compiled on the
// machine this is developed on, so any policy written there is policy nobody can prove.
//
// So the split is: decoding pixels and touching the filesystem are the app's, and every
// DECISION is here. What follows is arithmetic and enum matching over rows — no
// ImageIO, no AppKit, no disk — and it runs on Linux under `swift test`.
//
// Scope, stated so a reader does not assume more: this is the PREVIEW cache. The
// `artifact` table (mask rasters, denoise atlases, embeddings — docs/15 §15.7) has the
// same shape and the same problem and is not touched here.

import Foundation

/// The disk preview cache's policy. Bookkeeping rows live in `cache.preview`
/// (`CatalogStore`); payloads live under `previews/xx/` in the cache directory.
public enum PreviewCache {

    /// Where payloads sit, relative to the cache directory (docs/15 §15.2).
    public static let directoryName = "previews"

    // MARK: - Freshness

    /// What a stored row is still good for, given the photo's current `recipe_fp`.
    ///
    /// Three states rather than a boolean, because docs/15 §15.6 says two different
    /// things about two halves of the ladder and both are deliberate:
    ///
    /// · an edit makes the stored **fit** stale — the develop loop must never be shown
    ///   a cached picture of a recipe the user has since changed;
    /// · an edit does **not** make the stored **thumb/grid** stale — "the preview cache
    ///   serves browsing, not the develop loop", and swapping the picture under a cull
    ///   pass is the "Lightroom changed my photos" complaint docs/10 §10.1 exists to
    ///   defuse. The browse rungs keep serving and a background render replaces them
    ///   later, on the schedule that doc specifies.
    ///
    /// A third case sits under `.browsable` and is easy to miss: an EMBEDDED row at any
    /// rung. It is the camera's rendering, it is badged as such, and it never claimed to
    /// depict a recipe — see `freshness` for why calling it stale would cost the exact
    /// decode this cache exists to avoid.
    ///
    /// `invalidatePreviews(photoID:keeping:)` deletes a superset of what this enum calls
    /// `.stale` — see `isBrowseRung` for the one row where the two differ and why that
    /// costs a decode rather than a wrong picture.
    public enum Freshness: String, Sendable, Equatable {
        /// Fingerprints match: good for anything.
        case current
        /// Fingerprints differ, but this is a browse rung and browsing does not block
        /// on the develop loop. Servable; a candidate for background re-render.
        case browsable
        /// Fingerprints differ on a rung that claims to show the current render.
        /// Never served, and its payload should be unlinked.
        case stale
    }

    /// Whether `level` is one of the browse rungs — the ones an edit does not
    /// invalidate. Matches `invalidatePreviews`' `level >= 2` predicate from the other
    /// side, so a change to one is a visible disagreement with the other.
    ///
    /// One asymmetry, deliberate and worth naming: `freshness` also keeps serving an
    /// EMBEDDED fit row after an edit, and `invalidatePreviews` deletes it. The cost of
    /// that disagreement is one re-extraction of an embedded JPEG after each edit, and
    /// the alternative — teaching the SQL to spare embedded rows — changes the meaning
    /// of a function this change has no business redefining. Nothing wrong is ever
    /// shown: the row is gone, so the loupe decodes.
    public static func isBrowseRung(_ level: PreviewLevel) -> Bool {
        level.rawValue < PreviewLevel.fit.rawValue
    }

    public static func freshness(of row: PreviewRow,
                                 against fingerprint: String) -> Freshness {
        if row.recipeFP == fingerprint { return .current }
        if isBrowseRung(row.level) { return .browsable }
        // An embedded row is the CAMERA's rendering of the file as shot. It never
        // claimed to depict a recipe, it is badged as what it is (docs/10 §10.1's
        // honesty badge), and it is the first step of the documented progression
        // embedded → draft → full that the loupe walks on every photo. Calling it stale
        // because the user has since edited would mean re-extracting a full-size
        // embedded JPEG on every single loupe entry after the first edit — which is the
        // decode this cache exists to stop paying, at the one rung where the 50 ms goal
        // is actually measured.
        if row.source == .embedded { return .browsable }
        return .stale
    }

    // MARK: - Which stored rung answers a request

    /// What the loader should do about one request.
    public enum Decision: Equatable, Sendable {
        /// Read this row's payload instead of decoding the original. The row carries
        /// the path and the LRU key to stamp.
        case serve(PreviewRow)
        /// Nothing on disk answers this; decode the original and record the result.
        case decode
    }

    /// The row that answers a request for `level`, or `.decode`.
    ///
    /// Three rules, each with a way to be wrong worth naming:
    ///
    /// **Never upward.** A rung smaller than the one asked for is not an answer. Serving
    /// a 256 payload to a 1024 request produces a contact sheet that is four times
    /// softer than the code believes it is, and nothing downstream can tell — the image
    /// arrives, the cell fills in, the cache reports a hit.
    ///
    /// **The smallest servable rung.** A stored `fit` really can answer a `grid`
    /// request: the reader passes `kCGImageSourceThumbnailMaxPixelSize`, so the
    /// downsample is free. But it is the LAST resort, not the first — the exact rung is
    /// by definition the smallest servable one, and preferring it is not only about
    /// decode cost. After an edit the stored `grid` is `.browsable` (the as-shot render
    /// the cull is being done against) while a stored `fit` may be `.current` (the new
    /// render); taking the smallest is what keeps the contact sheet from jumping to the
    /// new rendering in the middle of a cull pass.
    ///
    /// **At the same rung, the current recipe's render before the camera's.** Two rows
    /// can sit at one rung — that is what cache migration 2 rebuilt the table for, so
    /// the embedded and the Lumen render can coexist during the handoff docs/10 §10.1
    /// describes. Once Lumen's render of the CURRENT recipe exists, it is the one to
    /// show; leaving the tie to whatever order SQLite returned would make the handoff
    /// happen or not happen at random.
    public static func decide(request level: PreviewLevel, fingerprint: String,
                              stored: [PreviewRow]) -> Decision {
        guard let wanted = ThumbnailLadder.pixels(for: level) else { return .decode }
        var best: (row: PreviewRow, pixels: Int, rank: Int)?
        for row in stored {
            guard let pixels = ThumbnailLadder.pixels(for: row.level),
                  pixels >= wanted else { continue }
            let state = freshness(of: row, against: fingerprint)
            guard state != .stale else { continue }
            let rank = state == .current ? 0 : 1
            if let chosen = best {
                if pixels > chosen.pixels { continue }
                if pixels == chosen.pixels, rank >= chosen.rank { continue }
            }
            best = (row, pixels, rank)
        }
        guard let best else { return .decode }
        return .serve(best.row)
    }

    /// The pixel size to ask the payload reader for, given the request and the row that
    /// answered it. A `fit` payload answering a `grid` request is read at 1024, not at
    /// 2560: the caller wanted a grid cell and the cache should not hand the memory LRU
    /// an entry six times the size it budgeted for.
    public static func readPixels(request level: PreviewLevel,
                                  served row: PreviewRow) -> Int? {
        guard let wanted = ThumbnailLadder.pixels(for: level),
              let have = ThumbnailLadder.pixels(for: row.level) else { return nil }
        return Swift.min(wanted, have)
    }

    // MARK: - What a finished decode writes

    /// The `recipe_fp` a finished decode is filed under.
    ///
    /// An embedded extraction is filed as as-shot (`""`) whatever the photo's current
    /// fingerprint is, because that is what the pixels ARE: the camera's rendering of
    /// the file, with none of the user's edits in it. Filing it under the current
    /// fingerprint would have the cache assert that the edit had been rendered, and
    /// `decide` would then hand it to the loupe as `.current` — the user would be
    /// grading against a picture that does not contain their own last twenty moves.
    ///
    /// Only a Lumen render earns the recipe's fingerprint. Nothing in the app produces
    /// one yet; the background render queue docs/10 §10.1 describes is not built.
    public static func recordingFingerprint(source: PreviewSource,
                                            current: String) -> String {
        source == .embedded ? "" : current
    }

    /// The row a finished decode should record, or nil when this decode does not belong
    /// on disk.
    ///
    /// What a rung promises, stated so nobody reads more into it: the rung is the size
    /// that was ASKED FOR, not a guarantee about the payload. Many Sony bodies embed a
    /// preview of about 1616×1080, so a `fit` request against one produces a `fit` row
    /// whose file is 1616 pixels on its long edge. That is not a lie and cannot mislead
    /// a reader, because the payload is by construction exactly what decoding the
    /// ORIGINAL at that request size would have produced — serving it back is never
    /// softer than the miss it replaced. The `never upward` rule in `decide` is about
    /// rungs, and it still holds; this note is about the gap between a rung and the
    /// pixels a particular camera put in the file.
    ///
    /// Nil for `oneToOne`, because that rung is unbuilt (see `ThumbnailLadder.pixels`),
    /// and nil for a size that is not a rung at all — a caller that invented its own
    /// number gets no row rather than a row whose payload is not the size the key says.
    ///
    /// `currentFingerprint` is the photo's, not the row's: what the row gets filed under
    /// is `recordingFingerprint`'s answer, so there is no way for a caller to file a
    /// camera render under a recipe by passing the wrong string.
    public static func rowForDecode(photoID: Int64, pixels: Int,
                                    currentFingerprint: String,
                                    source: PreviewSource, path: String,
                                    bytes: Int64) -> PreviewRow? {
        guard let level = ThumbnailLadder.level(for: pixels) else { return nil }
        return PreviewRow(photoID: photoID, level: level,
                          recipeFP: recordingFingerprint(source: source,
                                                         current: currentFingerprint),
                          source: source, path: path, bytes: bytes)
    }

    // MARK: - Where the payload lives

    /// The payload's path relative to the cache directory: `previews/xx/<name>.<ext>`,
    /// sharded by hash prefix (docs/15 §15.2).
    ///
    /// Sharded because a flat directory of a quarter of a million files is a directory
    /// nothing enumerates quickly, and hashed rather than taken from the photo id so the
    /// 256 shards fill evenly whatever order ids were handed out in.
    ///
    /// Every component of the cache key is in the name as well as in the hash, so a
    /// human looking at the directory can tell what a file is, and so two keys that
    /// collide in the shard still cannot collide in the filename.
    public static func payloadPath(photoID: Int64, level: PreviewLevel,
                                   recipeFP: String, ext: String) -> String {
        let key = payloadKey(photoID: photoID, level: level, recipeFP: recipeFP)
        let digest = XXH64.hexDigest(key)
        let shard = String(digest.prefix(2))
        let name = "\(photoID)-\(level.rawValue)-\(digest)"
        return "\(directoryName)/\(shard)/\(name).\(ext)"
    }

    /// The string the shard hashes. Separated out so a test can assert that the three
    /// key components all reach the hash: a path that ignored `recipe_fp` would let one
    /// file be two rows, and the second `recordPreview` would silently overwrite the
    /// first photo's pixels.
    public static func payloadKey(photoID: Int64, level: PreviewLevel,
                                  recipeFP: String) -> String {
        "\(photoID)|\(level.rawValue)|\(recipeFP)"
    }

    /// The shard directory a payload path sits in, so the writer can create it.
    public static func shardDirectory(for path: String) -> String? {
        let parts = path.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return parts.dropLast().joined(separator: "/")
    }

    // MARK: - Back pressure on the encode queue

    /// The ceiling on pixels waiting to be encoded.
    ///
    /// The decode pool is eight wide and the encode that follows it is one queue. If the
    /// encode falls behind — and at the `fit` rung it will, because one image there is
    /// about 26 MB of bitmap — every waiting write holds its decoded image alive. An
    /// unbounded queue is not a slow cache, it is an out-of-memory crash during the one
    /// operation this whole feature exists to make fast: the first pass over a card.
    ///
    /// 128 MB is a quarter of the memory LRU's own budget, so the two together stay
    /// inside an appetite this app already has.
    public static let pendingWriteBudgetBytes = 128 * 1024 * 1024

    /// Whether one more decoded image may join the encode queue.
    ///
    /// Refusing costs exactly one preview not filed — which is what every preview did
    /// before this cache existed — and it is recovered the next time that photo is
    /// decoded. An empty queue always admits, whatever the image weighs: a single frame
    /// bigger than the whole budget must still be cacheable, or a large-sensor body
    /// would silently never cache anything.
    public static func admitsWrite(pendingBytes: Int, imageBytes: Int,
                                   budget: Int = pendingWriteBudgetBytes) -> Bool {
        if pendingBytes <= 0 { return true }
        return pendingBytes + imageBytes <= budget
    }

    // MARK: - Budget

    public static let minimumBudgetBytes: Int64 = 10 * 1_000_000_000
    public static let maximumBudgetBytes: Int64 = 100 * 1_000_000_000

    /// The disk budget: 20% of free space, clamped to 10–100 GB (docs/15 §15.6).
    ///
    /// With one correction the doc does not make. Its clamp has a FLOOR of 10 GB, and a
    /// floor is fine as a floor on the budget but not as a licence to exceed the disk:
    /// on a volume with 6 GB free, "20% clamped up to 10 GB" is a cache authorized to
    /// fill a photographer's boot drive and then keep going. So the clamp is applied and
    /// then capped at what is actually free. The cap only binds below ~12.5 GB free;
    /// above that the doc's rule is what runs, unmodified.
    ///
    /// docs/10 §10.10 states a different pair of numbers for the same cache — a
    /// user-facing 5–100 GB knob defaulting to 20 GB. That is a Settings control which
    /// does not exist; this is the automatic default, which is what §15.6 describes.
    /// The two documents disagree and this comment is the record of it.
    public static func budgetBytes(freeBytes: Int64) -> Int64 {
        guard freeBytes > 0 else { return 0 }
        let share = freeBytes / 5
        let clamped = Swift.min(Swift.max(share, minimumBudgetBytes), maximumBudgetBytes)
        return Swift.min(clamped, freeBytes)
    }
}
