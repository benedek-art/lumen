// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "IngestHarness",
    dependencies: [.package(path: "/home/user/lumen/.claude/worktrees/test-ingest")],
    targets: [
        .executableTarget(name: "IngestHarness",
            dependencies: [.product(name: "LumenCore", package: "test-ingest")]),
        .executableTarget(name: "CatalogHarness",
            dependencies: [.product(name: "LumenCore", package: "test-ingest")]),
    ]
)
