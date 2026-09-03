# W2 — M · Recipe & serialization

Area: forward/backward compatibility, the K-020 silent downgrade, the dead wire fields
(K-043), pivot robustness (K-059), paste-settings subsets, fingerprint stability, and
what the fixtures mirror requires of any field change.

**Files read every line:** `Sources/LumenCore/Recipe/Recipe.swift` (1419),
`RecipeLook.swift` (638), `RecipeMasks.swift` (921), `CanonicalJSON.swift` (265),
`Fingerprint.swift` (147), `RecipeDecoding.swift` (72), `LookSubset.swift` (183);
`Sources/LumenCore/XMP/XMPSidecar.swift` (627); `scripts/gen-fixtures.py` recipe mirror
(lines 200–520) and header.
**Read for the owned question only:** `Sources/LumenCore/Catalog/CatalogStore.swift`
(`saveRecipe` 1690–1815, preview key 843–860, `currentRecipe` 1809–1814),
`Sources/LumenCore/Model/ZoneWeights.swift`, `Engine/ToneEngine.swift:380–392`,
`Engine/GradeEngine.swift:96–130`, `Engine/CurveStack.swift:58–62`,
`Sources/LumenApp/CatalogService.swift` (recipe→sidecar path 632–714, `enqueueSidecar`
1015–1052), `Sources/LumenApp/AppState.swift:3500–3565, 3676–3684`,
`Sources/LumenApp/ZonesPanel.swift:155–200`;
`Tests/LumenCoreTests/{CatalogTests,RecipeCodecToleranceTests,CanonicalJSONTests,
MaskDeadFieldTests,SidecarAndIngestTests}.swift` (the relevant cases).
**Docs:** PLAN.md (§"Decisions already taken", §"The fixtures ceremony" 482–488),
`docs/15-catalog.md §15.4/§15.5`, `docs/14 §pipelineVersion`, ledger §M rows.

Note: the working tree is **dirty from a concurrent session** — `Sources/LumenApp/CatalogService.swift` and `Sources/LumenCore/XMP/XMPSidecar.swift` carry uncommitted changes (a `SidecarStatedFields` / `XMPSidecar.reseed` pair, `XMPSidecar.swift:98-140`, which is the J1-03 repair). **Every line number below is against that working tree, not HEAD**; XMPSidecar sites after line 83 sit 59 lines lower than at HEAD. That change does not touch M-01: `reseed` still copies the carried version verbatim (`XMPSidecar.swift:136`, `out.pipelineVersion = stated.pipelineVersion`).

Note: no Swift toolchain exists in this environment (`swift` is not on PATH and
`/usr/share/swift` is an empty tree), so nothing here is `measured` by a run. Every
finding is traced by reading both ends of the call.

---

## Known-open dispositions

| id | verdict | evidence |
|---|---|---|
| K-020 | **CHANGED — catalog half FIXED, sidecar half STILL-OPEN** | The catalog guard now compares against this build: `CatalogStore.swift:1767` `rowVersion > Int64(currentPipelineVersion)`, and the stamp is clamped at `:1724-1725` `Swift.min(recipe.pipelineVersion, currentPipelineVersion)`; pinned by `CatalogTests.swift:179-224`. **But nothing on the sidecar path does either.** `SidecarMerge.resolve` (`XMPSidecar.swift:250-297`) never reads `sidecar.pipelineVersion`; `grep -rn "\.pipelineVersion" Sources/LumenApp Sources/LumenCore/XMP` returns only writes (`CatalogService.swift:702, 1029`; `XMPSidecar.swift:459`) and one parse (`:606-608`). A newer build's recipe that arrives in a `.xmp` is still downgraded in place. → **M-01**. |
| K-043 | **CHANGED — split** | The five `LocalAdjust` fields are now a *stated decision* with a two-sided test: `RecipeMasks.swift:647-682` (the "CARRIED, NOT RENDERED" block, with what each would take) and `Tests/LumenCoreTests/MaskDeadFieldTests.swift:37-49` (survives the wire) + `:51+` (changes no pixel). Row closed for those five. The **eight `Upright` fields are STILL-OPEN and undocumented**: `Recipe.swift:1294-1334` declares them, and `grep -rn upright --include=*.swift Sources/` finds exactly one non-declaration reader — `WorkspaceModification.swift:90` `|| geometry.upright != nil`, which only lights the Frame dot. No renderer, no panel, no test, and no comment saying so. `develop.heal` is in the same state (`Recipe.swift:1398-1419`; `Recipe.swift:182-190` admits it and says heal "should adopt" the LUT tripwire pattern "when somebody is next in that code"). → **M-05**. |
| K-059 | **CHANGED — padding half STILL-OPEN, non-finite half not reachable from the wire** | Padding: `Recipe.swift:479-481` runs zone pivots through `RecipeWire.fixedLength` (`RecipeDecoding.swift:63-71`), which pads a short array with the **tail** of the defaults, and `ToneEngine.swift:389` accepts the result on **count alone**. `{"pivots":[0.9]}` decodes to `[0.9, 0.5, 0.642857, 0.785714, 0.928571]` and renders. → **M-03**. Non-finite: JSON has no literal for NaN, and an infinity does **not** break `ZoneWeights.crossfade` — the guards at `ZoneWeights.swift:33-34` plus the loop at `:36` provably cannot leave `i == n-1` for any *finite* pivot set (each failing iteration forces `x >= pivots[i+1]`, and `x >= pivots[n-1]` returned already). The out-of-bounds `pivots[i + 1]` at `:37` needs an in-process NaN, which `ZoneWindows` defends against (`GradeEngine.swift:104-105, 180-182`) and `ToneEngine.zonePanelStops` does not. Re-scope the row to the padding half plus that one missing NaN guard. |

Cross-cutting rows (K-014, K-058, K-073, K-102): not touched, no disposition.

---

## New findings

### M-01 — a recipe a newer build wrote into a `.xmp` is silently downgraded, and written back still claiming the newer version
severity: S1
confidence: traced
class: defect
size: M
evidence: `Sources/LumenCore/Recipe/CanonicalJSON.swift:151-157` — `decodeRecipe` merges the sparse tree onto defaults and then hands it to `JSONDecoder().decode(Recipe.self, …)`, whose `CodingKeys` (`Recipe.swift:194-196`) name five keys; every key a later build added is **dropped here**, which the header at `:149-150` calls "forward compatibility for free". `Recipe.swift:207-208` then carries the *version* forward (`decodeIfPresent(Int.self, forKey: .pipelineVersion) ?? currentPipelineVersion`) while the *content* has been reduced. On the way back out, `CanonicalJSON.swift:109-111` forces `obj["pipelineVersion"] = .number(Double(recipe.pipelineVersion))` — the carried number, **not** clamped — and `Sources/LumenApp/CatalogService.swift:702` hands that same unclamped number to the sidecar: `recipe: (json, fingerprint, recipe.pipelineVersion)`, which `:1029` copies into `content.pipelineVersion` and `XMPSidecar.swift:459` writes as `<lumen:pipelineVersion>`. Nothing between the file and the write compares it against `currentPipelineVersion`: `SidecarMerge.resolve` (`XMPSidecar.swift:250-297`) decides on mtime (`:270-282`) and fingerprint (`:346-360`) only, and `taking` (`:327-338`) installs `incoming` — the downgraded recipe — as the catalog's. The catalog's own protection (`CatalogStore.swift:1764-1774`) cannot fire, because on this machine the row was never stamped with the newer version in the first place.
how the owner sees it: he grades a frame on his laptop running the newer build, opens the same folder on the desktop that has not been updated, nudges Exposure — and the parameters the newer build added are gone from the `.xmp` and from the catalog. The file still says it was written in the newer format, so when he goes back to the laptop the newer build accepts Lumen's downgraded copy as its own most recent work and there is nothing to restore from.
fix: `Sources/LumenCore/XMP/XMPSidecar.swift` + `Sources/LumenApp/CatalogService.swift`. (1) Add a fourth `Decision` case, `.sidecarIsNewerFormat`, returned from `resolve` when `sidecar.pipelineVersion > currentPipelineVersion` **and** the sidecar states a recipe — before the mtime test, since this is true whether or not the file moved. (2) In that case the catalog takes the fields it can read but the writer is forbidden: `flushSidecars` must skip the `lumen:recipe`, `lumen:recipeFingerprint` and `lumen:pipelineVersion` elements for that photo entirely (`XMPMerge` already leaves untouched anything `fieldLines` does not emit), so ratings and flags keep flowing and the recipe bytes are left alone. (3) The recipe this build then edits is preserved the way the catalog preserves one — `saveRecipe(…, kind: .version, name: "Preserved from a newer build (pipeline vN)")` — so the newer work is visible and restorable rather than merely not-destroyed. (4) `CatalogService.swift:702` passes `Swift.min(recipe.pipelineVersion, currentPipelineVersion)`, so a document this build authored never claims semantics it does not implement.
test (`Tests/LumenCoreTests/SidecarAndIngestTests.swift`) — red today at the first assertion:
```swift
func testASidecarFromANewerBuildIsNotRewrittenByThisOne() throws {
    let futureRecipeJSON = "{\"pipelineVersion\":\(currentPipelineVersion + 1),"
        + "\"develop\":{\"tone\":{\"exposure\":1.5}},\"somethingNewer\":{\"x\":1}}"
    var sidecar = SidecarContent()
    sidecar.pipelineVersion = currentPipelineVersion + 1
    sidecar.recipeJSON = futureRecipeJSON
    sidecar.recipeFingerprint = "xxh64:deadbeefdeadbeef"

    var catalog = SidecarMerge.State(recipe: Recipe(), sidecarMTime: 100)
    catalog.recipeFingerprint = try RecipeFingerprint.fingerprint(Recipe())
    let r = SidecarMerge.resolve(catalog: catalog, sidecar: sidecar, sidecarMTime: 200)

    XCTAssertEqual(r.decision, .sidecarIsNewerFormat,
                   "a recipe written in a vocabulary this build does not implement was "
                     + "read as if it were this build's own")
    // And the round trip must not narrow it: what this build re-emits for that photo
    // is not allowed to be the decoded-and-re-encoded form.
    let decoded = try CanonicalJSON.decodeRecipe(from: Data(futureRecipeJSON.utf8))
    let reemitted = try CanonicalJSON.canonicalRecipeJSON(decoded)
    XCTAssertFalse(reemitted.contains("somethingNewer"),
                   "sanity: the decode really does drop it")
    XCTAssertNotEqual(XMPSidecar.fieldLines(sidecar).contains("<lumen:recipe>"), true,
                      "the writer must emit no recipe element for this photo")
}
```
Substitution proof: delete the `.sidecarIsNewerFormat` branch and `resolve` returns `.sidecarWins`, the first assertion fails, and the flush re-emits `{"pipelineVersion":N+1,"develop":{"tone":{"exposure":1.5}}}` — the same version stamp over strictly less content, which is the loss.

### M-02 — the recipe TEXT in a row claims a pipeline version the row's own column denies
severity: S2
confidence: traced
class: defect
size: S
evidence: `CatalogStore.swift:1705` stores `try CanonicalJSON.canonicalRecipeJSON(recipe)` and `:1724-1725` clamps only the *column*: `let storedPipelineVersion = Swift.min(recipe.pipelineVersion, currentPipelineVersion)`. But `CanonicalJSON.swift:109-111` writes `recipe.pipelineVersion` into the JSON unclamped, so the row is `pipeline_version = 2` with `recipe = {"pipelineVersion":7,…}`. `currentRecipe` (`:1813`) decodes that text, so `Recipe.pipelineVersion` comes back as 7 on every subsequent open, forever — the clamp corrects the column and the bytes re-infect it. `CatalogTests.swift:212-214` asserts the property on the column only (`working.pipelineVersion == currentPipelineVersion`), so the divergence is invisible to the test written for exactly this row.
how the owner sees it: the version row Lumen preserved for him is labelled "Preserved from a newer build (pipeline v7)" and the working row beside it carries byte-identical version text, so the two are indistinguishable in the edits list; and every sidecar this build writes for that photograph from then on is stamped v7 — which is what makes M-01 unrecoverable rather than merely lossy.
fix: `CanonicalJSON.canonicalRecipeJSON` is the wrong place to decide (it also serializes for the fingerprint, where the recipe's own claim is what should be hashed). Clamp at the two writers instead: `CatalogStore.saveRecipe` builds its JSON from `var stamped = recipe; stamped.pipelineVersion = storedPipelineVersion` before `:1705`, and `CatalogService.swift:702` passes the same `min`. Test in `CatalogTests`: after the K-020 scenario, assert `try store.currentRecipe(photoID:)?.pipelineVersion == currentPipelineVersion` **and** that the stored text contains `"pipelineVersion":\(currentPipelineVersion)`. Red today on both — `currentRecipe` returns `currentPipelineVersion + 1`.

### M-03 — a short pivot array is padded into an unsorted one, and the tone engine renders it while the panel draws a repaired version
severity: S2
confidence: traced
class: defect
size: S
evidence: `Recipe.swift:479-481` decodes `zones.pivots` through `RecipeWire.fixedLength`, whose rule (`RecipeDecoding.swift:63-71`) is "take what is there, in order, and fill the rest from the default" — length-preserving, not **order**-preserving. `{"pivots":[0.9]}` therefore decodes to `[0.9, 0.5, 0.642857, 0.785714, 0.928571]`. `ToneEngine.swift:389` accepts it on count alone: `let pivots = zones.pivots.count == ev.count ? zones.pivots : Zones.defaultPivots`. `ZoneWeights.crossfade` (`ZoneWeights.swift:33`) then returns `(0, 1)` for every `x <= pivots[0] == 0.9`, i.e. for every scene value below **+3.6 EV** on the axis `Zones.defaultPivots` is built on (`x = (ev + 9)/14`), so the Darks slider alone governs essentially the whole picture. The other two ordered arrays in the format defend themselves: `CurveStack.regionCentres` (`CurveStack.swift:60`) does `splits.sorted()`, and `ZoneWindows` (`GradeEngine.swift:102-117`) checks finiteness, swaps `p1 < p0`, saturates and enforces a minimum gap. Zone pivots are the one that does not. Meanwhile `ZonesPanel.normalizedPivots` (`ZonesPanel.swift:164-171`) repairs the array *for display only* — it is a computed property; `movePivot` (`:178-195`) resets only on a wrong **count**. And the existing tolerance tests pin the padding without ever asserting the invariant: `RecipeCodecToleranceTests.swift:336-340` and `:371-379` assert `count`, `[0]` and `[4]` and nothing about order.
how the owner sees it: he opens a photograph whose `.xmp` was hand-edited (or trimmed by a sync tool) and the Zones strip draws five handles in sensible places while the picture is rendered as though every zone slider were the Darks slider. Dragging Mids does nothing he can see; the panel and the frame disagree and neither says why.
fix: `Sources/LumenCore/Recipe/RecipeDecoding.swift` + `Recipe.swift`. `fixedLength`'s
padding rule is right for arrays whose elements are **independent** — the mixer's eight
bands, a Point Colour's RGB triple, a band's `[below, above]` handles — where keeping six
real bands beats discarding them. It is wrong for arrays that carry a **joint** invariant,
because a padded pivot list is not a partial answer, it is a different answer: position
`i` means "the Darks zone" and a value that arrived at position 0 is not the same
statement as the same value at position 3. So add a second rule beside it:

```swift
/// A fixed-length array whose ORDER is part of its meaning: the zone pivots, the
/// grade's two, the parametric curve's three splits. Readers index them positionally
/// AND assume they ascend, so the two failures need different answers. A wrong LENGTH
/// has no positional meaning to preserve — padding position 0 from a one-element array
/// and the rest from the defaults produces a pivot list nobody wrote — so it falls back
/// to the default whole. A wrong ORDER at the right length is a real list somebody did
/// write, so it is repaired the way `ZoneWindows` already repairs the grade's two
/// (GradeEngine.swift:102-117): drop non-finite, saturate, sort, enforce a gap.
static func ascending(_ decoded: [Double]?, default defaults: [Double],
                      minimumGap: Double = 0.02) -> [Double] { … }
```

Route `Zones.pivots` (`Recipe.swift:479`), `GradingWheels.pivots` (`RecipeLook.swift:277`)
and `ParametricCurve.splits` (`Recipe.swift:605`) through it, so the invariant lives with
the format rather than three-quarters of the way down three different engines — two of
which repair it and one of which does not. Test in `RecipeCodecToleranceTests`:
```swift
func testAnOrderedArrayIsStillOrderedAfterTheDecoderFillsItIn() throws {
    let short = try JSONDecoder().decode(
        Zones.self, from: Data(#"{"pivots":[0.9]}"#.utf8))
    XCTAssertEqual(short.pivots, Zones.defaultPivots,
                   "the padding rule built a descending pivot array — every zone below "
                     + "the first pivot collapses onto Darks")

    // The engine, not just the value: Mids must still be able to move a mid-tone.
    var recipe = Recipe(); recipe.develop.zones = short
    recipe.develop.zones.mid.ev = 1.0
    let engine = ToneEngine(tone: Tone(), zones: recipe.develop.zones)
    XCTAssertEqual(engine.zonePanelStops(0.0), 1.0, accuracy: 1e-9,
                   "the Mids slider moved and mid-grey did not")

    // A full-length list that merely arrived out of order is REPAIRED, not discarded —
    // it is a list somebody actually wrote.
    let jumbled = try JSONDecoder().decode(
        Zones.self, from: Data(#"{"pivots":[0.8,0.2,0.5,0.35,0.65]}"#.utf8))
    XCTAssertEqual(jumbled.pivots, jumbled.pivots.sorted())
    XCTAssertEqual(jumbled.pivots.count, Zones.defaultPivots.count)
}
```
Substitution proof: restore the plain `fixedLength` call at `Recipe.swift:479` and the
first two assertions fail — `pivots[0]` comes back as 0.9 and `zonePanelStops(0.0)`
returns 0, because mid-grey (x = 0.643) is below the padded first pivot and takes the
Darks zone's EV. The second assertion is the one that names the pixels; the third is the
regression guard in the other direction, so the fix cannot become "throw the array away
whenever anything is wrong with it".

### M-04 — `gen-fixtures.py`'s `render_identity` is missing two of the three strips `Recipe.renderIdentity` performs
severity: S3
confidence: traced
class: defect
size: S
evidence: `Recipe.renderIdentity` (`Recipe.swift:142-192`) performs four projections: blank mask name+id (`:144-148`), group cosmetics (`:155`), drop a switched-off `look.bw` (`:156`), **drop an identity `look.grain`** (`:164`), and **drop `look.lut`** (`:181`). The Python mirror (`scripts/gen-fixtures.py:257-284`) implements the first three and stops — there is no `grain` clause and no `lut` clause. The mirror's own header (`:14-15`) says "Mirrored contracts (change BOTH sides together)", and PLAN.md's fixtures ceremony (`:482-488`) makes regeneration mandatory for any `Recipe()` default change. No fixture case exercises either field (`gen_canonical_fixture`, `:394-511`, covers default / develop / mask+look / precision / B&W), so the drift is silent: the fixtures lane is green and cannot see it.
how the owner sees it: not yet — and that is the shape of the risk. `Recipe.swift:176-180` leaves an explicit instruction to delete the `lut` strip in the same commit as the LUT stage. On that day the fixtures are regenerated from a mirror that never stripped it, and if the reconciliation is made by "fixing" Swift back to match Python, the photographer drags LUT Amount and the cache hands back the previous picture — the mirror defect the comment names by hand.
fix: add both clauses to `render_identity` in `scripts/gen-fixtures.py`, mirroring `Recipe.swift:164` and `:181` (a `grain` whose `amount` is not `> 0` is deleted; `lut` is deleted unconditionally), and add two cases to `gen_canonical_fixture` — a recipe with `look.lut` set and one with `{"grain": {"size": 90}}` — each asserting `fp(render_identity(x)) == fp(render_identity(defaults))`. Then `python3 scripts/gen-fixtures.py --check`. Test: `CanonicalJSONTests` replays every case in `canonical.json` by name and fails on one it does not implement (`:84`), so the new cases force the Swift side to state the same two identities. Red today: the Python `fp` for a LUT-carrying recipe differs from Swift's, which is precisely the drift.

### M-05 — eight `Upright` fields and `develop.heal` round-trip with no reader, no panel and nothing that says so
severity: S3
confidence: traced
class: defect
size: S
evidence: `Recipe.swift:1294-1334` declares `Upright`'s eight sliders with ranges in the comments ("−100…+100", "50…150, default 100"); `grep -rn "upright" --include=*.swift Sources/` finds no reader on either renderer — the only non-declaration site is `WorkspaceModification.swift:90` `|| geometry.upright != nil`, which lights the Frame section's dot. `develop.heal` (`Recipe.swift:1398-1419`) is the same, and `Recipe.swift:182-190` says so out loud, adds that it is deliberately *left in* `renderIdentity` as a cache-busting tripwire, and concludes the LUT pattern "is the better of the two … and heal should adopt it when somebody is next in that code". `LUTReference` (`RecipeLook.swift:177-226`) is the one dead slot done right: the inertness is stated at the definition, made mechanical by the strip at `Recipe.swift:181`, and held by a named test. `Upright` has none of the three.
how the owner sees it: not directly — there is no Upright control to be disappointed by. What he sees is the second-order cost: `develop.heal` stays in the fingerprint, so a photograph whose `.xmp` happens to carry a heal block gets a `recipe_fp` no other copy of the same edit shares, re-renders on open to produce identical bytes, and shows up as edited in the library.
fix: keep the fields — deleting them is the silent-drop failure `RecipeDecoding.swift:6-13` exists to prevent — and give both the LUT treatment in `Sources/LumenCore/Recipe/`: a "carried, not rendered" paragraph at each definition on the model of `RecipeMasks.swift:647-682`, `copy.develop.heal = Heal()` added to `renderIdentity` beside `:181`, and a `RecipeDeadFieldTests` pair on the model of `MaskDeadFieldTests` — the values survive `canonicalRecipeJSON`→`decodeRecipe`, and a recipe differing only in `upright`/`heal` fingerprints the same as one without. Red today on the second half for `heal`: `RecipeFingerprint.fingerprint(r)` with `r.develop.heal.count = 3` differs from the default's, and that test is what fails the day a heal stage lands, sending whoever wired it here to delete the strip.

### M-06 — `pasteSettings` copies a look that only version 2 can express onto a recipe still stamped version 1
severity: S3
confidence: traced
class: defect
size: S
evidence: `LookSubset.applied(to:)` (`LookSubset.swift:133-138`) raises the target's stamp deliberately — `copy.pipelineVersion = max(recipe.pipelineVersion, pipelineVersion)` — and `:126-132` states the reason: a v2 look can say "black and white, off, mix kept" (`look.bw.enabled == false`), "which a v1 reader renders as black and white, so a recipe that has just been handed one has to say v2 or it lies about what it holds". `AppState.pasteSettings` (`AppState.swift:3511-3521`) assigns `recipe.develop`, `recipe.look`, `recipe.masks`, `recipe.maskGroups` and never touches `pipelineVersion`; `pasteSettingsWithoutMasks` (`:3534-3539`) is the same. So the exact construct `LookSubset` guards against travels unguarded on the two commands photographers actually use across a shoot, and `CatalogStore.swift:1724` then stamps the row `min(1, 2) == 1`.
how the owner sees it: he copies settings from a frame he graded this week onto one he last touched before the upgrade — including a black-and-white treatment he switched off but kept the mix of — and the file records a vocabulary that cannot express that state. Any reader that honours the stamp, including this app's own future migrations, reads the frame as monochrome.
fix: one line in each of the two commands: `recipe.pipelineVersion = max(recipe.pipelineVersion, source.pipelineVersion)`. Better, move the rule out of the untestable target: add `Recipe.adoptingSettings(from:includingMasks:)` to `Sources/LumenCore/Recipe/Recipe.swift` next to `appendingMasks`, which does the four assignments **and** the `max`, and have `AppState` call it. Test in `Tests/LumenCoreTests/` (a `PasteSettingsTests` beside `PasteMasksTests`):
```swift
func testPastingASettingsSetRaisesTheTargetsVocabulary() {
    var source = Recipe(pipelineVersion: 2)
    source.look.bw = BlackAndWhite(bands: [0,0,0,0,-40,-65,0,0], enabled: false)
    let target = Recipe(pipelineVersion: 1)
    let out = target.adoptingSettings(from: source, includingMasks: true)
    XCTAssertEqual(out.pipelineVersion, 2,
                   "a recipe holding a switched-off B&W mix is stamped with a version "
                     + "whose readers render it as black and white")
    XCTAssertEqual(out.look.bw?.enabled, false)
}
```
Substitution proof: drop the `max` and the first assertion fails with 1 — which is what both menu commands produce today.

### M-07 — the render fingerprint hashes `pipelineVersion`, so a bump defined as rendering-identical throws away every cached preview
severity: S3
confidence: traced
class: defect
size: S
evidence: `RecipeFingerprint.fingerprint` (`Fingerprint.swift:124-127`) hashes `canonicalRecipeJSON(recipe.renderIdentity)`, and `CanonicalJSON.swift:109-111` forces `pipelineVersion` into that string past the sparse pass, so it is part of the digest. `renderIdentity`'s own definition (`Recipe.swift:124-125`) is "what actually reaches a pixel", and `currentPipelineVersion`'s doc comment (`Recipe.swift:21-25`) states that "No version-1 recipe renders differently under version 2". The preview cache is keyed `(photo_id, level, recipe_fp)` (`CatalogStore.swift:843-856`), and the artifact cache already carries the pipeline version as its **own** key column (`CatalogStore.swift:258, 2638`), so hashing it into `recipe_fp` as well is a second, coarser copy of the same guard. Note the asymmetry with the two strips a few lines above it: `look.lut` and an identity `look.grain` are removed from the digest with the argument "throws away every cached preview and artifact of that photograph to produce identical bytes" (`Recipe.swift:170-174`) — which is exactly what the version does to *every* photograph, once per bump.
how the owner sees it: the first launch after an upgrade re-renders the previews and 1:1s of a library in which nothing changed; and until each photograph is re-saved, two frames carrying the same edit at different stamps can never share a cached artifact.
fix: decide it explicitly rather than by omission. If the intent is "a bump may change pixels", the cheap correct form is a separate constant — `currentRenderVocabulary`, bumped only for rendering-affecting changes — substituted for `pipelineVersion` in the *fingerprint* projection (`renderIdentity` sets `copy.pipelineVersion = renderVocabulary(for: pipelineVersion)`), leaving the stored recipe's stamp untouched. If the intent is "v1 and v2 render alike", `renderIdentity` zeroes the field. Either way the choice belongs in the comment at `Recipe.swift:14-26`. Test in `CanonicalJSONTests`:
```swift
func testTwoStampsThatRenderTheSamePictureShareAFingerprint() throws {
    var v1 = Recipe(pipelineVersion: 1); v1.develop.tone.exposure = 0.35
    var v2 = v1; v2.pipelineVersion = 2
    XCTAssertEqual(try RecipeFingerprint.fingerprint(v1),
                   try RecipeFingerprint.fingerprint(v2),
                   "a version bump that changes no pixel invalidated every cached "
                     + "preview and artifact in the catalog")
    // and the STORED recipe still tells the two apart
    XCTAssertNotEqual(try CanonicalJSON.canonicalRecipeJSON(v1),
                      try CanonicalJSON.canonicalRecipeJSON(v2))
}
```
Red today at the first assertion. This one changes `recipe_fp` for every photograph once, so it is a fixtures-ceremony change (`canonical.json` regenerates) and belongs in the same commit as a mirror update.

---

## Nothing found at these

- **No S1 in the pure `Recipe`/`RecipeLook`/`RecipeMasks` decode surface.** Every type declares `CodingKeys` + `init(from:)` with the memberwise default as the fallback; I checked all 34 of them line by line against their own initializers and found no fallback that differs from the default beside it. The three non-obvious ones are correct and are the ones that would bite: `BlackAndWhite.enabled ?? true` (`RecipeLook.swift:608`), `Look.vignetteFeather ?? 50` (`:109-110`), and `CreativeGrain.size/roughness ?? 50` (`Recipe.swift:1044-1045`).
- **No defect in `CanonicalJSON.sparse`/`merge`/`canonicalNumber`.** The round-trip-shortest number rule (`:233-244`) is correct and its own comment explains the `%.6g` defect it replaced; key sorting is by UTF-8 code point to match Python's `sorted()` (`:197-201`).
- **`Recipe.appendingMasks` (`Recipe.swift:67-96`) is correct** on the property that matters — the batch is remapped together, so an intra-batch `maskRef` follows its partner and an out-of-batch one is left alone.

## Notes for W3

- M-01 and M-02 are one repair and should land together: clamping the stamp (M-02) without refusing the write (M-01) turns a downgrade that at least *admits* its version into one that quietly claims to be this build's own work.
- Any of M-03, M-05 (the `heal` strip) or M-07 moves `recipe_fp`, so each triggers the fixtures ceremony (PLAN.md:482-488) and cannot be split across commits from its mirror edit. M-04 must land **first** — the mirror is wrong today, so regenerating fixtures for any of the others locks the drift in.
