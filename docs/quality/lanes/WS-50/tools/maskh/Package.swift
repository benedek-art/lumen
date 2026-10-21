// swift-tools-version:6.0
import PackageDescription
let package = Package(
    name: "maskh",
    dependencies: [.package(path: "../../../../../..")],
    targets: [.executableTarget(name: "maskh",
        dependencies: [.product(name: "LumenCore", package: "lumen")],
        swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-Ounchecked"])])]
)
