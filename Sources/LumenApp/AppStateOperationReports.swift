#if os(macOS)
import AppKit
import Foundation
import LumenCore
import SwiftUI

extension AppState {
    func configureOperationReports(directory: URL) {
        guard operationReportStore == nil else { return }
        let store = OperationReportStore(directory: directory.appendingPathComponent("reports", isDirectory: true))
        operationReportStore = store
        Task {
            do {
                let archive = try await store.load()
                // A run may start while disk history loads. Never replace its newer checkpoint.
                for saved in archive.reports {
                    let current = operationReports.first { $0.id == saved.report.id }
                    if current == nil || current!.revision < saved.report.revision {
                        operationReports.removeAll { $0.id == saved.report.id }
                        operationReports.append(saved.report)
                    }
                    if (operationReportSavedRevisions[saved.report.id] ?? -1) <= saved.report.revision {
                        operationReportFiles[saved.report.id] = saved.file
                        operationReportSavedRevisions[saved.report.id] = saved.report.revision
                    }
                }
                trimOperationReportMemory()
                if !archive.warnings.isEmpty { operationReportWarning = archive.warnings.joined(separator: "\n") }
            } catch { operationReportWarning = "Could not load operation reports: \(error.localizedDescription)" }
        }
    }

    func checkpointOperationReport(_ report: OperationReport, force: Bool = true) async {
        guard let store = operationReportStore else {
            mergeOperationReport(report)
            operationReportWarning = "Operation report could not be saved: catalog report storage is unavailable."
            return
        }
        do {
            let saved = try await store.save(report, force: force)
            if saved {
                let file = await store.file(for: report.id)
                if (operationReportSavedRevisions[report.id] ?? -1) <= report.revision {
                    operationReportFiles[report.id] = file
                    operationReportSavedRevisions[report.id] = report.revision
                }
            }
            if saved || force { mergeOperationReport(report) }
            if let warning = await store.retentionWarning { operationReportWarning = warning }
        } catch {
            mergeOperationReport(report)
            operationReportWarning = "Operation report could not be saved; file outcomes are unchanged: \(error.localizedDescription)"
        }
    }

    private func mergeOperationReport(_ report: OperationReport) {
        if let current = operationReports.first(where: { $0.id == report.id }),
           current.revision > report.revision || (current.revision == report.revision && current.state != .running && report.state == .running) { return }
        operationReports.removeAll { $0.id == report.id }
        operationReports.append(report)
        trimOperationReportMemory()
    }

    private func trimOperationReportMemory() {
        operationReports.sort { $0.startedAt > $1.startedAt }
        // Match supported terminal history's count cap in memory. Running/unknown evidence stays.
        var terminal = 0
        operationReports = operationReports.filter { report in
            if report.state == .running || report.state == .interrupted { return true }
            terminal += 1
            return terminal <= 50
        }
        let retained = Set(operationReports.map(\.id))
        operationReportFiles = operationReportFiles.filter { retained.contains($0.key) }
        operationReportSavedRevisions = operationReportSavedRevisions.filter { retained.contains($0.key) }
    }
}

struct OperationReportsButton: View {
    @ObservedObject var state: AppState
    @State private var showing = false
    var body: some View {
        Button("Recent results") { showing.toggle() }
            .popover(isPresented: $showing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Ingest and export results").font(.headline)
                        if let warning = state.operationReportWarning { Text(warning).foregroundStyle(.orange) }
                        if state.operationReports.isEmpty { Text("No recorded runs yet.") }
                        ForEach(state.operationReports) { report in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(report.summary)
                                Text(report.startedAt.formatted()).font(.caption)
                                if let path = state.operationReportFiles[report.id],
                                   FileManager.default.fileExists(atPath: path.path) {
                                    Button("Reveal saved report") {
                                        NSWorkspace.shared.activateFileViewerSelecting([path])
                                    }
                                    if state.operationReportSavedRevisions[report.id] != report.revision {
                                        Text("Saved file contains an earlier checkpoint.").font(.caption).foregroundStyle(.orange)
                                    }
                                } else { Text("Report has not been saved.").font(.caption).foregroundStyle(.orange) }
                            }
                            Divider()
                        }
                    }.padding().frame(width: 460, alignment: .leading)
                }.frame(maxHeight: 440)
            }
    }
}
#endif
