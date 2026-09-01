# W2 — L · State, history & app integrity

**Area:** undo correctness, publication discipline, force-unwraps / main-thread blocking,
the L0 extension split's feasibility, updater safety.

**Files read in full (my sections):**
`Sources/LumenApp/AppState.swift` (structure, publication, editing, undo, gestures —
not the library/mask/album sections other areas own),
`Sources/LumenApp/HistoryStack.swift`, `Sources/LumenCore/Interaction/HistoryCoalescing.swift`,
`Sources/LumenApp/EditRevision.swift`, `Sources/LumenApp/CommandState.swift`,
`Sources/LumenApp/AppUpdater.swift` (frozen — findings only).

**Read for evidence, not owned:** `LumenControls.swift` (`LumenColorWheel` only),
`LookPanel.swift` / `MaskPanel.swift` / `CurveEditorView.swift` / `CropPanel.swift`
(coalescing-key call sites only), `LoupeView.swift` (`setZoom` / pinch only),
`Tests/LumenAppTests/DragBroadcastTests.swift`,
`Tests/LumenCoreTests/HistoryCoalescingTests.swift`, `.github/workflows/ci.yml`.

**Spec:** docs/13 §concurrency, docs/23 §diagnosis, docs/31 perf, docs/audit-2026-09/PLAN.md
§"Decisions already taken" + §W5, docs/00-vision, docs/20-proof-standard.

**Two negative results, stated because the brief asks for them:** there is **no force-unwrap
of any kind** in `AppState.swift`, `HistoryStack.swift`, `CommandState.swift`,
`EditRevision.swift` or `HistoryCoalescing.swift` (`grep -E "try!|as!|\)!|\]!"` — empty), and
**no main-actor blocking** in any of them (no `waitUntilExit`, `DispatchSemaphore`,
`DispatchQueue.sync`, `Thread.sleep`, or synchronous `contentsOf:`). The single force-unwrap
in my file list is `AppUpdater.swift:108` — `URL(string:)!` on a compile-time literal, which
is safe. Every main-thread block I own is in `AppUpdater` and is K-034.

---

## Known-open dispositions

**K-030 — `zoomLevel` publishes per pinch/scrub: STILL-OPEN, and worse than the row says.**
`AppState.swift:1577` — `@Published var zoomLevel: Double = 0`, no `didSet`, no guard.
`LoupeView.swift:130` — `state.zoomLevel = clamped`, written **unconditionally**, from
`LoupeViewport.setZoom`, which is the single funnel for every zoom source: the pinch
(`LoupeView.swift:1978`, once per `MagnifyGesture.onChanged`) and the scrubby zoom
(`LoupeView.swift:1936`, once per `DragGesture.onChanged`). Each write is a full
`AppState.objectWillChange` → the window and `LumenApp`'s `Scene` (seven `.commands` menus).
New sub-fact for triage: there is not even an equality guard, so a pinch event whose
`ZoomLadder.clamp` result equals the current value still publishes — the exact failure
`CommandState.refresh` (`CommandState.swift:390-394`) was written to avoid, on the property
next to it. Contrast `sliderGestureActive` (`AppState.swift:3180`), which is deliberately
unpublished for this reason and documents it.

**K-034 — `AppUpdater` blocks main; failure message may be wrong: STILL-OPEN, both halves.**
`AppUpdater.swift:262-272` — `run()` calls `process.waitUntilExit()`, and the enclosing
`final class AppUpdater` is `@MainActor` (`:102`), so the wait is on the main actor. Two
callers: `ditto -x -k` over the whole `Lumen.app.zip` (`:219`) and
`codesign --verify --deep --strict` (`:224`), which walks every nested binary in the bundle.
Neither is bounded. The message half is real and specific — see L-04.

**K-038 — coalescing keys shared between distinct decisions: STILL-OPEN.**
Curve points: `CurveEditorView.swift:556` — `editCurve(keyPrefix + channel.rawValue)`, the key
carries the channel and **no point index**, so dragging point A, releasing, and dragging point B
on the same channel inside 1.2 s folds both into one step. Crop/geometry:
`CropPanel.swift:219` `"geometry.reset"` and `:189` `"geometry.revert"` are one key each, so two
consecutive resets are one step; `LoupeView.swift:2287` uses the single key `"crop"` for every
crop change. Mask group rename is correctly per-id (`MaskPanel.swift:630`), and the mixer arcs
are correctly per-band-per-handle (`ColorPanel.swift:222`) — the row is not universal, but the
curve and geometry cases stand.

**K-102 (cross-cutting, FYI) — CHANGED, not still-open as worded.** `ci.yml:83-92`, job
`test-fast` on `macos-15`, runs `swift test --skip ControlProofTests` with **no target filter**,
so `LumenAppTests` does execute on every push. What is absent is a *named* lane: nothing in the
log distinguishes "LumenAppTests ran and passed" from "LumenAppTests built to zero tests", which
is the failure mode the common brief's first lesson is about. Re-word the row rather than close it.

**K-014, K-058, K-073** — not touched; no disposition.

---

## Findings

### L-01 — a grading-wheel drag is two undo steps per mouse event, and 3.4 s of it evicts the session's history
severity: S1
confidence: traced
class: defect
size: M

evidence: `LumenControls.swift:1597-1599`, inside one `DragGesture.onChanged`:

```swift
hue = (atan2(Double(dy), Double(dx)) * 180 / .pi + 360)
    .truncatingRemainder(dividingBy: 360)
sat = Double(r)
```

`hue` and `sat` are two `Binding<Double>`s built by two separate calls to
`LookPanel.swift:1155-1168` `bindWheel(...)`, whose setters are
`state.updateRecipe(coalescingKey: "wheel.\(title).hue")` and
`…"wheel.\(title).sat"` (`LookPanel.swift:539-541`). So **one mouse event makes two
`history.record` calls with two different keys.** `HistoryStack.record`
(`HistoryStack.swift:124-132`) compares the incoming key against
`steps[position - 1].coalescingKey`, and `HistoryCoalescing.shouldCoalesce`
(`HistoryCoalescing.swift:243`) returns false on the first line when they differ:

```swift
guard let key, let openKey, key == openKey else { return false }
```

The open step's key alternates `…hue`, `…sat`, `…hue`, … so it **never** equals the incoming
key. Traced call count per `onChanged`: 2 `record`, 0 coalesces, 2 appended steps. Same shape on
the mask panel's wheels (`MaskPanel.swift:2380`, `key + ".hue"` / `key + ".sat"`).

The eviction is `HistoryStack.swift:160-162`:

```swift
if steps.count > Self.limit { steps.removeFirst(steps.count - Self.limit) }
```

with `static let limit = 400` (`:47`). At 2 steps per event and a SwiftUI drag delivering ~60
events/s, the ring fills in **400 / 120 ≈ 3.4 seconds** of continuous puck movement, after which
every earlier step in the session — the crop, the white balance, the mask that was built ten
minutes ago — is removed from the front of `steps` and can never be undone back to.

how the owner sees it: he pushes the shadows puck around for a few seconds, then presses ⌘Z. The
picture moves by a hair. He presses it again: another hair. He holds ⌘Z down, and instead of
arriving at where the grade started he arrives at where he was *before* the drag's first three
seconds — everything older than that is simply gone from the Edit menu, including work from
earlier in the session that had nothing to do with the wheel.

fix: **What makes a gesture one step is the gesture, not the control.** The app already knows
exactly when one is in flight and does not tell history. `AppState.sliderGesture(active:)`
(`AppState.swift:3273-3290`) latches `sliderGestureActive` at the first movement of any slider or
wheel and unlatches at release, with two independent safety nets already wired: the photo switch
(`AppState.swift:551`, inside `primarySelection.didSet`) and the 8 s silence watchdog
(`AppState.swift:3295-3313`). That latch is consulted by persistence (`AppState.swift:3132`) and
by the loupe's settle (`LoupeView.swift:1258, 1349`) and by **nothing in the history path** — the
A2 claim "never consulted" is too strong, but "never consulted by the undo boundary", which is
what matters here, is exactly right.

*Where the boundary belongs.* Add a monotonic **gesture epoch** to `AppState`: bump it inside
`sliderGesture(active: true)` at the moment the latch actually closes (`AppState.swift:3276-3278`),
and pass `sliderGestureActive ? gestureEpoch : nil` into `history.record` as a fourth coalescing
input. Extend `HistoryCoalescing.shouldCoalesce` with `openEpoch: Int?, epoch: Int?` and put the
new clause **first**:

- both epochs non-nil and equal **and** `urls == openURLs` → coalesce, *regardless of key and
  regardless of the 1.2 s window*. A long, careful drag is still one step; an abandoned one is
  closed by the watchdog that already exists.
- otherwise fall through to today's rule unchanged: `key == openKey && urls == openURLs &&
  sinceLastEdit < window`.

Keep the photo-set equality condition exactly as it is — it is what makes the step an identity
(`HistoryCoalescing.swift:232-238`), and the photo switch unlatches the gesture anyway, so the
two rules agree rather than compete. Keep the key as the fallback identity for *keyed non-gesture*
edits (arrow-key nudges, ± steppers, menu items), which is where the 1.2 s window's own comment
says it belongs ("nudge, think, nudge again", `HistoryStack.swift:49-51`). This is orthogonal to
K-038: per-point curve keys and per-preset WB keys are still needed for the keyboard path.

Files: `Sources/LumenCore/Interaction/HistoryCoalescing.swift` (the rule),
`Sources/LumenApp/HistoryStack.swift` (`record`'s signature and the `Step`'s stored epoch),
`Sources/LumenApp/AppState.swift` (`gestureEpoch`, the bump in `sliderGesture`, the argument at
`:3130`). No view file changes — every call site already routes through `updateRecipe`.

*The tests, substitution-proof (revert the epoch clause and all three go red):*
1. `HistoryCoalescingTests.testTwoControlsInsideOneGestureAreOneStep` — assert **true** for
   `openKey: "wheel.Shadows.sat"`, `key: "wheel.Shadows.hue"`, `urls == openURLs`,
   `openEpoch: 7, epoch: 7, sinceLastEdit: 0.008`; **false** for the same call with `epoch: 8`;
   **false** for the same call with a different `urls` at the same epoch.
2. `DragBroadcastTests.testAWheelDragIsOneUndoStep` — the existing counting lane: 48 iterations of
   `record(key: "wheel.Shadows.hue")` followed by `record(key: "wheel.Shadows.sat")` inside one
   epoch; assert `history.steps.count == 1`. Today that fixture produces **96**.
3. `DragBroadcastTests.testALongDragDoesNotEvictEarlierHistory` — record 5 distinct keyed steps,
   then run a 400-event two-key wheel drag in one epoch, assert `steps.count == 6` and that six
   `undo()` calls return the first step's `before`. Under the defect the first five are gone.

---

### L-02 — the coalescing suite is green under L-01 because every fixture drives one key
severity: S2
confidence: measured
class: defect
size: S

evidence: `Tests/LumenAppTests/DragBroadcastTests.swift:75-84` —
`for event in 0..<48 { history.record(…, coalescingKey: "tone.exposure") }`, then
`XCTAssertEqual(history.steps.count, 1, "the fixture must actually be one coalesced drag")`.
`Tests/LumenCoreTests/HistoryCoalescingTests.swift:15-61` — six cases, every one with a single
control name on both sides. Neither file, and no other test in the repository, ever calls
`record` or `shouldCoalesce` twice with two different keys inside one gesture. The suite's own
comment claims the general property — "A drag is 48 mouse events and ONE undo step"
(`DragBroadcastTests.swift:46`) — which is true only for the one-property controls it fixtures.

how the owner sees it: nothing, which is the problem. The lane is green today, was green through
every wheel drag he has ever made, and would stay green if the fix were reverted.

fix: the two `DragBroadcastTests` cases in L-01 fix item 2 and 3, plus the pure-rule case in item
1. They are cheap (no rendering, no catalog) and land in lanes that already run.

---

### L-03 — the updater verifies that the downloaded bundle is *signed*, never *whose* signature it is
severity: S2
confidence: traced
class: defect
size: S

evidence: `AppUpdater.swift:224` — `try run("/usr/bin/codesign", "--verify", "--deep", "--strict", newApp.path)`.
There is no `-R`/`--requirement`, no team-identifier check, and no anchor. `codesign --verify`
answers "is this bundle's signature internally consistent with its contents" — an **ad-hoc**
signature passes it. The only other check on the payload is `AppUpdater.swift:210`,
`(attrs[.size] as? Int) == asset.size`, i.e. a byte count taken from the same JSON that supplied
the URL. Nothing hashes the asset. The bundle is then moved over the running app
(`:228-230`) and relaunched (`:245-247`). Note also that the project's own denoise-model plan
decided the opposite for a far less privileged payload: "Download on first use from a release
asset, **hash-verified**" (PLAN.md:95).

how the owner sees it: nothing, until the day the release feed serves something other than what CI
built — at which point the app replaces itself with it and relaunches, with no dialog that could
have caught it.

fix: `AppUpdater.swift` is lead-only/frozen, so this is a finding, not a patch. When it is opened:
pin the signature with `codesign --verify --deep --strict -R "anchor apple generic and
certificate leaf[subject.OU] = <team>"` (or, for the ad-hoc dev-latest lane, a `--verify` against
the *running* app's own designated requirement via `codesign -d -r-`), and publish a SHA-256 in
the release body beside the existing `commit:` line — `UpdateDecision.commit(inReleaseBody:)`
(`:50-60`) is already the tested parser for that body and takes a second key with three lines.
Test: `UpdateDecisionTests` gains `testADigestLineIsParsedAndAMissingOneIsRefused`, red when the
digest clause is removed.

---

### L-04 — the "your build is untouched" alert is shown on the one path where the build is gone
severity: S2
confidence: traced
class: defect
size: S

evidence: `AppUpdater.swift:226-235`:

```swift
let current = Bundle.main.bundleURL
let backup = work.appendingPathComponent("Lumen-previous.app")
try FileManager.default.moveItem(at: current, to: backup)
do { try FileManager.default.moveItem(at: newApp, to: current) }
catch {
    try? FileManager.default.moveItem(at: backup, to: current)   // <- `try?`
    throw error
}
```

and the handler it throws into, `:249-253`:

```swift
inform("The update didn't install",
       "\(error.localizedDescription)\n\nThe running build is untouched; …")
```

The rollback is `try?`. If it fails — and it can, because `backup` is inside
`FileManager.default.temporaryDirectory` (`:214`) while `current` is wherever the app is
installed, so both moves are cross-volume whenever `/Applications` and the temp dir differ — the
installed `Lumen.app` has been moved away, nothing has replaced it, and the alert asserts the
opposite. The suggested recovery ("git pull + scripts/build-app.sh") is also the wrong advice for
that state.

how the owner sees it: an alert saying the running build is untouched, then a Finder with no
Lumen in it after he quits.

fix: capture the rollback's own result and branch the message — one string when the old bundle is
back (today's wording), a different one naming `backup`'s path and telling him to move it back
when it is not. Copy the new bundle rather than moving the old one out first (`copyItem` into a
sibling, then an atomic `replaceItemAt`), which removes the window entirely. Test:
`UpdateDecisionTests` cannot reach this; extract the swap into a pure
`UpdateSwap.plan(current:staged:backup:)` returning the ordered file operations, and assert that
the failure plan's message names the backup path — red when the two branches are collapsed back
into one.

---

### L-05 — `HistoryStack`'s snapshots are built and unwired
severity: S3
confidence: measured
class: defect
size: S

evidence: `HistoryStack.swift:193-210` declares `struct Snapshot`, `@Published var snapshots`,
`func snapshot(_:named:)` and `func removeSnapshot(_:)`.
`grep -rn "\.snapshot(\|snapshots\|removeSnapshot" Sources Tests` returns **exactly one** hit
outside that file, and it is a comment: `CatalogService.swift:551`, "…can honestly promise until
snapshots ship." No view, no menu item, no test, no `AppState` member reaches any of the four.
`@Published var snapshots` is therefore a published property on the object whose whole header is
an argument about not publishing during a drag — it costs nothing today only because nobody
writes it.

how the owner sees it: nothing. It is the second lesson of the common brief in miniature — the
comment in `CatalogService` reads as though snapshots are a pending feature, and the code that
would have been that feature is already here with no call site.

fix: either wire it (a "Snapshot" item in the Edit menu writing through `AppState`, plus
persistence — snapshots that die with the process are worse than none) or delete all four members
and correct `CatalogService.swift:551`. Deleting is the honest default under docs/00's law about
controls that do nothing. Test: the surface tripwire — add the four names to
`scripts/check-swift-surface.py`'s unreferenced-member pass if it has one; otherwise deletion is
its own proof, since `swift build` stays green.

---

### L-06 — `setZoom` publishes `zoomLevel` even when the value did not change
severity: S3
confidence: traced
class: defect
size: S

evidence: `LoupeView.swift:126-130`:

```swift
let clamped: Double = ZoomLadder.clamp(ratio)
if ZoomLadder.isFit(clamped) { pan = .zero }
state.zoomLevel = clamped
```

`@Published` performs no equality check (`CommandState.swift:384-386` states this as the reason
its own setters are guarded). Every pinch event whose clamped result equals the current value —
which is every event at the top and bottom of the ladder, and every event of a pinch held still —
publishes `AppState` and rebuilds the window and the `Scene`. This is a strict subset of K-030 and
is separately worth fixing because it is one line and does not require moving `zoomLevel` off
`AppState`.

how the owner sees it: pinching against the ladder's end, or resting two fingers on the trackpad
mid-pinch, costs the same whole-window pass as pinching.

fix: `guard state.zoomLevel != clamped else { return }` before the write in
`LoupeViewport.setZoom` (after the `lastCursor`/`anchorNextZoomAtCursor` bookkeeping, which must
still happen). Test: `DragBroadcastTests.testAPinchThatDoesNotMoveTheZoomIsSilent` — sink
`AppState.objectWillChange`, call `setZoom(1.0, …)` twice, assert one publish; red when the guard
is removed.

---

### L-07 — dropping the `AppState.swift` extension split was right; here is the evidence, so it does not come back
severity: S2
confidence: measured
class: proposal(taste)
size: L

Fits the decided direction "Find first, fix second" and PLAN.md's serialized-landing mechanic;
it argues about `AppState.swift` only — the other six files in the L0 list are outside my area.

evidence, in three parts.

**(a) The half that cannot move is the half that couples the streams.** Swift forbids stored
properties in extensions. `AppState.swift` holds **73** `@Published` declarations and ~100 stored
members, **13** of them with `didSet` bodies; every one stays in `AppState.swift` no matter how the
methods are dealt out. And the `didSet` bodies are precisely the cross-area wiring. One property,
`primarySelection` (`AppState.swift:545-567`), calls into four of the five proposed destinations in
eleven lines:

```
sliderGesture(active: false)        // L, remainder
refreshPrimaryFrameSize()           // → AppState+MaskOverlay (F2)
refreshPrimaryAsShotNeutral()       // → AppState+MaskOverlay (F2)
refreshPrimaryLibraryDetail()       // → AppState+Library (J)
ensureMaskMattes()                  // → AppState+MaskOverlay (F2)
refreshCommandState()               // L, remainder
```

`filter`, `sortOrder` and `sortAscending` (`:517-541`) are the same shape into `+Library`. So the
lines four streams must edit are all in the file the split exists to make disjoint, and the split
does not make it disjoint.

**(b) `private` is file-scoped, so seven members widen — and every one crosses a *stream*
boundary, not merely a file one.**

| member | declared | reached from | crosses |
|---|---|---|---|
| `cancelMaskOverlayTimers()` | `AppState.swift:1274` | `:2654`, in `cursorDidChange` (Selection → +Library) | F2 ↔ J |
| `maskOverlayPersistentID` | `:1141` | `:2653`, same function | F2 ↔ J |
| `maskOverlayResumeID` | `:1272` | `:2650`, same function | F2 ↔ J |
| `refreshPrimaryFrameSize()` | `:1324` | `:557`, `primarySelection.didSet` (remainder) | F2 ↔ L |
| `refreshPrimaryAsShotNeutral()` | `:1351` | `:558`, same `didSet` | F2 ↔ L |
| `restore(_:to:)` | `:2801` (Culling → +Library) | `:3396`, in `apply(_:)` (undo → +Editing) | J ↔ L |
| `saveSourceState()` | `:1976` (per-source state → +Library) | `:531`, `:539` (`didSet`, remainder) and `:3363` (`prepareToQuit`, remainder) | J ↔ L |

**(c) The actual risk is not the widening — it is what the widening removes, and when.** Three of
the seven (`maskOverlayPersistentID`, `maskOverlayResumeID`, `cancelMaskOverlayTimers`) are the
mask-overlay suppression mechanism whose own comment is `AppState.swift:1162`: "SUPPRESSION IS
AUTHORITATIVE NOW. `maskOverlaySuppressed` existed, was set on … and was not consulted." `private`
is the only thing that currently forces every writer of that state to sit in one file where the
next reader can see them. Making it internal and then handing the two halves to F2 and J as
branches in separate worktrees that never see each other is a reasonable description of how it
became unconsulted the first time. A second cost: **L keeps both `AppState` remainder and
`AppState+Editing`**, so the split does not even separate the two files one stream owns — the
`gestureEpoch` change in L-01 above touches `sliderGesture` (remainder) and `updateRecipe`
(+Editing) and would straddle it.

And the split is unverifiable here. LumenApp cannot be compiled in this environment
(PLAN.md:22-23); `scripts/check-swift-surface.py` is the only local feedback, and K-014 records
that it cannot even see protocol conformance. A duplicate symbol, a missing `#if os(macOS)`, or a
flat-directory tripwire violation (`KeyGrammarTests:33` / `WorkspaceEntryTests:42` scan
`Sources/LumenApp/` non-recursively) surfaces only on CI `build-macos` — and L0 is merge-order
step 1, the SHA all sixteen worktrees branch from. A red L0 stalls every stream at once, for a
refactor that buys none of them file-disjointness.

fix (what to do instead): keep `AppState.swift` whole. Make the streams disjoint by **section**,
using the existing `// MARK:` blocks as the ownership contract — they already partition the file
cleanly (`:511` Library, `:908`/`:973` overlay + thumbnails, `:1465` Editor, `:2576` Selection,
`:2715` Culling, `:2840` Recipes, `:3164` Slider gestures, `:3417` Copy/paste, `:3493` Saved
looks) — and give F2's overlay block, J's library block and L's recipe/gesture block **one shared
merge slot in the serialized order** rather than three parallel worktrees. That costs one
serialization edge in a plan that is already serialized at the push level, and it costs zero
compile risk on the landing every other stream depends on. Test: none needed — the proof is that
`AppState.swift`'s diff stays reviewable in one place, which is the property the split was trading
away.

---

## Not found (stated so the next auditor does not re-spend it)
- No force-unwrap and no main-actor blocking anywhere in the five non-updater files (greps above).
- `HistoryStack.record`'s coalescing branch cannot resurrect a stale redo tail: `undo()` and
  `redo()` both set `lastEditTime = .distantPast` (`HistoryStack.swift:170, 178`), so the first
  edit after an undo always takes the `atomically` path that truncates at `:153-155`. The
  `atomically` invariant (`:99-104`) holds at all four mutation sites.
- `apply(_:)` (`AppState.swift:3385`) does not itself call `refreshCommandState()`, and does not
  need to: `history.undo()`/`redo()` move `position`, whose `didSet` (`HistoryStack.swift:54`)
  fires `onChange`, which `AppState.init` (`:1657`) binds to `refreshCommandState`.
