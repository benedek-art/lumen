# W2 — L · State, history & app integrity

Read `briefs/w2-common.md` first. Output: `docs/audit-2026-09/w2/L.md`.

## The question
Undo correctness (K-038 shared coalescing keys), the 'deliberately not published' rules honoured everywhere (K-030 zoomLevel publishes per pinch), force-unwraps and main-thread blocking (K-034), whether the L0 extension split in PLAN.md §W5 is feasible as drawn (which privates cross the boundary), updater safety.

## Files you own (read every line)
- `Sources/LumenApp/AppState.swift (structure, publication, editing, undo, gestures — not the library/mask sections other areas own)`
- `Sources/LumenApp/HistoryStack.swift`
- `Sources/LumenCore/Interaction/HistoryCoalescing.swift`
- `Sources/LumenApp/EditRevision.swift`
- `Sources/LumenApp/CommandState.swift`
- `Sources/LumenApp/AppUpdater.swift (read-only; frozen file — findings only)`

## Spec and prior audit to read
- `docs/13-architecture.md §concurrency`
- `docs/23-master-plan.md §diagnosis`
- `docs/31-defect-audit.md perf`
- `docs/audit-2026-09/w1/gap-table.md` §L

## Known-open rows to re-verify (STILL-OPEN / FIXED-SINCE / CHANGED / REJECTED, with file:line)
- **K-030** (S2, docs/31 r1 perf): `zoomLevel` publishes on `AppState` per pinch/scrub — whole-window + `Scene` rebuild, 7 menus
- **K-034** (S2, docs/31 r1 perf): `AppUpdater` blocks main through `ditto` + deep `codesign`; failure message may be wrong
- **K-038** (S2, docs/31 r1 smaller): Coalescing keys shared between distinct decisions (two WB presets, two curve points, two aspect ratios fold into one undo step)

## Cross-cutting rows (FYI — disposition only if you touch them)
- **K-014**: `check-swift-surface.py` cannot see protocol conformance
- **K-058**: Texture GPU gain has no ±4 EV limit; gamut flag on opposite sides of grain in the two renderers; album counts offline frames; `rebuild` writes bare LFs into CRLF sidecar; a Lumen element name stripped inside foreign provenance
- **K-073**: Everything else stays ranked in docs/31
- **K-102**: LumenAppTests exists (9 files) but no CI lane runs it under a filter

## Timebox
30 minutes. Read-only. No git.
