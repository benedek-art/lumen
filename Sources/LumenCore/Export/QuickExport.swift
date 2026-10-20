// QuickExport.swift
// Export with Previous (Lightroom's ⌥⇧⌘E) and the post-export reveal, as decisions.
//
// The app layer owns the folder panel, `NSWorkspace` and `UserDefaults`; what lives here
// is what it decides with them: whether a no-dialog re-export can run or has to fall back
// to the sheet, what the status line says about it, and which paths a "show in Finder"
// should select. All of it is pure so it is tested on Linux, where LumenApp never builds.
//
// The RECIPES are not remembered here. Their checkboxes already persist with the recipes
// themselves (`AppState.exportRecipes`), and the sheet is where they change, so the
// checked set at the moment of ⌥⇧⌘E IS "the previous export's recipes" unless the
// photographer changed it since — which the plan notices and the status line says.

import Foundation

/// What Lumen keeps of the last export run: where it went, with which recipes, and what
/// it wrote. Stored as JSON in `UserDefaults` under `QuickExport.lastExportDefaultsKey`.
///
/// A plain path rather than a bookmark: the app ships with no sandbox entitlement, so the
/// path is what carries access (the same reasoning as `AppState.lastFolderFilesKey`).
public struct LastExport: Codable, Equatable, Sendable {
    public var directoryPath: String
    public var recipeIDs: [String]
    public var recipeNames: [String]
    /// How many files the run actually delivered.
    public var deliveredCount: Int
    /// What "Show Last Export in Finder" selects — `QuickExport.revealTargets`, computed
    /// once at the end of the run so a 1,200-file delivery does not store 1,200 paths.
    public var revealPaths: [String]
    public var finishedAt: Date

    public init(directoryPath: String, recipeIDs: [String], recipeNames: [String],
                deliveredCount: Int, revealPaths: [String], finishedAt: Date) {
        self.directoryPath = directoryPath
        self.recipeIDs = recipeIDs
        self.recipeNames = recipeNames
        self.deliveredCount = deliveredCount
        self.revealPaths = revealPaths
        self.finishedAt = finishedAt
    }

    /// Builds the memory from a finished run's report. Only `.delivered` records with a
    /// confirmed `actualDestination` count: a skipped file was already there and a failed
    /// one never landed.
    public init(directory: String, recipes: [ExportRecipe], report: OperationReport,
                finishedAt: Date = Date()) {
        let delivered = QuickExport.deliveredPaths(in: report)
        self.init(directoryPath: directory,
                  recipeIDs: recipes.map(\.id),
                  recipeNames: recipes.map(\.name),
                  deliveredCount: delivered.count,
                  revealPaths: QuickExport.revealTargets(deliveredPaths: delivered,
                                                         directoryPath: directory),
                  finishedAt: finishedAt)
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// Nil for missing or unreadable data — the caller treats that as "no previous
    /// export", which falls back to the sheet rather than failing.
    public static func decode(_ data: Data?) -> LastExport? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(LastExport.self, from: data)
    }
}

public enum QuickExport {

    public static let lastExportDefaultsKey = "lumen.export.last"
    /// The sheet's "Show in Finder when done" checkbox. Global, not per recipe: one run
    /// writes every checked recipe, and it should reveal once.
    public static let revealWhenDoneDefaultsKey = "lumen.export.revealWhenDone"

    /// Above this many delivered files the reveal selects their folders instead: Finder
    /// selecting hundreds of items is slow and shows nothing useful a folder would not.
    public static let revealFileLimit = 100

    /// What ⌥⇧⌘E does.
    public enum Plan: Equatable, Sendable {
        /// Export the selection to `directory` with the checked recipes, no dialog.
        case run(directory: String, message: String)
        /// Something only the sheet can resolve — no folder yet, the folder is gone, no
        /// recipe checked. The message says which.
        case openSheet(message: String)
        /// Nothing to do and nothing the sheet would fix; say why in the status bar.
        case refuse(message: String)
    }

    /// - Parameters:
    ///   - recipes: the full recipe list; only checked ones are exported.
    ///   - targetCount: photos the export would act on (selection, else the primary).
    ///   - directoryExists: whether a path is an existing folder, injected for tests.
    public static func plan(last: LastExport?, recipes: [ExportRecipe], targetCount: Int,
                            isExporting: Bool,
                            directoryExists: (String) -> Bool) -> Plan {
        if isExporting {
            return .refuse(message: "An export is already running — ⌘E shows its progress")
        }
        guard targetCount > 0 else {
            return .refuse(message: "Select photos to export")
        }
        guard let last else {
            return .openSheet(message: "No previous export yet — choose a folder once "
                              + "and Export with Previous will reuse it")
        }
        let folderName = (last.directoryPath as NSString).lastPathComponent
        guard directoryExists(last.directoryPath) else {
            return .openSheet(message: "The last export folder “\(folderName)” is not "
                              + "there any more — choose another")
        }
        let active = recipes.filter(\.enabled)
        guard !active.isEmpty else {
            return .openSheet(message: "No recipe is checked — check one to export")
        }
        let changed = Set(active.map(\.id)) != Set(last.recipeIDs)
        let recipeCount = active.count == 1 ? "1 recipe" : "\(active.count) recipes"
        let photoCount = targetCount == 1 ? "1 photo" : "\(targetCount) photos"
        let message = "Exporting \(photoCount) to “\(folderName)” with \(recipeCount)"
            + (changed ? " (checked recipes changed since the last export)" : "")
            + " — ⌘E shows progress"
        return .run(directory: last.directoryPath, message: message)
    }

    /// Delivered paths from a report, in run order, without duplicates.
    public static func deliveredPaths(in report: OperationReport) -> [String] {
        var seen: Set<String> = []
        var paths: [String] = []
        for record in report.records where record.outcome == .delivered {
            guard let path = record.actualDestination, seen.insert(path).inserted else {
                continue
            }
            paths.append(path)
        }
        return paths
    }

    /// What a reveal should select: the files themselves up to `limit`, their distinct
    /// folders above it (recipes with subfolders give several), and the export folder
    /// when nothing was delivered at all.
    public static func revealTargets(deliveredPaths: [String], directoryPath: String?,
                                     limit: Int = revealFileLimit) -> [String] {
        var seen: Set<String> = []
        let unique = deliveredPaths.filter { seen.insert($0).inserted }
        if unique.isEmpty {
            return directoryPath.map { [$0] } ?? []
        }
        if unique.count <= limit { return unique }
        var folders: [String] = []
        var seenFolders: Set<String> = []
        for path in unique {
            let folder = (path as NSString).deletingLastPathComponent
            if seenFolders.insert(folder).inserted { folders.append(folder) }
        }
        return folders
    }

    /// The remembered reveal paths that still exist; if none do, the export folder when
    /// it exists. Empty means there is nothing to show.
    public static func existingRevealTargets(_ last: LastExport,
                                             exists: (String) -> Bool) -> [String] {
        let present = last.revealPaths.filter(exists)
        if !present.isEmpty { return present }
        return exists(last.directoryPath) ? [last.directoryPath] : []
    }
}
