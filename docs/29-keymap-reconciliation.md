<!-- docs/29 — the keymap reconciliation docs/12 §12.3, Keymap.swift and docs/28 item 30
all defer. This is a DECISION DOCUMENT: it states every divergence between the shipped
grammar and docs/12's canonical map, recommends a resolution for each, and marks the ones
that are the owner's call rather than mine. Nothing here is implemented. On a decision,
docs/12 gets amended explicitly (docs/00 §3) and `KeyGrammar.swift` follows. -->

# 29 — The keymap reconciliation

## Why this exists now

Three separate pieces of work are blocked on the same unmade decision, which is how a
deferral announces that it has stopped being cheap:

- **docs/28 Phase 4** wants `1`–`4` for the four workspaces. Those are ratings.
- **docs/28 Phase 6 item 24**, the ⌘K control palette, wants ⌘K. That is "Keyword the
  selection".
- **docs/12 §12.4 Speed Edit** wants held letters — and, it turns out, does *not* collide;
  see §3. That one resolves itself, which is worth knowing before spending a letter on it.

Meanwhile eight bindings have drifted from the canonical map, each for a defensible local
reason, none of them recorded as an amendment. `Keymap.swift` and `ContentView.swift` both
say in comments that this belongs to "one deliberate pass over the whole keymap". This is
the paperwork for that pass.

**Nothing here is a bug.** Every shipped binding works and is in `KeyGrammar`, which
`KeyGrammarTests` enforces in both directions. What has drifted is the *contract*, and
docs/00 §3 says a contract either holds or gets amended out loud.

## 1. The drift, and what I would do about each

`◆` = I would just do this, tell me to stop. `⚑` = your call, I have a preference but the
argument is close.

| Key | docs/12 says | Shipped | | Recommendation |
|---|---|---|---|---|
| `L` | Lights-out cycle (§12.7) | Look panel | ⚑ | **Give `L` back to Lights Out.** It is a *viewing-conditions* control and Law 7 territory; the Look panel is one of eight tabs and, after Phase 4, one of four workspaces reachable another way. But it is muscle memory you already have. |
| `B` | Add to target album | Basic panel | ⚑ | **Give `B` back to the album.** Same argument: `B` is a culling verb in the LR-compatible grammar D35 promises, and panel selection is about to stop being key-shaped at all. |
| `⌘B` | Assessment surround, ISO 12646 | Add to target album | ◆ | Falls out of the row above: if bare `B` is the album, ⌘B is free for assessment mode, which is what §12.7 and D46 specify. |
| `F` | Focus peaking | Filmstrip | ⚑ | **Keep `F` on the filmstrip**, amend docs/12. Focus peaking is unbuilt; the filmstrip toggle is used daily. A canonical map that reserves a letter for a feature that does not exist, against one that does, is the map being wrong. |
| `S` / `⇧S` | Collapse stack / promote pick | Scopes / Soft proof | ⚑ | **Keep the shipped meanings**, amend docs/12, and accept that collapse-stack and promote-pick stay sidebar buttons with no bare key. Note this is a real if small loss, not a redundancy: docs/12 gives stacks four actions across `S`/`⇧S` *and* `⌘G`/`⇧⌘G`, and only the latter pair is built. If you stack often, say so and I will find them keys. |
| `J` | Clipping overlay | `⇧H` | ◆ | Amend docs/12 to `⇧H`. It sits beside `H` for the histogram, which is where a photographer looks for it. `J` is arbitrary. |
| `⌘⇧C` / `⌘⇧V` | Copy / paste settings | `⌘C` / `⌘V` | ◆ | Keep shipped, amend docs/12. In an app with no text selection to copy, plain ⌘C for settings is the obvious binding and every competitor does it. |
| `⌘⇧E` | Export | `⌘E` | ◆ | Keep shipped, amend docs/12. Same argument. |

Net: three letters move (`L`, `B`, `⌘B`), five amendments to docs/12, no shipped behaviour
lost except the two panel shortcuts.

## 2. The two live collisions

### 2.1 Workspaces want `1`–`4`, and those are ratings — ⚑ **needs your answer**

This is the only genuinely hard one, and it is hard because both claimants are right.
`1`–`5` for stars is LR-compatible and D35 promises exactly that compatibility; workspace
switching by number is what Capture One and Lightroom's module row both do.

Three ways out, in the order I would rank them:

1. **`⌘1`–`⌘4` for workspaces.** Ratings keep the bare digits. Costs a modifier on a
   frequent action; gains zero disruption. *This is my recommendation.*
2. **Workspaces get no keys at all**, only the toolbar. Honest — you are not switching
   workspaces at key-repeat speed — but it breaks docs/12 §12.12's "switchable from the
   toolbar" being *also* keyable, and it makes the four-workspace IA feel heavier than the
   eight tabs it replaces.
3. **Bare `1`–`4` for workspaces, ratings move to `⌘1`–`⌘5`.** What Capture One does. It
   is also the one option that breaks the single most-pressed keys in a culling app, and
   D35's LR-compatibility promise with them. I would not.

### 2.2 ⌘K is taken — ◆

⌘K is "Keyword the selection" (sidebar, visible control, in `KeyGrammar`). The ⌘K palette
is a near-universal convention now and worth having under that key.

**Recommendation: the palette takes ⌘K; keywording moves to `⌘⇧K`.** Keywording is a
deliberate, low-frequency act performed with the sidebar open — a modifier costs it
nothing. The palette is the opposite and its whole value is that the key is the one your
hands already know from every other tool.

## 3. Speed Edit needs no keys, which is the spec's own best idea

Worth stating because it changes what this pass has to decide. docs/12 §12.4 resolves the
collision with **tap-versus-hold**, not with a reserved letter: *"`E` tapped is loupe view,
`E` held with a scroll is Exposure."* Threshold is 150 ms or any pointer/scroll movement.

So the mapped holds — `E` exposure, `C` contrast, `H`/`S` highlights/shadows, `W`/`T`
temp/tint, `K` look amount, `M` mask amount — **all share letters that already have tap
meanings, deliberately.** Speed Edit is not blocked on this document. What it is blocked on
is the tap/hold discriminator itself, which is real work and belongs in `KeyDispatcher`
beside the existing `holdActive` machinery.

One genuine conflict to note for whoever builds it: shipped `S` is Scopes and shipped `H`
is Histogram, both *toggles*. A tap toggles, a hold edits — which is exactly the design,
but it means the discriminator has to be right or a held `H` flickers the histogram on the
way to adjusting highlights.

## 4. What is specified and simply absent

Not drift — never built. Listed so the pass does not silently bless the gaps:

`I` info overlay · `Tab`/`⇧Tab` chrome collapse · `` ` `` hold magnifier · `V` face strip
(feature unbuilt) · `⌘'` snapshot · `⌘F11`/`⇧F11` second window · `⌃⌘F` full screen.

`Tab`/`⇧Tab` is the one I would build next of these: it is cheap, it is in every
competitor, and after Phase 3 reclaimed the chrome it is the natural finish.

## 5. What happens on a decision

1. docs/12 §12.3's tables are amended in place, each changed row annotated with why —
   docs/00 §3, nothing drifts silently.
2. `KeyGrammar.swift`'s `dispatchedKeys` and printed rows follow. `KeyGrammarTests`
   enforces both directions, so a half-done move fails on Linux rather than in the app.
3. The `Keymap.swift` and `ContentView.swift` comments that defer to "one deliberate pass"
   get deleted, because the pass will have happened.
4. docs/28 items 24 and 30 close, and Phase 4's workspace keys stop being blocked.

**Total keys actually moving under my recommendations: five.** `L`, `B`, `⌘B`, `⌘K`, and
`⌘⇧K` — plus whatever §2.1 lands on.
