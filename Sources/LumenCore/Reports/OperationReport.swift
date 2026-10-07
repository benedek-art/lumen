import Foundation

/// Paths and execution outcomes only: no image bytes, EXIF, recipes or pixel data.
public struct OperationFileRecord: Codable, Equatable, Sendable, Identifiable {
    public enum Outcome: String, Codable, Hashable, Sendable {
        case pending, delivered, verified, copied, alreadyPresent, skipped, failed, notAttempted, unknown
    }
    public var id: Int
    public var sourcePath: String
    public var label: String
    public var plannedDestination: String?
    public var attemptedDestination: String?
    /// Set only for a confirmed publication or a proven existing ingest copy.
    public var actualDestination: String?
    public var outcome: Outcome
    public var renamed = false
    public var replaced = false
    public var reducedKernels: [String] = []
    public var detail: String?

    public init(id: Int, source: URL, label: String, outcome: Outcome = .pending,
                plannedDestination: URL? = nil, attemptedDestination: URL? = nil,
                actualDestination: URL? = nil, detail: String? = nil) {
        self.id = id
        self.sourcePath = source.path
        self.label = label
        self.outcome = outcome
        self.plannedDestination = plannedDestination?.path
        self.attemptedDestination = attemptedDestination?.path
        self.actualDestination = actualDestination?.path
        self.detail = detail
    }
}

public struct OperationReport: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case ingest, export }
    public enum State: String, Codable, Sendable { case running, completed, cancelled, refused, interrupted }
    public var schemaVersion = 1
    public var id: UUID
    public var kind: Kind
    public var startedAt: Date
    public var finishedAt: Date?
    public var revision = 0
    public var state: State = .running
    public var records: [OperationFileRecord]
    public var issues: [String] = []

    public init(id: UUID = UUID(), kind: Kind, startedAt: Date = Date(), records: [OperationFileRecord]) {
        self.id = id
        self.kind = kind
        self.startedAt = startedAt
        self.records = records
    }

    public mutating func settle(_ record: OperationFileRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record }
        else { records.append(record) }
        revision += 1
    }

    public mutating func finish(_ state: State, at date: Date = Date()) {
        self.state = state
        finishedAt = date
        for index in records.indices where records[index].outcome == .pending {
            records[index].outcome = .notAttempted
        }
        revision += 1
    }

    /// An incomplete checkpoint cannot establish what happened after it was saved.
    /// Unknown entries may have been delivered before the process stopped.
    public var recoveredAfterRelaunch: OperationReport {
        guard state == .running else { return self }
        var report = self
        report.state = .interrupted
        for index in report.records.indices where report.records[index].outcome == .pending {
            report.records[index].outcome = .unknown
        }
        return report
    }

    public var summary: String {
        let counts = Dictionary(grouping: records, by: \.outcome).mapValues(\.count)
        var parts: [String] = []
        for (outcome, label) in [(OperationFileRecord.Outcome.delivered, "delivered"),
                                (.verified, "verified"), (.copied, "copied without verification"),
                                (.alreadyPresent, "already present"), (.skipped, "skipped"),
                                (.failed, "failed"), (.notAttempted, "not attempted"),
                                (.unknown, "unknown"), (.pending, "pending")] {
            if let count = counts[outcome], count > 0 { parts.append("\(count) \(label)") }
        }
        return "\(kind.rawValue.capitalized) — \(state.rawValue.capitalized): "
            + (parts.isEmpty ? "no file outcomes" : parts.joined(separator: ", "))
    }

    public mutating func finishIngest(_ result: IngestReport, sources: [URL], expectedRoles: [IngestDestinationRole] = [.primary], at date: Date = Date()) {
        records = result.results.enumerated().map { index, file in
            let outcome: OperationFileRecord.Outcome
            let detail: String?
            switch file.outcome {
            case .verified: outcome = .verified; detail = nil
            case .copied: outcome = .copied; detail = "Verification was disabled."
            case .alreadyPresent: outcome = .alreadyPresent; detail = "Existing bytes proved identical; not copied this run."
            case .failed(let failure):
                outcome = .failed
                switch failure {
                case .verificationMismatch: detail = "Verification mismatch; destination cleanup was attempted."
                case .unreadableCopy(let reason): detail = "The copy could not be verified; cleanup was attempted: " + reason
                default: detail = failure.message
                }
            }
            var record = OperationFileRecord(id: index, source: file.source, label: file.role.rawValue,
                outcome: outcome, plannedDestination: file.plannedDestination,
                attemptedDestination: file.destination,
                actualDestination: file.failure == nil ? file.destination : nil, detail: detail)
            record.renamed = file.wasRenamed && outcome != .alreadyPresent
            return record
        }
        let settled = Set(result.results.map { $0.source.path + "\u{0}" + $0.role.rawValue })
        for source in sources {
            for role in expectedRoles where !settled.contains(source.path + "\u{0}" + role.rawValue) {
                records.append(OperationFileRecord(id: records.count, source: source, label: role.rawValue,
                    outcome: .notAttempted, detail: "No concluded result was produced for this destination role."))
            }
        }
        issues = result.refusals
        finish(result.wasCancelled ? .cancelled : .completed, at: date)
    }
}
