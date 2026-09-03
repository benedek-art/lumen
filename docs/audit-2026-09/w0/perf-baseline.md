# Perf baseline — `cc82116`, gpu-parity run 33553464942 (macos-15, DEBUG build)

Captured from the job log before any W5 landing. W6 re-runs gpu-parity on the final
commit and compares row for row. The probe's own caveat applies: DEBUG build, so
CPU-side costs (plan construction, table bakes) are inflated ~10× against the shipping
build; GPU time is not. **Compare rows, not absolutes.**

## PERFPROBE — full pipeline, synthetic frame
| long edge | ms |
|---|---|
| 1024 | 22.0 |
| 1536 | 24.3 |
| 2048 | 38.0 |

## DRAGPROBE — per control, 1280 px, budget 35 ms (48-event drag; p50 / p95 / max / over-budget / tables h=hits b=bakes s=stale)
| control | path | p50 | p95 | max | over | tables |
|---|---|---|---|---|---|---|
| Exposure | draft | 60.2 | 81.9 | 95.7 | 47/47 | 96h/48b/0s |
| Exposure | settle | 57.3 | 98.4 | 98.4 | 11/11 | 24h/12b/0s |
| Whites | draft | 69.0 | 130.7 | 169.9 | 47/47 | 0h/48b/96s |
| **Whites** | **settle** | **388.0** | 477.2 | 477.2 | 11/11 | **0h/36b/0s** |
| Texture | draft | 36.4 | 51.9 | 65.2 | 27/47 | 138h/1b/5s |
| Texture | settle | 38.3 | 44.6 | 44.6 | 10/11 | 36h/0b/0s |
| Saturation | draft | 24.1 | 38.6 | 101.5 | 6/47 | 96h/0b/48s |
| **Saturation** | **settle** | **269.4** | 319.0 | 319.0 | 11/11 | 24h/12b/0s |
| Sharpen | draft | 22.3 | 40.3 | 53.1 | 4/47 | 138h/0b/6s |
| Sharpen | settle | 29.3 | 60.6 | 60.6 | 4/11 | 36h/0b/0s |

Read: a Whites **settle** costs 7× its draft and bakes tables on every frame with zero
cache hits (`0h/36b`); Saturation settle 11× its draft. The draft path is within 2× of
budget for tone; the settle path is the outlier. (docs/34's "colour LUT rebakes per
event" — still true on the settle path at this SHA.)

## DRAGPROBE — per rung, Exposure draft
| rung | p50 | p95 | max | over |
|---|---|---|---|---|
| 1728 | 76.9 | 106.7 | 149.4 | 47/47 |
| 1280 | 56.4 | 94.5 | 119.6 | 47/47 |
| 1024 | 46.7 | 88.5 | 128.4 | 42/47 |
| 768 | 37.6 | 73.1 | 119.7 | 29/47 |
| 576 | 28.0 | 38.2 | 44.3 | 6/47 |

## DRAGPROBE — structural, Exposure draft, 1280
| variant | p50 | p95 | max |
|---|---|---|---|
| lazy + readback | 42.3 | 53.4 | 60.7 |
| materialized + readback | 45.8 | 59.8 | 64.6 |
| lazy + iosurface | 46.2 | 72.6 | 96.0 |
| materialized + iosurface | 43.6 | 81.8 | 121.7 |

## TEXSPEC — texture frequency response, GPU/reference gain ratio
| period px | 2 | 3 | 4 | 6 | 8 | 12 | 16 | 24 | 32 |
|---|---|---|---|---|---|---|---|---|---|
| gpu/ref | 0.848 | 0.740 | 0.950 | 0.755 | 0.929 | 0.940 | 0.965 | 0.988 | 0.996 |

## TONEGOLD — GPU vs reference parity, worst abs error
| control | size 33 | size 65 |
|---|---|---|
| exposure +1.5 | 0.02134 | 0.00872 |
| contrast +60 | 0.01792 | 0.01068 |
| highlights −80 | 0.02030 | 0.01072 |
| shadows +80 | 0.01319 | 0.00349 |
| whites +70 | 0.01369 | 0.00810 |
| blacks −70 | 0.01352 | 0.00376 |

## Other probes worth holding still
- HALATION: predicted spread 52.77, gpu 52.31, reference 52.74; **mass gpu 6.45 vs reference 6.89** (GPU 6% light).
- LOCAL TABLE 33-vs-65 worst under the mask 0.013041; LOCAL CURVE table-vs-exact worst 0.1001.
- VIGNETTE BANDING dithered step 0.00585 / undithered 0.01172 / ideal 0.00331.
- EXPORT GRAIN mean 0.1824 σ 0.02362, rms diff 0.00000.
- VST PLANE spans −14.84 … 21.19; half-float step at top 0.015625.
- GAUSSIAN σ asked→measured: 1→1.038, 2→2.010, 4→3.992, 6→6.009, 9→8.949.
- DONT-RESIZE blended pixels 0 of 41600 (300×200).
- HEIF10 canWriteTenBitHEIC = true, delivered 10 bits.

## Defects visible in this same log (filed to the ledger)
- `[CIKernelPool] 3:11: ERROR: expected identifier — float long = max(w, h);` … "4 errors
  generated" during `DraftTruthfulnessTests`; then `MaskGPUParityTests` **skipped 3 of 5**
  with "kernels unavailable". A gradient-mask kernel uses `long` (a reserved word in the
  CI Kernel Language) as an identifier, fails to compile, and the parity tests that
  would catch it skip instead of fail. Green lane, dead GPU path. → ledger `N-001`.
- Lane timings on this SHA: build-macos 1m10s · test-fast 7m20s · app-bundle 1m45s ·
  fixtures-linux 1m50s · engine-linux 6m00s · gpu-parity 3m52s.
