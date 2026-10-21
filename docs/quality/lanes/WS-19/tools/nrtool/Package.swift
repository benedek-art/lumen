// swift-tools-version:5.9
// nrtool: apply the shipped S3 engine (ClassicalDenoise, NoiseProfile.forISO, scale 1)
// to an .lfi. Usage: nrtool in.lfi out.lfi ISO [luma= chroma= hot= ld= lc= cd= cs= mode=off]
// Unset sliders take ISODefaults.classic(forISO:). Prints the resolved block and
// sigma(0.18) of the profile to stderr.
import PackageDescription
let package = Package(name: "nrtool", platforms: [.macOS(.v14)],
  dependencies: [.package(path: "../../../../../..")],
  targets: [.executableTarget(name: "nrtool", dependencies: [.product(name: "LumenCore", package: "lumen")],
    swiftSettings: [.unsafeFlags(["-Ounchecked"])])])
