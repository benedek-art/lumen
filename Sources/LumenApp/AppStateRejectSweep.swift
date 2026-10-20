// AppStateRejectSweep.swift
// Photo ▸ Move Rejected Photos… (⌘⌫) and Remove Rejected from Catalog….
//
// The plan — which files go, what they are called, what the confirmation says and what
// the report records — is `RejectSweep` in LumenCore, where it is tested. This file asks,
// moves, and tells the catalog and the roll. Nothing here deletes a file: originals and
// sidecars go into `_Rejected` beside them or to the Trash, and Finder can put either back.

#if os(macOS)
import AppKit
import Foundation
import LumenCore

/// State the sweep needs and `AppState` has no stored property for (extensions cannot
/// add one): a re-entry guard, and the menu's text-field carve-out.
@MainActor
enum RejectSweepGate {
    static var running = false

    /// ⌘⌫ in a text field is "delete to the start of the line", and a menu key
    /// equivalent is offered before the field sees it — the same carve-out
    /// `TextEditingFocus` makes for ⌘C/⌘V. True when the field took the chord.
    static func giveChordToTextField() -> Bool {
        guard TextEditingFocus.isActive else { return false }
        return NSApp.sendAction(#selector(NSTextView.deleteToBeginningOfLine(_:)),
                                to: nil, from: nil)
    }
}

extension AppState {

    /// Every rejected photo in the open roll, whatever the filter is showing — the
    /// count a photographer sees on the Rejected chip.
    private var rejectedItems: [PhotoItem] {
        allPhotos.filter { $0.flag == .reject }
    }

    private func sweepIsBlocked() -> Bool {
        guard catalog != nil, !isExporting, !isScanning, !isRelinkingOriginal,
              !RejectSweepGate.running else {
            statusMessage = "Finish the active export, scan or relink before moving rejected photos."
            return true
        }
        return false
    }

    /// ⌘⌫. Counts, asks, then moves every rejected photo and its sidecars.
    func sweepRejectedPhotos() {
        guard !sweepIsBlocked(), let catalog else { return }
        guard !rejectedItems.isEmpty else {
            statusMessage = "No photos in this folder are flagged rejected."
            return
        }
        sliderGesture(active: false)
        RejectSweepGate.running = true
        statusMessage = "Preparing to move rejected photos…"
        let folder = folderURL
        Task {
            defer { RejectSweepGate.running = false }
            // Sidecars first, so each one carries its latest flag and recipe when it
            // moves and no later flush writes a new one at the old path.
            await catalog.flushSidecarsNow()
            guard folderURL == folder, !isScanning else {
                statusMessage = "The folder changed; nothing was moved."
                return
            }
            // Read after the flush: a flag changed while it ran is honoured.
            let items = rejectedItems
            let candidates = sweepCandidates(items, catalog: catalog)
            let folderPlan = RejectSweep.plan(candidates, into: .rejectedFolder,
                                              listing: Self.directoryNames,
                                              bareSidecarOwner: Self.sidecarOwner)
            guard !folderPlan.isEmpty else {
                statusMessage = "None of the rejected photos can be moved: "
                    + (folderPlan.skipped.first?.reason ?? "their originals are missing.")
                return
            }
            let alert = NSAlert()
            alert.messageText = "Move \(folderPlan.photoCount) rejected "
                + (folderPlan.photoCount == 1 ? "photo" : "photos") + " out of this folder?"
            alert.informativeText = RejectSweep.confirmationMessage(for: folderPlan)
                + "\n\nMove to Trash sends the same files to the Trash instead."
            alert.addButton(withTitle: "Move to _Rejected")
            alert.addButton(withTitle: "Move to Trash")
            alert.addButton(withTitle: "Cancel")
            let answer = alert.runModal()
            let plan: RejectSweep.Plan
            switch answer {
            case .alertFirstButtonReturn:
                plan = folderPlan
            case .alertSecondButtonReturn:
                plan = RejectSweep.plan(candidates, into: .trash, listing: Self.directoryNames,
                                        bareSidecarOwner: Self.sidecarOwner)
            default:
                statusMessage = nil
                return
            }
            await runSweep(plan, items: items, catalog: catalog)
        }
    }

    /// The moves happen here on the main actor, between the confirmation and the roll
    /// update, so no flag or edit can land on a frame halfway out of the folder. On one
    /// volume each move is a rename.
    private func runSweep(_ plan: RejectSweep.Plan, items: [PhotoItem],
                          catalog: CatalogService) async {
        let results = plan.groups.map { Self.move($0, disposition: plan.disposition) }

        var urlByPath: [String: URL] = [:]
        for item in items { urlByPath[item.id.standardizedFileURL.path] = item.id }
        var movedIDs: [Int64] = []
        var movedURLs: Set<URL> = []
        var failedPhotos = 0
        for (group, result) in zip(plan.groups, results) {
            if result.moved {
                movedIDs.append(contentsOf: group.photos.compactMap(\.photoID))
                for photo in group.photos {
                    movedURLs.insert(urlByPath[photo.url.path] ?? photo.url)
                }
            } else {
                failedPhotos += group.photos.count
            }
        }

        // Out of the roll BEFORE the await: the catalog cleanup yields the main actor,
        // and an edit landing on a moved photo then would write a sidecar at its old path.
        dropSweptPhotos(movedURLs)
        let removed = await catalog.removePhotos(ids: movedIDs)

        var report = OperationReport(kind: .rejects,
                                     records: RejectSweep.records(for: plan, results: results))
        for kept in plan.keptSidecars {
            report.issues.append("Left \(kept.path) in place: a photo that is not rejected shares it.")
        }
        if removed.count < movedIDs.count {
            report.issues.append("\(movedIDs.count - removed.count) moved photos are still "
                                 + "in the catalog and will show as missing.")
        }
        report.finish(.completed)
        await checkpointOperationReport(report)

        let place = plan.disposition == .trash ? "the Trash" : RejectSweep.folderName
        var message = "Moved \(movedURLs.count) rejected "
            + (movedURLs.count == 1 ? "photo" : "photos") + " to \(place)."
        let notMoved = failedPhotos + plan.skipped.count
        if notMoved > 0 {
            message += " \(notMoved) could not be moved — see Recent results."
        }
        statusMessage = message
    }

    /// One group, originals first. Any failure puts back what already moved, so a
    /// sidecar never ends up apart from its photograph.
    private nonisolated static func move(_ group: RejectSweep.Group,
                                         disposition: RejectSweep.Disposition) -> RejectSweep.GroupResult {
        let files = FileManager.default
        var done: [(from: URL, to: URL)] = []
        for step in group.moves {
            do {
                guard files.fileExists(atPath: step.source.path) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                switch disposition {
                case .rejectedFolder:
                    guard let destination = step.destination else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    try files.createDirectory(at: destination.deletingLastPathComponent(),
                                              withIntermediateDirectories: true)
                    // `moveItem` refuses an existing destination: never an overwrite.
                    try files.moveItem(at: step.source, to: destination)
                    done.append((from: step.source, to: destination))
                case .trash:
                    var resulting: NSURL?
                    try files.trashItem(at: step.source, resultingItemURL: &resulting)
                    done.append((from: step.source, to: resulting.map { $0 as URL } ?? step.source))
                }
            } catch {
                var stranded: [String] = []
                for back in done.reversed() {
                    do { try files.moveItem(at: back.to, to: back.from) }
                    catch { stranded.append(back.to.path) }
                }
                var reason = "\(step.source.lastPathComponent): \(error.localizedDescription)"
                if !stranded.isEmpty {
                    reason += " Could not put back: " + stranded.joined(separator: ", ")
                }
                return RejectSweep.GroupResult(moved: false, failure: reason)
            }
        }
        return RejectSweep.GroupResult(moved: true, landed: done.map { $0.to })
    }

    /// A frame whose sidecar write is still owed after the flush is skipped: once its
    /// catalog row goes, that write is the only copy of its latest flag and edits.
    private func sweepCandidates(_ items: [PhotoItem],
                                 catalog: CatalogService) -> [RejectSweep.SweepCandidate] {
        let owed = catalog.photosOwingSidecars()
        return items.map { item in
            let isOwed = owed.paths.contains(item.id.standardizedFileURL.path)
                || item.catalogID.map { owed.photoIDs.contains($0) } == true
            return RejectSweep.SweepCandidate(url: item.id, photoID: item.catalogID,
                                              isRejected: true, sidecarOwed: isOwed)
        }
    }

    /// The owner tag (`sourceExtension`) a bare sidecar records, if it can be read.
    nonisolated static func sidecarOwner(_ sidecar: URL) -> String? {
        (try? Data(contentsOf: sidecar)).flatMap { XMPSidecar.parse($0) }?.sourceExtension
    }

    /// A directory's file names, or none when it does not exist.
    nonisolated static func directoryNames(_ directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    /// Photo ▸ Remove Rejected from Catalog…. The files are not touched.
    func removeRejectedFromCatalog() {
        guard !sweepIsBlocked(), let catalog else { return }
        let items = rejectedItems.filter { $0.catalogID != nil }
        guard !items.isEmpty else {
            statusMessage = "No photos in this folder are flagged rejected."
            return
        }
        let alert = NSAlert()
        alert.messageText = "Remove \(items.count) rejected "
            + (items.count == 1 ? "photo" : "photos") + " from the catalog?"
        alert.informativeText = "Their files and sidecars stay in the folder, untouched. "
            + "Lumen lists them again the next time this folder is scanned, reading their "
            + "flags and edits back from the sidecars; to keep them out, use Move Rejected "
            + "Photos (⌘⌫) instead.\n\nAlbums, keywords, stacks, snapshots and history "
            + "kept only in the catalog are removed with them, and the undo history is cleared."
        alert.addButton(withTitle: "Remove from Catalog")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        sliderGesture(active: false)
        RejectSweepGate.running = true
        statusMessage = "Removing rejected photos from the catalog…"
        Task {
            defer { RejectSweepGate.running = false }
            // The sidecars are what bring flags and edits back on the next scan.
            await catalog.flushSidecarsNow()
            // A frame still owed a sidecar keeps its row: that row is then the only
            // record of its latest flag and edits.
            let owed = catalog.photosOwingSidecars()
            // Only frames still rejected after the flush: a flag may have changed.
            let stillRejected = Set(rejectedItems.map(\.id))
            var urlByID: [Int64: URL] = [:]
            var kept = 0
            for item in items where stillRejected.contains(item.id) {
                guard let id = item.catalogID else { continue }
                if owed.photoIDs.contains(id) || owed.paths.contains(item.id.standardizedFileURL.path) {
                    kept += 1
                } else {
                    urlByID[id] = item.id
                }
            }
            let removed = await catalog.removePhotos(ids: Array(urlByID.keys))
            dropSweptPhotos(Set(removed.compactMap { urlByID[$0] }))
            var message = "Removed \(removed.count) rejected "
                + (removed.count == 1 ? "photo" : "photos") + " from the catalog."
            let notRemoved = urlByID.count - removed.count + kept
            if notRemoved > 0 {
                message += " \(notRemoved) could not be removed"
                    + (kept > 0 ? " — their sidecars are not saved yet." : ".")
            }
            statusMessage = message
        }
    }
}
#endif
