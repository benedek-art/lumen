// Ingest harness: runs LumenCore's real IngestPlanner + VerifiedCopyDriver on a card folder
// built by make_card.py, and writes the report as JSON for check.py to verify independently
// (sha256 of every file, source untouched, backup identical, no partial files).
//
// usage: IngestHarness <card> <primary> <backup|-> <folderTemplate> <renameTemplate|-> <job|-> <out.json>
//                      [--cancel-after-bytes N] [--verify 0|1] [--chunk N]
//
// The scan mirrors IngestSheet.ingestScan (private, macOS-only app code): recursive
// enumerator skipping hidden files and package descendants, PhotoFormats.browsable
// extensions, sorted by filename with localizedStandardCompare. Capture date mirrors
// ingestCreationDate (creation date, else modification date).
import Foundation
import LumenCore

var args = Array(CommandLine.arguments.dropFirst())
func opt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
}
let cancelAfter = opt("--cancel-after-bytes").flatMap { Int64($0) }
let verify = (opt("--verify") ?? "1") == "1"
let chunk = opt("--chunk").flatMap { Int($0) } ?? IngestFileDigest.defaultChunkSize
guard args.count == 7 else { print("bad args"); exit(2) }
let card = URL(fileURLWithPath: args[0], isDirectory: true)
let primary = URL(fileURLWithPath: args[1], isDirectory: true)
let backup: URL? = args[2] == "-" ? nil : URL(fileURLWithPath: args[2], isDirectory: true)
let folderTemplate = args[3]
let renameTemplate: String? = args[4] == "-" ? nil : args[4]
let job: String? = args[5] == "-" ? nil : args[5]
let outPath = args[6]

// --- scan (replica of IngestSheet.ingestScan) ---
let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
var found: [(URL, Int64)] = []
if let e = FileManager.default.enumerator(at: card, includingPropertiesForKeys: keys,
                                           options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
    for case let f as URL in e {
        guard PhotoFormats.browsable.contains(f.pathExtension.lowercased()) else { continue }
        let size = Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        found.append((f, size))
    }
}
found.sort { $0.0.lastPathComponent.localizedStandardCompare($1.0.lastPathComponent) == .orderedAscending }

var utc = Calendar(identifier: .gregorian)
utc.timeZone = TimeZone(identifier: "UTC")!
let sources = found.map { (url, size) -> IngestSourceFile in
    let v = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
    return IngestSourceFile(url: url, byteCount: size,
                            captureDate: v?.creationDate ?? v?.contentModificationDate ?? Date())
}
var roots = [IngestDestinationRoot(url: primary, role: .primary)]
if let backup {
    if IngestLocation.sameDirectory(backup, primary) {
        let o: [String: Any] = ["refused": "backup is primary (sheet refuses)"]
        try! JSONSerialization.data(withJSONObject: o).write(to: URL(fileURLWithPath: outPath)); exit(0)
    }
    roots.append(IngestDestinationRoot(url: backup, role: .backup))
}
let plan = IngestPlanner.plan(sources: sources, destinations: roots, folderTemplate: folderTemplate,
                              renameTemplate: renameTemplate, job: job, calendar: utc)

let cancellation = IngestCancellation()
final class Box: @unchecked Sendable { var maxProcessed: Int64 = 0; var events = 0 }
let box = Box()
let driver = VerifiedCopyDriver(verify: verify, chunkSize: chunk)
let report = driver.run(plan, cancellation: cancellation) { p in
    box.events += 1
    box.maxProcessed = max(box.maxProcessed, p.bytesProcessed)
    if let cancelAfter, p.bytesProcessed >= cancelAfter { cancellation.cancel() }
}

func outcomeString(_ o: IngestCopyOutcome) -> [String: Any] {
    switch o {
    case .verified(let d): return ["kind": "verified", "xxh": d.hex, "bytes": d.byteCount]
    case .copied(let d): return ["kind": "copied", "xxh": d.hex, "bytes": d.byteCount]
    case .alreadyPresent(let d): return ["kind": "alreadyPresent", "xxh": d.hex, "bytes": d.byteCount]
    case .failed(let f): return ["kind": "failed", "message": f.message]
    }
}
let out: [String: Any] = [
    "scanned": found.map { $0.0.path },
    "planned": plan.copies.map { ["source": $0.source.path,
                                  "destinations": $0.destinations.map { $0.url.path }] },
    "refusals": plan.refusals,
    "results": report.results.map { r -> [String: Any] in
        ["source": r.source.path, "planned": r.plannedDestination.path,
         "destination": r.destination.path, "role": r.role.rawValue,
         "outcome": outcomeString(r.outcome)] },
    "wasCancelled": report.wasCancelled,
    "filesAttempted": report.filesAttempted,
    "filesPlanned": report.filesPlanned,
    "framesVerified": report.framesVerified,
    "allVerified": report.allVerified,
    "summary": report.summary,
    "progressEvents": box.events,
    "unknownTokensRename": renameTemplate.map { RenameTemplate.unknownTokens(in: $0) } ?? [],
    "unknownTokensFolder": RenameTemplate.unknownTokens(in: folderTemplate),
]
try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: outPath))
print(report.summary)
