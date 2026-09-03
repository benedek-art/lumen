# W2 — K · Crop, lens & geometry

Read `briefs/w2-common.md` first. Output: `docs/audit-2026-09/w2/K.md`.

## The question
Crop tool grammar vs LR (overlay cycling, aspect lock K-023 broken by angle, straighten ruler, R R reset), K-029 ⌘K arms crop without a panel; Upright/perspective and removeCA/defringe exist in the model with no UI — surface or delete, and what DxO's/LR's lens modules would require; K-093 Heal with no stage.

## Files you own (read every line)
- `Sources/LumenCore/Model/CropGeometry.swift`
- `Sources/LumenCore/Model/Straighten.swift`
- `Sources/LumenApp/CropPanel.swift`
- `Sources/LumenApp/ViewerOverlays.swift (CropOverlayView, StraightenOverlayView only)`
- `Sources/LumenCore/Interaction/FrameOrientation.swift`
- `Sources/LumenCore/Recipe/Recipe.swift (Geometry, Crop, Upright, LensCorrections, Defringe, Heal only)`
- `Sources/LumenApp/EffectsPanel.swift (Lens Corrections section only)`

## Spec and prior audit to read
- `docs/09-spec-geometry.md`
- `docs/33-speed-crop-and-the-blur-postmortem.md Stream C`
- `docs/audit/geometry-output.md`
- `docs/audit-2026-09/w1/gap-table.md` §K

## Known-open rows to re-verify (STILL-OPEN / FIXED-SINCE / CHANGED / REJECTED, with file:line)
- **K-023** (S2, docs/31 r1 correctness): A ratio lock is silently broken by any change of angle (16:9 at 0° → 1.83:1 at 2°)
- **K-029** (S2, docs/31 r1 correctness): ⌘K → "Lens Corrections" arms the crop rectangle with no crop panel; Escape can't revert
- **K-093** (—, BUILDING): Heal/clone does not exist on any path; `Heal` participates in `renderIdentity`; Upright same

## Cross-cutting rows (FYI — disposition only if you touch them)
- **K-014**: `check-swift-surface.py` cannot see protocol conformance
- **K-058**: Texture GPU gain has no ±4 EV limit; gamut flag on opposite sides of grain in the two renderers; album counts offline frames; `rebuild` writes bare LFs into CRLF sidecar; a Lumen element name stripped inside foreign provenance
- **K-073**: Everything else stays ranked in docs/31
- **K-102**: LumenAppTests exists (9 files) but no CI lane runs it under a filter

## Timebox
30 minutes. Read-only. No git.
