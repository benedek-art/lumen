#!/usr/bin/env python3
"""Checks on gen-slider-atlas.py's `load()`: which file speaks for a control.

The verdicts directory also holds the atlas agents' scratch, including in one run a
`bw.aqua.compact.json` beside `bw.aqua.json` carrying the same id. "First in sorted
order wins" picked the compact copy, because `.c` sorts before `.j`. These cases pin
the rule that replaced it: the file named exactly `<id>.json` wins whatever sorts first.

    python3 scripts/test-gen-slider-atlas.py      # exit 0 when every case holds
"""
import importlib.util, json, os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "gen_slider_atlas", os.path.join(HERE, "gen-slider-atlas.py"))
atlas = importlib.util.module_from_spec(spec)
spec.loader.exec_module(atlas)

failures = []


def check(label, condition):
    print(("ok   " if condition else "FAIL ") + label)
    if not condition:
        failures.append(label)


def write(directory, name, record):
    with open(os.path.join(directory, name), "w") as handle:
        json.dump(record, handle)


# The fixture V7 reproduced the defect with: the compact copy sorts first.
with tempfile.TemporaryDirectory() as d:
    write(d, "bw.aqua.json", {"id": "bw.aqua", "entry": "canonical", "problems": []})
    write(d, "bw.aqua.compact.json", {"id": "bw.aqua", "entry": "compact"})
    loaded = atlas.load(d)
    check("one verdict per id", len(loaded) == 1)
    check("the canonical bw.aqua.json wins over bw.aqua.compact.json",
          loaded and loaded[0]["entry"] == "canonical")

# The same pair the other way round in sort order, so the rule is not an accident of
# which name sorts first.
with tempfile.TemporaryDirectory() as d:
    write(d, "tone.contrast.json", {"id": "tone.contrast", "entry": "canonical"})
    write(d, "tone.contrast.zz-copy.json", {"id": "tone.contrast", "entry": "copy"})
    loaded = atlas.load(d)
    check("canonical wins when it sorts first too",
          len(loaded) == 1 and loaded[0]["entry"] == "canonical")

# No canonical file at all: still exactly one, and deterministically the first sorted.
with tempfile.TemporaryDirectory() as d:
    write(d, "b-copy.json", {"id": "look.x", "entry": "b"})
    write(d, "a-copy.json", {"id": "look.x", "entry": "a"})
    write(d, "notes.json", {"something": "else"})
    loaded = atlas.load(d)
    check("without a canonical file the first in sorted order wins",
          len(loaded) == 1 and loaded[0]["entry"] == "a")

if failures:
    sys.exit(f"{len(failures)} case(s) failed")
print("gen-slider-atlas load(): all cases hold")
