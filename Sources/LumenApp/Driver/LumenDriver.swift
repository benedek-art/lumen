// LumenDriver.swift
// In-app automation: with LUMEN_DRIVER=<scenario.json> the app opens a fixture folder
// against a throwaway catalog, runs the scenario's steps as synthesized user input,
// writes what it observed to LUMEN_DRIVER_OUT and exits. Without the variable nothing
// here runs. Format and usage: driver/README.md.

#if os(macOS)

import AppKit
import LumenCore
import SwiftUI

enum LumenDriver {

    static let scenarioPath: String? = {
        guard let value = ProcessInfo.processInfo.environment["LUMEN_DRIVER"],
              !value.isEmpty else { return nil }
        return value
    }()

    static var isActive: Bool { scenarioPath != nil }

    /// The app's state: the owner's catalog normally, a temporary one under the driver.
    @MainActor
    static func makeAppState() -> AppState {
        guard isActive else { return AppState() }
        // A scenario starts from the app's defaults. Only the driver's own bundle, so a
        // driver run of the real app never clears the owner's preferences.
        if let domain = Bundle.main.bundleIdentifier, domain.hasSuffix(".driver") {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-driver-\(UUID().uuidString)", isDirectory: true)
        let catalog = root.appendingPathComponent("catalog", isDirectory: true)
        let previews = root.appendingPathComponent("previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: catalog,
                                                 withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: previews,
                                                 withIntermediateDirectories: true)
        let previewDirectory: URL? = previews
        return AppState(catalogDirectory: { catalog },
                        previewDirectory: { previewDirectory })
    }

    @MainActor private static var session: DriverSession?

    @MainActor
    static func start(_ state: AppState) {
        guard isActive, session == nil, let path = scenarioPath else { return }
        let session = DriverSession(state: state, scenarioPath: path)
        self.session = session
        Task { @MainActor in
            await session.run()
        }
    }

    /// Called by the loupe's render model each time it puts a frame on screen.
    @MainActor
    static func frameApplied(_ result: RenderResult, recipe: Recipe, model: AnyObject) {
        guard let session else { return }
        session.noteFrame(result, recipe: recipe, model: model)
    }

    /// The app's own interaction stamps (`LatencyHUD`), as `tl` rows.
    @MainActor
    static func noteTimeline(_ stamp: InteractionTimeline.Stamp) {
        guard session != nil else { return }
        var row: [String: Any] = ["stage": stamp.kind.rawValue, "rev": stamp.revision]
        if let draft = stamp.draft { row["draft"] = draft }
        if let edge = stamp.longEdge { row["edge"] = edge }
        if let ms = stamp.renderMilliseconds { row["ms"] = ms }
        if let lane = stamp.laneMilliseconds { row["lane"] = lane }
        if let name = stamp.name { row["name"] = name }
        if let main = stamp.mainMilliseconds { row["main"] = main }
        DriverTimeline.shared.add("tl", row,
                                  at: Double(stamp.nanoseconds &- DriverClock.zero) / 1e9)
    }
}

#endif
