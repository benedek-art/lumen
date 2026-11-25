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
}

#endif
