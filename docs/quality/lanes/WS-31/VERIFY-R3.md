# WS-31 Colour Mixer — Verify round 3 (final), sha 39c68a7

**Verdict: PASS.** The ring fix is correct. The one CI failure is the known pre-existing `fixtures-linux` "Swift surface" failure, and its findings are identical to base.

## 1. Ring fix (`MixerHueRing`, ColorPanel.swift 1435–1781)

The diff from 3dc4f91 to 39c68a7 touches only ColorPanel.swift (+73 lines) and ColorPanelReachTests.swift (+76 lines, 2 tests).

### `displayArc`
- A core shorter than 18 pt is spread to exactly 18 pt. The spread keeps `mid = (above − below)/2`, so the true `coreCentre` does not move.
- Each feather handle stays at its true outer angle, or at 14 pt outside its core handle if that is further out.
- An arc that is already legible is returned unchanged.
- Engine limits (core 3.4–44°, feather 12–60°) rule out negative or degenerate cores. The largest drawn span is the true span (≤ 208°), or 46 pt (≈ 44°) when spread. So the arc cannot wrap onto its own other side.
- Only the selected band is drawn, so it cannot overlap another band's arc.
- Wrap at 0/360° is handled: `arcPath` and `point` use cos/sin on unwrapped degrees, and the handle positions use `wrapHue`.
- Fuzz test, 200k random arcs inside engine limits at R = 60 (scratchpad `fuzz.py`): 0 violations of core ≥ 18 pt, feather ≥ 14 pt, `coreCentre` kept, span < 360°. The closest core separation was 17.99999999 pt.

### Hit test
- `grab` is called against the same `displayArc` the Canvas draws, using the same radius function.

### Drag
- The drag writes `wrapHue(grabDegrees + hueDelta(grabPointer, pointer))`.
- `grabDegrees` is the handle's TRUE angle at the press; `grabPointer` is the press angle.
- The sign is correct, and there is no jump: the fuzz test confirms a first move of ε writes true + ε.
- Crossing ±180° makes no difference, because the sum is taken mod 360.
- Values written go through the existing `draggedArc` clamps (core 3.4–44°, feather 12–60°), so nothing can be written outside engine limits.
- Double-click reset, the press-is-not-a-move gate and the annulus gate are unchanged.

### Minor (UX, not bugs)
- While the true core is under ≈ 17.2°, dragging one core handle slides BOTH drawn core dots at half the pointer's speed. This is inherent to the symmetric spread; the true opposite handle does not move.
- A true feather of 12–13.4° draws at 13.4°, a small dead zone in the display.

## 2. Local checks

| Check | Result |
|---|---|
| `swiftc -parse` | clean |
| `check-swift-surface.py` | same findings as surface-base.log; only AppState line numbers shifted (3163/3172 → 3180/3189) |
| `swift test --parallel --filter LumenCoreTests --skip ControlProofTests` | 3070 tests (3068 + 2 new), exit 0, 0 failures |

## 3. CI for head 39c68a7

| Workflow | Conclusion |
|---|---|
| CI | failure. One job failed: `fixtures-linux`, step "Swift surface". engine-linux, app-bundle, build-macos and test-fast all passed. |
| GPU parity | success |
| Proof sweep | success |
| UI layout | success |
| UI snapshots | success |

The `fixtures-linux` findings on 39c68a7 are the same as base a93efb2's CI log, compared after stripping line numbers:
- `Font is in LumenRender` (LumenType.swift:30);
- 5 `set(_, forKey)` label findings in AppState and PanelLayout;
- 6 LumenRender inits;
- 1 `CommandLine` symbol.

Nothing is new; this is the pre-existing failure.

## 4. Snapshots (`ui-snapshots`, quality-k2-color-mixer/39c68a7)

- The only PNG that changed against R2 is `panel-grade-colour-mixer-band-range.png` (674094ff). `panel-grade-colour`, `point-colour`, `all-bands`, `mixer-hue`, `saturation` and `luminance` are byte-identical to R2, which R2 had already checked against baseline.
- In the new ring, the Yellow core dots sit ≈ 17.5 pt apart, centre to centre, with a visible bright segment between them. The blue core-centre tick is midway between them, and the dim tails and feather dots are clearly separate.
- `index.md` has 3 "could not find" entries (Noise Reduction, Zones, Masks folds). The same 3 are present in baseline a93efb2. There are none for Colour states.

Before/after image: `/tmp/claude-0/verify3/ui_before_after.png` (210 KB). It shows baseline point-colour, new point-colour, and the ring at R2 vs R3.
