# C4-mono: Leica Monochrom DNG (corpus 1087) renders black

Branch `C4-mono`, based on `origin/claude/jolly-sagan-k7ch7z` @ 1c6ac52. Not pushed.
Follows up P20-corpus.md item 3.

## Mechanism (as diagnosed in P20, now fixed in LumenCore)

The file is LinearRaw with one sample per pixel and no ColorMatrix, AsShotNeutral or
CalibrationIlluminant. Its decode is finite and correct. `CIRAWFilter.neutralTemperature`
and `neutralTint` (Lumen's `AppleRawSource.asShotTemperature`/`asShotTint`) have no
defined value for it. Those values reach `WhiteBalanceEngine`, where `Num.clamp` passes
NaN through. The `aK == tK` identity test is false on NaN, so the S6 matrix comes out
NaN in both renderers, and an 8-bit render of NaN is black.

## Items

| # | Item | Status | Commit |
|---|------|--------|--------|
| 1 | Explicit as-shot sanitation (non-finite or non-positive temperature becomes 5500 K / tint 0; Apple's value still goes back to the filter) | FIXED | 18e6ddd |
| 2 | NaN must not pass through the clamp at the WB inputs, and no change for finite inputs | FIXED | 18e6ddd |
| 3 | Linux tests: a NaN neutral gives a finite, neutral-preserving matrix | FIXED | 18e6ddd |
| 4 | Corpus log line: as-shot values and per-channel decode means | FIXED (diagnostic) | 0d733f5 |

### 1–3: 18e6ddd
- `WhiteBalanceEngine.Neutral.sanitizedAsShot(kelvin:tint:)` is the one rule. It is
  applied in `WhiteBalanceEngine.init`, `displayed(...)` (the Temp/Tint rows and
  `RenderPlan.balancedNeutral`, so masks' absolute WB also adapts from it) and
  `neutralizing(...)` (the eyedropper). `RenderCoordinator.asShotNeutral` is a one-line
  LumenApp hunk that returns the sanitised neutral.
- `AppleRawSource` is untouched. `decode` still writes Apple's own
  `neutralTemperature`/`neutralTint` back to the filter, so the decode does not change.
- I added `Num.clampFinite(x, lo, hi, fallback:)` and used it only at the two WB target
  inputs, where a NaN target falls back to as-shot (which is what nil already means).
  `Num.clamp` itself is unchanged, so none of its ~340 callers can move. I chose this
  over changing `Num.clamp` globally because a global NaN→lo would silently change
  NaN handling everywhere, which can't be proven safe caller by caller.
- RED/GREEN: `AsShotNeutralSanitationTests` has 7 tests. With the sanitation and
  `clampFinite` substituted out, 5 fail: four by assertion, and the picker test by a
  `Mat3.inverse on a singular matrix` precondition trap. So the old eyedropper would also
  have crashed the app on this file. The two no-change proofs pass both ways, as they
  should. All 7 pass with the fix.
- No-change proofs, bit for bit:
  - `clampFinite` equals `clamp` over 594 non-NaN value/bound/fallback combinations,
    including ±0, subnormals, ±inf and NaN bounds.
  - The engine matrix equals the old clamp-then-adapt formula over a full grid of
    14×9×10×8 = 10080 cases: positive finite as-shot temperatures, finite tints, and
    targets that include nil, out-of-range, 0, negative and ±inf.
  - `displayed` matches as well.
- Related suites are green: MaskWhiteBalance, AuditWhiteBalancePicker, TintGuard,
  Engine, SliderScale, HuePreservation, PlanTableCache and Robustness (203 tests,
  0 failures). ControlProofTests: see below.

### 4: 0d733f5
The corpus lane emits this line for every file:
`corpus-wb: <id> neutralTemperature=… neutralTint=… sanitized=K/T decode-mean-rgb=r,g,b nonfinite=n/N`.
- The raw values are printed with `String(describing:)`, because the lane's `fmt` helper
  prints NaN as "-".
- The means cover the finite R/G/B samples of the same RGBAf readback the finiteness
  check already walks.
- This is macOS-only and source-verified. `check-swift-surface.py` exits 0.

## Proof records that move
None. Every proof record renders with a finite, positive as-shot neutral, and for those
the WB matrix is bit-identical (the grid proof above). ControlProofTests was started
locally, but it was stopped at the 30-minute background limit on the shared 4-core box,
before reporting. The proof workflow on CI will confirm it.

## DECISIONS
- A file with no camera neutral is treated as the rendered-file reference (5500 K,
  tint 0). This was specified, and it is what a JPEG already gets. An alternative would
  be "identity, whatever the target". It renders the same at as-shot, but explicit
  Temp values would then be relative to 5500 K. That is the current behaviour, and the
  Temp row shows 5500, which keeps it consistent.
- A non-positive finite as-shot temperature used to clamp to `ColorTemperature.minKelvin`.
  It now becomes 5500 K. This is the only behaviour change for a finite input. No real
  decoder reports one.
- A finite temperature with a non-finite tint keeps the temperature and takes tint 0.

## FOUND-WHILE-FIXING
- On the old code, the eyedropper (`WhiteBalanceEngine.neutralizing`) hit a
  `Mat3.inverse` precondition failure, which is a crash, on any file with a NaN neutral.
  This commit fixes it.
- Not confirmed on hardware yet. The next corpus lane run should show
  `neutralTemperature=nan` (or a non-positive value) for 1087, a non-zero
  `decode-mean-rgb`, and R-6 passing. If the neutral turns out to be finite, P20's
  second suspect (a 0/0 on exactly achromatic input in S3–S15) is still open.
