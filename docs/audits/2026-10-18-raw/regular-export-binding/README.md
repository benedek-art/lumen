# Regular-file binding witness

2026-10-18; isolated source base `99b2db8`. This is a portable test of the actual new stat helper, not native export/encoder certification. The full macOS 99b2 run caught `ExportSourceChangedError(url: file:///dev/null)` in the original export-stage diagnostic: the opportunistic fallback had bound a synthetic device. The fix narrows only that fallback to regular files; explicit expected tokens and their validation remain intact.

Frozen SHA-256:

| Source | SHA-256 |
| --- | --- |
| `Sources/LumenCore/Catalog/SourceFileIdentity.swift` | `f1525319942d41c8ccb3b980a3e4cf75e47a68a6145fd20912a605a07087629b` |
| `Sources/LumenPipeline/PipelineRenderer.swift` | `89c26cc1c22dffb9c7e07332c53f53a1ea6cd4d44699f7307a4a36d131883613` |
| `Tests/LumenCoreTests/RegularSourceFileIdentityTests.swift` | `1592b8bfa0167cf25cc743285d7d00fcb64381d8d32e21ff2d97ed856295f65a` |

## Executed evidence

- GREEN: three tests, zero failures, exit 0 (.008s).
- Causal mutant: change only the `readRegularFile` delegation from `requiringRegularFile: true` to `false`. Three tests execute; the directory and `/dev/null` refusal assertions fail (two failures), exit 1 (.111s). Regular/symlink identity and replacement/broken-link controls pass.
- macOS-target syntax parse and `git diff --check` passed; no SDK typecheck or native export execution is claimed here. No assertion or tolerance changed in the original export tests.

Original logs at `/workspace/scratch/2982a056243e/`:

| Log | SHA-256 |
| --- | --- |
| `regular-export-helper-green.log` | `396821c55cea22e5b4f3c3455fc5dccec89f30cb4b61e6cc9abdc52419628fef` |
| `regular-export-device-mutant.log` | `de188d6f3f2f28f5e0f35324a7cdc80ec26e1fcb11e67464bd012b482bba8520` |

## Exact portable harness and commands

The already-executed harness lives in `/workspace/scratch/2982a056243e/regular-export-portable`. `identity.swift` is the production SourceFileIdentity file prefixed with `import LumenCore`; `tests.swift` is the actual new test file with only `@testable import LumenCore` removed. The source-local new nominal type is tested. Release objects from checkpoint `4d7dcbd` supply the unchanged XXH64 dependency; this is deliberately not presented as a newest-source full Core build. `device-mutant.swift` differs only by the one delegation boolean above. `main.swift` registers the three actual methods:

```swift
import XCTest
XCTMain([testCase([
("testRegularOriginalAndSymlinkUseTheSameGeneration", RegularSourceFileIdentityTests.testRegularOriginalAndSymlinkUseTheSameGeneration),
("testDirectoriesDevicesAndMissingPlaceholdersDoNotBindImplicitly", RegularSourceFileIdentityTests.testDirectoriesDevicesAndMissingPlaceholdersDoNotBindImplicitly),
("testReplacementStillChangesGenerationAndBrokenSymlinkIsUnbound", RegularSourceFileIdentityTests.testReplacementStillChangesGenerationAndBrokenSymlinkIsUnbound)
])])
```

Commands below use task-specific shell variables for readability; their expansion is the exact executed toolchain/objects/inputs. These commands are documentation, not a claimed second execution.

```bash
audit_root=/workspace/scratch/2982a056243e
audit_probe="$audit_root/regular-export-portable"
audit_release="$audit_root/build-numeric-mode-release/x86_64-unknown-linux-gnu/release"
export SWIFT_BACKTRACE=enable=no
export LD_LIBRARY_PATH="$audit_root/swift-deps/usr/lib/x86_64-linux-gnu"
export LIBRARY_PATH="$LD_LIBRARY_PATH"
"$audit_root/swift/usr/bin/swiftc" -I "$audit_release/Modules" \
  -Xcc "-fmodule-map-file=$audit_root/lumen-investigation/Sources/CSQLite3/module.modulemap" \
  "$audit_probe/identity.swift" "$audit_probe/tests.swift" "$audit_probe/main.swift" \
  "$audit_release"/LumenCore.build/*.o -lsqlite3 -o "$audit_probe/test"
stdbuf -oL "$audit_probe/test" > "$audit_root/regular-export-helper-green.log" 2>&1
# GREEN exit 0.

"$audit_root/swift/usr/bin/swiftc" -I "$audit_release/Modules" \
  -Xcc "-fmodule-map-file=$audit_root/lumen-investigation/Sources/CSQLite3/module.modulemap" \
  "$audit_probe/device-mutant.swift" "$audit_probe/tests.swift" "$audit_probe/main.swift" \
  "$audit_release"/LumenCore.build/*.o -lsqlite3 -o "$audit_probe/device-mutant"
stdbuf -oL "$audit_probe/device-mutant" > "$audit_root/regular-export-device-mutant.log" 2>&1
# Mutant exit 1, exactly two failed assertions.
```

## Combined-source read-only review

Reviewed `/workspace/scratch/2982a056243e/lumen-sidecar-scaling-next` after integration. All three source hashes above match. The fallback is `expectedSourceIdentity ?? SourceFileIdentity.readRegularFile(source.url)`; `stat` follows symlinks and the regular-file check uses the same stat result as the token. The pre-decode, post-decode and pre-publication guards remain. `validateExportSource` still uses the unrestricted existing `read` for explicit tokens, so a caller-supplied device token is not silently ignored. AppStateActions/RenderCoordinator export plumbing is unchanged from 99b2. External replacement after final stat remains the documented filesystem TOCTOU limitation.

Archived mutant log normalizes trailing line whitespace only so repository whitespace checks remain clean. Original runtime log hash is listed above; archived copy SHA256 `3344ddf03c73e1b5353954e127041d1547e3824472603c319c9c7307f6e1294d`. Assertion text/results are unchanged.
