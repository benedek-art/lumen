# 22 — The first hour on a Mac

Everything in this repository has been verified by a compiler, a test suite and a Python
mirror of the engine. None of it has been verified by a photograph.

This document is the list of things that only a Mac can settle, ordered so that the first
hour answers the most questions. It exists because the pass that produced it closed 48
defects and could not touch about thirty others for one reason: no machine here can run
Core Image, SwiftUI, or a camera file.

## Before anything else

```sh
git fetch origin claude/photo-editor-design-plan-8ahzmm
git checkout claude/photo-editor-design-plan-8ahzmm
swift build          # the first real answer: does LumenApp compile outside CI
swift run LumenApp
```

Then open a folder of your own RAWs — not one file, a folder, ideally a card you have
already culled once in Lightroom so you have something to disagree with.

## The five that change what happens next

These are ordered by how much of the rest depends on them.

**1. Does a slider drag show one colour and apply another?** This was your report, it
drove the whole of docs/19 Phase 1, and four separate fixes landed for it — one LUT size
for draft and settle, the draft following the viewport, canonicalization off the input
path, and `AppState.photos` memoised. Nobody has seen whether it worked. Drag Temp, drag
Saturation, drag Exposure. Watch the frame while dragging and after release.

**2. Is a subject mask the right way up?** `VisionMattes` has never run. The buffer's
orientation is argued from convention — a CGImage's row 0 is the top, Vision returns the
same order, `Plane` is top-down too — and never observed. If a subject mask comes out
mirrored vertically, that is the line to look at and it is a one-line fix. Add a Subject
mask, set Exposure +2 inside it, and see which half of the picture moves.

**3. Does `CIRAWFilter` normalize sensor saturation to 1.0?** The entire meaning of the
new "% clipped" readout rests on this. Press ⇧H on a frame you know is blown. If the
percentage disagrees with what you can see recovering in the highlights, the ceiling is
not where the caption claims.

**4. Where does the eyedropper actually land?** The coordinate inverse is shared with
`MaskCanvas` and has two tests, but "the click lands where the cursor was" is not
something CI can say. Pick a white balance off a known neutral. Pick a Point Colour off a
shirt. On a CROPPED frame especially.

**5. Second-launch culling speed.** The preview cache now writes to disk and reads back;
README goal #1 is under 50 ms to the next photo. Open a folder, quit, reopen, and hold the
arrow key. The specific risk to watch, named when it was built: every decode takes one
`queue.sync` onto the catalog's serial queue, which during a cold scan is also running the
EXIF backfill in 200-row transactions.

## What a first session should record rather than fix

Bring back observations, not diagnoses. The pattern that produced the best work in this
repository is: you describe what you saw in ordinary words, and the measurement happens
afterwards. "Its slow finiky" and "a different colour comes up while I'm dragging"
produced more real defects than any audit did.

## The thirty that are waiting on this

Grouped by what the answer unlocks.

**Cannot be checked at all without hardware** — every latency budget in docs/12; whether
any panel truncates (the histogram readout tabs are known to overlap, the rest is
unswept); every Vision matte; whether the encoder writes ADDED metadata, which decides
whether Copyright and Contact actually reach the file; whether HEIC preview encoding
succeeds or silently falls back to JPEG.

**Written but never executed.** Four goldens in `Tests/LumenPipelineTests` have never run:
the halation width golden (which predicts 52.79 px² against a pre-fix ≈455), the graph
halation reachability test, the masked-colour export table size, and the export
kernel-failure refusal. By docs/20 none of them is a proof yet. Run `proof-macos` from the
Actions tab.

**Deferred because a fix needs a GPU to verify.** Texture ships at a fraction of its
reference and has been reverted twice; the third attempt needs the gate to tell a gradient
from an edge before the two radii can be decoupled, and every number is in docs/19.
Sharpening is not resolution-scaled, so an export is less sharpened than the frame you
judged. The CPU-fallback preview applies no crop, straighten or flip — the fix crosses
three row-order conventions and writing it blind risks an upside-down picture instead of a
wrongly-framed one.

**Deferred because it needs a model.** Tier-2 AI denoise, and four of seven AI mask kinds.
Three kinds — Subject, Background, People — run on Apple's Vision with no download.

## What this document is not

It is not a test plan and it is not a bug list. It is the set of questions this machine
cannot answer, written down while the reasons are fresh, so that an hour of your attention
is spent on the things that need a photographer and a screen rather than on rediscovering
what a test could have told you.
