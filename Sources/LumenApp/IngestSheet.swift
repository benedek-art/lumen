// IngestSheet.swift
// Verified ingest (D38, docs/02 §7) as ONE screen: source, files, primary and backup
// destinations, folder and filename templates with live previews, verify, start. No
// wizard, no pages — insert a card, glance at the previews, press Return.
//
// Two pieces of honesty are built into this file rather than papered over:
//
//   · The copy engine does not exist yet. The sheet drives an `IngestDriver`; the
//     default implementation is `UnavailableIngestDriver`, which copies nothing and
//     says so. The Start button is disabled and the banner explains why, because a
//     button that looks live and silently does nothing is worse than no button.
//   · The documented default rename template `{date}-{seq4}-{orig}` does NOT validate
//     against `RenameTemplate` as shipped — `seqWidth` only recognises the `{seq:N}`
//     form, so `{seq4}` is an unknown token that renders empty. Rather than quietly
//     shipping a different default, the sheet starts on the documented one, shows the
//     validation error inline, and offers a one-click repair to `{seq:4}`.

#if os(macOS)

import AppKit
import Foundation
import LumenCore
import SwiftUI

// MARK: - The driver seam

/// One file the ingest is planning to copy.
struct IngestPlanFile: Identifiable, Hashable, Sendable {
    let id: URL
    var byteSize: Int64

    var url: URL { id }
    var filename: String { id.lastPathComponent }
    var fileExtension: String { id.pathExtension }
}

/// Everything the copy engine needs, resolved from the sheet. Templates travel
/// unrendered: the engine renders them per file, because `{seq}` depends on position.
struct IngestRequest: Sendable {
    var files: [IngestPlanFile]
    var primaryDestination: URL
    var backupDestination: URL?
    var folderTemplate: String
    var renameTemplate: String
    var renameEnabled: Bool
    var jobName: String
    /// Streamed xxHash64 in flight, then a destination re-read and re-hash. Only a
    /// matching re-read marks a frame verified, per destination.
    var verify: Bool
    var ejectWhenDone: Bool
}

enum IngestStartResult: Sendable {
    case started
    case refused(String)
}

/// The seam the copy engine will land behind. Deliberately tiny: plan in, "did it
/// start" out. Progress reporting belongs to the engine's own queue model, not here.
protocol IngestDriver {
    /// `nil` when the driver can really copy. Otherwise the reason it cannot, shown
    /// verbatim in the sheet — never paraphrased into "something went wrong".
    var unavailableReason: String? { get }

    func start(_ request: IngestRequest) -> IngestStartResult
}

/// The default. It plans, validates and previews; it moves no bytes.
struct UnavailableIngestDriver: IngestDriver {
    var unavailableReason: String? {
        "The verified-copy engine is not built yet. This sheet plans the ingest and "
            + "checks the templates — it will not copy, verify or eject anything."
    }

    func start(_ request: IngestRequest) -> IngestStartResult {
        .refused("Nothing was copied: the verified-copy engine is not implemented yet. "
                 + "\(request.files.count) file\(request.files.count == 1 ? "" : "s") "
                 + "would have been written to \(request.primaryDestination.path).")
    }
}

// MARK: - Sheet

@MainActor
struct IngestSheet: View {
    @Environment(\.dismiss) private var dismiss: DismissAction

    let driver: any IngestDriver

    init(driver: any IngestDriver = UnavailableIngestDriver()) {
        self.driver = driver
    }

    // Source
    @State private var volumes: [URL] = []
    @State private var sourceURL: URL? = nil
    @State private var files: [IngestPlanFile] = []
    @State private var isScanning: Bool = false

    // Destinations
    @State private var primaryDestination: URL? = nil
    @State private var backupEnabled: Bool = false
    @State private var backupDestination: URL? = nil

    // Templates
    @State private var folderTemplate: String = "{year}/{date} {job}"
    @State private var renameEnabled: Bool = true
    /// The template docs/10 §10.7 documents. It does not validate — see the file header.
    @State private var renameTemplate: String = "{date}-{seq4}-{orig}"
    @State private var jobName: String = ""

    // Protocol
    @State private var verify: Bool = true
    @State private var ejectWhenDone: Bool = false
    @State private var statusLine: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Lumen.separator)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    unavailableBanner
                    sourceSection
                    destinationSection
                    templateSection
                    protocolSection
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            Divider().overlay(Lumen.separator)
            footer
        }
        .frame(width: 640, height: 660)
        .background(Lumen.panelBackground)
        .onAppear { refreshVolumes() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Ingest")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Lumen.primaryText)
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(14)
    }

    @ViewBuilder
    private var unavailableBanner: some View {
        if let reason = driver.unavailableReason {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(Lumen.primaryText)
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(Lumen.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(Lumen.controlBackground)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .padding(.bottom, 6)
        }
    }

    // MARK: Source

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Source")
            IngestFieldRow("Volume") {
                Menu {
                    ForEach(volumes, id: \.self) { volume in
                        Button(ingestVolumeLabel(volume)) { chooseSource(volume) }
                    }
                    if volumes.isEmpty {
                        Text("No mounted volumes found")
                    }
                    Divider()
                    Button("Rescan volumes") { refreshVolumes() }
                    Button("Choose Folder…") { browseForSource() }
                } label: {
                    Text(sourceURL.map { $0.path } ?? "Choose a card or folder")
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .controlSize(.small)
                .frame(maxWidth: 380)
            }

            HStack(spacing: 6) {
                Text("Files")
                    .font(.system(size: 11))
                    .foregroundStyle(Lumen.secondaryText)
                    .frame(width: Lumen.labelWidth, alignment: .leading)
                Text(fileCountSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(Lumen.primaryText)
                Spacer(minLength: 0)
            }
            .frame(minHeight: Lumen.rowHeight)

            fileList
        }
    }

    @ViewBuilder
    private var fileList: some View {
        if files.isEmpty {
            IngestNote(isScanning
                       ? "Scanning…"
                       : "No readable frames yet. Pick a card — DCIM is found automatically.")
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(files) { file in
                        HStack(spacing: 6) {
                            Text(file.filename)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Lumen.primaryText)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(ingestByteString(file.byteSize))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Lumen.secondaryText)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 120)
            .background(Lumen.controlBackground)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    private var fileCountSummary: String {
        if isScanning { return "Scanning…" }
        if files.isEmpty { return "—" }
        let total = files.reduce(Int64(0)) { $0 + $1.byteSize }
        return "\(files.count) file\(files.count == 1 ? "" : "s") · \(ingestByteString(total))"
    }

    // MARK: Destinations

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Destinations")
            IngestFieldRow("Primary") {
                HStack(spacing: 6) {
                    Text(primaryDestination.map { $0.path } ?? "Not chosen")
                        .font(.system(size: 11))
                        .foregroundStyle(primaryDestination == nil
                                         ? Lumen.secondaryText : Lumen.primaryText)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Button("Choose…") { browseForPrimary() }
                        .controlSize(.small)
                }
            }
            LumenToggleRow(title: "Backup copy", isOn: $backupEnabled,
                           help: "A second volume, verified independently of the primary.")
            if backupEnabled {
                IngestFieldRow("Backup") {
                    HStack(spacing: 6) {
                        Text(backupDestination.map { $0.path } ?? "Not chosen")
                            .font(.system(size: 11))
                            .foregroundStyle(backupDestination == nil
                                             ? Lumen.secondaryText : Lumen.primaryText)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Button("Choose…") { browseForBackup() }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: Templates

    private var templateSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Naming")
            IngestFieldRow("Job") {
                IngestTextEntry(text: $jobName, placeholder: "feeds {job}")
            }
            IngestFieldRow("Folders") {
                IngestTextEntry(text: $folderTemplate, placeholder: "{year}/{date} {job}",
                                monospaced: true)
            }
            LumenToggleRow(title: "Rename files", isOn: $renameEnabled,
                           help: "Off keeps the camera's own names.")
            if renameEnabled {
                IngestFieldRow("Filenames") {
                    IngestTextEntry(text: $renameTemplate, placeholder: "{date}-{seq:4}-{orig}",
                                    monospaced: true)
                }
            }

            IngestFieldRow("Preview") {
                Text(pathPreview)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Lumen.primaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !templateProblems.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(templateProblems, id: \.self) { problem in
                        HStack(alignment: .top, spacing: 5) {
                            Image(systemName: "xmark.octagon")
                                .font(.system(size: 10))
                            Text(problem)
                                .font(.system(size: 10))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(Lumen.primaryText)
                    }
                    if repairAvailable {
                        Button("Rewrite {seqN} as {seq:N}") { repairTemplates() }
                            .controlSize(.small)
                    }
                }
                .padding(8)
                .background(Lumen.controlBackground)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .padding(.vertical, 4)
            }

            IngestNote("Tokens: " + Self.tokenList
                       + ". A width form is written {seq:4}, not {seq4}. Unknown tokens are "
                       + "an error here rather than an empty stretch in a delivered filename.")
            IngestNote("Preview uses the first file's creation date; camera, serial and ISO "
                       + "tokens resolve from EXIF during the copy, so they read as empty here.")
        }
    }

    /// Sorted so the list is stable between redraws.
    static var tokenList: String {
        RenameTemplate.knownTokens.sorted().map { "{" + $0 + "}" }.joined(separator: " ")
    }

    // MARK: Verify protocol

    private var protocolSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Verify")
            LumenToggleRow(title: "Verify every copy", isOn: $verify,
                           help: "xxHash64 streamed in flight, then the written file is "
                               + "re-read and re-hashed. Only a matching re-read counts.")
            if !verify {
                IngestNote("D38 does not offer an unverified copy: without the re-read there "
                           + "is no evidence the card actually landed. Leave this on.")
            }
            LumenToggleRow(title: "Eject when done", isOn: $ejectWhenDone,
                           help: "Offered only once every frame verifies on every destination.")
            IngestNote("Each destination verifies independently — a backup that fails does not "
                       + "mark the primary unverified, and neither one alone unlocks eject.")
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let statusLine {
                Text(statusLine)
                    .font(.system(size: 11))
                    .foregroundStyle(Lumen.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Text(readinessSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(canStart ? Lumen.primaryText : Lumen.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(startButtonTitle) { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
                    .help(driver.unavailableReason ?? "Copy and verify every checked frame")
            }
        }
        .padding(14)
    }

    private var startButtonTitle: String {
        driver.unavailableReason == nil ? "Ingest" : "Ingest (unavailable)"
    }

    private var canStart: Bool {
        driver.unavailableReason == nil
            && !files.isEmpty
            && primaryDestination != nil
            && (!backupEnabled || backupDestination != nil)
            && templateProblems.isEmpty
    }

    private var readinessSummary: String {
        if driver.unavailableReason != nil { return "Planning only — nothing will be copied." }
        if files.isEmpty { return "Choose a source with readable frames." }
        if primaryDestination == nil { return "Choose a primary destination." }
        if backupEnabled && backupDestination == nil { return "Choose a backup destination." }
        if !templateProblems.isEmpty { return "Fix the template errors above." }
        let count = files.count
        return "\(count) frame\(count == 1 ? "" : "s") → "
            + (backupEnabled ? "2 destinations" : "1 destination")
            + (verify ? ", verified" : ", UNVERIFIED")
    }

    // MARK: Template validation and preview

    private var templateProblems: [String] {
        var problems: [String] = []
        for token in RenameTemplate.unknownTokens(in: folderTemplate) {
            problems.append("Folder template: unknown token {\(token)}")
        }
        if renameEnabled {
            for token in RenameTemplate.unknownTokens(in: renameTemplate) {
                problems.append("Filename template: unknown token {\(token)}")
            }
            if renamedBasename.isEmpty {
                problems.append("Filename template renders empty for the first file.")
            }
        }
        if folderTemplate.contains("\\") {
            problems.append("Folder template: use / to separate path components.")
        }
        return problems
    }

    private var repairAvailable: Bool {
        Self.repaired(folderTemplate) != folderTemplate
            || (renameEnabled && Self.repaired(renameTemplate) != renameTemplate)
    }

    /// `{seq4}` → `{seq:4}`. The docs and the shipped parser disagree on this one form;
    /// the repair is mechanical, so offer it rather than making the user retype.
    static func repaired(_ template: String) -> String {
        var out = template
        for width in 1...9 {
            out = out.replacingOccurrences(of: "{seq\(width)}", with: "{seq:\(width)}")
        }
        return out
    }

    private func repairTemplates() {
        folderTemplate = Self.repaired(folderTemplate)
        renameTemplate = Self.repaired(renameTemplate)
    }

    private var previewContext: RenameContext {
        let first = files.first
        let basename = first.map { $0.id.deletingPathExtension().lastPathComponent }
            ?? "DSCF0001"
        let date = first.flatMap { ingestCreationDate(of: $0.id) } ?? Date()
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        let trimmedJob = jobName.trimmingCharacters(in: .whitespaces)
        return RenameContext(originalBasename: basename, captureDate: components,
                             camera: nil, cameraSerial: nil, iso: nil,
                             job: trimmedJob.isEmpty ? nil : trimmedJob)
    }

    /// Folder templates are sanitised **per path component**: split on `/` first, then
    /// render, or the separator itself would be scrubbed to a dash.
    private var folderPreview: String {
        let context = previewContext
        let components = folderTemplate.split(separator: "/", omittingEmptySubsequences: true)
        let rendered = components
            .map { RenameTemplate.render(String($0), context: context, seq: 1) }
            .filter { !$0.isEmpty }
        return rendered.joined(separator: "/")
    }

    private var renamedBasename: String {
        guard renameEnabled else {
            return files.first.map { $0.id.deletingPathExtension().lastPathComponent }
                ?? "DSCF0001"
        }
        return RenameTemplate.render(renameTemplate, context: previewContext, seq: 1)
    }

    private var pathPreview: String {
        let ext = files.first.map { $0.fileExtension } ?? "RAF"
        let filename = ext.isEmpty ? renamedBasename : renamedBasename + "." + ext
        var parts: [String] = []
        if let primary = primaryDestination {
            parts.append(primary.path)
        } else {
            parts.append("<destination>")
        }
        let folder = folderPreview
        if !folder.isEmpty { parts.append(folder) }
        parts.append(filename)
        return parts.joined(separator: "/")
    }

    // MARK: Source scanning

    private func refreshVolumes() {
        volumes = ingestMountedVolumes()
        if sourceURL == nil, let card = volumes.first(where: { ingestLooksLikeCard($0) }) {
            chooseSource(card)
        }
    }

    private func chooseSource(_ url: URL) {
        sourceURL = url
        files = []
        isScanning = true
        statusLine = nil
        let extensions = AppState.browsableExtensions
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                ingestScan(root: url, extensions: extensions)
            }.value
            self.files = found
            self.isScanning = false
        }
    }

    private func browseForSource() {
        if let url = ingestChooseDirectory(prompt: "Use as Source") { chooseSource(url) }
    }

    private func browseForPrimary() {
        if let url = ingestChooseDirectory(prompt: "Ingest Here") { primaryDestination = url }
    }

    private func browseForBackup() {
        if let url = ingestChooseDirectory(prompt: "Back Up Here") { backupDestination = url }
    }

    // MARK: Start

    private func start() {
        guard let primary = primaryDestination else {
            statusLine = "Choose a primary destination first."
            return
        }
        let request = IngestRequest(
            files: files,
            primaryDestination: primary,
            backupDestination: backupEnabled ? backupDestination : nil,
            folderTemplate: folderTemplate,
            renameTemplate: renameTemplate,
            renameEnabled: renameEnabled,
            jobName: jobName.trimmingCharacters(in: .whitespaces),
            verify: verify,
            ejectWhenDone: ejectWhenDone)

        switch driver.start(request) {
        case .started:
            statusLine = "Ingest running — the contact sheet fills as frames verify."
        case .refused(let reason):
            statusLine = reason
        }
    }
}

// MARK: - Filesystem helpers (off the view, so they stay nonisolated)

private func ingestMountedVolumes() -> [URL] {
    let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRemovableKey]
    let mounted = FileManager.default.mountedVolumeURLs(
        includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
    return mounted
}

private func ingestVolumeLabel(_ url: URL) -> String {
    let values = try? url.resourceValues(forKeys: [.volumeNameKey])
    let name = values?.volumeName ?? url.lastPathComponent
    return ingestLooksLikeCard(url) ? name + "  (DCIM)" : name
}

/// The DCIM heuristic: a directory named DCIM at the volume root means "camera card".
private func ingestLooksLikeCard(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    let dcim = url.appendingPathComponent("DCIM", isDirectory: true)
    let exists = FileManager.default.fileExists(atPath: dcim.path, isDirectory: &isDirectory)
    return exists && isDirectory.boolValue
}

private func ingestScan(root: URL, extensions: Set<String>) -> [IngestPlanFile] {
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
    guard let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
    var found: [IngestPlanFile] = []
    for case let file as URL in enumerator {
        guard extensions.contains(file.pathExtension.lowercased()) else { continue }
        let values = try? file.resourceValues(forKeys: [.fileSizeKey])
        let size = Int64(values?.fileSize ?? 0)
        found.append(IngestPlanFile(id: file, byteSize: size))
    }
    return found.sorted {
        $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
    }
}

private func ingestCreationDate(of url: URL) -> Date? {
    let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
    return values?.creationDate ?? values?.contentModificationDate
}

private func ingestByteString(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

@MainActor
private func ingestChooseDirectory(prompt: String) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = prompt
    guard panel.runModal() == .OK else { return nil }
    return panel.url
}

// MARK: - Small pieces

private struct IngestFieldRow<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Lumen.secondaryText)
                .frame(width: Lumen.labelWidth, alignment: .leading)
                .lineLimit(1)
            content
            Spacer(minLength: 0)
        }
        .frame(minHeight: Lumen.rowHeight)
    }
}

private struct IngestTextEntry: View {
    @Binding var text: String
    var placeholder: String = ""
    var monospaced: Bool = false

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 11, design: monospaced ? .monospaced : .default))
            .foregroundStyle(Lumen.primaryText)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(Lumen.controlBackground)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .frame(maxWidth: 340)
    }
}

private struct IngestNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(Lumen.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
            .padding(.bottom, 4)
    }
}

#endif
