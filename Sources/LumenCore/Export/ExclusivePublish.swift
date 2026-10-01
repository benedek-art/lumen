// ExclusivePublish.swift
// Putting a finished export under its final name without ever replacing a file there.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Why a finished export could not be put under its name. Distinct cases because the
/// photographer's next move differs: a taken name is a re-export, a volume that cannot
/// promise "no overwrite" is a different destination, anything else is a disk problem.
public enum ExportPublishError: Error, Equatable, LocalizedError, Sendable {
    /// A file appeared under the destination name while the export was encoding (another
    /// app, another export, a sync client). Nothing was replaced.
    case destinationExists
    /// The volume supports none of the ways to publish without overwriting (exclusive
    /// rename, hard link, exclusive create). Nothing was replaced.
    case unsupportedVolume(errno: Int32)
    /// Any other failure, with the system's errno.
    case failed(errno: Int32)

    public var errorDescription: String? { reason }

    /// Short enough for the export status line.
    public var reason: String {
        switch self {
        case .destinationExists:
            return "a file with that name appeared while exporting; it was left untouched"
        case .unsupportedVolume(let code):
            return "this volume cannot write without risking an overwrite ("
                + ExportPublishError.name(code) + ")"
        case .failed(let code):
            return "the file could not be written (" + ExportPublishError.name(code) + ")"
        }
    }

    static func name(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}

// The C calls by module, because `Syscalls` has members with the same names.
#if canImport(Darwin)
private func sysLink(_ a: UnsafePointer<CChar>, _ b: UnsafePointer<CChar>) -> Int32 { Darwin.link(a, b) }
private func sysRename(_ a: UnsafePointer<CChar>, _ b: UnsafePointer<CChar>) -> Int32 { Darwin.rename(a, b) }
private func sysUnlink(_ a: UnsafePointer<CChar>) -> Int32 { Darwin.unlink(a) }
private func sysClose(_ fd: Int32) { _ = Darwin.close(fd) }
#else
private func sysLink(_ a: UnsafePointer<CChar>, _ b: UnsafePointer<CChar>) -> Int32 { Glibc.link(a, b) }
private func sysRename(_ a: UnsafePointer<CChar>, _ b: UnsafePointer<CChar>) -> Int32 { Glibc.rename(a, b) }
private func sysUnlink(_ a: UnsafePointer<CChar>) -> Int32 { Glibc.unlink(a) }
private func sysClose(_ fd: Int32) { _ = Glibc.close(fd) }
#endif

/// THE NO-OVERWRITE GUARANTEE, ON EVERY VOLUME THAT CAN KEEP IT.
///
/// `PipelineRenderer.write` encodes to a hidden sibling and publishes it with
/// `renamex_np(…, RENAME_EXCL)`: the existence check and the rename are one syscall, so
/// a file created under the name during the encode is never replaced (REL-04). But
/// RENAME_EXCL is only guaranteed on volumes that advertise `VOL_CAP_INT_RENAME_EXCL`
/// (APFS, HFS+). exFAT and FAT cards, SMB and NFS shares may answer ENOTSUP or EINVAL,
/// and every export to them failed — where they used to work (V6 note 1).
///
/// So on exactly those two answers, and only those, publication falls back to other
/// operations that are also atomic about the name:
///   1. `link(partial, destination)` — fails with EEXIST if the name exists; on success
///      the partial is unlinked. Hard links exist on NFS and many SMB servers.
///   2. Where links are not supported either (FAT, exFAT), claim the name with
///      `open(destination, O_CREAT | O_EXCL)` — again EEXIST if it exists — and then
///      rename the partial over the empty file THIS call just created. If that rename
///      fails, the claim is removed.
/// Every other errno is a failure, kept and reported, never retried.
public enum ExclusivePublish {

    /// The filesystem calls, injectable so the fallback can be driven on any machine.
    /// Each returns 0 on success or the errno it failed with.
    public struct Syscalls: Sendable {
        public var renameExclusive: @Sendable (URL, URL) -> Int32
        public var link: @Sendable (URL, URL) -> Int32
        public var createExclusive: @Sendable (URL) -> Int32
        public var rename: @Sendable (URL, URL) -> Int32
        public var unlink: @Sendable (URL) -> Int32

        public init(renameExclusive: @escaping @Sendable (URL, URL) -> Int32,
                    link: @escaping @Sendable (URL, URL) -> Int32 = Syscalls.posixLink,
                    createExclusive: @escaping @Sendable (URL) -> Int32 = Syscalls.posixCreateExclusive,
                    rename: @escaping @Sendable (URL, URL) -> Int32 = Syscalls.posixRename,
                    unlink: @escaping @Sendable (URL) -> Int32 = Syscalls.posixUnlink) {
            self.renameExclusive = renameExclusive
            self.link = link
            self.createExclusive = createExclusive
            self.rename = rename
            self.unlink = unlink
        }

        public static let posixLink: @Sendable (URL, URL) -> Int32 = { from, to in
            from.withUnsafeFileSystemRepresentation { f in
                to.withUnsafeFileSystemRepresentation { t in
                    sysLink(f!, t!) == 0 ? 0 : errno
                }
            }
        }

        public static let posixCreateExclusive: @Sendable (URL) -> Int32 = { url in
            url.withUnsafeFileSystemRepresentation { path in
                let fd = open(path!, O_CREAT | O_EXCL | O_WRONLY, 0o644)
                guard fd >= 0 else { return errno }
                sysClose(fd)
                return 0
            }
        }

        public static let posixRename: @Sendable (URL, URL) -> Int32 = { from, to in
            from.withUnsafeFileSystemRepresentation { f in
                to.withUnsafeFileSystemRepresentation { t in
                    sysRename(f!, t!) == 0 ? 0 : errno
                }
            }
        }

        public static let posixUnlink: @Sendable (URL) -> Int32 = { url in
            url.withUnsafeFileSystemRepresentation { path in
                sysUnlink(path!) == 0 ? 0 : errno
            }
        }
    }

    /// The answers on which an exclusive rename is retried another way: the call itself
    /// is not supported here, as opposed to "the name is taken" or a disk failure.
    static let unsupported = Set<Int32>([ENOTSUP, EOPNOTSUPP, EINVAL])
    /// The answers on which a hard link is not available and the name is claimed by an
    /// exclusive create instead.
    // Built from arrays, not literals: ENOTSUP and EOPNOTSUPP are the same number on
    // Linux, and a Set LITERAL with a duplicate traps at runtime.
    static let noLinks = Set<Int32>([ENOTSUP, EOPNOTSUPP, EINVAL, EPERM, EXDEV, EMLINK, ENOSYS])

    /// Publishes `partial` as `destination`. Without `allowOverwrite` an existing file at
    /// `destination` is never replaced. The caller removes `partial` on a throw.
    public static func publish(_ partial: URL, as destination: URL,
                               allowOverwrite: Bool, using calls: Syscalls) throws {
        if allowOverwrite {
            let code = calls.rename(partial, destination)
            if code != 0 { throw ExportPublishError.failed(errno: code) }
            return
        }
        let exclusive = calls.renameExclusive(partial, destination)
        if exclusive == 0 { return }
        if exclusive == EEXIST { throw ExportPublishError.destinationExists }
        guard unsupported.contains(exclusive) else {
            throw ExportPublishError.failed(errno: exclusive)
        }

        // 1. A hard link: atomic about the name, and the bytes are already on disk.
        let linked = calls.link(partial, destination)
        if linked == 0 {
            // Published. A partial that will not unlink is a stray hidden file beside a
            // finished delivery, not a failed export.
            _ = calls.unlink(partial)
            return
        }
        if linked == EEXIST { throw ExportPublishError.destinationExists }
        guard noLinks.contains(linked) else { throw ExportPublishError.failed(errno: linked) }

        // 2. Claim the name, then move the bytes over our own empty claim.
        let claimed = calls.createExclusive(destination)
        if claimed == EEXIST { throw ExportPublishError.destinationExists }
        if claimed != 0 {
            throw unsupported.contains(claimed)
                ? ExportPublishError.unsupportedVolume(errno: claimed)
                : ExportPublishError.failed(errno: claimed)
        }
        let moved = calls.rename(partial, destination)
        if moved != 0 {
            _ = calls.unlink(destination)
            throw ExportPublishError.failed(errno: moved)
        }
    }

    /// What the export status line says about a failed file, or nil when the error has
    /// no reason a photographer can act on. Keeps the three outcomes V6 note 2 found
    /// indistinguishable apart: a lost race, an unsupported volume, a refused contact.
    public static func statusReason(for error: Error) -> String? {
        if let publish = error as? ExportPublishError { return publish.reason }
        if let contact = error as? MetadataPolicy.InvalidContact { return contact.message }
        return nil
    }
}
