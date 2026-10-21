# WS-09 Auto Tone: acceptance spec

Owned: `AutoTone` (ToneEngine.swift), `AppStateActions.applyAutoTone / applyAutoToneSuggestions /
statistics`, the Auto footer button. Shared tooling added: `lumen-render auto` (new file
`Sources/LumenRender/AutoCommand.swift`, one dispatch line in `CLI.swift`).

Setup for every measured line:

```
swift build -c release --product lumen-render
T=docs/quality/lanes/WS-09/tools
python3 $T/auto_corpus.py /tmp/ws09/new --sheet /tmp/ws09/new.png
python3 $T/auto_corpus.py /tmp/ws09/old --legacy --sheet /tmp/ws09/old.png
python3 $T/spec_check.py /tmp/ws09/new --legacy /tmp/ws09/old
```

`auto_corpus.py` runs Auto the way the app does (512-px proxy at tone zero, read back into scene EV,
solve, then up to 3 corrective proxy renders for clipping and crush) on all 25 corpus frames, and renders
before (tone at zero) and after at 640 px. Luminance is sRGB-encoded (0..1, x255 = code).
"Clip" = % of pixels with any channel at code 255; "crush" = any channel at code 0.
Low-key by intent: 2348 (black jacket), 967 (black bag).

| # | Claim | Threshold | Measured by |
|---|---|---|---|
| S1 | Exposure puts the frame on a sensible key | median in 0.38..0.46 on every frame where highlight protection did not bind (Auto's predicted median < 0.40, or a clip refinement ran); no frame above 0.46 | spec_check S1 |
| S2 | Low-key frames stay low-key | 2348 and 967 median <= 0.30 | spec_check S2 |
| S3 | Highlight protection: Auto never blows what the capture held | clip after <= max(0.5 %, clip at tone zero + 0.5 %) on all 25 | spec_check S3 |
| S4 | Blacks to just-clip, not crushed | crush after <= max(0.5 %, crush at tone zero + 0.5 %) on all 25 | spec_check S4 |
| S5a | Whites to just-clip | p99 >= 0.85 on >= 18/25, and every frame short of it has Whites at Auto's +60 cap or is protection-bound | spec_check S5a |
| S5b | Blacks reach near black | p1 <= 0.05 on >= 21/25 | spec_check S5b |
| S6 | Consistency on the 6929/6933 pair (same scene, 0.39 EV apart in capture) | rendered medians within 0.01, means within 0.02 | spec_check S6 |
| S7 | Vibrance modest, Saturation untouched | Vibrance <= +15 on all 25, and >= +5 unless the crush loop lowered it; `Result.apply` writes no other field | spec_check S7; `AutoToneQualityTests.testAutoVibranceIsModestAndFollowsChroma` |
| S8 | Auto's prediction is the picture | predicted median within 0.02 of the rendered median on all 25 | spec_check S8 |
| S9 | Unit contract | `AutoToneQualityTests` (key across capture shifts within 0.03; bracket consistency; just-clip endpoints on a reachable frame; low-key window not blown; prediction within 0.03; envelope, finiteness, determinism) and the existing `EngineTests` Auto tests pass | `swift test --filter "AutoToneQualityTests\|EngineTests"` |
| S11 | Holds under other looks (round 2, after verifier) | Punchy: S1-S8 all PASS. Linear (the look every rendered JPEG/TIFF imports on): S1-S4, S6-S8 PASS; S5 is N/A because Linear is an identity clip with no white/black point, and Auto sets Whites/Blacks/Contrast to 0 there | `auto_corpus.py DIR --set look.render.preset=Punchy` / `=Linear`, then `spec_check.py DIR` (`--linear` for Linear) |
| S12 | Nothing out of nothing | an all-black or all-blown frame gets Tone() and Vibrance 0; on Linear Auto writes no Whites/Blacks/Contrast; the crush loop lowers Vibrance where Blacks has no reach | `testAutoLeavesAnAllBlackOrAllBlownFrameAlone`, `testAutoOnTheLinearLookLeavesTheEndpointsAlone`, `testTheCrushLoopLowersVibranceOnTheLinearLook` |
| S10 | No render change | no file under `Sources/LumenPipeline`, no `RenderPlan`/`ReferenceRenderer` code touched; GPU parity unaffected | `git diff --stat $BASE -- Sources/LumenPipeline Sources/LumenCore/Render` empty |

Visual claims (human judges, from the evidence sheets):

- V1 `evidence/pair_6929_6933_old_vs_new.png`: new Auto opens the overcast street (the wall reads
  white-ish, foliage has depth) and the two frames look like the same exposure.
- V2 `evidence/lowkey_2348_1192_old_vs_new.png`: the jacket stays black (old Auto turned it grey),
  and the stained glass is not blown (old Auto clipped its whites).
- V3 `evidence/corpus_new_auto_before_after.png`: on no frame is the new Auto a worse starting point
  than tone at zero; nothing looks over-processed (no halos, no flat HDR look).
