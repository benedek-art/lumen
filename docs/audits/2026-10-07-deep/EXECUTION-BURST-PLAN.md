# Integrated-suite burst query-plan failure

Commit `06d47bf`, branch `codex/lumen-oct07-persistence`. Test-only change to `Tests/LumenCoreTests/CullingEvidenceCatalogTests.swift`; production CatalogStore and indexes unchanged.

## Diagnosis

An independent direct unsandboxed run of the existing full class reproduced one failure among 18 tests. The integrated optimized failure and the isolated failure both report:

`SCAN photo USING INDEX photo_aperture | SEARCH f EXISTS USING INTEGER PRIMARY KEY (rowid=?) | USE TEMP B-TREE FOR ORDER BY`

The tested invariant is already satisfied: the correlated frame-score lookup searches its integer primary key by bound rowid. The assertion demanded the contiguous text `SEARCH f USING INTEGER PRIMARY KEY`, which misses SQLite's inserted EXISTS annotation. Runtime SQLite version from the actual test database is **3.54.0**.

This is a version-coupled test assertion, not evidence of a new missing index or a query regression. SQLite explicitly warns that EXPLAIN QUERY PLAN text may change between releases; SEARCH identifies a subset lookup whereas SCAN identifies an iteration. [SQLite's official EQP documentation](https://www.sqlite.org/eqp.html)

## Repair and retained strength

The replacement requires the complete detail `SEARCH f [optional EXISTS] USING INTEGER PRIMARY KEY (rowid=?)`. It does not accept a generic SEARCH, a different alias, a range index, or a scan. Existing anti-frame-score-SCAN assertions remain. The actual plan check now covers both inBurst and notInBurst.

An added negative control deliberately changes the direct equality to `f.photo_id + 0 = photo.id`, losing its sargable primary-key condition without changing mathematical equality. Runtime plan:

`SCAN photo USING COVERING INDEX photo_aperture | SEARCH f EXISTS USING COVERING INDEX frame_score_burst (burst_id>?)`

The checker rejects that degraded access plan. It also rejects a fabricated SCAN and a lookup against the wrong alias; both known old/current primary-key detail forms are accepted.

## Verification

- Baseline full class, direct unsandboxed xctest: 18 tests, 1 failure.
- Repaired class, native isolated build/test with 2 jobs: 19 tests, 0 failures.
- Repaired full class, direct unsandboxed xctest: 19 tests, 0 failures (~0.49 s).
- `git diff --check` passed.

Logs: `/private/tmp/lumen-oct07-persistence-burst-baseline.log`, `/private/tmp/lumen-oct07-persistence-burst-green.log`, `/private/tmp/lumen-oct07-persistence-burst-final-direct.log`.

No test is skipped, no index performance constraint removed, and no production query rewritten to satisfy a diagnostic string.
