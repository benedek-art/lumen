# WS-08 report: Zones register

**Status (paused by the director at 3454637): BUILT, NOT VERIFIED.** Round 3 (the last allowed round) is pushed. Its verifier was cut off by the usage limit before reaching a verdict, so there is no `VERIFY.md` yet. Round 2 (9b39825) FAILED verification on one defect, a spill collapse (`VERIFY-round2.md` F1). Round 3 fixes it, and so far that is the builder's claim only. Linux suite 3105/0 on 3454637 (base 3058/0). macOS CI on 9b39825: CI, UI layout, UI snapshots and proof green; GPU parity was still queued. Not yet confirmed on 3454637. To finish: re-run the round-3 verifier, then send READY.

## For the owner

1. Drag Darks to +3 on a real photo: the shadows now lift the full 3 EV with texture kept, and the excess carries into Shadows/Mids (their rows say "carried from Darks"). Judge whether that broad lift is what you want at the top of the range.
2. Two opposite neighbours (e.g. Darks +3, Shadows −3) cap at ±0.48 EV each, with a "conflicts with…" caption. A monotone curve can't do more.
3. Wheel, sat and falloff per zone are gone: they never rendered and they duplicate Colour Grading. Old recipes still open and render identically.
4. Brights still does little on raws: their highlights sit at or below +2.5 EV, the sensor clip. I kept the pivots so existing edits don't move.
5. Check the caption placement under each zone row in the round-3 snapshot (`quality-ws-02-08-pickers-zones/3454637/` on `ui-snapshots`).

## What changed and why

- **Inversion fixed (Z1).** Before: any zone past about 1.27 EV of difference from its neighbour made the curve fall, and Darks +3 rendered 2.85 EV of input as one tone (`AUDIT.md` Z-1). Now `ToneEngine.zoneEase` projects the requests onto the set of curves that stay monotone with slope ≥ 0.25, using Pool Adjacent Violators over the five zones.
  - A lone zone is delivered exactly over ±3, with no dead range.
  - The excess spills into neighbours as a bound: Darks +3 gives 2.045 / 1.090 / 0.135.
  - Measured: slowest slope 0.2500, largest C1 break 0.0036, overshoot ~1e-16. The round-3 sweep (every zone at ±3, every other zone −3…+3 in 0.01 steps) gives a largest step of 0.0100 and a largest fall of 9e-16.
- **Fixed axis (Z3).** Zones sit on fixed stops, so Basic Whites/Blacks ±100 no longer move them. Before, they shifted Mid by up to 0.96 EV.
- **Minimum pivot gap (Z4).** The minimum gap between pivots is now 1 EV. Before it was 0.28 EV, which gave 6.6× slopes.
- **Dead fields removed (Z7).** Defaults render byte-identical on 6 frames, and the default recipe's fingerprint is unchanged.
- **Readout.** `AppliedReadout.zoneEasing` adds captions under each row.

### Spec amendments

These are lead decisions, each marked in `SPEC.md`:
- the spill rule;
- Z1.10's metric moved from display codes to EV, because a plain Exposure +0.95 failed the old one;
- the rising-seam kink judged against base.

### Existing tests changed

Each change was made because the test encoded the old behaviour. Reasons are in `BUILD-NOTES.md`:
- the flattening tests;
- the clamp tests;
- the zone proof floors, re-measured at 70%;
- the default-recipe digest;
- three tests that set the dead fields;
- two test renames.

## Not fixed / for other lanes

See `NEEDS.md`:
- GPU 32³ cube resolution against the zone response (WS-07);
- the bake clamp still fires with Contrast −100 or Blacks +100 combined with zones (WS-07);
- the shared slider value formatter shows no sign;
- the docs/04 update.
