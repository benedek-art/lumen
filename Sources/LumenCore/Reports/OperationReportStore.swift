import Foundation

public struct SavedOperationReport: Sendable {
    public var report: OperationReport
    public var file: URL
}

public struct OperationReportArchive: Sendable {
    public var reports: [SavedOperationReport]
    public var warnings: [String]
}

/// Completed history is bounded. Unfinished, malformed and newer-version evidence is
/// preserved even when it cannot be included in the supported-history retention cap.
public actor OperationReportStore {
    public let directory: URL
    private let completedLimit: Int
    private let completedBytes: Int
    private let maximumFileBytes = 16 * 1024 * 1024
    public private(set) var retentionWarning: String?
    private var checkpoints: [UUID: (time: Date, revision: Int)] = [:]

    public enum StoreError: Error, LocalizedError {
        case oversized, unsupported, malformed, identityMismatch
        public var errorDescription: String? {
            switch self {
            case .oversized: return "The operation report exceeds the supported size limit."
            case .unsupported: return "The existing report uses a newer schema and was left untouched."
            case .malformed: return "The existing report cannot be read safely and was left untouched."
            case .identityMismatch: return "The report identity does not match its file name."
            }
        }
    }

    public init(directory: URL, completedLimit: Int = 50, completedBytes: Int = 32 * 1024 * 1024) {
        self.directory = directory
        self.completedLimit = max(1, completedLimit)
        self.completedBytes = max(1, completedBytes)
    }

    public func file(for id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }

    /// True only when these bytes were actually saved. Running checkpoints are
    /// coalesced (one second or 50 outcomes); start/final writes are forced by callers.
    /// A crash between checkpoints leaves unknown outcomes, never guessed deliveries.
    @discardableResult
    public func save(_ report: OperationReport, force: Bool = true, now: Date = Date()) throws -> Bool {
        guard report.schemaVersion == 1 else { throw StoreError.unsupported }
        guard report.revision >= 0, report.records.count <= 100_000,
              Set(report.records.map(\.id)).count == report.records.count else { throw StoreError.malformed }
        if !force, let previous = checkpoints[report.id],
           now.timeIntervalSince(previous.time) < 1, report.revision - previous.revision < 50 {
            return false
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = file(for: report.id)
        if FileManager.default.fileExists(atPath: target.path) {
            let existing = try decode(target)
            // Delayed checkpoints of this same operation must not undo a final report.
            if existing.revision >= report.revision { return false }
            if existing.state != .running && report.state == .running { return false }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(report)
        guard data.count <= maximumFileBytes else { throw StoreError.oversized }
        try data.write(to: target, options: .atomic)
        if report.state == .running { checkpoints[report.id] = (now, report.revision) }
        else { checkpoints.removeValue(forKey: report.id) }
        // Pruning is best effort and never turns a successful report write into a
        // failed delivery/report claim. Only supported, terminal files are eligible.
        if report.state != .running {
            do { try prune(); retentionWarning = nil }
            catch { retentionWarning = "The report was saved, but old report history could not be pruned: \(error.localizedDescription)" }
        }
        return true
    }

    public func load() throws -> OperationReportArchive {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return OperationReportArchive(reports: [], warnings: [])
        }
        var reports: [SavedOperationReport] = []
        var warnings: [String] = []
        for url in try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).filter({ $0.pathExtension == "json" }) {
            do {
                reports.append(SavedOperationReport(report: try decode(url).recoveredAfterRelaunch, file: url))
            } catch {
                warnings.append("Could not read report \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        reports.sort { $0.report.startedAt > $1.report.startedAt }
        return OperationReportArchive(reports: reports, warnings: warnings)
    }

    private func decode(_ url: URL) throws -> OperationReport {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= maximumFileBytes else { throw StoreError.oversized }
        let data = try Data(contentsOf: url)
        struct Header: Decodable { var schemaVersion: Int }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else { throw StoreError.malformed }
        guard header.schemaVersion == 1 else { throw StoreError.unsupported }
        guard let report = try? JSONDecoder().decode(OperationReport.self, from: data) else { throw StoreError.malformed }
        guard url.deletingPathExtension().lastPathComponent == report.id.uuidString else { throw StoreError.identityMismatch }
        guard report.revision >= 0, report.records.count <= 100_000,
              Set(report.records.map(\.id)).count == report.records.count else { throw StoreError.malformed }
        return report
    }

    private func prune() throws {
        var completed: [(url: URL, report: OperationReport, bytes: Int)] = []
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.pathExtension == "json" {
            guard let report = try? decode(url), report.state != .running, report.state != .interrupted else { continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            completed.append((url, report, (attributes[.size] as? NSNumber)?.intValue ?? 0))
        }
        completed.sort { $0.report.startedAt > $1.report.startedAt }
        var bytes = 0
        for (index, item) in completed.enumerated() {
            bytes += item.bytes
            // Always keep the most recent terminal report, even if it exceeds the
            // history byte budget. The individual file cap still bounds that file.
            if index > 0 && (index >= completedLimit || bytes > completedBytes) {
                try FileManager.default.removeItem(at: item.url)
            }
        }
    }
}
