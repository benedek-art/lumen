// UnsavedSidecarRecord.swift
// Which sidecars were still unwritten when Lumen quit, kept where the next launch finds it.
//
// The quit flush runs inside `applicationWillTerminate`. A failure there was reported
// through `onFailure`, which hops to the main actor, and the main actor never runs again
// once termination returns; `close()` then marked the queue closed and the re-queued
// entry was dropped. Nothing durable said that the portable copy of an edit was behind
// the catalog, so the photographer could not know to fix the volume.
//
// The record names the photograph and which fields were owed, not the content: the next
// launch rebuilds those fields from the catalog, which is the newer truth by then, so a
// record that outlives its write (a crash after a later success) only causes a redundant,
// correct rewrite and never resurrects an older state.
//
// In LumenCore so its codec runs on the lane that runs every push.

import Foundation

public struct UnsavedSidecarRecord: Codable, Equatable, Sendable {
    /// The photograph's path (not the sidecar's: the sidecar name is re-resolved).
    public var photoPath: String
    public var photoID: Int64?
    /// `SidecarStatedFields.rawValue` of the fields the failed write was stating.
    public var stated: Int

    public init(photoPath: String, photoID: Int64?, stated: SidecarStatedFields) {
        self.photoPath = photoPath
        self.photoID = photoID
        self.stated = stated.rawValue
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

    /// Merge two records for one photograph: every field either one owed is owed.
    public func merged(with other: UnsavedSidecarRecord) -> UnsavedSidecarRecord {
        UnsavedSidecarRecord(photoPath: photoPath, photoID: photoID ?? other.photoID,
                             stated: statedFields.union(other.statedFields))
    }

    /// The launch notice for a set of records; nil when there are none.
    public static func notice(for records: [UnsavedSidecarRecord]) -> String? {
        guard !records.isEmpty else { return nil }
        let names = records.map { URL(fileURLWithPath: $0.photoPath).lastPathComponent }.sorted()
        let shown = names.prefix(5).joined(separator: ", ")
        let more = names.count > 5 ? " and \(names.count - 5) more" : ""
        return "The portable sidecar for \(shown)\(more) could not be saved when Lumen last "
            + "quit. The catalog has the edits; Lumen is writing the sidecar again now and "
            + "will keep retrying while the photo's volume is unavailable."
    }
}
