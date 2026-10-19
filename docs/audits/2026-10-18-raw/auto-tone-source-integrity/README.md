# Auto Tone source integrity candidate

Baseline: `0a82064e16453683b4682fc918042b504b3e65bd`. Previously a late asynchronous Auto Tone result could repopulate an old folder's recipe/history after source replacement and publish its old URL via the source-only persistence path. A same-URL original replacement was also unchecked. The candidate captures source revision, catalog mapping and physical identity before measurement and checks them before closing any current gesture or touching history/persistence. Healthy midgesture landing retains its existing intended behavior. Selection changes alone do not cancel requested targets.

Three native regressions cover folder switch, same-URL physical replacement, and healthy midgesture landing with undo/redo and catalog/XMP checks. They have passed Linux Swift frontend parsing only; native SDK compilation and execution remain pending at this checkpoint. Existing AuditStateSafety tests are unchanged.

## Executed portable evidence

`main.swift` contains exact candidate context/capture/validation bodies, with validator visibility changed only to invoke it, minimal wrapper types, actual `SourceFileIdentity.swift`, and the complete XXH64 enum extracted from tracked Fingerprint.swift. It does not compile the native AppState or simulate history/SQL. Synthetic temporary files exercise physical replacement/removal. The green executable returned 0: eight checks, zero failures. The bypass witness returned 1: five rejected stale/foreign cases became accepted, while healthy and virtual compatibility remained accepted. `known stale preflight` checks that capture returns nil (its printed true is successful refusal).

`provenance.json` identifies the exact source/compiler and executed binary hashes; logs and compiled source snapshots are retained. The builder regenerates helper/main bodies from the supplied checkout. The archived XXH64 and identity snapshots were compiled directly, not linked from a previously built Core module. The initial dependency-incomplete compile was corrected before these executions.

Reproduce from repository root (set `SWIFTC` to a compatible compiler and configure its runtime library path if needed):

```sh
AUDIT=docs/audits/2026-10-18-raw/auto-tone-source-integrity
mkdir -p /tmp/auto-tone-witness/mutant
python3 "$AUDIT/extract-witness.py" "$PWD" /tmp/auto-tone-witness
cp /tmp/auto-tone-witness/mutant-main.swift /tmp/auto-tone-witness/mutant/main.swift
"$SWIFTC" -O /tmp/auto-tone-witness/main.swift "$AUDIT/SourceFileIdentity.swift" "$AUDIT/XXH64-extracted.swift" -o /tmp/auto-tone-witness/green
"$SWIFTC" -O /tmp/auto-tone-witness/mutant/main.swift "$AUDIT/SourceFileIdentity.swift" "$AUDIT/XXH64-extracted.swift" -o /tmp/auto-tone-witness/red
/tmp/auto-tone-witness/green
/tmp/auto-tone-witness/red  # expected exit 1, five failing checks
```

Executed compiler `/workspace/scratch/2982a056243e/swift/usr/bin/swiftc`; `LD_LIBRARY_PATH=/workspace/scratch/2982a056243e/swift-deps/usr/lib/x86_64-linux-gnu`; output paths were `/workspace/scratch/2982a056243e/auto-tone-context-witness/{green,red}`. The same source arguments shown above were used, with the identity implementation taken directly from the tracked Core path; its archived snapshot is byte-identical. `swiftc -frontend -parse` on the two changed Swift files and `git diff --check` passed.

Native causal mutation: replace the unique call expression `autoToneSourceIsCurrent(context, suggestions: suggestions)` in the landing guard with `true`. Do not remove capture or alter healthy behavior. Run the three new methods and unchanged AuditStateSafety midgesture control; stale-source assertions must fail in the mutant, healthy behavior must still pass.

Limits: stat identity is not a content digest or cross-process file lock. Unknown virtual identities retain existing nil/nil compatibility. This does not qualify parallel Auto-result ordering, SQL-failure UI rollback, every Auto feature, private cameras or physical GUI input.
