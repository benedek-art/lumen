// swift-tools-version:5.9
// WS-41 float probe: renders an .lfi through the CPU reference WITHOUT the 8-bit PNG,
// so display hue can be measured with no rounding (SPEC Amendment A1, lines 17-19).
// Build: swift build -c release --package-path scripts/proof/ws41/probe \
//          --scratch-path /tmp/ws41-probe     (huefloat.py does this on first use)
import PackageDescription
let package = Package(name: "probe",
  dependencies: [.package(path: "../../../..")],
  targets: [.executableTarget(name: "probe",
                              dependencies: [.product(name: "LumenCore", package: "lumen")])])
