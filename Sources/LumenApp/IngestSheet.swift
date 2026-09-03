// IngestSheet.swift
// Verified ingest (D38, docs/02 §7) as ONE screen: source, files, primary and backup
// destinations, folder and filename templates with live previews, verify, start. No
// wizard, no pages — insert a card, glance at the previews, press Return.
//
// The copy engine is NOT here. It is `VerifiedCopyDriver` in LumenCore, behind the
// `IngestDriver` seam below, and it is there rather than here for one reason: the part
// of this app that moves the only copy of somebody's wedding has to be testable on a
// machine with no Core Image, no SwiftUI and no card reader in it. This file is the
// screen — it scans, it plans, it previews, it starts the engine, and it reports what
// the engine says, verbatim.
//
// One piece of honesty is built into this file rather than papered over:
//
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

enum IngestRunOutcome: Sendable {
    /// Nothing was attempted, and why — shown verbatim, never paraphrased into
    /// "something went wrong".
    case refused(String)
    /// The engine ran. What it did — including every frame that failed and why — is in
    /// the report.
    case finished(IngestReport)
}

/// The seam the copy engine lands behind. One method, because a copy that takes twenty
/// minutes needs exactly two things the old "did it start" shape could not carry: a way
/// to say how far it has got, and a way to be stopped.
protocol IngestDriver: Sendable {
    func run(_ request: IngestRequest,
             cancellation: IngestCancellation,
             progress: @escaping @Sendable (IngestProgress) -> Void) async -> IngestRunOutcome
}

/// The real one. `IngestPlanner` turns the sheet's templates into the exact paths that
/// will be written, `VerifiedCopyDriver` streams the bytes and reads every landed file
/// back, and this adapts the sheet's request to both.
///
/// It refuses instead of copying in the two cases where copying is worse than stopping:
/// nothing to copy, and a backup destination that IS the primary destination — which is
/// not a second copy of anything, and would spend the whole ingest writing
/// `DSCF0001-1.RAF` beside every frame it had just written.
struct VerifiedCopyIngestDriver: IngestDriver {

    func run(_ request: IngestRequest,
             cancellation: IngestCancellation,
             progress: @escaping @Sendable (IngestProgress) -> Void) async -> IngestRunOutcome {
        guard !request.files.isEmpty else {
            return .refused("Nothing was copied: there are no frames to copy.")
        }
        var roots = [IngestDestinationRoot(url: request.primaryDestination, role: .primary)]
        if let backup = request.backupDestination {
            guard backup.standardizedFileURL != request.primaryDestination.standardizedFileURL
            else {
                return .refused("Nothing was copied: the backup destination is the primary "
                                + "destination. A second copy has to be a second volume.")
            }
            roots.append(IngestDestinationRoot(url: backup, role: .backup))
        }
        // The date the templates date-stamp with. Read here rather than in the engine so
        // a plan is a pure function of its inputs — and read from the same place the
        // preview reads it, so the path previewed is the path written.
        let sources = request.files.map { file in
            IngestSourceFile(url: file.url, byteCount: file.byteSize,
                             captureDate: ingestCreationDate(of: file.url) ?? Date())
        }
        let plan = IngestPlanner.plan(sources: sources,
                                      destinations: roots,
                                      folderTemplate: request.folderTemplate,
                                      renameTemplate: request.renameEnabled
                                          ? request.renameTemplate : nil,
                                      job: request.jobName.isEmpty ? nil : request.jobName,
                                      calendar: Calendar.current)
        guard !plan.copies.isEmpty else {
            return .refused("Nothing was copied: "
                            + (plan.refusals.first ?? "the plan named no file to write."))
        }
        let driver = VerifiedCopyDriver(verify: request.verify)
        // Off the main thread: this is a card being drained, not a UI update. The
        // progress callback arrives on that thread and hops back on its own.
        let report = await Task.detached(priority: .userInitiated) {
            driver.run(plan, cancellation: cancellation, progress: progress)
        }.value
        return .finished(report)
    }
}

// MARK: - Sheet

@MainActor
struct IngestSheet: View {
    @Environment(\.dismiss) private var dismiss: DismissAction

    let driver: any IngestDriver

    init(driver: any IngestDriver = VerifiedCopyIngestDriver()) {
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

    // The run
    @State private var isRunning: Bool = false
    @State private var runProgress: IngestProgress? = nil
    @State private var lastReport: IngestReport? = nil
    @State private var cancellation: IngestCancellation? = nil
    /// Latched separately from the token so the button can say "Stopping…" the instant
    /// it is pressed, rather than at the next chunk boundary.
    @State private var stopRequested: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Lumen.separator)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    failureBanner
                    sourceSection
                    destinationSection
                    templateSection
                    protocolSection
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            // docs/30: every scroll view in the app is silent. A legacy scroller insets
            // its content, so an indicator appearing is a relayout of everything inside it.
            .scrollIndicators(.never)
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
                .font(.lumenTitle)
                .foregroundStyle(Lumen.primaryText)
            Spacer()
            // Closing is not stopping, and it must not silently become stopping: a card
            // half drained is the one state this sheet exists to prevent. So Close puts
            // the sheet away and the copy carries on, and the tooltip says so rather
            // than leaving a photographer to find out by looking at the destination.
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .help(isRunning
                      ? "Puts this sheet away. The copy carries on — press Stop first if "
                        + "you meant to stop it."
                      : "Put this sheet away")
        }
        .padding(14)
    }

    /// The frames the last run did not land, by name.
    ///
    /// The status line carries the one-sentence summary; this carries the list, because
    /// "3 failed" is not something a photographer standing at a card reader can act on
    /// and "DSCF0417.RAF → backup: could not be written to the destination: No space
    /// left on device" is.
    @ViewBuilder
    private var failureBanner: some View {
        if !failureLines.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(failureLines.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "xmark.octagon")
                            .font(.lumenGlyphCaption)
                        Text(failureLines[index])
                            .font(.lumenCaption)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Lumen.primaryText)
                }
            }
            .padding(8)
            .background(Lumen.controlBackground)
            .clipShape(RoundedRectangle(cornerRadius: Lumen.radiusControl))
            .padding(.bottom, 6)
        }
    }

    /// Capped, and the cap is counted out loud: a card whose every frame failed would
    /// otherwise push the whole sheet off the screen.
    private var failureLines: [String] {
        guard let report = lastReport else { return [] }
        var lines = report.failures.prefix(8).map {
            $0.label + ": " + ($0.failure?.message ?? "")
        }
        if report.failures.count > 8 {
            lines.append("+ \(report.failures.count - 8) more frames failed.")
        }
        lines.append(contentsOf: report.refusals.prefix(4))
        return lines
    }

    // MARK: Source

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Source")
            IngestFieldRow("Volume") {
                // THE NAME, NOT THE PATH. The old trigger printed the whole POSIX path
                // head-truncated — "…/Volumes/EOS_R5/DCIM" — because an `NSPopUpButton`
                // will happily print a hundred characters and let the truncation sort
                // it out. What a photographer identifies a card by is its name, so the
                // trigger says that and the tooltip carries the path in full, which is
                // the only place the path was ever actually read.
                LumenMenu(title: sourceURL?.lastPathComponent
                              ?? "Choose a card or folder",
                          symbol: sourceSymbol,
                          minWidth: 220,
                          help: sourceURL?.path
                              ?? "The card or folder these frames are copied from") {
                    ForEach(volumes, id: \.self) { volume in
                        // "(DCIM)" was inside the name; it is an annotation about the
                        // volume rather than part of what it is called, so it sits in
                        // the annotation column where the eye can skip it — and the
                        // card gets the card glyph, which is faster than either.
                        LumenMenuItem(title: ingestVolumeName(volume),
                                      symbol: ingestLooksLikeCard(volume)
                                          ? "sdcard" : "externaldrive",
                                      detail: ingestLooksLikeCard(volume)
                                          ? "DCIM" : nil,
                                      isSelected: volume == sourceURL) {
                            chooseSource(volume)
                        }
                    }
                    if volumes.isEmpty {
                        LumenMenuItem(title: "No mounted volumes found",
                                      symbol: "exclamationmark.triangle",
                                      isEnabled: false) {}
                    }
                    LumenMenuDivider()
                    LumenMenuItem(title: "Rescan volumes",
                                  symbol: "arrow.clockwise") { refreshVolumes() }
                    LumenMenuItem(title: "Choose Folder…",
                                  symbol: "folder") { browseForSource() }
                }
            }

            HStack(spacing: 6) {
                Text("Files")
                    .font(.lumenBody)
                    .foregroundStyle(Lumen.secondaryText)
                    .frame(width: Lumen.labelWidth, alignment: .leading)
                Text(fileCountSummary)
                    .font(.lumenBody)
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
                                .font(.lumenCaptionNumeric)
                                .foregroundStyle(Lumen.primaryText)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(ingestByteString(file.byteSize))
                                .font(.lumenCaptionNumeric)
                                .foregroundStyle(Lumen.secondaryText)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                    }
                }
                .padding(.vertical, 4)
            }
            // docs/30: every scroll view in the app is silent. A legacy scroller insets
            // its content, so an indicator appearing is a relayout of everything inside it.
            .scrollIndicators(.never)
            .frame(height: 120)
            .background(Lumen.controlBackground)
            .clipShape(RoundedRectangle(cornerRadius: Lumen.radiusControl))
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
                        .font(.lumenBody)
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
                            .font(.lumenBody)
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
                    .font(.lumenNumeric)
                    .foregroundStyle(Lumen.primaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !templateProblems.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(templateProblems, id: \.self) { problem in
                        HStack(alignment: .top, spacing: 5) {
                            Image(systemName: "xmark.octagon")
                                .font(.lumenGlyphCaption)
                            Text(problem)
                                .font(.lumenCaption)
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
                .clipShape(RoundedRectangle(cornerRadius: Lumen.radiusControl))
                .padding(.vertical, 4)
            }

            IngestNote("Tokens: " + Self.tokenList
                       + ". A width form is written {seq:4}, not {seq4}. Unknown tokens are "
                       + "an error here rather than an empty stretch in a delivered filename.")
            // This note used to promise that {camera}, {serial} and {iso} "resolve from
            // EXIF during the copy". Nothing reads EXIF yet, and now that the copy is
            // real that sentence would have been a lie about a delivered filename
            // rather than a promise about a preview — so it says what actually happens.
            IngestNote("Dates come from each file's creation date. {camera}, {serial} and "
                       + "{iso} are not read yet: they render empty here AND in the copy, so "
                       + "a template using one produces a name with a gap in it.")
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
            if isRunning {
                VStack(alignment: .leading, spacing: 3) {
                    LumenProgressBar(value: runProgress?.fraction ?? 0)
                    HStack(spacing: 8) {
                        Text(progressCaption)
                            .font(.lumenCaption)
                            .foregroundStyle(Lumen.secondaryText)
                        Spacer(minLength: 0)
                        // THE WAY OUT, and deliberately NOT ⎋: this sheet's Close is
                        // already ⎋, and a photographer putting a dialog away must not
                        // thereby stop a card halfway through draining. Stopping is
                        // also safe — the frame in flight is discarded rather than left
                        // half-written, so the destination afterwards holds exactly the
                        // frames that finished and verified.
                        Button(stopRequested ? "Stopping…" : "Stop") {
                            stopRequested = true
                            cancellation?.cancel()
                        }
                        .disabled(stopRequested)
                        .help("Stop after the frame being copied. Frames already "
                              + "verified are kept; the one in flight is discarded "
                              + "rather than left half-written.")
                    }
                }
            }
            if let statusLine {
                Text(statusLine)
                    .font(.lumenBody)
                    .foregroundStyle(Lumen.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Text(readinessSummary)
                    .font(.lumenBody)
                    .foregroundStyle(canStart ? Lumen.primaryText : Lumen.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Ingest") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
                    .help("Copy every frame to every destination, read each copy back, "
                          + "and report anything that did not match")
            }
        }
        .padding(14)
    }

    /// What the caption under the bar says. Frames first, because frames are what a
    /// photographer is counting; bytes second, because they are what the time is.
    private var progressCaption: String {
        if stopRequested { return "Stopping — the frame in flight is being discarded" }
        guard let progress = runProgress else { return "Starting…" }
        let name = progress.currentFile.map { " · " + $0 } ?? ""
        return "\(progress.filesCompleted) of \(progress.filesTotal) frames · "
            + ingestByteString(progress.bytesCopied) + " of "
            + ingestByteString(progress.bytesTotal) + name
    }

    private var canStart: Bool {
        !isRunning
            && !files.isEmpty
            && primaryDestination != nil
            && (!backupEnabled || backupDestination != nil)
            && templateProblems.isEmpty
    }

    private var readinessSummary: String {
        if isRunning { return "Copying — leave the card in the reader." }
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
    ///
    /// Through `IngestPlanner`, which is the same call the copy makes. A preview that
    /// renders a path one way while the engine writes it another is a lie told in the
    /// one place a photographer looks before pressing Return, so there is exactly one
    /// implementation and this is a call to it.
    private var folderPreview: String {
        IngestPlanner.folderComponents(template: folderTemplate,
                                       context: previewContext,
                                       seq: 1).joined(separator: "/")
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

    /// The trigger's glyph: what the chosen source IS, or the shape of the thing you
    /// are being asked to choose while there is nothing chosen. A card and a folder are
    /// different objects to a photographer standing at a reader, and the DCIM
    /// heuristic already knows which one this is.
    private var sourceSymbol: String {
        guard let url = sourceURL else { return "externaldrive" }
        return ingestLooksLikeCard(url) ? "sdcard" : "folder"
    }

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
        guard !isRunning else { return }
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

        let token = IngestCancellation()
        cancellation = token
        stopRequested = false
        isRunning = true
        runProgress = nil
        lastReport = nil
        statusLine = nil
        // Captured now rather than read at the end: the run outlives the toggles, and
        // what the photographer asked for when they pressed Ingest is what should
        // happen when it lands — not whatever the checkbox says twenty minutes later.
        let ejectWanted = ejectWhenDone
        let card = sourceURL

        Task {
            let outcome = await driver.run(request, cancellation: token, progress: { progress in
                // The engine reports from the copy thread. `@State` is main-actor
                // storage, so the hop is explicit.
                Task { @MainActor in self.runProgress = progress }
            })
            self.isRunning = false
            self.cancellation = nil
            self.stopRequested = false
            self.runProgress = nil
            switch outcome {
            case .refused(let reason):
                self.lastReport = nil
                self.statusLine = reason
            case .finished(let report):
                self.lastReport = report
                self.statusLine = report.summary
                    + ingestEjectNote(report, wanted: ejectWanted, source: card)
            }
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

/// What the volume calls itself. The DCIM mark used to be glued on the end of this
/// string; the menu draws it in its own annotation column now, so the name comes back
/// as a name.
private func ingestVolumeName(_ url: URL) -> String {
    let values = try? url.resourceValues(forKeys: [.volumeNameKey])
    return values?.volumeName ?? url.lastPathComponent
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

/// Eject, on the one condition docs/10 §10.7 allows: every frame proven on every
/// destination. Anything less and the card is still the only copy of something, so a
/// run that was stopped, that failed a frame, or that refused one does not get to
/// unmount the evidence — and it says which of those happened rather than silently
/// leaving the card mounted.
///
/// Not `@MainActor`: it is called from the main actor, and `NSWorkspace` does not need
/// the annotation to get there. The card is also only ejected when it is REMOVABLE —
/// an ingest from a folder on the internal disk must not unmount the internal disk.
private func ingestEjectNote(_ report: IngestReport, wanted: Bool, source: URL?) -> String {
    guard wanted else { return "" }
    guard report.allVerified else {
        return " The card was NOT ejected: not every frame verified on every destination."
    }
    guard let source,
          let values = try? source.resourceValues(forKeys: [.volumeURLKey,
                                                            .volumeIsRemovableKey]),
          let volume = values.volume else { return "" }
    guard values.volumeIsRemovable == true else {
        return " \(volume.lastPathComponent) is not a removable volume, so it was left mounted."
    }
    do {
        try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
        return " \(volume.lastPathComponent) ejected."
    } catch {
        return " The card was not ejected: " + error.localizedDescription
    }
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
                .font(.lumenBody)
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
            .clipShape(RoundedRectangle(cornerRadius: Lumen.radiusChip))
            .frame(maxWidth: 340)
    }
}

private struct IngestNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.lumenCaption)
            .foregroundStyle(Lumen.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
            .padding(.bottom, 4)
    }
}

#endif
