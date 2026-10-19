import Foundation

/// A successfully written portable document awaiting SQL observation/settlement.
/// Physical I/O must finish before this value is submitted. The catalog owner must
/// serialize its generation check and physical write with new intent commits.
public struct SidecarIntentPublication: Equatable, Sendable {
    public struct Observation: Equatable, Sendable {
        public let modificationTime: Int64?
        public let digest: String
        public init(modificationTime: Int64?, digest: String) {
            self.modificationTime = modificationTime
            self.digest = digest
        }
    }
    public let photoPath: String
    public let photoID: Int64?
    public let generation: String?
    /// Nil when publication must not acknowledge unimported external recipe bytes.
    public let observation: Observation?

    public init(photoPath: String, photoID: Int64?, generation: String?, observation: Observation? = nil) {
        self.photoPath = photoPath
        self.photoID = photoID
        self.generation = generation
        self.observation = observation
    }

    /// Existing v1 metadata format; no schema or chronology migration.
    public static func observationKey(photoID: Int64) -> String { "sidecar_bytes_v1:\(photoID)" }
}
