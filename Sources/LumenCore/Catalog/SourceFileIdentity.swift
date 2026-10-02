import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A cheap filesystem generation, not a content digest. Inode detects atomic
/// replacement; nanosecond mtime AND ctime detect rapid, same-size in-place writes,
/// including writes that restore mtime. Metadata-only changes may harmlessly miss a
/// cache. Filesystems that do not expose a changed stat tuple cannot be certified by
/// this token; content verification remains a separate concern.
///
/// `st_dev` is deliberately NOT part of it. On macOS the device number of an external
/// volume depends on mount order, so re-plugging a photo drive changed every token on
/// it, and the catalog scan read that as "every original was replaced" and wiped the
/// folder's quick signatures, EXIF and previews. A replacement is always on the same
/// volume as the path it replaces, so the device number never told anything apart.
///
/// A differing token is a SUSPICION, not a verdict: `CatalogStore.scan` confirms it
/// against the stored quick signature before invalidating anything.
public struct SourceFileIdentity: Hashable, Sendable {
    public let token: String

    /// The fields a token carries: inode, size, mtime (s, ns), ctime (s, ns).
    static let fieldCount = 6

    public static func read(_ url: URL) -> SourceFileIdentity? {
        #if canImport(Darwin) || canImport(Glibc)
        var info = stat()
        let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return stat(path, &info)
        }
        guard status == 0 else { return nil }
        #if canImport(Darwin)
        let modified = info.st_mtimespec
        let changed = info.st_ctimespec
        #else
        let modified = info.st_mtim
        let changed = info.st_ctim
        #endif
        return SourceFileIdentity(token: "\(info.st_ino):\(info.st_size):"
            + "\(modified.tv_sec):\(modified.tv_nsec):\(changed.tv_sec):\(changed.tv_nsec)")
        #else
        return nil
        #endif
    }

    /// Whether a stored token and a current one name the same file generation.
    /// Tokens written before the device number was dropped carry it as a leading
    /// field; it is ignored, so those rows are not read as changed on upgrade.
    public static func sameGeneration(stored: String, current: String) -> Bool {
        decisive(stored) == decisive(current)
    }

    private static func decisive(_ token: String) -> ArraySlice<Substring> {
        let fields = token.split(separator: ":", omittingEmptySubsequences: false)
        return fields.suffix(fieldCount)
    }

    /// A filename-safe discriminator. This hashes the stat tuple, not photo bytes.
    public var cacheKey: String { XXH64.hexDigest(Array(token.utf8)) }
}
