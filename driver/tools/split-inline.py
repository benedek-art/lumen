#!/usr/bin/env python3
"""Split the workflow's inline scenario input into files.

    split-inline.py INPUT.json OUT_DIR

INPUT is one scenario object or an array of them; writes OUT_DIR/inline-<name>.json.
"""
import json
import re
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
out = Path(sys.argv[2])
for index, scenario in enumerate(data if isinstance(data, list) else [data]):
    name = re.sub(r"[^A-Za-z0-9_.-]+", "-", str(scenario.get("name", index))).strip("-") or str(index)
    (out / f"inline-{name}.json").write_text(json.dumps(scenario, indent=1) + "\n")
    print(f"inline-{name}.json")
