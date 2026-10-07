# Qualified release staging and recovery

Publication remains manual: dispatch CI on the current main commit with
`publish_validated_release` enabled only after RAW and native UI qualification.
All six required validation jobs must pass. Ordinary builds cannot publish.

The publisher creates a draft candidate, uploads `Lumen.app.zip`, downloads the
uploaded asset and checks its complete SHA-256 and size before changing the public
feed. It checks main again after upload and immediately before promotion. A new
release object supplies a new `published_at` value, which the installed updater
uses to decide whether an update is newer. Its body retains the updater's exact
`commit:` and `sha256:` contract.

For an existing feed, a unique archive tag preserves the exact original Git object
(including annotated tags). The previous release, metadata and asset remain intact.
Recovery IDs and metadata are flushed to `release-recovery.json` before public
mutations; CI uploads this file even when publication fails. Qualification runs
serialize without cancelling an active publisher.

GitHub has no atomic release/tag transaction. During promotion the feed can be
briefly unavailable. A client that downloaded old metadata and then follows the
fixed asset URL after promotion receives different bytes and refuses their SHA;
the installer does not accept a mismatched bundle. Errors trigger reread and
rollback, including an applied mutation whose response was lost. If recovery also
fails, the job reports original tag object, release/asset IDs and recovery steps.
No candidate, archive or evidence is automatically deleted on uncertain outcomes.
A killed runner or network outage can leave the old release archived and require
manual recovery; continuous availability is not guaranteed.

Use the uploaded recovery artifact to locate both releases. Return the candidate
to its original candidate tag as a draft, restore `dev-latest` to the saved original
Git object, then return the previous release to `dev-latest`. Do not move the
archive tag: it must continue pointing to the original object. Check that the
fixed asset and original metadata are visible afterward. A failed bootstrap has
no previous release to restore; retain the verified candidate and inspect its
actual visibility before retrying.

Archives and candidates deliberately accumulate. A separate retention policy is
deferred; automatic deletion is outside this repair. Publication has only been
validated with offline API mocks, not a live release or installation.

Validation: `python3 scripts/test-publish-staged-release.py` exercises successful
promotion, before/after-applied failures, recovery failures, publication ordering,
stale main, concurrent release changes, missing fixed assets, SHA refusal and
explicit opt-in. `ruby scripts/check-release-policy.rb` rejects 31 unsafe workflow
mutations while preserving the previous 24 negative controls.
