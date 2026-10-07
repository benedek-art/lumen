# October 7 — independent ingest landing identities (PS-07/08)

Review of the inode-based landing identity repair found two remaining cases: one source's primary and backup could be hard links to one file in different directories, and a destination could be the source itself or a link to it. Both existing files matched the source digest and were credited as already ingested; the report could enable eject without an independent landing.

Three new runtime regressions ran against the identity-only baseline and produced five failing assertions: shared primary/backup inode, source/self-link credited as a landing, and legacy proven reports incorrectly enabling eject.

Repair:

- Existing collision candidates that alias the source or a destination already landed for this source are not accepted as already present. The existing disambiguation chain walks past them and creates/reuses an independent file. Existing source and alias bytes remain untouched.
- The report independently rejects proven primary/backup results sharing one file and proven results aliasing the source, even when built by legacy/manual code rather than the repaired driver. Its summary explains why an independent copy is still required.
- Ordinary re-ingest still reuses already landed independent files. A rerun of the hardlinked-primary/backup regression reuses the safe disambiguated backup and copies zero bytes.

Validation: native macOS compilation and focused ingest/collision/adversarial tests; final count and log recorded below. These tests use disposable byte fixtures and real hard links. No user originals, mounted cards or applications were modified. This establishes separate file identities; it does not certify separate physical disks, as IngestLocation already documents.

Final validation: 46 tests passed, zero failures (`FileLandingIdentity|IngestCopy|IngestAdversarial`), log `/private/tmp/lumen-oct07-identity-final.log`. `git diff --check` passed. Independent review of root identity/scan changes found no other blocking issue. Root source checker completed exit 0 before these follow-on changes; final combined source checking belongs to integration. Release opt-in policy check passed and rejected 24 unsafe mutations; manual opt-in preserved all six check dependencies, successful-main condition, and exact current-main-tip refusal.
