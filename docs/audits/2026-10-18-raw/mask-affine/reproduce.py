#!/usr/bin/env python3
"""Generate portable XCTest inputs in a NEW directory; do not compile/run them.

The historical prepare-portable.py is retained unchanged as executed evidence.
This safe entry point never writes into the archive or overwrites existing files.
"""
import argparse
from pathlib import Path
import re

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source-root', type=Path, required=True)
parser.add_argument('--output-dir', type=Path, required=True)
args = parser.parse_args()
root = args.source_root.resolve(strict=True)
out = args.output_dir.resolve()
if out.exists():
    parser.error('--output-dir must not already exist')
helper_path = root / 'Sources/LumenCore/Interaction/BrushStabilizer.swift'
helper = helper_path.read_text()
files = {'helper.swift': helper + '\nenum Num { static func saturate(_ v: Double) -> Double { min(max(v,0),1) } }\n'}
entries = []
for name in ['BrushStabilizerTests', 'BrushStabilizerSourceMetricTests']:
    text = (root / f'Tests/LumenCoreTests/{name}.swift').read_text()
    text = text.replace('@testable import LumenCore', '')
    files[f'{name}.swift'] = text
    methods = re.findall(r'func (test\w+)\(', text)
    entries.append('testCase([' + ','.join(f'("{m}", {name}.{m})' for m in methods) + '])')
files['main.swift'] = 'import XCTest\nXCTMain([' + ','.join(entries) + '])\n'
for line in ['scaleX = sourceWidth / long', 'scaleY = sourceHeight / long']:
    if files['helper.swift'].count(line) != 1:
        parser.error(f'expected exactly one production metric assignment: {line}')
files['mutant.swift'] = files['helper.swift'].replace('scaleX = sourceWidth / long', 'scaleX = 1').replace('scaleY = sourceHeight / long', 'scaleY = 1')
# mkdir(exist_ok=False) also rejects a competing creator; exclusive file opens
# prevent replacing anything even if another process writes inside the new directory.
out.mkdir(parents=True, exist_ok=False)
for name, text in files.items():
    with (out / name).open('x') as handle:
        handle.write(text)
print(f'Generated {len(files)} input files in {out}; no compiler or tests executed.')
