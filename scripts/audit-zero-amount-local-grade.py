#!/usr/bin/env python3
"""Run three existing tests with verbatim LocalPlan on portable Swift.

Requires a release LumenCore build with testing enabled, matching its .swiftmodule
and object files. Example preparation (in the source checkout to qualify):
  swift build -c release --target LumenCore -Xswiftc -enable-testing --scratch-path BUILD

This is NOT a macOS/GPU test. The wrapper copies LocalPlan from RenderGraph.swift,
uses the existing LumenCore module/objects, copies ZeroAmountLocalGradeTests.swift,
removes only its os(macOS) guard, substitutes Foundation for CoreImage, removes the
LumenPipeline import, and omits the GPU-only test method. No test math is copied or
rewritten. The normal native test file remains the GPU qualification path.

The RED helper comes from an explicit Git baseline; GREEN comes from the current
working file. Both use the SAME current test bodies. Every wrapper, compiler log,
execution log and file/object digest is retained in the selected output directory.
Infrastructure failure is an error, never an expected RED. There are no retries.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

BASELINE = "f970bf265bd76d0499d0b3fe0ff1e4e8a2adf960"
GRAPH = "Sources/LumenPipeline/RenderGraph.swift"
TEST = "Tests/LumenPipelineTests/ZeroAmountLocalGradeTests.swift"
PORTABLE_TESTS = [
    "testZeroAmountBypassesAllLocalColourTablesWhilePositiveAmountStaysLive",
    "testZeroAmountTablePathPreservesExtendedChannels",
    "testGroupZeroKeepsDonorSelectionAndResolvesItsAdjustmentToIdentity",
]


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def helper(source: str) -> str:
    start = source.index("struct LocalPlan {")
    end = source.index("/// Uploaded cube bytes", start)
    return source[start:end]


def wrapper(plan: str, tests: str) -> str:
    start = tests.index("    func testBothRenderersPreserveExtendedPixelsAtZeroAmount()")
    end = tests.index("    func testGroupZeroKeepsDonorSelectionAndResolvesItsAdjustmentToIdentity()", start)
    portable = tests[:start] + tests[end:]
    for old, new in [
        ("#if os(macOS)\n", ""), ("#endif\n", ""),
        ("import CoreImage\n", "import Foundation\n"),
        ("@testable import LumenPipeline\n", ""),
    ]:
        if portable.count(old) != 1:
            raise ValueError("Test wrapper substitution is no longer unique: " + old.strip())
        portable = portable.replace(old, new, 1)
    names = re.findall(r"    func (test\w+)\(", portable)
    if names != PORTABLE_TESTS:
        raise ValueError("Portable test discovery changed; inspect extraction before updating")
    registrations = ",\n".join(
        f'("{name}", ZeroAmountLocalGradeTests.{name})' for name in names)
    main = "\nXCTMain([testCase([\n" + registrations + "\n])])\n"
    return "import Foundation\n@testable import LumenCore\n" + plan + portable + main


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", default="swiftc")
    parser.add_argument("--build-dir", required=True, type=Path,
                        help="Architecture/config directory containing Modules and LumenCore.build")
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--baseline-ref", default=BASELINE)
    parser.add_argument("--library-dir", action="append", default=[], type=Path)
    parser.add_argument("--include-dir", action="append", default=[], type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    build = args.build_dir.resolve()
    output = args.output_dir.resolve()
    if output.exists() and any(output.iterdir()):
        raise ValueError("Choose an empty output directory; existing audit evidence is never overwritten")
    output.mkdir(parents=True, exist_ok=True)
    objects = sorted((build / "LumenCore.build").glob("*.o"))
    module = build / "Modules/LumenCore.swiftmodule"
    if not objects or not module.is_file():
        raise ValueError("Matching prebuilt LumenCore objects/module were not found")
    baseline = subprocess.check_output(
        ["git", "show", args.baseline_ref + ":" + GRAPH], cwd=root, text=True)
    source = (root / GRAPH).read_text()
    tests = (root / TEST).read_text()
    environment = os.environ.copy()
    if args.library_dir:
        existing = environment.get("LD_LIBRARY_PATH", "")
        directories = [str(p.resolve()) for p in args.library_dir]
        environment["LD_LIBRARY_PATH"] = os.pathsep.join(directories + ([existing] if existing else []))
    environment["SWIFT_BACKTRACE"] = "enable=no"
    version = subprocess.check_output([args.swiftc, "--version"], env=environment, text=True)
    object_digests = {p.name: digest(p.read_bytes()) for p in objects}
    evidence = {
        "kind": "portable-verbatim-LocalPlan-XCTest; no GPU execution",
        "working_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
        "baseline_ref": args.baseline_ref,
        "swift_version": version.strip(),
        "source_sha256": digest(source.encode()), "test_sha256": digest(tests.encode()),
        "baseline_graph_sha256": digest(baseline.encode()),
        "core_module_sha256": digest(module.read_bytes()),
        "core_object_sha256": object_digests,
        "core_objects_digest": digest(json.dumps(object_digests, sort_keys=True).encode()),
        "core_source_revision": "not inferred from prebuilt module; rebuild at intended source before qualification",
        "omitted_native_test": "testBothRenderersPreserveExtendedPixelsAtZeroAmount",
        "tests": PORTABLE_TESTS, "runs": {},
    }
    evidence_path = output / "provenance.json"

    def save() -> None:
        evidence_path.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")

    save()
    for label, graph, expected_exit, expected_failures in [
        ("red", baseline, 1, 6), ("green", source, 0, 0),
    ]:
        swift = output / ("zero-grade-" + label + ".swift")
        binary = output / ("zero-grade-" + label)
        swift.write_text(wrapper(helper(graph), tests))
        command = [args.swiftc, "-I", str(build / "Modules"),
                   "-I", str(root / "Sources/CSQLite3")]
        for directory in args.include_dir:
            command += ["-Xcc", "-I" + str(directory.resolve())]
        for directory in args.library_dir:
            command += ["-L", str(directory.resolve())]
        command += ["-lsqlite3", str(swift)] + [str(p) for p in objects] + ["-o", str(binary)]
        compiled = subprocess.run(command, env=environment, text=True, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT)
        (output / (label + "-compile.log")).write_text(compiled.stdout)
        record = {"compile_command": command, "compile_exit": compiled.returncode,
                  "wrapper_sha256": digest(swift.read_bytes())}
        evidence["runs"][label] = record
        save()
        if compiled.returncode != 0:
            print(f"{label}: compilation failed; see {label}-compile.log", file=sys.stderr)
            return 1
        result = subprocess.run([str(binary)], env=environment, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (output / (label + "-execution.log")).write_text(result.stdout)
        record["execution_exit"] = result.returncode
        record["execution_log_sha256"] = digest(result.stdout.encode())
        summary = f"Executed 3 tests, with {expected_failures} failures (0 unexpected)"
        qualified = result.returncode == expected_exit and summary in result.stdout
        record["qualified_expected_outcome"] = qualified
        save()
        print(f"{label}: exit={result.returncode}, expected_outcome={qualified}")
        if not qualified:
            print(f"{label}: infrastructure or unexpected assertion outcome; inspect {label}-execution.log", file=sys.stderr)
            return 1
    print("Portable RED/GREEN complete. Native CPU/GPU test remains separate.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print("Portable audit setup failed: " + str(error), file=sys.stderr)
        raise SystemExit(1)
