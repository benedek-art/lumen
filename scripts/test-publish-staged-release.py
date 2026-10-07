#!/usr/bin/env python3
"""Offline publication failure tests. No gh process, network, release or tag mutation."""
import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import os

spec = importlib.util.spec_from_file_location("publisher", Path(__file__).with_name("publish-staged-release.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
COMMIT = "a" * 40
OLD_TAG = "b" * 40  # May identify an annotated tag object: restore exactly this object.


class FakeGitHub:
    def __init__(self, fail=None, after=False, rollback_fail=None, bootstrap=False):
        self.fail, self.after, self.rollback_fail = fail, after, rollback_fail
        self.failed = False
        self.calls = []
        self.head = COMMIT
        self.tag_object = OLD_TAG
        self.old = {"id": 1, "name": "Known-good", "body": "commit: old\nsha256: oldhash",
                    "draft": False, "tag_name": "dev-latest", "published_at": "2025-01-01T00:00:00Z", "assets": []}
        self.releases = {} if bootstrap else {1: self.old}
        self.bytes = {10: b"known-good"}
        if not bootstrap:
            self.old["assets"] = [self.asset(10, "Lumen.app.zip", self.bytes[10])]
        self.refs = {}
        self.new_publication = "2026-10-07T00:00:00Z"
        self.next_asset = 11
        self.tip_reads = 0
        self.move_main_at = None
        self.change_release_at = None
        self.current_reads = 0
        self.corrupt_download = False

    @staticmethod
    def asset(asset_id, name, data):
        return {"id": asset_id, "name": name, "size": len(data), "state": "uploaded", "download_count": 0}

    def operation(self, name, action):
        self.calls.append(name)
        first_failure = name == self.fail and not self.failed
        recovery_failure = self.failed and name == self.rollback_fail
        if first_failure and not self.after:
            self.failed = True
            raise RuntimeError(f"injected {name}")
        if recovery_failure:
            raise RuntimeError(f"recovery unavailable at {name}")
        result = action()
        if first_failure:
            self.failed = True
            raise RuntimeError(f"lost response after applied {name}")
        # Every visible release has internally consistent bytes and checksum.
        # Old URLs fetched across promotion can mismatch; updater rejects that SHA.
        for release in self.releases.values():
            if release["tag_name"] == "dev-latest" and not release["draft"] and release["id"] == 2:
                assets = [a for a in release["assets"] if a["name"] == "Lumen.app.zip"]
                assert len(assets) == 1
                import hashlib
                assert f"sha256: {hashlib.sha256(self.bytes[assets[0]['id']]).hexdigest()}" in release["body"].splitlines()
        return copy.deepcopy(result)

    def tip(self):
        self.tip_reads += 1
        if self.tip_reads == self.move_main_at:
            self.head = "c" * 40
        return self.head

    def current(self):
        self.current_reads += 1
        if self.current_reads == self.change_release_at:
            self.old["body"] = "external qualified build"
        # Real clients can download concurrently. Counters are not publication state.
        if self.old["assets"]:
            self.old["assets"][0]["download_count"] += 1
        return copy.deepcopy(next((r for r in self.releases.values()
                                   if r["tag_name"] == "dev-latest" and not r["draft"]), None))

    def release(self, release_id):
        return copy.deepcopy(self.releases[release_id])

    def create(self, tag, commit, body):
        def apply():
            release = {"id": 2, "name": "Candidate", "body": body, "draft": True,
                       "tag_name": tag, "published_at": None, "assets": []}
            self.releases[2] = release
            return release
        return self.operation("create", apply)

    def upload(self, release_id, path, name):
        def apply():
            asset = self.asset(self.next_asset, name, Path(path).read_bytes())
            self.bytes[self.next_asset] = Path(path).read_bytes()
            self.next_asset += 1
            self.releases[release_id]["assets"].append(asset)
            return asset
        return self.operation("upload_candidate" if release_id == 2 else "upload_staged", apply)

    def download(self, asset_id, path):
        Path(path).write_bytes(b"corrupt" if self.corrupt_download else self.bytes[asset_id])

    def create_tag(self, name, object_sha):
        return self.operation("archive_tag", lambda: self.refs.update({name: object_sha}))

    def edit(self, release_id, values):
        point = ("archive_release" if release_id == 1 and values["tag_name"] != "dev-latest"
                 else "restore_old" if release_id == 1
                 else "restore_candidate" if values.get("draft") else "publish")
        def apply():
            self.releases[release_id].update(values)
            if values.get("draft") is False:
                self.releases[release_id]["published_at"] = self.new_publication
        return self.operation(point, apply)

    def tag(self):
        return self.tag_object

    def set_tag(self, commit):
        def apply():
            self.tag_object = commit
        return self.operation("restore_tag" if commit == OLD_TAG else "set_tag", apply)


class StagedReleaseTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="lumen-release-mock-")
        self.addCleanup(self.scratch.cleanup)
        self.bundle = Path(self.scratch.name) / "Lumen.app.zip"
        self.bundle.write_bytes(b"new validated bundle")
        self.recovery = Path(self.scratch.name) / "recovery.json"

    def publish(self, api):
        module.Publisher(api).publish(self.bundle, COMMIT, "dev-candidate-test", self.recovery)

    def assert_old_restored(self, api):
        active = api.current()
        self.assertEqual(active["name"], "Known-good")
        self.assertEqual(active["body"], "commit: old\nsha256: oldhash")
        self.assertEqual(api.tag(), OLD_TAG)
        visible = [a for a in active["assets"] if a["name"] == "Lumen.app.zip"]
        self.assertEqual([a["id"] for a in visible], [10])
        self.assertEqual(api.bytes[10], b"known-good")

    def test_success_stages_verified_draft_before_touching_current_and_keeps_old_bytes(self):
        api = FakeGitHub()
        self.publish(api)
        self.assertEqual(api.calls[:3], ["create", "upload_candidate", "archive_tag"])
        self.assertLess(api.calls.index("upload_candidate"), api.calls.index("archive_release"))
        module.Publisher.assert_contract(api.current(), COMMIT, module.digest_file(self.bundle), 11)
        self.assertEqual(api.tag(), COMMIT)
        self.assertEqual(api.bytes[10], b"known-good")
        self.assertEqual(api.old["assets"][0]["name"], "Lumen.app.zip")
        self.assertEqual(api.refs["dev-previous-1-2"], OLD_TAG)
        self.assertGreater(module.Publisher.publication_date(api.current()), module.Publisher.publication_date(api.old))
        self.assertFalse(api.releases[2]["draft"])
        self.assertTrue(self.recovery.exists())

    def test_create_and_upload_failures_never_change_known_good_release(self):
        for point in ["create", "upload_candidate", "archive_tag"]:
            for after in [False, True]:
                with self.subTest(point=point, after=after):
                    api = FakeGitHub(fail=point, after=after)
                    with self.assertRaises(RuntimeError):
                        self.publish(api)
                    self.assert_old_restored(api)
                    self.assertNotIn("archive_release", api.calls)

    def test_corrupt_candidate_never_reaches_promotion(self):
        api = FakeGitHub()
        api.corrupt_download = True
        with self.assertRaisesRegex(RuntimeError, "does not match"):
            self.publish(api)
        self.assert_old_restored(api)
        self.assertNotIn("archive_release", api.calls)

    def test_every_promotion_failure_rolls_back_even_when_response_was_lost_after_apply(self):
        for point in ["archive_release", "set_tag", "publish"]:
            for after in [False, True]:
                with self.subTest(point=point, after=after):
                    api = FakeGitHub(fail=point, after=after)
                    with self.assertRaisesRegex(RuntimeError, "previous release restored"):
                        self.publish(api)
                    self.assert_old_restored(api)
                    self.assertEqual(len(api.bytes), 2, "Recovery evidence must not be deleted")
                    self.assertEqual(api.refs["dev-previous-1-2"], OLD_TAG)

    def test_rollback_failure_retains_evidence_and_reports_actionable_asset_and_tag_ids(self):
        api = FakeGitHub(fail="publish", rollback_fail="restore_old")
        with self.assertRaises(module.RecoveryError) as issue:
            self.publish(api)
        self.assertIn("release 1 asset 10", str(issue.exception))
        self.assertIn(OLD_TAG, str(issue.exception))
        self.assertIn("candidate release 2", str(issue.exception))
        self.assertEqual(api.bytes[10], b"known-good")
        self.assertTrue(self.recovery.exists())

    def test_main_drift_refuses_staging_or_promotion(self):
        for at in [1, 2, 3]:
            with self.subTest(at=at):
                api = FakeGitHub()
                api.move_main_at = at
                with self.assertRaises(RuntimeError):
                    self.publish(api)
                self.assert_old_restored(api)
                self.assertNotIn("archive_release", api.calls)

    def test_concurrent_release_change_is_not_rolled_back_or_overwritten(self):
        for at in [2, 3]:
            api = FakeGitHub()
            api.change_release_at = at
            with self.assertRaisesRegex(RuntimeError, "changed"):
                self.publish(api)
            self.assertEqual(api.current()["body"], "external qualified build")
            self.assertNotIn("archive_release", api.calls)

    def test_bootstrap_only_exposes_verified_candidate(self):
        api = FakeGitHub(bootstrap=True)
        self.publish(api)
        module.Publisher.assert_contract(api.current(), COMMIT, module.digest_file(self.bundle), 11)
        self.assertEqual(api.calls, ["create", "upload_candidate", "set_tag", "publish"])

    def test_bootstrap_publish_failure_before_or_after_apply_never_exposes_unverified_bytes(self):
        for after in [False, True]:
            api = FakeGitHub(bootstrap=True, fail="publish", after=after)
            with self.assertRaises(RuntimeError):
                self.publish(api)
            if api.current() is not None:
                module.Publisher.assert_contract(api.current(), COMMIT, module.digest_file(self.bundle), 11)
            self.assertEqual(api.bytes[11], self.bundle.read_bytes())

    def test_missing_fixed_asset_refuses_before_staging(self):
        api = FakeGitHub()
        api.old["assets"] = []
        with self.assertRaisesRegex(RuntimeError, "exactly one"):
            self.publish(api)
        self.assertEqual(api.calls, [])

    def test_older_publication_date_rolls_back(self):
        api = FakeGitHub()
        api.new_publication = "2024-01-01T00:00:00Z"
        with self.assertRaisesRegex(RuntimeError, "newer publication date"):
            self.publish(api)
        self.assert_old_restored(api)

    def test_recovery_evidence_precedes_first_public_mutation(self):
        api = FakeGitHub()
        operation = api.operation
        def checked(name, action):
            if name == "archive_release":
                import json
                evidence = json.loads(self.recovery.read_text())
                self.assertEqual(evidence["previous_tag_object"], OLD_TAG)
                self.assertEqual(evidence["previous_asset_id"], 10)
                self.assertEqual(evidence["candidate_asset_id"], 11)
            return operation(name, action)
        api.operation = checked
        self.publish(api)

    def test_all_rollback_failures_keep_bytes_and_archive_object(self):
        for point in ["restore_candidate", "restore_tag", "restore_old"]:
            api = FakeGitHub(fail="publish", after=True, rollback_fail=point)
            with self.assertRaises(module.RecoveryError):
                self.publish(api)
            self.assertEqual(api.bytes[10], b"known-good")
            self.assertEqual(api.refs["dev-previous-1-2"], OLD_TAG)
            self.assertTrue(self.recovery.exists())

    def test_bootstrap_tag_unknown_outcome_never_exposes_incomplete_candidate(self):
        for after in [False, True]:
            api = FakeGitHub(bootstrap=True, fail="set_tag", after=after)
            with self.assertRaises(RuntimeError):
                self.publish(api)
            self.assertIsNone(api.current())
            self.assertTrue(api.releases[2]["draft"])
            self.assertEqual(api.bytes[11], self.bundle.read_bytes())

    def test_explicit_opt_in_is_required_before_any_api_construction(self):
        for value in [None, "false", "TRUE"]:
            env = {} if value is None else {"LUMEN_PUBLISH_QUALIFIED": value}
            with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(module, "GitHub") as api:
                with self.assertRaisesRegex(RuntimeError, "opt-in"):
                    module.main()
                api.assert_not_called()

    def test_recovery_file_failure_prevents_public_mutation(self):
        api = FakeGitHub()
        with mock.patch.object(module.Publisher, "write_recovery", side_effect=OSError("disk full")):
            with self.assertRaisesRegex(OSError, "disk full"):
                self.publish(api)
        self.assert_old_restored(api)
        self.assertNotIn("archive_release", api.calls)

    def test_download_failure_preserves_previous_release(self):
        api = FakeGitHub()
        with mock.patch.object(api, "download", side_effect=RuntimeError("network loss")):
            with self.assertRaisesRegex(RuntimeError, "network loss"):
                self.publish(api)
        self.assert_old_restored(api)
        self.assertNotIn("archive_tag", api.calls)

    def test_empty_bundle_and_incomplete_sha_are_refused_before_any_mutation(self):
        api = FakeGitHub()
        self.bundle.write_bytes(b"")
        with self.assertRaises(ValueError):
            self.publish(api)
        self.assertEqual(api.calls, [])
        with self.assertRaises(ValueError):
            module.Publisher(api).publish(self.bundle, "short", "candidate")
        self.assertEqual(api.calls, [])


if __name__ == "__main__":
    unittest.main()
