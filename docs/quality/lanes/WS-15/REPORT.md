# WS-15 Dehaze: report

**STATUS: PAUSED, NOT VERIFIED. Do not merge.** The owner paused the programme mid-round.
Spec written and amended; builder round 1 complete but too weak; builder round 2 stopped
mid-tuning (usage limit, then pause). The independent verifier never ran. Branch head
carries round 1's code, which keeps CPU and GPU in step but is known to fail the spec.

## For the owner

1. The old Dehaze was wrong: +100 mostly darkened (−1.6 EV on 4213) and cut sky saturation, and it left 100–190 px horizon halos.
2. Round 1 fixed the safety problems (no crush, no casts, no halos, no airlight flips, preview matches full size) but made Dehaze far too weak: about ΔE 1 at +100 on 4213.
3. That fails the strength lines and the existing proof authority floor (9.8 against 68), so ControlProofTests and the new U2 test will be red in CI.
4. Round 2 (stronger per-channel physics) is a half-tuned CPU-only patch at 24/44; it is not applied.
5. To resume, apply `round2-wip.patch`, finish tuning to the spec, mirror it into the GPU twin, then run the verifier.

## Where things stand

| Item | State |
|---|---|
| Audit (`AUDIT.md`) | Done. 16 findings on six corpus frames plus synthetics. No Lightroom exports exist in the repo, so LR comparisons rest on documented behaviour (sources in AUDIT.md). |
| Spec (`SPEC.md`) | Done, 44 lines after the round 1 amendments. On the pre-fix code 6 of 40 passed. |
| Spec amendment, round 1 | Halo profiles that compared two different surfaces were fixed (geometry only, no threshold loosened). Every original halo still fails on the pre-fix code. Strength lines P8–P10 and N5 were added. Details in SPEC.md, "Amendments (round 1)". |
| Builder round 1 (branch head) | 33/44 on the amended spec (`round1-results.txt`); 36/44 counting the U10 corpus airlight numbers, which pass in Swift. |
| Builder round 2 | Stopped mid-tuning. CPU only. `round2-wip.patch`, best run `round2-wip-r2a.txt` (24/44). Not applied. |
| Verifier | Not run. |
| CI | This push carries known failures, listed below. |

## Round 1 results on the amended spec

- **Pass:** I1, P1–P4, P6–P8, C1–C8, H1–H3, S1–S4, R1–R3, G1–G6. A1–A3 pass in Swift via U10; the Python probe copies the old airlight rule and reads FAIL.
- **Fail:**
  - P5: far-field local contrast ×1.10–1.23, needs ≥ 1.30 on 4213.
  - P9: positive strength ΔE 1.1–1.6, needs ≥ 5 on 4213.
  - P10: authority 9.8 against the floor of 68.
  - N1: 3437 at −50, 1.05 against ≥ 1.20.
  - N3: far black lift 0.001–0.018, needs ≥ 0.02.
  - N4: far contrast ratio 0.94–0.97, needs ≤ 0.85.
  - N5: negative strength 1.1–1.3, needs ≥ 2.5–3.0.
  - U2: ground contrast ×1.11, needs ≥ 1.3.

## Known CI failures on this head

- `WS15DehazeSpecTests.testPositiveRestoresSkyChromaAndGroundContrast` (U2): genuine failure, round 1 is too weak.
- `ControlProofTests`, detail.dehaze authority floor: the re-recorded record holds 9.8 against 68. The floor was not lowered.
- The GPU path was mirrored by hand and parses, but it has never been compiled or run; macOS GPU parity is unproven.

## What changed (round 1, at head)

`DetailEngine` (airlight from a fixed 256 px proxy, upper-frame bright-region rule; per-surface fields; fixed-hue chroma restoration; neutral airlight), `RenderGraph.applyDehaze` and `Kernels.dehazeSource` (same algorithm, shared constants), and new tests `WS15DehazeSpecTests` and `WS15DehazeAirlightCorpusTests`. `Proof/records/detail.dehaze.json` was re-recorded. One sentence in `BUILDING.md` was changed for spec line G6. Full design and rejected alternatives are in `BUILD-NOTES.md`.

Base-commit test baseline: 3044/3044 LumenCoreTests passed on Swift 6.1.2. `cloud-setup.sh` installs 6.0.3, which cannot build LumenApp, so tests need 6.1.2.

## Evidence (round 1; before on top, after below)

The three best:
- `evidence/01_4213_horizon.png`: storm-sky and halo fixed, but the haze is barely cut.
- `evidence/10_4213_sweep.png`: the full slider, old against new.
- `evidence/05_3437_negative_veil.png`: the pink veil is gone.
