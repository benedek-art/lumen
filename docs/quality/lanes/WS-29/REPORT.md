# WS-29 Saved looks, look copy/paste, built-in looks: report (lane K4)

## For the owner

1. Lumen now ships 8 looks at the top of the Looks panel: Natural Portrait, Vivid Landscape, Soft Matte, Warm Film, Cool Cinema, Faded Vintage, B&W Classic and B&W High Contrast. Each one dials with Amount.
2. Fixed: a look that changed contrast used to land all of it at 1% Amount, so the slider moved away from the look over its first third.
3. Fixed: Paste Look now stamps the recipe version the way applying a saved look does, so older builds can't misread it.
4. Try by hand: Natural Portrait on a real portrait (the corpus has no people), and the B&W looks' Amount, which snaps to monochrome at 1% (the switch is categorical, as in Lightroom).
5. JPEG/HEIC frames keep the Linear register, so the curve half of each built-in look does nothing there.

Best evidence: `evidence/builtin-looks-overview.png`, with larger strips in `evidence/builtin-looks-{1,2,3}.png`.

## Verdict per spec line

Final verifier (round 3 of 3, fresh agent, spec + diff only): **PASS**. Rounds 1 and 2 failed; their findings are fixed in 7d24962 and 7bce34f.

| # | Verdict | Measured |
|---|---|---|
| S1 lands exactly at 100% | PASS | identical Look and pixels; develop untouched |
| S2 monotone blend on the picture | PASS | strictly increasing at every 10% step; 50% = 0.572 of full (was: 0.0124 → 0.0111 → 0.0098 over 10–30%, moving away) |
| S2b across registers | PASS | 99%→100% distance 1.7e-4 (was a jump of 0.017) |
| S3 catalog JSON round trip | PASS | identical pixels at 100% and 40% |
| S4 re-apply is a no-op | PASS | identical pixels |
| S5 Paste Look raises the version | PASS (reading + door test) | macOS `LookClipboardTests.testPasteLookStatesTheVersionItsLookNeeds`; see CI |
| S6 8 built-ins | PASS | half-Amount ratio 0.49–0.51 (colour), 0.96 (B&W, strictly short); 0 extra clipping |
| V1 tasteful on 6 photos | PASS (verifier and builder) | no neon, porcelain neutral; B&W High Contrast crushes low-key frames by intent |
| V2 Looks panel snapshot | pending macOS `ui-snapshots` | |

## What changed and why

- **`LookSubset.blendedRender`:** a nil curve override (contrast, skew, hue preservation, black target) now walks from or to the value its preset actually renders, using the preset the frame keeps (`carriedRenderPreset`). It used to take the look's override whole whenever either side was nil.
- **`AppState.copyLook/pasteLook`:** the copy is a `LookSubset` and the paste goes through `applied(to:)`. `LookRenderPresetDoorTests` counted raw `.look =` assignments, and there are none left, so it now also counts the routed door.
- **`BuiltInLooks.swift`** (new): sparse canonical JSON decoded by the catalog's own decoder. `LookPanel.savedLooksRows` shows "Lumen" then "Yours", and the Amount slider is always shown. Colour looks use Neutral plus walkable overrides, not a named preset; a preset lands whole and left Cool Cinema's slider dead.
- **Look designs:** `tools/json/*.json`, `tools/notes.md` (intent, settings, what rendered badly), `tools/contact.py` (re-renders the sheet).

## Not fixed / for a human

- Preset changes and the B&W switch are categorical under Amount. This is documented and matches Lightroom.
- Re-applying a look at a partial Amount compounds (documented in `applied(to:)`).
- `whiteTarget` still lands whole when either side is nil; its nil means the live display headroom.
- Built-in looks lean on controls other lanes own (wheels WS-35, display transform WS-13, film WS-38). If those lanes retune their controls, re-run `tools/contact.py` and look again.
