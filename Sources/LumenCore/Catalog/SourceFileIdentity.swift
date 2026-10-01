import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A cheap filesystem generation, not a content digest. Device/inode detects atomic
/// replacement; nanosecond mtime AND ctime detect rapid, same-size in-place writes,
/// including writes that restore mtime. Metadata-only changes may harmlessly miss a
/// cache. Filesystems that do not expose a changed stat tuple cannot be certified by
/// this token; content verification remains a separate concern.
public struct SourceFileIdentity: Hashable, Sendable {
    public let token: String

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
        return SourceFileIdentity(token: "\(info.st_dev):\(info.st_ino):\(info.st_size):"
            + "\(modified.tv_sec):\(modified.tv_nsec):\(changed.tv_sec):\(changed.tv_nsec)")
        #else
        return nil
        #endif
    }

    /// A filename-safe discriminator. This hashes the stat tuple, not photo bytes.
    public var cacheKey: String { XXH64.hexDigest(Array(token.utf8)) }
}
