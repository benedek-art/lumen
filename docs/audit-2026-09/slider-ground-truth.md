# Slider ground truth — every open defect, re-verified against the tree

The owner asked for every slider to be verified. Before fixing anything, the record had to be
trustworthy: `docs/audit-2026-09/ledger.md` and `STATUS.md` disagreed on four rows, several
STATUS entries carried stale trailing "NOT FIXED" text from before a landing, and 76 commits
had touched the engine, the recipe or the develop panels since the audit was written.

So fourteen agents re-checked every open slider defect against HEAD — seven auditing a control
family each, then seven more whose only job was to REFUTE what the first seven claimed,
defaulting to refuted when a claim could not be independently reproduced. A defect that
survives that costs real engineering time, so a false positive is expensive.

**Result: 49 claims survived. 2 were refuted.**

**Count the survivors carefully — 49 headings are 47 defects.** `K-075` and `TONE-30` are each
written up twice, once per family, because each belongs to two. Anyone cutting a work list
straight from the headings will schedule those two jobs twice.

**Landed since this run: A1-01, B2-02, K-039, B1-08 and the histogram's second write path**,
each marked at its own entry with what shipped. That leaves **43 still open — 20 S2, 22 S3, and
`NEW-typing-bypasses-step`, which carries no severity because the refute pass concluded it
carries no engineering cost either.**

The evidence sections are left as they were measured — they are the record of what was true
when the run was made, and rewriting them would destroy the thing this document is for.

The adversarial half earned its place beyond the two refusals: it CORRECTED several survivors
whose substance held but whose headline did not. A1-02 is the clearest — the ledger says "the
entire positive half of the Brights zone renders one identical picture", and the measurement
says the positive half moves the frame by 19.4 code values. What is true is narrower and is
recorded below. A claim that overstates is a claim that gets dismissed when someone checks it.

Every entry below carries the family's measured evidence. Nothing here is a reading of the ledger; the ledger is what was being checked.

## Tone and Zones

### A1-01 — S2 — **LANDED**

> **Fixed.** The reach is the distance to the anchor on the side being mapped and the slope
> eases to exactly 1 there, so `d · 1 == d` makes the anchor a fixed point of the mapping and
> the promise is geometry rather than a wide-enough window. Shipped in two steps, and the
> second is the honest part: easing from the pivot outward pinned the anchor but cost
> `tone.contrast` a third of its authority (81.42 → 54.83, below its own declared floor of
> 55), so the slope now holds undiluted across the inner 20% of the reach and eases over the
> rest — a film curve's straight section, shoulder and toe. Authority 68.38, and the trade
> against the zonal limiter is tabulated at `ToneEngine.contrastShoulderStart`.

Contrast's slope-relax window is still denominated on two constants (4→12 EV) while the
display transform saturates at the +5/−9 EV anchors, so Contrast +100 flattens the top 1.875
stops and the bottom 3.037 stops of the real range to one value — and the tooltip, docs/04 and
the green test all still say it cannot.

**What the photographer sees.** Pushing Contrast to +100 renders everything from scene +3.125
EV up as one flat 255 (cloud edges in a sky gone) and everything from −5.96 EV down as one
flat display black. At +50 he still loses 1.15 stops of sky. The slider's own tooltip promises
this cannot happen.

<details><summary>Evidence</summary>

Sources/LumenCore/Engine/ToneEngine.swift:485-486 `public static let contrastRelaxStartEV:
Double = 4` / `public static let contrastRelaxEndEV: Double = 12`, used at :497 `let relax =
Num.smoothstep(Self.contrastRelaxStartEV, Self.contrastRelaxEndEV, abs(d))`.
Sources/LumenCore/Engine/DisplayTransform.swift:281 `let X = Num.saturate(x)` clamps the curve
argument, so every scene value at or above whiteAnchorEV returns exactly display white.
MEASURED against the built LumenCore (probe linked to .build/debug/LumenCore.build):
ToneEngine(tone: Tone(contrast: 100)).contrastMapped(5) = 7.87109375 EV against a +5 EV
anchor; contrastMapped(-9) = -10.70859375 against a −9 EV one. Bisecting contrastMapped(t)=+5
gives t=3.124999999999999 → 1.8750000000000009 stops crushed; contrastMapped(t)=−9 gives
t=−5.962734343524412 → 3.037265656475588 stops. Contrast +50: 1.1538 and 1.2792 stops. Through
ReferenceRenderer.render on ProofFrames.neutralRamp (−8…+5 EV, 256 columns): Contrast 0 → 0 of
256 columns at 255.0000 and 1 of 256 tied to the darkest value; Contrast +100 → 34 of 256 at
exactly 255.0000 and 40 of 256 tied to the darkest; Contrast +50 → 19 at 255.0000. (34 columns
= 1.73 EV, 40 = 2.03 EV — the shadow figure is the analytic 3.037 stops truncated by the
ramp's −8 EV floor.) The three contradicting statements are all still in the tree:
Sources/LumenApp/BasicPanel.swift:481-484 help text "...the ends of the scale stay pinned, so
it cannot clip a highlight."; docs/04-spec-tone.md:273-274 "soft saturation of the slope's
effect beyond ±4 EV from the pivot so extremes compress instead of exploding";
Tests/LumenCoreTests/EngineTests.swift:351-359 testContrastPinsTheEndsOfTheScale still loops
`for t in [-LumenLog.maxEV, LumenLog.maxEV]` (LumenLog.maxEV = 12,
Sources/LumenCore/Color/LUT.swift:30) — I ran it: PASSES in 0.0s. GIT: the only commit
touching ToneEngine.swift since the audit base cc82116 is 69a4cbd (the zonal-limiter half-
split); it does not touch the relax constants or contrastMapped.

</details>

### A1-03 — S2

Zone pivots are still stored on a normalized axis divided by the LIVE anchors while
Zones.defaultPivots is derived once from the DEFAULT anchors, so Whites +100 alone walks
"Midtones" to −0.9643 EV and Whites+Blacks +100 walks it to −1.5000 EV, with the strip's
handles fixed in x.

**What the photographer sees.** He sets a zone stack on a face, nudges Whites to hold a
specular, and the face moves a full stop. Every Zones handle is exactly where he left it, so
there is nothing to undo and nothing to blame.

<details><summary>Evidence</summary>

Sources/LumenCore/Engine/ToneEngine.swift:505-509 `public func normalizedAxis(_ t: Double) ->
Double { let span = whiteAnchorEV - blackAnchorEV; …; return Num.saturate((t - blackAnchorEV)
/ span) }` — the live anchors, written at :133-134 `let hi = Self.defaultWhiteAnchorEV -
Self.whiteBlackRangeEV * whites` / `let lo = Self.defaultBlackAnchorEV -
Self.whiteBlackRangeEV * blacks` with `whiteBlackRangeEV = 1.5` (:46).
Sources/LumenCore/Recipe/Recipe.swift:511-514 `public static let defaultPivots: [Double] =
[-4.0, -2.0, 0.0, 2.0, 4.0].map { ($0 - ToneEngine.defaultBlackAnchorEV) /
(ToneEngine.defaultWhiteAnchorEV - ToneEngine.defaultBlackAnchorEV) }` — solved once, from the
defaults. MEASURED scene EV of the five pivots (Dark/Shadow/Mid/Light/Bright): W=0 B=0,
anchors +5.00/−9.00 → −4.0000 −2.0000 +0.0000 +2.0000 +4.0000. W=+100 B=0, anchors +3.50/−9.00
→ −4.5357 −2.7500 −0.9643 +0.8214 +2.6071. W=0 B=−100, anchors +5.00/−7.50 → −3.0357 −1.2500
+0.5357 +2.3214 +4.1071. W=+100 B=+100, anchors +3.50/−10.50 → −5.5000 −3.5000 −1.5000 +0.5000
+2.5000. W=−100 B=−100, anchors +6.50/−7.50 → −2.5000 −0.5000 +1.5000 +3.5000 +5.5000.
Reproduces the dossier table to four decimals. The strip draws in normalized x from
`normalizedPivots` (Sources/LumenApp/ZonesPanel.swift:192-201), which never consults an
anchor, so the handles cannot move — under a header that claims "the picture and the maths
cannot disagree" (ZonesPanel.swift:244-245). The guarding test cannot see it:
AccuracyProbeTests.testTheDefaultZonePivotsSitAtTheirDocumentedEVs builds default anchors only
— I ran it, PASSES in 0.001s.

</details>

### K-039 — S2 — **LANDED**

> **Fixed.** `SliderScale` gets its third case, `.log`, and the row asks for it. The
> default moves from 14.1% of the track to 58.8%; 1.0 — the identity of a slope — lands
> dead centre, because 0.1 is a tenth and 10 is ten times; and the 1.0…1.9 working band
> goes from 9.1% of the travel to 13.9%. The step stays in value units, which is this
> file's rule for every scale and which the first version of the ratio test got wrong
> before the test was corrected rather than the axis bent. `RenderContrastScaleTests`
> guards the call site by text, because `LookPanel` is macOS-only and no compiler on the
> Linux lane sees a missing argument there.

The Render Contrast row still ships on a linear 0.1…10 track where docs/04 specifies log-
scaled — the default sits at 14.14 % of the track and the 1.0–1.9 working band is 9.09 % of it
— and SliderScale still has no log case.

**What the photographer sees.** Nine tenths of the Render Contrast track is above 1.9, a
region nobody uses; every meaningful setting is crammed into the first ninth, one 0.05 step
apart.

<details><summary>Evidence</summary>

Sources/LumenApp/LookPanel.swift:1173-1181: `LumenSlider(title: "Contrast", value:
renderBinding("render.contrast", …), range: 0.1...10, defaultValue: base.contrast, step: 0.05,
decimals: 2, bipolar: false, …)` — no `scale:` argument, and `LumenSlider.scale` defaults to
`.linear` (Sources/LumenApp/LumenControls.swift:447 `var scale: SliderScale = .linear`,
consumed at :620 and :956). docs/04-spec-tone.md:302 `| Contrast | 0.1–10.0, log-scaled | 1.5
| Slope at mid-gray |`. Sources/LumenCore/Interaction/SliderDrag.swift:51-59 `public enum
SliderScale` still declares exactly two cases, `case linear` (:54) and `case reciprocal` (:59)
— the fix needs a third case as well as the call-site change. Arithmetic on the shipped track:
default 1.5 → (1.5 − 0.1)/(10 − 0.1) = 14.14 %; the band a photographer works in, ≈1.0…1.9 →
0.9/9.9 = 9.09 %. The mechanism exists and is wired elsewhere —
Sources/LumenApp/BasicPanel.swift:227 passes `scale: .reciprocal` for Temp — so this is an
unapplied fix, not a missing one.

</details>

### K-040 — S2

Four of the five Zones sliders go non-monotone above ±1.2733 EV while the visible track runs
to ±3 and the drag to ±5 — 2.36× and 3.93× past monotonicity — and one zone at +3 EV makes
bakeGainLUT's forward clamp fire on 122 of 1024 samples, 11.91 % of the tonal axis.

**What the photographer sees.** Push any of the four lower zones past about +1.27 EV and the
LUT starts pinning: at +3 EV an eighth of the tonal axis renders as one flat value, so a
stretch of the picture posterizes into a band instead of getting brighter.

<details><summary>Evidence</summary>

Sources/LumenApp/ZonesPanel.swift:137 and :166: `range: -3...3, hardRange: -5...5` on the five
zone rows. Sources/LumenCore/Engine/ToneEngine.swift:566-568 is the backstop the ledger
counts: `for i in 1..<mapped.count where mapped[i] < mapped[i - 1] { mapped[i] = mapped[i - 1]
}`, and its own comment at :534-537 says the Zones panel is deliberately outside
solveZonalLimits ("the explicit power tool and would stop being one if it were limited").
MEASURED by replaying bakeGainLUT's exact 1024-sample grid over LumenLog.decode, counting
clamp firings on the cumulative forward pass: Mid at +3.0 EV = 122/1024 = 11.91 %;
Dark/Shadow/Light at +3.0 EV = 121/1024 = 11.82 %; at +5.0 EV Mid = 210/1024 = 20.51 %; at
+1.5 EV = 45-46/1024 = 4.4 %. Largest setting with zero firings, by bisection: Dark 1.2733,
Shadow 1.2734, Mid 1.2734, Light 1.2733 EV — so the ±3 track is 2.36× that and the ±5 hard
range 3.93×. Bright never binds at any setting up to +6 EV, because its shelf sits above the
white anchor. The ledger's own 11.9 % figure reproduces to one decimal.

</details>

### M-03 / K-059 — S2

A short zone-pivot array is still padded with the TAIL of the defaults into an unsorted array,
the tone engine still accepts it on count alone and renders it, and the panel draws a repaired
version — measured 2.0000 stops of disagreement between the picture and the strip, with one
zone made completely unreachable.

**What the photographer sees.** A recipe from a sidecar another tool wrote renders with one
Zones slider silently doing nothing at all, while the strip above it draws that zone as a live
window in the middle of the range.

**Corrected by the refute pass.** Finding stands unchanged. Two immaterial cite nits: `git log
-S"zones.pivots.count == ev.count"` returns two commits, not one — 92a3707 (pre-base) and
2124941, which is the audit commit itself (post-base) and touched only the ledger prose, not
ToneEngine.swift. And two line cites drifted: the count-only guard is at ToneEngine.swift:517,
not :514, and ZoneWeights' "pivots strictly ascending inside [0,1]" is at :12, not :13.

<details><summary>Evidence</summary>

Sources/LumenCore/Recipe/RecipeDecoding.swift:63-71 `static func fixedLength<T>(_ decoded:
[T]?, default defaults: [T]) -> [T]` ends `return decoded + defaults[decoded.count...]` — the
defaults' tail, never re-sorted. Sources/LumenCore/Recipe/Recipe.swift:537-539 `self.pivots =
RecipeWire.fixedLength(try c.decodeIfPresent([Double].self, forKey: .pivots), default:
Zones.defaultPivots)`. Sources/LumenCore/Engine/ToneEngine.swift:514 `let pivots =
zones.pivots.count == ev.count ? zones.pivots : Zones.defaultPivots` — count alone, no
ordering check, and ZoneWeights' own contract (Sources/LumenCore/Model/ZoneWeights.swift:13
"pivots strictly ascending inside [0,1]") is unenforced. MEASURED by decoding real JSON
through Zones.init(from:): `{"pivots":[0.9]}` → [0.9, 0.5, 0.6428571428571429,
0.7857142857142857, 0.9285714285714286], ascending = false, and ToneEngine renders it.
`{"pivots":[0.7,0.8],"mid":{"ev":2.0}}` → [0.7, 0.8, 0.6428571428571429, 0.7857142857142857,
0.9285714285714286]: sweeping x over [0,1] at 0.0005, ZoneWeights.weights(x:pivots:)[2] is > 0
at NO x — the Mid zone is unreachable, and mid.ev = +2.0 renders +0.0000 stops at every t. The
panel's repair (Sources/LumenApp/ZonesPanel.swift:192-201 `for i in 1..<out.count where out[i]
<= out[i - 1] { out[i] = Swift.min(out[i - 1] + Self.minimumGap, 1) }`) turns the same array
into [0.7, 0.8, 0.82, 0.84, 0.9285714285714286], under which Mid does have a window: at t =
+2.50 the engine renders +0.0000 stops while the strip's own pivots imply +1.9749. Max |engine
− panel| over t ∈ [−9, +5] = 2.0000 stops at t = +2.480. GIT: `git log -S"fixedLength" --
Sources/LumenCore/Recipe/RecipeDecoding.swift` returns one commit, 6f66f0c, which `git merge-
base --is-ancestor 6f66f0c cc82116` confirms predates the audit base; `git log
-S"zones.pivots.count == ev.count"` returns only 92a3707, also pre-base. No fix landed.

</details>

### A1-02 — S3

The Brights zone does saturate above its own pivot — +1/+2/+3 EV are byte-identical from +3.78
EV up — and the record's frontLoading 0.9976 is pinned but never judged; but the ledger's
headline ("the entire POSITIVE half renders one identical picture") is measurably FALSE: the
positive half still moves the frame by 19.4 code values.

**What the photographer sees.** Dragging Brights up does open the frame — about 19 code values
from 0 to +3 — but the lift is delivered in the +2…+3.5 EV skirt below the zone's own pivot,
and at and above the pivot itself the three settings render identically. The ledger's "nothing
happens at +1 or +3" is not what the engine does.

**Corrected by the refute pass.** Substance stands. Two of the claim's own column figures are
slightly off. Its scene-EV labels are half a pixel low: ProofFrames builds the ramp with
u=(x+0.5)/width, so the columns it calls +2.867 / +3.375 / +3.781 / +4.188 EV are really
+2.893 / +3.400 / +3.807 / +4.213 EV. And "from +3.781 EV up +1, +2 and +3 are all 255.000"
does not hold at that column — I measure Brights +1 = 254.671 there; the first column where
all three read 255.000 is x=241, scene +4.264 EV. At the pivot column the claim's 251.914 for
Brights 0 is exact, but Brights +1 is 254.994, not 255.000.

<details><summary>Evidence</summary>

Tests/LumenCoreTests/Proof/records/zones.bright.ev.json is unchanged and carries
`"frontLoading" : 0.9976190251055395`, `"authority" : 43.23033167676323`, `"deadSteps" : 0`,
`"smallestLiveStep" : 1.0012561977990515`. I reproduced ProofRunner's own path (Recipe →
RenderPlan(lutSize: LUT3D.exportSize) → ReferenceRenderer.render on ProofFrames.neutralRamp)
and got authority 43.230332 and smallestLiveStep 1.001256 — byte-agreeing with the committed
record, so the record is current, not stale. frontLoading is compared only against the
committed value (Tests/LumenCoreTests/Proof/ProofRecord.swift:99 `&& near(frontLoading,
other.frontLoading)`); no floor exists anywhere and ControlProofTests asserts
authority/deadSteps/givenBack/declaredPlateauSteps instead — that half of the finding stands.
WHAT I MEASURED THAT REFUTES THE LEDGER: peak separation Brights 0 → +3 EV = 19.388 code
values, located at scene +2.867 EV; per-step peaks 0→+1 = 10.046, +1→+2 = 6.470, +2→+3 =
4.805, all far above the 1e-9 dead-step threshold. So the positive half is not one picture.
What IS true is narrower and I measured it column by column on the ramp: at +3.375 EV Brights
+2 and +3 are both 255.000; from +3.781 EV up +1, +2 and +3 are all 255.000; at its own pivot
+4.188 EV all three are 255.000 against Brights 0's 251.914. 18,912 of 24,576 samples are
byte-identical between Brights 0 and +3. Also worth correcting: ProofMetrics.sweep builds
`cumulative` from index 1 (Tests/LumenCoreTests/Proof/ProofMetrics.swift:172-176), so
`cumulative[count/2]` reads at travel step 11 of 20 = setting +0.3 EV, not at 0 — frontLoading
0.9976 is "peak-from-the-low-end saturates once the peak pixel clips", not "the top half is
dead".

</details>

### A1-05 — S3

Whites' shelf (+1.0…+4.0 EV) still lies entirely inside Highlights' rising ramp —
highlightWeight is 0.8960 at Whites' own end point, not 1.0 — and the file's stated "Blacks'
steepest point around −5.9 EV" is 2.435 stops from the −3.465 EV the constants actually
produce.

**What the photographer sees.** Highlights −60 then Whites +60 do not give back what the first
slider took: both are working the +1…+4 EV stretch and partly cancelling, where the two
tooltips describe two different jobs.

**Corrected by the refute pass.** The two headline facts hold. One supporting sentence in the
claim is wrong: "Highlights' slope at Whites' end point is still the largest it gets" is
false. highlightWeight is smoothstep(0, 5, t), whose slope peaks at 0.30000 at t=+2.5 and is
0.19200 at t=+4.0 (and also 0.19200 at t=+1.0). The defensible version is that Highlights'
STEEPEST point (+2.5 EV) sits in the middle of Whites' shelf, not that the shelf's end point
is where Highlights is steepest.

<details><summary>Evidence</summary>

Sources/LumenCore/Engine/ToneEngine.swift:79-81 states the design as a fact: "They start above
where Highlights and Shadows have already saturated, so the two controls act on different
parts of the range instead of fighting for the same one." Constants unchanged: `endShelfStart:
Double = 0.20` / `endShelfEnd: Double = 0.80` (:82-83), `highlightShelfEnd: Double = 1.0`
(:66), `blackShelfStart: Double = 0.15` / `blackShelfEnd: Double = 0.62` (:88-89),
`shadowShelfEnd: Double = 0.5` (:77). MEASURED on ToneEngine() at default anchors — t /
highlightWeight / whiteWeight: +1.0 / 0.1040 / 0.0000; +2.0 / 0.3520 / 0.2593; +3.0 / 0.6480 /
0.7407; +4.0 / 0.8960 / 1.0000; +5.0 / 1.0000 / 1.0000. So
highlightWeight(endShelfStart·whiteAnchorEV = +1.0) = 0.10400000000000002 and
highlightWeight(endShelfEnd·whiteAnchorEV = +4.0) = 0.8960000000000001 — Whites' whole travel
sits inside Highlights' ramp, and Highlights' slope at Whites' end point is still the largest
it gets. Second half, the stale sentence at :86-87 "Shadows' steepest point is around −2.2 EV,
Blacks' around −5.9": measured max |d/dt| by 1e-4 sweep over −9.5…0, shadowWeight peaks at t =
−2.2500 (slope 0.33333) which matches, blackWeight peaks at t = −3.4650 (slope 0.35461) —
2.435 stops off the stated −5.9. The two slopes peak 1.2150 stops apart, not the 3.7 the
comment implies.

</details>

### TONE-13 — S3

The "±100 ≈ ∓2 EV, final constants tuned against LrC 15.5 renders of the golden corpus" claim
still has no corpus, no goldens and no test — the only tests pinning ±2 EV compare ToneEngine
against its own constant.

**What the photographer sees.** Nothing directly; the risk is that a Lightroom refugee's
habitual slider positions land somewhere nobody has ever measured, and a constants retune
could move them again with the suite green.

**Corrected by the refute pass.** Finding stands. One supporting stat is understated, not
overstated: `grep -rniE "lrc|lightroom" Tests/ --include=*.swift` returns 33 hits across 21
files today, not 20 across 15 — the extra files are ProofRegistry.swift,
SidecarAndIngestTests, PreviewCacheTests, PolygonMaskTests, LayoutMetricTests and
PanelLayoutBroadcastTests. I read the ProofRegistry hit (:1298, prose about the Colour Balance
grid); every hit is still prose and none is an LR render or a tonal comparison, so the
conclusion is unaffected.

<details><summary>Evidence</summary>

docs/04-spec-tone.md:149-152 still reads "Calibration: ±100 on Highlights/Shadows ≈ ∓2.0 EV of
peak zonal gain; ±100 on Whites/Blacks ≈ ±1.5 EV of end-point shift — final constants tuned
against LrC 15.5 renders of the golden corpus so a Lightroom refugee's habitual '−60
Highlights, +35 Shadows' lands within visual tolerance of what their hands expect." `grep -rni
"lrc|lightroom" Tests/ --include=*.swift` returns 20 hits, all prose in SidecarReseedTests,
SidecarNamingTests, RejectMarkerTests, BrushStabilizerTests, PasteMasksTests,
MaskHandlesTests, DenoiseTests, ViewingConditionsTests, MaskWhiteBalanceTests,
EngineIntegrationTests, CaptureSharpenScopeTests, HistogramDisplayTests,
SidecarLabelPolicyTests, LookAmountTests, DenoiseQualityTests — nothing tonal, and none of
them an LR render. The two tests that DO pin the ±2 EV number assert Lumen against Lumen:
Tests/LumenCoreTests/AccuracyProbeTests.swift:94-100 `XCTAssertEqual(…,
ToneEngine.highlightShadowRangeEV, accuracy: 0.05, …)` and
Tests/LumenCoreTests/Proof/FieldBaselineProbeTests.swift:79, :87, :89, all against
`ToneEngine.highlightShadowRangeEV`. No corpus exists: `find . -iname "*lrc*" -o -iname
"*lightroom*"` outside .git returns three markdown documents and no image. The project's own
baselines document says so — docs/26-tone-baselines.md:10-11 "Lightroom cannot run headless on
Linux; the owner-exported LR references (master plan, M2) remain the final leg and slot into
the same tables", and :208-212 still lists them as things that "drop into" the tables in the
future tense. scripts/baselines/ contains only crosscheck.py (RawTherapee + darktable).

</details>

### TONE-30 — S3

look.render.whiteTarget is declared, decoded, round-tripped and read by the engine, and has
zero writers anywhere in Sources/LumenApp — two engine comments in the current tree say so
themselves.

**What the photographer sees.** Nothing — the field is inert. It round-trips through the
sidecar and the catalog carrying a value no surface can set, and a stale-table path in
PlanTableCache is latent only because of that.

**Corrected by the refute pass.** Finding stands. The claim's inventory of writers is one
short: besides FilmLab.swift:1480 and ExportRecipe.swift:765 there is also
LookSubset.swift:529 (`out.whiteTarget = override(own.whiteTarget, carried.whiteTarget)`), and
the live-EDR path reaches the field as `displayWhiteTarget` from
PipelineRenderer.swift:376/:938. All are engine-internal and none is a UI control, so "zero
writers anywhere in Sources/LumenApp" is still exactly true.

<details><summary>Evidence</summary>

Sources/LumenCore/Recipe/RecipeLook.swift:132 `public var whiteTarget: Double?` ("% of SDR
white. nil = follow the display's live EDR headroom"), decoded at :173, and READ at :152-155
inside `RenderParams.resolved(displayWhiteTarget:)`: `if let whiteTarget { p.whiteTarget =
whiteTarget } else if let displayWhiteTarget { p.whiteTarget = displayWhiteTarget }`, feeding
DisplayTransform.swift:161 `let w = Swift.max(p.whiteTarget, 1) / 100.0`. `grep -rn
"whiteTarget" Sources/LumenApp/` returns NOTHING — zero hits. The Display Transform fold in
Sources/LumenApp/LookPanel.swift:1161-1210 ships exactly five controls — Preset (:1161),
Contrast (:1173), Skew (:1182), Hue keep (:1190), Black target (:1200) — so whiteTarget is the
one RenderParams field with no row. Two engine comments state it independently in the current
tree: Sources/LumenCore/Engine/RenderPlan.swift:378-379 "It takes a control over
`look.render.whiteTarget`, which has no UI yet, to make the two disagree", and
Sources/LumenCore/Engine/PlanTableCache.swift:369 "`transform.white` moves only with
`whiteTarget`, which no control writes". The only writers of a whiteTarget anywhere are
engine-internal: FilmLab.swift:1480 `np.whiteTarget = white * 100.0` on a
DisplayTransformParams, and ExportRecipe.swift:765 `whiteTargetPercent`.

</details>

## Colour and Mixer

### B1-04 — S2

`bandWeights` still normalises by the raw sum, so widening one band's ring handle halves its
two neighbours' authority at their own centres, and the ring still draws the raw arc rather
than the normalised weight.

**What the photographer sees.** He widens Red to catch a brick wall, then finds Orange doing
half of what it did five minutes ago on the same photo, with no number anywhere saying why.

<details><summary>Evidence</summary>

Sources/LumenCore/Engine/ColorEngine.swift:595 — `for i in 0..<bandCount { w[i] /= sum }`,
unchanged; `bandCoreMaxDegrees: Double = 44.0` at :127. Measured through `ColorEngine.apply`
on a patch at Orange's own centre (74.23 deg), only Red's core moved: core 22.5 -> Orange
weight at its own centre 1.0000, Orange Sat +100 chroma gain 2.0000, Orange Hue +100 rotation
45.00 deg; core 36.0 -> 0.7432 / 1.7432 / 33.45 deg; core 44.0 -> 0.5027 / 1.5027 / 22.62 deg,
i.e. 49.7% of Orange's (and Magenta's) authority gone. All eight cores at 44 -> every band
reads 0.3358 at its own centre. Red feather 15 -> 60 alone costs both neighbours 40.9% (1.0000
-> 0.5912). The ring still strokes the band's own raw core+feather arc at
ColorPanel.swift:1192-1203, not the normalised weight. Partial mitigation that already existed
at audit time: `MixerBandRibbon` (ColorPanel.swift:281, weights from
`ColorPanel.ribbonWeights` :1018-1026) does plot `ColorEngine.bandWeights(hue:arcs:)`, which
is the normalised vector — but neighbours are drawn at 0.30 opacity on a 30 pt strip and
nothing renormalises the engine. No test named for this exists
(`testWideningOneBandDoesNotWeakenItsNeighbours` is absent from Tests/).

</details>

### B1-06 — S2

The H-K term still feeds OKLab chroma scaled by 0.40 into a formula that expects CIE 1960
S_uv, delivering Nayatani's effect at roughly 1/19 to 1/40 of its published magnitude.

**What the photographer sees.** Nothing directly — that is the finding. Vibrance and
Saturation are, to within about 1%, plain OKLab chroma scales, while docs/05, docs/24 and
ColorEngine.swift:18-20 all sell them as H-K-corrected.

**Corrected by the refute pass.** Holds, with two numbers loosened. (1) The damping range is
wider than "1/19 to 1/40": the sRGB green primary (C_OKLab 0.2948) has true S_uv 1.2501
against Lumen's 0.1179, a factor of only 10.6×, so the range across hues runs from about
1/10.6 to 1/40. (2) "the factor spans only 1.0110...1.0195 (1.95% total)" mislabels the span:
1.95% is the maximum departure from unity, while the actual span is 0.85% — which is the same
0.84% the claim separately attributes to the hue-dependent part, since the K_Br term is a pure
constant offset (0.0872·kBr·0.16 = 1.60% of the 1.95%).

<details><summary>Evidence</summary>

Sources/LumenCore/Color/Perceptual.swift:185-190 — `let s = Swift.max(0, chroma) * 4.0` then
`return 1 + (-0.1340 * q(hueDegrees: hue) + 0.0872 * kBr) * s * 0.1`, i.e. S_effective = 0.40
x C_OKLab. Unchanged; `git log -S"brightnessFactor"` shows no H-K commit since fb7bdeb.
Measured with a linked probe using the shipped Rec.2020 matrices and D65 white for the true
S_uv = 13*sqrt((u-un)^2+(v-vn)^2): blue sky C 0.12 -> true S_uv 0.9022 vs Lumen's 0.0480
(18.8x), published Gamma 1.1052 vs Lumen's 1.0056; sRGB blue primary C 0.3132 -> S_uv 2.7061
vs 0.1253 (21.6x), Gamma 1.3195 vs 1.0148; red C 0.20 -> S_uv 3.2068 vs 0.0800 (40.1x), Gamma
1.3116 vs 1.0078. Across all hues at C = 0.40 the factor spans only 1.0110...1.0195 (1.95%
total) and the hue-dependent part — the entire reason the term exists — spans 0.84%. kBr
measures 1.1489 and is a constant, so most of even that 1.95% is a hue-flat gain that cancels
in fromRGB/toRGB round trips.

</details>

### B1-07 — S2

The B&W band gain is still a pure addition on unity with no level normalisation, so moving all
eight sliders together changes exposure on every chromatic pixel while greys stay put.

**What the photographer sees.** His B&W conversion changes exposure as he mixes: the sky clips
or blocks up against a wall that never moves, and compensating with Exposure moves both.

**Corrected by the refute pass.** The mechanism and the code values hold; the EV figure does
not. "+0.45 EV" is log2 of the display-encoded code ratio (175/128 = 0.459). With Σw = 1 and
gate = 1 the engine-level gain at all-bands +100 is exactly 2.0× in linear light, i.e. +1.00
EV — the claim understates its own finding by more than half. Also note the code values are a
naive sRGB encode of ColorEngine.apply's output; the shipping render puts a display transform
after this stage, which will compress the 47-code delta somewhat without changing the +1 EV at
the engine.

<details><summary>Evidence</summary>

Sources/LumenCore/Engine/ColorEngine.swift:1410-1414 — `let w = Self.bandWeights(hue: lch.h)`
/ `let gate = Self.chromaGate(lch.C)` / `gain += w[i] * gate * (blackAndWhiteBands[i] / 100) *
Self.bwKappa`, returned at :1418 as `RGB(gray: Swift.max(0, base * Swift.max(0, gain)))`.
Sum(w) = 1, so gain = 1 + Sum(w_i * gate * band_i/100) and nothing renormalises. Measured
through `ColorEngine.apply`, sRGB code values of the rendered grey with all eight bands set
together: blue sky C 0.12 -> 128 (bands 0) / 154 (+50) / 175 (+100) / 0 (-100); pale skin C
0.05 -> 157 / 184 / 207 / 65; a true neutral -> unmoved at every setting. +47 code values on
the sky at +100 is about +0.45 EV, against 0 on the grey in the same frame. The existing test
file BlackAndWhiteMixTests pins the neutral half
(`testANeutralIsUntouchedByTheMixAtAnySaturation`) and the B1-03 fix, but nothing asserts a
uniform mix is a level no-op; `testAUniformBWMixIsALevelNoOp` does not exist in Tests/.

</details>

### B1-08 / COLOR-01 — S2 — **LANDED (renamed, not re-anchored)**

> **Fixed by renaming the bands, on the owner's explicit choice between the two available
> fixes.** Two names sat more than half a band (22.5°) from their own centre and now do not:
> Green → **Mint** (43.3° → 1.4°) and Blue → **Azure** (31.8° → 1.9°). The other six are all
> inside half a band and are untouched; for Magenta at 15.5° no candidate is materially better
> (Pink 8.5°, Rose 14.6°), so changing it would be a swap rather than a fix.
>
> **The centres did not move**, which is why this cost no `pipelineVersion` bump, no migration,
> and no re-render of saved work — the recipe stores bands positionally and the names reach only
> the panel and one status message. `MixerBandNameTests` now asserts the half-band rule, so a
> name can no longer drift from its centre silently, and `testTheBandCentresAreWhereTheGoldenLockSaysTheyAre`
> fails if someone tries to move a centre under cover of a rename.
>
> **What renaming does NOT fix, and the entry stays open-in-spirit for it:** there is still no
> band centred on ordinary green. The centres either side are 68.2° and 163.3°, and green sits in
> the 95° gap. Only re-anchoring closes that, and re-anchoring is the migration described below.

The band anchor and spacing are untouched, so the eight names still sit off the colours they
name and ordinary foliage is still majority-"Yellow".

**What the photographer sees.** He drags "Green" to deepen leaves and gets 39% of the move he
asked for, the other 61% waiting under a slider labelled Yellow; the eyedropper agrees with
the mislabel rather than rescuing him from it.

**Corrected by the refute pass.** Holds as stated, with one row of the offset table wrong. The
agent's "orange +8.09°" treats linear (1,0.5,0) as "sRGB orange"; the conventional sRGB orange
#FF8000 decodes to linear (1, 0.2159, 0) and lands at OKLCh hue 52.98°, i.e. −21.25° off
Orange's 74.23° centre — matching docs/audit/colour.md's original "sRGB orange=53.0°" and
docs/23-master-plan.md's "~21° off". So the true offset table is green −21.73, orange −21.25,
magenta −15.87, aqua −14.46, yellow −9.46, blue +9.82, red 0.00; the largest is ~21.7°, and
the "27°" headline still does not reproduce (the agent already conceded that). Everything else
reproduces exactly.

<details><summary>Evidence</summary>

Sources/LumenCore/Engine/ColorEngine.swift:101-102 — `public static let bandAnchorDegrees:
Double = 29.23` / `public static let bandSpacingDegrees: Double = 45.0`, with `bandNames` at
:95 unchanged; `git log -- ColorEngine.swift` shows no re-anchoring commit and
`pipelineVersion` has not moved. Measured through the shipped engine (linear sRGB ->
`RGBColorSpace.srgb.matrix(to: .rec2020)` -> `OKLabTransform.working.toLCh` ->
`ColorEngine.bandWeights(hue:arcs:)` at the default arcs): sRGB green hue 142.50 deg -> Green
0.502, Yellow 0.498 (an exact 50/50 split); foliage (0.15,0.35,0.08) hue 135.57 deg -> Yellow
0.610, Green 0.390; sRGB cyan 194.77 deg -> Aqua 0.693, Green 0.307; sRGB magenta 328.36 deg
-> Magenta 0.629, Purple 0.371. Offset of each colour from the centre of the band it is NAMED
for: green -21.73, magenta -15.87, aqua -14.46, yellow -9.46, blue +9.82, orange +8.09, red
0.00 deg. NOTE: I could not reproduce the headline "27 deg" — the largest offset I measure is
21.73 deg on green; every other number in the row reproduces to three decimals. The
alternative fix the brief offered ("ship the eyedropper") did land earlier, at 762e028
(2026-08-29, before the brief was written): ColorPanel.swift:591 `state.beginPick(.mixerBand)`
-> AppState.swift:3395-3401 `ColorEngine.dominantBand(for:arcs:)` -> "Green selected." — but
it reports foliage as Yellow, i.e. it names the same wrong band, it does not correct it.

</details>

## Grading and Colour Balance

### B2-02 — S2 — **LANDED**

> **Fixed.** Both instruments call `Lumen.hueColor` — the OKLCh→working→sRGB conversion the
> mixer's band ring already had right — so the ring paints the colour the engine applies.
> Position is untouched: the puck still reads `atan2(dy, dx)` clockwise from three o'clock,
> so every stored `wheel.hue` means the pixel it always meant. `WheelHueAgreementTests` pins
> the convention on the side that had no test.

The grading wheel is still painted with SwiftUI HSB while the engine reads the same angle as
an OKLab ab angle: measured mean 29.6 deg, max 50.3 deg of hue error over 24 angles.

**What the photographer sees.** He drags the puck into the green of the Shadows wheel and the
shadows come out yellow; into the blue and they come out cyan. There is no numeric H/S readout
on the wheel (LookPanel.swift:877 passes `title: ""`), so nothing on screen contradicts the
colour under the puck.

<details><summary>Evidence</summary>

Sources/LumenApp/LumenControls.swift:2023-2025 unchanged: `static let wheelColors: [Color] =
(0..<13).map { Color(hue: Double($0) / 12, saturation: 0.72, brightness: 0.8) }`, painted at
:1881 `.fill(AngularGradient(colors: Self.wheelColors, center: .center))`, puck placed at
:2010 `.offset(x: r * cos(a), y: r * sin(a))`, drag reads `hue = (atan2(Double(dy),
Double(dx)) * 180 / .pi + 360)...` (:1931). The engine reads that number as an OKLab ab angle
- GradeEngine.swift:212-215 `let radians: Double = Num.wrapHue(wheel.hue) * .pi / 180 ...
self.a = amplitude * cos(radians); self.b = amplitude * sin(radians)`. MEASURED through the
engine's own working context (/tmp/probe/hue.swift), global wheel sat=1 on mid-grey, output
converted Rec.2020->sRGB and read back as an HSB hue: 0 deg -> 337.7 (-22.3), 60 -> 30.9
(-29.1), 90 -> 44.3 (-45.7), 120 -> 69.7 (-50.3), 240 -> 201.2 (-38.8), 300 -> 263.9 (-36.1);
mean |error| 29.6 deg, max 50.3 deg over 24 angles - the brief's 29.6/50.4 reproduced. The
correct function exists one file over and is still unused by the wheel: ColorPanel.swift:1055
`static func hueColor(_ degrees: Double, L: Double = 0.72, C: Double = 0.16) -> Color`; the
only reference to it in LumenControls.swift is a comment at :2021. `git log -S"wheelColors"`
last touched it in 5a29ed0 (2026-08-30), before the brief (2882bb7, 2026-09-02). A test would
live in LumenAppTests, which is macOS-only and cannot run here.

</details>

### B2-04 — S2

At Blending 0 the Luminance ring and every Brilliance zone are still inert over ~95% of their
travel, nothing surfaces the realised strength, and both certifying tests still pass on
increments of 1e-9 or smaller.

**What the photographer sees.** He drags Blending to 0 to get a hard zone separation - the
reason the control exists - and from there the Luminance ring and every Brilliance slider stop
responding. Brilliance Highlights from -5 to -100 does not change the picture by one code
value, and no caption says why.

**Corrected by the refute pass.** Holds as stated; only the two softKnee line cites drifted by
two lines (GradeEngine.swift:428 and :1132, not :426/:1130). Measured flat span at Blending 0
is 97% of travel, not ~95%.

<details><summary>Evidence</summary>

Both solves still close with the same asymptotic knee: `return
Swift.min(Num.softKnee(normalized) / normalized, 1)` at
Sources/LumenCore/Engine/GradeEngine.swift:426 (solveLumScale) and :1130
(solveBrillianceScale). MEASURED (/tmp/probe/blend0.swift), applied ring stops =
0.5*lum*lumScale with mid+lum/high-lum: Blending 0 gives 0.0101122 (lum 0.10), 0.0101135
(0.25), 0.0101136 (0.50), 0.0101136 (0.75), 0.0101136 (1.00) - the whole travel from 0.25 to
1.00 differs by 1e-7 stops; the brief's proposed ratio test (realised at lum 1.0 / at lum
0.25) gives 1.0000035 at Blending 0, 1.0045682 at 10, 1.2175 at 25, 2.4008 at 50. Brilliance
Highlights effective value (|v| * brillianceScale) at Blending 0: 1.3922 (-5), 1.3928 (-10),
1.3928 (-20), 1.3928 (-50), 1.3928 (-100) - the brief's 1.39, reproduced. The code's own claim
at :1068-1069 (`below the knee ordinary settings (the / panel's documented +/-20 working range
included) are exactly unlimited`) holds only for Blending >= 35: a lone Brilliance -20
delivers 20.0000 at Blending 50 and 35, but 17.6708 at Blending 25 and 8.0386 at Blending 10.
Blending is a plain 0...100 slider (LookPanel.swift:679-684). Nothing is surfaced: grep for
lumScale|brillianceScale|jointScale|appliedBrillianceScale across Sources/LumenApp/*.swift
returns zero hits. The two certifying tests are unchanged -
Tests/LumenCoreTests/GradeLuminanceInversionTests.swift:210 `XCTAssertGreaterThan(applied,
previous,` with no epsilon (its own comment at :206-209 says the knee 'gains about 1e-9 per
step' at Blending 0), and :332 `XCTAssertGreaterThan(gain, previousGain + 1e-9,` which never
leaves the default Blending. Both pass today; a 1e-9 threshold on a visible control is a test
that cannot fail meaningfully, and both would still pass if softKnee were replaced by any
strictly-increasing but visually flat function.

</details>

### K-049 — S2

The grading zone pivots are still the guessed [0.33, 0.67], which resolve to -4.38 / +0.38 EV
against the spec's -2.0 / +1.5 EV.

**What the photographer sees.** The Highlights wheel starts acting on mid-grey (31% of the
weight there) and the Shadows wheel does nothing at -2 EV, so 'shadows' on this panel means
two stops lower than the spec and than the photographer's reading of the histogram strip above
it.

<details><summary>Evidence</summary>

Sources/LumenCore/Recipe/RecipeLook.swift:246 `public static let defaultPivots: [Double] =
[0.33, 0.67]` - `git log -S"[0.33, 0.67]"` returns only abd70fa, the repo's first commit, so
nothing has touched it. MEASURED through the engine's own ZoneWindows() at the default anchors
(-9..+5 EV, span 14.0): shadow pivot -4.3800 EV, highlight pivot +0.3800 EV. The spec is
docs/05-spec-color.md:178 `| Zone pivots | Shadow pivot -6 .. 0 EV; Highlight pivot 0 .. +4 EV
(relative to mid-gray) | -2.0 / +1.5 EV |`, which through the same anchors would be pivots
[0.5000, 0.7500]. Consequences measured on the same windows: at mid-grey the Highlights wheel
already carries 30.62% of the weight (sh 0.0000 / mid 0.6938 / high 0.3062), and at -2 EV the
Shadows wheel carries 0.0000. Zones.defaultPivots (Recipe.swift:511) does derive itself from
documented EVs; GradingWheels still does not.

</details>

### B2-06 — S3

The wheels still ship with no modifier grammar, no keyboard focus and no numeric entry, and
the printer lights still spend the spec's coarse/fine modifiers on channel select.

**What the photographer sees.** The wheel is a pure mouse instrument - no fine drag, no hue-
only or saturation-only drag, no keyboard, no way to type a hue - which is the one place LrC's
grammar was promised so nothing would be unlearned. On the printer lights he counts keypresses
in twelves.

**Corrected by the refute pass.** Holds for the wheels (no modifier grammar, no keyboard
focus, no numeric entry, against docs/05-spec-color.md:174, :181 and :208). The printer-lights
half is overstated: docs/05:181's Cmd/Shift/Alt row governs the wheels, not the printer
lights, so the modifiers there are not 'the spec's coarse/fine modifiers' being spent - though
it is true no coarse or fine step exists and a quarter point is unrepresentable.
ControlIndex.swift lives in Sources/LumenCore/Interaction/, and the modifier row is
docs/05:181 not :180.

<details><summary>Evidence</summary>

Sources/LumenApp/LumenControls.swift:1842-2026 `struct LumenColorWheel` has exactly one
gesture (:1911 `DragGesture(minimumDistance: 0)`) whose only event read is
`NSApp.currentEvent?.clickCount` for the double-click reset; a scan of lines 1838-2027 for
modifierFlags / focusable / keyboardShortcut returns nothing, and every drag writes both `hue`
and `sat` (:1931-1933). No numeric field, and the call site passes no label to hang one on:
LookPanel.swift:877 `LumenColorWheel(title: "",`. Spec asks for Cmd = hue-only, Shift = sat-
only, Alt = fine (docs/05-spec-color.md:180), numeric H/S entry (:174) and wheel focus 1-4
with arrow nudges. Printer lights: LookPanel.swift:949-969 spends the modifiers on channels -
`printerRow("Master", "master", lights.master, masterLimit, [],` then `.control` for r,
`.option` for g, `.shift` for b - and the only steps declared are `onStep(-1)` / `onStep(1)`
(LookPanel.swift:1737, 1748), so no coarse or fine step exists and riding the master to +/-48
is 48 keypresses. A quarter-point step is not representable at all: RecipeLook.swift:379-383
`public struct PrinterLights { public var master: Int; public var r: Int; public var g: Int;
public var b: Int }`, and applyPoints (LookPanel.swift:998) takes an `Int` delta. Per-pivot
falloff is still absent from GradingWheels (RecipeLook.swift:227-260 has
global/shadows/mid/high/blending/balance/pivots/colorBalance and no `falloffs`), while
GradeEngine.swift:76-78 still holds two half-widths 'so the per-pivot `falloffs` field the
format is due to gain can drive them independently'. ControlIndex.swift:146-152 lists
look.wheels / look.printerLights / look.primaries and no per-wheel control. `git diff
2882bb7..HEAD -- Sources/LumenApp/LookPanel.swift` shows no wheel/modifier/focus change since
the brief. The proposed tests live in LumenAppTests, which is macOS-only and cannot be run
here.

</details>

## Detail and Denoise

### D2-01 — S2

The shipping GPU Texture is still image minus a SELF-guided filter of itself, so selection is
by contrast (a = var/(var+ε)) and not by scale; no band-stack was ported, and the contrast-
invariance test the finding asks for still does not exist.

**What the photographer sees.** Texture +100 is strongest on flat low-contrast areas — skin,
sky, sensor noise — and weakest on the high-contrast weave and bark BasicPanel promises it is
for, and its passband does not move with resolution the way the reference's does (the audit
measured the GPU returning identical band gains at 2560 px and 6000 px, including 1.718× on
the 2 px scale the reference weights at exactly 0).

**Corrected by the refute pass.** Holds. One evidence correction that cuts against the claim's
framing but not its substance: the roster window 911-925 is cropped — Kernels.swift:933
registers `bSpline5` (the à-trous B3-spline pass, makeGeneral), and
RenderGraph.fineDetailBand:1138-1170 already builds a genuine à-trous band stack over a scale
index on the GPU for S12 sharpening. So the machinery to select by scale exists and ships; it
is the Texture/Clarity stage specifically that was never moved onto it. That makes the port
cheaper than 'no band-stack was ported' implies, not less real.

<details><summary>Evidence</summary>

Sources/LumenPipeline/RenderGraph.swift:635 `let fine = Swift.max(Int((Double(longEdge) *
0.003).rounded()), 2)` and :678 `if d.texture != 0, let baseFine = Self.guidedSelfFilter(lum,
radius: fine, epsilon: epsilon)` feeding Kernels.swift:339-350 `lumenDetailGainGated`, whose
band is still `hi.r - lo.r` off that self-guided base — the exact construction the finding
names. The kernel roster at Kernels.swift:911-925 contains detailGain and detailGainGated and
no band-stack kernel over à-trous scale index. The reference half is unchanged and still
scale-selective: DetailEngine.swift:270-289 `let center = bandCenter(width: w, height: h)`
with realized-weight renormalisation. Two epsilon/perStop fixes DID land in this region since
(RenderGraph.swift:659, :676) but neither changes the selector. `git log --all --grep=D2-01`
returns only the audit report 442ad09; `git log --since=2026-08-25 --
Sources/LumenPipeline/RenderGraph.swift` shows no band-port commit. grep of Tests/ for
Passband / contrast-invarian returns nothing. GPU verdict is by code reading —
TextureSpectrumProbeTests is in LumenPipelineTests and cannot run on Linux.

</details>

### E1-03 — S2

The 'profiled' claim is still unbacked: NoiseProfile.estimate(from:) has zero call sites and
zero tests, the render path always builds the generic per-ISO seed curve, and I reproduced the
σ bias — 1.13× on the easiest input and 3.10× with ordinary texture.

**What the photographer sees.** Nothing today, because the code never runs — every body at a
given ISO gets identical thresholds off the generic seed table. The harm is latent: the moment
anyone wires the estimator docs/07 requires, a textured ISO 6400 frame is denoised as though
it were roughly ISO 60000.

**Corrected by the refute pass.** Holds; the specific numbers in this claim are the low end.
My run of the shipping estimate() reproduces the ORIGINAL audit table (1.32 / 1.38 / 3.33×)
almost exactly — 1.315× / 1.388× / 3.286× — rather than this claim's re-probe (1.125 / 1.148 /
3.098×), because the audit's ramp is the proof frame's own (0.18·2^(−3+5v)) and the claimant's
was gentler. The bias is real, reproducible from the code as written today, and if anything
worse than the claim states.

<details><summary>Evidence</summary>

Sources/LumenCore/Image/DenoiseEngine.swift:139 `public static func estimate(from plane:
Plane) -> NoiseProfile`. A grep of Sources/ and Tests/ for `NoiseProfile.estimate` /
`.estimate(from` returns exactly one hit outside the definition, and it is a comment:
DenoiseEngine.swift:1069 ("...which is what `NoiseProfile.estimate` returns for a clean
plane"). The only profile the render ever builds is
Sources/LumenCore/Engine/RenderPlan.swift:455 `let noiseProfile =
NoiseProfile.forISO(captureISO ?? 100)`. docs/07 line 163 still specifies the other half: "For
unknown (camera, ISO) pairs the model is estimated on first encounter...". Measured (my probe,
built a 256×256 ramp plus Poisson–Gaussian noise from NoiseProfile.forISO(6400)'s own
sigma(at:), then ran estimate on it): PROBE-E103 flat ramp a=6.53e-04 b=3.22e-05, σ(0.18)
est/true = 1.125×; ramp+2% 6 px sinusoid 1.148×; ramp+15% 6 px sinusoid a=6.30e-03 against a
true 6.4e-04, σ ratio 3.098×. Same shape as the audit's 1.32/1.38/3.33× (my ramp is gentler,
so less within-block gradient at the flat end). No commit outside the audit report 102c407
mentions E1-03.

</details>

### E2-01 — S2

Output sharpening is still a bare per-channel CIUnsharpMask over RGB — the one sharpening
stage that reaches the delivered file is still the one that fringes colour, and the code's own
comment still records that deleting the call leaves every suite green.

**What the photographer sees.** Every default web JPEG gets a hue-rotated, saturation-boosted
rim along saturated edges — a red jersey against blue sky — that no view in the app ever
shows, because nothing upstream of the encoder sharpens per channel.

<details><summary>Evidence</summary>

Sources/LumenPipeline/PipelineRenderer.swift:2245-2256: `static func applyOutputSharpen(...) {
guard !sharpen.isIdentity else { return image }; let filter = CIFilter.unsharpMask();
filter.inputImage = image.clampedToExtent(); filter.radius =
Float(sharpen.appliedRadius(printPPI: resolutionPPI)); filter.intensity =
Float(Num.clamp(sharpen.energy(), 0, 2)) ... }` — no KernelLibrary.sharpenDelta, no lumaRatio,
unlike S12 in RenderGraph. The no-test clause is still in place verbatim at :2243-2244
("deleting this call entirely leaves every suite green (OUT-08)"). The default web recipe
still ships it on: ExportRecipe.swift:628-631 `webJPEG` with `sharpen: OutputSharpen(medium:
.screen, amount: .standard)`, and the struct still derives radius 1.0 / energy 0.55·1.0 for
that case. Independent re-derivation (my python probe of out = in + i·(in − G(in, r)) per
channel on a saturated red(1.0,0.05,0.05) → blue(0.05,0.10,1.0) step): Screen/Standard 3.34°
peak hue rotation with saturation 0.950 → 1.000 (clipped); Matte/High (radius 3.0, energy
1.377) 4.59°. Smaller than the audit's 6.5°/15.3° because my edge clips at 1.0 where theirs
was allowed to run to 1.221, but the same defect: a luminance-ratio recombination gives
exactly 0°. `git log --all --grep=E2-01` returns only the audit commit 9982559.

</details>

### K-088 — S2

Capture sharpening (S4) is unchanged — richardsonLucy still has no shipping caller, so Lumen's
own deconvolution never runs on a photograph; the row's second clause ('and untested') is no
longer true, and the auto-σ branch remains reached by nothing.

**What the photographer sees.** The 'capture sharpening' the panel and docs describe as Lumen
measuring this lens's own PSF and deconvolving it never happens; on a RAW the user gets
Apple's at-demosaic sharpener scaled by a percentage, and on a rendered file nothing at all.

**Corrected by the refute pass.** Holds. Two small evidence corrections: the live assertion is
XCTAssertGreaterThan(base.rise / p.rise, 1.1) at FieldBaselineProbeTests.swift:240, not :239
(239 is the comment above it). And there is a second stale artefact the claim does not name:
BUILDING.md:323-324 still asserts richardsonLucy 'appears in no file under Tests/', which the
passing probe above contradicts.

<details><summary>Evidence</summary>

Sources/LumenCore/Image/SpatialOps.swift:613 `public static func richardsonLucy(_ plane:
Plane, sigma: Double, iterations: Int) -> Plane` is called from exactly one place,
DetailEngine.swift:512 inside captureSharpen, which itself is called only from
Tests/LumenCoreTests/Proof/FieldBaselineProbeTests.swift:223. On the shipping RAW path the
sharpener is Apple's (AppleRawSource.swift:317-318). Untested is FIXED-SINCE, and I ran it on
Linux: `swift test --filter FieldBaselineProbeTests` prints "SHARPBASE capture RL psf 1.5 rise
1.37 px recovery x1.53 overshoot 9.5% undershoot 3.5%" behind a live
XCTAssertGreaterThan(base.rise / p.rise, 1.1) at FieldBaselineProbeTests.swift:239. That call
pins `radius: sigma` (1.5), so the auto branch — DetailEngine.swift:506 `sigma =
SpatialOps.estimatePSFSigma(lum)` — is still executed by nothing anywhere.

</details>

### K-090 — S2

The dehaze sky guard is still reference-only: the GPU gets a single scalar transmission floor
for the whole frame, and both the graph and the kernel still say so in their own comments.

**What the photographer sees.** On the GPU — i.e. in every preview and every export — Dehaze
takes its largest correction in exactly the bright flat sky the reference protects, so the
shipped picture diverges from the reference renderer precisely where the control is most often
used.

<details><summary>Evidence</summary>

Sources/LumenPipeline/RenderGraph.swift:879-880 `let distance =
Num.clamp(DetailEngine.dehazeDistance, 0, 100) / 100` / `let floorT = Num.mix(0.55, 0.05,
distance)` — one number, passed as `Float(floorT)` at :896 — and
Sources/LumenPipeline/Kernels.swift:152 `float t = max(raw, floorT);`. Both admissions are
still in the tree: RenderGraph.swift:875-878 ("The reference ALSO lifts it per pixel toward
0.9 where the frame is bright and flat — its sky guard — which needs the gradient and log-
luminance planes the kernel is not given, so that part stays reference-only") and
Kernels.swift:143-145 ("Still missing versus the reference: the sky guard..."). The reference
does it per pixel at Sources/LumenCore/Image/DetailEngine.swift:417-421: `let bright =
Num.smoothstep(0.5, 2.0, logLum[x, y])`, `let flat = 1.0 - Num.smoothstep(0.05, 0.35,
gradient[x, y])`, `let floorT = Num.mix(tMin, 0.9, Num.saturate(bright * flat))`, `let tv =
Swift.max(t[x, y], floorT)`. `git log --all --grep=K-090` returns only the audit report
442ad09.

</details>

### DETAIL-14 — S3

Luminance still gives residual error back across its travel — the best point is now Luminance
~25 and 50 upward is worse than leaving the noise in; the 2.5σ bound reduced the give-back and
the fixing commit explicitly says it did not remove it.

**What the photographer sees.** Pushing the Luminance slider past roughly 25 moves the
photograph further from the clean frame rather than closer; at 50 and above it is worse than
leaving the noise in, and fine texture keeps draining (correlation 0.856 → 0.799 over the
travel).

**Corrected by the refute pass.** Holds, and the claim understates it in one place: the
travel's true optimum is Luminance 15 (3.5058), not ~25 (3.5365) — my 5-step sweep reads
0:3.6235 5:3.5370 10:3.5101 15:3.5058 20:3.5162 25:3.5365 … 100:4.1079 — so top/best is 1.172,
not the 1.162 the claim computes off its 5-point grid. Luminance 100 is 13.4% worse than
undenoised, as stated. Test bound is at DenoiseQualityTests.swift:77, not :76.

<details><summary>Evidence</summary>

Sources/LumenCore/Image/DenoiseEngine.swift:604-608 ships the post-fix table as a comment:
"slider 0 25 50 75 100 / RMS 3.623 3.537 3.711 3.916 4.108" followed by "Still rising, and
honestly so." My own probe (ClassicalDenoise(ClassicNR(luma: s, chroma: 0), profile:
forISO(6400)) over ProofFrames.noisyISO6400, scored by ProofMetrics.rmsAgainst against
cleanISO6400, run in a /tmp copy of the tree): PROBE14-RMS 0:3.6235 25:3.5365 50:3.7114
75:3.9162 100:4.1079; fine-band correlation 0:0.8561 25:0.8432 50:0.8287 75:0.8137 100:0.7986.
Top/best = 4.1079/3.5365 = 1.162, and Luminance 100 is 13.4% worse than undenoised. The suite
only BOUNDS this: Tests/LumenCoreTests/Proof/DenoiseQualityTests.swift:76 is
XCTAssertLessThan(top / best, 1.50). The ISO sweep printed by that file's own test agrees —
"LUMAPROBE ISO 6400: default 25.0 scores 3.4486 best 3.4112 at 10" with the travel rising to
4.0482 at 100. The proof ceremony cannot see it either:
Tests/LumenCoreTests/Proof/records/denoise.luma.json carries "givenBack": 0 and "isMonotone":
true, because ProofRecord.givenBack (ProofRecord.swift:51-58) measures backward steps in how
far the render MOVES, not distance from ground truth. Commit fb5f584's own message: "What this
does not fix, and the reason. Luminance still gives residual error back across its travel."

</details>

### K-075 — S3

detail.capture.radius is still a stored, codable recipe field whose only reader —
DetailEngine.captureSharpen — has no shipping caller; the wire-or-remove decision was half
taken (the panel row was removed) and the field and the engine path both survive.

**What the photographer sees.** Nothing today — no control writes the field any more (the
Radius row is gone), so the user cannot set a number that is ignored. What remains is a dead
field in the recipe and sidecar that DetailPanel.swift:283 still has to clear defensively for
recipes written by other builds.

**Corrected by the refute pass.** Holds on substance — no render stage reads
detail.capture.radius and captureSharpen has no shipping caller — but 'whose only reader is
DetailEngine.captureSharpen' is not literally true. DetailPanel.swift:271 reads it
(`hasCaptureOverride`: `capture.radius != nil`) and :283 writes nil to it
(`clearCaptureOverrides`), with a comment at :279-281 explaining why: a recipe from another
build can carry one. Both are metadata uses; neither reaches a pixel.

<details><summary>Evidence</summary>

Sources/LumenCore/Recipe/Recipe.swift:877 `public var radius: Double? // manual override; nil
= auto-estimated`, encoded at :914 and decoded at :922. Sole reader:
Sources/LumenCore/Image/DetailEngine.swift:503-507 inside captureSharpen. A repo-wide grep for
`captureSharpen` finds exactly one call:
Tests/LumenCoreTests/Proof/FieldBaselineProbeTests.swift:223. The shipping RAW stage reads
only the strength: Sources/LumenPipeline/AppleRawSource.swift:317-318 `filter.sharpnessAmount
= defaultSharpness * Float(dev.detail.capture.strengthFraction)`. The panel's header states
the state plainly (Sources/LumenApp/DetailPanel.swift:17-22): "There is no Radius row and no
Overrides fold... `CaptureSharpen.radius` reaches only `DetailEngine.captureSharpen`, which
has no caller." No commit message anywhere mentions K-075.

</details>

## Film Lab and Effects

### C1-02 — S2

Film Lab Strength scales only the tone blend; halation Amount and grain amplitude are still
step functions of Strength — full-on at 1, unchanged to 100.

**What the photographer sees.** Dragging Strength 0→1 on Portra pops the whole grain field
(0.054 density units at peak) and the full 35% red halo on in a single step; dragging 1→100
changes neither of them. The slider K-045 made continuous for tone is still a switch for the
two spatial stages.

**Corrected by the refute pass.** Holds as stated, with one correction to the evidence, not
the finding: the "Strength 0 → halationAmount 0.350000" row cannot occur on any shipping path.
RenderPlan.swift:251 gates chain construction on `film.amount > 0`, so at Strength 0 filmChain
is nil and both spatial gates fail — that number came from constructing FilmChain directly.
The real shape is 0 at Strength 0, then full value at Strength 1 and flat to 100, which is
still the step function the finding describes.

<details><summary>Evidence</summary>

Sources/LumenCore/Engine/FilmLab.swift:1574-1580 `public var halationAmount: Double { guard
let s = stock else { return 0 } ... return Num.clamp(recipe.halation / 100.0, 0, 1) }` — the
word `strength` does not appear. :1585-1588 `public var grainAmount: Double { guard solved !=
nil else { return 0 }; return grain.amount * FilmGrainProfile.densityScale }`. `strength` is
only spent at :1523-1528 `let base: RGB = neutral.apply(c, gamut: Gamut.sharedBoundary) ...
return base.mix(film, strength)`, i.e. on tone alone. The two spatial gates read the unscaled
scalars: Sources/LumenPipeline/RenderGraph.swift:176 `if let film = plan.filmChain,
film.halationAmount > 0`, Sources/LumenCore/Engine/ReferenceRenderer.swift:114 same, and
Sources/LumenCore/Engine/RenderPlan.swift:290 `self.grain = chain.grainAmount > 0 ?
GrainPlan.film(chain) : nil`. MEASURED (probe linking LumenCore, Portra 400 / halation 35 /
grain 45, longEdge 4000): Strength 0 → halationAmount 0.350000, grainAmount 0.000000; Strength
1 → 0.350000 / 0.054000; Strength 25 → 0.350000 / 0.054000; Strength 50 → 0.350000 / 0.054000;
Strength 100 → 0.350000 / 0.054000. HalationProfile.strength.r is 0.017500 at every one of
those. git log -S over FilmLab.swift shows `halationAmount` untouched since 2fc137f (its
introduction).

</details>

### C1-03 — S2

The Display Transform rows are ghosted at 30% and refuse the drag whenever any stock is loaded
at Strength > 0, while the transform is still most of the picture at every Strength below 100.

**What the photographer sees.** With Portra at Strength 50, half of what is on screen is the
user's own Contrast / Skew / Hue-keep / Black target — and all four rows plus the preset
picker sit at 30% opacity and will not move. The panel says a stage is off while it renders.

**Corrected by the refute pass.** The defect holds, but two supporting statements are wrong.
(1) "No commit in the 771-commit history moves `transformIsInert`" is false twice over: the
history is 767 commits (`git rev-list --count HEAD` = 767), and e741448 rewrote the property —
the old multi-line body became `replacingStock != nil`, the opacity went 0.45 → 0.30, and an
`if transformIsInert` caption block was deleted. The predicate's semantics are unchanged
(filmLab non-nil, amount > 0, stock ships), so the conclusion survives. (2) "most of the
picture at every Strength below 100" is only true below Strength 50; at Strength 75 the
transform is 25% of the blend. "Reaches pixels at every Strength below 100" is the accurate
wording.

<details><summary>Evidence</summary>

Sources/LumenApp/LookPanel.swift:1148 `private var transformIsInert: Bool { replacingStock !=
nil }`; :1142-1146 `private var replacingStock: String? { guard let film =
state.currentRecipe.look.filmLab, film.amount > 0, let stock = FilmStock.named(film.stock)
else { return nil }; return stock.name }`; :1118-1119 `transformControls(base:
base).disabled(transformIsInert).opacity(transformIsInert ? 0.30 : 1)`. The header badge at
:1099-1105 says "replaced by X" at every Strength, and the comment at :1081-1082 still reads
"A loaded stock bypasses this stage completely". The code says otherwise:
Sources/LumenCore/Engine/RenderPlan.swift:267-268 `chain = FilmChain(film, filmExposure:
film.exposure, displayWhite: transform.white, base: transform)`, and FilmLab.swift:1523-1528
`let base: RGB = neutral.apply(c, gamut: Gamut.sharedBoundary); guard let s = solved else {
return base } ... return base.mix(film, strength)` where `neutral` IS the recipe's solved
transform. The panel's predicate is `amount > 0`; the condition under which the transform is
genuinely gone is `strength == 1`. No commit in the 771-commit history moves
`transformIsInert`; it was introduced at 6e0d94b and has not changed.

</details>

### C1-05 — S2

The stock roster is still exactly six; no tungsten stock, no rem-jet-removed variant, no ISO
800, no second slide stock, no T-grain black-and-white.

**What the photographer sees.** Six cards in the Stock picker. The halation engine — the one
feature this panel is built around — ships with no stock whose anti-halation layer has been
removed, which is the look the control exists to produce.

**Corrected by the refute pass.** Every substantive element reproduces; one citation is
misattributed. The quoted text "roster is still six, FilmLab.swift:398-405" is not in the
ledger's K-071 row — ledger.md:88 reads "Film-stock expansion + grain customisation — deferral
lifted" and contains no roster description. The quote is from docs/audit-2026-09/w2/C1.md:34.
The finding itself is unaffected.

<details><summary>Evidence</summary>

Sources/LumenCore/Engine/FilmLab.swift:398-405 `public static let all: [FilmStock] =
[FilmStock.portra400, FilmStock.gold200, FilmStock.ektar100, FilmStock.triX400,
FilmStock.velvia50, FilmStock.cine250D]`. MEASURED via probe: count = 6 — Lumen Portra 400
(halationStrength.max 0.05), Lumen Gold 200 (0.06), Lumen Ektar 100 (0.03), Lumen Tri-X 400
(0.04), Lumen Velvia 50 (0.0), Lumen Cine 250D (0.05). R7 C.1.3 asks for fourteen (Portra
160/800, Ultramax 400, 500T, 800T, Provia 100F, HP5+, T-Max/Delta 400, Delta 3200 among them)
and docs/05's launch list of 8 names Portra 160, Vision3 500T→2383 "plus a high-halation
variant" and Provia 100F — none present. No commit in the history adds a FilmStock literal;
the ledger's own K-071 row ("roster is still six, FilmLab.swift:398-405") still describes the
tree exactly.

</details>

### C1-08 — S2

The Halation slider (and now Halo Size and Halo Redness too) is a live, undimmed, uncaptioned
control that reaches nothing on Velvia 50.

**What the photographer sees.** Load Velvia 50, drag Halation 0→100 (or Halo Size, or Halo
Redness): nothing happens, nothing dims, nothing says why.

<details><summary>Evidence</summary>

Sources/LumenCore/Engine/FilmLab.swift:361 Velvia 50 `halationStrength: RGB.zero`; :1574-1580
`halationAmount` returns 0 whenever `max(s.halationStrength.r, max(.g, .b)) == 0`, for any
`recipe.halation`. Sources/LumenApp/LookPanel.swift:1339-1346 draws `LumenSlider(title:
"Halation", ... range: 0...100, defaultValue: stock?.halationDefault ?? 0, step: 1, decimals:
0, bipolar: false, help: "How much of the highlight energy passes through the emulsion...")`
with no `.disabled` and no caption; grep of `disabled` in LookPanel.swift hits only :253 (Save
Look), :1118 (the Display Transform block) and :1785 — never the Halation row. MEASURED:
lumen/velvia50 at halation 0 / 50 / 100 → halationAmount 0.000000 in all three, strengths
(0.00000, 0.00000, 0.00000), isIdentity true; lumen/portra400 at halation 50 → 0.500000,
strengths (0.02500, 0.00562, 0.00000). SCOPE GREW: C2-05 (f67582b) added two more equally live
rows over the same dead path — LookPanel.swift:1354 `Halo Size` and :1370 `Halo Redness` — so
the silent no-op on a transparency is now three rows, not one.

</details>

### C2-04 — S2

CONFIRMED AS A TEST LOCKING IN A BUG: the grain half-pixel floor's own test certifies, as
intended behaviour, that a 1200 px preview draws Size 0.5 and Size 1.0 as the same picture,
and never asserts preview/export parity.

**What the photographer sees.** Nothing, until he compares an export to the screen — the lane
is green and has been. The bottom of the Grain Size slider is one value in the fit view and
live in the file.

**Corrected by the refute pass.** Accurate, with two qualifications a reader should carry. (1)
The cited companion base values are 1.354190 / 4.062569, not 1.35 / 4.05 — a rounding slip,
and the point stands since both clear the 0.5 floor. (2) "never asserts preview/export parity"
is true of this test function but not of the family: CreativeGrainTests.swift:574 (added by
C2-01) now asserts cells-per-edge parity between 2560 and 8000 for the blue record to 1e-9,
and :685 pins octave band-limiting. Note also that the behaviour the test pins is argued for
in its own doc-comment at :1348-1359 ("that is the pixel grid rather than a bug"), so the fix
is a coverage question — widening the sweep — rather than removing the floor.

<details><summary>Evidence</summary>

Tests/LumenCoreTests/EngineIntegrationTests.swift:1360-1385
`testGrainSizeSaturatesOnSmallRendersAndIsLiveOnExports`: `XCTAssertEqual(scale(1200, 0.5),
0.5, accuracy: 1e-12)` / `XCTAssertEqual(scale(1200, 1.0), 0.5, accuracy: 1e-12)` — the
divergence asserted to 1e-12 — followed by a 31-step monotonicity sweep at 6000 px only. RAN
IT on Linux: `swift test --filter
EngineIntegrationTests/testGrainSizeSaturatesOnSmallRendersAndIsLiveOnExports` → passed (0.001
seconds). MEASURED the quantity it pins (Portra 400, printSizeInches 10): size 0.50 → 1200px
0.500000 / 6000px 1.000000; size 0.75 → 0.500000 / 1.500000; size 1.00 → 0.500000 / 2.000000;
size 1.50 → 0.600000 / 3.000000; size 2.00 → 0.800000 / 4.000000. The companion the brief
names as the fake parity test is also unchanged:
Tests/LumenCoreTests/CreativeGrainTests.swift:248-260 still picks `CreativeGrain(amount: 50,
size: 60)` at L = 2000 vs 6000, where `base` is 1.35 / 4.05 and the floor cannot bite, so
`large / small == 3.0` is green by choice of arguments. C2-01 (56008bf) added
CreativeGrainTests:574-600 (blue-record parity) and C2-01b (0158776) added :685-735 (octave
band-limiting) — neither touched the floor test or widened the sweep to size ∈ {0, 50, 100} ×
L ∈ {1000, 2560, 6000, 8000} as the finding's fix asks.

</details>

### D2-05 — S3

DetailEngine.vignetteInnerRadius (the computed static) still documents a GPU wiring that
landed on the function instead; it has no reader in Sources at all, only three test lines.

**What the photographer sees.** Nothing. It is a maintenance hazard: a symbol whose doc
comment describes a wiring the code has moved off, sitting one line above the function that
replaced it.

**Corrected by the refute pass.** There are FOUR test readers of the property, not three. The
claim missed Tests/LumenPipelineTests/KernelGoldenTests.swift:3814 (`Int(Double(width / 2) *
(1 + DetailEngine.vignetteInnerRadius * 2.0.squareRoot()))`) — live code, not a comment —
alongside VignetteFeatherTests.swift:32 and VignetteResponseTests.swift:328 and :350. Two
smaller corrections: `git log -S"public static var vignetteInnerRadius"` unpathed returns two
commits, 59d0b41 and 442ad09, though 442ad09 only quotes the code inside
docs/audit-2026-09/w2/D2.md, so "introduced once, never removed" is right when the grep is
scoped to the source file. And the property is not purposeless —
KernelGoldenTests.swift:3706-3710 documents it as the deliberate default-feather compatibility
anchor that LumenCore pins (`vignetteInnerRadius(feather: 50) == vignetteInnerRadius`). The
live defect is therefore narrower than "documents a GPU wiring": one stale clause in one doc
comment, on a property whose remaining job is to be a test anchor.

<details><summary>Evidence</summary>

Sources/LumenCore/Image/DetailEngine.swift:675-679: `/// The fixed geometry, for readers that
carry no recipe feather — the GPU graph /// reads this until its half of docs/32 Stream E item
4 lands, and it is the /// default-feather answer by construction.` over `public static var
vignetteInnerRadius: Double { vignetteInnerRadius(feather: Look.vignetteFeatherDefault) }`.
The GPU half HAS landed: Sources/LumenPipeline/RenderGraph.swift:1353 `let feather = 1 -
DetailEngine.vignetteInnerRadius(feather: recipeFeather)` — the FUNCTION, with the recipe's
value — and the CPU reference does the same at DetailEngine.swift:800 `let inner =
DetailEngine.vignetteInnerRadius(feather: feather)`. Non-comment readers of the property
across Sources/ and Tests/: Tests/LumenCoreTests/VignetteFeatherTests.swift:32
`XCTAssertEqual(DetailEngine.vignetteInnerRadius, 0.375, accuracy: 0, ...)`,
Tests/LumenCoreTests/VignetteResponseTests.swift:328 and :350 — three test lines, zero in
Sources. (The D2 brief said one test reader; there are now three, still none in production.)
MEASURED: both spellings return 0.375. git log -S"public static var vignetteInnerRadius" shows
one commit, 59d0b41, which introduced it — nothing has removed or re-commented it since.

</details>

### N-006 — S3

HalationProfile.normalizedWeights still has zero callers; both renderers apply the raw bounce
weights 1 / 0.5 / 0.25, so Halation Amount is delivered at 1.75x the stock's measured
strength.

**What the photographer sees.** Nothing today. The moment a stock with a different bounce
count ships (R7's 800T), the number on the Halation slider stops meaning what it meant on
every existing stock.

<details><summary>Evidence</summary>

Sources/LumenCore/Engine/FilmLab.swift:525-531 `public var normalizedWeights: [Double]` — grep
over Sources/ and Tests/ returns exactly one hit, that definition line. Both apply paths walk
the raw weights: Sources/LumenCore/Engine/ReferenceRenderer.swift:482-492 `var weight = 1.0
... glow[x, y] = glow[x, y] + blurred[x, y] * weight ... weight *= profile.decay`;
Sources/LumenPipeline/RenderGraph.swift:1403-1425 `var weight = 1.0 ... let scaled =
Self.applyMatrix(blurred, Mat3.diagonal(RGB(gray: weight))) ... weight *= profile.decay`.
FilmLab.swift:455 still says the weights are "raw, so `strength` keeps its measured meaning".
MEASURED (Portra 400, Amount 100, longEdge 4000): weights = [1.0, 0.5, 0.25], weightSum =
1.75; normalizedWeights = [0.5714285714285714, 0.2857142857142857, 0.14285714285714285], sum
1.0. Delivered red gain per unit uniform field = strength.r x weightSum = 0.087500, against
the measured constant at FilmLab.swift:451 `measuredStrength: RGB(0.05, 0.015, 0.0)` — a
factor of exactly 1.7500. The two renderers agree with each other, so this is calibration, not
a parity break.

</details>

## UI write paths (new findings)

### NEW-histogram-second-write-path — S2 — **LANDED**

> **Fixed in `9bcac9f`.** `Lumen.ToneRow` states the five rows' bounds and step once, and the
> histogram resolves its drags through it — which is `LumenSlider`'s own clamp-then-snap, so the
> handle can no longer leave Exposure on a value the slider that displays it cannot produce or
> return to. A `DesignSystemTests` ratchet stops the inline copy coming back.

HistogramView.setTone is a second, hand-rolled write path into
develop.tone.{blacks,shadows,exposure,highlights,whites} that re-implements LumenSlider's
clamp with duplicated literals, applies no step quantization, offers no reset, and is
invisible to every inventory and test that governs sliders.

**What the photographer sees.** Drag a histogram zone and tone.blacks lands on e.g. 13.333
where the panel slider (step 1, decimals 0) can only ever produce 13; both readouts print "13"
while the recipe and its sidecar hold 13.333, so two photographs that read identically are
not. There is no way to return a zone to its default from the graph — no double-click reset —
so the only undo is the panel row or ⌘Z. Nothing in CI can notice if the ±5/±100 literals
drift from BasicPanel's ranges.

**Corrected by the refute pass.** Holds as written, with one sourcing correction: the ±5/±100
literals are TRIPLICATED, not merely duplicated. Sources/LumenCore/Recipe/Recipe.swift:448-449
states the same numbers as the D6 tone contract in a doc comment ('exposure in EV (−5…+5); the
rest −100…+100'), BasicPanel.swift:469/:524/:531/:538/:546 restates them as `range:`, and
HistogramView.swift:422 restates them again — three files, no shared constant.

<details><summary>Evidence</summary>

Sources/LumenApp/HistogramView.swift:420-433 `private func setTone(_ slider:
Histogram.ZoneSlider, _ value: Double) { guard value.isFinite else { return }; let limit:
Double = slider == .exposure ? 5 : 100; let clamped: Double = Swift.min(Swift.max(value,
-limit), limit); state.updateRecipe(coalescingKey: "histogram.zone." + slider.rawValue) {
recipe in ... recipe.develop.tone.blacks = clamped ... } }`. Reader at :410-418 toneValue;
gesture at :381-399 zoneDrag, attached at :155 `.gesture(zoneDrag(width: size.width))`. NO
snap: `SliderTrack.snapped`/`resolve` (Sources/LumenCore/Interaction/SliderDrag.swift:166,172)
is never called here. NO reset: grep of HistogramView.swift for reset/default/step/snap/round
returns only unrelated hits (graph decimation `step` at :625, `Lumen.secondaryText`); the
graph carries only zoneDrag, onContinuousHover, a readout-space contextMenu and the two
clipping-triangle Buttons. The ±5 / ±100 limits are literals duplicated from
BasicPanel.swift:469 `range: -5...5` and :523/:530/:537/:545 `range: -100...100` with no
shared constant. GOVERNANCE: the new SliderEvidenceTests scans exactly 9 files —
Tests/LumenCoreTests/SliderEvidenceTests.swift:264-266 `let panels = ["BasicPanel",
"ColorPanel", "DetailPanel", "EffectsPanel", "ZonesPanel", "LookPanel", "CropPanel",
"CurveEditorView", "MaskPanel"]` — and grep for "histogram"/"Histogram" in that file returns
ZERO hits. Ran it: 6/6 pass, "82 control keys bound by the develop panels, 64 with a proof
record" — none of the 82 is this path.

</details>

### NEW-bipolar-inconsistent — S3

All four cited sites confirmed; bipolar's only remaining effect is whether the neutral tick is
drawn at defaultValue, and it is suppressed on 16 rows whose default sits mid-track —
including MaskPanel's Temp, whose own comment argues at length that it must be 'the same row'
as BasicPanel's Temp.

**What the photographer sees.** Sixteen rows draw no mark where their default sits, so the
only way to find the rest position by eye is to double-click and watch the thumb move. Worst
on the two rows whose default is not a round number the photographer could guess: the mask's
Temp neutral (as-shot, at 66.3% of the mired track for a 5500 K file — `fraction = (−1e6/5500
+ 500)/480`, matching BasicPanel's own "about two thirds along") and DetailPanel's ISO-
adaptive denoise sub-sliders. The global Temp row shows the tick; the mask copy of the same
control does not.

**Corrected by the refute pass.** Holds. Two framing corrections, both of which understate
rather than overstate the defect. (1) MaskPanel's Temp is NOT one of the 16 — the 16 are the
15 literal-default rows plus EffectsPanel Feather; Temp's default is the per-photo
`neutral.kelvin`. The true suppressed set is 16 PLUS Temp PLUS the ISO-adaptive DetailPanel
rows, so 16 is a floor. (2) Of the four DetailPanel siblings cited at :585/:594/:623/:633,
only three are bipolar-caused: DenoiseEngine.swift:1776-1784 ISODefaults.classic(forISO:) sets
`lumaContrast: 0`, so the 'Contrast' row at :594 has its default AT the 0…100 lower bound and
its tick is suppressed by the `zeroFraction > 0.001` guard regardless of the flag. The claim's
own three-row body sentence (lumaDetail 50−10n, colorDetail 50, colorSmoothness 50+40n) is
correct; only the 'four siblings' header is one row generous.

<details><summary>Evidence</summary>

bipolar appears exactly 4 times in LumenControls.swift — the declaration at :458 `var bipolar:
Bool = true`, two comment lines at :455 and :1011, and ONE use in body at :1046 `if bipolar &&
zeroFraction > 0.001 && zeroFraction < 0.999 {` which draws the neutral mark (a 1 pt
Lumen.separator rectangle, or a 3 pt black halo under a 1 pt white line on a ramped track). It
no longer gates the fill: :1007-1012 "Where the fill STARTS is the lower of the two, always —
what decides it is where the default sits, not whether the range straddles zero. Consulting
`bipolar` here collapsed to `min(fraction, fraction)` on every unipolar slider." SITES:
BasicPanel.swift:222+262 Temp `range: 2000...50000, scale: .reciprocal, defaultValue:
neutral.kelvin, step: 50, decimals: 0, bipolar: true, trackStops: Lumen.temperatureStops` vs
MaskPanel.swift:2913-2915 `optionalAdjustSlider(mask.id, "Temp", \.kelvin,
ColorTemperature.minKelvin...ColorTemperature.maxKelvin, neutral.kelvin, step: 50, bipolar:
false, scale: MaskPanel.temperatureScale, trackStops: Lumen.temperatureStops)` —
ColorSpaces.swift:287-288 confirms minKelvin=2000/maxKelvin=50000, so identical range,
identical scale, identical stops, identical per-photo default, opposite flag; and
MaskPanel.swift:2923-2924 Tint passes `bipolar: true`, so the two rows of one white-balance
block disagree. MaskPanel.swift:2895-2912 spends 18 lines arguing this row must match
BasicPanel's on axis, stops and quantum — bipolar is the fourth thing it still gets wrong, and
BasicPanel.swift:281-284 names the exact stake: "THE AS-SHOT LANDMARK GETS DRAWN. `bipolar` is
what gates the default tick, and Tint already had it; Temp did not, which is why the one row
whose neutral moves per photograph was the one row with nothing on its track saying where that
neutral is." DetailPanel.swift:603+613 Colour `range: 0...100, defaultValue:
isoDefault.classic.chroma, bipolar: true` against four siblings at :585,:594,:623,:633 all
`bipolar: false` — ISODefaults.classic(forISO:) gives lumaDetail 50−10n, colorDetail 50,
colorSmoothness 50+40n, all strictly inside the track, so the three rows whose default is ISO-
adaptive and therefore unguessable draw no mark while Colour alone does.
EffectsPanel.swift:154-159 Feather `range: 0...100, defaultValue: Look.vignetteFeatherDefault,
step: 1, decimals: 0, bipolar: false` with RecipeLook.swift:57 `public static let
vignetteFeatherDefault: Double = 50` — dead centre, no tick. Measured across all 96
LumenSlider(title:) call sites: 15 literal-default rows plus EffectsPanel Feather have a
default strictly inside the track and bipolar:false — ColorPanel:443 Range (50%),
DetailPanel:320 Radius (20%), DetailPanel:671 Amount (50%), EffectsPanel:322 Size (50%), :333
Roughness (50%), ExportSheet:662 (23.6%), :666 (22.5%), :674 (43.2%), :853 Opacity (60%), :856
Size (12.8%), :859 Inset (10%), :901 Headroom (42.9%), LookPanel:679 Blending (50%),
MaskPanel:1699 Feather (50%), :1856 Reach (14.1%).

</details>

### NEW-histogram-exposure-limit-mismatch — S3

The claim's numbers are real but its framing is wrong: the histogram's ±5 exposure clamp
matches BasicPanel's SOFT drag range, not a contradiction of its hard range — BasicPanel's own
thumb drag evicts a typed −8 to −5 identically, so this is duplicated-literal risk, not a
divergent-limit bug.

**What the photographer sees.** With Exposure typed to −8 (legal), a one-pixel histogram drag
moves it to −5: a 3-stop jump. Real, and the same class SliderDrag.nudged carries a 20-line
comment about having fixed for arrow keys — but BasicPanel's own thumb drag does exactly the
same thing, so a photographer sees no inconsistency between the two surfaces.

**Corrected by the refute pass.** Holds. One citation drift: the four `range: -100...100` tone
rows are at BasicPanel.swift:524/531/538/546, not :523/530/537/545 (the cited lines are each
row's `value:` line). SliderDrag's `clamped` body is :152-155, not :153-156.

<details><summary>Evidence</summary>

HistogramView.swift:422 `let limit: Double = slider == .exposure ? 5 : 100`.
BasicPanel.swift:467-471 `LumenSlider(title: "Exposure", value:
binder.value(\.develop.tone.exposure, "tone.exposure"), range: -5...5, hardRange: -10...10,
defaultValue: 0, step: 0.01, decimals: 2, ...)`. The panel's own drag clamps to the SOFT bound
too: SliderDrag.swift:236-239 `value(from:travelled:)` calls `resolve`, and :172 `resolve` =
`snapped(clamped(value))` where :153-156 `clamped` pins to lowerBound/upperBound = −5…5. So
histogram and panel-drag agree; only typing (LumenControls.swift:1371) reaches ±10, and that
asymmetry is the documented contract (LumenControls.swift:1369-1370 "Typing reaches the hard
limit; dragging does not. That asymmetry is what makes soft limits helpful instead of
restrictive."). For the other four sliders the histogram's ±100 equals BOTH the range and the
effective hard range (BasicPanel passes `hardRange: nil`, and LumenControls.swift:572
`effectiveHardRange = hardRange ?? range`), so there is no discrepancy at all on 4 of the 5
zones.

</details>

### NEW-point-colour-duplicated-block — S3

The two definitions agree on every number today but already disagree on help text, and the one
test that touches them deliberately collapses them into a single row, so it cannot detect a
future divergence.

**What the photographer sees.** Today: the five Point Colour rows inside a mask have no
tooltips while the five identical global rows do. If either block's range or default is
edited, the other silently keeps the old one and the same-named control behaves differently
depending on whether it is reached from the Colour panel or from a mask — and ColorPanel needs
the same number changed in two places within its own file (the `range:` argument and the
Num.clamp literal) or typing will clamp to a bound the track does not show.

**Corrected by the refute pass.** Holds. Citation drift only: the derived clamp is at
MaskPanel.swift:3020, not :3017; ColorPanel's hardcoded clamps are at :806-813, not :805-812;
pointBinding's write is at :825-828.

<details><summary>Evidence</summary>

ColorPanel.swift:430-453 spells five LumenSliders inline: Hue −60…60 def 0, Saturation
−100…100 def 0, Luminance −100…100 def 0, Range 0…100 def 50 `bipolar: false` (the block's
only bipolar argument, at :445), Variance −100…100 def 0 — all `step: 1, decimals: 0`, all
five carrying a `help:` string. MaskPanel.swift:2362-2371 calls a helper five times with the
same numbers: `swatchSlider(mask.id, s, "Hue", -60...60, 0, ...)`, `"Saturation", -100...100,
0`, `"Luminance", -100...100, 0`, `"Range", 0...100, 50, ..., bipolar: false`, `"Variance",
-100...100, 0`; helper at :3004-3026 `LumenSlider(title: t, value: maskValue(...), range: r,
defaultValue: d, step: 1, decimals: 0, bipolar: bipolar)`. AGREE on range, default, step,
decimals and bipolar for all five. DISAGREE on help: 5 `help:` strings in ColorPanel:430-453,
ZERO occurrences of "help" in MaskPanel:3004-3026 — swatchSlider has no help parameter at all.
They also write different fields: ColorPanel:817-828 `recipe.develop.pointColors[index]`,
MaskPanel:3013-3020 `m.adjust.pointColors[index]`. Clamps are stated a THIRD time and
differently — ColorPanel:805-812 hardcodes `Num.clamp(v, -60, 60)` / `(-100, 100)` / `(0,
100)` inside PointComponent.write, duplicating the literals from `range:` twelve lines away,
while MaskPanel:3017 derives its clamp `Num.clamp(v, r.lowerBound, r.upperBound)` from the
range it was handed and so cannot drift. NO GUARD:
Tests/LumenCoreTests/SliderEvidenceTests.swift:140-145 says so outright — "ColorPanel's
`point.\(index).\(component)` and MaskPanel's `point.\(title).\(index)` collapse to the same
shape. The record covers the global rows; the per-mask copies ride `mask.*`" — one manifest
row `"point.*.*"` covers both, so editing either block's ranges keeps the suite green
(verified: 6/6 pass at HEAD).

</details>

### NEW-typing-bypasses-step — none

commitText does clamp-without-snap exactly as claimed, but it is a deliberate, twice-
documented design decision, and the claim's row list is wrong in two places: Temp's hardRange
equals its range today, and ExportSheet has three such rows, not four.

**What the photographer sees.** Nothing harmful. Type 5523 K into Temp and it is stored
exactly; the next drag re-snaps it to 5550 (a 27 K move, 0.9 mired — under the just-noticeable
shift the panel's own comment cites). On Exposure the residue is under one 0.01 EV step. The
out-of-soft-range case that WAS harmful — a nudge dragging a typed −8 home — was already fixed
one-sided at SliderDrag.swift:200-211.

**Corrected by the refute pass.** Holds; carries no engineering cost. Citation drift only: the
BasicPanel quote is at :247-250 (not :249-252), the LumenControls 'no snap' comment at
:1333-1336 (not :1332-1335), 'Typing reaches the hard limit' at :1367-1368 (not :1369-1370),
and Temp's range/hardRange pair at :225-226 (not :225-227).

<details><summary>Evidence</summary>

Sources/LumenApp/LumenControls.swift:1350-1375 `private func commitText() { ... guard let
parsed = SliderEntry.value(of: textValue, current: value) else { return } ... value =
min(max(parsed, effectiveHardRange.lowerBound), effectiveHardRange.upperBound) ... }` — no
`snapped`/`resolve`, confirmed. Deliberate, stated twice: LumenControls.swift:1332-1335 "There
is deliberately no `snap` here any more. The clamp-then-snap the drag applies is
`SliderTrack.resolve`, in LumenCore, where it is tested"; BasicPanel.swift:249-252 "it is the
DRAG's quantum only. Typing is not snapped (`commitText` clamps to the hard range and writes
what was typed), so an exact Kelvin from a grey card still goes straight in." CLAIM
CORRECTIONS — full inventory of hardRange != range across Sources/LumenApp is 8 call sites:
BasicPanel.swift:279 Tint (−150…150 / −300…300), BasicPanel.swift:469 Exposure (−5…5 /
−10…10), ExportSheet.swift:663 Megapixels (0.5…100 / 0.1…500), :667 Pixels (320…8000 /
16…30000), :675 Resolution (72…600 / 1…2400), LookPanel.swift:1231 Black target (0…9 / 0…15),
ZonesPanel.swift:137 the five-zone ForEach (−3…3 / −5…5) and :166 Global (−3…3 / −5…5).
BasicPanel.swift:225-227 Temp reads `range: 2000...50000, hardRange: 2000...50000` —
identical, so Temp is NOT a case. ExportSheet has three, not four.

</details>

## Fields no engine reads

### K-061 — S2

CurveStack.bakeChannelLUTs still has zero callers anywhere in the repo, and measurement
confirms it would silently drop both preserveLuminance and the luma curve if anyone wired it
to the GPU.

**What the photographer sees.** nothing today — the function is unreachable; it is a landmine,
not a live defect. Wired as written it would make the Preserve Luminance toggle and the whole
luma curve inert on the GPU path

**Corrected by the refute pass.** Holds as written. One correction: the quoted baked samples
are bakeChannelLUTs(size: 256), not the default size 1024 (which gives [0.5999988866929917,
0.8370367397580212, 0.8370367397580212, 0.9185185186638162]). The bit-identity across
preserveLuminance and the luma curve — the load-bearing part — reproduces at both sizes.

<details><summary>Evidence</summary>

Sources/LumenCore/Engine/CurveStack.swift:308-312 `public func bakeChannelLUTs(size: Int =
1024) -> (r: LUT1D, g: LUT1D, b: LUT1D) { (LUT1D(size: size) { channelCurve(master($0),
channel: 0) }, ... ) }` — no `set.preserveLuminance` branch, no `lumaCurve`, unlike `apply` at
CurveStack.swift:275-300 which has both. Callers: `grep -rn bakeChannelLUTs .` (excluding
.build/.git) returns the definition plus four docs/ledger mentions — zero code callers.
MEASURED at HEAD 86a8f97 with point curve [[0,0],[0.25,0.6],[1,1]]: baked samples [r@0.25,
r@0.5, g@0.5, b@0.75] = [0.5999821543415093, 0.8370322525524372, 0.8370322525524372,
0.9185185278998609] and are BIT-IDENTICAL for preserveLuminance=true, preserveLuminance=false,
and with a luma curve [[0,0],[0.5,0.2],[1,1]] added. The pictures those settings actually make
are not: CurveStack.apply(RGB(0.6,0.2,0.1)) gives (1.0, 0.5218295372158633,
0.2531432432308362) with preserve on, (0.846657794471659, 0.6532336242395368,
0.48086549412307905) with it off, (1.0, 0.3998605091866396, 0.1953878496321382) with the luma
curve. Both fields are otherwise live and reachable: CurveStack.swift:277 `if
set.preserveLuminance` and a UI toggle at CurveEditorView.swift:583-584.

</details>

### D1-07 — S3

look.lut / LUTReference.ref,name,tap,amount still have no reader on any render path, but both
harmful halves are closed — there is no UI control and renderIdentity strips it, pinned by a
passing test.

**Corrected by the refute pass.** Holds as written. Corrections: the ControlIndex LUT-removal
comment is at ControlIndex.swift:123-135 (not 117-124), and the pinning test runs in 0.025 s
on this machine.

<details><summary>Evidence</summary>

Sources/LumenCore/Recipe/RecipeLook.swift:180-195 `A creative LUT ... **and nothing renders
it.** ... There is no stage that reads it on any path: not RenderGraph, not export, not
ReferenceRenderer.` Confirmed by grep: the only non-declaration hits are
Sources/LumenCore/Interaction/WorkspaceModification.swift:156 (`|| look.lut != nil` lights the
modified dot) and :240 (`recipe.look.lut = nil` on reset). RenderGraph.swift:968/1023/1872
`lut` are LocalCurvePlan/ColorCube's own LUT3D, unrelated. No UI: `grep -rni '\blut\b'
Sources/LumenApp/*.swift` yields only two comments (ControlPalette.swift:32,
CurveEditorView.swift:9); ControlIndex.swift:117-124 removed the palette entry on purpose.
Stripped at Recipe.swift:236 `copy.look.lut = nil`. MEASURED: recipe with
`LUTReference(ref:"blob:xxh64:abc", name:"kodak", tap:.log, amount:42)` fingerprints
`xxh64:fd50cceee634dfb4` — identical to base — and `rendersSameAs(base)` is true. Ran `swift
test --filter testALookCarryingALUTRendersTheSamePictureAsOneWithout`: passed (0.023 s).

</details>

### K-043 — S3

Both halves of K-043 are unchanged: all eight Upright numerics and all five LocalAdjust fields
(noise, noiseChroma, moire, defringe, grainAmount) have zero readers and no control, and every
one of them still changes the cache key.

**What the photographer sees.** nothing — no control writes any of the thirteen fields; the
cost is a cache miss per foreign sidecar

**Corrected by the refute pass.** Holds as written; both halves reproduce, including on a
wider grep than the claim ran.

<details><summary>Evidence</summary>

UPRIGHT: Sources/LumenCore/Recipe/Recipe.swift:1352-1391 declares
vertical/horizontal/rotate/aspect/scale/offsetX/offsetY/strength; `grep -rn 'upright'
Sources/` finds exactly one non-declaration reader, WorkspaceModification.swift:90 `||
geometry.upright != nil` (a modified-dot test, not a stage). No UI: CropPanel.swift:401-403
`No perspective rows: \`Upright\` is a wire format with no stage behind it`. MEASURED: a
fully-populated Upright -> `xxh64:45b6e49e1692a8ba` vs base `xxh64:fd50cceee634dfb4`.
LOCALADJUST: RecipeMasks.swift:687-691 declares the five; `grep -rn
'adjust.noise|adjust.moire|adjust.defringe|adjust.grainAmount|noiseChroma' Sources/` finds
them only in RecipeMasks.swift:727-771 (init/decode) — RenderGraph.applyLocalAdjust
(RenderGraph.swift:935), LocalPlan (RenderGraph.swift:1881) and
ReferenceRenderer.applyLocalAdjust (ReferenceRenderer.swift:285) mention none. No UI:
MaskPanel.swift:2403-2410 `DELIBERATELY ABSENT ... all five are read by NOTHING`. MEASURED
against a one-mask baseline, each of noise/noiseChroma/moire/defringe/grainAmount = 50 yields
a DIFFERENT fingerprint.

</details>

### K-075 — S3

detail.capture.radius is still stored and never applied — the only function that reads it,
DetailEngine.captureSharpen, has zero production callers — though the Radius control that
wrote it was removed at 891d65e.

**What the photographer sees.** nothing now — the slider that stored a number no stage read is
gone; only a foreign sidecar can carry a radius

**Corrected by the refute pass.** Holds as written. Corrections: the radius branch is
DetailEngine.swift:503-506 (not 501-506) and the RAW-path read is AppleRawSource.swift:226
(not :225).

<details><summary>Evidence</summary>

The reader: Sources/LumenCore/Image/DetailEngine.swift:501-506 `if let r = params.radius {
sigma = Num.clamp(r, SpatialOps.minPSFSigma, SpatialOps.maxPSFSigma) } else { sigma =
SpatialOps.estimatePSFSigma(lum) }`. Its callers: `grep -rn 'captureSharpen' Sources/ Tests/`
gives the definition at DetailEngine.swift:495, three DetailPanel comments, and exactly one
call — Tests/LumenCoreTests/Proof/FieldBaselineProbeTests.swift:223. The RAW path reads a
different accessor: AppleRawSource.swift:225 `captureStrength:
dev.detail.capture.strengthFraction`, and Recipe.swift:896-905 `strengthFraction` is `guard
auto else { return 0 } ... Num.clamp(requested / 100, 0, CaptureSharpen.maxStrength)` — radius
never appears. UI gone: DetailPanel.swift:17-22 `There is no Radius row and no Overrides fold
... \`CaptureSharpen.radius\` reaches only \`DetailEngine.captureSharpen\`, which has no
caller`, removed at 891d65e; DetailPanel.swift:281-286 still clears radius for foreign
recipes. MEASURED cache cost: `capture.radius = 1.7` -> `xxh64:af7e38770a07bc35` vs base
`xxh64:fd50cceee634dfb4`.

</details>

### K-092 — S3

develop.zones.*.wheel/.sat/.falloff still have zero readers on any path — the tone engine
takes .ev and nothing else — and no panel offers a control for them, so the field is dead
weight rather than a lying control.

**What the photographer sees.** nothing — no control exists to write them from inside the app;
only a hand-edited sidecar can carry a non-zero value

**Corrected by the refute pass.** Holds as written. Only correction:
ZoneAdjust.wheel/.sat/.falloff are declared at Recipe.swift:557-560 (struct at 556), not
559-562.

<details><summary>Evidence</summary>

Sources/LumenCore/Engine/ToneEngine.swift:512-514 `public func zonePanelStops(_ t: Double) ->
Double { let ev = [zones.dark.ev, zones.shadow.ev, zones.mid.ev, zones.light.ev,
zones.bright.ev]` — .wheel/.sat/.falloff appear nowhere in it; ToneEngine.swift:598-601
`private var zonePanelIsIdentity: Bool { zones.dark.ev == 0 && ... && zones.global.ev == 0 }`.
`grep -rn 'zones\.' Sources/` returns no hit for wheel/sat/falloff outside
Recipe.swift:559-562 (the struct) and ZonesPanel.swift:13 (a comment). ZonesPanel writes only
ev: ZonesPanel.swift:176-183 `evBinding(...) { recipe.develop.zones[keyPath: path].ev = value
}` and pivots at :208-223. Fields declared Sources/LumenCore/Recipe/Recipe.swift:556-562.

</details>

### K-093 — S3

develop.heal.strokesRef and .count have no reader on any render path and no UI, and Heal is
still deliberately left IN renderIdentity — confirmed by measurement, so a foreign sidecar
carrying heal busts the cache for no pixel change.

**What the photographer sees.** nothing — no path in the app writes heal; a foreign sidecar
costs one full re-render to identical bytes

**Corrected by the refute pass.** Holds as written. Minor: the Retouch note is
EffectsPanel.swift:35-39 (not 36-39), and Recipe.swift:301 is a further declaration-site hit
the claim's grep list omits.

<details><summary>Evidence</summary>

Sources/LumenCore/Recipe/Recipe.swift:1457-1459 `public struct Heal { public var strokesRef:
String?; public var count: Int }`. `grep -rn '\.heal\b' Sources/` returns only
Recipe.swift:240/313/338 and WorkspaceModification.swift:95/138 (`|| develop.heal != Heal()`,
the modified dot) and :258 (reset) — zero hits in Sources/LumenPipeline. (The many
`strokesRef` hits elsewhere are `MaskComponent.strokesRef`, a different field that IS
rendered.) UI removed at 891d65e (2026-08-29, 'Delete the sections that were only prose, and
the control nothing reads'); EffectsPanel.swift:36-39 `Retouch is gone ... its entire content
was a paragraph saying heal and clone are not implemented`. Recipe.swift:240-249 keeps it in
the key on purpose and concedes the LUT tripwire is 'the better of the two patterns and heal
should adopt it'. MEASURED: `Heal(strokesRef:"blob:xxh64:def", count:3)` ->
`xxh64:0cfa49330f99205c` vs base `xxh64:fd50cceee634dfb4`; rendersSameAs false.

</details>

### NEW-denoise-model — S3

develop.denoise.model has no render reader and no UI; its single consumer,
RecipeFingerprint.denoiseInputFingerprint, is itself dead code with no production caller.

**Corrected by the refute pass.** Holds as written. Correction: `public var model: String?` is
at Recipe.swift:1125, not :1128.

<details><summary>Evidence</summary>

Sources/LumenCore/Recipe/Recipe.swift:1128 `public var model: String? // e.g. "nafnet/2.1";
nil = current default`. Its only read is Sources/LumenCore/Recipe/Fingerprint.swift:144 `s +=
"|model=\(recipe.develop.denoise.model ?? "default")"`, inside `denoiseInputFingerprint`
(Fingerprint.swift:139) whose callers across the whole repo are
Tests/LumenCoreTests/CanonicalJSONTests.swift:228,229,233,234 and nothing else. The denoise
stages read mode/amount/classic only: DenoiseEngine.swift:1409-1411 and :1838-1844 `switch
denoise.mode { ... return denoise.classic ... coupled(denoise.classic, aiEnabled: true) }`. No
UI: DetailPanel.swift:656 `Tier 2 does not exist: no model ships` and :693 `No model ships
yet: Amount drives the raw decoder's own noise`. MEASURED: `denoise.model = "nafnet/2.1"` ->
`xxh64:75e5b7aa344a87e4` vs base `xxh64:fd50cceee634dfb4`.

</details>

### NEW-filmlab-printsize — S3

look.filmLab.printSize has a reader, but the print long edge cancels out of the grain
arithmetic exactly, so it reaches no pixel — and it is still in the cache key; the picker that
wrote it was removed at fce9bc1.

**Corrected by the refute pass.** Holds as written; every number reproduces exactly, and the
one function where print size would not cancel (FilmGrainProfile.magnification) has zero
callers, so there is no escape hatch.

<details><summary>Evidence</summary>

Reader chain: RecipeLook.swift:448 `public var printSize: String?` -> FilmLab.swift:1565-1567
`public var printLongEdgeInches: Double {
FilmGrainProfile.printLongEdgeInches(recipe.printSize) }` -> FilmLab.swift:1264-1268
`plateScale(longEdgePixels:channel:)` -> FilmLab.swift:945-951 `rawPlateScale`: `let mag =
printLongEdgeMM / gateLongEdgeMM; let pitchOnPrintMM = (pitchMicrons / 1000.0) * mag; let
pixelsPerPrintMM = Double(max(longEdgePixels,1)) / printLongEdgeMM; return pitchOnPrintMM *
pixelsPerPrintMM` — printLongEdgeMM appears once in each factor and cancels. MEASURED
(portra400, 6000 px long edge): plateScale = 2.0 at 5", 1.9999999999999998 at 8", 2.0 at 10",
1.9999999999999998 at 16", 2.0 at 30" — a spread of 2.2e-16; blue record 4.0 /
3.9999999999999996. `swift test --filter
testGrainFollowsTheGateAndTheRenderSizeNotThePrintSize` passes (pins 1e-12, 5"-30"). UI gone
at fce9bc1 (2026-08-22) 'The Print size picker is gone'; LookPanel.swift:1382-1393 states why.
Not stripped from the key: MEASURED, filmLab with printSize "30x40" ->
`xxh64:6465fceb21071df5`, different from the same filmLab without it.

</details>

### NEW-lens-removeCA-defringe — S3

geometry.lens.removeCA and every field of Defringe still have zero readers, but the critical
half is FIXED: the on-by-default CA toggle and the seven Defringe controls were deleted from
the panel at 98d96ee, leaving only lens.profile, which is genuinely consumed at decode.

**What the photographer sees.** nothing now — before 98d96ee every photo in the library
carried a ticked 'Remove chromatic aberration' box that reached no stage

**Corrected by the refute pass.** Holds as written. Minor: LensCorrections spans
Recipe.swift:1393-1416 and the 'DEFAULTED TO ON' sentence is at EffectsPanel.swift:461, just
past the cited 454-458.

<details><summary>Evidence</summary>

Sources/LumenCore/Recipe/Recipe.swift:1396-1415 (`public var removeCA: Bool` default true,
`public var defringe: Defringe?`) and Recipe.swift:1419+ (`Defringe`). The only production
reader of the whole LensCorrections struct is `lens.profile`:
Sources/LumenPipeline/AppleRawSource.swift:229 `lensProfile: dev.geometry.lens.profile` and
:336 `filter.isLensCorrectionEnabled = dev.geometry.lens.profile`. EffectsPanel.swift:454-458
`Not shown: Remove chromatic aberration, and the seven controls under Defringe. \`removeCA\`
and every field of \`Defringe\` have a wire format and no reader ... the removed CA toggle
DEFAULTED TO ON`. Fixed at 98d96ee (2026-08-22) 'Lens Corrections shows the one control that
reaches a pixel'. Residual cache cost MEASURED: `removeCA=false` -> `xxh64:05c2203fb71b9147`;
`defringe = Defringe()` present -> `xxh64:9907fafcd0d00c8f`; base `xxh64:fd50cceee634dfb4`.

</details>

### NEW-raw-decoder — S3

develop.raw.decoder — the "apple" | "lumen" escape hatch — is read by nothing that renders; no
RawSource is selected from it, no UI writes it, and it still busts the cache key.

**Corrected by the refute pass.** Holds as written; every cited line and number reproduces
exactly.

<details><summary>Evidence</summary>

Sources/LumenCore/Recipe/Recipe.swift:420 `public var decoder: String // "apple" | "lumen"
(RawSource escape hatch, D50)`. `grep -rn 'raw\.decoder\b' Sources/ Tests/ | grep -v
decoderVersion` returns nothing outside Recipe.swift:427/441 (init/decode). The sibling field
IS read — AppleRawSource.swift:212 `if let requested = dev.raw.decoderVersion` — which is what
makes the dead one easy to mistake for live. The only textual consumer is the dead
`denoiseInputFingerprint` (Fingerprint.swift:141). MEASURED: `raw.decoder = "lumen"` ->
`xxh64:6e199f03aed14ba4` vs base `xxh64:fd50cceee634dfb4`, so a sidecar naming a decoder that
does not exist re-renders every preview to identical bytes.

</details>

### NEW-renderidentity-strips-only-lut — S3

Of the twelve fields audited here that reach no pixel, exactly one (look.lut) is stripped from
renderIdentity; the other eleven all change recipe_fp, so any sidecar carrying one throws away
every cached preview and artifact of that photograph to re-render identical bytes.

**What the photographer sees.** nothing visible; a full 45 MP re-render and a lost 1:1/fit
cache per affected photograph, and the library calls such a photo edited

**Corrected by the refute pass.** The mechanism holds exactly: of the dead fields audited in
this family, look.lut alone is stripped from renderIdentity and every other one changes
recipe_fp. The count is wrong — the evidence block itself measures sixteen unstripped dead
configurations (eleven top-level plus the five LocalAdjust fields), not eleven, and counting
individual wire fields the way K-043 and NEW-lens do makes it larger again.

<details><summary>Evidence</summary>

Sources/LumenCore/Recipe/Recipe.swift:220-249 strips `copy.look.lut = nil` behind a comment
ending `WHEN A LUT STAGE IS BUILT, DELETE THIS LINE IN THE SAME COMMIT`, then explicitly
declines to do the same for heal: `\`develop.heal\` is the SAME situation and is deliberately
handled the other way ... the tripwire above is the better of the two patterns and heal should
adopt it when somebody is next in that code`. Measured fingerprints against base
`xxh64:fd50cceee634dfb4` (probe at /tmp/lumenprobe/probe.swift, HEAD 86a8f97): look.lut
`fd50cceee634dfb4` (SAME — stripped); zones wheel `4f6fe95a59ab75bb`, zones sat
`5c4aa93c3b88dea9`, zones falloff `85277c9d84648c01`, heal `0cfa49330f99205c`, upright
`45b6e49e1692a8ba`, lens.removeCA `05c2203fb71b9147`, lens.defringe `9907fafcd0d00c8f`,
detail.capture.radius `af7e38770a07bc35`, denoise.model `75e5b7aa344a87e4`, raw.decoder
`6e199f03aed14ba4`, filmLab.printSize `6465fceb21071df5` (all DIFFERENT), plus all five
LocalAdjust fields DIFFERENT against a one-mask baseline. Eleven fields, one policy, applied
once.

</details>

### TONE-18 — S3

TONE-18's specific claim is CONFIRMED by measurement: the dead zone fields are NOT stripped
from Recipe.renderIdentity, so a sidecar carrying a zone wheel/sat/falloff gets a different
recipe_fp and re-renders the frame to identical bytes.

**What the photographer sees.** nothing on screen; a cache miss and a full re-render of a 45
MP frame producing byte-identical pixels, once per such sidecar

**Corrected by the refute pass.** Holds as written, measurements bit-identical on independent
replication. Only correction: `copy.look.lut = nil` is at Recipe.swift:239 (not :236);
renderIdentity spans 178-250.

<details><summary>Evidence</summary>

Sources/LumenCore/Recipe/Recipe.swift:178-249 `renderIdentity` strips only mask cosmetics,
`look.bw` when off, an identity `look.grain` and (Recipe.swift:236) `copy.look.lut = nil` —
zones are untouched. Measured with a probe linked against the built LumenCore
(/tmp/lumenprobe/probe.swift, run at HEAD 86a8f97): base `xxh64:fd50cceee634dfb4`;
`zones.dark.wheel=[0.2,-0.1]` -> `xxh64:4f6fe95a59ab75bb`; `zones.dark.sat=40` ->
`xxh64:5c4aa93c3b88dea9`; `zones.dark.falloff=0.9` -> `xxh64:85277c9d84648c01`;
`rendersSameAs(base)` false in all three. NOTE the ledger's own citation is stale: TONE-18
says 'Recipe.swift:55-63' for renderIdentity; it is now Recipe.swift:178-249. The claim
survives the move.

</details>

### TONE-30 — S3

TONE-30's claim holds and is the mirror image of this family: look.render.whiteTarget IS live
in the engine, but no control in the app writes it — a capability with no door rather than a
door with nothing behind it.

**What the photographer sees.** nothing directly; the consequence is that a documented AgX
product control is unreachable, and that PlanTableCache's stale-serve pairing defect stays
latent only because no control writes it

**Corrected by the refute pass.** Holds as written; the two candidate 'writers'
(PipelineRenderer's HDR displayWhiteTarget fallback and FilmLab's DisplayTransformParams
write) do not write the recipe field, so they do not refute it.

<details><summary>Evidence</summary>

Reader is live: Sources/LumenCore/Recipe/RecipeLook.swift:152-156 `if let whiteTarget {
p.whiteTarget = whiteTarget } else if let displayWhiteTarget { p.whiteTarget =
displayWhiteTarget }` -> Sources/LumenCore/Engine/DisplayTransform.swift:363 `var params =
recipe.look.render.resolved(displayWhiteTarget: displayWhiteTarget)` ->
DisplayTransform.swift:161 `let w = Swift.max(p.whiteTarget, 1) / 100.0`. MEASURED:
`RenderParams().resolved().whiteTarget == 100.0`, `RenderParams(whiteTarget:
300).resolved().whiteTarget == 300.0`. No writer: `grep -rn 'whiteTarget'
Sources/LumenApp/*.swift` returns ZERO hits; LookPanel.swift:1202-1235 binds blackTarget (and
contrast/skew/huePreservation) only. Two engine comments agree — RenderPlan.swift:378-379 `It
takes a control over \`look.render.whiteTarget\`, which has no UI yet` and
PlanTableCache.swift:369 `\`transform.white\` moves only with \`whiteTarget\`, which no
control writes`. MEASURED cache behaviour: `whiteTarget = 300` -> `xxh64:1b1e75311da673a2` —
correctly different, because here it genuinely does change pixels.

</details>

## Refuted — claims that did not survive

### B2-03 (grade)

The measurements reproduce exactly (hue 0 -> -0.1523 EV, 180 -> +0.1408, 330 -> -0.1482; hue
90 sat 1 mid-grey -> RGB(0.2476, 0.1674, -0.0114); first negative at sat 0.25 hue 5 t=-9;
worst -10.19 EV at sat 0.75 hue 255 t=-8.5) and the code is unchanged - but the defect they
are offered as does not hold. (1) The header's word is the SPEC's own: docs/05-spec-
color.md:193 says "Wheel tints apply as constant-luminance hue/chroma offsets per zone", and
it means constant OKLab L. I measured the round trip: L in 0.564621614 -> L out 0.564621614 at
hues 0/90/180/270, dL <= 1.11e-16, i.e. bit-exact. The stage does precisely what its comment
claims; scene-Y necessarily varies when perceptual lightness is held (that is what OKLab L
is), so the 0.29 EV is an inherent property of any constant-lightness tint, not an
implementation error. (2) 'nothing in the stage clamps it' is true and is the explicitly
argued architecture, not an oversight - the file header at :32-34 and the 15-line comment at
GradeEngine.swift:750-765 state that gamut mapping is S14's job and record the 0.17 bake error
that running it here caused. (3) The negatives are in fact clamped where the design says:
DisplayTransform.apply does `out = RGB(Swift.max(out.r, 0), Swift.max(out.g, 0),
Swift.max(out.b, 0))` (DisplayTransform.swift:341) and `tone()` returns black for x <= 0
(:300). I pushed the worst cases through `DisplayTransform.forRecipe(Recipe())`: hue 90 sat 1
at mid-grey renders display (0.24712, 0.18022, 0.00000), and the -10.19 EV case at t=-8.5
renders (0.00033, 0.00000, 0.00418) against an untinted (0.00015, 0.00015, 0.00015) - every
output finite, no NaN, no fold, and the -10 EV 'worst case' is a pixel 8.5 stops under mid-
grey that renders black either way. Nothing here is worth engineering time as an S2.

### NEW-brilliance-global-minus-100 (grade)

The raw numbers reproduce (Global -100 -> brillianceScale 1.000000 and a 122.84 EV drop at
t=+0.38 with mid +100 / high -100, 56.61 EV with mid +100 alone; -99 -> 0.002053; -95 ->
0.010267; -80 -> 0.041070; 0 -> 0.205319), but both halves of the claim collapse. The -100
bail is conceded by the claim itself to be deliberate and argued at GradeEngine.swift:527-540
and :1074-1079, so it is not a live defect. The '-99 cliff' is a misreading of an internal
multiplier as the realised control strength. `folds = rest * (1 - ratio) / fall`
(GradeEngine.swift:1119) makes the cap exactly proportional to `rest = 1 + global/100`, so the
scale is perfectly linear in Global, with no cliff anywhere: 0.2053 * rest reproduces 0.002053
at -99, 0.010267 at -95, 0.041070 at -80 and 0.205319 at 0, to six digits. What the
photographer actually gets is the ratio of peak gain to base gain, and I measured it: with
Brilliance mid +100 at Blending 50, peak/rest is 1.516828 at Global -99, 1.516828 at -95,
1.516823 at -80 and 1.513807 at 0 - i.e. 0.6011 stops of midtone lift over the rest of the
frame at -99, identical to the 0.5982 stops delivered at Global 0. The control is not
annihilated at -99; the small scale is precisely the multiplier required to deliver the same
relative zone contrast once the base gain has been crushed to 1%, which is what a slope
limiter is for. That is also why the measured worst fold at -99 is 0.0000 EV. The residual
complaint - 'nothing on screen saying so' - is not new; it is B2-04's un-surfaced limiter,
already filed.

