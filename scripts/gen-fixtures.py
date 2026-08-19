#!/usr/bin/env python3
"""Golden-fixture generator + Linux-side verifier for LumenCore.

This script is the executable mirror of the algorithms in Sources/LumenCore.
It runs where Swift cannot (this repo is developed partly from Linux machines)
and produces the fixtures under Tests/LumenCoreTests/Fixtures/ that the Swift
test suite replays on macOS. It also *verifies* what it can on the spot:
  - executes the catalog DDL (extracted from Schema.swift) in real SQLite
  - round-trips the XMP template through an XML parser
  - checks xxh64 against the reference C implementation (python-xxhash)
  - sanity-checks curve monotonicity and zone partition-of-unity

Mirrored contracts (change BOTH sides together):
  CanonicalJSON.swift   <-> canonical_number / canonical_serialize / sparse / merge
  MonotoneCubic.swift   <-> MonotoneCubic
  ZoneWeights.swift     <-> zone_weights / exposure_stops
  MaskAlgebra.swift     <-> mask_combined
  XMPSidecar.swift      <-> xmp_serialize
  RenameTemplate.swift  <-> rename_render
"""

import json
import math
import os
import re
import sqlite3
import sys
import xml.etree.ElementTree as ET

import xxhash

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES = os.path.join(ROOT, "Tests", "LumenCoreTests", "Fixtures")
os.makedirs(FIXTURES, exist_ok=True)

FAILURES = []


def check(cond, msg):
    if not cond:
        FAILURES.append(msg)
        print(f"  FAIL: {msg}")


# ---------------------------------------------------------------------------
# Canonical JSON (mirror of CanonicalJSON.swift)
# ---------------------------------------------------------------------------

def canonical_number(d):
    assert math.isfinite(d), "non-finite number in recipe JSON"
    if d == round(d) and abs(d) < 1e15:
        i = int(d)
        return "0" if i == 0 else str(i)
    return "%.6g" % d


def _escape(s):
    out = []
    for ch in s:
        if ch == '"':
            out.append('\\"')
        elif ch == "\\":
            out.append("\\\\")
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif ord(ch) < 0x20:
            out.append("\\u%04x" % ord(ch))
        else:
            out.append(ch)
    return '"' + "".join(out) + '"'


def canonical_serialize(v):
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return canonical_number(float(v))
    if isinstance(v, str):
        return _escape(v)
    if isinstance(v, list):
        return "[" + ",".join(canonical_serialize(x) for x in v) + "]"
    if isinstance(v, dict):
        return "{" + ",".join(
            _escape(k) + ":" + canonical_serialize(v[k]) for k in sorted(v.keys())
        ) + "}"
    raise TypeError(type(v))


def _deep_eq(a, b):
    # numeric equality across int/float, like JSONValue's Double-only numbers
    if isinstance(a, bool) or isinstance(b, bool):
        return a is b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return float(a) == float(b)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(_deep_eq(x, y) for x, y in zip(a, b))
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(_deep_eq(a[k], b[k]) for k in a)
    return a == b


def sparse(value, defaults):
    if not (isinstance(value, dict) and isinstance(defaults, dict)):
        return value
    pruned = {}
    for key, sub in value.items():
        if key in defaults:
            dsub = defaults[key]
            if _deep_eq(sub, dsub):
                continue
            if isinstance(sub, dict) and isinstance(dsub, dict):
                s = sparse(sub, dsub)
                if isinstance(s, dict) and not s:
                    continue
                pruned[key] = s
                continue
        pruned[key] = sub
    return pruned


def merge(defaults, overlay):
    if not (isinstance(defaults, dict) and isinstance(overlay, dict)):
        return overlay
    result = dict(defaults)
    for key, ov in overlay.items():
        if key in defaults and isinstance(defaults[key], dict) and isinstance(ov, dict):
            result[key] = merge(defaults[key], ov)
        else:
            result[key] = ov
    return result


def canonical_recipe_json(full_tree, defaults):
    sp = sparse(full_tree, defaults)
    sp["pipelineVersion"] = full_tree.get("pipelineVersion", 1)
    return canonical_serialize(sp)


def fp(s):
    return "xxh64:" + xxhash.xxh64(s.encode("utf-8"), seed=0).hexdigest()


# ---------------------------------------------------------------------------
# The default Recipe() JSON tree — must match the Swift structs' defaults.
# The Swift suite asserts encode(Recipe()) equals this file; drift fails there.
# ---------------------------------------------------------------------------

def zone_adjust():
    return {"ev": 0, "wheel": [0, 0], "sat": 0, "falloff": 0.5}


def wheel():
    return {"hue": 0, "sat": 0, "lum": 0}


DEFAULT_RECIPE = {
    "pipelineVersion": 1,
    "develop": {
        "raw": {"decoder": "apple"},
        "tone": {"exposure": 0, "contrast": 0, "contrastPivot": 0, "highlights": 0,
                 "shadows": 0, "whites": 0, "blacks": 0},
        "zones": {"pivots": [0.08, 0.25, 0.5, 0.75, 0.92],
                  "dark": zone_adjust(), "shadow": zone_adjust(), "mid": zone_adjust(),
                  "light": zone_adjust(), "bright": zone_adjust(), "global": zone_adjust()},
        "curve": {"parametric": {"highlights": 0, "lights": 0, "darks": 0,
                                 "shadows": 0, "splits": [0.25, 0.5, 0.75]},
                  "preserveLuminance": True},
        "mixer": {"bands": [{"hue": 0, "sat": 0, "lum": 0} for _ in range(8)],
                  "uniformity": 0},
        "pointColors": [],
        "detail": {"capture": {"auto": True}, "texture": 0, "clarity": 0, "dehaze": 0,
                   "sharpen": {"amount": 0, "radius": 1, "detail": 25,
                               "masking": 0, "haloSuppression": 0}},
        "denoise": {"mode": "classic", "amount": 50,
                    "classic": {"luma": 0, "chroma": 25, "hotPixels": 0}},
        "geometry": {"crop": {"x": 0, "y": 0, "w": 1, "h": 1}, "angle": 0,
                     "flipH": False, "lens": {"profile": True, "removeCA": True}},
        "heal": {"count": 0},
    },
    "look": {
        "wheels": {"global": wheel(), "shadows": wheel(), "mid": wheel(), "high": wheel(),
                   "blending": 50, "balance": 0, "pivots": [0.33, 0.67]},
        "printerLights": {"master": 0, "r": 0, "g": 0, "b": 0},
        "primaries": {"rHue": 0, "rPurity": 0, "gHue": 0, "gPurity": 0,
                      "bHue": 0, "bPurity": 0, "tintHue": 0, "tintPurity": 0},
        "vignette": 0,
    },
    "masks": [],
}


def gen_canonical_fixture():
    print("canonical.json ...")
    defaults = DEFAULT_RECIPE
    cases = []

    # Case A: pristine default recipe -> everything pruned except pipelineVersion.
    a_canon = canonical_recipe_json(defaults, defaults)
    check(a_canon == '{"pipelineVersion":1}', f"case A canonical unexpected: {a_canon}")
    cases.append({"name": "default", "canonical": a_canon, "fingerprint": fp(a_canon)})

    # Case B: a plausible develop edit (mirrors RecipeCodecTests.caseB in Swift).
    b = json.loads(json.dumps(defaults))  # deep copy
    b["develop"]["raw"]["temp"] = 5200
    b["develop"]["raw"]["tint"] = 8
    b["develop"]["tone"]["exposure"] = 0.35
    b["develop"]["tone"]["shadows"] = 25
    b_canon = canonical_recipe_json(b, defaults)
    cases.append({"name": "developEdit", "canonical": b_canon, "fingerprint": fp(b_canon)})
    check('"exposure":0.35' in b_canon and '"temp":5200' in b_canon,
          f"case B canonical missing fields: {b_canon}")

    # Case C: mask stack + look edits (mirrors RecipeCodecTests.caseC in Swift).
    c = json.loads(json.dumps(defaults))
    c["look"]["wheels"]["shadows"] = {"hue": 18, "sat": 0.06, "lum": -0.04}
    c["look"]["printerLights"]["master"] = 3
    c["look"]["printerLights"]["r"] = -1
    c["look"]["filmLab"] = {"stock": "lumen/portra400", "amount": 100, "pushPull": 0,
                            "halation": 35, "grain": {"size": 1, "amount": 40}}
    c["masks"] = [{
        "id": "6f000000-0000-0000-0000-00000000la01",
        "name": "Sky", "enabled": True, "amount": 100,
        "components": [
            {"op": "add", "kind": "aiSky", "amount": 100, "invert": False,
             "model": "skyseg/1.3"},
            {"op": "subtract", "kind": "brush", "amount": 80, "invert": False,
             "strokesRef": "blob:xxh64:00c41b0000000000"},
            {"op": "intersect", "kind": "lumaRange", "amount": 100, "invert": False,
             "lo": 0.55, "hi": 1, "smooth": 0.5},
        ],
        "refine": {"feather": 12, "edge": -5, "blur": 0,
                   "levelsLo": 0, "levelsHi": 100, "levelsGamma": 1},
        "adjust": {"exposure": -0.6, "contrast": 0, "highlights": 0, "shadows": 0,
                   "whites": 0, "blacks": 0, "temp": -300, "tint": 0, "hue": 0,
                   "sat": 0, "vibrance": 0, "texture": 0, "clarity": 0, "dehaze": 0,
                   "sharpness": 0, "noise": 0, "noiseChroma": 0, "moire": 0,
                   "defringe": 0, "grainAmount": 0, "colorTintStrength": 0,
                   "pointColors": []},
    }]
    c_canon = canonical_recipe_json(c, defaults)
    cases.append({"name": "maskAndLook", "canonical": c_canon, "fingerprint": fp(c_canon)})
    check('"filmLab"' in c_canon and '"aiSky"' in c_canon,
          f"case C canonical missing fields: {c_canon[:200]}")

    with open(os.path.join(FIXTURES, "canonical.json"), "w") as f:
        json.dump({"cases": cases}, f, indent=1)
    with open(os.path.join(FIXTURES, "default-recipe.json"), "w") as f:
        json.dump(DEFAULT_RECIPE, f, indent=1, sort_keys=True)


# ---------------------------------------------------------------------------
# xxh64 vectors (verify the Swift port byte path by byte path)
# ---------------------------------------------------------------------------

def gen_fingerprint_fixture():
    print("fingerprint.json ...")
    inputs = [
        "",                                    # empty
        "a",                                   # 1 byte tail
        "abcd",                                # 4-byte lane
        "lumen",                               # 5 bytes
        "0123456789abcdef",                    # 16 bytes: two 8-byte laps
        "0123456789abcdefghijklmnopqrstu",     # 31 bytes: just under stripe
        "0123456789abcdefghijklmnopqrstuv",    # 32 bytes: one full stripe
        "The quick brown fox jumps over the lazy dog",     # >32
        "x" * 1000,                            # long
        "grüß-dich-☀️",                        # multibyte UTF-8
        '{"pipelineVersion":1}',               # the default-recipe canonical form
    ]
    vectors = [{"input": s,
                "xxh64": xxhash.xxh64(s.encode("utf-8"), seed=0).hexdigest()}
               for s in inputs]
    with open(os.path.join(FIXTURES, "fingerprint.json"), "w") as f:
        json.dump({"vectors": vectors}, f, indent=1)


# ---------------------------------------------------------------------------
# Monotone cubic (mirror of MonotoneCubic.swift)
# ---------------------------------------------------------------------------

class MonotoneCubic:
    def __init__(self, points):
        pts = sorted([p for p in points if len(p) >= 2], key=lambda p: p[0])
        xs, ys = [], []
        for p in pts:
            if xs and p[0] <= xs[-1]:
                continue
            xs.append(p[0])
            ys.append(p[1])
        self.xs, self.ys = xs, ys
        n = len(xs)
        if n < 2:
            self.m = [0.0] * n
            return
        d = [(ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i]) for i in range(n - 1)]
        m = [0.0] * n
        m[0], m[n - 1] = d[0], d[n - 2]
        for i in range(1, n - 1):
            m[i] = 0.0 if d[i - 1] * d[i] <= 0 else (d[i - 1] + d[i]) / 2
        for i in range(n - 1):
            if d[i] == 0:
                m[i] = m[i + 1] = 0.0
            else:
                a, b = m[i] / d[i], m[i + 1] / d[i]
                s = a * a + b * b
                if s > 9:
                    t = 3 / math.sqrt(s)
                    m[i] = t * a * d[i]
                    m[i + 1] = t * b * d[i]
        self.m = m

    def evaluate(self, x):
        xs, ys, m = self.xs, self.ys, self.m
        n = len(xs)
        if n == 0:
            return x
        if n == 1:
            return ys[0]
        if x <= xs[0]:
            return ys[0]
        if x >= xs[-1]:
            return ys[-1]
        lo, hi = 0, n - 1
        while hi - lo > 1:
            mid = (lo + hi) // 2
            if xs[mid] <= x:
                lo = mid
            else:
                hi = mid
        h = xs[lo + 1] - xs[lo]
        t = (x - xs[lo]) / h
        t2, t3 = t * t, t * t * t
        h00 = 2 * t3 - 3 * t2 + 1
        h10 = t3 - 2 * t2 + t
        h01 = -2 * t3 + 3 * t2
        h11 = t3 - t2
        return (h00 * ys[lo] + h10 * h * m[lo]
                + h01 * ys[lo + 1] + h11 * h * m[lo + 1])


def gen_curves_fixture():
    print("curves.json ...")
    curve_cases = [
        {"name": "identity", "points": [[0, 0], [1, 1]]},
        {"name": "sCurve", "points": [[0, 0], [0.25, 0.18], [0.75, 0.85], [1, 1]]},
        {"name": "matteFade", "points": [[0, 0.08], [0.4, 0.42], [1, 0.96]]},
        {"name": "flatSegment", "points": [[0, 0], [0.4, 0.5], [0.6, 0.5], [1, 1]]},
        {"name": "steepMonotone", "points": [[0, 0], [0.1, 0.05], [0.2, 0.9], [1, 1]]},
        {"name": "singlePoint", "points": [[0.5, 0.3]]},
        {"name": "duplicateX", "points": [[0, 0], [0.5, 0.4], [0.5, 0.9], [1, 1]]},
        {"name": "unsorted", "points": [[1, 1], [0, 0], [0.5, 0.6]]},
    ]
    samples = [i / 32 for i in range(33)] + [-0.25, 1.25]
    out = []
    for case in curve_cases:
        c = MonotoneCubic(case["points"])
        values = [c.evaluate(x) for x in samples]
        # verification: monotone inputs must produce monotone outputs
        if case["name"] in ("identity", "sCurve", "matteFade", "steepMonotone"):
            inside = [c.evaluate(x) for x in [i / 200 for i in range(201)]]
            check(all(b - a >= -1e-12 for a, b in zip(inside, inside[1:])),
                  f"curve {case['name']} not monotone")
        out.append({"name": case["name"], "points": case["points"],
                    "samples": samples, "values": values})
    with open(os.path.join(FIXTURES, "curves.json"), "w") as f:
        json.dump({"cases": out}, f, indent=1)


# ---------------------------------------------------------------------------
# Zone weights (mirror of ZoneWeights.swift)
# ---------------------------------------------------------------------------

def zone_weights(x, pivots):
    n = len(pivots)
    w = [0.0] * n
    if n == 1 or x <= pivots[0]:
        w[0] = 1.0
        return w
    if x >= pivots[-1]:
        w[-1] = 1.0
        return w
    i = 0
    while i < n - 1 and not (pivots[i] <= x < pivots[i + 1]):
        i += 1
    u = (x - pivots[i]) / (pivots[i + 1] - pivots[i])
    wi = 0.5 * (1 + math.cos(math.pi * u))
    w[i] = wi
    w[i + 1] = 1 - wi
    return w


def exposure_stops(x, pivots, zone_ev, global_ev):
    w = zone_weights(x, pivots)
    return global_ev + sum(wi * ev for wi, ev in zip(w, zone_ev))


def gen_zones_fixture():
    print("zones.json ...")
    default_pivots = [0.08, 0.25, 0.5, 0.75, 0.92]
    custom_pivots = [0.1, 0.3, 0.6, 0.85]
    samples = [i / 24 for i in range(25)]
    cases = []
    for name, pivots in [("default", default_pivots), ("custom4", custom_pivots)]:
        weights = [zone_weights(x, pivots) for x in samples]
        for x, w in zip(samples, weights):   # verification: partition of unity
            check(abs(sum(w) - 1) < 1e-12, f"zones {name} weights at {x} sum {sum(w)}")
        cases.append({"name": name, "pivots": pivots, "samples": samples,
                      "weights": weights})
    ev_case = {
        "pivots": default_pivots,
        "zoneEV": [0.3, 0.0, -0.2, 0.0, -1.0],
        "globalEV": 0.15,
        "samples": samples,
        "stops": [exposure_stops(x, default_pivots, [0.3, 0, -0.2, 0, -1.0], 0.15)
                  for x in samples],
    }
    with open(os.path.join(FIXTURES, "zones.json"), "w") as f:
        json.dump({"cases": cases, "exposure": ev_case}, f, indent=1)


# ---------------------------------------------------------------------------
# Mask algebra (mirror of MaskAlgebra.swift)
# ---------------------------------------------------------------------------

def component_alpha(raw, invert, amount):
    v = min(max(raw, 0.0), 1.0)
    if invert:
        v = 1 - v
    return v * min(max(amount, 0.0), 100.0) / 100.0


def mask_combined(stack):
    acc = 0.0
    for c in stack:
        v = component_alpha(c["alpha"], c["invert"], c["amount"])
        if c["op"] == "add":
            acc = max(acc, v)
        elif c["op"] == "subtract":
            acc = min(acc, 1 - v)
        elif c["op"] == "intersect":
            acc *= v
    return acc


def gen_maskalgebra_fixture():
    print("maskalgebra.json ...")
    def comp(op, alpha, invert=False, amount=100):
        return {"op": op, "alpha": alpha, "invert": invert, "amount": amount}

    cases = [
        {"name": "singleAdd", "stack": [comp("add", 0.7)]},
        {"name": "addUnion", "stack": [comp("add", 0.3), comp("add", 0.6)]},
        {"name": "skyMinusBrush",
         "stack": [comp("add", 0.9), comp("subtract", 0.5, amount=80)]},
        {"name": "docsCoreCase",  # docs/08: sky ∩ luma range, minus a brush stroke
         "stack": [comp("add", 1.0), comp("subtract", 0.4),
                   comp("intersect", 0.75)]},
        {"name": "invertedAdd", "stack": [comp("add", 0.2, invert=True)]},
        {"name": "startsWithSubtract", "stack": [comp("subtract", 0.5)]},
        {"name": "amountScaling", "stack": [comp("add", 1.0, amount=35)]},
        {"name": "clampedInput", "stack": [comp("add", 1.7), comp("intersect", -0.2)]},
    ]
    for c in cases:
        c["expected"] = mask_combined(c["stack"])
    check(mask_combined([comp("subtract", 0.5)]) == 0.0, "empty-start subtract not 0")
    check(abs(mask_combined([comp("add", 1.0, amount=35)]) - 0.35) < 1e-12,
          "amount scaling broken")
    with open(os.path.join(FIXTURES, "maskalgebra.json"), "w") as f:
        json.dump({"cases": cases}, f, indent=1)


# ---------------------------------------------------------------------------
# XMP (mirror of XMPSidecar.swift — template must match byte for byte)
# ---------------------------------------------------------------------------

def xmp_escape(s):
    return (s.replace("&", "&amp;").replace("<", "&lt;")
             .replace(">", "&gt;").replace('"', "&quot;"))


def xmp_serialize(content):
    fields = ""
    fields += f"   <xmp:Rating>{content['rating']}</xmp:Rating>\n"
    if content.get("label") is not None:
        fields += f"   <xmp:Label>{xmp_escape(content['label'])}</xmp:Label>\n"
    fields += (f"   <lumen:pipelineVersion>{content['pipelineVersion']}"
               "</lumen:pipelineVersion>\n")
    if content.get("recipeFingerprint") is not None:
        fields += (f"   <lumen:recipeFingerprint>{xmp_escape(content['recipeFingerprint'])}"
                   "</lumen:recipeFingerprint>\n")
    if content.get("writeStamp") is not None:
        fields += f"   <lumen:writeStamp>{xmp_escape(content['writeStamp'])}</lumen:writeStamp>\n"
    if content.get("catalogUUID") is not None:
        fields += f"   <lumen:catalogUUID>{xmp_escape(content['catalogUUID'])}</lumen:catalogUUID>\n"
    if content.get("recipeJSON") is not None:
        fields += f"   <lumen:recipe>{xmp_escape(content['recipeJSON'])}</lumen:recipe>\n"
    return (
        '<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>\n'
        '<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Lumen">\n'
        ' <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n'
        '  <rdf:Description rdf:about=""\n'
        '    xmlns:xmp="http://ns.adobe.com/xap/1.0/"\n'
        '    xmlns:lumen="http://lumenapp.dev/xmp/1.0/">\n'
        f"{fields}  </rdf:Description>\n"
        " </rdf:RDF>\n"
        "</x:xmpmeta>\n"
        '<?xpacket end="w"?>'
    )


def gen_xmp_fixture():
    print("xmp.json ...")
    recipe_json = '{"develop":{"tone":{"exposure":0.35}},"pipelineVersion":1}'
    cases = [
        {"name": "full",
         "content": {"rating": 3, "label": "Red", "pipelineVersion": 1,
                     "recipeFingerprint": fp(recipe_json),
                     "recipeJSON": recipe_json,
                     "catalogUUID": "9E107D9D-372B-4F2C-A1B2-000000000001",
                     "writeStamp": "2026-08-19T21:30:00Z"}},
        {"name": "cullOnly",
         "content": {"rating": 5, "label": None, "pipelineVersion": 1,
                     "recipeFingerprint": None, "recipeJSON": None,
                     "catalogUUID": None, "writeStamp": None}},
        {"name": "escaping",
         "content": {"rating": 0, "label": 'A<&>"label', "pipelineVersion": 1,
                     "recipeFingerprint": None,
                     "recipeJSON": '{"name":"a \\"quoted\\" <tag>"}',
                     "catalogUUID": None, "writeStamp": None}},
    ]
    for c in cases:
        xml_text = xmp_serialize(c["content"])
        c["xmp"] = xml_text
        # verification: well-formed XML and fields round-trip via a real parser
        root = ET.fromstring(xml_text.split("?>\n", 1)[1].rsplit("\n<?xpacket", 1)[0])
        ns = {"xmp": "http://ns.adobe.com/xap/1.0/",
              "lumen": "http://lumenapp.dev/xmp/1.0/",
              "rdf": "http://www.w3.org/1999/02/22-rdf-syntax-ns#"}
        desc = root.find(".//rdf:Description", ns)
        rating = desc.find("xmp:Rating", ns)
        check(rating is not None and int(rating.text) == c["content"]["rating"],
              f"xmp {c['name']} rating round-trip")
        if c["content"]["recipeJSON"] is not None:
            rj = desc.find("lumen:recipe", ns)
            check(rj is not None and rj.text == c["content"]["recipeJSON"],
                  f"xmp {c['name']} recipe round-trip")
    with open(os.path.join(FIXTURES, "xmp.json"), "w") as f:
        json.dump({"cases": cases}, f, indent=1)


# ---------------------------------------------------------------------------
# Rename templates (mirror of RenameTemplate.swift)
# ---------------------------------------------------------------------------

def rename_render(template, ctx, seq):
    def pad(v, width):
        return "" if v is None else str(v).zfill(width)

    def expand(token):
        c = ctx["captureDate"]
        if token == "orig":
            return ctx["originalBasename"]
        if token == "seq":
            return "%04d" % seq
        if token.startswith("seq:"):
            spec = token[4:]
            if not re.fullmatch(r"[0-9]+", spec):
                return ""
            width = int(spec)
            return ("%0" + str(width) + "d") % seq if 1 <= width <= 9 else ""
        if token == "date":
            return pad(c.get("year"), 4) + pad(c.get("month"), 2) + pad(c.get("day"), 2)
        if token == "year":
            return pad(c.get("year"), 4)
        if token == "month":
            return pad(c.get("month"), 2)
        if token == "day":
            return pad(c.get("day"), 2)
        if token == "time":
            return pad(c.get("hour"), 2) + pad(c.get("minute"), 2) + pad(c.get("second"), 2)
        if token == "hour":
            return pad(c.get("hour"), 2)
        if token == "minute":
            return pad(c.get("minute"), 2)
        if token == "camera":
            return ctx.get("camera") or ""
        if token == "serial":
            return ctx.get("cameraSerial") or ""
        if token == "iso":
            return str(ctx["iso"]) if ctx.get("iso") is not None else ""
        if token == "job":
            return ctx.get("job") or ""
        return ""

    out, rest = "", template
    while "{" in rest:
        open_i = rest.index("{")
        out += rest[:open_i]
        close_i = rest.find("}", open_i + 1)
        if close_i == -1:
            out += rest[open_i:]
            rest = ""
            break
        out += expand(rest[open_i + 1:close_i])
        rest = rest[close_i + 1:]
    out += rest
    cleaned = "".join(
        "-" if ch in "/\\:" else ("" if ord(ch) < 0x20 else ch) for ch in out
    )
    return " ".join(p for p in cleaned.split(" ") if p)


def gen_rename_fixture():
    print("rename.json ...")
    ctx = {"originalBasename": "IMG_4032",
           "captureDate": {"year": 2026, "month": 8, "day": 19,
                           "hour": 21, "minute": 5, "second": 9},
           "camera": "X-T5", "cameraSerial": "7A0042", "iso": 1600,
           "job": "kovacs wedding"}
    cases = [
        {"template": "{date}_{job}_{seq}", "seq": 12},
        {"template": "{year}/{month}/{orig}", "seq": 1},
        {"template": "{date}-{time}-{seq:6}", "seq": 31},
        {"template": "{camera}_{iso}iso_{seq:2}", "seq": 7},
        {"template": "plain-name", "seq": 1},
        {"template": "broken{unclosed", "seq": 1},
        {"template": "{orig} copy", "seq": 1},
    ]
    for c in cases:
        c["context"] = ctx
        c["expected"] = rename_render(c["template"], ctx, c["seq"])
    check(rename_render("{date}_{seq}", ctx, 3) == "20260819_0003", "rename date_seq")
    check(rename_render("{year}/{month}/x", ctx, 1) == "2026-08-x", "rename sanitize /")
    with open(os.path.join(FIXTURES, "rename.json"), "w") as f:
        json.dump({"cases": cases}, f, indent=1)


# ---------------------------------------------------------------------------
# Schema: extract the DDL from Schema.swift and execute it in real SQLite
# ---------------------------------------------------------------------------

def verify_schema():
    print("schema check (real SQLite) ...")
    src = open(os.path.join(ROOT, "Sources", "LumenCore", "Catalog", "Schema.swift")).read()
    blocks = re.findall(r'"""\n(.*?)\n?\s*"""', src, re.DOTALL)
    check(len(blocks) >= 3, f"expected 3 DDL/pragma blocks in Schema.swift, got {len(blocks)}")
    lumen_ddl, cache_ddl, pragmas = blocks[0], blocks[1], blocks[2]

    con = sqlite3.connect(":memory:")
    for stmt in pragmas.strip().split(";"):
        if stmt.strip():
            con.execute(stmt)
    con.executescript(lumen_ddl)
    con.executescript(cache_ddl)

    # smoke: insert + indexed grid-filter query plan uses the cull index
    con.execute("INSERT INTO folder (id, path) VALUES (1, '/photos/wedding')")
    con.execute("""INSERT INTO photo (id, folder_id, filename, file_size, file_mtime,
                   rating, flag) VALUES (1, 1, 'IMG_0001.RAF', 42, 0, 3, 1)""")
    con.execute("""INSERT INTO edit (photo_id, kind, is_current, pipeline_version,
                   recipe, recipe_fp, updated_at)
                   VALUES (1, 'working', 1, 1, '{"pipelineVersion":1}', ?, 0)""",
                (fp('{"pipelineVersion":1}'),))
    row = con.execute("""SELECT p.filename, e.recipe_fp FROM photo p
                         JOIN edit e ON e.photo_id = p.id AND e.is_current = 1
                         WHERE p.flag = 1 AND p.rating >= 3""").fetchone()
    check(row is not None and row[0] == "IMG_0001.RAF", "schema smoke query")
    plan = con.execute(
        "EXPLAIN QUERY PLAN SELECT id FROM photo WHERE flag = 1 AND rating >= 3"
    ).fetchall()
    check(any("photo_cull" in str(r) for r in plan),
          f"grid filter not index-backed: {plan}")
    con.close()
    print("  lumen.db + cache.db DDL executed clean; grid filter is index-backed")


# ---------------------------------------------------------------------------

def main():
    gen_canonical_fixture()
    gen_fingerprint_fixture()
    gen_curves_fixture()
    gen_zones_fixture()
    gen_maskalgebra_fixture()
    gen_xmp_fixture()
    gen_rename_fixture()
    verify_schema()
    if FAILURES:
        print(f"\n{len(FAILURES)} verification failure(s)")
        sys.exit(1)
    print("\nAll fixtures generated; all Linux-side verifications passed.")


if __name__ == "__main__":
    main()
