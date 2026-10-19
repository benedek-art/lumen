#!/usr/bin/env python3
"""Link the synthetic Swift witness to an existing frozen LumenCore build.
No speed thresholds, private assets or owner-machine/drive assumptions.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-path", type=Path, required=True)
    parser.add_argument("--configuration", choices=["debug", "release"], default="debug")
    parser.add_argument("--swiftc", default=shutil.which("swiftc"))
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--prototype", action="store_true", help="compare existing per-file settlement with the batch helper candidate")
    args = parser.parse_args()
    if not args.swiftc:
        parser.error("swiftc is unavailable; pass --swiftc explicitly")
    if args.output_dir.exists() and (not args.output_dir.is_dir() or any(args.output_dir.iterdir())):
        parser.error("output directory is not empty; preserve existing evidence and choose a new directory")
    root = Path(__file__).resolve().parent.parent
    witness = root / "scripts" / ("SidecarBatchSettlementScaling.swift" if args.prototype else "SidecarSettlementScaling.swift")
    build = args.build_path.resolve()
    modules = sorted({p.resolve() for p in build.glob(f"**/{args.configuration}/Modules/LumenCore.swiftmodule")})
    if len(modules) != 1:
        parser.error(f"expected one built LumenCore.swiftmodule, found {len(modules)}")
    module = modules[0]
    target = module.parent.parent
    objects = sorted((target / "LumenCore.build").glob("*.o"))
    if not objects:
        parser.error("LumenCore object files are absent; build the frozen source first")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    compiler_version = subprocess.check_output([args.swiftc, "--version"], text=True)
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    compile_flags = ["-O", "-I", str(module.parent)]
    if sys.platform.startswith("linux"):
        compile_flags += ["-Xcc", "-fmodule-map-file=" + str(root / "Sources/CSQLite3/module.modulemap")]
    provenance = {
        "recorded_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "git_head": head,
        "working_tree_status": subprocess.check_output(["git", "status", "--short"], cwd=root, text=True),
        "platform": platform.platform(), "compiler": str(args.swiftc), "compiler_version": compiler_version,
        "configuration_directory": args.configuration, "harness_flags": compile_flags,
        "warning": "Harness -O does not change the optimization of the linked existing core objects; no native UI or physical-drive claim.",
        "core_sources": {str(p.relative_to(root)): digest(p) for p in sorted((root / "Sources/LumenCore").rglob("*.swift"))},
        "witness_sha256": digest(witness), "module_sha256": digest(module),
        "objects": {str(p.relative_to(build)): digest(p) for p in objects}, "prototype": args.prototype,
    }
    with tempfile.TemporaryDirectory(prefix="lumen-intent-probe-") as tmp:
        binary = Path(tmp) / "probe"
        command = [args.swiftc, *compile_flags, str(witness), *map(str, objects), "-o", str(binary)]
        subprocess.run(command, check=True, cwd=root)
        provenance["binary_sha256"] = digest(binary)
        result = subprocess.run([str(binary)], capture_output=True, text=True, cwd=root)
        (args.output_dir / "results.tsv").write_text(result.stdout)
        (args.output_dir / "stderr.log").write_text(result.stderr)
        provenance["returncode"] = result.returncode
        provenance["results_sha256"] = digest(args.output_dir / "results.tsv")
    (args.output_dir / "provenance.json").write_text(json.dumps(provenance, indent=2, sort_keys=True) + "\n")
    print(result.stdout, end="")
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
