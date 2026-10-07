#if os(macOS)
import Foundation
import CryptoKit

/// File-heavy update work runs away from the UI actor. Every path is supplied by
/// the caller, so tests can exercise failure handling using disposable bundles.
enum UpdateFileWork {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func verifyDownload(_ file: URL, expectedSize: Int, digest: String) async throws {
        try await Task.detached(priority: .utility) {
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            guard (attrs[.size] as? Int) == expectedSize else {
                throw Failure(message: "the download's size doesn't match the release's")
            }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                hash.update(data: chunk)
            }
            let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == digest else {
                throw Failure(message: "the download's SHA-256 doesn't match the release's "
                    + "(expected \(digest.prefix(12))…, got \(actual.prefix(12))…)")
            }
        }.value
    }

    /// Stage beside the destination before replacement, keeping it on one volume.
    static func replaceBundle(_ incoming: URL, current: URL) async throws {
        try await Task.detached(priority: .utility) {
            let manager = FileManager.default
            let staged = current.deletingLastPathComponent()
                .appendingPathComponent("Lumen-update-\(UUID().uuidString).app")
            defer { try? manager.removeItem(at: staged) }
            try manager.copyItem(at: incoming, to: staged)
            _ = try manager.replaceItemAt(current, withItemAt: staged)
        }.value
    }

    @MainActor
    static func withScratch<T>(_ operation: (URL) async throws -> T) async throws -> T {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-update-\(UUID().uuidString)")
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        }.value
        do {
            let result = try await operation(work)
            await remove(work)
            return result
        } catch {
            await remove(work)
            throw error
        }
    }

    static func remove(_ path: URL) async {
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: path)
        }.value
    }
}

@MainActor
enum UpdateRelaunch {
    /// A failed launch leaves the current process running.
    static func perform(open: () async throws -> Void, terminate: () -> Void) async throws {
        try await open()
        terminate()
    }
}
#endif
