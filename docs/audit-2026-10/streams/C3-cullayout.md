# C3-cullayout — two macOS CI failures on 5c29602

Branch: worktree branch of `agent-a9959f2252dafe956`, based on `origin/claude/jolly-sagan-k7ch7z` @ 1c6ac52.

| # | Failure | Status | Commit | Evidence | Proof records that move |
|---|---|---|---|---|---|
| 1 | `CullingAnalyzerTests.testASoftCopyScoresLowerAndHashesAsTheSamePicture`: pHash distance 28 > 12 | FIXED (fixture defect; the pHash is NOT-A-DEFECT) | 9021ba0 | Linux mirror `CullingAssistTests.testASoftCopyOfTheAnalyzerSceneHashesAsTheSamePicture`: red with the discs removed (1 failure, 32 × 32 span 0.010 vs 0.4); green with them (span 0.10…0.92, distance 0). CullingAssistTests 24/24. macOS half source-verified | none |
| 2 | `LayoutMetricTests.testTheInventoryCoversEveryShippedSlider`: 102 call sites vs 97 | FIXED | 2404f36 | 5 rows added, count 102. A replica of the by-title scan over the old table misses Start at, Size, Feather and Opacity, and over the new table misses nothing. `recite-slider-inventory.py HEAD --write` exits 0 (0 moved, 0 unplaced); a broken citation makes it exit 1. SliderEvidence/ControlIndex/CullingAssist 44/44 green on Linux. LumenAppTests source-verified | none |

## 1. The hash, with evidence

The pHash (`PerceptualHash.hash`: area-resample to 32 × 32, separable DCT-II, 8 × 8 low block, DC
dropped, median split) was checked against each suspect. It is correct:
- **Resolution:** both JPEGs are 1800 × 1200 and decode to the same 1536 px edge (`decodeLongEdge`).
- **Normalisation:** a median threshold does not change when the luma is scaled or offset.
- **Block:** coefficients are indexed `v·8+u` for u, v in 0…7, and only index 0 (DC) is dropped.

The fixture was the problem. Its doc comment says "checker-and-discs", but only the checker was
drawn: 60 × 40 cells, with all of their energy far above the hash's band. At 32 × 32 the scene is a
flat 0.57…0.58. Every AC coefficient is moiré against a median of 0, so the bits are noise. The
distance changes with how the picture is resampled, which is what noise does:

| Render path | Distance |
|---|---|
| Linux, centre-sampled | 12 |
| numpy replica with 2 × 2 supersampling | 18 |
| macOS through JPEG and ImageIO | 28 |

With the three discs drawn, the soft copy is 0 bits from the sharp frame. The macOS test now also
asserts that the 32 × 32 the hash reads spans more than 0.4. A flat fixture then fails as a flat
fixture, not as a distance.

## 2. The census rows

| Row | Site | Host | Range | Step |
|---|---|---|---|---|
| Size | HealCanvas.swift:343 | `healBar` (new) | 2…400 | 1 |
| Feather | HealCanvas.swift:347 | `healBar` | 0…100 | 1 |
| Opacity | HealCanvas.swift:351 | `healBar` | 0…100 | 1 |
| Amount (LUT) | LookPanel.swift:250 | `developTop` | 0…100 | 1 |
| Start at | ExportSheet.swift:831 | `exportSheet` | 1…999, hard 1…99 999 | 1 |

`healBar` is a fixed 250 pt HUD with 10 pt of padding. That leaves 230 pt of content and 80 pt of
track. Its frame is pinned in `testTheLayoutChainThisSuiteMeasuresIsTheOneInTheSource`.

## DECISIONS

1. **Start at's drag and type ranges were narrowed** (`ExportSheet.swift:832`). This is a one-line
   change in a file the export stream owns. Recording the old values (1…9999, hard 1…999 999)
   would have broken two other census checks:
   - `testEveryValueTheReadoutAdvertisesIsReachableBySomeGesture`: 9 998 steps, so even ⇧-scrub
     gets only 0.17 pt per step.
   - `testEveryReadoutFitsItsValueColumnAtBothWeights`: `999999` is about 41.8 pt against 42.0 pt
     of room, a margin within the measurement error.

   It now drags over 1…999 and accepts typed values up to 99 999. `ExportNaming` still clamps to
   999 999, so no stored value changes. The owner may prefer a plain numeric field: a sequence
   number is not really a slider value.

## FOUND-WHILE-FIXING

- The LUT Amount row could not have been caught by the by-title tripwire. LookPanel already has a
  look-apply row titled "Amount", so a second "Amount" in that file passes the check. Only the
  count noticed it.
- `layout-metrics` CI filters to `LayoutMetricTests`. That is why
  `LayoutMetricSelfTests.testEveryLiterallyTitledSliderInTheSourcesIsInTheInventory`, which would
  also have failed, did not appear in that lane's report.
