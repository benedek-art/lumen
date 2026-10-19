# Brush stabilization coordinate units

Source base `5d1ff3a9793a6ea6487dcf67a304f47bc438e0d1`. Existing geometry independent oracle covers quarter turns and reflection separately, but not their composition or asymmetric crops; that new native composition qualification was deferred to keep this fix bounded. No rotation-order defect is established.

## Causal units defect

`BrushStabilizer.swift:52` declares rope length in source-normalized LONG-edge units; default maximum is .02. `MaskCanvas.normalized` maps displayed locations through `PipelineRenderer.sourceNormalized`, yielding source fractions of width and height separately. `dragBrush` previously supplied these fractions directly to a Euclidean unit-square metric. On a1000×500 image Stabilize100 therefore left20px horizontal lag but10px vertical lag. Identical30px pointer moves produced10px versus20px brush travel;15px jitter was suppressed horizontally yet moved the vertical brush5px. This affects intermediate recorded paths. The existing final `finish` did reach the actual endpoint.

The actual unmodified helper witness is retained in `BrushStabilizer.actual.swift` with `main.swift` and `metric-output.txt`. It compiled and ran with `--require-isotropy`, exit1: the explicit expected20px physical rope failed; square, disabled and final-endpoint controls passed. It is diagnostic evidence, not an intentionally failing default XCTest.

## Bounded repair

The helper now accepts source width/height (default1 for legacy callers). Before its unchanged pulled-string math it converts `(x,y)` to `(x*W/L,y*H/L)`, `L=max(W,H)`, then converts emitted points back to per-axis fractions. Stored strokes and .02 maximum/strength curve are unchanged. Exact first seeds, disabled samples and final endpoints retain input coordinates without a floating roundtrip. Invalid/nonfinite/underflowed dimensions fall back to the legacy unit metric; nonfinite custom maximum rope disables stabilization rather than creating NaN/Inf. No Float conversion is introduced.

Both actual MaskCanvas constructors pass its sourceSize; seed, ordinary and final samples share that helper. Its existing captured `MaskCanvasMapping` checks imageRect/sourceSize at each callback and cancels on mapping changes. The edit context also carries geometry/source identity, so a drag cannot silently change its metric/target.

The size domain was traced, not inferred from its label: LoupeView1181/1934 → AppState414 sourceFrameSize → primaryFrameSize with FrameOrientation EXIF reconciliation. AppState1273 obtains RenderCoordinator737 nativeSize → ImageSource.nativePixelSize. AppleRawSource125 uses original filter.nativeSize; rendered ImageSource103 uses the EXIF-oriented decoded extent. Recipe rotation/reflection/crop are downstream. PipelineRenderer2507 already inverses those operations before BrushPoint storage. The same source dimensions thus define both per-axis normalization and long-edge conversion. Existing metadata-unknown Loupe fallback to preview dimensions remains a separate mapping limitation; metadata arrival cancels the press. Native EXIF/metadata-arrival/pointer acceptance is still required.

## Frozen verification

18 actual-helper portable XCTest methods passed, exit0 (.007s): all13 preexisting BrushStabilizerTests unchanged plus5 new physical metric tests (landscape/portrait/square, axis and oblique/reflected travel, jitter, exact seed/release/disabled output, legacy/invalid inputs). The causal mutant keeps scaleX/scaleY at1:18 tests execute,10 assertions fail, exit1; all13 legacy tests still pass. It isolates the missing metric conversion. Mac-target syntax parse and diff check passed. This is not SwiftUI execution or a macOS SDK typecheck.

The four raw logs are archived here as `frozen-green.log`, `frozen-mutant.log`, `first-signal4.log`, and `final-first-signal4.log`; their original absolute paths used the prefix `/workspace/scratch/2982a056243e/brush-source-metric-`. Final frozen runs did not crash. Earlier pre-freeze first launches of fresh green binaries exited Signal4; one retry each passed. They are excluded from semantic evidence. See `PROVENANCE.md` for compiler, shim and log hashes.

SHA256:

| File | Hash |
| --- | --- |
| `Sources/LumenCore/Interaction/BrushStabilizer.swift` | `a4e935d71017e59b27e6b493f8266fe53b4b36434fccb9fd6a18d26214e1403d` |
| `Sources/LumenApp/MaskCanvas.swift` | `b192a91e091fa29de3d86fa4bf16d2a8e1f0ecdd420437a19bc0a217fdd65b83` |
| `Tests/LumenCoreTests/BrushStabilizerSourceMetricTests.swift` | `be68245df0d779504ea0a225b1913575ca324b26c8eb8824dc4a67abff6f6f91` |

Actual SwiftPM qualification filter: `swift test -c release --jobs 2 --filter 'BrushStabilizerTests|BrushStabilizerSourceMetricTests'` (use existing Linux build flags/SQLite configuration). Portable harness originals are in `/workspace/scratch/2982a056243e/brush-source-metric-probe`; `prepare.py` copies the actual helper and actual tests, removes only the module import, supplies the sole Num.saturate dependency and registers XCTest methods. `prepare-portable.py` preserves that historical generator unchanged: **do not run it inside this archive**, because it writes next to itself. The safe NEW `reproduce.py` requires explicit source root and a nonexistent output directory, refuses overwrite, and generates inputs only. The commands below are reproducible instructions, not a claim of another execution:

```bash
audit_root=/workspace/scratch/2982a056243e
audit_source="$audit_root/lumen-mask-affine"
audit_probe="$audit_root/brush-source-metric-reproduced"
export SWIFT_BACKTRACE=enable=no
export LD_LIBRARY_PATH="$audit_root/swift-deps/usr/lib/x86_64-linux-gnu"
export LIBRARY_PATH="$LD_LIBRARY_PATH"
python3 "$audit_source/docs/audits/2026-10-18-raw/mask-affine/reproduce.py" \
  --source-root "$audit_source" --output-dir "$audit_probe"
"$audit_root/swift/usr/bin/swiftc" "$audit_probe/helper.swift" \
  "$audit_probe/BrushStabilizerTests.swift" "$audit_probe/BrushStabilizerSourceMetricTests.swift" \
  "$audit_probe/main.swift" -o "$audit_probe/green"
stdbuf -oL "$audit_probe/green" > "$audit_probe/green.log" 2>&1
# Mutant uses mutant.swift instead of helper.swift and output binary mutant;
# run logs to "$audit_probe/mutant.log", expected exit1 /10 failures.
```
