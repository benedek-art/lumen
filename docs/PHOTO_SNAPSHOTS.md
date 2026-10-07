# Per-photo named snapshots (APP-12)

The History panel now saves, restores and deletes named snapshots for the primary
photograph. Snapshots use existing `edit.kind = snapshot` catalog rows, not global
session-only recipes. Names must be nonempty, at most 120 characters, and unique
within that photo. Another photo may use the same name.

Creation finishes any active slider gesture and captures the current complete
recipe. Snapshots remain non-current immutable rows. Restore reads the row scoped
to its photo, validates its pipeline and payloads, and applies a normal edit to
that photo alone. Undo returns to the prior settings. A changed selection or recipe
while the asynchronous read is in flight refuses restoration rather than replacing
newer edits. Selection loads use request epochs so delayed rows cannot appear under
a different photo. Deletion confirms in the UI, targets only that named row, and
keeps the current edit and content-addressed blobs.

Brush/heal painting and creative LUT blob references must have matching disk bytes;
a warm render cache does not authorize a missing or damaged dependency. Brush and
LUT payloads must decode, and future pipeline/painting versions are refused. The
existing catalog backups include every edit row and blob shelf, so paintings used
only by snapshots survive backup and restoration. Named snapshots depend on the
catalog and its backups; they are not exported into the working recipe's sidecar.

Validation used real temporary SQLite catalogs and actual AppState methods without
RAW files. The expanded native macOS suite passed 106 related tests; the final
focused suite passed 20 tests after scoped failure-message changes. Tests cover
creation, duplicate names, two-photo isolation, selection-load races, targeted
restore, undo/redo, deletion, relaunch, shared blob preservation, missing-payload
creation/restoration refusal, and snapshot-only painting backup recovery. Logs:
`/private/tmp/lumen-photo-snapshots-tests.log` and
`/private/tmp/lumen-photo-snapshots-final.log`.

The macOS targets compile. Interactive native UI and real RAW qualification remain
future checks; no image formation math or release publication was changed.
