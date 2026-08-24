// swift-tools-version:6.0
// Lumen — a personal RAW photo editor for macOS.
//
// Target layout follows docs/13-architecture.md:
//   LumenCore     — no UI, no Apple-only frameworks. Recipe model, canonical JSON +
//                   fingerprints, curve/zone/mask reference math, XMP sidecars,
//                   catalog schema, ingest templates. Builds on macOS and Linux
//                   (Linux is used for CI-style verification of the pure core).
//   LumenPipeline — the render path. Apple RAW stage wrapper, export. macOS-only
//                   (sources are `#if os(macOS)` so the target stays declarable).
//   LumenApp      — SwiftUI shell. macOS-only.
//
// On Linux, build/test only the core:  swift build --target LumenCore
//                                      swift test  --filter LumenCoreTests
import PackageDescription

let package = Package(
    name: "Lumen",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "LumenCore", targets: ["LumenCore"]),
        .executable(name: "LumenApp", targets: ["LumenApp"]),
    ],
    targets: [
        // Linux only in practice: on macOS the SDK's own SQLite3 module wins, and this
        // target simply provides one where the platform does not. It exists so
        // `canImport(SQLite3)` is true on the local lane, which is what puts the
        // catalog and its tests under a compiler outside CI.
        .systemLibrary(name: "CSQLite3", path: "Sources/CSQLite3"),
        .target(
            name: "LumenCore",
            dependencies: [
                // Linux only. macOS has SQLite3 in the SDK; without this, Linux does
                // not, so `canImport(SQLite3)` was false and the entire catalog — plus
                // every test of it — compiled out of the local lane while `swift test`
                // reported green.
                .target(name: "CSQLite3", condition: .when(platforms: [.linux])),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "LumenPipeline",
            dependencies: ["LumenCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "LumenApp",
            dependencies: ["LumenCore", "LumenPipeline"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "LumenCoreTests",
            dependencies: ["LumenCore"],
            // The evidence sheets are OUTPUT, not input: the proof run writes them for a
            // human to look at (docs/20), they are gitignored, and SwiftPM would
            // otherwise warn once per PNG about files it does not know what to do with.
            exclude: ["Proof/evidence"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The GPU path's goldens. These RUN on the macOS CI runner: they compile every
        // kernel, render synthetic frames through the real Core Image graph, and
        // compare against the f32 reference in LumenCore. A shader that drifts from
        // its reference fails here rather than in someone's photographs.
        .testTarget(
            name: "LumenPipelineTests",
            dependencies: ["LumenCore", "LumenPipeline"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The app layer's tests — the target docs/21 pattern 6 said was missing while
        // 39% of the codebase went unfalsifiable by construction. Files are
        // `#if os(macOS)` like LumenPipelineTests', so the Linux lanes build an empty
        // target and lose nothing. Tests here exercise pure app logic (counts, keys,
        // gesture bookkeeping) — never a full `AppState`, whose init opens the real
        // catalog in Application Support.
        .testTarget(
            name: "LumenAppTests",
            dependencies: ["LumenApp", "LumenCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
