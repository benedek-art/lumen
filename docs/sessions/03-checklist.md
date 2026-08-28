# Owner session C — the slider round, and the one number that settles it

Third report of the same thing: "it's still not smooth … one by one, like tick by tick."
Two rounds of fixes before this one were real defects that were not the cause. This
round measured instead of reasoning, ruled three expensive fixes OUT, and fixed two
things — but the last question cannot be answered from the repository. It needs you at
the app for about fifteen minutes.

**Step 1 is the whole point of the session.** If you only do one thing, do that one.

**Build:** download the `Lumen.app` artifact from the newest green CI run on
`claude/photo-editor-design-plan-8ahzmm` (GitHub → Actions → CI → the run →
Artifacts), unzip, then in Terminal:

    xattr -dr com.apple.quarantine ~/Downloads/Lumen.app

**Fill in first:**

- CI run number the build came from: `……`
- Photo folder used: `……`
- Mac model, and whether the Lumen window was full screen: `……`

---

## 1. THE NUMBER. Is the app SEEING your hand, or failing to draw it?

⌥⌘L for the HUD. Its top line is new:

    in/out    87/s   12fps

`in` is how many slider movements the app actually RECEIVED per second. `out` is how
many pictures it drew per second. Open a photo, go to Basic, and drag **Exposure**
steadily for three or four seconds. Read the top line **while dragging**, not after.

Then do the same for **Whites**, **Saturation** and **Texture**, since those load
different parts of the machine.

**Write both numbers per slider:**

| slider | in /s | out fps | draft ms @size | did it feel smooth? |
|---|---|---|---|---|
| Exposure | …… | …… | …… | …… |
| Whites | …… | …… | …… | …… |
| Saturation | …… | …… | …… | …… |
| Texture | …… | …… | …… | …… |

**Why both numbers and not one.** Latency alone cannot tell two opposite problems
apart, and three rounds of this work have been argued without the distinction:

- **`in` high (60–120), `out` low (under ~20)** — the app sees every bit of your hand
  and cannot draw fast enough. The fix is in the rendering, and the measurements say
  making the picture smaller will NOT help much below a certain size, so it would mean
  changing the pipeline.
- **`in` and `out` both low and roughly EQUAL (say 12 and 12)** — the app never saw
  most of your hand. macOS threw the movements away before Lumen got them, because the
  main thread was busy. Nothing about rendering touches this. This is what the two
  fixes in this round were aimed at, so if you see it, they were not enough and the
  next step is already written down.

A dash `—` means the app has not seen enough events to compute a rate yet; keep
dragging.

Two things about `in`, so it is not over-read. It counts slider movements that
actually CHANGED the value, not raw mouse events — so a very slow drag, where several
mouse events land on the same value, reads lower than the hand really moved. Drag at
the speed you would actually work at. And the HUD costs a little main-thread work
itself, which is the very thing being measured; it is one small overlay against a
window of panels, so it will not change which of the two answers you get, but do not
read the last digit.

**What I saw:** ……

---

## 2. Does it feel different from last time?

Plain words, no numbers. Drag every slider in Basic, then Detail, then Color.

**Look at:** whether the picture follows your hand as a slope, or advances in visible
steps. If it steps, roughly how many steps per second — two? ten? — and whether the
slider's own **thumb and the number beside it** step with the picture or move smoothly
while only the picture lags. That difference matters: a thumb that steps means the app
is not receiving your hand, which is a different fault from a picture that lags.

**What I saw:** ……

---

## 3. Letting go should now be quicker

Drag any tone slider, let go, and watch the moment it sharpens.

**Look at:** the picture should go sharp shortly after you release. It used to render a
frame it already had and then wait 40 ms before starting the good one — about seventy
milliseconds of doing nothing useful at the one moment you are waiting. That is gone.
What must NOT have appeared: any flicker, a coarse frame, or a colour change on
release. Sharpness should arrive; nothing else should move.

**What I saw:** ……

---

## 4. The panels must still follow the photograph

This round stopped a slider edit from re-drawing the whole window, which is the point —
but it means each panel that shows an edit now has to subscribe to edits explicitly. If
one was missed, that panel will draw once and then silently stop following.

Open each develop section in turn — the app's own eight tabs, **Basic · Zones ·
Curve · Color · Detail · Effects · Masks · Look** — and in each, move one control.
Sliders where there are sliders; in Curve drag a point; in Masks add a gradient and
move its Exposure.

**Look at:** the control's own number (or the curve's own shape) changes as you drag,
and the picture follows. Then press **⌘Z** and confirm the panel goes back with the
picture. Anything that shows a stale value, or a number that does not move while the
picture does, is a missed subscription — name the panel and the control. This is the
most likely way this round broke something, so it is worth the five minutes.

**What I saw:** ……

---

## 5. The menu bar was taken off the drag path — check it still works

The Edit menu used to be rebuilt on every mouse movement of every drag. It is not any
more, which means its labels are now kept current deliberately rather than by accident.

**Look at:**
- Make an edit. Edit menu → it says **Undo Edit**, enabled. Redo is greyed.
- ⌘Z → the picture reverts; Edit menu now offers **Redo Edit**.
- With no folder open, File → **Back Up Catalog** and Export → **Export…** are greyed;
  with a photo selected they are not.
- Debug menu says **Hide Latency HUD** while the HUD is on and **Show** while it is off.
- The develop column's own Undo/Redo buttons agree with the menu at all times.

**What I saw:** ……

---

## 6. Switch folders after editing — this crashed in an earlier draft of the fix

Edit a photo (any slider), then open a different folder. Then a third. Then come back.

**Look at:** no crash, and the Edit menu's Undo is greyed once the new folder is open
(history belongs to the roll that produced it). This is here because a version of this
round's change did crash exactly here — an empty undo stack still being indexed into —
and it was caught by a test rather than by you, which is the way round it should be.

**What I saw:** ……

---

## 7. Zoom still behaves

Pinch to zoom in on a photo, pan, pinch back out, then double-click to return to fit.
Drag a slider while zoomed in.

**Look at:** no jump on the first pinch, no coarse frame replacing a sharp one when you
zoom, and sliders behave the same way zoomed as they do at fit. The draft/settle rules
were touched this round and this is the path that shares them.

**What I saw:** ……

---

## What happens next, depending on step 1

Nothing below needs your input — it is written down so the reading you take has an
obvious consequence rather than becoming another round of guessing.

- **`in` low and equal to `out`** → the main thread is still eating your input. Next
  lever: `AppState` → `@Observable`, so a view is invalidated only for the properties
  it actually reads. This round's two small observables are the first step of that, not
  a substitute for it.
- **`in` high, `out` low** → the render is the ceiling. Measured: the frame stops
  getting cheaper below about 1024 px, so the answer is not fewer pixels — it is fewer
  or cheaper passes, which is a pipeline change and a real piece of work.
- **Both high and it feels smooth** → it is fixed, and the number says why.
