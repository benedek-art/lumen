# W6 — the probes re-run, against `w0/perf-baseline.md`

Final commit `1df319f`, gpu-parity run 33653711460 (macos-15, DEBUG). The baseline is
`cc82116`, run 33553464942, same lane and same build configuration.

**The caveat the baseline states applies to both sides and is doing real work here.**
DEBUG inflates CPU-side costs — plan construction, table bakes — roughly 10× against the
shipping build; GPU time is not inflated. These are also shared runners with one sample
per row. So: a consistent double-digit move across five rows is signal, and a single row
moving 15% is not.

## DRAGPROBE — per control, 1280 px, budget 35 ms

p50 milliseconds, and the count of events over budget.

| control | path | baseline | final | Δ | over-budget |
|---|---|---|---|---|---|
| Exposure | draft | 60.2 | **49.3** | −18% | 47/47 → 47/47 |
| Exposure | settle | 57.3 | **47.7** | −17% | 11/11 → 11/11 |
| Whites | draft | 69.0 | **47.8** | **−31%** | 47/47 → 47/47 |
| Whites | settle | 388.0 | 375.8 | −3% | 11/11 → 11/11 |
| Texture | draft | 36.4 | **26.1** | **−28%** | **27/47 → 1/47** |
| Texture | settle | 38.3 | **28.2** | −26% | **10/11 → 0/11** |
| Saturation | draft | 24.1 | 25.0 | +4% | 6/47 → 7/47 |
| Saturation | settle | 269.4 | **315.7** | **+17%** | 11/11 → 11/11 |
| Sharpen | draft | 22.3 | **16.8** | −25% | **4/47 → 1/47** |
| Sharpen | settle | 29.3 | **16.8** | **−43%** | **4/11 → 0/11** |

**Seven of ten rows are faster, five of them by more than 17%.** The line that matters
most to a photographer is Texture's draft going from 27 of 47 events over budget to
**one** — that control was missing its frame budget more than half the time and now
essentially never does. Sharpen's settle joins it at 0 of 11.

**Two rows did not improve and one got worse, and neither is explained away here.**

`Saturation settle` is up 17% at p50 and its p95 moved 319 → 542. That is the widest
spread in the table and the shape of a single slow sample on a shared runner rather than
a trend — but it is also the row I would look at first with a repeatable harness, because
it is one of the two controls N-002 named.

`Whites settle` moved 3%, which is nothing, and its table column is unchanged at
`0h/36b/0s`. **That is the honest state of N-002**: the settle path still reports zero
cache hits and 36 bakes. I1-01 landed the join, I1-04 landed the identity gate, and this
row still reads the same — because I1-02, the probe fix, did not land. The probe measures
hits and bakes over disjoint sample sets and `resetStats` did not clear entries, so this
column cannot currently distinguish "the fix did not work" from "the probe cannot see
it". Saturation's settle did move, 24h/12b → 25h/11b: one bake became a hit, which is the
join doing exactly what it was built to do and is the only direct evidence in this table
that it works at all.

**Until I1-02 lands, N-002's row is not measurable and must not be reported as closed.**

### Addendum — I1-02 landed after this run

The probe is fixed and these numbers are the LAST ones taken before it. Two reasons the
settle row could not hit, and only the first had been dealt with:

1. The settle used to sample `(e + 0.5) / 12` against the draft's `(e + 0.5) / 48` — odd
   ninety-sixths against even ones, two sets that can never coincide. Fixed earlier, by
   sampling every fourth draft value.
2. **That was not enough, and it is why this run still reads `0h`.** The cache holds
   eight entries per slot. A Whites drag re-keys the finish table at all 48 values, so
   when it ends only its last eight are resident — and a settle spread across the whole
   travel can address at most one of them. `0h/36b` was still arithmetic.

Each settle sample now renders its own draft frame first, untimed, at the same value:
the drag's last event, then the settle. That is the pair a photographer performs, and it
is the only arrangement in which this row's hit count means anything. Traffic is also
accumulated per timed frame now, so the untimed draft's stale serves are not counted as
the settle's.

`testTheSettleRunCanAddressWhatTheDraftRunLeftBehind` pins both halves as arithmetic, so
it fails without a GPU and without waiting for the probe. **The next gpu-parity run's
Whites settle row is the real re-measurement of N-002.**

## PERFPROBE — full pipeline, synthetic frame

| long edge | baseline | final | Δ |
|---|---|---|---|
| 1024 | 22.0 | 26.7 | +21% |
| 1536 | 24.3 | 28.0 | +15% |
| 2048 | 38.0 | 40.9 | +8% |

Up across all three, by a shrinking margin as the frame grows. Two readings fit:

1. Runner variance. One sample per row, a shared macOS runner, and a fixed per-run
   overhead would show exactly this shape — largest as a fraction at the smallest frame.
2. Real added work. The grain stage now band-limits its plate (C2-01b) and mixes three
   sampled fields per pixel (C2-02), and halation gained two parameters. The mix is one
   multiply-add per channel and the band limit *removes* octaves, so neither should cost
   8–21% of a whole pipeline — but "should not" is not a measurement.

The DRAGPROBE rows are the ones that carry a photographer's experience, and they moved
the other way; PERFPROBE renders a synthetic frame once per size. **This is recorded as
unresolved rather than dismissed.** The next step is the one I1-02 also needs: run each
probe several times and report a distribution, so a 15% move can be told apart from a
15% wobble.

## Other rows on the same run, unchanged and green

`EXPORT GRAIN rms difference 0.00000` — the exported grain matches the reference exactly,
which is what the whole C2 group was for. `HALATION predicted spread 52.77 / gpu 52.31 /
reference 52.74`. `TEXSPEC` gpu/ref from 0.848 at a 2-pixel period to 0.996 at 32.
`TONEGOLD` parity worst 0.0213 at table size 33, 0.0107 at 65. 86 tests, 0 failures.
