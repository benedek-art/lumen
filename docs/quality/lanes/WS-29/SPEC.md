# WS-29 Saved looks, look copy/paste and the built-in looks: acceptance spec

Owned: `LookPanel.savedLooksSection/savedLooksRows` + menu, `LookSubset.blended/applied/extracted`,
`DevelopPresetLibrary.swift`, `AppStateDevelopPresets.swift`; look copy/paste (`AppState.copyLook/pasteLook`,
unowned elsewhere, WS-29 is "look copy/paste"). New: `BuiltInLooks.swift`.

| # | Claim | Threshold | Measured by |
|---|---|---|---|
| S1 | At 100% a look lands exactly: same `Look`, develop untouched, identical pixels to the source look on the target | exact | `SavedLookReliabilityTests.testS1…` |
| S2 | The blend is monotone on the rendered picture: distance from the frame's own render rises at every 10% step, 0% is bit-identical, 50% is 30–70% of the full distance | strict increase | `testS2…` (busy look: wheels across 0/360, grid, printer lights, primaries, vignette, contrast override) |
| S3 | Canonical JSON round trip (the catalog's form) applies and renders identically at 100% and 40% | exact | `testS3…` |
| S4 | Re-applying a look a frame already wears is a no-op at any Amount | identical pixels | `testS4…` |
| S5 | Paste Look is the saved-look door at full strength: lands the look, keeps a rendered file's register, raises `pipelineVersion` to the look's | version ≥ look's | `LookClipboardTests.testPasteLookStatesTheVersionItsLookNeeds` (macOS), `LookRenderPresetDoorTests` |
| S6 | 8 built-in looks: unique names, decode through the catalog path, no LUT, apply through `applied(to:)`, render finite, move the picture, clip ≤ +0.5% over the plain render, 50% lands strictly short of the look | as stated | `BuiltInLooksTests` |

Visual claims:
- V1 `evidence/builtin-looks-overview.png` (+ `-1/-2/-3` at larger size): every look tasteful on all 6 photos (Sony A7 IV, Panasonic GX85, GX80, Canon R5, 77D, Fujifilm X-T10 low light): no neon, no crushed shadows beyond the B&W High Contrast intent, no hue shifts in neutrals.
- V2 UI snapshot of the Looks panel (macOS `ui-snapshots`): built-in list readable, Amount above it.
