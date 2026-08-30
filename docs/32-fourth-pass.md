# 32 — The fourth pass: the owner's full walkthrough, planned

This document is written to be read COLD, by a session with no memory of how it came to
exist. It is the complete plan for the owner's fourth round of feedback — his first full
walkthrough of every workspace — and it contains everything the executing session needs:
the ground rules that keep CI green, the streams with file ownership for parallel agents,
and the acceptance criteria per item.

**Base:** branch `claude/photo-editor-design-plan-8ahzmm`, at or after `538eb08`.
**Context documents:** `docs/31-defect-audit.md` (two audit rounds: ~29 defects fixed,
~35 recorded and ranked — several now land in these streams), `docs/30-ui-rebuild.md`
(the rebuild history, §7 records what each review changed), `docs/24-*` (slider dossiers,
the source for help text).

The owner's verdict, so the tone is understood: *"Overall, very, very good… I feel like
it's getting really close. There are definitely still issues that I would fix."* This
pass is convergence, not rebuild. Do not redesign what he called good.

---

## 0. GROUND RULES FOR THE EXECUTING SESSION — read before any edit

These are paid-for lessons. Every one of them cost a red CI run or worse this week.

1. **Git.** Develop, commit and push ONLY on `claude/photo-editor-design-plan-8ahzmm`.
   `git push -u origin <branch>`, retry up to 4 times with 2s/4s/8s/16s backoff on
   network failure. No PRs unless the owner asks. Never rewrite pushed history. Commit
   messages end with the `Co-Authored-By:` and `Claude-Session:` trailers and NEVER name
   a model.
2. **The sandbox lies.** This container has been re-provisioned from stale snapshots
   twice. Before anything: `git fetch origin` and confirm the local head IS the remote
   head. If the local tree is behind or dirty with work you do not recognise, do not
   touch it — make a worktree from `origin/<branch>` and work there.
3. **Swift is not on PATH.** `/opt/swift/usr/bin/swift`, `/opt/swift/usr/bin/swiftc`.
4. **`Sources/LumenApp` and `Sources/LumenPipeline` type-check ONLY on the macOS CI
   lanes** (`build-macos`, `test-fast`, `gpu-parity`, `app-bundle`). Locally you get
   syntax parsing only. Two compile errors shipped this way in one day:
   - `var rendered = rendered` (same-scope shadowing — illegal for a `let`).
   - `help:` passed before `step:` in a `LumenSlider` call — **Swift enforces argument
     order**, and `LumenSlider`'s order is
     `title, value, range, hardRange, scale, defaultValue, step, decimals, bipolar,
     trackStops, wand, …, help, onEditingChanged, onReset`. `help` comes LATE. Check
     every call you touch against the declaration.
   - **`scripts/check-swift-surface.py` does NOT catch the argument-order case** when an
     argument is a multi-line ternary — verified false negative, recorded in docs/31's
     postscript. Do not treat its green as proof of arg order.
5. **After every push: WAIT for CI and look.** All five lanes plus `gpu-parity`. Do not
   report progress to the owner, and do not stack further pushes, while a lane is red.
   The rolling dev build (`app-bundle` → `dev-latest`) is what the owner installs, so a
   red push blocks his testing.
6. **Verification triad before any push:**
   `/opt/swift/usr/bin/swiftc -parse -swift-version 5 $(find Sources -name '*.swift')`,
   `python3 scripts/check-swift-surface.py`,
   `/opt/swift/usr/bin/swift test --skip ControlProofTests` (~10 min, 999 green at base).
7. **Text-scan tripwires that WILL fire on honest work:**
   - `KeyGrammarTests` reads `Keymap.swift` and `.keyboardShortcut(` call sites as TEXT.
     Every `case "x":` in the dispatcher is a declared binding; a normalisation must be
     a ternary, not a `switch`. Chord changes mean editing `KeyGrammar` + call sites in
     one commit.
   - `WorkspaceEntryTests` forbids calling `PanelLayout.select/reveal/expose` outside
     `PanelLayout.swift`/`WorkspaceEntry.swift`. Navigation goes through
     `AppState.enter`/`jump`.
   - `WorkspaceTests` parses a markdown table in docs/28; changing workspace/section
     structure means updating that table.
   - SwiftUI builders cap at 10 children; the error says `'buildExpression' is
     unavailable` and never mentions arity. The View menu's first inner Group sits AT 10.
8. **`PanelLayoutBroadcastTests` counts publishes.** Hover state never reaches an
   `ObservableObject`; a 48-event drag must cost `PanelLayout` zero publishes.
9. **House defect.** This repo has shipped "built but unwired" at least ten times. When
   you add a control, trace it to the render stage; when you add a key, prove the view
   holding it is in the hierarchy (a `.keyboardShortcut` on an unbuilt view silently
   never registers — that was ⇧⌘G).
10. **Parallel agents:** disjoint file ownership per stream, exactly as listed below.
    Agents never run git commands; the lead commits per stream after running the triad.

---

## 1. ANSWERS ALREADY GIVEN — decisions the owner has made, do not relitigate

- **Navigation becomes a vertical rail** (his ask: *"I'd rather have a vertical area on
  the side of the page like Lightroom has it, the right side of the page"*). The
  horizontal strip and the `WorkspaceReturnBar` both go.
- **The Simple/Full register dies** (*"I don't know why we have show fewer sections.
  That's kind of unnecessary, as well as the one hidden section active"*). Always Full.
- **Crop auto-saves** — Done/Revert buttons go; Reset/Escape remain the way back.
- **The on-image crop hint goes** entirely.
- **Tooltips on everything**: every slider name's long-hover explains what it does and
  when to use it, quickly. Many have it; ~30 rows still say only "double-click to reset".
- **Hover/press fills come OFF non-premium surfaces**: band swatches, container rows,
  section-ish labels that are not clickable. (Slider rows already lost theirs in pass 3.)

---

## 2. THE STREAMS

Run A–D as parallel agents (disjoint files). E and F are engine/pipeline work the lead
should sequence after A–D land, or run as a second wave — they carry the highest
regression risk and need the full suite plus gpu-parity between each.

### Stream A — Navigation: the vertical workspace rail
**Owns:** `ContentView.swift`, `DevelopPanel.swift`, `DevelopColumn.swift` (switcher
parts), `Workspace.swift` + `WorkspaceLayout` (register removal), `PanelLayout.swift`,
`WorkspaceTests`/`PanelLayoutBroadcastTests` updates, docs/28 table.

1. **Vertical rail, right edge, always present.** Replace `WorkspaceSwitcher`'s
   horizontal strip AND `WorkspaceReturnBar` with one persistent vertical rail on the
   window's right edge: the five workspaces (icon over short label, the symbols already
   exist) plus the masks door, ~52–60 pt wide, visible in every view mode and workspace —
   Cull included, which permanently closes the stranding trap. Selected state matches the
   tab treatment (radiusTab, tabFill). ⌘1–⌘5 and `AppState.enter` unchanged. The develop
   column sits left of the rail.
2. **Kill the register.** `DisclosureRegister` and everything downstream: the
   "Show all/fewer sections" footer, `hiddenActiveIndicator`, `isInSimpleRegister`,
   `reveal`'s register promotion (simplify to select+expand). Persistence key
   `develop.register` stops being read (leave old values unread, per the
   `develop.masking` precedent). Update the WorkspaceTests that pin the register and the
   docs/28 table. `expose`/`reveal` simplify accordingly.
3. **Back to grid, visibly.** A small control at the filmstrip's left end: grid icon,
   "Grid (G)". Also **filmstrip controls**: hide/show and two or three height steps
   (a compact segmented or a drag — keep it simple), persisted.
4. **Double-click reliability** in grid: investigate the tap/double-tap race in
   `GridView` (single-tap select + double-tap open on the same cell — likely needs
   `onTapGesture(count:2)` BEFORE `count:1` or a combined gesture). He reports it
   "sometimes doesn't work".

*Acceptance:* no state of the app lacks visible navigation; grid⇄loupe round trip is
one obvious click each way; no register UI anywhere; tests green including reworked
tripwires (rewrite with intent, never delete silently).

### Stream B — Crop, round three: make the tool trustworthy
**Owns:** `CropPanel.swift`, `ViewerOverlays.swift`, `LoupeView.swift`,
`CropGeometry.swift` + tests (additive only), `Keymap.swift`/`KeyGrammar` for the
Return/Done grammar change.

The owner: *"Big thing about the crop, it's definitely finicky. It's glitching crazy…
when I'm moving it, it's spazzing out."* Moving the box is good; **edge/corner drags
glitch and do not follow the cursor**.

1. **Root-cause the edge-drag glitch before touching anything.** Candidate mechanisms,
   in likelihood order — the fix must name which one it was:
   a. `onContinuousHover` + per-event `@State` churn re-evaluating the overlay body and
      resetting `dragOrigin` mid-gesture;
   b. hit-region flapping between edge/corner/rotate under the pointer (region
      precedence recomputed per event while the rect moves under the cursor);
   c. with `angle ≠ 0`, drag deltas divided by the wrong rect (frame vs rect) or applied
      un-rotated;
   d. the `.onChange(of: viewport.showCrop)` / `beginSession` interplay stamping the
      baseline mid-drag.
   Write the trace down in the commit message.
2. **Angle interaction model.** His words: *"when I change the angle it automatically
   removes all the stuff… instead of giving me that gray top/bottom/left/right… I want
   to tilt the image and then move the square that I made. Right now I can't."* Two
   concrete changes that get Lightroom's feel without abandoning the inscribed-frame
   model:
   - When the angle changes, do NOT keep the crop pinned at 100% of the new inscribed
     frame. Preserve the rectangle's pixel size/centre where it fits (shrink minimally
     when it does not) so there is always slack to move after tilting.
   - While the tool is armed, render the FULL straightened frame with the
     outside-the-usable-area region dimmed (the gray he asks for), so tilting visibly
     rotates the picture under a stable box rather than re-cropping it.
   `CropGeometry` changes must come with property tests; the 23 existing tests stay
   green untouched.
3. **"Original" resets the crop.** Choosing Original in the aspect menu restores the
   full frame (clear crop rect + lock; keep angle/flip — Reset on the section header
   clears everything, and say so in its help).
4. **Delete the hint** (`crop.handHintSeen`, `hint(in:)`, `revealHint`) — all of it.
5. **Breathing room.** While the crop tool is armed, inset the drawn image (~24 pt) so
   the picture is not flush against the panel/sidebar and corner brackets are never
   clipped at the window edge. (His screenshot shows the frame crammed to the left.)
6. **Done/Revert rows go.** Auto-commit: the recipe is already written per event, so
   "Done" is only disarm — fold that into leaving the workspace, keep `R` toggle and
   Escape-reverts grammar, retire Return-commits (update `KeyGrammar` + Keymap + help
   sheet in ONE commit; the grammar tests scan text).
7. **Golden-ratio guide:** verify divisions are 1/φ² and 1/φ (≈0.382, 0.618); fix if the
   drawn lines are thirds-adjacent or otherwise off.
8. **Lens Corrections honesty check.** The toggle drives Apple RAW decode's embedded
   opcodes. Verify `PhotoFormats.raw` covers `arw` (Sony a7 IV — yes) and `rw2`
   (Panasonic GX85 — CONFIRM; if absent, the file never hits the RAW path at all).
   Give the row help that says exactly this: embedded manufacturer profile at decode,
   no lens database, does nothing for JPEGs (already disabled there).
9. Rotation feel (nice-to-have, last): finer response near 0°, ⇧ for fine.

*Acceptance:* he can tilt, then move the box, with gray showing where the picture
isn't; edge drags track the cursor 1:1 with no jitter; Original brings the whole image
back; no hint, no Done/Revert; brackets never clipped.

### Stream C — Every control explains itself; hierarchy pass
**Owns:** `DetailPanel.swift`, `BasicPanel.swift`, `ZonesPanel.swift`,
`EffectsPanel.swift` (help text only), `CurveEditorView.swift` (help only),
`LumenControls.swift` (help plumbing/`LumenSectionHeader` hover gating only).

1. **Help-text sweep, all ~92 sliders + toggles + menus.** Source: `docs/24-*` dossiers
   and docs/04/05. Format: one plain sentence of what it does + when you'd use it, then
   the reset hint. Enumerate rows whose help is bare ("Amount — double-click to reset")
   and fill every one. He named sharpening's Amount specifically.
2. **Capture Sharpening area** (his words: *"a little odd… the Auto for the measured is
   just kind of sitting there and I'm not really sure what that does"*): make the
   Auto/Measured badge self-explanatory (help on the badge; consider wording "Auto —
   measured from the file"), and remove hover affordance from anything that is not
   clickable.
3. **Hover discipline:** audit every `lumenHoverable`/press fill in these files; keep it
   on real click targets only.
4. **Develop overall:** he asked us to find anything that "stands out" — one agent pass
   over Develop's four sections for spacing/alignment oddities, report-and-fix small.

*Acceptance:* long-hover on any control name answers "what is this" in one sentence;
nothing non-interactive lights up.

### Stream D — Grade workspace UX
**Owns:** `LookPanel.swift`, `ColorPanel.swift`, `LumenControls.swift` (wheel +
segmented visuals), `MaskPanel.swift` untouched.

1. **Flatten the Looks section.** "Name this look" and "Display transform" lose their
   chevrons — plain content inside the one Looks fold. General rule he stated: one
   chevron per section, no nested folds unless they hide ≥4 rows.
2. **Press/hover fills off the band swatches and container rows** (*"when I press on
   them, they highlight… it doesn't have any padding so it looks kind of weird"*). The
   mixer band swatch strip, the Colour Balance zone segmented, and any full-bleed
   highlight: either remove the fill or give it the chip inset — removal preferred per
   his instruction.
3. **Point Colour UX.** The + button becomes an explicit eyedropper affordance (eyedropper
   icon + "pick from the photo" help; cursor feedback while armed). **Fix the minus
   button — he reports it does nothing.** The removal code exists
   (`ColorPanel.swift:435` `pointColors.remove(at: target)`), so trace why the button
   doesn't reach it (selection index? disabled state? hit area) and add a regression
   test on the mutation path.
4. **Wheels: less pastel.** `wheelColors` is sat 0.55 / brightness 0.8; raise saturation
   toward ~0.7–0.75 and check it against the mixer ring too (he flagged both). The wheel
   is Law 7's stated exception — richer is allowed; garish is not.
5. **Wheel lightness bar:** centre it under the wheel, give it a caption ("Luminance")
   and help; he could not tell what it was.
6. **Colour Balance copy.** The visible captions reading *"The colourfulness/lightness
   ratio, at constant H-K…"* / *"H-K corrected brightness at constant ratio"*
   (`LookPanel.swift:389,401`) read as leaked jargon to him. Move the science into
   `help:`; on-screen captions say plain things ("Saturation without changing perceived
   brightness" / "Perceived brightness without changing colourfulness"). "Chroma" as a
   bare divider label gets a proper group-header treatment or a plainer name.
7. **Printer Lights + Primaries:** help text (dossier-sourced); he guessed printer
   lights right — say it on hover.
8. **B&W review:** verify the per-band treatment behaves (tie to Stream F's parity
   checks); UI just needs help text.

*Acceptance:* one chevron per section in Grade; nothing highlights on press except real
buttons; point-colour add/remove both work with obvious affordances; no jargon captions
on screen.

### Stream E — The engine fixes he can now feel
**Owns:** `Sources/LumenCore/Engine/*`, `LoupeView.swift` (ladder feed),
`InspectionGain.swift`. Sequenced by the lead; full triad + gpu-parity between items.
All four are already traced in docs/31 round two with measured numbers — read those
entries first.

1. **Grading-wheel Luminance inversion** (docs/31 R2 §1). He is actively using these
   wheels. `solveLumScale` must solve against `3·slope` (OKLab L³), `ColorBalanceGrid`
   gets the same limiter, `lumRangeStops` restated. Add the numeric regression test from
   the audit (Midtones +1 / Highlights −1 must be monotone).
2. **Blur while dragging wheels and sliders** (his: *"I get the blurry effect until I
   let go"*, again under vignette). Fix the draft ladder's feed (docs/31 §23): pass the
   DELIVERED long edge (`draft.image` size) to `record`/`isRepresentative`, not the
   requested one, so the ladder climbs during wheel drags; verify `recordSettle` fast
   recovery on cropped photos. Then check the wheel drag actually rides the same
   gesture→draft path sliders do.
3. **Film Lab keeps the user's display transform** (docs/31 R2 §2): blend base = the
   recipe's solved transform, killing the 51-code Strength-1 jump.
4. **Vignette:** (a) banding at −3 — investigate the preview path (fp16 plane + strong
   negative gain; the GPU vignette also lacks the reference's ±3/+1 clamp — docs/31
   R2 smaller-items); likely needs display-path dither or higher-precision gain
   application; measure before/after on a gray ramp. (b) Feather/midpoint control:
   engine geometry is currently fixed — add ONE `feather` parameter end to end
   (recipe field + both renderers + parity golden + slider) rather than a suite of
   knobs. (c) Reassess strength range only after banding is fixed.

### Stream F — Pipeline correctness (second wave with E)
**Owns:** `Sources/LumenPipeline/*`, `PlanTableCache.swift`.
Straight from docs/31 round two, each with the traced fix already written down:
1. Stale-table door: key carries an identity prefix; never serve another photo's table
   (§4 — the B&W-flash-on-photo-switch bug).
2. Mask raster resolution scales with the render for settle/export (1024 stays for
   drafts only) (§3).
3. `logLuminance` floor at zero on the GPU path (§5 R2 numbering: the negative-luminance
   guided-filter blowup).
4. Texture gain clamp ±4 EV to match the reference; gamut-flag placement parity.
5. Export tail from round one: `.none` must not resample (scale exactly 1), Lanczos
   `clampedToExtent`, metadata read from the SOURCE dictionary (§§11–13).

### Stream G — Export sheet
**Owns:** `ExportSheet.swift`, `ExportRecipe.swift`, `PipelineRenderer` write path
(coordinate with F on shared lines — G goes second).
1. **Quality defaults to 100** (currently 90; update the shipped presets too, keeping
   "Web sRGB 2048" smaller if justified — say so in its name/help if kept at 90).
2. **Bit depth honesty + capability.** Facts: JPEG is 8-bit by format; TIFF/PNG 16-bit
   already exist (`effectiveBitDepth`); the dither stage exists to fight 8-bit banding.
   Work: (a) UI copy that states this at the format row, (b) investigate **10-bit HEIC**
   via CGImageDestination/HEVC — if writable, wire it as HEIC's depth option; if not,
   record why in the sheet's help. His sky-banding worry is the driver.
3. Verify the whole sheet against its help: resize modes (after F's `.none` fix),
   output sharpening radius denomination, naming tokens, metadata policy (after F),
   watermark bounds (fixed earlier — confirm), soft-proof no-effect-on-export (verified
   in audit — add the one-line test).

### Stream H — Guards (background, lead-owned, small commits)
1. Fixture suite for `check-swift-surface.py` (known-good + known-bad snippets; the
   known-bad set MUST include the multi-line-ternary argument-order case). Fix the hole
   it exposes.
2. Arity guard extended to inner `Group`s of the menus.
3. `ProofRegistry.shippingReader` made real (assert the named line contains the reading
   expression) or deleted with a doc note — no inert guards.
4. Regression tests shipped WITH each stream's fix (the lead enforces this at commit).

---

## 3. SCHEDULING

Wave 1 (parallel agents): A, B, C, D. These are UI-layer, disjoint, and everything the
owner will retest first. Lead integrates, runs the triad, pushes, watches CI.
Wave 2: E then F (engine/pipeline, gpu-parity between items), G after F, H throughout.
Ping the owner when Wave 1 is green and installed-testable; again after Wave 2.

## 4. EXPLICITLY DEFERRED (owner's "prerequisite talk" — do not start)
- Open-source denoise integration.
- Film-stock replication expansion + large grain customisation area.
- Masks polish round two (he did not reach masks this session).
Also still open in docs/31: everything not named above stays ranked there.
