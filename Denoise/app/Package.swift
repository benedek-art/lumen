// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LumenDenoise",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "LumenDenoise", path: "Sources/LumenDenoise")]
)
