# WS-02 report: eyedroppers and pick routing

**Status (paused by the director at 3454637): DONE and VERIFIED.** Verifier PASS on 61b7afd (`VERIFY.md`), every spec line. macOS CI, GPU parity, UI layout and UI snapshots green on 61b7afd. Linux suite 3086/0 on 61b7afd, 3105/0 on the merged branch (base c170432: 3058/0). WS-08 shares this branch and is NOT verified yet; see `../WS-08/REPORT.md`.

## For the owner

1. Pick a grey card at Fit and at 200% on a high-ISO file: the sample is now 5x5 screen pixels at ≤100% and 5x5 image pixels above (Lightroom's rule), so the WB no longer wanders ±15 mired between adjacent clicks (now 2.4-4.6).
2. Arm a picker, then switch photo, delete the swatch, or open crop: the pick is refused with a message instead of writing somewhere else.
3. Esc cancels a pick on the first press, even with a slider focused.
4. Clicking a blown highlight or near-black for WB now says so instead of returning a confident wrong neutral.
5. Judge the armed WB button (accent fill) against the mixer's armed button (grey fill); they differ.

## What changed and why

| Spec | Change | Measured |
|---|---|---|
| A1 | Point Colour / mixer pick reads the colour-stage input after denoise and Presence (`maskSource: false`), the image the colour stage actually compares. Mask taps unchanged. | macOS `PickTapParityTests` pass; old tap differs > 1e-3 with Dehaze/Clarity |
| B1-B3 | `PickSample.radius`: 5x5 device px at ≤100%, 5x5 image px above, cap 63 px; plumbed catcher → `resolvePick` → RenderCoordinator → samplers with no default. | Fit radius 9 (24 MP), 8 (G9). Neutral wander 1σ at Fit 3.0 / 4.6 / 2.4 mired (was 14.7 / 15.1 / 9.3) |
| C1-C2 | `PickArming` binds a pick to its photo and target counts; checked before sampling and after each await. | `PickArmingTests` 9/9, macOS `PickArmingAppTests` pass |
| D1 | Escape order is a pure function; an armed pick beats slider focus. | macOS `PickEscapeTests` pass |
| E1-E2 | Neutral guard: refuse when max channel ≥ 0.95 of clip, or Y < 0.002. Distinct status messages. | 0-4.9% of random windows refused as clipped on 25 frames (10.8% on the blown GX80) |
| F1-F3 | `PickGeometry`, a pure LumenCore twin of `PR.sourceNormalized`, Linux-tested; macOS parity test against the real one. | Round trip < 1e-9 over crop/±45°/flip grid; parity passes on macOS |
| G1 | Arming is refused while crop is armed or two-pane compare is up (there is no click target). | macOS test passes |
| H1-H4 | Every prompt names Esc; success messages for every target; sample-size square under the pointer; armed WB button look. | Snapshots `panel-develop-white-balance-armed`, `overlay-pick-indicator-fit/-200` |
| I1 | Five snapshot cases appended. | Rendered on 61b7afd |

One existing test data file changed: `LayoutMetricSupport.swift` slider citations moved +2 lines for the BasicPanel edit (the test checks line numbers).

## Not fixed / for other lanes

See `NEEDS.md`. Known gaps the verifier noted, none blocking: a re-sample remembers only the swatch count (remove one and add one, and it re-samples the new slot); the before/after refusal also triggers before the "before" image loads; the two armed-button styles differ. Lightroom's drag-a-rectangle sample for Colour Range is not implemented. The Linux test command at base fails to compile (two trailing commas in `CompareView.swift`, Swift 6.0.3); every Linux run here patched them for the run and restored them.
