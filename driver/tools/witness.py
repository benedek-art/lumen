#!/usr/bin/env python3
"""The pixel witness: geometry facts read from a run's screenshots, never from the app.

    witness.py RUN_DIR --map fiducial.json

RUN_DIR is one scenario's output (report.json, scenario.json, shots/). For every
screenshot of the fiducial fixture it finds where the image really is on screen
(fiducial.py), then derives:

  shots.<name>     scale, rect (window points), insets of the image inside the viewer,
                   the image pixel under the cursor, and how far the app's own claim
                   of the image rectangle is from the pixels (claimErrorPt)
  groups.<id>      for a gesture captured step by step (`"capture": "each"`): how far
                   the image point that started under the cursor has moved away from
                   the cursor (driftMaxPt, driftEndPt), the largest jump between two
                   consecutive captures (jumpMaxPt) and the scale series

and evaluates the scenario's `witness` checks against those, e.g.
  {"that": "groups.pinch.driftMaxPt", "lt": 2}
  {"that": "drift.before.after", "lt": 2}      anchor drift between two named shots

Writes RUN_DIR/witness.json. Exit status 0 even when checks fail; summarize.py reads
the verdicts. Needs numpy and Pillow.
"""
import argparse
import json
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))


def flatten(value, prefix, out):
    if isinstance(value, dict):
        for k, v in value.items():
            flatten(v, f"{prefix}.{k}" if prefix else k, out)
    elif isinstance(value, list):
        out[prefix + ".count"] = len(value)
        for i, v in enumerate(value):
            flatten(v, f"{prefix}.{i}", out)
    else:
        out[prefix] = value


def evaluate(check, table):
    path = check.get("that", "")
    actual = table.get(path)

    def rhs(key):
        value = check[key]
        return table.get(value, value) if isinstance(value, str) else value

    def num(v):
        return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None

    if "exists" in check:
        return (actual is not None) == bool(check["exists"]), f"{path} exists == {check['exists']}"
    for key, symbol, op in (("gt", ">", lambda a, b: a > b), ("ge", ">=", lambda a, b: a >= b),
                            ("lt", "<", lambda a, b: a < b), ("le", "<=", lambda a, b: a <= b)):
        if key in check:
            a, b = num(actual), num(rhs(key))
            return (a is not None and b is not None and op(a, b)), f"{path} {symbol} {check[key]}"
    if "near" in check:
        a, b, tol = num(actual), num(rhs("near")), check.get("tol", 0.01)
        return (a is not None and b is not None and abs(a - b) <= tol), \
            f"{path} ≈ {check['near']} ± {tol}"
    for key, negate in (("eq", False), ("ne", True)):
        if key in check:
            same = actual is not None and actual == rhs(key)
            return same != negate, f"{path} {'!=' if negate else '=='} {check[key]}"
    return False, f"{path}: no operator"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("run")
    parser.add_argument("--map", required=True)
    args = parser.parse_args()
    run = Path(args.run)
    report = json.loads((run / "report.json").read_text())
    scenario = json.loads((run / "scenario.json").read_text())
    checks = scenario.get("witness", [])
    result = {"shots": {}, "groups": {}, "drift": {}, "checks": []}

    rows = report.get("shots", [])
    if scenario.get("fixture", "fiducial") == "fiducial" and rows:
        import numpy as np
        from PIL import Image
        import fiducial
        meta = json.loads(Path(args.map).read_text())
        placed = {}
        for row in rows:
            path = run / row["file"]
            entry = {"located": False, "t": row.get("t")}
            result["shots"][row["name"]] = entry
            viewer = row.get("viewer")
            if not path.exists() or not viewer:
                continue
            scale = row.get("scale", 1) or 1
            rgb = np.asarray(Image.open(path).convert("RGB"))
            roi = [viewer["x"] * scale, viewer["y"] * scale, viewer["w"] * scale, viewer["h"] * scale]
            place = fiducial.locate(rgb, meta, roi)
            if place is None:
                continue
            # Everything below is in window points, like the driver's own coordinates.
            rect = [v / scale for v in place["rect"]]
            pt_per_px = place["scale"] / scale
            entry.update({
                "located": True, "scale": pt_per_px, "rect": {"x": rect[0], "y": rect[1],
                                                               "w": rect[2], "h": rect[3]},
                "lines": place["lines"], "rms": place["rms"] / scale, "match": place["match"],
                # Positive: surround shows between the image edge and the viewer edge.
                "insetLeft": rect[0] - viewer["x"], "insetTop": rect[1] - viewer["y"],
                "insetRight": viewer["x"] + viewer["w"] - (rect[0] + rect[2]),
                "insetBottom": viewer["y"] + viewer["h"] - (rect[1] + rect[3]),
            })
            cursor = row.get("cursor")
            if cursor:
                u, v = fiducial.image_point(place, cursor["x"] * scale, cursor["y"] * scale)
                entry["underCursor"] = {"u": u, "v": v}
            claim = row.get("image")
            if claim:
                entry["claimErrorPt"] = max(abs(claim["x"] - rect[0]), abs(claim["y"] - rect[1]),
                                            abs(claim["x"] + claim["w"] - rect[0] - rect[2]),
                                            abs(claim["y"] + claim["h"] - rect[1] - rect[3]))
            placed[row["name"]] = (place, scale, cursor)

        def drift(a, b):
            """Where the image point under a's cursor is in b, relative to b's cursor."""
            if a not in placed or b not in placed:
                return None
            place_a, scale_a, cursor_a = placed[a]
            place_b, scale_b, cursor_b = placed[b]
            if not cursor_a or not cursor_b:
                return None
            u, v = fiducial.image_point(place_a, cursor_a["x"] * scale_a, cursor_a["y"] * scale_a)
            x, y = fiducial.screen_point(place_b, u, v)
            return x / scale_b - cursor_b["x"], y / scale_b - cursor_b["y"]

        groups = {}
        for row in rows:
            if row.get("group"):
                groups.setdefault(row["group"], []).append(row["name"])
        for name, members in groups.items():
            series, scales, previous, jump = [], [], None, 0.0
            located = [m for m in members if m in placed]
            for m in located:
                d = drift(located[0], m)
                if d is None:
                    continue
                series.append([round(d[0], 2), round(d[1], 2)])
                scales.append(round(result["shots"][m]["scale"], 5))
                if previous is not None:
                    jump = max(jump, math.hypot(d[0] - previous[0], d[1] - previous[1]))
                previous = d
            magnitudes = [math.hypot(*d) for d in series]
            result["groups"][name] = {
                "captures": len(members), "located": len(located),
                "driftMaxPt": max(magnitudes) if magnitudes else None,
                "driftEndPt": magnitudes[-1] if magnitudes else None,
                "jumpMaxPt": jump if series else None,
                "scaleStart": scales[0] if scales else None,
                "scaleEnd": scales[-1] if scales else None,
                "scaleRatio": scales[-1] / scales[0] if scales and scales[0] else None,
                # How far the image itself travelled on screen, first capture to last.
                "moveX": (result["shots"][located[-1]]["rect"]["x"]
                          - result["shots"][located[0]]["rect"]["x"]) if located else None,
                "moveY": (result["shots"][located[-1]]["rect"]["y"]
                          - result["shots"][located[0]]["rect"]["y"]) if located else None,
                "scaleMonotonic": all(b >= a - 1e-4 for a, b in zip(scales, scales[1:]))
                                  or all(b <= a + 1e-4 for a, b in zip(scales, scales[1:])),
                "driftSeries": series, "scaleSeries": scales,
            }
        # Pairwise drift on demand: a check on drift.<a>.<b> asks for it.
        for check in checks:
            parts = check.get("that", "").split(".")
            if len(parts) == 3 and parts[0] == "drift":
                d = drift(parts[1], parts[2])
                if d is not None:
                    result["drift"].setdefault(parts[1], {})[parts[2]] = math.hypot(*d)

    table = {}
    flatten({k: result[k] for k in ("shots", "groups")}, "", table)
    for a, others in result["drift"].items():
        for b, value in others.items():
            table[f"drift.{a}.{b}"] = value
    for check in checks:
        holds, summary = evaluate(check, table)
        actual = table.get(check.get("that", ""))
        result["checks"].append({"check": summary, "pass": bool(holds), "actual": actual,
                                 "note": check.get("note", "")})
    (run / "witness.json").write_text(json.dumps(result, indent=1) + "\n")
    for name, group in result["groups"].items():
        print(f"{name}: drift max {group['driftMaxPt']} end {group['driftEndPt']} "
              f"jump {group['jumpMaxPt']} scale {group['scaleStart']} -> {group['scaleEnd']} "
              f"({group['located']}/{group['captures']} located)")
    for check in result["checks"]:
        print(("PASS " if check["pass"] else "FAIL ") + check["check"] + f" (was {check['actual']})")


if __name__ == "__main__":
    main()
