# The first session on a Mac

2026-08-23. The owner opened the app on his own machine against a folder of his own
frames — the first time any human has run it. Everything below is his, in the order he
said it, with what was already known about each and what was done.

The audit that preceded this was seven agents reading code for a day. It is worth
recording which of these it had already predicted, because that is the only honest way to
measure what reading code is worth.

---

## The one that outranks everything he listed

**MAC-01 — the folder never registered, so nothing he did was saved.** BROKEN.

An orange message in the sidebar, which he did not mention and which matters more than
anything he did:

```
Could not register pix with the catalog — DecodingError.keyNotFound: Key 'core'
not found in keyed decoding container. Path: develop.mixer.bands[0].
```

`MixerBand.core` and `.feather` are non-optional with defaults in the memberwise `init`
and no custom `init(from:)`, so Swift's synthesized `Codable` REQUIRES both keys. His
sidecars predate those fields. Registration fails, and with it every rating, flag, label
and edit for the whole folder.

**The scope is worse than the message.** 36 of 39 Codable types in the recipe layer have
no tolerant decoder — only `ClassicNR`, `BlackAndWhite` and `Mask` do, each added
reactively when somebody hit this same wall. Fixing the key the error names would move him
to the next missing key on his next launch.

Not predicted by the audit. Nothing in a day of reading found it, and thirty seconds of
use did.

---

## Confirmed, and predicted

**MAC-02 — the temperature slider's scale.** *"Why does it go from 2,000 Kelvin to 50,000
Kelvin? I don't think anything even changes above like 15,000 Kelvin."*

This is TONE-09, found by reading, now confirmed by a photographer without prompting. The
engine already works in mireds — `1e6 / kelvin`, the perceptually even axis every other
raw editor uses — and only the SLIDER is linear in Kelvin, which crams the visible range
into the bottom fifth. The proof harness had independently measured 97% of the control's
effect in the first half of a 3000–9000 K sweep, which is the same defect seen from a
third direction.

**MAC-03 — sliders slow and unresponsive.** *"Right now the sliders are really slow.
Everything is super unresponsive. The image isn't really updating very well."*

This is UX-01 and UX-03 and it is also, word for word, the complaint that produced docs/19
Phase 1 — four fixes landed for it and none was ever verified by a human. It is still
here. New tonight and a prime suspect: the disk preview cache takes a `queue.sync` onto
the catalog's serial queue per decode, and during a first scan that queue is also running
the EXIF backfill.

---

## Needs a measurement before it is believed

**MAC-04 — "Highlights don't work. Whites don't work. Blacks don't seem to work."**

Look at the values in his own screenshot: **Highlights 2, Shadows 7, Whites 11, Blacks
−7.** Those are tiny settings on ±100 sliders where the effect *should* be nearly
invisible, and the registry records these controls at 55.8 / 47.6 / 23.3 code values at
FULL travel on the reference renderer.

So the likely reading is not three dead controls but one dropped gesture: his drag moved
the value by 2 and he judged a slider that had barely moved. He also said the sliders are
unresponsive, and he said Shadows works — Shadows reached 7.

That is a hypothesis and it is recorded as one. It is exactly the shape of the reasoning
that was WRONG about `mixer.red.hue` earlier today, where a plausible mechanism turned out
to be false on measurement. It gets confirmed or refuted, not assumed.

---

## Interface

**MAC-05 — the blue rectangle around the image.** *"I think we should remove that blue
square."* It is macOS's own focus ring: `LoupeView` is `.focusable()` and focused on
appear, which it must be, because the entire bare-key culling grammar depends on it. The
ring is the system's, not the app's.

**MAC-06 — the histogram readout row collides with the panel below it.** *"I want to make
sure that the working percent, the sRGB, and output 255 is not in the same layer or
visually the same as the other pages, like the color or the curves, because they're kind of
overlapping."* UX-15 recorded truncation risk in this panel at 320 pt; this is that risk
arriving as overlap rather than truncation.

**MAC-07 — unexpected zoom.** *"There are lots of zoom in, zoom out things that happen when
I'm not pressed on the image full screen."* Narrowing detail worth keeping: it happens in
fit mode, not at 1:1.

**MAC-08 — tint's response is uneven.** *"If I try to tint it blue, it goes from slightly
blue to an entirely full blue."*

**MAC-09 — exposure is very intense.** Its recorded authority is 169.07 code values, the
largest of any control in the registry by a wide margin.

**MAC-10 — double-click to reset a slider.** He asked for it. **It already exists** —
`LumenControls.swift` has `onTapGesture(count: 2) { reset() }` at three separate sites. So
either it is not working on his machine or it is undiscoverable, and both are findings. A
feature the owner asks for while it is in front of him is not a feature.

---

## What this says about the audit

Seven agents reading code for a day predicted MAC-02 and MAC-03 exactly, and missed MAC-01
entirely — a total loss of catalog state, visible within seconds of launch, sitting in
orange text on the first screen.

Reading found the things that are wrong in the code. Using found the thing that was wrong
about the code meeting a real folder of files with history. Neither substitutes for the
other, and the ratio of effort — one day against thirty seconds — is the argument for
doing the second one first, and much more often.
