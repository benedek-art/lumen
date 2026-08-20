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
        .target(
            name: "LumenCore",
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
    ]
)
