# S-01/S-02 — ingest landing identity and eject safety

2026-09-22. Isolated branch `codex/lumen-ingest-identity`, based on `6c9c026`.
Bounded repair of distinct-frame collapse and aliased primary/backup destinations.
All fixtures are generated in temporary directories; no private photographs, card
contents or existing user files are used by the tests.

## Failure mechanism

The driver used matching file digests as proof of incremental re-ingest without
tracking which planned landing already owned that file. Two different planned
frames with identical bytes and the same rendered filename could therefore share
one landed file. Every result was marked proven, so the report unlocked eject.

The driver also opened two destination roots independently without checking their
filesystem identity. A primary directory and a symbolic link to it became two
writers in the same directory. Final-name disambiguation avoided overwriting but
created two files in one place and mislabeled one a backup.

A related API-level gap was reproduced in a manually constructed mixed plan: one
frame with a valid destination and one with no destinations produced `planned=2`,
`attempted=2`, `results=1`, `allVerified=true`. Its summary claimed “Ingested 2
frames, every copy verified.” The usual UI planner supplies common destinations
to all frames, so this mixed shape is API-reachable rather than ordinary UI input.

## Contract

Each planned landing needs a distinct filesystem object. Byte equality remains
necessary for re-ingest, but is not sufficient when that object is already claimed
by another landing in the current run. Per-frame destination directories must also
be distinct. An alias of a planned source file must never be accepted as an
independent existing copy, and original source bytes must remain untouched.

`IngestIdentityClaims` remembers resolved paths and filesystem device/file numbers.
The driver claims successful landings across the whole run, checks each frame's
destination-directory identity after creating any missing child directories, and
preserves existing files while disambiguating a newly required independent copy.
Source identities are reserved separately. `IngestReport.allVerified` additionally
rejects reports with duplicate landed objects or landings that alias a source.
These checks do not replace independent byte/length read-back verification.

A frame with no destinations is now explicitly refused before a read or copy is
attempted. Its source is preserved and the refusal blocks eject, even when another
frame in the same plan has a verified copy. It is not added to the attempted-file
or copied-byte counters; the broader accounting defects below remain unchanged.

Two safely landed identical frames may legitimately unlock eject. The old
unconditional-false twin test assumed the collapse still existed; the repaired
tests must check actual landed cardinality/content and separately reject a legacy
report claiming that one landed object proves both frames.

This is directory/file identity, not a new promise of independent physical devices:
different directories on one volume remain allowed. It is not a defence against
an adversarial process continuously replacing mounts, links or file contents
during the copy. Verification retains the existing read-back/digest contract.

`IngestReport.allVerified` is no longer a pure, cheap property: each evaluation
resolves paths and reads filesystem identities for the current source/result
records. In its present form this is up to three metadata lookups per result,
including repeated source lookups when a frame has multiple destinations; symlink
resolution can itself require further filesystem work. The app's eject guard is
on a UI path. Large cards, slow/removable media and network volumes therefore need
separate latency qualification. No cached Boolean is introduced because the public
report and its result URLs remain mutable; changing them must not retain a stale
success verdict. A later immutable completion snapshot/API would need its own
validity contract before safely reducing these repeated checks.

## Qualification

Native macOS 27, arm64, Swift 6.4, optimized tests. Reproducible command:

```sh
swift test -c release --jobs 2 --scratch-path <isolated-scratch> --filter Ingest
```

Before the implementation, all 11 initial new real-filesystem identity cases ran
ordinary-red: 28 failed assertions, exit 1. The first repaired selection passed
48 identity/copy/planner tests. A subsequent 70-test all-ingest run passed before
the additional mixed-empty refusal. The standalone mixed-empty probe then exited
1 with the unsafe success described above, before its narrow repair.

Final expanded run: **71 tests, zero unexpected failures, zero skips**, exit 0.
Eleven inherited expected assertions remain across eight unrelated tests. The
independent mixed-empty probe then exited 0 with `planned=2`, `attempted=1`,
`results=1`, `allVerified=false`, `refusals=1`, and named the uncopied frame.

The final new suite contains 13 tests covering identical frames on primary and
backup, pre-existing matching bytes, repeated source entries, identical roots,
symlink roots with uncreated children, aliases introduced after planning, existing
hard-linked copies, case-aliased names, source aliases/hard links, collapsed legacy
reports, and a mixed destination-less plan. Landed bytes are independently read
with Foundation, source/existing bytes are checked unchanged, and device/inode
cardinality is asserted independently of the driver's helper. Existing mismatch,
cancellation, awkward-length, stranger-file and mid-copy-arrival cases still run.

Four inherited adversarial tests now use ordinary assertions, with no expected
failure: identical twins both survive; a collapsed twin report cannot unlock
eject; aliased directories cannot claim backup redundancy; destination-less frames
are refused. The obsolete unconditional false oracle for a correctly preserved
two-file ingest was replaced with explicit collapsed-report rejection, while the
repaired driver is required to preserve and verify both actual files.

No application UI, RAW/colour pipeline, photos, sidecars or persistent cache state
was changed. Tests use local temporary files on this host; other filesystems and
external-device durability were not qualified. No performance claim is made.

## Remaining ingest issues

Eight inherited expected-failure tests remain, containing eleven failing assertions:

- S-03: counters still include planned bytes for existing copies and failed reads;
  the bar can reach 100% with missing data; a stopped summary can omit a failed
  backup; attempted counts are still described as ingested counts in failure text.
  The short-read safety guard already rejects truncation, but its byte counter is
  still wrong. This repair does not present that inherited quarantine as an
  unfixed truncation/verification defect.
- S-04: a later run does not recognize an earlier disambiguated `-1` copy, so it
  can add another copy and report bytes copied again. Run-local identity claims
  deliberately do not pretend to establish persistent source provenance.

These expected failures remain active and are not loosened or suppressed by new
wrappers. Green results for this bounded repair are not full ingest qualification.
