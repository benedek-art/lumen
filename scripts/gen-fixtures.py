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
  LUT.swift             <-> lumen_log_encode / lumen_log_decode / tetrahedral
  ColorEngine.swift     <-> lum_sat_rolloff
  ToneEngine.swift      <-> contrast_mapped
  DetailEngine.swift    <-> band_weight / band_center / dehaze_ratio
  MaskRaster.swift      <-> radial_alpha / edge_engagement
  DenoiseEngine.swift   <-> vst_inverse_blend
  DisplayTransform.swift<-> DisplayTransform
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
        "color": {"vibrance": 0, "saturation": 0, "density": 50, "protectSkin": 70},
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
        "render": {"preset": "Neutral"},
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
# Engine math fixed in this session (mirrors, so the algorithms are checked
# where Swift cannot run)
#
#   LUT.swift          <-> lumen_log_encode / lumen_log_decode / tetrahedral
#   ColorEngine.swift  <-> lum_sat_rolloff
#   ToneEngine.swift   <-> contrast_mapped
#   DetailEngine.swift <-> band_weight / realized_band_weight
# ---------------------------------------------------------------------------

MID_GREY = 0.18
MIN_EV = -12.0
MAX_EV = 12.0
LOG_RANGE = MAX_EV - MIN_EV
INV_RANGE = 1.0 / LOG_RANGE
LINEAR_CUT = MID_GREY * (2.0 ** (MIN_EV + 1.5))
TOE_SLOPE = INV_RANGE / (LINEAR_CUT * math.log(2.0))
TOE_OFFSET = 1.5 * INV_RANGE - TOE_SLOPE * LINEAR_CUT


def lumen_log_encode(x):
    if x >= LINEAR_CUT:
        return (math.log2(x / MID_GREY) - MIN_EV) * INV_RANGE
    return TOE_SLOPE * x + TOE_OFFSET


def lumen_log_decode(y):
    cut_y = TOE_SLOPE * LINEAR_CUT + TOE_OFFSET
    if y >= cut_y:
        return MID_GREY * (2.0 ** (y * LOG_RANGE + MIN_EV))
    return (y - TOE_OFFSET) / TOE_SLOPE


def tetrahedral(size, f, c):
    """Mirror of LUT3D.sample. `f` maps a grid coordinate triple to a triple."""
    n = size
    mx = n - 1
    fr, fg, fb = [min(max(v, 0.0), 1.0) * mx for v in c]
    r0, g0, b0 = int(fr), int(fg), int(fb)
    r0, g0, b0 = min(r0, mx), min(g0, mx), min(b0, mx)
    r1, g1, b1 = min(r0 + 1, mx), min(g0 + 1, mx), min(b0 + 1, mx)
    tr, tg, tb = fr - r0, fg - g0, fb - b0

    def at(r, g, b):
        return f(r / mx, g / mx, b / mx)

    c000 = at(r0, g0, b0)
    c111 = at(r1, g1, b1)

    def sub(p, q):
        return tuple(a - b for a, b in zip(p, q))

    def blend(a, b, cc):
        return tuple(c000[i] + a[i] * tr + b[i] * tg + cc[i] * tb for i in range(3))

    if tr >= tg:
        if tg >= tb:
            return blend(sub(at(r1, g0, b0), c000), sub(at(r1, g1, b0), at(r1, g0, b0)),
                         sub(c111, at(r1, g1, b0)))
        if tr >= tb:
            return blend(sub(at(r1, g0, b0), c000), sub(c111, at(r1, g0, b1)),
                         sub(at(r1, g0, b1), at(r1, g0, b0)))
        return blend(sub(at(r1, g0, b1), at(r0, g0, b1)), sub(c111, at(r1, g0, b1)),
                     sub(at(r0, g0, b1), c000))
    if tb > tg:
        return blend(sub(c111, at(r0, g1, b1)), sub(at(r0, g1, b1), at(r0, g0, b1)),
                     sub(at(r0, g0, b1), c000))
    if tb > tr:
        return blend(sub(c111, at(r0, g1, b1)), sub(at(r0, g1, b0), c000),
                     sub(at(r0, g1, b1), at(r0, g1, b0)))
    return blend(sub(at(r1, g1, b0), at(r0, g1, b0)), sub(at(r0, g1, b0), c000),
                 sub(c111, at(r1, g1, b0)))


SAT_ROLLOFF_LO0, SAT_ROLLOFF_LO1 = 0.02, 0.20
SAT_ROLLOFF_HI0, SAT_ROLLOFF_HI_WIDTH, SAT_ROLLOFF_FLOOR = 0.86, 0.35, 0.35


def smoothstep(a, b, x):
    if b <= a:
        return 0.0 if x < a else 1.0
    t = min(max((x - a) / (b - a), 0.0), 1.0)
    return t * t * (3 - 2 * t)


def lum_sat_rolloff(brightness):
    if not math.isfinite(brightness):
        return 0.0
    u = max(0.0, brightness - SAT_ROLLOFF_HI0) / SAT_ROLLOFF_HI_WIDTH
    taper = SAT_ROLLOFF_FLOOR + (1 - SAT_ROLLOFF_FLOOR) / (1 + u * u)
    return smoothstep(SAT_ROLLOFF_LO0, SAT_ROLLOFF_LO1, brightness) * taper


CONTRAST_RELAX_START, CONTRAST_RELAX_END = 4.0, 12.0


def contrast_mapped(t, contrast, pivot=0.0):
    if contrast == 0:
        return t
    slope = 1 + 0.6 * (contrast / 100.0)
    d = t - pivot
    relax = smoothstep(CONTRAST_RELAX_START, CONTRAST_RELAX_END, abs(d))
    return pivot + d * (slope + (1 - slope) * relax)


def band_weight(level, center, half_width):
    if half_width <= 0:
        return 0.0
    d = abs(level - center) / half_width
    if d >= 1:
        return 0.0
    return 0.5 * (1 + math.cos(math.pi * d))


def band_center(long_edge):
    if long_edge <= 0:
        return 1.0
    return 1.0 + min(max(math.log2(long_edge / 2560.0), -1.0), 2.0)


def gen_engine_checks():
    print("engine math (shaper / rolloff / contrast / cube / texture) ...")

    # --- the shaper -------------------------------------------------------
    check(abs(lumen_log_encode(LINEAR_CUT * (1 - 1e-12)) - lumen_log_encode(LINEAR_CUT))
          < 1e-9, "shaper toe does not meet its log branch")
    for x in [0.0, 1e-9, 1e-6, LINEAR_CUT * 0.5, LINEAR_CUT, 0.001, 0.18, 1.0, 100.0]:
        y = lumen_log_encode(x)
        check(0.0 <= y <= 1.0, f"shaper left the unit domain at {x}: {y}")
    prev, x = -1e18, 0.0
    while x < 600:
        y = lumen_log_encode(x)
        check(y >= prev - 1e-12, f"shaper reversed at {x}")
        prev = y
        x = x + 5e-6 if x < 1e-4 else x * 1.05
    for y in [0.0, 0.05, 0.25, 0.5, 0.75, 1.0]:
        check(abs(lumen_log_encode(lumen_log_decode(y)) - y) < 1e-9,
              f"shaper round trip broke at {y}")

    # --- the saturation rolloff -------------------------------------------
    for b in [1.0, 1.5, 2.0, 4.0, 20.0]:
        check(lum_sat_rolloff(b) > 0.2, f"saturation switched off at brightness {b}")
    check(abs(lum_sat_rolloff(0.5) - 1.0) < 1e-12, "rolloff not full through mid range")
    check(lum_sat_rolloff(0.0) == 0.0, "rolloff non-zero at true black")
    prev = lum_sat_rolloff(SAT_ROLLOFF_HI0)
    x = SAT_ROLLOFF_HI0
    while x < 30:
        x += 0.01
        v = lum_sat_rolloff(x)
        check(v <= prev + 1e-12, f"rolloff rose at {x}")
        check(prev - v < 0.02, f"rolloff stepped at {x}")
        prev = v
    # C1 at the knee: the taper must leave it with (near) zero slope.
    h = 1e-5
    slope = (lum_sat_rolloff(SAT_ROLLOFF_HI0 + h) - lum_sat_rolloff(SAT_ROLLOFF_HI0)) / h
    check(abs(slope) < 1e-3, f"rolloff has a kink at the knee: slope {slope}")

    # --- contrast ---------------------------------------------------------
    for c in [-100, -40, 40, 100]:
        for t in (-MAX_EV, MAX_EV):
            check(abs(contrast_mapped(t, c) - t) < 1e-9,
                  f"contrast {c} moved the end of the scale at {t} EV")
        prev = -1e18
        t = -14.0
        while t <= 14:
            m = contrast_mapped(t, c)
            check(m >= prev - 1e-9, f"contrast {c} inverted at {t} EV")
            prev = m
            t += 0.05
    for c, expected in [(100, 1.6), (50, 1.3), (-100, 0.4)]:
        s = (contrast_mapped(0.05, c) - contrast_mapped(-0.05, c)) / 0.1
        check(abs(s - expected) < 0.01, f"contrast {c} slope at pivot was {s}")

    # --- tetrahedral interpolation keeps the neutral axis -----------------
    def asym(r, g, b):
        m = (r + 2 * g + 5 * b) / 8.0
        base = m * m
        return (base + (r - m) * 0.75, base + (g - m) * 0.75, base + (b - m) * 0.75)

    for i in range(0, 201):
        y = i / 200.0
        out = tetrahedral(17, asym, (y, y, y))
        check(abs(out[0] - out[1]) < 1e-9 and abs(out[1] - out[2]) < 1e-9,
              f"cube put a cast on the neutral axis at {y}: {out}")
        check(abs(out[0] - y * y) < 2e-3, f"neutral value drifted at {y}")

    # --- texture band weights are resolution independent -------------------
    half_width = 1.6
    reference = sum(band_weight(l, 0.0, half_width) for l in range(-32, 33))
    for long_edge in [640, 1280, 2560, 5120, 10240, 20480]:
        center = band_center(long_edge)
        realized = sum(band_weight(i, center, half_width) for i in range(5))
        check(realized > 1e-9, f"no realized band weight at {long_edge}")
        normalized = sum(band_weight(i, center, half_width) * (reference / realized)
                         for i in range(5))
        check(abs(normalized - reference) < 1e-9,
              f"texture weight not normalized at long edge {long_edge}")
    # And the un-normalized sums really did differ, or the fix was a no-op.
    raw = [sum(band_weight(i, band_center(le), half_width) for i in range(5))
           for le in (1280, 2560)]
    check(abs(raw[0] - raw[1]) > 0.2,
          "texture band weights did not actually differ across resolutions")

    print("  shaper, rolloff, contrast, cube neutrality and texture scaling all hold")


# ---------------------------------------------------------------------------
# Spatial + local fixes from this session
#
#   MaskRaster.swift    <-> radial_alpha / edge_engagement
#   DetailEngine.swift  <-> dehaze_ratio
#   DenoiseEngine.swift <-> vst_inverse_blend
# ---------------------------------------------------------------------------

def radial_alpha(w, h, cx, cy, rx, ry, rotation_deg, feather, x, y):
    """Mirror of MaskRaster.radialPlane AFTER the long-edge-units fix."""
    theta = -rotation_deg * math.pi / 180.0
    ct, st = math.cos(theta), math.sin(theta)
    f = min(max(feather, 0.0), 100.0) / 100.0
    rx_px = max(rx * w, 1e-6)
    ry_px = max(ry * h, 1e-6)
    pixel_guard = min(max(1.0 / max(min(rx_px, ry_px), 1.0), 0.0), 1.0)
    rin = min(max(max(1 - f, pixel_guard), 0.0), 1 - 1e-6)

    long_edge = float(max(w, h))
    sx, sy = w / long_edge, h / long_edge
    cxl, cyl = cx * sx, cy * sy
    rxl, ryl = max(rx * sx, 1e-12), max(ry * sy, 1e-12)

    dv = (y + 0.5) / long_edge - cyl
    du = (x + 0.5) / long_edge - cxl
    qx = du * ct - dv * st
    qy = du * st + dv * ct
    r = math.hypot(qx / rxl, qy / ryl)
    if r <= rin:
        return 1.0
    if r >= 1:
        return 0.0
    return smoothstep(1.0, rin, r)


def edge_engagement(shift):
    return min(max(abs(shift), 0.0), 1.0)


def dehaze_ratio(y0, y1, magnitude):
    """Mirror of the fixed guard in DetailEngine.applyDehaze."""
    trust = smoothstep(0.01, 0.05, abs(y0) / magnitude) if magnitude > 0 else 0.0
    ratio = min(max(y1 / y0, 0.05), 20.0) if y0 != 0 else 1.0
    return 1.0 + (ratio - 1.0) * trust


def vst_inverse_blend(algebraic, unbiased, shrinkage):
    t = min(max(shrinkage, 0.0), 1.0)
    if t >= 1:
        return unbiased
    if t <= 0:
        return algebraic
    return algebraic + (unbiased - algebraic) * t


def gen_spatial_checks():
    print("spatial + local math (radial / edge / dehaze / denoise) ...")

    # --- a rotated ellipse must render at the angle it was given ----------
    # The bug: rotating in normalized coordinates mixed fractions-of-width with
    # fractions-of-height, so on a 3:2 frame a 45 degree ellipse drew at 33.7.
    w, h = 300, 200                       # 3:2
    for wanted in (0.0, 30.0, 45.0, 60.0, 120.0):
        best, best_r2 = None, -1.0
        for yy in range(h):
            for xx in range(w):
                if radial_alpha(w, h, 0.5, 0.5, 0.20, 0.10, wanted, 0, xx, yy) <= 0:
                    continue
                dx = (xx + 0.5) - 0.5 * w
                dy = (yy + 0.5) - 0.5 * h
                r2 = dx * dx + dy * dy
                if r2 > best_r2:
                    best_r2, best = r2, (dx, dy)
        # Angle of the farthest covered pixel = the major axis, in pixel space.
        got = math.degrees(math.atan2(best[1], best[0])) % 180.0
        want = wanted % 180.0
        delta = min(abs(got - want), 180 - abs(got - want))
        check(delta < 4.0,
              f"radial mask at {wanted} deg rendered at {got:.1f} deg on a 3:2 frame")

    # An unrotated ellipse must still be exactly as wide and tall as asked.
    covered_x = [xx for xx in range(w)
                 if radial_alpha(w, h, 0.5, 0.5, 0.20, 0.10, 0, 0, xx, h // 2) > 0]
    covered_y = [yy for yy in range(h)
                 if radial_alpha(w, h, 0.5, 0.5, 0.20, 0.10, 0, 0, w // 2, yy) > 0]
    check(abs(len(covered_x) - 2 * 0.20 * w) < 2,
          f"unrotated ellipse width wrong: {len(covered_x)} px")
    check(abs(len(covered_y) - 2 * 0.10 * h) < 2,
          f"unrotated ellipse height wrong: {len(covered_y)} px")

    # --- the Edge control must ramp in, not switch on ---------------------
    check(edge_engagement(0.0) == 0.0, "edge engaged at zero shift")
    prev = 0.0
    s = 0.0
    while s <= 2.0:
        e = edge_engagement(s)
        check(e - prev < 0.06, f"edge engagement stepped at shift {s}")
        prev = e
        s += 0.05
    check(edge_engagement(1.0) == 1.0, "edge never reaches full engagement")

    # --- dehaze must not swing on the sign of a near-zero luminance -------
    # y1 is a fixed negative number there; the old code substituted a SIGNED
    # epsilon for y0, so the sign alone chose between the 0.05 and 20 clamps.
    y1 = -0.004
    noise_mag = 0.02                      # the (-0.02, +0.009, -0.01) shadow-noise case
    left = dehaze_ratio(-1e-7, y1, noise_mag)
    right = dehaze_ratio(+1e-7, y1, noise_mag)
    check(abs(left - right) < 0.01,
          f"dehaze swings across zero luminance: {left} vs {right}")
    check(abs(dehaze_ratio(0.0, y1, noise_mag) - 1.0) < 1e-12,
          "dehaze not identity at zero")
    prev = None
    v = -1e-4
    while v <= 1e-4:
        r = dehaze_ratio(v, y1, noise_mag)
        if prev is not None:
            check(abs(r - prev) < 0.02, f"dehaze stepped at luminance {v}")
        prev = r
        v += 2e-6
    # ...and a saturated blue, whose luminance is only six percent of its peak
    # channel, must still dehaze at full strength rather than being mistaken for
    # cancelled noise.
    blue_luma = 0.0593
    check(abs(dehaze_ratio(blue_luma, blue_luma * 0.7, 1.0) - 0.7) < 0.02,
          "dehaze stopped working on a saturated blue")

    # --- the denoise inverse blend ----------------------------------------
    alg, unb = 1.0, 1.0 + 0.25 * 1.024e-2      # pedestal at ISO 102400
    check(vst_inverse_blend(alg, unb, 0.0) == alg, "blend not algebraic at zero")
    check(vst_inverse_blend(alg, unb, 1.0) == unb, "blend not unbiased at full")
    # Luminance 1 gives k/kmax = 4*(0.01^0.7)/4 ~= 0.04, so the first step must
    # carry about a twenty-fifth of the pedestal, not all of it.
    first = 4.0 * (0.01 ** 0.7) / 4.0
    lift = vst_inverse_blend(alg, unb, first) - alg
    check(lift < (unb - alg) * 0.1,
          f"first denoise step still carries {lift / (unb - alg):.0%} of the pedestal")

    print("  rotation isotropy, edge ramp, dehaze continuity and denoise blend hold")


# ---------------------------------------------------------------------------
# THE display transform (D8)
#
#   DisplayTransform.swift <-> DisplayTransform
#
# Its four constraints are supposed to hold BY CONSTRUCTION rather than by
# clamping, which is exactly the kind of claim worth executing.
# ---------------------------------------------------------------------------

def srgb_encode(x):
    if x <= 0.0031308:
        return 12.92 * x
    return 1.055 * (abs(x) ** (1 / 2.4)) * (1 if x >= 0 else -1) - 0.055


def srgb_decode(x):
    if x <= 0.04045:
        return x / 12.92
    return ((x + 0.055) / 1.055) ** 2.4


SKEW_SHAPE = 2.0


class DisplayTransform:
    def __init__(self, contrast=1.5, skew=0.0, white_target=100.0,
                 black_target=0.0152, white_anchor_ev=5.0, black_anchor_ev=-9.0):
        w = max(white_target, 1) / 100.0
        b = min(max(black_target, 0), 15) / 100.0
        self.white = w
        self.black = min(b, MID_GREY * 0.5)

        hi = max(white_anchor_ev, 0.5)
        lo = min(black_anchor_ev, -0.5)
        self.min_ev = lo
        self.range = hi - lo
        self.pivot_x = (0 - lo) / (hi - lo)

        eb, ew, ep = srgb_encode(self.black), srgb_encode(w), srgb_encode(MID_GREY)
        self.encoded_black, self.encoded_white = eb, ew
        span = max(ew - eb, 1e-6)
        py = min(max((ep - eb) / span, 0.01), 0.99)
        self.pivot_y = py

        c = min(max(contrast, 0.1), 10)
        h = 1e-6
        slope_of_decode = max((srgb_decode(ep + h) - srgb_decode(ep - h)) / (2 * h), 1e-9)
        m = c * MID_GREY * math.log(2.0) * (hi - lo) / (slope_of_decode * span)

        a_toe = m * self.pivot_x / py
        a_shoulder = m * (1 - self.pivot_x) / (1 - py)
        sk = min(max(skew, -1), 1)
        self.toe_lambda = min(max(sk * 0.5, -1), a_toe / SKEW_SHAPE * 0.9)
        self.shoulder_lambda = min(max(-sk * 0.5, -1), a_shoulder / SKEW_SHAPE * 0.9)
        self.toe_power = a_toe - self.toe_lambda * SKEW_SHAPE
        self.shoulder_power = a_shoulder - self.shoulder_lambda * SKEW_SHAPE

    def normalized_curve(self, x):
        X = min(max(x, 0.0), 1.0)
        if X < self.pivot_x:
            if self.pivot_x <= 0:
                return 0.0
            u = X / self.pivot_x
            return (self.pivot_y * (u ** self.toe_power)
                    * (1 - self.toe_lambda + self.toe_lambda * u ** SKEW_SHAPE))
        if self.pivot_x >= 1:
            return 1.0
        u = (1 - X) / (1 - self.pivot_x)
        s = ((u ** self.shoulder_power)
             * (1 - self.shoulder_lambda + self.shoulder_lambda * u ** SKEW_SHAPE))
        return 1 - (1 - self.pivot_y) * s

    def tone(self, x):
        if x <= 0:
            return self.black
        ev = math.log2(x / MID_GREY)
        X = (ev - self.min_ev) / self.range
        Y = self.normalized_curve(X)
        return srgb_decode(self.encoded_black
                           + (self.encoded_white - self.encoded_black) * Y)


def gen_display_transform_checks():
    print("the display transform (anchors / monotonicity / HDR) ...")

    cases = [dict(), dict(contrast=1.2, skew=0.2), dict(contrast=2.2, skew=-0.3),
             dict(white_anchor_ev=3.0, black_anchor_ev=-6.0),
             dict(white_anchor_ev=7.5, black_anchor_ev=-11.0),
             dict(white_target=400.0), dict(white_target=1600.0, contrast=1.8)]

    for kw in cases:
        t = DisplayTransform(**kw)
        label = kw or "default"

        # 1. Mid-grey lands on 0.18 display-linear, ABSOLUTELY, at every peak.
        got = t.tone(MID_GREY)
        check(abs(got - MID_GREY) < 2e-3,
              f"{label}: mid-grey landed at {got:.5f}, not 0.18")

        # 2 + 3. The scene anchors land on the display's black and white targets.
        lo_scene = MID_GREY * 2 ** t.min_ev
        hi_scene = MID_GREY * 2 ** (t.min_ev + t.range)
        check(abs(t.tone(lo_scene) - t.black) < 1e-4,
              f"{label}: black anchor landed at {t.tone(lo_scene)}, not {t.black}")
        check(abs(t.tone(hi_scene) - t.white) < 1e-4,
              f"{label}: white anchor landed at {t.tone(hi_scene)}, not {t.white}")

        # 4. Log-log slope at mid-grey equals `contrast`, independent of skew.
        wanted = kw.get("contrast", 1.5)
        d = 1e-4
        a = math.log2(t.tone(MID_GREY * 2 ** -d))
        bb = math.log2(t.tone(MID_GREY * 2 ** d))
        slope = (bb - a) / (2 * d)
        check(abs(slope - wanted) < 0.02,
              f"{label}: log-log slope at mid-grey was {slope:.4f}, wanted {wanted}")

        # Monotone across the whole scene domain, and bounded by the targets.
        prev, ev = -1e18, MIN_EV
        while ev <= MAX_EV:
            v = t.tone(MID_GREY * 2 ** ev)
            check(v >= prev - 1e-12, f"{label}: transform inverted at {ev} EV")
            check(t.black - 1e-9 <= v <= t.white + 1e-9,
                  f"{label}: transform left [black, white] at {ev} EV: {v}")
            prev = v
            ev += 0.02

    # Skew must move the curve's shape without moving the pivot slope — that is
    # the whole claim of the two-power construction.
    d = 1e-4
    slopes = []
    for skew in (-0.8, -0.4, 0.0, 0.4, 0.8):
        t = DisplayTransform(skew=skew)
        a = math.log2(t.tone(MID_GREY * 2 ** -d))
        bb = math.log2(t.tone(MID_GREY * 2 ** d))
        slopes.append((bb - a) / (2 * d))
    check(max(slopes) - min(slopes) < 0.01,
          f"skew moved the pivot slope: {[round(s, 4) for s in slopes]}")
    # ...and it really did change the curve, or the invariance is vacuous.
    # Relative, not absolute: four stops under mid-grey the display values are
    # around 0.003, where any absolute threshold is arbitrary. Skew moves the toe
    # by 40 % there and the shoulder by a few percent — it is a shape control, so
    # the toe is where to look.
    for ev, want in ((-4.0, 0.15), (3.0, 0.01)):
        lo_s = DisplayTransform(skew=-0.8).tone(MID_GREY * 2 ** ev)
        hi_s = DisplayTransform(skew=0.8).tone(MID_GREY * 2 ** ev)
        rel = abs(hi_s - lo_s) / max(abs(lo_s), 1e-12)
        check(rel > want,
              f"skew changed the curve by only {rel:.1%} at {ev} EV")

    # HDR: raising the display peak must not raise the black floor, and must not
    # move mid-grey — the highlights get let out, the picture does not brighten.
    sdr = DisplayTransform(white_target=100)
    hdr = DisplayTransform(white_target=1000)
    check(abs(sdr.black - hdr.black) < 1e-12, "raising the peak raised the floor")
    check(abs(sdr.tone(MID_GREY) - hdr.tone(MID_GREY)) < 2e-3,
          "raising the peak moved mid-grey")
    check(hdr.tone(MID_GREY * 2 ** 4) > sdr.tone(MID_GREY * 2 ** 4),
          "raising the peak did not let the highlights out")

    print("  four anchors, monotonicity, skew invariance and HDR headroom all hold")


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
    gen_engine_checks()
    gen_spatial_checks()
    gen_display_transform_checks()
    if FAILURES:
        print(f"\n{len(FAILURES)} verification failure(s)")
        sys.exit(1)
    print("\nAll fixtures generated; all Linux-side verifications passed.")


if __name__ == "__main__":
    main()
