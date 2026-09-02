# The grind — live status

The resume point. After a container reset or a context compaction, do this and nothing
else first:

```
git fetch origin claude/photo-editor-design-plan-8ahzmm
git reset --hard origin/claude/photo-editor-design-plan-8ahzmm
cat docs/audit-2026-09/STATUS.md
```

Then relaunch the briefs under `briefs/` whose output files are missing, and continue
from the first unchecked wave below. The plan is `/root/.claude/plans/enchanted-skipping-rocket.md`
(also mirrored as `docs/audit-2026-09/PLAN.md`).

## Decisions (owner's; never re-ask)
Find first, then fix · backlog first, then new · publish `dev-latest` on every green
landing · involvement: the U0 mockup checkpoint only, then the report · all docs/32 §4
deferrals lifted · UI: Option B "Modern pro", whole · rows 24 pt · keymap: `L`→Lights
Out, `B`→album, `⌘B`→assessment, `F`/`S` stay · denoise: free + best, delivery mine
(download-on-first-use), timing mine.

## THE SECOND HALF — where the run is now

The plan for this stretch is `/root/.claude/plans/enchanted-skipping-rocket.md`. The
mission, in one line: **audit the seventeen areas that were never audited, land what
they find, and let the decode path meet a real RAW file.**

W2 was scoped to 30 areas and trimmed to 13 when the owner said "trim discovery, spend
it on fixes". That was right then and it left seventeen areas unexamined — chosen for
where work was already queued, not for where risk lives. Every area that HAS been
audited produced at least one S1 or a real S2. There is no reason to think the other
half is cleaner; it is just unread.

Six concurrent agents, hard cap, and a commit after every wave. Twenty concurrent
agents died on a session rate limit earlier tonight, and the commit-per-wave rule is
what makes a container reset cost one wave instead of the night.

- [x] **Wave 1** — M, J3, A1, K, I3 + the RAW-corpus lane design. `2124941`, `d38ec25`.
- [x] **Wave 2** — E1, E2, B2, B3, D1, D2. `102c407`, `9982559`, `2882bb7`, `442ad09`.
- [x] **Wave 3** — F2, G3, H1, H2, J2 (I2 outstanding). `d02c414`.
- [ ] **Wave 4+** — the fix streams the three waves produce, then the standing S2
      backlog in `w3/dispositions.md` order.

**ALL THIRTY AREAS ARE NOW AUDITED.** The trimmed thirteen plus the seventeen that
were cut. Wave 2 and 3 found **7 more S1s** and roughly 45 S2s.

### The S1s the second half found

| id | what |
|---|---|
| **M-01** | a `.xmp` from a newer build is downgraded in place and rewritten still claiming the newer version — **LANDED** `d386442` |
| **J3-02** | a filename template that renders empty writes the batch beside the granted folder — **LANDED** `7c0bbb4` |
| **J3-01** | the tolerant preset decode is one level deep; one added field reverts every delivery preset to the stock four |
| **D1-01** | `LookSubset.applied(to:)` carries `look.render` whole, so a RAW look overwrites a JPEG's "Linear" and applies a second tone map (measured: sRGB 255 → 222) |
| **E2-02** | the Capture-sharpening toggle is live on JPEG/HEIC/TIFF, reaches nothing, lights the modified dot |
| **F2-01** | a mask that does not read the picture has no photograph in its raster cache key — every AI kind; draft keys collide at 1024x682 for any two 3:2 frames |
| **H1-01** | `⌘B` assessment surround and `L` lights out never reach the field: `surroundColor` is painted once and covered opaquely at five other sites |
| **G3-01 / J2-01** | `⌘B` is attached TWICE, to two different actions. Found independently by two auditors. `KeyGrammarTests` collects call sites into a `Set`, so a chord attached twice collapses to one member and nothing asks "is any chord attached twice" |

### The strongest thing the second half produced is not a defect

Three separate audits found that **the instrument could not see the defect**:
- `testContrastPinsTheEndsOfTheScale` probes ±12 EV, exactly where its smoothstep is
  1 by construction, while the picture is formed against anchors at +5/−9 (A1).
- Three of five sharpen proof records use `stepEdge`, whose rim measures 34.414 code
  values at 128, 1600, 4096 and 7008 px alike — the frame cannot express a
  scale-dependent defect — and `ScaleHonestyTests`' spatial roster omits sharpen (E2).
- `KeyGrammarTests` collapses duplicate chords into a `Set` (G3, J2).

That is the same failure `MaskGPUParityTests` had when it skipped itself for months.
**A green lane is not evidence** is not a slogan here; it is the single most common
finding in this audit.

### Fixes landed in the second half
| SHA | what |
|---|---|
| `d386442` | **J1-03** the sidecar write states its own fields · **M-01** and never a recipe it cannot represent. Checker taught what a conformance supplies; fixtures 25 → 27. |
| `71d8a78` | the RAW corpus lane |
| `7c0bbb4` | **J3-02** the empty rendered filename · **KG-02** `O` past the entry verb · **G3-02** `R` past it from the other side |

`71d8a78`: build-macos ✅ app-bundle ✅ fixtures-linux ✅ (test-fast, engine-linux
running).

### Wave 1's harvest — 3 S1, 17 S2, 13 S3 across five areas

| id | sev | what |
|---|---|---|
| **M-01** | S1 | `CatalogStore` refuses a recipe from a newer build twice over; the SIDECAR path does neither. A `.xmp` a newer build wrote is reduced to the keys this build's `CodingKeys` name and written back still claiming the newer number. **LANDING NOW.** |
| **J3-01** | S1 | the tolerant delivery-preset decode is one level deep — a field added to `OutputSharpen`/`MetadataPolicy` throws out of the array decode and `AppState`'s `try?` reverts every preset to the stock four |
| **J3-02** | S1 | a filename template that renders empty makes `folder.appendingPathComponent("")` yield `.../Deliveries.jpg` — the whole batch is written BESIDE the folder the open panel granted |
| **KG-01** | S2 | with >1 photo selected every crop/angle/ratio write is computed from the PRIMARY's frame dimensions and stamped on all targets — K-023's exact defect, in the one place its fix does not reach |
| **KG-02** | S2 | `O` calls `setMasking(true)` instead of the `toggleMasking` entry verb, so the crop tool stays armed inside the mask editor |
| **A1-01** | S2 | Contrast clips 1.875 stops of highlight and 3.037 of shadow where the tooltip, docs/04 and the test all promise it cannot |
| **A1-03** | S2 | Whites/Blacks silently drag every Zones pivot; Whites +100 alone moves "Midtones" to −0.96 EV while the strip's handles do not move |
| **I3-01** | S2 | `recordDeveloped` files a viewer-sized settle at the fixed 2560 rung, so the loupe's first frame after an edit comes back SOFTER — against the "never upward" rule `PreviewCache` states in its own header |
| **I3-02** | S2 | `trimDecodeResidency`'s 768 MB is not a bound: the two passes spare `sourceOrder.last` and `suffix(4)`, an inspection plane is budget-exempt, so the enforceable floor is 1792 MB |

Full files: `w2/M.md`, `w2/J3.md`, `w2/A1.md`, `w2/K-area.md`, `w2/I3.md`.

### The audits corrected themselves, which is the point of reading them

- **J3 closed five known-open rows** by verifying rather than assuming: K-024, K-025,
  K-026, K-096, K-065. It also found K-015 FIXED-SINCE, correcting J1's row, and
  K-103 INVERTED — watermarking is fully built and docs/11 still calls it deferred.
- **K filed nothing for the thing its brief suspected.** `sourceNormalized` and
  `displayedNormalized` are exact inverses by construction (one `geometryRects` call
  feeds both), and the flip/crop composition, the canvas tilt's sign, `usableSize`'s
  join at 45 degrees and a crop's CanonicalJSON round trip were all verified by hand
  and recorded as correct. That list is worth as much as the defects.
- **A1 found its own area's test to be a tautology**: `testContrastPinsTheEndsOfTheScale`
  probes ±12 EV, exactly where `smoothstep(4, 12, |d|)` is 1 by construction, while the
  picture is formed against anchors at +5/−9 EV. Green, and blind.
- **J1-03's audit was half wrong and I checked it before fixing it.** It said
  `sidecar_mtime` "is not updated by the flush at all". It is — `setSidecarMTime` runs
  on every successful write with a known `photoID`. The stale-read half was real; the
  mtime half was not, and the fix does not pretend to close it.

### The RAW corpus lane
`.github/workflows/raw-corpus.yml` + `w6/raw-corpus-plan.md`. 16 CC0 files, 233.9 MB,
12 containers, 12 manufacturers, Bayer in three phases plus X-Trans, monochrome and
Foveon; four real rotated files in both directions. **No goldens** — exactly one number
is pinned per file (the EXIF orientation tag, which lives in bytes a sha256 already
froze); every other assertion is a property of any photograph or a cross-check between
two independent readers. **It has never run.** Read plan §9 before reading a failure.
Its first run answers a question this project does not currently know the answer to:
whether `CIRAWFilter.nativeSize` is oriented or in sensor order — several caches and
ladders quietly assume one.

## Waves
- [x] W0 — ledger K-001…K-104, perf baseline, 42 briefs
- [x] W1 — 7 dossiers + gap table
- [x] U0 — mockup published and **APPROVED** by the owner ("build it")
- [x] W2 — **13 of 13 areas audited** (the trimmed set): C1 F3 F5 · A2 B1 C2 F1 F4 G1 G2 I1 J1 L
- [ ] W3 — verification of the ~90 findings W2 produced
- [ ] W4 — triage into landing order
- [~] W5 — implementation IN PROGRESS, see Landings
- [ ] W6 — re-audit, perf after, docs/38, report

## Decisions taken since the plan
- Audit trimmed from 30 areas to 13 (owner: "trim discovery, spend it on fixes").
- **L0 dropped** — the four-file `AppState` split. The L audit confirms it was right:
  7 privates would widen across stream boundaries, 73 `@Published` and 13 `didSet`
  cannot move, and it is unverifiable locally on the SHA every worktree branches from.
- **Two UI-direction entries corrected** where the approved mockup silently reverted the
  owner's own recorded requests (see PLAN.md §The UI direction): radii stay 6/9/14, and
  hover paints only clickable things, never a slider row. His words beat my mockup.
- **One fix refused**: writing `xmp:Rating` = −1 for a reject. It broke a pinned
  contract (`testFlagAndRatingSurviveEachOther`) that exists so a frame can be four
  stars AND rejected. The read half landed; the interop gap is written up.

## Landings (SHA · what · CI)
| SHA | Landing | CI |
|---|---|---|
| cc82116 | base | green |
| d5d7136 · 64ae6da · fce5936 | N-001: three dead GPU mask kernels revived (two reserved words, then a vertical flip); checker pass 13 + 2 fixtures | gpu-parity **green** on fce5936 |
| 903ad4d | `ci.yml` `paths-ignore: docs/**` | green |
| 6f07572 | **F3-01** canvas gesture no longer writes to every selected photo · **F3-03** an absent mask input no longer selects the whole frame when inverted | in 27b8372's run |
| 2083f92 | **F4-01** picker flags keyed by mask · **F4-02** `MaskSelection.activeComponent` — a disclosed-but-unselected mask stops editing another mask's component | cancelled by the next push |
| 27b8372 | **F1-01** Delete removes the mask, not the photograph | build-macos ✅ app-bundle ✅ engine-linux ✅ fixtures ✅ test-fast running |
| 7bd7fdf | **K-053** a rating keystroke stops deleting another tool's colour label · **K-054** Lightroom's reject survives the trip in | held until 27b8372 reports |

**Seven S1s landed.** Four were found tonight (F3-01, F3-03, F4-01, F4-02); two of those
were regressions in code that shipped this morning.

## Landed, batch 2 (after ac5570d)

| SHA | Landing | Proof |
|---|---|---|
| 31ef62a | **L-01 / A2-01** a grading-wheel drag is one undo step, not two per mouse event — gesture epoch as the first coalescing clause | substitution: "480 is not equal to 1 — a four-second wheel drag produced 480 undo steps" |
| 3fbb096 | **B1-02** Point Colour stops rotating the hue of near-neutrals — chroma gate hoisted out of the Variance branch | substitution: "60.00000000000068 is not less than 1.0", both controls stay green; `pointColor.hue` proof record expected to move — re-pin pending the local drift run |
| cf9fb58 | **I1-01 + I1-03** a settle joins or steals the bake the drag already queued (245–319 ms off the release of Whites/Saturation); background bakes and joins counted on the HUD (`d`/`j`); `resetStats` zeroes per-slot traffic too | substitution in two rounds: read-side door removed → "2 is not equal to 1"; store-side pending clear removed → "baked twice: once by the settle and once again by the drain" |
| 56008bf | **C2-01** (corrected) the blue grain record is the same texture in preview and export — one half-pixel floor, not two | 5 tests; the red/green no-op is pinned across 6 stocks × 4 resolutions |

**Audit corrections made while landing** — recorded because W3 would otherwise re-find them:
- **C2-01 named the wrong channel.** The double floor is provably a no-op for `sizeScale ≤ 1`
  (red 0.8, green 1.0): `max(max(x,½)·s, ½) = max(x·s, ½)` for `s ≤ 1`. It is real for BLUE
  at 2.0 (Velvia 17.2 %, Ektar 0.45 % preview↔export divergence → exactly 0 after). The
  red 46 % / green 17 % divergences the finding headlined are the floor itself and need
  R7 C.2.3's band-limited plate — **still open**, filed as C2-01b.
- **G2-12's glyph radius** (2.5 in `LumenBehaviourGlyph`) is correct: the canvas is 14 pt
  tall, the box ~8, and `radiusChip` on it is a capsule. Reverted with the reasoning in
  the file.
- **G2's "pitch = 24" for the slider row** would have made the column tighter than the
  build the owner called "back to back to back" — his words beat the mockup (third time
  this round: radii, hover, now pitch). Reconciled: row 24 (his number), inner air kept,
  the vestigial outer point (it separated HOVER fills, and hover is gone) dropped →
  pitch 28, on the grid, exactly what he approved.
- **The mockup's focus ring** on slider rows contradicts *"it gets a blue border around
  it, which I don't want"* (`LumenFocus.swift`). Scoped: rows keep `lumenFocusSurface`;
  `lumenFocusRing` exists for controls with no groove (menu trigger, switches).

## U1 — in progress on the tree (uncommitted until the drift run frees `.build`)
Tokens: text 0.86/0.62/0.48 · `hoverLift` +0.03 additive via `Lumen.hovered(on:)` ·
`focusRing` accent@60 1.5 pt · `hudFill` black@72 + `lumenHUD()` · `rowHeight` 24 ·
type 12 semibold / 11 / 10 / 11 tabular. Radii **unchanged** (6/9/14 + `radiusTab` 12 —
the rail tab's own argument stands). 53 section headers to mixed case through
`.lumenHeading` (it had zero call sites); `LumenCapsLabel` to one size (10). Cursor leak
(G2-05) closed by one balanced modifier for all three cursors. Switch spring 0.22→0.12;
checkbox hover on the surface not `.brightness`. Menu: hairline retired, glyphs to the
10 pt floor, trigger gets additive hover + focus ring. Slider readout is a pill (well
fill, modified border in the 0.72 grey), `valueWidth` 44→48 with the pill's air inside
the column. Badge → HUD pill. `DesignSystemTests`: three prohibitions (no hover/ring on
the slider row, headings through the token, cursor pushes only through the modifier) and
five ratchets (raw font sizes 199, 9 pt 37, raw radii 34, hand-rolled HUD fills 19).
**Correction to d15e663's own message:** it says the slider row's pitch becomes 28. It
does not — the row is 24, its padding makes 28, and the panels stack rows at
`VStack(spacing: 2)`, so the pitch is 30. The touch target (28) and the owner's row
number (24) are both right; the stack's two points are U2 item 5's, changed per file
with each stack's contents read rather than by a blind sweep of thirty-one sites. The
comment in `LumenControls.swift` now carries the arithmetic.

**And `valueWidth` is 52, not the 48 that first landed.** G1 §2 measured the binding
case — Black target's `15.000` at three decimals, 41.2 pt while scrubbing, where the
readout goes medium weight — and said a pill needs ≥ 52. At 11 pt that is ~37.8, which
makes 48 sufficient by two tenths of a point: inside the error of estimating a font
metric, for four points of track worth 0.03 pt per unit at the default width.

**Deferred to U5:** toggle-row keyboard focus — space is a global hold key in `Keymap`,
so the row would need the dispatcher yield the slider has.

## Landed, batch 3 (after 0816fc4)

| SHA | Landing |
|---|---|
| 55d03cc | **I1-05** a table another pane is using stops being evicted mid-drag; `valueWidth` 48→52 and the pitch arithmetic corrected |
| 2b23c62 | **U2** panels on one rhythm — doubled headings, truncated labels, the last two rules, one pitch, paired insets, 33 font calls to tokens |
| 80954db | **Lights out (`L`) and the ISO 12646 assessment surround (`⌘B`)** built, so the three keymap moves land on features that exist |
| 8a299a5 | **Proof ceremony**: `pointColor.hue` and `.range` re-pinned after the chroma gate |
| 8987690 | **U4 first half**: every overlay, badge and the floating masks panel on one HUD material |
| 4e11740 | **B1-01** a Point Colour swatch selects its own colour instead of the whole frame, plus its ceremony (all five records) |
| 796618a | **K-016** export presets survive a build that adds a field · **K-020** a newer build's edit survives you opening it |
| 7772301 | **K-018** brush strokes are in the backup · **F3-02** a long painting stops deleting the sidecar's copy of itself |
| cf669c1 | The argument order U2 shipped, and the checker hole that let it through |

**EVERY S1 DATA-LOSS ROW IN THE LEDGER IS NOW CLOSED**: K-015, K-016, K-018, K-020,
K-052, K-053, K-054, F3-01, F3-02, F3-03.

## The red streak, recorded because it is the lesson of the night

`2b23c62` (U2) added an `indented` parameter to `LumenSlider`, declared after `bipolar`,
and passed it right after `title:` at four call sites. Swift's memberwise initializer
requires declaration order. **`build-macos` was red from 2b23c62 to 7772301 — five
pushes — and `dev-latest` did not move from 0816fc4 for about two hours.**

`swiftc -parse` cannot see it: argument labels are a type-check question. The surface
checker can, and did not, because `synthesize_memberwise` vetoed `LumenSlider` over
`@State private var wheelSettleCloser: Task<Void, Never>?` — a private OPTIONAL, which
has an implicit nil and is not a memberwise parameter at all. A vetoed struct is not
partly checked; every one of its call sites is silently exempt. Thirteen structs were
vetoed and they were the most-constructed views in the app.

One condition fixed it: **3977 checked call sites and 13 blind structs → 4099 and zero**,
with two new fixtures pinning the hole shut.

**The rule for the rest of the grind: after any change to a shared control's signature,
run `check-swift-surface.py` AND look at `build-macos` on the pushed SHA before starting
the next landing.** A green local triad is not a build.

## Landed, batch 4
| SHA | Landing |
|---|---|
| f586762 | **U3 type**: the ten shell files onto the scale; the 10 pt floor is now zero, not a ratchet; `.lumenCaptionNumeric` for counts. Raw font calls 199 → 84. |
| 0158776 | **C2-01b** the plate is band-limited to the resolution it is sampled at — the real mechanism behind the red/green grain parity loss; ceremony re-pinned `film.grain.size` alone of twelve. |

**Report published** for the owner: https://claude.ai/code/artifact/07e0620e-84bc-4b25-844a-662d4d840395
— what to test in ten steps, the twenty-four landings, and what I got wrong (the red
streak included).

## Queued next, in order
1. ~~**U3 shell**~~ — **done, and this entry was stale for two batches.** The sidebar
   regroup, the status bar's query sentence, the filter bar's move into a popover with
   live counts and the type-scale migration all landed with U2; the last piece was the
   radius pass (21 of 22 raw corner radii onto the 6/9/14 ladder or onto
   `Lumen.swatchRadius(_:)`). Re-check a queue entry against the code before working it.
2. ~~**U4 canvas**~~ — **also largely done.** The on-canvas radial and linear handles
   are built to the mockup: four rim dots, the feather-ring handle on the hit test's own
   two conditions, no rotation knob (the owner: "I just don't want this little lever at
   the edge"). What landed this batch is the drawn dot radii moving onto `MaskHandles`
   beside the grab radius they must stay smaller than. Left: before/after chrome and the
   collapsed mask column.
3. ~~**U5**~~ — **done.** Four landings:
   · the type scale split from a GLYPH scale, because an SF Symbol's point size is not a
     type size — which is why 89 raw sizes survived three migrations. 37 glyphs were
     already wearing text tokens. Now 35 raw sizes, and a check that fails on the next
     `Image` given a text token.
   · **one empty state replacing five** — four mark sizes, three text treatments and four
     stack spacings for one idea. This is the failure the design tests could not see:
     every one of the five spelled its tokens correctly, and what repeated was a SHAPE.
   · **three motions replacing eight numbers**, where a fold animated four ways across
     two curve families in files whose own comments were arguing for one.
   · the keyboard reference already existed and is held to the dispatcher by
     `KeyGrammarTests`; `controlHover` is now derived from `controlSurfaceValue +
     hoverLift` rather than written as 0.27 twice.

   Hover and focus were **already coherent** — the fills go through `Lumen.controlHover`
   or `Lumen.hovered(on:)`, both tokens — so the "sweep" turned up one derivation and no
   defects. Recorded rather than invented.
4. **Engine leftovers** — all of C2 is landed: ~~C2-01b~~ **0158776** ·
   ~~C2-02~~ / ~~C2-03/K-065~~ **6425f60** · ~~C2-05 halation Size and Redness~~,
   ~~C2-06~~, ~~C2-07~~ in the current batch. ~~I1-04 the settle loop~~ **abab18a**.
   Still open: **I1-02** (fix the DragProbe so N-002's row can be re-measured),
   **C2-04** (the floor's own test asserts the divergence), **N-005** (the three
   "independent" plate seeds correlate), **N-006** (halation's unused
   `normalizedWeights`, so Amount is scaled by 1.75)
5. **W3/W4** verification and triage of the ~70 W2 findings not yet landed
6. **W6 close** — re-audit each landing against its finding, perf probes against
   `w0/perf-baseline.md`, `docs/38-the-grind.md`, and the owner's report

## Rule learned: docs-only pushes cancelled the code push's CI
`ci.yml` triggered on every push and its concurrency group cancels in progress, so
each STATUS/ledger push cancelled the run verifying the previous code push — and its
`app-bundle`. Fixed in `ci.yml` with `paths-ignore: docs/**`. For W5: commit docs with
the code they describe, and never push prose while a code run is in flight unless
the run is already past `app-bundle`.

## Mechanism change (W2/W3), recorded
The Workflow tool caps concurrency at min(16, CPUs−2) per run and this box has 4 CPUs
→ 2 agents at a time; a 30-area run would take hours. The Agent tool fan-out ran seven
research agents concurrently without a cap, so W2 audits run that way (one background
agent per area, briefs unchanged) and W3 runs as **two independent refuters per area**
— lens A (by-design / already-fixed / duplicate / scope) and lens B (evidence /
severity / numbers / reproducibility / the test) — writing `w3/<code>-a.md` and
`w3/<code>-b.md`. W4 treats a finding as CONFIRMED only when both lenses confirm it.
The per-finding refuter design stays in `briefs/w3-common.md` as the standard each
lens applies to every finding.

## W2 progress
- 21:52 launched F1–F5, I1–I3 (masks + pipeline) — before the gap table, since those
  areas lean on code and K-rows.
- 21:57 gap table landed (a60b016); launched A1, A2, B1, B2, B3, C1, C2, D1, D2, E1,
  E2, G1. **The Agent tool caps at 20 concurrent** — G2, G3, H1, H2, J1, J2, J3, K, L,
  M are queued and launch as the first batch frees slots (~22:22). On a reset: launch
  any area whose `w2/<code>.md` is missing, 20 at a time.
- W3 (two lenses per area) launches per area as its `w2/<code>.md` lands.

## Streams (W5)
_not started_

## Two things found while landing, both worth their own row

**C2-01b did not reach the film path's GPU plate, and no test could see it.** The
band-limited plate landed in `ReferenceRenderer` and in `RenderGraph`'s creative
builder; the film path had a SECOND CIImage plate builder in `PipelineRenderer`, and it
kept asking for the unlimited plate. So a stock's grain on screen and in the exported
file went back to carrying exactly the aliasing that fix removes. `GrainPlateTests`
pinned the two builders together and stayed green throughout, because it compared what
both of them asked for when asked for the *unlimited* plate. Fixed by deleting the
duplicate: there is one builder now, `RenderGraph.grainPlate`, and
`testThereIsOneGPUPlateBuilderAndItAsksThePlanForItsScale` reads
`Sources/LumenPipeline` as text and fails if a second one appears or if anybody reaches
past `GrainPlan` for a raw plate. **Lesson: a test that pins two implementations
together has to exercise them the way the renderer does, not the way that makes them
easy to compare.**

**The three "independent" dye-layer plates are not independent.** `plateSeed(channel:)`
separates the three seeds by adding a golden-ratio constant, and the fields that come
back correlate at r ≈ 0.088 / 0.044 / −0.040 over 16 384 samples — the first is about
eleven standard errors out, so it is structure and not sampling. It makes C2-02's defect
smaller rather than larger, so it is not urgent, and it is the reason the C2-02 mix's
amplitude preservation is a few percent rather than exact. Worth a plate-generator look
in W3.

## Notes
- **U0 mockup published**: https://claude.ai/code/artifact/d2b27d8f-e938-4f72-a402-2d638cd52f9b
  (Develop / Masking / Cull scenes, Current ↔ Proposed toggle, live slider states, `B`
  for assessment mode). Awaiting the owner's yes/adjust; UI streams wait on it.
- W1: r1, r2, r3, r5 on disk and committed (944f3da); r4, r6, r7 running.
- N-001 chain: d5d7136 (`long`→`edge`) → sentinel found `maskFold` dead too → 64ae6da
  (`out`→`folded`, checker pass 13) → parity tests ran for the first time: **GPU alpha
  vertically mirrored** (23 failures / 3 tests) → flip fix pushed. **64ae6da's dev
  build drew mirrored gradient masks** (app-bundle publishes regardless of tests) —
  superseded within ~15 min. Lesson for W5: an engine landing that un-skips tests can
  ship a regression through app-bundle before the lane reports; treat "first real run
  of a previously-skipped test" as an engine-window event.
