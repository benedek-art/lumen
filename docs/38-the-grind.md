# The grind — what changed, and what to look at

Three hundred commits between `1a4b7a2` and here. This is the durable record: what was
found, what was fixed, what was found to be already fixed, and what is still open with
its reason. `docs/audit-2026-09/` holds the working papers — the ledger, the 122 audit
findings, the W3 dispositions, the perf baseline.

## The shape of it

The work ran in three kinds:

**Discovery** produced a 104-row backlog with a perf baseline, seven research dossiers
against Lightroom Classic, Capture One, DxO, darktable, RawTherapee and the creative
bar, and thirteen area audits totalling **122 findings**.

**Landings** fixed them, one commit per defect, each with a test that goes red when the
defect is substituted back. That last clause is the whole discipline: break it, watch it
fail, restore. A check that has never failed is not a check, and this session was bitten
by that three times in one file.

**Verification** — W3 — re-read every finding against the code that now exists rather
than the code the audit read. Its most useful output was not a fix.

## What a photographer will notice

**Nothing loses work any more.** Ten S1 rows, every one about a photograph or an edit
that could not be recovered: two RAWs with one basename sharing a sidecar and destroying
each other's edits; a brush stroke overwriting every selected photograph's mask; a
sidecar silently dropping a whole painting past ~20 000 points; export presets wiped by a
strict decoder when a build added a field; a newer build's recipe quietly downgraded on
open; brush blobs in no backup; a rating keystroke destroying another tool's colour
label; a culling keystroke destroying a rating.

**The film emulation is right where it was wrong.** The grain in a colour stock's
exported file no longer carries coloured speckle no preview could show — measured 2.06×
the luminance noise, now 0.41×, with the luminance grain itself held to +0.04%. The
grain you see in the fit view is now the low-pass of the grain in the file rather than a
differently-pitched pattern. Halation gained the Size and Redness controls that had been
computed from since the day they were written and reachable from nowhere. Point Colour
selects its own colour instead of moving the whole photograph. Turning Saturation down no
longer switches the black-and-white mix off.

**The app looks like one thing.** One type scale, one glyph scale — separate, because an
SF Symbol's point size is not a type size and holding them on one number is why 89 raw
sizes survived three migrations. One radius ladder. One empty state where there were
five. Three motions where a fold animated four ways. 24 pt rows on one pitch. Lights Out
and the ISO 12646 assessment surround.

**The sliders feel like sliders.** A drag on a grading wheel is one undo step, not four
hundred. Letting go of one stops waiting for a table the machine is already baking. ↑
and ↓ do something.

**The updater checks who built the update.** It verified that the download was signed and
never by whom — and these builds are ad-hoc signed, so an ad-hoc signature made by anyone
satisfied that. CI now publishes the asset's SHA-256 and the app refuses anything else,
before the archive is unpacked. It also stopped moving your installed copy out of the way
before putting the new one in, which is the window in which an alert saying "the running
build is untouched" was not true.

## What to test, in ten minutes

1. **Two RAWs with the same basename** in one folder (a `.NEF` and a `.DNG` of the same
   frame). Edit one. Open the other. They no longer share a sidecar.
2. **Paint a brush mask with several photographs selected.** Only the one under the
   pointer takes the strokes.
3. **A long painting** — thousands of points. Close and reopen. It is all there.
4. **A colour stock at grain 40, exported at full size.** Look at a flat mid-tone at
   100%. Grain, not coloured speckle.
5. **Film Lab › Halo Size and Halo Redness.** They were not there yesterday.
6. **Drag a grading wheel, then ⌘Z once.** One step.
7. **Focus a slider and press ↑.** It moves.
8. **`L`** cycles Lights Out; **`⌘B`** is the assessment surround; **`B`** is the album.
9. **Open a folder with a filter that matches nothing.** The empty state says the
   photographs are still there.
10. **Help › Lumen Keyboard Reference.** Every shortcut the app actually dispatches.

## What is still open

`docs/audit-2026-09/w3/dispositions.md` ranks all of it. The short version:

- **The colour-science group** (`B1-04…08`) — the mixer's band ring authority, Density's
  hue rotation, the H-K term's magnitude, the B&W mix's level normalisation, band names
  up to 27° off the colours they name. Each moves pixels and each wants its own proof
  ceremony.
- **The film group's remainder** (`C1-01…08` minus four landed) and the mask canvas and
  panel groups (`F1`, `F4`, `F5`).
- **The layout truncations** (`G1-01/02/04/05/06`). These are the one group source alone
  cannot settle: they need measurement at 320 / 380 / 520 pt against a running app.
- **Two found while landing, by measurement rather than by audit**: `plateSeed`'s three
  "independent" fields correlate at r ≈ 0.088, and `HalationProfile.normalizedWeights`
  exists with no caller, so Halation Amount is scaled by the raw bounce sum 1.75. Both
  renderers agree, so the second is a calibration question and not a parity break.

## What went wrong, recorded

**Five red pushes in a row.** U2 added a parameter to `LumenSlider` declared after
`bipolar` and passed after `title:`; Swift's memberwise initializer requires declaration
order. `build-macos` was red for two hours and `dev-latest` froze while I reported
progress. The root cause was a blind spot in `check-swift-surface.py`: it vetoed
`LumenSlider` entirely because of one `@State private var … Task<Void, Never>?`. Closing
that took the checker from 3977 to 4099 checked call sites and from 13 bailed structs to
zero.

**C2-01b did not reach the film path's GPU plate.** The band-limited plate landed in the
reference renderer and in one of the two CIImage plate builders. The other kept asking
for the unlimited plate, so a stock's grain went straight back to carrying the aliasing
the fix removes. The test that pinned the two builders together stayed green throughout,
because it compared what each asked for when asked for the *unlimited* plate. There is
one builder now.

**A test passed its own substitution proof by reading its own explanation.**
`EditRevisionRuleTests` searched for the word `EditRevision`; deleting the declaration
left the doc comment that explains why the declaration is there. `DesignSystemTests` had
already written that lesson down. `AppUpdater`'s check, written after both, strips
comments.

**A checker was read through a grep.** `check-swift-surface.py` exits non-zero and prints
findings in more than one shape; I counted the lines matching one shape and got 0 from a
program exiting 1. The exit code is the answer.

**Two corrections to the audit that raised the finding.** J1-02 named `setRating` and
`setLabel` as the calls a broken text index would fail; they never reindex, and the real
paths are keywords, job names and the EXIF backfill. C2-01 named the wrong grain channel:
the double half-pixel floor is provably a no-op for the two records it was blamed for.
Both findings survived, narrower and correct.

**And the first version of the C2-02 fix was wrong in a way only a proof record caught.**
Holding each dye layer's amplitude while removing their independence raises the LUMINANCE
noise 51%: `film.grain.size`'s authority went 40.1 → 44.1 and its non-monotone hand-back
14.9 → 33.7. The version that shipped holds the luminance instead. Nothing in the test
suite would have found that; the 135 committed proof records did.
