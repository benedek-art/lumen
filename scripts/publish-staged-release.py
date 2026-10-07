#!/usr/bin/env python3
"""Stage and verify an update before changing the updater's existing release.

GitHub has no atomic release-tag transaction. Readers during promotion may see a
missing feed or a stale URL with mismatched bytes and must refuse (AppUpdater fails
closed). A NEW release object preserves the updater's published_at date ordering.
The old release and assets are archived intact; rollback restores the public feed.
"""
import copy
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import uuid


class APIError(RuntimeError):
    def __init__(self, message, status=None):
        super().__init__(message)
        self.status = status


class RecoveryError(RuntimeError):
    pass


class GitHub:
    def __init__(self, repository):
        self.repository = repository
        self.base = f"repos/{repository}"

    def request(self, method, endpoint, data=None, upload=None, download=None):
        args = ["gh", "api", endpoint, "--method", method,
                "-H", "X-GitHub-Api-Version: 2022-11-28"]
        if upload:
            args += ["-H", "Content-Type: application/zip", "--input", str(upload)]
        elif data is not None:
            args += ["--input", "-"]
        if download:
            args += ["-H", "Accept: application/octet-stream"]
        payload = json.dumps(data).encode() if data is not None else None
        if download:
            with open(download, "wb") as target:
                result = subprocess.run(args, input=payload, stdout=target, stderr=subprocess.PIPE)
            output = b""
        else:
            result = subprocess.run(args, input=payload, capture_output=True)
            output = result.stdout
        if result.returncode:
            message = result.stderr.decode(errors="replace")
            match = re.search(r"HTTP (\d{3})", message)
            raise APIError(message.strip(), int(match.group(1)) if match else None)
        return json.loads(output) if output else None

    def current(self):
        try:
            return self.request("GET", f"{self.base}/releases/tags/dev-latest")
        except APIError as error:
            if error.status == 404:
                return None
            raise

    def release(self, release_id):
        return self.request("GET", f"{self.base}/releases/{release_id}")

    def create(self, tag, commit, body):
        return self.request("POST", f"{self.base}/releases", {
            "tag_name": tag, "target_commitish": commit, "name": f"Candidate {commit}",
            "body": body, "draft": True, "prerelease": True,
        })

    def upload(self, release_id, path, name):
        endpoint = f"https://uploads.github.com/repos/{self.repository}/releases/{release_id}/assets?name={name}"
        return self.request("POST", endpoint, upload=path)

    def download(self, asset_id, path):
        self.request("GET", f"{self.base}/releases/assets/{asset_id}", download=path)

    def create_tag(self, name, object_sha):
        return self.request("POST", f"{self.base}/git/refs", {"ref": f"refs/tags/{name}", "sha": object_sha})

    def edit(self, release_id, values):
        return self.request("PATCH", f"{self.base}/releases/{release_id}", values)

    def tag(self):
        return self.request("GET", f"{self.base}/git/ref/tags/dev-latest")["object"]["sha"]

    def set_tag(self, commit):
        try:
            return self.request("PATCH", f"{self.base}/git/refs/tags/dev-latest", {"sha": commit, "force": True})
        except APIError as error:
            if error.status != 404:
                raise
            return self.request("POST", f"{self.base}/git/refs", {"ref": "refs/tags/dev-latest", "sha": commit})

    def tip(self):
        return self.request("GET", f"{self.base}/git/ref/heads/main")["object"]["sha"]


def digest_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as file:
        while chunk := file.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


class Publisher:
    def __init__(self, api):
        self.api = api

    def verify(self, asset, expected_digest, expected_size):
        if asset.get("state") != "uploaded" or asset.get("size") != expected_size:
            raise RuntimeError("Candidate asset is not a complete uploaded bundle")
        with tempfile.TemporaryDirectory(prefix="lumen-release-verify-") as directory:
            downloaded = Path(directory) / "bundle.zip"
            self.api.download(asset["id"], downloaded)
            if downloaded.stat().st_size != expected_size or digest_file(downloaded) != expected_digest:
                raise RuntimeError("Candidate download does not match the built bundle")

    def publish(self, bundle, commit, candidate_tag, recovery_file=None):
        bundle = Path(bundle)
        if not re.fullmatch(r"[0-9a-f]{40}", commit):
            raise ValueError("A complete lower-case commit SHA is required")
        if self.api.tip() != commit:
            raise RuntimeError("Refusing to stage a commit that is not the current tip of main")
        digest = digest_file(bundle)
        size = bundle.stat().st_size
        if not size:
            raise ValueError("An empty bundle cannot be published")
        body = (f"commit: {commit}\nsha256: {digest}\n"
                "Validated development build; published after explicit RAW and native UI qualification.")
        previous = copy.deepcopy(self.api.current())
        old_tag = self.api.tag() if previous is not None else None
        old_asset = None
        if previous is not None:
            active = [a for a in previous["assets"] if a["name"] == "Lumen.app.zip"]
            if previous.get("draft") or len(active) != 1:
                raise RuntimeError("The current release must expose exactly one known-good Lumen.app.zip")
            old_asset = active[0]
        candidate = self.api.create(candidate_tag, commit, body)
        asset = self.api.upload(candidate["id"], bundle, "Lumen.app.zip")
        self.verify(asset, digest, size)
        # Recheck after potentially slow upload. A staged old candidate is harmless;
        # promotion of a commit that lost main's tip is refused.
        if self.api.tip() != commit:
            raise RuntimeError("Main moved during staging; the current release was not changed")
        if self.current_signature(self.api.current()) != self.current_signature(previous):
            raise RuntimeError("The current release changed while staging; refusing concurrent promotion")
        if previous is None:
            if recovery_file is not None:
                self.write_recovery(recovery_file, {
                    "previous_release_id": None, "candidate_release_id": candidate["id"],
                    "candidate_tag": candidate_tag, "candidate_asset_id": asset["id"],
                    "candidate_commit": commit,
                })
            # Bootstrap exposes only a completely verified draft. An API error can
            # leave it unpublished OR already published; neither case deletes bytes.
            self.api.set_tag(commit)
            self.api.edit(candidate["id"], {"tag_name": "dev-latest", "draft": False,
                                          "name": f"Dev build {commit}", "prerelease": True})
            self.assert_contract(self.api.current(), commit, digest, asset["id"])
            return
        backup_tag = f"dev-previous-{previous['id']}-{candidate['id']}"
        # Archive reference points at the exact original object, including an
        # annotated tag. It is never forced, moved or deleted during recovery.
        self.api.create_tag(backup_tag, old_tag)
        if self.api.tip() != commit:
            raise RuntimeError("Main moved before promotion; the current release was not changed")
        if self.current_signature(self.api.current()) != self.current_signature(previous) or self.api.tag() != old_tag:
            raise RuntimeError("The current release or tag changed before promotion; refusing to replace it")
        if recovery_file is not None:
            self.write_recovery(recovery_file, {
                "previous_release_id": previous["id"], "previous_body": previous["body"],
                "previous_name": previous["name"], "previous_asset_id": old_asset["id"],
                "previous_tag_object": old_tag, "backup_tag": backup_tag,
                "candidate_release_id": candidate["id"], "candidate_tag": candidate_tag,
                "candidate_asset_id": asset["id"], "candidate_commit": commit,
            })
        try:
            self.api.edit(previous["id"], {"tag_name": backup_tag})
            self.api.set_tag(commit)
            self.api.edit(candidate["id"], {"tag_name": "dev-latest", "draft": False,
                                          "name": f"Dev build {commit}", "prerelease": True})
            visible = self.api.current()
            self.assert_contract(visible, commit, digest, asset["id"])
            if not visible.get("published_at") or (previous.get("published_at") and
                self.publication_date(visible) <= self.publication_date(previous)):
                raise RuntimeError("New release did not receive a newer publication date")
        except Exception as original:
            # A failed response may follow a server-applied edit. Re-read both
            # objects; never delete evidence or guess which mutation took effect.
            try:
                candidate_state = self.api.release(candidate["id"])
                if candidate_state["tag_name"] == "dev-latest":
                    self.api.edit(candidate["id"], {"tag_name": candidate_tag, "draft": True})
                self.api.set_tag(old_tag)
                self.api.edit(previous["id"], {"tag_name": "dev-latest"})
                restored = self.api.current()
                if self.current_signature(restored) != self.current_signature(previous) or self.api.tag() != old_tag:
                    raise RuntimeError("Recovery did not restore the previous contract")
            except Exception as recovery:
                raise RecoveryError(
                    f"Promotion failed ({original}); automatic recovery also failed ({recovery}). "
                    f"No release or asset was deleted. Known-good release {previous['id']} asset "
                    f"{old_asset['id']} is retained; archive reference {backup_tag} preserves original tag object {old_tag}. "
                    f"Move candidate release {candidate['id']} back to {candidate_tag} as a draft, "
                    "then restore dev-latest to the original tag object and release. "
                    "Use the saved release-recovery.json artifact for exact IDs and metadata."
                ) from original
            raise RuntimeError(f"Promotion failed; previous release restored: {original}") from original

    @staticmethod
    def write_recovery(path, evidence):
        with open(path, "w") as recovery:
            recovery.write(json.dumps(evidence, indent=2) + "\n")
            recovery.flush()
            os.fsync(recovery.fileno())

    @staticmethod
    def current_signature(release):
        if release is None:
            return None
        return (release["id"], release["body"], release["name"], release.get("draft"), release.get("tag_name"), release.get("published_at"),
                tuple((a["id"], a["name"], a["size"], a["state"]) for a in release["assets"]
                      if a["name"] == "Lumen.app.zip"))

    @staticmethod
    def publication_date(release):
        return datetime.fromisoformat(release["published_at"].replace("Z", "+00:00"))

    @staticmethod
    def assert_contract(release, commit, digest, asset_id):
        lines = release["body"].splitlines()
        if release.get("draft") or release.get("tag_name") != "dev-latest" or f"commit: {commit}" not in lines or f"sha256: {digest}" not in lines:
            raise RuntimeError("Promoted release metadata does not match the verified candidate")
        active = [a for a in release["assets"] if a["name"] == "Lumen.app.zip"]
        if len(active) != 1 or active[0]["id"] != asset_id:
            raise RuntimeError("Promoted release does not expose the verified candidate asset")


def main():
    if os.environ.get("LUMEN_PUBLISH_QUALIFIED") != "true":
        raise RuntimeError("Explicit qualification opt-in is required; nothing was published")
    commit = os.environ["GITHUB_SHA"]
    repository = os.environ["GITHUB_REPOSITORY"]
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Invalid repository")
    tag = f"dev-candidate-{commit[:12]}-{uuid.uuid4().hex[:12]}"
    def interrupted(signum, _frame):
        raise RuntimeError(f"Release publication interrupted by signal {signum}")
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    Publisher(GitHub(repository)).publish(Path("Lumen.app.zip"), commit, tag,
                                          recovery_file=Path("release-recovery.json"))
    print(f"Verified and promoted build {commit}; prior release asset retained")


if __name__ == "__main__":
    main()
