# Owner session A — the drag answers the hand

The M1a/M1b gate (docs/23): every basic slider on a hard photo, judged by eye and by
the HUD's numbers. ~25 minutes. Write observations in plain words under each "What I
saw" — no diagnosis needed, that happens repo-side. If something looks wrong, what
matters most is *what you were doing at that exact moment*.

**Build:** download the `Lumen.app` artifact from the newest green CI run on
`claude/photo-editor-design-plan-8ahzmm` (GitHub → Actions → CI → the run → Artifacts),
unzip, then in Terminal:

    xattr -dr com.apple.quarantine ~/Downloads/Lumen.app

**Fill in first:**

- Mac model / chip / RAM: `……`
- Display (built-in? 5K?): `……`
- CI run number the build came from: `……`

---

## 1. The folder comes back on its own

Launch, open a folder of real RAWs (File → Open). Quit. Launch again.

**Look at:** the second launch must land in the same folder with no open dialog and no
empty state.

**What I saw:** ……

## 2. Turn the instrument on

Debug menu → Show Latency HUD (⌥⌘L). Select a photo, nudge Exposure.

**Look at:** three numbers appear in the loupe's corner — `input→draft`, `draft @size`,
`settle @size`. They update while you drag.

**What I saw:** ……

## 3. Build the hard photo

Pick a real RAW (ideally high-ISO, or one with a bright sky). Set Sharpen ~80, leave
Denoise on, add a radial mask with generous feather + Refine, and give the mask
Exposure +0.8 or so. Every later step uses THIS photo unless it says otherwise.

**Look at:** nothing yet — this is setup. Note roughly what the photo is (ISO, scene).

**What I saw:** ……

## 4. Exposure is the yardstick

Drag Exposure slowly −2 → +2 and back, watching the picture, then the HUD.

**Look at:** the picture tracks the hand continuously — no stutter, no wait-then-jump.
**Write down the HUD numbers** while dragging: input→draft ≈ `…` ms, draft ≈ `…` ms
@`…`.

**What I saw:** ……

## 5. Whites and Blacks must feel like Exposure

Same slow drag on Whites, then Blacks, then one curve point, then a colour wheel.

**Look at:** these used to respond at a fraction of Exposure's rate (each frame re-baked
colour tables). They must now feel the SAME as step 4. Write the HUD draft ms for
Whites: `…` ms. Any slider that still feels heavier than Exposure — name it.

**What I saw:** ……

## 6. Do Highlights/Whites/Blacks actually work (MAC-04)

On a frame with a bright sky: Highlights −100, then +100. Same full travel for Whites
and Blacks, one at a time, others at 0.

**Look at:** full travel must be unmistakably visible — sky detail crushed/recovered,
whites clipping, blacks blocking. This settles "Highlights don't work" with evidence:
the earlier session judged them at travel of 2–11 on a ±100 scale.

**What I saw:** ……

## 7. Nothing may change on release

For each of: Exposure, Contrast, Highlights, Shadows, Whites, Blacks, Temp, Tint,
Clarity, Dehaze, the curve point, and the mask's own Exposure — drag, release, and
STARE at the picture for two seconds.

**Look at:** on release the picture may only get *sharper* (the settle). Any shift in
brightness, colour, contrast, grain, or mask edge at release is a failure — name the
slider and what shifted. This is the whole point of the milestone.

**What I saw:** ……

## 8. Shadows must not halo (the ε fix)

A backlit frame — dark subject against bright sky. Shadows +100.

**Look at:** the dark-to-bright edges. Before the fix, Shadows painted a ~half-stop
bright rim along such edges. There must be no glow/rim now. Compare against Lightroom's
Shadows on the same frame if it's handy.

**What I saw:** ……

## 9. Shadows must not chase noise

The high-ISO frame. Shadows +100.

**Look at:** shadows lift smoothly. Failure looks like crunchy/blotchy texture
appearing as you drag — the mask following the noise instead of the scene.

**What I saw:** ……

## 10. The sky in the loupe is the sky in the file (dither)

A frame with a smooth sky or gradient, at fit zoom. Export it (JPEG is fine). Open the
export next to the loupe.

**Look at:** the loupe used to show banding in skies the exported file rendered clean.
Preview and export must now show the same smooth gradient.

**What I saw:** ……

## 11. Draft softness is allowed, pumping is not

Drag Exposure fast back and forth for ten seconds, then hold the mouse still.

**Look at:** while dragging, the picture may soften slightly; on pause it resolves
sharp. Failures: the picture visibly changes SIZE, flickers, or oscillates sharp/soft
while your hand is still. Note the HUD draft `@size` after the burst: `…` — that is the
resolution ladder's chosen rung on your machine.

**What I saw:** ……

## 12. The unexpected zoom (MAC-07) — one observation

Work in fit mode (not 1:1) for a few minutes — browse, drag sliders, resize the window.

**Look at:** if the unexpected zoom-in/zoom-out happens, freeze and note WHICH was true
at that instant: (a) a slider was mid-drag, (b) the folder was still loading, (c) the
window was being resized, (d) nothing — pointer still. This one observation picks
between four different mechanisms; three theories are already refuted.

**What I saw:** ……

## 13. Double-click reset

Double-click the label of a few sliders you've moved (Exposure, a wheel, a mask
slider).

**Look at:** the value snaps to default and the picture follows immediately — no
lingering old rendering, no track-jump on the next drag.

**What I saw:** ……

## 14. A quit cannot eat an edit

Move a slider to a value you'll remember. Quit within a second of releasing. Relaunch.

**Look at:** the edit is there. (Edits during a drag persist on release; a quit
mid-gesture flushes the pending one.)

**What I saw:** ……

## 15. The verdict, in one line each

- Sliders feel immediate — yes / no / only some (which): ……
- Anything popped on release (which): ……
- The two numbers that summarize your machine: typical input→draft `…` ms, settle
  `…` ms.
- Worst moment of the session, in plain words: ……
