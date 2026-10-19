# Portable execution provenance

Executed in isolated `lumen-mask-affine`, base `5d1ff3a9793a6ea6487dcf67a304f47bc438e0d1`. Compiler `/workspace/scratch/2982a056243e/swift/usr/bin/swiftc`: Swift version6.1.2 (`swift-6.1.2-RELEASE`), target `x86_64-unknown-linux-gnu`. Default compiler optimization (no `-O` flag). Runtime and linker environment used `SWIFT_BACKTRACE=enable=no`, `LD_LIBRARY_PATH` and `LIBRARY_PATH` both `/workspace/scratch/2982a056243e/swift-deps/usr/lib/x86_64-linux-gnu`. Test execution used `stdbuf -oL`. No older Core objects were linked in this brush witness.

The actual production helper was compiled directly into the XCTest executable. The sole production dependency was replaced with this exact shim:

```swift
enum Num { static func saturate(_ v: Double) -> Double { min(max(v,0),1) } }
```

The tests are the actual unchanged existing test file and the new source-metric file, removing only `@testable import LumenCore` because helper and tests were compiled together. The generator registers their18 actual XCTest methods. The mutant changes only `scaleX = sourceWidth / long` and `scaleY = sourceHeight / long` into `scaleX = 1` and `scaleY = 1`; its unused-local warning is expected. These tests qualify helper behavior, not actual AppState, SwiftUI event dispatch, sourceSize propagation at runtime, GPU rasterization or an end-to-end painted mask.

All three integrated input source hashes:

| Source | SHA256 |
| --- | --- |
| `BrushStabilizer.swift` | `a4e935d71017e59b27e6b493f8266fe53b4b36434fccb9fd6a18d26214e1403d` |
| `MaskCanvas.swift` (source review/parse only) | `b192a91e091fa29de3d86fa4bf16d2a8e1f0ecdd420437a19bc0a217fdd65b83` |
| `BrushStabilizerSourceMetricTests.swift` | `be68245df0d779504ea0a225b1913575ca324b26c8eb8824dc4a67abff6f6f91` |

Existing `BrushStabilizerTests.swift` SHA256 `dcab6b120fed6dde0b2bc2449beb319a25a2c08734b75da8e8943bb87dcd51eb`. Historical executed generator `prepare-portable.py` SHA256 `d46600e515b76b8b28f2e284da983ee32cc3a0c04f7b670b77da3396ed4ef1ed`. Its original execution location was `/workspace/scratch/2982a056243e/brush-source-metric-probe/prepare.py`; it writes next to itself. The new safe `reproduce.py` was added after execution and was not used to produce these logs. It requires a fresh directory, refuses overwrite, and does not invoke a compiler or tests. No verification rerun is claimed for the archive additions.

| Raw archived log | SHA256 | Result |
| --- | --- | --- |
| `frozen-green.log` | `796daa1f1c087555c43681122074b6c6c14a6cac3b22e2b739024c7fbb6916ee` |18 methods,0 failures, exit0 |
| `frozen-mutant.log` | `3163ccac61426f0720ef0a1679530cddc76e9ccdd90fbea35e96a6f83a710103` |18 methods,10 failed assertions, exit1 |
| `first-signal4.log` | `c33f0308bb2f7168c6ca5ee9de7397bf4fe4e4b0298fb78b0e6254e5427f6e77` | pre-freeze binary first launch, exit132; excluded |
| `final-first-signal4.log` | `9d96c2ec3684bd3dfa58b304d7a3802db71b29ff36df1ccd877c61e0d8edc3cd` | earlier pre-freeze binary first launch, exit132; excluded |

The final frozen green/mutant executions completed without Signal4. The separately recorded macOS-target `swiftc -frontend -parse -target arm64-apple-macosx15.0` check was syntax-only on Linux: no Apple SDK, no macOS typecheck/link or pointer execution. Native qualification remains a separate CI/owner acceptance item.
