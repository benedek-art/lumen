# W6 — the RAW corpus lane

**The hole this closes.** Three hundred commits of audit and repair, and this application
has never once been pointed at a file that came out of a camera. Every test in the tree
uses a synthetic frame, a stub `ImageSource`, or a measurement harness.
`Tests/LumenPipelineTests/DraftTruthfulnessTests.swift` says so in its own header — "the
decode (a stub here, identical by construction)" — and it is right to: it is testing the
graph, not the decoder. But nothing else tests the decoder either.

The reason is structural rather than negligent. `AppleRawSource` is `CIRAWFilter`,
`CaptureMetadataReader` is `CGImageSourceCopyPropertiesAtIndex`, and both are
`#if os(macOS)`. The work happens on Linux. `engine-linux` cannot see them,
`swiftc -parse` reads their syntax and nothing else, and `check-swift-surface.py` is a
text tool. The two macOS lanes that could see them — `build-macos` and `test-fast` —
compile them and run tests that hand them nothing.

So an entire class of defect is invisible: a camera whose orientation tag we mishandle,
a decode that comes back at unexpected dimensions, EXIF that does not land, a colour
cast on one manufacturer's files. `PipelineRenderer.applyMetadataPolicy` currently
writes, in a comment, that

> Orientation 1: "the pixels are already the right way up", which is what this renderer
> delivers by construction.

That is a claim about `CIRAWFilter`'s output convention. It has never been checked
against a file whose EXIF orientation is anything but 1. Every file this project has
ever rendered was synthetic and upright.

This document designs the lane that checks it, and `.github/workflows/raw-corpus.yml` is
that lane. **The lane is written and unproven — it has never executed.** §9 says what
that means and what to look at first.

---

## 1. Where the files come from

### 1.1 What raw.pixls.us actually is

`https://raw.pixls.us/` is reachable from this environment and is a real, curated
archive of camera RAW files, run by the PIXLS.US community. Its own front page states
that it "is used by [darktable](https://www.darktable.org/) for regression testing of
[rawspeed](https://github.com/darktable-org/rawspeed) and by
[RawTherapee](http://rawtherapee.com). It is available for any projects that need access
to a library of raw files." That last sentence is the permission this lane runs on, and
it is the site's own words, not an inference.

Everything below was fetched, not recalled.

### 1.2 There is a real manifest, and it is a JSON API

The repository table on the front page is a DataTables widget backed by:

```
https://raw.pixls.us/json/getrepository.php?set=all
```

It returns `application/json`, 1.19 MB, `{"data": [ [...], ... ]}` — **2016 rows** at
the time of writing, nine columns each:

| # | column | content |
|---|---|---|
| 0 | Make | `"Nikon"` |
| 1 | Model | `"Z 30"` |
| 2 | Mode | `"12bit 12bit compressed (Lossless) (3:2)"` — bit depth, compression, aspect |
| 3 | Pixls | nominal megapixels, as a number |
| 4 | Remark | free text |
| 5 | License | an HTML anchor; CC0 links `creativecommons.org/publicdomain/zero/1.0/` |
| 6 | Date | `"2016-12-29"` |
| 7 | Raw | an anchor to the file **plus its sha256 and size** in a nested `<div>` |
| 8 | Exif | an anchor to an exiv2 dump of the file's metadata |

Column 7 is the one that makes this workable. It carries the **sha256 of the file**
inline, which means a corpus can be pinned by content rather than by URL, and a CI cache
can be verified rather than trusted.

A second endpoint, `?set=noncc0`, returns just the Make/Model pairs whose sample is not
CC0 (146 rows). It is not needed — the per-row licence in `set=all` is authoritative and
finer-grained — but it corroborates the count.

### 1.3 The URL scheme

Two routes, both fetched and both working:

- **`https://raw.pixls.us/getfile.php/<id>/nice/<url-encoded filename>`** — the one the
  manifest hands you. Verified: `HTTP 200`, `Content-Length` matching the manifest,
  `Content-Disposition: attachment`, correct `Content-Type` (`image/x-canon-cr2`,
  `image/x-fuji-raf`, `image/x-x3f`, …). No authentication, no cookie required, no
  redirect. Example, fetched in full and checksummed:

  ```
  https://raw.pixls.us/getfile.php/3949/nice/GoPro%20-%20HERO8%20Black%20-%2016bit%20%284%3A3%29.GPR
  → 200, 4 073 376 bytes,
    sha256 bfd992594af380748f3d46e37814dae595356cb6fce182d4188230ca978e6a9f
  ```
  which is **exactly** the digest the manifest carries for row id 3949.

- **`https://raw.pixls.us/data/<Make>/<Model>/<original filename>`** — a plain Apache
  directory index mirroring the whole archive. Fetched and enumerated; e.g.
  `https://raw.pixls.us/data/GoPro/HERO8%20Black/` lists `GOPR0009.GPR`, `GOPR5797.GPR`.
  This route is **not** used, for one specific reason: the filenames there are the
  camera's own (`IMG_6310.CR3`), they are not the manifest's "nice" names, and the
  mapping between the two is not published. `getfile.php` is self-describing and pinned
  by digest; `/data/` would need scraping.

The site also documents full mirrors over git-LFS (`git clone
https://raw.pixls.us/data.lfs.git`) and git-annex (`https://raw.pixls.us/data.annex.git`).
Those are the right route for anybody who wants the whole archive; they are the wrong
route for CI, which wants sixteen specific files.

### 1.4 Licensing — read carefully, because it is not uniform

**1870 of the 2016 rows are CC0 1.0 (public domain dedication).** The remaining **146
are CC BY-NC-SA 4.0** — every one of them carrying the remark `"Import from
rawsamples.ch"`, i.e. inherited from the older rawsamples.ch archive under its own terms.

Counted directly from the manifest:

```
Creative Commons 0 - Public Domain                              1870
Creative Commons - Attribution, Non-Commercial, ShareAlike 4.0   146
```

The non-commercial clause makes those 146 unusable for a project that may ship
commercially, and the ShareAlike clause is a licence-compatibility question nobody wants
in a CI lane. **All sixteen files in the corpus below are CC0**, verified per row from
column 5 of the manifest. The corpus manifest in the workflow records the licence per
file so the check is re-runnable, and the fetch step is written to refuse any row that
is not CC0.

The upload form is the provenance chain for the CC0 claim. A contributor must tick, in
the site's own words:

> I declare that I own full rights to this file and I hereby release it under the CC0
> license into the public domain.

and

> The file is manually copied from card/camera, without using any software like Nikon
> Transfer, and *hasn't been modified in any way*.

The second declaration matters as much as the first for our purposes: it is why these
files still carry the camera's original EXIF, the camera's original orientation tag, and
the camera's own embedded preview — which is what three of the invariants in §5 are
built on. The site also states it does **not** want "Photographs of people, for legal
reasons", which removes the other obvious licensing hazard.

### 1.5 The one thing that gives me pause, stated plainly

`https://raw.pixls.us/robots.txt` reads, in full:

```
User-agent: *
Disallow: /data/
Disallow: /data-unique/
Disallow: /download/
Disallow: /getfile.php
Disallow: /getfile.php/
Disallow: /data.annex.git/
Disallow: /data-unique.annex.git/
Disallow: /data.lfs.git/
Disallow: /data-unique.lfs.git/
```

Every download route is `Disallow`ed to crawlers. This is a robots directive, not a
licence term, and it is aimed at search-engine indexing of a multi-terabyte binary
archive — which is a bandwidth problem, not a permissions one. It sits alongside a front
page that explicitly offers the archive to "any projects that need access to a library
of raw files" and publishes two full-mirror clone commands.

I am not going to pretend that squares itself. **The honest reading is: they do not want
bulk automated traffic, and they do want projects to use the files.** So the lane is
built to be the second thing and not the first:

- a **fixed, hand-picked list of sixteen files**, pinned by sha256 — it can never walk
  the archive;
- fetched **once** and cached (§4), so the steady-state cost to them is zero;
- **sequential, not parallel**, with `--retry` backoff, and a `User-Agent` naming the
  project and the repository so the traffic is attributable;
- **234 MB total**, roughly one photographer's afternoon;
- and §9.4 names the exit: if this is ever unwelcome, the fetch step's URL column is the
  only thing that changes. Mirroring the sixteen files into a release asset on this
  repository — they are CC0, so that is permitted without further ask — makes the lane
  independent of raw.pixls.us entirely, and is what I would do the moment the lane earns
  its keep.

I have not contacted the maintainers. If this lane is ever wired into a per-push
trigger, somebody should.

### 1.6 If it does not work out

It does work out — every URL in §3 was fetched and returned 200 with a matching digest.
But if raw.pixls.us goes away or asks us to stop, the fallbacks in order of preference:

1. **Mirror the sixteen CC0 files as a GitHub release asset on this repository.** CC0
   permits redistribution without condition. 234 MB is well inside a release asset's
   limit, the URL becomes stable forever, and the app already publishes a
   `dev-latest` release, so the mechanism exists. This is the *right* long-term home
   and the only reason it is not the plan today is that it should not be done before
   the corpus has proved it is the right corpus.
2. **The DNG SDK / Adobe DNG sample files** — a much narrower corpus (DNG only), which
   loses X-Trans, CR3, RW2, ORF, IIQ and X3F, i.e. most of the coverage this lane
   exists for.
3. **Shoot our own.** One body, no coverage, and every file becomes a permanent hosting
   obligation. Named for completeness, not recommended.

There is no fourth option that is honest. In particular: I did not find, and do not
believe there is, a manufacturer-run archive of CC0 RAW files spanning makes.

---

## 2. How big, and why that size

A camera RAW is 5–80 MB. A GitHub-hosted runner has ~14 GB free on the boot volume, and
`actions/cache` allows 10 GB per repository with 7-day eviction for unused entries. The
binding constraint is neither disk nor cache: it is **the time cost of a cache miss**,
and the bandwidth cost to a volunteer-run server.

The corpus is **sixteen downloaded files totalling 233.9 MB**, plus **two synthetic
negatives generated on the runner** (§3.2) which cost nothing.

At the ~3 MB/s measured from this environment that is roughly 80 seconds of fetching; a
GitHub runner is normally faster. On a cache hit it is zero. Decoding sixteen frames at
up to 40 MP, rendering each, and exporting each is the real cost of the lane, which is
why the job's timeout is 45 minutes and not 15.

**Why sixteen and not six.** Every file below buys a *decode path*, not a camera. The
whole thesis of the lane is that the defects it hunts are per-manufacturer and
per-container; a corpus that covers four containers tests four containers. Sixteen is
the smallest set I could build that touches every axis in §3 at least twice.

**Why sixteen and not sixty.** Because each additional file costs a full-sensor demosaic
plus a full-sensor export on a rationed macOS runner, and because a corpus nobody can
hold in their head stops being curated and starts being a pile.

---

## 3. The corpus

### 3.1 The sixteen files

All CC0. All verified reachable (`HTTP 200`, `Content-Length` as listed). Digests are
the manifest's, and the one file fetched in full matched exactly.

| # | id | file | MB | what it buys that nothing else does |
|---|---|---|---|---|
| 1 | 1346 | Canon EOS 5D — `RAW (3:2)`.CR2 | 12.25 | The plain CR2 container: lossless-JPEG-compressed Bayer, the single most common RAW on earth by installed base. The control case — if this one is wrong, everything is. |
| 2 | 2102 | Canon EOS 40D — `sRAW2 (sRAW) (3:2)`.CR2 | 5.54 | **The dimensions trap.** sRAW is a half-resolution, already-demosaiced Canon mode: the delivered image (EXIF `PixelXDimension` 1936×1288) is nothing like the sensor array. Any invariant that assumes "delivered dimensions ≈ sensor megapixels" dies here, which is exactly why it is in the corpus — it keeps §5's R-3 honest. |
| 3 | 4671 | Canon EOS RP — `3:2`.CR3 | 7.05 | The modern Canon container (ISO-BMFF, not TIFF). Note: the manifest has **no exiv2 sidecar** for this row — third-party tools still find CR3 hard, which is precisely why an Apple-decoder lane should carry one. |
| 4 | 5812 | Nikon Z 30 — `12bit compressed (Lossless) (3:2)`.NEF | 18.87 | **Orientation 8** (`left, bottom`, rotate 270° CW). A real camera RAW shot in portrait. Sensor array 5600×3728 RGGB (`CFAPattern 0 1 1 2`) — upright it must deliver 3728 wide by 5600 tall. Also: NEF *lossless compressed*. |
| 5 | 824 | Nikon D200 — `12bit uncompressed (3:2)`.nef | 15.36 | The **uncompressed** half of the compression axis, paired with #4 inside one manufacturer's format so the contrast is clean. Sensor 3904×2616, `CFAPattern 1 0 2 1` — **a different Bayer phase from #4**, which is how a hard-coded CFA assumption gets caught. |
| 6 | 2349 | Sony DSLR-A450 — `12bit compressed (3:2)`.ARW | 14.03 | **Orientation 6** (`right, top`, rotate 90° CW) — the *opposite* rotation from #4. One rotation direction cannot distinguish "rotated correctly" from "rotated backwards"; two can. Also the cleanest demonstration of the sensor-array-vs-active-area gap: EXIF says 4592×3056, the CFA IFD says 4608×3072. |
| 7 | 6001 | Fujifilm X-H2 — `14bit compressed (3:2)`.RAF | 27.61 | **X-Trans.** A 6×6 non-Bayer CFA with a completely different demosaic. Also 14-bit, also compressed, also **orientation 6**, also the largest frame in the corpus at 40.9 MP — the memory and time worst case in one file. |
| 8 | 2607 | Panasonic DC-GH5S — `4:3`.RW2 | 18.28 | RW2, whose sensor border and multi-aspect crop are the classic source of a delivered frame that is a few pixels off the array. The same body appears in the archive at 1:1, 3:2, 4:3 and 16:9 — a ready-made expansion if #8 ever fails interestingly. |
| 9 | 5283 | OM System OM-1 — `16bit (4:3)`.ORF | 20.81 | 16-bit ORF, Four Thirds. And a *metadata* case: the Make string is `"OM System"` where the same lineage used to write `"OLYMPUS"`. `CaptureMetadataReader.joinCamera` has a de-stutter rule that has never seen a real Make/Model pair. |
| 10 | 2239 | Pentax K10D — `12bit compressed (3:2)`.PEF | 9.12 | PEF, a container almost nothing outside Pentax writes. Cheap coverage of a decoder nobody exercises. |
| 11 | 1087 | Leica M Monochrom (Typ 246) — `12bit (3:2)`.DNG | 20.69 | **A sensor with no colour filter array at all.** exiv2 confirms `PhotometricInterpretation: Linear Raw`, 5984×4000, no `CFAPattern`. Every assumption about demosaic and white balance is different here, and it is the one file where "a neutral patch stays neutral" is not a tolerance but a near-identity (§5, R-7b). |
| 12 | 4264 | Apple iPhone 12 Pro — `8bit (4:3)`.DNG | 27.84 | **ProRAW: a linear DNG.** `SubImage1` is `Linear Raw`, 12 bits × 3 samples, JPEG-compressed, 4032×3024 — already demosaiced, nothing to interpolate. A third **orientation 6** case, from a producer that is neither a camera maker's DSLR nor a Bayer sensor. |
| 13 | 6168 | Google Pixel 7 Pro — `16bit (4:3)`.dng | 11.68 | **Orientation 3** (180°). Included knowingly as the case the aspect-ratio invariant *cannot* catch (§5, R-4's stated limit) and the preview-correlation invariant can. Bayer BGGR (`CFAPattern 2 1 1 0`), 3882×2924. |
| 14 | 2767 | Phase One P65+ — `IIQ S (4:3)`.IIQ | 11.05 | Medium format, a proprietary container, and a file where exiv2 itself gets confused — it reports the 296×220 *preview* as the primary IFD while `PixelXDimension` says 4490×3364. That confusion is a finding in its own right (§5.1) and the reason no dimension in this corpus is a manifest golden. |
| 15 | 1116 | Sigma DP1 — `3:2`.X3F | 9.84 | **Foveon.** Three stacked photodiode layers, no CFA, and a container Apple has never been documented as supporting. It is here to exercise the *refusal* path on a real file rather than a mangled one. The lane does **not** assert that it fails — see §5, R-2. |
| 16 | 3949 | GoPro HERO8 Black — `16bit (4:3)`.GPR | 3.88 | VC5-compressed GPR, 4000×3000 RGGB — and **orientation 2, a horizontal mirror**. The cheapest file in the corpus and the one carrying the transform that a double-apply makes invisible. Same reasoning as #13. |

**Coverage summary.** Containers: CR2, CR3, NEF, ARW, RAF, RW2, ORF, PEF, DNG, IIQ, X3F,
GPR — twelve. Manufacturers: twelve. CFA: Bayer in three phases (RGGB, GRBG, BGGR),
X-Trans, monochrome (none), Foveon (none), linear/pre-demosaiced (two). Bit depth: 12,
14, 16, and "8bit" as the manifest reads a lossy ProRAW. Compression: uncompressed,
lossless-compressed, lossy-compressed, JPEG-in-DNG, VC5. Orientation: 1 (nine files),
2 (one), 3 (one), 6 (three), 8 (one). Aspect: 3:2 and 4:3.

### 3.2 The two synthetic negatives

Both are generated on the runner from file #1, so they cost no download, need no hosting,
and are byte-deterministic.

- **`truncated.CR2`** — the first 40% of `1346`'s bytes. A plausible interrupted copy: a
  valid TIFF header, a valid IFD chain, and image data that stops mid-stream.
- **`stub.CR2`** — the first 512 bytes of `1346`. A header and nothing else. There is no
  photograph in 512 bytes, which is why this one gets the *hard* refusal assertion and
  the truncated file gets the softer one (§5, R-9).

A deliberately corrupt file that ships in the corpus would be a file somebody has to
host and explain. A file the lane makes for itself from a file it already has is neither.

---

## 4. Caching

**The requirement.** Sixteen RAW files must be fetched once, not on every push.

**The mechanism.** `actions/cache@v4` on a single directory, `.raw-corpus/`, keyed on the
*content of the corpus manifest*:

```
key: raw-corpus-v1-${{ steps.manifest.outputs.digest }}
```

where `digest` is the sha256 of the manifest the workflow just wrote. Change any URL,
digest, or flag and the key changes and the corpus is refetched; change a comment
elsewhere in the workflow and it is not.

`restore-keys` is deliberately **absent**. A partial restore from an older corpus would
hand the test a directory that is missing files or holding the wrong ones, and the
symptom would be a lane that silently tests twelve files instead of sixteen. A miss that
costs eighty seconds is cheaper than a green run that proved less than it claimed.

**Two guards, because a cache is where a bad download goes to live forever.**

1. Every file is checksummed **after download**, and a mismatch deletes the file and
   fails the step. A truncated fetch never reaches the cache.
2. Every file is checksummed **again after restore**, on hits as well as misses. A cache
   entry that has rotted, or that was written by an older and buggier version of this
   lane, is caught before the tests read it. This costs a few seconds of `shasum` over
   234 MB.

**What the cache does not survive.** GitHub evicts cache entries unused for 7 days, and
evicts least-recently-used entries once a repository passes 10 GB. A lane on a
dispatch-only trigger will therefore pay the full fetch most times it runs. That is
acceptable, and it is another argument for §9.4's release-asset mirror once the lane is
wired into a real trigger.

**One constraint worth naming.** This exercise may create only two files, so the corpus
manifest currently lives as a heredoc *inside* the workflow and the cache key is computed
at runtime from what that heredoc writes. When the lane is wired up for real the manifest
should become a committed file — `Tests/LumenPipelineTests/RawCorpus/corpus.tsv` — and
the key should become `hashFiles('Tests/LumenPipelineTests/RawCorpus/corpus.tsv')`, which
is the same semantics with none of the runtime work. The Swift test already reads the
manifest from disk rather than from the environment precisely so that move is a one-line
change.

---

## 5. What it asserts

This is the part that matters, so here is the rule the whole section is built on:

> **Assert invariants, never goldens.** A golden per camera is sixteen maintenance
> obligations that go stale the first time Apple ships a decoder update, and a lane whose
> failures are usually noise is a lane people learn to ignore. Everything below is either
> (a) a property that must hold of *any* photograph from *any* camera, or (b) a
> cross-check between two independent readers of the same bytes.

There is exactly one number pinned per file — the EXIF orientation tag — and §5.1 argues
why that one is not a golden.

### 5.1 Why the manifest carries almost no numbers

The obvious design is to record each file's expected dimensions and assert them. The
corpus itself talks me out of it:

- The manifest's own **Pixls** column is inconsistent: for the EOS 7D's sRAW2 row it
  reports 17.92 MP (the *sensor*), and for the EOS 40D's sRAW2 row it reports 2.49 MP
  (the *delivery*). Two rows of the same kind, two different meanings.
- **exiv2 disagrees with itself across containers.** For the Nikon Z 30 the "primary
  image" IFD is the CFA plane (5600×3728, correct). For the Phase One P65+ the same
  heuristic finds a 296×220 preview, while `Exif.Photo.PixelXDimension` says 4490×3364.
- **Sensor array ≠ active area.** Sony A450: 4608×3072 in the CFA IFD, 4592×3056 in
  `PixelXDimension`. Panasonic's RW2 border and Fuji's X-Trans crop do the same thing by
  different amounts.
- And Apple's decoder may legitimately deliver a different number again after a macOS
  update, which is the entire reason `AppleRawSource` pins a decoder version.

So the dimension assertions are **relationships between two live readings taken on the
runner** — `CGImageSourceCopyPropertiesAtIndex` and `CIRAWFilter.nativeSize` — with
tolerances wide enough for a sensor border and narrow enough to catch a factor of two.

The EXIF orientation tag is different in kind. It is *in the file's bytes*, the file is
pinned by sha256, and the value in the manifest was read by exiv2 — an implementation
that shares no code with ImageIO. Asserting that `CaptureMetadataReader` reads the same
number exiv2 read is a genuine two-implementation cross-check, and it cannot go stale
without the file changing.

### 5.2 The assertions

Every one runs against every file in the corpus, and the failure message always names the
file and the manufacturer, because "an assertion failed" is not actionable when sixteen
cameras share a test.

---

#### Tier 0 — liveness. Applies to all eighteen files, negatives included.

**R-0 — It never crashes.** Opening and decoding every file in the corpus completes
without trapping. This one is structural rather than an `XCTAssert`: a trap kills the
test binary and XCTest reports the abort. It is listed because it is the *first* thing
this lane buys — nothing in the tree has ever handed `CIRAWFilter` a byte it did not
generate itself.

**R-1 — It never hangs.** Every open-decode-render completes inside a per-file wall-clock
ceiling of **120 seconds**. Implemented as a watchdog: the work runs on a background
queue, the test waits on a semaphore with a timeout, and a timeout fails the test with
the filename. A hung decoder otherwise consumes the job's whole 45 minutes and reports
nothing at all, which is strictly worse than a red build. The watchdog deliberately does
*not* try to kill the hung thread — it cannot, safely — it just fails and lets the
process exit.

**R-2 — Refuse or decode, never something in between.** For every file, exactly one of:
`AppleRawSource(url:)` throws, or `decode(...)` returns `nil`, or it returns a `CIImage`
with a **finite, non-empty, non-infinite** extent whose origin and size are all finite.
There is no third state. `CIImage.extent` can legitimately be `CGRect.infinite`, and an
infinite extent that reaches the graph is how you get an allocation of infinite size —
`DecodeMaterializer` already guards it, and this is the assertion that the guard is
reached from a real file.

Note what R-2 does **not** say: it does not say which files must decode. Sigma's X3F and
GoPro's GPR are in the corpus because Apple probably cannot open them, and asserting
that would be asserting Apple's support matrix — which moves, in the direction of more
support, and would turn a *good* macOS update into a red build. The lane **logs** which
files decoded and which refused, into the job summary, so a change in the support matrix
is visible as a diff rather than as a failure.

---

#### Tier 1 — geometry.

Let **E** = `(width, height)` from `CGImageSourceCopyPropertiesAtIndex` →
`kCGImagePropertyPixelWidth/Height`; **N** = `AppleRawSource.nativePixelSize`; **D** =
the extent of the frame `PipelineRenderer` delivers for an untouched recipe.

**R-3 — Delivered dimensions are plausible against the file's own EXIF.**

- `1 ≤ N.width, N.height ≤ 65535`. Catches zero, negative, and garbage.
- Pixel counts agree within 10%: `0.90 ≤ (N.w·N.h) / (E.w·E.h) ≤ 1.11`.
  *Why 10%:* the widest legitimate gap measured in this corpus is Sony's 4608×3072 vs
  4592×3056 — 1.0%. Panasonic's border and Fuji's crop are the same order. 10% is five
  times the worst real case and still refuses a factor-of-two error, which is what a
  draft decode leaking into the settle path, or a half-resolution scale factor, looks
  like.
- **Up to a transpose**, each dimension matches: `{N.w, N.h}` matches `{E.w, E.h}`
  pairwise within 10% under *some* pairing. This is orientation-blind on purpose — it
  says "same picture, same size, possibly sideways" and leaves "and the right way up" to
  R-4, so the two failures are distinguishable in the log.

**R-4 — Orientation is applied exactly once.** Let `o` be the file's EXIF orientation.

- If `o ∈ {5,6,7,8}` (the 90°-class transforms): the delivered frame's long edge must
  have **swapped**. `(D.w > D.h) == (E.w < E.h)`.
- If `o ∈ {1,2,3,4}`: it must **not** have swapped. `(D.w > D.h) == (E.w > E.h)`.

Four files carry a 90°-class tag — Nikon Z 30 (8), Sony A450 (6), Fujifilm X-H2 (6),
Apple iPhone 12 Pro (6) — from four manufacturers, in **both** rotation directions. A
single direction cannot tell "rotated correctly" from "rotated backwards"; two can.
Applying the rotation **twice** yields a 180° transform, which restores the original
aspect, so R-4 catches a double-apply on all four.

**The limit of R-4, stated rather than hidden.** It cannot catch a double-apply of
orientation 2 (mirror) or 3 (180°), because both are self-inverse in aspect. The corpus
carries one of each — GoPro (2) and Pixel 7 Pro (3) — and R-5 is what covers them.

**R-5 — The render agrees with the camera's own embedded preview.** Every one of these
files carries a maker JPEG preview that the camera already oriented. Take the largest
available preview through `CGImageSourceCreateThumbnailAtIndex`, orient it by its own
EXIF, reduce both it and the delivered render to a 32×32 luma grid, normalise each to
zero mean and unit variance, and require **Pearson r ≥ 0.6**.

*Why this is an invariant and not a golden:* nothing per-camera is stored. The assertion
is that two views of the same photograph — the camera's and ours — agree about where the
sky is. It is deliberately loose on values: the preview carries the camera's tone curve
and ours is flat and scene-referred, so the numbers differ a lot and the *structure* does
not. A 90° error drops r to near zero; a 180° error or a mirror drops it hard on any
frame that is not accidentally symmetric.

*Honesty:* r ≥ 0.6 is a first guess. The lane **logs the measured r for every file on
every run, passes included**, so the threshold can be set from sixteen real numbers after
the first green run instead of being guessed at twice. And when no preview ≥ 256 px is
available the assertion is *skipped with a logged note*, never failed — the absence of a
preview is the file's property, not a defect in ours.

---

#### Tier 2 — the render is a picture.

Render each decodable file at 1024 px on the long edge through `PipelineRenderer`, with
the recipe the app would start it on, and read back `RGBAf`.

**R-6 — Not black, not white, not NaN.**

- **Every** sample is finite. Not a spot check — all 1024×~683×4 of them. NaN
  propagates from edge handling and from `0/0` in a normalisation, and it lives at the
  borders where a spot check does not look. One non-finite value fails, and the message
  reports the pixel coordinate.
- Mean display-referred luminance in `[0.02, 0.85]`.
- P95 − P5 luminance ≥ `0.02`. A flat grey frame passes a mean test and is still a dead
  decode; this is what says the frame has *content*.
- Fewer than 90% of pixels within 1/255 of 0.0, and fewer than 90% within 1/255 of 1.0.

*Why these bounds are safe:* raw.pixls.us's submission guidelines ask, in the site's own
words, for images that are "Well-lit, pattern-full, scenery, low ISO. For example, a
daylight landscape", "Image in focus and properly exposed". The corpus is drawn from a
pool curated to be ordinary daylight photographs. Bounds this wide pass a genuinely dark
scene and a genuinely bright one, and refuse a zeroed buffer, a clamped buffer, and a
NaN-poisoned graph. They are alarms, not measurements.

**R-7 — A neutral patch stays neutral.**

The site explicitly refuses colour-target submissions ("**NOT** a color target"), so
there is no grey card to sample and no fixed coordinate to trust. The patch is therefore
**found, not addressed**:

1. Reduce the render to a grid of 16×16 blocks.
2. Keep blocks whose mean luminance is in `[0.20, 0.60]` — mid-tones, where a cast shows.
3. Among those, keep the quartile with the lowest within-block variance — flat regions:
   sky, road, wall, shadow.
4. Of those, take the block with the **smallest** chroma, convert its mean to CIELAB
   under D65, and assert `sqrt(a*² + b*²) < 20`.

*What that number is for.* It is not a colour-accuracy claim; 20 ΔC is enormous. It is a
**cast alarm**: a swapped red/blue channel (a BGGR sensor read as RGGB — and the corpus
carries both phases), a missing or wrong camera colour matrix, or a white balance applied
twice moves the *most neutral block in the frame* far past 20. A warm sunset does not,
because we are taking the minimum over the whole frame and every one of these images is a
daylight landscape containing something grey.

*Honesty:* this is the assertion most likely to fail for an uninteresting reason. So the
same discipline as R-5 — **log the measured chroma for every file on every run, passes
included**, and set the real threshold from sixteen measurements after the first green
run. Shipping it loose and tightening from evidence is the only version of this that
does not either miss the defect or cry wolf.

**R-7b — The monochrome file is monochrome.** For the file the manifest flags `mono`
(Leica M Monochrom, which exiv2 confirms has no `CFAPattern` and a `Linear Raw`
photometric interpretation), the assertion is far stronger: the chroma of the *median*
block, not the minimum, must be `< 2`. A monochrome sensor cannot produce colour. If
this frame has colour in it, something downstream is inventing it — and that is a defect
that would be invisible on every other file in the corpus.

---

#### Tier 3 — export and metadata.

**R-8 — An export reopens with the dimensions it claims.** Export each decodable file to
a 16-bit TIFF at a fixed 1600 px long edge, then reopen the written file with a fresh
`CGImageSourceCreateWithURL` and assert:

- the file exists and is non-empty;
- the reopened container's `kCGImagePropertyPixelWidth/Height` equal the reopened
  `CGImage`'s actual `width`/`height`. **This is the assertion the codebase most needs.**
  `PipelineRenderer.applyMetadataPolicy` reconciles those fields deliberately, with a
  long comment explaining that carrying the source's forward makes "a resized file that
  claims the original's size", and nothing has ever checked it through a real encoder;
- the reopened `kCGImagePropertyOrientation` is `1` or absent. The renderer sets it to 1
  on purpose — "the pixels are already the right way up". If a container round-trips
  something else, every viewer in the world rotates a Lumen export a second time;
- the long edge is 1600 ± 1, and the aspect matches **D**'s aspect within 1%.

**R-9 — The negatives are refused, at two severities.**

- `stub.CR2` (512 bytes): **hard refusal.** `AppleRawSource(url:)` must throw, or
  `decode` must return `nil`. There is no photograph in 512 bytes; a decoder returning an
  image here is definitively wrong, and so is a Lumen that accepts it.
- `truncated.CR2` (40% of a valid file): **refused, or a picture that passes Tier 2.**
  This is the softer form on purpose, and the reason is worth writing down: I cannot
  assert that Apple never recovers a partial frame, but I *can* assert what Lumen does
  with the result — and a half-decoded frame is 60% black, which R-6's "fewer than 90% of
  pixels near zero" rule refuses. So "half-decoded" is forbidden by the tier-2
  assertions rather than by a special case. Which branch was taken is logged either way,
  because a change in that branch is a change in Apple's decoder and worth seeing.
- Both are also subject to R-0 and R-1: whatever happens, it happens without a crash and
  inside 120 seconds. On malformed input those two are the assertions most likely to earn
  their keep.

**R-10 — EXIF lands.** `CaptureMetadataReader.read(url:)` returns non-nil for every
decodable file, and:

- `camera` is non-empty and contains the manufacturer token the manifest records,
  case-insensitively. This is what checks `joinCamera`'s de-stutter rule against sixteen
  real Make/Model pairs — including `"NIKON CORPORATION"` + `"NIKON Z 30"` (must collapse
  to `"NIKON Z 30"`) and `"OM System"` + `"OM-1"` (must *not* collapse to `"OM-1"`);
- `width` and `height` are non-nil and equal **E** exactly — they come from the same
  dictionary, so this checks the plumbing, not the decoder;
- `orientation` equals the manifest's exiv2-read value. The one pinned number, argued in
  §5.1;
- `captureAt` is non-nil and falls between 1998-01-01 and now + 1 day. A date parse that
  silently fails leaves nil; an offset bug puts it in 1970 or 2038. This is the invariant
  form of "the date lands" — no per-file golden, just a window nothing plausible escapes;
- `iso`, *if present*, is in `25...409600`. Not required to be present: some files
  legitimately carry none, and `AppleRawSource` already documents nil as the honest
  answer that falls back to the base-ISO noise profile. The count of files that
  answered is logged.

**R-11 — The decoder pin exists and is stable within a run.** `pinnedDecoderVersion` is
non-nil for every decodable file, and two `AppleRawSource` instances over the same file
report the same pin. The value is **logged, never asserted against a constant** — it
legitimately changes when Apple ships a new decoder, and pinning it would turn a macOS
runner-image bump into a red build with no defect behind it. But it is emitted into the
job summary so that change is *visible*, which is the whole premise of D50.

### 5.3 What is deliberately not asserted

- No per-camera dimension, colour, or pixel goldens. Not one.
- No assertion that any particular format decodes. The support matrix is Apple's.
- No cross-run comparison. Two runs on different runner images are two different
  decoders; a drift check across them would be measuring macOS.
- Nothing about *quality*. This lane asks "is it a photograph of the right thing, the
  right way up, the right size, with its metadata attached". Whether it is a *good*
  render is what the proof sweep and the parity goldens are for.

---

## 6. Where the test code goes

A new file, `Tests/LumenPipelineTests/RawCorpusTests.swift`. **It is not created by this
exercise** — the sketch below is the shape it should take, and it is here rather than
under `Tests/` on purpose.

It belongs in `LumenPipelineTests` because that is the only target that compiles
`AppleRawSource`, `CaptureMetadataReader` and `PipelineRenderer`. Note the consequence:
`gpu-parity.yml` runs `swift test --filter LumenPipelineTests`, so once this file exists
it joins that lane unless it skips itself — which is exactly why the corpus gate below is
`XCTSkipUnless` on an environment variable and not a hard failure.

And the counterweight, which is the trap `ci.yml` already names about `CSQLite3` — "a
green run that had never built a third of LumenCore is the same shape as a check that
cannot fail": **a skipped corpus must not read as a pass in the corpus lane.** So the
workflow greps the log for the expected file count and fails if the tests skipped
(§7, step 9). The skip protects developers; the grep protects the lane.

```swift
// RawCorpusTests.swift
// The first tests in this project's history that open a file a camera made.
//
// Everything else in Tests/ uses a synthetic frame or a stub ImageSource — correctly,
// because those tests are about the graph. The consequence is that CIRAWFilter,
// CGImageSourceCopyPropertiesAtIndex and the whole decode path have never seen a byte
// this repository did not generate. A camera whose orientation tag we mishandle, a
// decode that returns unexpected dimensions, EXIF that does not land, a cast on one
// manufacturer's files: none of it is visible to any existing lane.
//
// THESE ARE INVARIANTS, NOT GOLDENS, and the distinction is the whole design. A golden
// per camera is sixteen maintenance obligations that go stale the first time Apple ships
// a decoder update, and a lane whose failures are usually noise is a lane people learn
// to ignore. Every assertion below is either a property that must hold of any photograph
// from any camera, or a cross-check between two independent readers of the same bytes.
// The one pinned number is the EXIF orientation tag, which is in the file's bytes, and
// the file is pinned by sha256 — see docs/audit-2026-09/w6/raw-corpus-plan.md §5.1.
//
// The corpus is not in the repository. It is 234 MB of CC0 RAW files fetched and cached
// by .github/workflows/raw-corpus.yml, which points LUMEN_RAW_CORPUS at the directory.
// Without that variable every test here SKIPS, so `swift test` on a developer machine
// and the gpu-parity lane are unaffected. The corpus lane greps its own log for the
// expected file count, because a check that skips silently is a check that cannot fail.
#if os(macOS)
import CoreGraphics
import CoreImage
import ImageIO
import XCTest
@testable import LumenCore
@testable import LumenPipeline

final class RawCorpusTests: XCTestCase {

    // MARK: The manifest

    /// One row of corpus.tsv. Deliberately thin: a path, a digest, a manufacturer token,
    /// the EXIF orientation exiv2 read, and flags. No dimensions, no colours — see §5.1
    /// for why every number that could go stale is measured on the runner instead.
    struct Entry {
        let id: String            // raw.pixls.us row id, for the failure message
        let path: URL
        let makeToken: String     // "NIKON", "OM", "FUJIFILM" — matched case-insensitively
        let orientation: Int      // what exiv2 read; 0 when the file carries no tag
        let isMono: Bool          // no CFA at all — R-7b applies instead of R-7
        let isNegative: Bool      // synthetic; may not decode by construction
        let isHardNegative: Bool  // 512-byte stub: MUST refuse
        let label: String         // "Nikon Z 30 · NEF 12-bit lossless · orientation 8"
    }

    /// Skips the whole class when the corpus is absent. Empty is refused as well as
    /// missing, for the same reason `ControlProofTests.isRecording` refuses empty:
    /// GitHub sets an unset expression to "", and a check that reads mere presence
    /// reads that as yes.
    ///
    /// AND IT PRINTS `corpus-file: <id>` FOR EVERY ROW IT RESOLVES. That line is a
    /// contract with the lane, not debug output: the workflow's last step greps the log
    /// for it and fails when the count is below the manifest's, because a test class
    /// gated on an environment variable that never arrives skips silently and reads
    /// exactly like a pass. `ci.yml` names that shape about CSQLite3 — "a green run that
    /// had never built a third of LumenCore is the same shape as a check that cannot
    /// fail". If this line is ever renamed, rename it in raw-corpus.yml in the same
    /// commit.
    private func corpus() throws -> [Entry] {
        let raw = ProcessInfo.processInfo.environment["LUMEN_RAW_CORPUS"] ?? ""
        try XCTSkipUnless(!raw.trimmingCharacters(in: .whitespaces).isEmpty,
                          "LUMEN_RAW_CORPUS unset — corpus lane only")
        // …parse <dir>/corpus.tsv, resolve paths, XCTSkipUnless the file exists…
        fatalError("sketch")
    }

    // MARK: The watchdog (R-1)

    /// Run `work` on a background queue and fail if it has not finished in `seconds`.
    ///
    /// A hung decoder otherwise eats the job's entire 45 minutes and reports nothing,
    /// which is strictly worse than a red build: a cancelled lane tells you the runner
    /// died, not which file killed it. This does NOT attempt to kill the hung thread —
    /// it cannot do that safely — it fails, names the file, and lets the process exit.
    private func withWatchdog<T>(_ seconds: TimeInterval, _ label: String,
                                 _ work: @escaping () -> T) throws -> T {
        var result: T?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async { result = work(); done.signal() }
        guard done.wait(timeout: .now() + seconds) == .success, let result else {
            XCTFail("\(label): still decoding after \(Int(seconds))s — hung, not slow")
            throw XCTSkip("hung")
        }
        return result
    }

    // MARK: Tier 0 — liveness

    /// R-2. Every file lands in exactly one of two states: refused, or an image with a
    /// finite, non-empty extent. There is no third state, and `CGRect.infinite` — which
    /// `CIImage` produces legitimately elsewhere — is the third state this catches.
    ///
    /// What this does NOT assert: which files decode. The X3F and the GPR are in the
    /// corpus because Apple probably cannot open them, and asserting that would be
    /// asserting Apple's support matrix — which moves in the direction of MORE support,
    /// so pinning it would turn a good macOS update into a red build. The outcome per
    /// file is written to the evidence sheet instead, where a change shows as a diff.
    func testEveryFileEitherDecodesCleanlyOrRefusesCleanly() throws { }

    // MARK: Tier 1 — geometry

    /// R-3. Two independent readings of the same file must agree about how big the
    /// picture is: ImageIO's EXIF dictionary, and CIRAWFilter's nativeSize.
    ///
    /// Within 10%, and only up to a transpose. Both slacks are measured, not guessed:
    /// the Sony A450 in this corpus reports 4608×3072 in its CFA IFD and 4592×3056 in
    /// PixelXDimension — a masked sensor border, 1.0%. Ten percent is five times the
    /// worst real case and still refuses a factor of two, which is what a draft decode
    /// leaking into the settle path looks like. The transpose is left to R-4 so the two
    /// failures are distinguishable in the log rather than one confused message.
    func testDeliveredDimensionsArePlausibleAgainstTheFilesOwnEXIF() throws { }

    /// R-4. THE ONE THIS LANE WAS BUILT FOR.
    ///
    /// `PipelineRenderer.applyMetadataPolicy` states, in a comment, that the pixels it
    /// delivers "are already the right way up… by construction". That is a claim about
    /// CIRAWFilter's output convention, and until this test runs it has never been
    /// checked against a file whose orientation tag is anything but 1.
    ///
    /// Four files carry a 90°-class tag, from four manufacturers, in BOTH directions:
    /// Nikon Z 30 (8), Sony A450 (6), Fujifilm X-H2 (6), Apple iPhone 12 Pro (6). One
    /// direction cannot tell "rotated correctly" from "rotated backwards". Two can.
    /// Applying the rotation twice is a 180° transform, which restores the aspect — so
    /// a double-apply fails here too.
    ///
    /// The limit, stated rather than hidden: a double-applied MIRROR (orientation 2,
    /// the GoPro) or 180° (orientation 3, the Pixel 7 Pro) is invisible to an aspect
    /// test, because both are self-inverse in aspect. R-5 is what covers those two.
    func testAPortraitFrameComesOutPortrait() throws { }

    /// R-5. The camera's own embedded preview is a second opinion about the same
    /// photograph, and it costs nothing to ask for it.
    ///
    /// Both reduced to a 32×32 luma grid, normalised, correlated; r ≥ 0.6. Loose on
    /// values on purpose — the preview carries the camera's tone curve and our render is
    /// flat and scene-referred, so the numbers differ a great deal and the STRUCTURE
    /// does not. A 90° error takes r to near zero; a mirror or a 180° takes it hard
    /// negative on anything not accidentally symmetric.
    ///
    /// 0.6 is a first guess and is treated as one: the measured r for every file is
    /// written to the evidence sheet on every run, passes included, so the threshold can
    /// be set from sixteen real numbers rather than guessed at twice. A file with no
    /// preview ≥ 256 px SKIPS with a note — the absence of a preview is that file's
    /// property, not a defect in ours.
    func testTheRenderAgreesWithTheCamerasOwnPreview() throws { }

    // MARK: Tier 2 — the render is a picture

    /// R-6. Every sample finite — all of them, not a spot check, because NaN arrives
    /// from edge handling and from 0/0 in a normalisation and lives at the borders where
    /// a spot check does not look. Then: mean luminance in [0.02, 0.85]; P95−P5 ≥ 0.02,
    /// because a flat grey frame passes a mean test and is still a dead decode; and
    /// under 90% of pixels pinned at either end.
    ///
    /// These are alarms, not measurements. They are safe this wide because the corpus is
    /// drawn from a pool raw.pixls.us curates for "well-lit… daylight landscape…
    /// properly exposed" — its words. A genuinely dark scene passes; a zeroed buffer, a
    /// clamped buffer and a NaN-poisoned graph do not.
    func testTheRenderIsNeitherBlankNorPoisoned() throws { }

    /// R-7. The patch is FOUND, not addressed: raw.pixls.us explicitly refuses colour
    /// targets, so there is no grey card and no coordinate worth trusting. 16×16 blocks;
    /// keep mid-luminance ones; keep the flattest quartile; take the least chromatic;
    /// require CIELAB chroma < 20.
    ///
    /// Twenty is enormous, and that is the point — this is a CAST ALARM, not a colour
    /// accuracy claim. A swapped red/blue (this corpus carries RGGB, GRBG and BGGR), a
    /// missing camera matrix, or a white balance applied twice moves the frame's most
    /// neutral block far past 20. A warm sunset does not, because we take the minimum
    /// over the whole frame. Measured chroma for every file goes to the evidence sheet
    /// so the threshold gets set from data after the first green run.
    func testTheMostNeutralPatchInEachFrameIsNeutral() throws { }

    /// R-7b. The Leica M Monochrom has no colour filter array — exiv2 confirms no
    /// CFAPattern and a Linear Raw photometric interpretation. So the assertion is not a
    /// tolerance, it is close to an identity: the MEDIAN block's chroma < 2, not the
    /// minimum's. A monochrome sensor cannot produce colour, and if this frame has any,
    /// something downstream is inventing it — which would be invisible on every other
    /// file in the corpus.
    func testAMonochromeSensorProducesNoColour() throws { }

    // MARK: Tier 3 — export and metadata

    /// R-8. Export to 16-bit TIFF at 1600 px, reopen through a fresh CGImageSource, and
    /// require the container's claimed dimensions to equal its own pixels'.
    ///
    /// This is the assertion `applyMetadataPolicy` most needs. It reconciles those
    /// fields deliberately — its comment warns that carrying the source's forward makes
    /// "a resized file that claims the original's size and a straightened file that
    /// viewers rotate a second time" — and no test has ever put that through an encoder
    /// and read it back. The orientation check is the other half: the renderer writes 1
    /// on purpose, and a container that round-trips anything else means every viewer
    /// rotates a Lumen export a second time.
    func testAnExportReopensWithTheDimensionsItClaims() throws { }

    /// R-9. Two negatives at two severities, and the split is deliberate.
    ///
    /// The 512-byte stub gets a HARD refusal: there is no photograph in 512 bytes, so a
    /// decoder that returns an image is definitively wrong and so is a Lumen that takes
    /// it. The 40%-truncated file gets the softer form — refused, OR a picture that
    /// passes Tier 2 — because I cannot assert that Apple never recovers a partial
    /// frame, only what Lumen does with the result. A half-decoded frame is 60% black,
    /// and R-6's near-zero rule is what forbids it. Which branch was taken is logged
    /// either way: a change there is a change in Apple's decoder.
    func testATruncatedFileIsRefusedRatherThanHalfDecoded() throws { }

    /// R-10. `joinCamera` has a de-stutter rule that has never seen a real Make/Model
    /// pair. This corpus has sixteen, including the two that make the rule non-trivial:
    /// "NIKON CORPORATION" + "NIKON Z 30" must collapse to "NIKON Z 30", and
    /// "OM System" + "OM-1" must NOT collapse to "OM-1".
    ///
    /// The date is asserted as a WINDOW (1998 → now+1d), not a value: a parse that fails
    /// silently leaves nil and an offset bug lands in 1970 or 2038, and both are caught
    /// without pinning anything that could go stale. ISO is asserted only if present —
    /// AppleRawSource already documents nil as the honest answer.
    func testTheMetadataReaderGetsRealFilesRight() throws { }

    /// R-11. The pin exists and does not move within a run. Its VALUE is written to the
    /// evidence sheet and never asserted against a constant: it legitimately changes
    /// when Apple ships a new decoder, and pinning it would make a runner-image bump a
    /// red build with no defect behind it. Visible, not enforced — which is what D50
    /// actually needs.
    func testTheDecoderVersionPinIsPresentAndStable() throws { }
}
#endif
```

---

## 7. The lane

`.github/workflows/raw-corpus.yml`, written to match the conventions of `ci.yml`,
`gpu-parity.yml` and `proof.yml`: `macos-15`, a per-ref `concurrency` group with
`cancel-in-progress`, `set +e` around the test command with the same `grep` sequence over
the log, and comments that carry the reasoning rather than the mechanics.

**The trigger.** `workflow_dispatch`, plus `push` on **its own file only**. Not on
`Sources/**`, and not called from any other workflow. Two reasons, pulling opposite ways
and resolved this way on purpose:

- This repository has been burned twice by dispatch-only lanes. `gpu-parity.yml`'s header
  records that its predecessor "was NEVER dispatched: not once in the project's history",
  during which "eleven commits touched Sources/LumenPipeline… one of them changing a blur
  radius by a factor of three". `proof.yml` records the same failure mode. A lane that
  requires a human at the Actions tab does not run.
- But this lane is **unproven** (§9). Putting an unproven lane on `Sources/**` today
  means its first red build is probably its own bug, on somebody else's push, and the
  fastest way to teach a team to ignore a lane is to make its first three failures
  noise.

So it triggers on changes to itself — the `gpu-parity.yml` precedent, "its own file is in
the paths so the push that lands a lane change also exercises it" — and §9.3 names the
exact condition for widening it.

**The steps, and why each exists.**

1. `actions/checkout@v4`.
2. **Write the corpus manifest.** A heredoc, for now (§4's constraint). It is the single
   source of truth for URLs, digests, orientations and flags, and both the fetcher and
   the Swift test read it — so they cannot disagree.
3. **Compute the manifest digest** into a step output. This is the cache key. Keying on
   the manifest rather than on the workflow file means editing a comment does not throw
   away 234 MB.
4. **`actions/cache@v4`** on `.raw-corpus/`, no `restore-keys` — §4 argues why a partial
   restore is worse than a miss.
5. **Fetch on miss.** Sequential, `--retry 3 --retry-delay 5 --fail`, a `User-Agent`
   naming the repository, refusing any manifest row not marked CC0, checksumming each
   file and deleting-and-failing on mismatch.
6. **Verify on hit as well as miss.** Re-checksum all sixteen. A cache is where a bad
   download goes to live forever.
7. **Build the two negatives** with `head -c`. Deterministic, free, and nobody has to host
   a corrupt file.
8. **Write the inventory into `$GITHUB_STEP_SUMMARY`** — sixteen rows, so a human opening
   the run sees what was actually tested before reading any assertion.
9. **Run `swift test --filter RawCorpusTests`** with `LUMEN_RAW_CORPUS` set, then grep the
   log the way `ci.yml` does — compile errors, the `Executed N tests` summary, failing
   test names, first failure per test.
10. **The guard on the guard.** A separate step, `if: always()`, that counts
   `corpus-file:` lines in the log and fails when there are fewer than the manifest has
   rows. This is not belt-and-braces. `ci.yml` already names the trap about `CSQLite3` —
   a green run that never built the code "is the same shape as a check that cannot
   fail" — and a test class gated on an environment variable is exactly that shape: if
   `LUMEN_RAW_CORPUS` fails to reach the process, if the manifest path moves, or if
   `--filter` matches nothing after a rename, every assertion above silently does not
   run and the lane reports green having proved nothing. The expected count comes from
   the manifest, not from a constant, so adding a file to the corpus cannot leave the
   guard behind. The `corpus-file:` line is therefore a contract between the Swift and
   the YAML; renaming it requires touching both.
11. **Upload the evidence sheet**, `if: always()`. Per file: decoded or refused, E, N, D,
    orientation in and out, the measured preview correlation, the measured neutral-patch
    chroma, the decoder pin. This is what turns R-5 and R-7's guessed thresholds into
    measured ones, and it is the artifact somebody reads when a camera starts failing.

---

## 8. Risks

| risk | severity | what the design does about it |
|---|---|---|
| **The lane has never run.** Written from source reading and remote metadata; no macOS runner has executed a line of it. | **high** | §9. Stated at the top of this document, in the workflow header, and in the report. |
| `CIRAWFilter.nativeSize` may be in sensor order rather than oriented — unknown, and unknowable from Linux. | high | R-3 is written orientation-blind (up to a transpose) so it passes under either convention; R-4 pins the convention separately, so the first run *answers the question* instead of failing ambiguously. |
| raw.pixls.us `robots.txt` disallows the download routes. | medium | §1.5, in full and unspun. Fixed pinned list, cached, sequential, attributable UA, and §9.4's release-asset mirror as the exit. |
| `getfile.php` numeric ids might not be stable. | medium | Every file is pinned by sha256. If an id ever points at different bytes the fetch fails loudly rather than testing the wrong photograph. |
| R-7's chroma threshold is a guess and may fail on a legitimately warm frame. | medium | Logged on every run including passes; set from data after the first green run. Same for R-5's correlation floor. |
| A camera newer than the runner's macOS decodes on nobody's machine. | medium | R-2 does not require any file to decode; refusals are logged, not failed. The corpus deliberately favours mature bodies for exactly this reason — the newest is the 2022 X-H2. |
| A 234 MB cache miss on a rationed macOS runner. | low | ~80 s at the measured rate, once. §9.4 removes even that. |
| The new test file joins `gpu-parity.yml`'s `--filter LumenPipelineTests` and slows it. | low | `XCTSkipUnless` on `LUMEN_RAW_CORPUS`, which that lane does not set. Costs one skipped-test line. |
| Sixteen large decodes exhaust the runner's memory. | low | Tests run one file at a time and release each source; `AppleRawSource` already bounds its own decode cache by bytes. If it bites, the lever is a smaller render size, not fewer files. |
| A macOS update changes the decoder and moves every measurement. | low by design | Nothing is asserted against a stored render. The pin is logged so the change is visible. |

---

## 9. Honesty: what I could not verify

**9.1 The lane is unproven. It has never executed.** Everything here was written on a
Linux box from source reading plus fetched remote metadata. What *is* verified: every URL
in §3 returns HTTP 200 with the `Content-Length` listed; one file (the GoPro) was fetched
in full and its sha256 matched the manifest exactly; the licence of all sixteen was read
from the manifest's own licence column; the orientation tags in §3 were read from
raw.pixls.us's exiv2 sidecars, not assumed. What is **not** verified: that any of these
files decodes on macOS at all, that `swift test --filter RawCorpusTests` compiles, that
the YAML is accepted by GitHub's run-creation service — `proof.yml`'s header records that
this repository has seen valid YAML rejected there before, with three runs reporting
"failure" and zero jobs.

**9.2 The first thing to check.** Dispatch the lane and read step 8's inventory before
reading any assertion. It answers the only question that matters first: **which of the
sixteen files did `CIRAWFilter` open at all?** Everything downstream is conditional on
that. My expectation, stated so it can be wrong: the twelve mainstream camera files open;
the Sigma X3F does not; the GoPro GPR probably does not; the Phase One IIQ is genuinely
uncertain. If fewer than ten open, the corpus is wrong, not the assertions.

**The second thing:** R-3 versus R-4 on the four rotated files. That pair tells you
whether `CIRAWFilter.nativeSize` is oriented or in sensor order, which is a fact this
project does not currently know and which several caches and ladders quietly assume an
answer to.

**9.3 When to widen the trigger.** Three consecutive green dispatched runs, with the
evidence sheet from each read by a human, and R-5's and R-7's thresholds re-set from
those measurements. Then add `Sources/LumenPipeline/**` and
`Sources/LumenCore/Catalog/**` to the `push` paths. Not before: an unproven lane on a
per-push trigger teaches people to ignore it.

**9.4 What I would do next, in order.**
1. Dispatch it. Read the inventory.
2. Set R-5 and R-7 from the measured numbers.
3. Mirror the sixteen CC0 files as a release asset on this repository and repoint the
   manifest's URL column. This removes the runtime dependency on a volunteer-run server,
   removes the `robots.txt` question entirely, and makes the corpus reproducible if
   raw.pixls.us ever changes.
4. Then, and only then, widen the trigger.

**9.5 One thing I chose not to do.** I did not contact the raw.pixls.us maintainers to
ask whether a CI lane is welcome. That is a human's message to send, not mine, and §1.5
is written so whoever sends it has the facts in front of them.
