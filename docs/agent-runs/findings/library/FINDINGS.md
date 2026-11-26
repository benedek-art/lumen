# Library tester (areas 1, 4, 5, 6, 7-navigation, 10): findings

App under test: `claude/loving-cray-d58nrb-integration` (build 805455c01e in runs 1 and 2, 288b693a69 in run 3), driven on hosted macos-15 VMs (VirtualMac2,1, Apple M1 Virtual, 3 cores, paravirtual GPU, 1600x1200 at 1x).
Fixture: the driver `raw` fixture plus six corpus RAWs added to `driver/fixtures/raw.tsv` on my branch `claude/loving-cray-d58nrb-test-library`. In capture order the roll is D200.NEF, 5D-12MP.CR2, A450-portrait.ARW (orientation 6), iPhone12P-portrait.DNG (orientation 6), EOSRP.CR3, Z30-portrait.NEF (orientation 8), Pixel7P-rot180.DNG (orientation 3), A7IV-33MP.ARW, XH2-40MP.RAF (known not to decode), indices 0 to 8.

Runs:
- 45744732517: build failed (the requests-branch driver has no `noteTimeline`). No scenarios ran.
- 45745190128 (run 1), 45748331573 (run 2), 45754701382 (run 3): built with 0 compiler errors.
- 45758313436 (run 4, confirmations): still queued at wind-down.

Repro files: `repro/run1-scenarios.json`, `repro/run2-scenarios.json`, `repro/run3-scenarios.json`, `repro/run4.json`, generators `repro/gen_run*.py`. `repro/states.py` summarises a scenario's state dumps (flag, rating and label per photo); `repro/lat.py` reads key-to-frame latency from `timeline.jsonl`. The artifacts are in `/tmp/claude-0/-home-user-lumen/7b419a8a-9f16-5bc3-bbad-d84e24161d81/scratchpad/library-work/run{1,2,3}/`.

## Findings, ranked by harm

### 1. BLOCKER: at launch a sidebar text field owns the keyboard, so cull keys are typed instead of applied and Return makes an album of them
- **What I did.** The app opens the folder in the grid (the launch state). I pressed P, X, 3, then Return, then clicked the first thumbnail and pressed P.
- **What I saw.**
  - No photo was flagged or rated: P, X and 3 went into the "New album" field.
  - Return created an album (status `Album "px3" created`; `app.collections.count` 0 → 1).
  - After clicking a thumbnail, P was still typed into the field.
  - In run 1, `]`, `[`, ⌘A, E, C and Escape all went into the field ("]]][[[...", "epx365u-94ppp").
  - In run 2, the search field had the focus instead. "p3" was typed, the grid showed "0 of 9", and the later cull keys acted on a hidden photo.
  - Keys only start to work once the loupe has appeared (⌘2 or a double-click), because the loupe takes focus on appear and the grid holds none.
- **Correct.** The grid owns bare keys from launch (AREAS 0.3), and a click on a thumbnail takes focus away from any text field.
- **Evidence.**
  - Run 2 `r2-01-launch-focus` (states `after-pxx`, `after-return`, `p-after-click`).
  - Run 1 `lib-01`, `lib-02`, `lib-05`.
  - Run 2 `r2-08-filterbar`.
  - Images: `images/run2-launch-keys-in-album-field.png`, `images/run2-album-px3-created-p-typed-after-click.png`, `images/run1-album-field-ate-cull-keys.png`, `images/run2-search-ate-p3-zero-of-nine.png`.
- **Confidence.** High under the driver (3 runs, 10+ scenarios). Medium-high that a normal launch does the same, since nothing was clicked before the keys.

### 2. BLOCKER (loses a decision): a filter that hides the selected photo leaves it as the cull target
- **What I did.** With D200 at Pick + 4★, I pressed ⌥⌘U (Show Unflagged Only, 5 of 9 shown), then E, X, X.
- **What I saw.**
  - The grid cursor index was -1.
  - E opened the loupe on the hidden picked D200. No pick badge was visible, and the filmstrip showed only the 5 unflagged frames.
  - The first X changed Pick to Reject. The second X changed it to unflagged. D200 went from `P4` to `-4`: the pick is lost.
  - Same root cause: with "Show Rejected Only" (0 shown), P picked and X rejected D200, a photo that was not on screen.
- **Correct.** When the selected photo leaves the filter, the cursor moves to a visible photo, and keys never act on hidden photos.
- **Evidence.** Run 3 `r3-11-filters` (states `u-before-loupe` to `u-loupe-after-x2`) and `r3-10-filter-hidden` (`h-p`, `h-x`). Image: `images/run3-loupe-shows-hidden-pick.png`.
- **Confidence.** High.

### 3. BLOCKER, likely: X and 3 pressed while the Filter popover is open still decide (X un-rejected a photo)
- **What I did.** In the grid, with D200 rejected, I clicked the Filter button at its centre (430, 69), then pressed X, 3, Escape.
- **What I saw.** D200's reject was toggled off and the cursor advanced; 5D got 3★; `history.position` went 2 → 4.
- **Correct.** AREAS area 4 journey 4: no decision while the popover is up.
- **Evidence.** Run 3 `r3-10-filter-hidden` (`pop-open`, `pop-x3`).
- **Caveat.** The driver cannot screenshot popovers. The proof scenarios `r4-01` and `r4-02` were queued in run 4 and did not run. Inference from the code: the dispatcher's guard (`keyWindow !== mainWindow`) passes when the popover never becomes key.
- **Confidence.** Medium.

### 4. BLOCKER, seen once: the ⌘K field did not take focus, so typing "Exposure" culled three photos
- **What I did.** Run 2 `r2-12-resize`: ⌘4, Tab, Tab, F, ⌘K, wait 0.6 s, type "Exposure", Return.
- **What I saw.** The palette was up (`showControlPalette` true), but the letters reached the cull dispatcher about 0.9 s after ⌘K. D200 was rejected, 5D picked, A450 unflagged; scopes turned on; the app entered Crop.
- **Correct.** The palette field has focus as soon as the palette shows.
- **Evidence.** States `film-toggled` and `palette-exposure`; the keyDown rows in `run2/r2-12-resize/timeline.jsonl` at t≈26.5 s.
- **Reproduction status.** Typing straight after ⌘K from the Cull loupe did NOT reproduce it (run 3 `r3-09-palette-race`). The trigger is the state, not the timing. Run 4 `r4-03` isolates it but did not run.
- **Confidence.** High that it happened; low on the trigger.

### 5. MAJOR (loses a decision): at the last frame, P toggles, so a double press or a held key un-picks
- **What I did.** With auto-advance on, I pressed P on XH2 (index 8, the last frame) three times.
- **What I saw.** Pick, then unflagged, then Pick (`r3-03` states `last-p1..3`). Five quick presses ended as Pick, which follows the parity (`r3-04` `after-rapid-p-last`). Keymap allows repeat of P/X/U/digits whenever auto-advance is on.
- **Correct.** At the end of the roll a repeated decision key changes nothing (in Lightroom, P sets the flag rather than toggling it).
- **Confidence.** High. True auto-repeat cannot be sent by the driver, but separate presses show the same toggle.

### 6. MAJOR (VM numbers): next-photo latency is far over the 50 ms paging budget, and most of the time is on the main thread
- **What I did.** Run 3 `r3-01-latency-cull`: Cull loupe with the filmstrip on, 2.5 s pause between presses so the cache is pre-decoded. Table in `repro/latency-r3-01.txt`.
- **What I saw** (times after the key arrives):

  | What appears | Time |
  |---|---|
  | EMBEDDED PREVIEW (first screen change) | 74–209 ms, median about 113 |
  | First rendered draft | 309–593 ms |
  | Sharp frame | 358–1006 ms (portrait frames slowest) |

- **Where the time goes.** For the keystroke at t=16.83 s, the main thread was blocked for 104 ms, then the render request was made, then the main thread was blocked again for 138 ms, then the render started at 241 ms, and the draft arrived at 307 ms (the render lane itself took 62 ms).
  - The key handler alone blocks the main thread for 55–185 ms on every keystroke.
  - 8 presses at 60 ms intervals caused one 775 ms stall. Paging still landed exactly, with no skips or doubles.
  - In Develop (run 1 `lib-09`), drafts took 274–318 ms and sharp frames 356–424 ms.
- **Correct.** Under 50 ms per photo at key repeat (docs/12 §12.2).
- **Confidence.** High for the VM. That the main-thread share also matters on a real Mac is inference.

### 7. MAJOR: the ⌘K result list shows rows that do not match the query
- **What I did.** Typed several queries into ⌘K and took screenshots.
- **What I saw.**
  - "kel": only "Reset", even after 3.3 s, yet Return went to Develop › White Balance.
  - "noise": "Temperature".
  - "nr": an unfiltered list.
  - "printer": only "Reset", yet Return opened Grade › Grading.
  - "zzqq": correctly says "No control or command by that name".
- **Likely cause (inference).** `ControlPalette.swift:198–230` overrides the ForEach identity with `.id(index)` inside a LazyVStack.
- **Evidence.** Run 2 `r2-14-palette-printer` and run 1 `lib-13`. Images: `images/run2-palette-results-montage.png`, `images/run1-palette-kel.png`, `images/run1-palette-nr.png`.
- **Confidence.** High that the display is wrong.

### 8. MINOR: the comma/period printer-light keys exist only while Grade › Grading is expanded
- **Works.** With Grading open: "." master 0 → 1, ×3 → 4, "," → 3; ⌃. Red/Cyan +1, ⌥. Green/Mag +1, ⇧. Blue/Yellow +1 (`r2-14`).
- **Dead.** In Develop, in the grid, with Tab hiding the panels, and in Grade with Grading collapsed (run 1 `lib-14`). The key reference lists ", ." with no such condition.
- **Confidence.** High.

### 9. MINOR: a second C or N always returns to the grid, even when you came from the loupe
- **What I saw.** Loupe, C, C ends in the grid; loupe, N, N ends in the grid (`r3-07`, states `c-from-loupe`, `c-c-from-loupe`, `n-n-from-loupe`).
- **Correct.** Return to the previous view.
- **Confidence.** High.

### 10. MINOR: Survey ignores the roll order
- **What I saw.** With 9 selected and the roll sorted by capture time, the panes are alphabetical (5D, A7IV, A450, D200, ...). → and auto-advance walk that order, and the third row is cut off by the filmstrip (`r3-07`, `images/run3-survey-order.png`).
- **Confidence.** High.

### 11. MINOR: the column divider grabs only on its left half
- **What I saw.** A drag starting at x=1003 (the column's edge; the hairline is at 1002) did nothing in runs 1 and 2. At x≈1001 it worked: 380 → 520 (clamped), → 320 (clamped), → 414.4 (`r3-12`).
- **Likely cause (inference).** The column covers the right half of the 6 pt hit overlay (`ContentView.swift:66–110`).
- **Confidence.** Medium-high.

### 12. MINOR: arrow keys do nothing while zoomed to 1:1
- **What I saw.** After Z, ←×5 kept the photo (correct) but panX stayed at 1107.1, so the picture did not pan (`r3-08`, states `z-zoomed`, `z-left`).
- **Correct.** AREAS area 7 journey 6: the arrows pan.
- **Status.** The confirmation `r4-04` did not run. This may belong to the zoom fixer.
- **Confidence.** Medium.

Also seen (minor):
- At the 72 pt filmstrip height the star badges are clipped, so 5★ reads as about 4 (`images/run3-filmstrip-72-stars-clipped.png`).
- After Select None the status still says "Selected 8 photos" (run 1 `lib-15`).
- Two fast ⌘-clicks on one cell move the cursor to another frame (run 1 `lib-15` `cmd2x2`).
- The Undo/Redo menu labels may lag behind the stack (low confidence; menu state is read without opening the menu).

## Taste calls (not defects)
- With a slider focused, Tab leaves the panels alone but moves focus to the next slider: Exposure → Contrast, so → nudged Contrast (`r3-12`).
- ⇧Tab restores the filmstrip only if it was on before, then reports "Panels partly hidden".
- D solo-opens Detail, and that collapse persists.

## Tested and working (run 3 unless noted)
- Loupe culling with auto-advance: each key advanced exactly one frame; - in the loupe is not purple; marks were intact after paging back 8 and forward 8 (`r3-03`).
- Rapid keys at 25/s: P×8 picked exactly 0–7; ←/→×8 exact; grid X×4 and 3×3 exact; no skips or doubles (`r3-04`).
- Auto-advance off: P toggles; a rating and a label do not clobber each other; ⇧P, ⇧3, ⇧X, ⇧6, ⇧0, ⇧U, ⇧- force an advance; - in the grid is purple (`r3-05`).
- Targets: ⌘A + 5 in the grid rated all 9 with no advance; in the loupe a key affects the active frame only; ⌘Z/⇧⌘Z step by step; Select Rejects, Select by Rating, Deselect Unpicked (`r3-06`).
- Undo ordering with a develop edit interleaved (run 1 `lib-16`).
- Library filter chords, ⌘L off/on with the criteria kept, ⌘\ (also with Lights dim and with ⇧Tab), the empty-filter view (`r3-11`).
- Search by filename, the sort-direction button, the Auto-advance switch; typing into the search field never culls (run 2 `r2-08`).
- Grid click, ⇧-click, ⌘-click, double ⌘-click (no loupe), double-click opens the exact frame, Invert Selection (run 1 `lib-15`).
- Filmstrip click grammar and height steps (`r3-02`).
- Thumbnail size: ]×3 = 232, clamps at 96 and 512, ⌘−/⌘= in the grid (`r3-14`).
- ⌘→ pages while zoomed and opens the next photo at fit; View › Next Photo; the - and = ladder returns to fit; ⌘← stops at 0; 10 fast E/G pairs (`r3-08`).
- EMBEDDED PREVIEW badge; orientation 6, 8 and 3 files upright everywhere; "Can't read XH2" shown while its neighbours still page (`r3-02`, `r3-08`).
- XMP `lumen:flag` and `xmp:Rating` written asynchronously (more than 0.7 s after the key) (`r3-03`, `r3-06`).
- ⌘1–⌘5 and rail clicks; the Masks door; D, R, R, M, Q; Escape layering; ⌃N/⌃P/⌃A/⌃E/⌃H inert (run 1 `lib-11`, run 2 `r2-11`).
- Tab, ⇧Tab, ⌥⌘S and F with the right status texts; column width clamps 320–520 and persists through workspace switches, Tab and relaunch; filmstrip visibility persists across relaunch (`r3-12`, `r3-13`).
- A fresh Develop opens with WB, Tone and Presence expanded (run 2 `r2-11`).
- ⌘/ and ? open the reference, and keys pressed under it do nothing (run 1 `lib-13`).
- ⌘K "kel" and "printer" land on the right section; X typed into the palette does not reject.
- With a slider focused, P still picks and ⌘→ still pages (`r3-12`).

## Could not test
- Run 4 (45758313436) was not finished at wind-down. It held:
  - Proof that the popover was open (finding 3).
  - The ⌘K focus trigger (finding 4).
  - Arrows while zoomed (finding 12).
  - Lights "out" with ⌘\ (my run 3 sequence skipped past "out").
  - Grid ↑/↓.
  - The filmstrip grid button.
- The driver cannot hold a key or send repeat events. Untested: real auto-repeat, holding P with auto-advance off, the Space-hold peek, the [ ] holds, Caps Lock.
- Popover and sheet contents cannot be screenshotted (the Sort menu, Filter chips, the reference body).
- Each scenario has its own photos and catalog, so these are untested: decisions surviving a quit and relaunch, ⌘O, drag-drop, relink, backup, catalog recovery, 2,000-file and empty folders.
- Sort by Rating, Flag or Sharpness; Metadata facets; a 1180×720 window; 4K.

## Driver and lane notes (not app findings)
- Preferences are NOT reset between scenarios: `run-suite.sh` runs `defaults delete` once per suite. Layout state leaks into the next scenario, which contradicts the README.
- The requests-branch driver did not build integration (run 45744732517). My base on `claude/loving-cray-d58nrb-test-library` carries integration's `LumenDriver.swift`.
- The `offset` on a drag step appeared to be ignored.
