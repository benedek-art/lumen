// UnsavedSidecarRecord.swift
// Portable publication intent, committed with catalog edits and retained across restart.
//
// The quit flush runs inside `applicationWillTerminate`. A failure there was reported
// through `onFailure`, which hops to the main actor, and the main actor never runs again
// once termination returns; `close()` then marked the queue closed and the re-queued
// entry was dropped. Nothing durable said that the portable copy of an edit was behind
// the catalog, so the photographer could not know to fix the volume.
//
// Scalar fields are rebuilt from the current catalog. Keyword deltas are persisted
// because a flat bag cannot express an owed removal through the remaining catalog
// members alone. Recovery reconciles those deltas with current membership so a record
// that outlives its write cannot reverse a newer catalog edit.
//
// In LumenCore so its codec runs on the lane that runs every push.

import Foundation

public struct UnsavedSidecarRecord: Codable, Equatable, Sendable {
    /// The photograph's path (not the sidecar's: the sidecar name is re-resolved).
    public var photoPath: String
    public var photoID: Int64?
    /// `SidecarStatedFields.rawValue` of the fields the committed edit still owes.
    public var stated: Int
    /// Optional for records produced before keyword deltas were persisted.
    public var keywordEdit: SidecarKeywordEdit?
    /// Identifies the latest committed intent; older publications cannot settle it.
    public var generation: String?

    public init(photoPath: String, photoID: Int64?, stated: SidecarStatedFields, keywordEdit: SidecarKeywordEdit? = nil, generation: String? = nil) {
        self.photoPath = photoPath
        self.photoID = photoID
        self.stated = stated.rawValue
        self.keywordEdit = keywordEdit
        self.generation = generation
    }

    public var statedFields: SidecarStatedFields { SidecarStatedFields(rawValue: stated) }

    /// The catalog `meta` key the records live under.
    public static let metaKey = "sidecar_unsaved"

    /// Nil for an empty list, so writing it clears the key.
    public static func encode(_ records: [UnsavedSidecarRecord]) -> String? {
        guard !records.isEmpty else { return nil }
        let sorted = records.sorted { $0.photoPath < $1.photoPath }
        guard let data = try? JSONEncoder().encode(sorted) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// An unreadable value decodes to nothing rather than throwing: the record is a
    /// notice, and the catalog the fields are rebuilt from is intact either way.
    public static func decode(_ value: String?) -> [UnsavedSidecarRecord] {
        guard let value else { return [] }
        let data = Data(value.utf8)
        return (try? JSONDecoder().decode([UnsavedSidecarRecord].self, from: data)) ?? []
    }

    /// Transactional updates must not replace unreadable existing debt with an empty list.
    public static func decodeValidated(_ value: String?) throws -> [UnsavedSidecarRecord] {
        guard let value else { return [] }
        let bytes = Data(value.utf8)
        let decoder = JSONDecoder()
        let records = try decoder.decode([UnsavedSidecarRecord].self, from: bytes)
        let knownFields: SidecarStatedFields = [.rating, .flag, .label, .recipe, .strokes, .keywords]
        guard Set(records.map(\.photoPath)).count == records.count,
              records.allSatisfy({ $0.photoPath.hasPrefix("/") && $0.stated >= 0 && ($0.stated & ~knownFields.rawValue) == 0 }),
              case .array(let entries) = try decoder.decode(JSONValue.self, from: bytes) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "unsupported portable intent fields"))
        }
        let recordKeys: Set<String> = ["photoPath", "photoID", "stated", "keywordEdit", "generation"]
        let keywordKeys: Set<String> = ["added", "removed"]
        for entry in entries {
            guard case .object(let object) = entry, Set(object.keys).isSubset(of: recordKeys) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "unsupported portable intent keys"))
            }
            if case .object(let keywords)? = object["keywordEdit"], !Set(keywords.keys).isSubset(of: keywordKeys) {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "unsupported portable keyword intent keys"))
            }
        }
        return records
    }

    /// Merge two records for one photograph: every field either one owed is owed.
    public func merged(with other: UnsavedSidecarRecord) -> UnsavedSidecarRecord {
        UnsavedSidecarRecord(photoPath: photoPath, photoID: photoID ?? other.photoID,
                             stated: statedFields.union(other.statedFields),
                             keywordEdit: keywordEdit.map { $0.then(other.keywordEdit ?? SidecarKeywordEdit()) }
                                ?? other.keywordEdit,
                             generation: other.generation ?? generation)
    }

    /// The launch notice for a set of records; nil when there are none.
    public static func notice(for records: [UnsavedSidecarRecord]) -> String? {
        guard !records.isEmpty else { return nil }
        let names = records.map { URL(fileURLWithPath: $0.photoPath).lastPathComponent }.sorted()
        let shown = names.prefix(5).joined(separator: ", ")
        let more = names.count > 5 ? " and \(names.count - 5) more" : ""
        return "The portable sidecar for \(shown)\(more) could not be saved during Lumen’s last "
            + "session. The catalog has the edits; Lumen is writing the sidecar again now and "
            + "will keep retrying while the sidecar is unavailable or cannot be safely updated."
    }
}
