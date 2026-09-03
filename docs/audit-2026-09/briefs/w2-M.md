# W2 — M · Recipe & serialization

Read `briefs/w2-common.md` first. Output: `docs/audit-2026-09/w2/M.md`.

## The question
Forward/backward compatibility, K-020 silent downgrade, K-043 dead wire fields (LocalAdjust ×5, Upright ×8, Heal, LUT) — delete vs keep with the pipelineVersion cost of each, K-059 pivot robustness, paste-settings subsets, fingerprint stability, and exactly what the fixtures mirror requires of any field change (the fixtures ceremony in PLAN.md).

## Files you own (read every line)
- `Sources/LumenCore/Recipe/Recipe.swift (the Codable surface, versioning, defaults, renderIdentity)`
- `Sources/LumenCore/Recipe/RecipeLook.swift (Codable)`
- `Sources/LumenCore/Recipe/RecipeMasks.swift (Codable)`
- `Sources/LumenCore/Recipe/CanonicalJSON.swift`
- `Sources/LumenCore/Recipe/Fingerprint.swift`
- `Sources/LumenCore/Recipe/RecipeDecoding.swift`
- `Sources/LumenCore/XMP/XMPSidecar.swift (recipe encoding only)`
- `scripts/gen-fixtures.py (the recipe mirror, lines ~328–530)`

## Spec and prior audit to read
- `docs/15-catalog.md §recipe`
- `docs/14-pipeline.md §pipelineVersion`
- `scripts/gen-fixtures.py header`
- `docs/audit-2026-09/w1/gap-table.md` §M

## Known-open rows to re-verify (STILL-OPEN / FIXED-SINCE / CHANGED / REJECTED, with file:line)
- **K-020** (**S1**, docs/31 r1 data-loss): A recipe written by a newer build is silently downgraded in place (guard compares carried-forward version, not this build's)
- **K-043** (S3, docs/31 r1 smaller): Five `LocalAdjust` fields and eight `Upright` fields round-trip meaning nothing
- **K-059** (S2, docs/31 r2): Non-finite zone pivot indexes past the pivot array; short foreign pivot array padded with defaults' tail → unsorted array accepted

## Cross-cutting rows (FYI — disposition only if you touch them)
- **K-014**: `check-swift-surface.py` cannot see protocol conformance
- **K-058**: Texture GPU gain has no ±4 EV limit; gamut flag on opposite sides of grain in the two renderers; album counts offline frames; `rebuild` writes bare LFs into CRLF sidecar; a Lumen element name stripped inside foreign provenance
- **K-073**: Everything else stays ranked in docs/31
- **K-102**: LumenAppTests exists (9 files) but no CI lane runs it under a filter

## Timebox
30 minutes. Read-only. No git.
