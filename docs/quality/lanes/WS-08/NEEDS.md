# WS-08 needs from other lanes

Things the WS-08 build found or relies on, in code it does not own. Nothing here is edited by WS-08.

## WS-07 (tone stage S7, the bake, the cube)

- **GPU tone cube resolution (audit Z-6).** The cube is 32³ for interactive renders and 65³ for export along grey.
  An eased zone curve still has 2 EV features, and the 32-knot cube misses them by an estimated 0.09–0.19 EV. It
  needs a 1D gain texture or ≥ 256 grey samples. A zones parity golden should be added at the same time; no
  `LumenPipelineTests` parity test uses a zones recipe today.
- **Stale comments in WS-07's functions.** The register now limits itself (`ToneEngine.appliedZoneEV`), so these
  sentences are no longer true:
  - `ToneEngine.bakeGainLUT`: "the Zones panel, which is the explicit power tool and would stop being one if it
    were limited";
  - the `Flattening` doc comment: "The clamp is the Zones panel's only limiter" and the Darks +2 / +4 numbers;
  - `RenderPlan.swift` around line 610, which describes the floor in terms of a Zones-only clamp.
- **The clamp backstop for zones combined with Contrast or the six sliders.** The zone ease does not see them.
  Since round 2, a zone spills its excess into its neighbours at exactly the 0.25 floor, so negative Contrast has
  more to undo. Contrast −100 with Darks +3 flattens −3.18 … +2.22 EV (worst 0.40 EV, possibly two merged bands —
  Z-10); at Contrast −60, −1.33 … +1.56 (worst 0.05); at −40, nothing. The panel reports it through the existing
  flattened caption. A joint solve, or feeding the contrast slope into the zone limit, belongs with
  `solveZonalLimits`.
- **`zoneFlattening` under-reporting (audit Z-10).** It merges separate bands into one. This is unchanged.

## WS-58 (keys, recipe surface)

- Verified, no edit needed. `WorkspaceModification` (`develop.zones != Zones()`) and `ToneKeyInputs`
  (`develop.zones`) stop seeing wheel/sat/falloff because `ZoneAdjust` no longer has them. A recipe carrying only
  those keys now decodes to `Zones()`, so it neither marks Tone modified nor re-bakes S7.
- Pivots did not move (Z2), so no recipe-version migration is needed.

## WS-35 (grading wheels)

- `GradeEngine.normalizedAxis` has the same Whites/Blacks coupling as Z3. The grading strip's zones move when the
  white or black point moves.

## WS-05 (Basic panel)

- `BasicPanel.zonesExpanded` is private `@State`, so the fold snapshot `panel-develop-tone-zones-open` still shows
  it closed. WS-08 renders `ZonesPanel` directly in its own snapshot cases. Making the fold injectable would fix the
  original one.

## Integrator (docs outside the lane folder)

- docs/04 §Zones:
  - wheel, sat and falloff are gone;
  - the zones are fixed in stops (−9 … +5 EV axis, independent of Whites/Blacks);
  - pivots are at least 1 EV apart;
  - a seam that would run slower than 0.25 stops per stop is eased, and the panel shows the applied value.

## Later (no lane yet)

- A histogram behind the pivot strip, and an auto-fit of pivots to the image (darktable-style). This is the real
  answer to "Brights does nothing on this photo" (Z2).
