import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum OriginalRelinkError: Error, LocalizedError, Equatable {
    case originalAvailable, unavailableIdentity, candidateUnavailable, candidateChanged
    case mismatch, ambiguous, alreadyRegistered, changedMapping, incompatibleSidecar, unsafeDebt, unsupportedHash, unavailableEditPayload
    public var errorDescription: String? {
        switch self {
        case .originalAvailable: return "The original is still present. Relinking is only available for a missing original."
        case .unavailableIdentity: return "The catalog has no usable stored size/signature for this original."
        case .candidateUnavailable: return "The chosen original is not a readable regular file."
        case .candidateChanged: return "The chosen file changed during verification. Choose it again after its copy finishes."
        case .mismatch: return "The chosen file does not match the original's stored size and signature."
        case .ambiguous: return "More than one catalog photo owns this size/signature. Relinking would be ambiguous."
        case .alreadyRegistered: return "The chosen path is already registered to another catalog photo."
        case .changedMapping: return "The catalog mapping changed during verification. Start relinking again."
        case .incompatibleSidecar: return "The chosen file has an unreadable or conflicting sidecar. It was left untouched."
        case .unsafeDebt: return "Pending sidecar records cannot be safely moved. The original mapping and records were preserved."
        case .unavailableEditPayload: return "The catalog edit or its brush payloads cannot be safely carried to a new sidecar by this build."
        case .unsupportedHash: return "The catalog's full-file checksum format cannot be verified by this build."
        }
    }
}

public struct OriginalRelinkTarget: Sendable, Equatable {
    public let photoID: Int64
    public let original: URL
    public let fileSize: Int64
    public let quickSignature: String
    public let fullHash: String?
    public init(photoID: Int64, original: URL, fileSize: Int64, quickSignature: String, fullHash: String?) {
        self.photoID = photoID; self.original = original; self.fileSize = fileSize
        self.quickSignature = quickSignature; self.fullHash = fullHash
    }
}

/// The bytes are read outside the database lane. Its generation is checked again
/// before committing; the prefix signature is explicitly not full-file equality.
public struct OriginalRelinkCandidate: Sendable {
    public let url: URL
    public let fileSize: Int64
    public let fileMTime: Int64
    public let quickSignature: String
    public let identity: SourceFileIdentity
    public let fullHash: String?

    public static func inspect(_ url: URL, fullHashRequired: Bool = false) throws -> Self {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        guard let before = SourceFileIdentity.read(url),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let date = attributes[.modificationDate] as? Date else { throw OriginalRelinkError.candidateUnavailable }
        let signature: String
        var fullHash: String?
        do {
            signature = try QuickSignature.compute(url: url)
            if fullHashRequired {
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                var stream = XXH64Stream()
                while let bytes = try file.read(upToCount: 1 << 20), !bytes.isEmpty { stream.update(bytes) }
                fullHash = "xxh64:" + stream.hexDigest()
            }
        } catch { throw OriginalRelinkError.candidateUnavailable }
        guard SourceFileIdentity.read(url) == before else { throw OriginalRelinkError.candidateChanged }
        return Self(url: url, fileSize: size, fileMTime: Int64(date.timeIntervalSince1970),
                    quickSignature: signature, identity: before, fullHash: fullHash)
    }

    public func verifyUnchanged() throws {
        guard SourceFileIdentity.read(url) == identity else { throw OriginalRelinkError.candidateChanged }
    }
}

public enum OriginalRelink {
    /// Permission and other I/O errors cannot establish that an original is missing.
    public static func requireMissing(_ url: URL) throws {
        #if canImport(Darwin) || canImport(Glibc)
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return lstat(path, &info)
        }
        guard result != 0, errno == ENOENT || errno == ENOTDIR else {
            throw OriginalRelinkError.originalAvailable
        }
        #else
        throw OriginalRelinkError.originalAvailable
        #endif
    }
}

public struct OriginalRelinkResult: Sendable {
    public let photoID: Int64
    public let original: URL
    public let destination: URL
    public let invalidatedPreviews: [PreviewRow]
}
