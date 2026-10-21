# U3 — viewer, compare and editing workflow: acceptance spec

Baseline: `ui-snapshots:claude-inspiring-dirac-ulgpch/a93efb2/`. After: `ui-snapshots:quality-u3-viewer-workflow/<sha>/`.
Interaction lines cannot be measured in a PNG; they are verified from the code path and listed for the owner to try.

| # | Claim | Threshold | How it is checked |
|---|---|---|---|
| S1 | A fitted loupe keeps a matte round the picture | ≥ 24 pt (48 px @2x) of surround between the picture and the sources sidebar and develop column on the limiting axis | `window-1512x982-develop.png`: picture edge to panel edge, pixels |
| S2 | Arming crop does not resize the picture | crop inset == fit matte (`LoupeGeometry.fitMatte`) | code: `cropInset = LoupeGeometry.fitMatte`; `window-1512x982-crop.png` vs `-develop.png` picture width |
| S3 | Space held while zoomed pans and does not zoom out | press while zoomed changes `zoom` by 0; release after a pan leaves `zoom` unchanged; a tap still toggles | code path `KeyDispatcher` → `LoupeViewport.spaceDown/spaceUp`, `panTo` marks the hold |
| S4 | Holding Space never beeps | every Space key repeat in loupe/Compare/grid peek is claimed (returns true) | code path |
| S5 | Z, −, + and Space zoom Compare | each changes `CompareSync.shared.zoom` in `.compare`; none touches `LoupeViewport.zoom` there | code path; `window-1512x982-compare-zoom-1to1.png` |
| S6 | Footer offers the selective copy and, with > 1 selected, Sync | `Copy…` opens the Copy Settings sheet; `Sync…` visible iff `selectedPhotos.count > 1`; all footer titles fit at 320 pt | `LayoutMetricTests.testEveryDevelopFooterButtonFitsItsShareOfTheRow` (macOS CI) |
| S7 | The histogram card's height does not depend on the scope feed | provenance note drawn inside the graph, no extra row; section headers at the same y in develop and grade windows | `window-1512x982-develop.png` vs `-grade.png`, first section header y |
| S8 | Snapshot coverage for zoom, before/after and compare | 5 new window states written | `index.md` of the lane's snapshot set |

Visual claims (judge from the named sheets):
- V1 `window-1512x982-develop.png`: the photograph reads as a print on a matte, not as a hole in the chrome.
- V2 `window-1512x982-compare.png`: two fitted frames do not touch across the divider.
- V3 `window-1512x982-develop-before-after-side.png`: before and after are the same size and both labelled.
