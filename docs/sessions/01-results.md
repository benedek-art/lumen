# Session A — results (owner, 2026-08-26, delivered in chat)

Build: branch head (c81ac57 era). Format free-form rather than the checklist; every
observation is quoted or tightly paraphrased, then triaged. Diagnosis is repo-side,
per the protocol.

## What the owner saw

1. "Double clicking the slider doesn't turn it back to the reset for that specific
   slider." — **Confirmed defect, fixed.** The track had a `TapGesture(count: 2)`
   BEHIND a minimumDistance-0 drag; the drag claims every press, so the tap never
   fired and the first click jumped the value to the press point. This is exactly the
   "double-click reset vs the track-jump" item M2 had queued for re-verification.
   Fix: the drag's own press handling reads `NSApp.currentEvent.clickCount` and
   routes ≥2 through `reset()` (so optional-backed rows still CLEAR, not pin). Same
   fix applied to the colour wheel, which had the same buried tap.

2. Exposure / Contrast / Highlights / Shadows / Whites / Blacks: "seem to be
   working." — **MAC-04 SETTLED.** All six tone controls confirmed alive by the owner
   at real travel. The first session's readings (travel 2–11 on ±100 scales) are
   explained; no dead controls.

3. "If I press on the image, it zooms in, but then it kind of glitches all over the
   place when I move the sliders." — **Root-caused, fixed; this is MAC-07's face.**
   While zoomed, `effectiveRatio` returned the bare zoom level, so the drawn size was
   the RENDERED image's pixels x zoom — and the rendered image flips between a
   ladder-capped draft (≤2048) and the full settle (~4600) on every slider event: a
   4.5x size oscillation. Two parts to own honestly: the DraftLadder wiring REGRESSED
   the zoomed-draft invariant (`DraftResolution` used to force zoomed drafts to
   settle size — expensive but size-stable; the ladder capped them small and nothing
   re-checked the invariant), and the display maths never normalized. The fix is
   `LoupeGeometry.zoomedRatio` — zoom x full/rendered — so any proxy occupies the
   settle's extent and a drag changes sharpness, never size (drafts stay
   ladder-cheap; 1:1 drags get FASTER as well as stable). `ZoomedRatioTests` pins it.

4. "It isn't quick to edit... it switches little by little instead of going up in a
   ramp; anything that I press is not updated well in time." — **Two suspects, one
   fixed, one to measure.** (a) Zoomed drags pre-fix rendered FULL-RES drafts per
   event (~100+ ms each) — if any of this was observed zoomed, the ladder+normalize
   fix addresses it directly. (b) At fit, small tone moves may quantize through the
   32-knot tone LUT/cube: a nudge that lands between knots changes nothing, then
   steps — "little by little" is what knot quantization looks like. That is M2's
   knot-density measurement, now first in the queue. HUD numbers (input→draft, draft
   ms) were not captured this session — still wanted next session to separate
   "frames are late" from "frames are coarse".

5. "Texture doesn't really seem to be working... I think it's working but I don't
   know if the accuracy is right." — matches the ledger: Texture ships a one-band
   approximation, magnitude unmeasured post-fix (M3, demotable). Clarity/Dehaze
   "working pretty good" — consistent with the ε rim fix.

6. "Density doesn't seem to be able to be moved. Only Protect Skin." — **Not a
   defect: Saturation was 0.** Density blends a Saturation PUSH and is deliberately
   disabled at sat ≤ 0 (`ColorAdjust.densityIsLive`), with the explanation in a
   hover tooltip + the note below. Discoverability miss: a grayed slider whose
   reason lives in a tooltip reads as broken. Candidate polish: inline the reason
   when disabled.

7. The owner's priority, verbatim in intent: **accuracy over features.** "The
   difference between us and Lightroom is less so the product, it's more so the
   accuracy... I would like to determine a factual and testable area where this
   comes out as accurate as possible." → M2 is promoted to exactly this: calibration
   contracts per basic slider, fine-travel smoothness measurements, tone-cube knot
   density, and recorded baselines against open implementations (Lightroom
   side-by-sides need owner-exported references).

## Gate outcome

- MAC-04: **closed** (owner-confirmed working controls).
- MAC-07: **root-caused and fixed** (zoomedRatio); owner re-check next session.
- Double-click reset: fixed, owner re-check.
- M1b exit gate ("sliders feel immediate; no pop-on-release"): **not yet met** — the
  owner reports steppy/late updates; no pop-on-release was reported, no HUD numbers
  captured. Next session: HUD numbers + retest zoom + double-click.
