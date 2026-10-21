#!/usr/bin/env python3
"""WS-06 UI lines (U1, T1, T2): read the Contrast and Pivot LumenSlider literals in
Sources/LumenApp/BasicPanel.swift and check range and tooltip text.

  ui_check.py REPO
"""
import re, sys

src = open(f"{sys.argv[1]}/Sources/LumenApp/BasicPanel.swift").read()


def row(title):
    i = src.index(f'LumenSlider(title: "{title}"')
    # The literal runs to the next slider or the next comment line, whichever is first.
    ends = [e for e in (src.find("LumenSlider(", i + 1), src.find("\n            //", i)) if e > 0]
    block = src[i:min(ends)]
    help_text = "".join(re.findall(r'"((?:[^"\\]|\\.)*)"', block[block.index("help:"):]))
    rng = re.search(r"(?<![A-Za-z])range:\s*(-?[\d.]+)\s*\.\.\.\s*(-?[\d.]+)", block)
    hard = re.search(r"hardRange:\s*(nil|(-?[\d.]+)\s*\.\.\.\s*(-?[\d.]+))", block)
    step = re.search(r"step:\s*([\d.]+)", block)
    return dict(range=(float(rng.group(1)), float(rng.group(2))),
                hard=None if hard.group(1) == "nil" else (float(hard.group(2)), float(hard.group(3))),
                step=float(step.group(1)), help=help_text)


def out(key, ok, detail):
    print(f"{key} {1.0 if ok else 0.0:.6f} {detail}")


c, p = row("Contrast"), row("Pivot")
out("U1_pivot_range_ok", p["range"] == (-3.0, 3.0) and p["hard"] == (-4.0, 4.0) and p["step"] == 0.01,
    f"range {p['range']} hardRange {p['hard']} step {p['step']} (want -3...3, hard -4...4, 0.01)")
out("U1_contrast_range_ok", c["range"] == (-100.0, 100.0) and c["step"] == 1.0,
    f"range {c['range']} step {c['step']}")
h = c["help"].lower()
problems = []
if "cannot clip" in h or "can't clip" in h or "never clip" in h:
    problems.append("claims it cannot clip")
if not re.search(r"white and black (point|end)", h):
    problems.append("does not say the white and black points stay fixed")
if not re.search(r"(compress|flatten|squeez)", h):
    problems.append("does not say strong settings compress the brightest and darkest tones")
if re.search(r"(more|adds?|boosts?|richer) (colou?r|saturation)", h):
    problems.append("claims a saturation change Contrast does not make (C3 is open)")
out("T1_contrast_tooltip_truthful", not problems, "; ".join(problems) or repr(c["help"]))
hp = p["help"].lower()
pp = []
if not re.search(r"darken", hp):
    pp.append("does not warn that a raised Pivot with + Contrast darkens the picture")
out("T2_pivot_tooltip_truthful", not pp, "; ".join(pp) or repr(p["help"]))
