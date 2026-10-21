// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "solve",
  dependencies: [.package(path: "/home/user/lumen")],
  targets: [.executableTarget(name: "solve", dependencies: [.product(name: "LumenCore", package: "lumen")])])
