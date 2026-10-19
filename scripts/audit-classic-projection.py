#!/usr/bin/env python3
"""Optional diagnostic using existing release LumenCore, no production sources copied.

Build first: swift build -c release --target LumenCore --scratch-path BUILD
Then pass BUILD/<triple>/release, swiftc and any SDK include/library directories.
Output must be a new directory. Raw cells report quality regressions without retuning.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def compare_core_sources(current, built):
    def manifest(root):
        base = root / 'Sources/LumenCore'
        return {str(path.relative_to(base)): digest(path) for path in sorted(base.rglob('*.swift'))}
    def git(root, *arguments):
        return subprocess.check_output(['git', '-C', str(root), *arguments], text=True).strip()
    current_hashes, built_hashes = manifest(current), manifest(built)
    differences = [name for name in sorted(set(current_hashes) | set(built_hashes))
                   if current_hashes.get(name) != built_hashes.get(name)]
    return {
        'current_root': str(current.resolve()), 'current_head': git(current, 'rev-parse', 'HEAD'),
        'current_worktree_status': git(current, 'status', '--short'),
        'built_checkout_root': str(built.resolve()), 'built_checkout_head': git(built, 'rev-parse', 'HEAD'),
        'built_checkout_worktree_status': git(built, 'status', '--short'),
        'current_core_sha256': current_hashes, 'built_checkout_core_sha256': built_hashes,
        'differing_core_files': differences,
        'denied_differences': differences,
        'qualification': 'current filesystem source snapshots, not a source manifest captured when the linked objects were built; no exact-current-whole-package build claim',
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, required=True)
    parser.add_argument('--built-source-root', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--swiftc', default='swiftc')
    parser.add_argument('--mode', choices=['baseline', 'detail'], default='baseline')
    parser.add_argument('--baseline-csv', type=Path)
    parser.add_argument('--include-dir', type=Path, action='append', default=[])
    parser.add_argument('--library-dir', type=Path, action='append', default=[])
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    build = args.build_dir.resolve()
    source = root / 'scripts/audit-classic-projection.swift'
    engine = Path('Sources/LumenCore/Image/DenoiseEngine.swift')
    comparison = compare_core_sources(root, args.built_source_root.resolve())
    (output / 'current-v-built-core.json').write_text(json.dumps(comparison, indent=2, sort_keys=True) + '\n')
    assert not comparison['denied_differences'], 'rebuild required: changed Core dependencies ' + str(comparison['denied_differences'])
    objects = sorted((build / 'LumenCore.build').glob('*.swift.o'))
    assert objects, 'release LumenCore objects unavailable'
    command = [args.swiftc, '-O', '-I', str(build / 'Modules'), '-I', str(root / 'Sources/CSQLite3')]
    for path in args.include_dir:
        command += ['-Xcc', '-I' + str(path.resolve())]
    for path in args.library_dir:
        command += ['-L', str(path.resolve())]
    command += ['-lsqlite3', str(source), *map(str, objects), '-o', str(output / 'classic-projection')]
    record = {
        'source_commit': subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip(),
        'swift_version': subprocess.check_output([args.swiftc, '--version'], text=True),
        'compile_command': command, 'harness_sha256': digest(source),
        'denoise_source_sha256': digest(root / engine),
        'built_source_root': str(args.built_source_root.resolve()),
        'core_source_comparison': comparison,
        'module_sha256': digest(build / 'Modules/LumenCore.swiftmodule'),
        'object_sha256': {path.name: digest(path) for path in objects},
        'scope': 'actual linked CPU Classic only; analytic independent projections; no GPU, AI model or camera quality acceptance',
    }
    start = time.monotonic()
    compiled = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (output / 'compile.log').write_text(compiled.stdout)
    record['compile_exit'] = compiled.returncode
    record['compile_seconds'] = time.monotonic() - start
    if compiled.returncode == 0:
        execute = [str(output / 'classic-projection'), str(output), args.mode]
        if args.baseline_csv:
            execute.append(str(args.baseline_csv.resolve()))
            record['baseline_csv_sha256'] = digest(args.baseline_csv)
        elif args.mode == 'detail':
            raise ValueError('--baseline-csv is required for detail mode')
        record['execution_command'] = execute
        record['binary_sha256'] = digest(output / 'classic-projection')
        start = time.monotonic()
        result = subprocess.run(execute, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (output / 'execution.log').write_text(result.stdout)
        record['execution_exit'] = result.returncode
        record['execution_seconds'] = time.monotonic() - start
        print(result.stdout, end='')
    (output / 'provenance.json').write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
    print(json.dumps({key: value for key, value in record.items() if key.endswith('exit') or key.endswith('seconds')}))
    return record.get('execution_exit', compiled.returncode)


if __name__ == '__main__':
    raise SystemExit(main())
