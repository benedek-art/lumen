# Lumen Denoise (Mac app)

A native macOS 14+ batch front end for the raw-domain denoiser. Drop ARW (Sony A7 IV), RW2 (Panasonic GX85) or DNG files
or folders, press Denoise, and every photo goes through `python -m lumen_denoise.infer FILES --out DIR --strength S`.
The result is `<output>/<stem>-Denoised.dng`. You can compare the original and the result with a draggable before/after
split, and zoom to 100% on a Retina display. Strength follows the photo's ISO by default, using editable bands. Photos
that already have an up-to-date output are skipped. The queue is restored on the next launch. The status line shows
throughput and ETA, and you get a notification when a batch finishes in the background. Nothing is ever written to
`/Volumes/Offload Drive`, not even through a symlink. No dependencies: SwiftUI, AppKit, Core Image, ImageIO and
UserNotifications only.

The engine checkout defaults to `~/Projects/lumen-denoise`, with python at `<root>/.venv/bin/python`. To use another one,
set it in Settings › Engine, or set `LUMEN_DENOISE_ROOT=/path` and `LUMEN_PYTHON=/path/to/python` in the environment.

## Files

| File | What it holds |
| --- | --- |
| `Sources/LumenDenoise/Engine.swift` | Foundation only. Config (`Cfg`), the Offload Drive guard (`isForbiddenOutput`, `guardSelfTest`), file discovery, and the process runner `EngineRun`. The runner uses its own process group, a staging dir, blocking pipe readers, and cancel/kill. |
| `Sources/LumenDenoise/Core.swift` | Foundation only. Queue types, error translation, ISO bands, output naming, chunk planning, skip-done, throughput/ETA and queue persistence. |
| `Sources/LumenDenoise/Model.swift` | `@MainActor QueueModel`, which connects Core and Engine: batches, moving finished files into place, EXIF reads, notifications, dock badge and autotest. |
| `Sources/LumenDenoise/Preview.swift` | `RawRenderer` (`CIRAWFilter`, cached) and `BeforeAfterView` (split, 100% zoom, per-photo strength). |
| `Sources/LumenDenoise/LumenDenoiseApp.swift` | App, menu commands, main window, Settings, `--selftest` and `LUMEN_SNAPSHOT`. |
| `Tests/` | `EngineTests.swift`, `CoreTests.swift`, `main.swift`, `fake_engine/` (a fake `lumen_denoise.infer`) and `run_linux_tests.sh`. These are not part of the app target. |
| `DESIGN.md` | The design contract and the changes made after it. |
| `build.sh` | Release build, `.app` bundle, ad-hoc signature and `--selftest`. |

## Build and smoke test on the Mac

Run all commands from `Denoise/app/`. You need Xcode 16 or its command line tools; the CLT for Xcode 15 also works.

```bash
cd Denoise/app

# 1. Unit tests: Engine + Core against Tests/fake_engine (never the real model). Must exit 0 and end with "PASS core: all".
./Tests/run_linux_tests.sh

# 2. Release build -> dist/Lumen Denoise.app. Ends by running --selftest, and the script fails if the selftest fails.
./build.sh

# 3. Selftest on its own: the Offload Drive guard (including symlinks that dangle while the drive is unmounted) plus
#    Core checks. Prints PASS/FAIL lines and "SELFTEST PASS"; exit 0.
./dist/Lumen\ Denoise.app/Contents/MacOS/LumenDenoise --selftest

# 4. Normal launch.
open "dist/Lumen Denoise.app"
```

### Autotest (real engine, no clicking)

Run the binary directly, not with `open`, so that the environment variables reach it. Use a fresh output folder that is
not on the Offload Drive. The autotest never loads or saves the persisted queue or preferences. It writes
`<OUT>/autotest.json` and quits.

```bash
BIN="dist/Lumen Denoise.app/Contents/MacOS/LumenDenoise"
RAWS="/path/to/folder-with-6-or-more-raws"          # mix ISOs and both cameras if possible

# a) Full batch + preview PNG (before|after at fit on top, 800x800 centre crops at 100% below)
OUT=$(mktemp -d); LUMEN_AUTOTEST_FILES="$RAWS" LUMEN_AUTOTEST_OUT="$OUT" LUMEN_AUTOTEST_PREVIEW=/tmp/lumen-preview.png "$BIN"
cat "$OUT/autotest.json"; ls -la "$OUT"; open /tmp/lumen-preview.png

# b) Skip-already-done: the same command with the same $OUT again
LUMEN_AUTOTEST_FILES="$RAWS" LUMEN_AUTOTEST_OUT="$OUT" "$BIN"; cat "$OUT/autotest.json"

# c) Cancel after the first result (cleanup test)
OUT2=$(mktemp -d); LUMEN_AUTOTEST_FILES="$RAWS" LUMEN_AUTOTEST_OUT="$OUT2" LUMEN_AUTOTEST_CANCEL_AFTER=1 "$BIN"
cat "$OUT2/autotest.json"; ls -la "$OUT2"

# d) Cancel during model load / first photo (0 = cancel 3 s after the engine starts)
OUT3=$(mktemp -d); LUMEN_AUTOTEST_FILES="$RAWS" LUMEN_AUTOTEST_OUT="$OUT3" LUMEN_AUTOTEST_CANCEL_AFTER=0 "$BIN"
cat "$OUT3/autotest.json"; ls -la "$OUT3"

# e) Fixed strength (turns off the per-ISO defaults)
OUT4=$(mktemp -d); LUMEN_AUTOTEST_FILES="$RAWS" LUMEN_AUTOTEST_OUT="$OUT4" LUMEN_AUTOTEST_STRENGTH=0.8 "$BIN"

# f) Exposure-matched preview: at strength 0 the two halves should differ only in noise, not in brightness or tint
OUT5=$(mktemp -d); LUMEN_AUTOTEST_FILES="$RAWS/one.ARW" LUMEN_AUTOTEST_OUT="$OUT5" LUMEN_AUTOTEST_STRENGTH=0 \
  LUMEN_AUTOTEST_PREVIEW=/tmp/lumen-preview-s0.png "$BIN"

# g) Guard: none of these may create anything on the drive (run with the drive mounted AND unmounted)
ln -sfn "/Volumes/Offload Drive" /tmp/offload-link
LUMEN_AUTOTEST_FILES="$RAWS" LUMEN_AUTOTEST_OUT="/Volumes/Offload Drive/lumen-test" "$BIN"
LUMEN_AUTOTEST_FILES="$RAWS" LUMEN_AUTOTEST_OUT="/tmp/offload-link/lumen-test" "$BIN"
ls "/Volumes/Offload Drive/lumen-test" 2>&1     # must say: No such file or directory
```

What to check in `autotest.json`:

| Field | Expected |
| --- | --- |
| `staleStagingDirs` | `[]` in every run, cancel runs included (no `.lumen-staging-*` left behind). |
| `partialFilesOutsideStaging` | `[]` in every run, cancel runs included (no half-written `.dng`). |
| `alert` | `null` in a) to f). In g) the run refuses: the report is printed to stdout instead of written, and the alert names the Offload Drive. |
| `items[].status` | a) all `done`. b) all `skipped`. c) at least one `done`, the rest `cancelled`. d) all `cancelled`, or one `done` on a fast Mac. No item is ever left `working` or `queued`. |
| `items[].output` | Exists and opens in Lightroom, Preview or Finder Quick Look. Names are `<stem>-Denoised.dng`. A same-name photo from another card gets `<stem>-2-Denoised.dng`. |
| `items[].seconds`, `iso`, `strength` | Filled in for done items. `strength` follows the ISO bands (≤800: 0.55, ≤3200: 0.75, ≤12800: 0.9, above: 1.0) unless `LUMEN_AUTOTEST_STRENGTH` is set. |
| `items[].error` | `null` unless the status is `failed`; then it is a readable "Title: one-sentence fix". |
| `preview` | `true` when `LUMEN_AUTOTEST_PREVIEW` was set. |

Also check `xattr -p com.lumen.denoise.source "$OUT/<stem>-Denoised.dng"`: it prints the source path.

### Screenshots for the PR

`LUMEN_SNAPSHOT=/tmp/shot.png "$BIN"` writes the main window to a PNG after about 1.5 s and quits; it needs no
screen-recording permission. Take each screenshot in light and in dark mode (System Settings › Appearance):

1. The empty window: the drop zone (and the orange "Engine not found" row if you point Settings at a bad folder).
2. A queue of about 300 photos mid-batch: the progress bar, the status line "N of M · X photos/min · about Y left,
   finishes ≈HH:MM", the working spinner, done/skipped/failed rows and the dock badge.
3. A selected done photo in Fit with the split handle near the centre, showing the Before/After labels.
4. The same photo at 100% (⌘1), panned to fine detail such as hair or foliage in shadows.
5. A failed row with its red title and the one-line fix, plus the Copy Error context menu.
6. Settings: the ISO band editor, Batch toggles, Engine folder and the log.
7. The bottom bar with Auto by ISO on (band summary) and off (slider).
8. The "Cancel the batch and quit?" dialog, and the macOS notification "Batch finished".

## Manual verification checklist

Start with a normal launch (`open "dist/Lumen Denoise.app"`), Settings pointing at the real engine and an output
folder on the internal disk. ☐ = check it off.

Features

- ☐ **Drop and add.** Drag a folder with subfolders onto the window. All ARW/RW2/DNG files appear, sorted, with ISO and
  camera. Hidden files, `._*` files and `*-Denoised.dng` files are ignored. Dropping the same folder again gives the
  alert "Nothing added". ⌘O opens a panel that accepts both files and folders.
- ☐ **Per-ISO strength.** Rows show the strength picked for their ISO. Settings (⌘,): change a band, add a band and
  remove a band while its field is focused. The app must not crash and the rows update. Turn Auto by ISO off: the
  bottom bar shows the slider and every row follows it.
- ☐ **ETA and throughput.** During a batch the status line shows "loading model…" first, then photos/min, the time
  left and the finish time. Values settle after 2 or 3 photos and don't jump when a new chunk starts.
- ☐ **Skip already done.** Run the same folder twice. The second run marks every photo "Already done" within seconds.
  Re-process (context menu) still re-runs a photo. Turning off Settings › Skip re-runs everything.
- ☐ **Queue persistence.** Quit with done, failed and queued photos in the list, then relaunch. The same list and the
  same states come back. Delete one output DNG and relaunch: that photo is queued again. Unplug the card and relaunch:
  its queued photos show "Source missing".
- ☐ **Notification.** Start a batch of about 5 photos, switch to another app, and wait. A "Batch finished" notification
  arrives with "Denoised N photos · … · time", and the Dock icon bounces once. Allow notifications at the first prompt.
  With the app in front there is no notification. The dock badge counts the photos left and clears at the end.
- ☐ **Before/after preview.** Select a done photo. The split handle drags smoothly, the cursor becomes ↔ over it, and the
  labels say Before (left) and After (right). Hold Space to see the whole Before frame; \ toggles the split. Z or ⌘1
  zooms to 100%, ⌘0 returns to Fit, and double-clicking zooms on the clicked spot. Drag to pan. A pinch on the trackpad
  zooms in and out. While the queue list has focus, ↑/↓ still move through the photos, and Space, Z and \ still work.
- ☐ **100% on Retina.** On the built-in Retina display at 100%, one image pixel is one screen pixel. A 33 MP A7 IV frame
  is about 3.5 window-widths wide, and noise grain looks crisp, not soft. Do the same on an external non-Retina
  display if you have one; the image must be twice as large in points there.
- ☐ **Exposure match.** In the split view, brightness and white balance are identical on both sides; only the noise differs.
- ☐ **Per-photo strength.** In the preview's bottom bar, set 70% and press "Re-run this photo at 70%". Only that photo
  runs; the row shows "70% (custom)". The ↩ button next to the slider resets it to automatic.
- ☐ **Clear errors.** Point Settings at an empty folder and press Denoise. You get one alert, "Python environment not
  found" (or "Engine folder not found"), with the fix, and no retry storm. Add a damaged file (a renamed JPEG as .ARW):
  that photo fails with "Unsupported or damaged RAW file" and the others continue. Copy Error puts the title, fix,
  path and traceback on the clipboard.
- ☐ **Light/dark.** Switch appearance while the app runs. Bars, list, drop zone and log are all readable in both
  modes; status green, orange and red are visible; the split handle stays white over photos.
- ☐ **Keyboard.** Every shortcut in the table below works.

Bug fixes

- ☐ **Offload Drive guard.** Choose `/Volumes/Offload Drive` (with the drive mounted) as the output folder: it is
  refused with the alert "Can't write to the Offload Drive". Then make `ln -s "/Volumes/Offload Drive" ~/Desktop/off`
  and choose `~/Desktop/off`, and a folder inside it: both are refused. Unmount the drive and repeat with the dangling
  link: it is still refused. If macOS mounted the drive as "Offload Drive 1", that is refused too. The selftest covers
  the symlink cases.
- ☐ **Cancel leaves no partial files.** Start a batch of 10, press ⌘. in the middle of a photo, then run
  `ls -la "<output>"`. You see only complete `*-Denoised.dng` files and no `.lumen-staging-*`. Run
  `ls $TMPDIR | grep -i dng` (on macOS `$TMPDIR` is in `/var/folders/...`): nothing new. Cancelled rows say
  "Cancelled", and Denoise resumes them.
- ☐ **Quit mid-batch.** During a batch press ⌘Q. You are asked "Cancel the batch and quit?". "Keep Running" continues.
  "Cancel Batch and Quit" quits within about 3 s. `ps aux | grep lumen_denoise` and `ps aux | grep "DNG Converter"`
  show nothing left. On relaunch the interrupted photo is queued again and finished photos are kept.
- ☐ **Force quit mid-batch.** During a batch run `kill -9 <app pid>`. The python process exits by itself within about
  1 s, because it watches its parent. On relaunch, the stale staging dir is swept.
- ☐ **No exiftool error from Finder.** Launch from Finder or the Dock (not a shell) and denoise one ARW. There is no
  "exiftool not installed" error, because Homebrew paths are added to PATH.
- ☐ **Same file name from two cards.** Process `card1/DSC01234.ARW`, then a different `card2/DSC01234.ARW` into the same
  folder. The second one becomes `DSC01234-2-Denoised.dng`; the first one is untouched and is not "skipped".
- ☐ **Ejected output drive mid-batch.** Output on a USB stick: eject it (force-eject if needed) during a batch. You get
  one alert, "Stopped: output folder is gone", and no per-photo error flood. Choosing `/Volumes/<unplugged>/x` as the
  output gives "Output drive not connected", and nothing is created under `/Volumes`.
- ☐ **Retry and Re-process scope.** With 20 queued and 2 failed, Retry Failed (⇧⌘R) while idle runs only the 2.
- ☐ **Stdout buffering.** Results appear one by one as each photo finishes, not all at the end of a chunk.
- ☐ **Second instance.** Run a second copy from the terminal (`"$BIN" &`) on the same output folder while the first one
  is mid-batch. The first batch must not break: its staging dir is not swept by the second copy.

## Keyboard shortcuts

| Keys | Action |
| --- | --- |
| ⌘O | Add Files… (files or folders) |
| ⇧⌘O | Choose Output Folder… |
| ⌘R | Start Denoising |
| ⌘. | Cancel the batch |
| ⇧⌘R | Retry Failed |
| ⇧⌘K | Clear Finished |
| ⌥⌘R | Reveal the selected photo's output (or the output folder) in Finder |
| ⌥⌘L | Show Log |
| ⌘, | Settings (ISO bands, skip/notify, engine folder, log) |
| ⌘1 / ⌘0 | Preview: 100% / Fit |
| Z | Preview: toggle Fit / 100% (preview or queue list focused) |
| Space (hold) | Preview: show Before full frame |
| \ | Preview: toggle split / After only |
| Double-click image | Toggle 100%, centred on the click |
| Pinch | Zoom in / out |
| ↑ / ↓ | Previous / next photo in the queue |
| ⌫ | Remove selected photos (queue list focused; not the one in progress) |
| Return / double-click row | Open the denoised DNG, or reveal the original if there is none |
| Esc | Close the log sheet |

"Re-process Selected" and "Clear All" are in the Denoise menu and have no shortcut. ⌘⌫ was dropped on purpose,
because it would also fire while you edit a text field.

## If the build fails

The cloud sessions that wrote this code could not build macOS targets. `Engine.swift` and `Core.swift` were compiled
and tested on Linux. The three UI files were checked with `swiftc -parse` and by reading them against the macOS 14
SDK. These are the most likely compile problems; line numbers are as of this PR:

| Where | Risk and fix |
| --- | --- |
| `Model.swift:605`, `:609` | `rename`, `strerror`, `errno` and `setxattr` come from Darwin through Foundation. If one is "not in scope", add `import Darwin` at the top of the file. |
| `Model.swift:891` | `kCGImagePropertyExifSubsecTimeOriginal`. If it is missing, use `"SubsecTimeOriginal"` as the key. |
| `Model.swift:387` | `URLResourceValues.isVolume` via `.isVolumeKey`. |
| `Model.swift:355` | `Task.detached` returning `[(String, Bool)]`. This compiled on Linux in Swift 5 and 6 modes. If Sendable checking complains, map to a small `struct: Sendable`. |
| `Model.swift:473-475`, `:794` | `MainActor.assumeIsolated` inside engine and preview callbacks. Valid on macOS 14; it traps at runtime if a callback arrives off the main queue, which would be an Engine bug. |
| `Preview.swift:82-84` | `CIRAWFilter.baselineExposure`, `neutralTemperature` and `neutralTint` setters (macOS 12+ API). If the compiler rejects them, delete those three lines; the preview then loses only the exposure match. |
| `Preview.swift:285`, `:358` | `.coordinateSpace(.named(...))` and `DragGesture(coordinateSpace: .named(...))` with the macOS 14 `NamedCoordinateSpace`. If the call is ambiguous, write `.coordinateSpace(name: "lumenPreviewPane")` and `coordinateSpace: CoordinateSpace.named("lumenPreviewPane")`. |
| `Preview.swift:176`, `LumenDenoiseApp.swift:253` | `onKeyPress(keys:phases:action:)` with string-literal `KeyEquivalent`s (macOS 14). |
| `Preview.swift:301` | `MagnifyGesture` and `Value.startLocation` (macOS 14). If `startLocation` is missing, pass `nil` instead. |
| `Preview.swift:50` | `withCheckedContinuation` returning a tuple with a non-Sendable `CGImage` inside an `@unchecked Sendable` struct. At most a warning. |
| `LumenDenoiseApp.swift:353` | `let s: Double? = switch …` is a Swift 5.9 switch expression with mixed `Double` and `Double?` branches. If it is rejected, write `item.usedStrength ?? strength as Double?` on the `.done` branch, or use a plain `switch` with assignments. |
| `LumenDenoiseApp.swift:378` | `some ShapeStyle` parameter called with `.secondary`, `.green`, `.red` or `.orange`. If that is ambiguous, pass `Color.secondary` and so on. |
| `LumenDenoiseApp.swift:257` | Two-parameter `onChange(of:)` (macOS 14) on an optional UUID. |
| `LumenDenoiseApp.swift:698` | `NSApp` used inside `DispatchQueue.main.asyncAfter`. This is unchanged from v0.1, which built; Swift 6 language mode would need `MainActor.assumeIsolated`. |
| `Core.swift:252` | Darwin `getxattr(path, name, value, size, position, options)` with 6 arguments. The Linux branch is the one that was tested. |

General tips: `swift build 2>&1 | grep -E "error|warning: .*will be an error"` gives the short list. Warnings about
Sendable or main-actor isolation are expected in Swift 5 mode and are harmless. Run `swift build` (debug) before
`./build.sh` for faster turnaround.

If the app builds but misbehaves:

- **The selftest fails.** Look for the `FAIL guard …` line. A path under `/Volumes` that you expected to be allowed may
  be on a volume named "Offload Drive".
- **No notification.** Check System Settings › Notifications › Lumen Denoise. The ad-hoc signature changes on every
  build, so macOS may ask again.
- **Space, Z or \ do nothing in the list.** Click the image once, which focuses the preview, and report it. The list's
  key forwarding is the part that could not be checked on Linux.
