// swift-tools-version:6.0
// WS-16 stage probe: runs the S9 finish pass (Vibrance/Saturation/Density/Protect Skin,
// Black & White) alone, through ColorEngine (Double oracle) and ExactColorStage (the Float
// twin ReferenceRenderer and the GPU run). Depends on LumenCore at the repository root.
// Build:  (cd docs/quality/lanes/WS-16/measure/probe && swift build -c release)
import PackageDescription
let package = Package(name: "ws16probe", platforms: [.macOS(.v15)],
  dependencies: [.package(path: "../../../../../..")],
  targets: [.executableTarget(name: "ws16probe",
    dependencies: [.product(name: "LumenCore", package: "lumen")],
    swiftSettings: [.swiftLanguageMode(.v5)])])
