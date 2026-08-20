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
  GradeEngine.swift     <-> ZoneWindows / solve_lum_scale
  MaskAlgebra.swift     <-> mask_combined
  LUT.swift             <-> lumen_log_encode / lumen_log_decode / tetrahedral
  ColorEngine.swift     <-> lum_sat_rolloff / vibrance_saturation
  ToneEngine.swift      <-> contrast_mapped / ToneEngine
  DetailEngine.swift    <-> band_weight / band_center / dehaze_ratio
  MaskRaster.swift      <-> radial_alpha / edge_engagement
  DenoiseEngine.swift   <-> vst_inverse_blend
  DisplayTransform.swift<-> DisplayTransform
  SpatialOps.swift      <-> box_blur / guided_filter
  BlobStore.swift       <-> blob_filename
  Perceptual.swift      <-> oklab_* / ucs_*
  ColorSpaces.swift     <-> locus / temperature_and_tint
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
    """Mirror of CanonicalJSON.canonicalNumber.

    Shortest representation that round-trips, tried at 15, 16 then 17 significant
    digits. Both sides go through C printf, so the bytes match.
    """
    assert math.isfinite(d), "non-finite number in recipe JSON"
    if d == round(d) and abs(d) < 1e15:
        i = int(d)
        return "0" if i == 0 else str(i)
    for precision in (15, 16, 17):
        text = "%.*g" % (precision, d)
        if float(text) == d:
            return text
    return "%.17g" % d


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


def render_identity(tree):
    """Mirror of Recipe.renderIdentity — what the fingerprint hashes.

    Masks lose their name and their id: the name is a panel label, and the id is a
    random UUID whose presence meant renaming a mask threw away every cached render
    and two photos with identical mask edits could never share one.
    """
    out = json.loads(json.dumps(tree))
    for mask in out.get("masks", []) or []:
        mask["name"] = ""
        mask["id"] = ""
    return out


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
    cases.append({"name": "default", "canonical": a_canon,
                  "fingerprint": fp(canonical_recipe_json(render_identity(defaults), defaults))})

    # Case B: a plausible develop edit (mirrors RecipeCodecTests.caseB in Swift).
    b = json.loads(json.dumps(defaults))  # deep copy
    b["develop"]["raw"]["temp"] = 5200
    b["develop"]["raw"]["tint"] = 8
    b["develop"]["tone"]["exposure"] = 0.35
    b["develop"]["tone"]["shadows"] = 25
    b_canon = canonical_recipe_json(b, defaults)
    cases.append({"name": "developEdit", "canonical": b_canon,
                  "fingerprint": fp(canonical_recipe_json(render_identity(b), defaults))})
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
    cases.append({"name": "maskAndLook", "canonical": c_canon,
                  "fingerprint": fp(canonical_recipe_json(render_identity(c), defaults))})
    check('"filmLab"' in c_canon and '"aiSky"' in c_canon,
          f"case C canonical missing fields: {c_canon[:200]}")

    # Case D: numbers that six significant digits could not represent. Until this
    # existed, every fixture value round-tripped at 6 digits by luck, so the whole
    # `%.6g` truncation — lossy save AND fingerprint aliasing — was invisible to the
    # fixtures. Two recipes differing only past the sixth figure must produce
    # different canonical strings and different fingerprints.
    d1 = json.loads(json.dumps(defaults))
    d1["develop"]["tone"]["exposure"] = 1.2345678901234
    d1["develop"]["raw"]["temp"] = 5123.456789
    d1["look"]["vignette"] = -0.30000000000000004      # a real float-arithmetic result
    d1_canon = canonical_recipe_json(d1, defaults)
    cases.append({"name": "beyondSixFigures", "canonical": d1_canon,
                  "fingerprint": fp(canonical_recipe_json(render_identity(d1), defaults))})

    d2 = json.loads(json.dumps(d1))
    d2["develop"]["tone"]["exposure"] = 1.2345678901235   # differs in the 14th digit
    d2_canon = canonical_recipe_json(d2, defaults)
    check(d1_canon != d2_canon,
          "two recipes differing past the sixth figure serialized identically")
    check(fp(d1_canon) != fp(d2_canon),
          "two recipes that render differently share a fingerprint")
    cases.append({"name": "beyondSixFiguresNeighbour", "canonical": d2_canon,
                  "fingerprint": fp(canonical_recipe_json(render_identity(d2), defaults))})

    # ...and serialization must be lossless: what comes back parses to what went in.
    for value in (1.2345678901234, 0.1, 1 / 3, 5123.456789, -0.30000000000000004,
                  1e-7, 2.5e20, 1234567.5):
        check(float(canonical_number(value)) == value,
              f"canonical_number lost {value!r} -> {canonical_number(value)}")

    # Renaming a mask must not change the fingerprint — it keys every cached
    # render — and two photos given identical mask edits must share one.
    renamed = json.loads(json.dumps(c))
    renamed["masks"][0]["name"] = "Sky (final)"
    renamed["masks"][0]["id"] = "6f000000-0000-0000-0000-0000000zzz99"
    check(fp(canonical_recipe_json(render_identity(c), defaults))
          == fp(canonical_recipe_json(render_identity(renamed), defaults)),
          "renaming a mask changed the render fingerprint")
    check(c_canon != canonical_recipe_json(renamed, defaults),
          "the stored recipe lost the mask name — only the fingerprint should")

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
    # Characters below 0x20 other than tab/LF/CR are illegal in XML 1.0 even as
    # numeric references, so they are dropped rather than escaped — matching the Swift.
    s = "".join(ch for ch in s if ord(ch) >= 0x20 or ch in "\t\n\r")
    return (s.replace("&", "&amp;").replace("<", "&lt;")
             .replace(">", "&gt;").replace('"', "&quot;"))


def xmp_serialize(content):
    fields = ""
    fields += f"   <xmp:Rating>{content['rating']}</xmp:Rating>\n"
    # `lumen:flag` rather than Lightroom's `xmp:Rating = -1`: Lumen keeps flag and
    # rating as separate axes, so overloading the rating would destroy one of them.
    if content.get("flag", "none") != "none":
        fields += f"   <lumen:flag>{content['flag']}</lumen:flag>\n"
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
         "content": {"rating": 5, "flag": "pick", "label": None, "pipelineVersion": 1,
                     "recipeFingerprint": None, "recipeJSON": None,
                     "catalogUUID": None, "writeStamp": None}},
        # A reject that is also rated. Lightroom's convention would write
        # xmp:Rating = -1 and lose the four stars; these are separate axes here.
        {"name": "rejectedButRated",
         "content": {"rating": 4, "flag": "reject", "label": "blue",
                     "pipelineVersion": 1, "recipeFingerprint": None,
                     "recipeJSON": None, "catalogUUID": None, "writeStamp": None}},
        # A label carrying a control character: illegal in XML 1.0 even as a numeric
        # reference, so emitting it would produce a sidecar nothing can read back.
        {"name": "controlCharacters",
         "content": {"rating": 1, "label": "bad\u0007label\u0000", "pipelineVersion": 1,
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
        want_flag = c["content"].get("flag", "none")
        got_flag = desc.find("lumen:flag", ns)
        check((got_flag.text if got_flag is not None else "none") == want_flag,
              f"xmp {c['name']} flag round-trip")
        # The rating must survive a reject: they are separate axes.
        if want_flag == "reject":
            check(int(rating.text) == c["content"]["rating"],
                  f"xmp {c['name']} lost the rating to the reject flag")
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


def clamp(v, lo, hi):
    """`Num.clamp`. Spelled out rather than nested min/max so the mirror reads like
    the Swift it mirrors."""
    return lo if v < lo else (hi if v > hi else v)


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
# The spatial primitive everything is built on, and the blob-ref validator
#
#   SpatialOps.swift <-> box_blur / guided_filter
#   BlobStore.swift  <-> blob_filename
# ---------------------------------------------------------------------------

def clamped(p, w, h, x, y):
    return p[min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)]


def box_blur(p, w, h, radius):
    if radius <= 0:
        return list(p)
    r = min(radius, max(w, h))
    n = float(2 * r + 1)
    tmp = [0.0] * (w * h)
    for y in range(h):
        s = sum(clamped(p, w, h, k, y) for k in range(-r, r + 1))
        tmp[y * w] = s / n
        for x in range(1, w):
            s += clamped(p, w, h, x + r, y) - clamped(p, w, h, x - r - 1, y)
            tmp[y * w + x] = s / n
    out = [0.0] * (w * h)
    for x in range(w):
        s = sum(clamped(tmp, w, h, x, k) for k in range(-r, r + 1))
        out[x] = s / n
        for y in range(1, h):
            s += clamped(tmp, w, h, x, y + r) - clamped(tmp, w, h, x, y - r - 1)
            out[y * w + x] = s / n
    return out


def guided_filter(inp, guide, w, h, radius, epsilon):
    if radius <= 0:
        return list(inp)
    eps = max(epsilon, 1e-12)
    mean_i = box_blur(guide, w, h, radius)
    mean_p = box_blur(inp, w, h, radius)
    corr_i = box_blur([g * g for g in guide], w, h, radius)
    corr_ip = box_blur([g * p for g, p in zip(guide, inp)], w, h, radius)
    a, b = [0.0] * (w * h), [0.0] * (w * h)
    for i in range(w * h):
        var_i = max(corr_i[i] - mean_i[i] * mean_i[i], 0.0)
        cov = corr_ip[i] - mean_i[i] * mean_p[i]
        av = cov / (var_i + eps)
        a[i] = av
        b[i] = mean_p[i] - av * mean_i[i]
    mean_a = box_blur(a, w, h, radius)
    mean_b = box_blur(b, w, h, radius)
    return [mean_a[i] * guide[i] + mean_b[i] for i in range(w * h)]


def blob_filename(ref):
    """Mirror of BlobStore.filename(for:) — the untrusted-reference gate."""
    parts = ref.split(":")
    if len(parts) != 3 or parts[0] != "blob":
        return None
    algorithm, digest = parts[1], parts[2]
    if algorithm != "xxh64" or len(digest) != 16:
        return None
    for ch in digest:
        if not (ch.isascii() and (ch.isdigit() or ("a" <= ch <= "f"))):
            return None
    return algorithm + "-" + digest + ".blob"


def gen_spatial_primitive_checks():
    print("guided filter + blob reference validation ...")

    w, h = 48, 16

    # A constant plane must blur to itself EXACTLY, borders included. The whole
    # edge convention (clamped repeats, divided by the full window) rests on it.
    for radius in (1, 3, 8, 40):
        flat = [0.37] * (w * h)
        out = box_blur(flat, w, h, radius)
        check(max(abs(v - 0.37) for v in out) < 1e-12,
              f"constant plane did not blur to itself at radius {radius}")

    # A constant plane is a fixed point of the guided filter too.
    flat = [0.37] * (w * h)
    gf = guided_filter(flat, flat, w, h, 4, 0.01)
    check(max(abs(v - 0.37) for v in gf) < 1e-9, "guided filter moved a constant plane")

    # The defining property, stated the way the docstring states it: epsilon is a
    # VARIANCE threshold in the guide's own units, so the filter smooths anything
    # flatter than sqrt(eps) and keeps anything above it. Testing that directly is
    # worth more than testing "it smooths", and it is the semantics anyone reading
    # a call site has to trust.
    eps = 0.0008
    threshold = math.sqrt(eps)                      # 0.0283
    step = [0.2 if (i % w) < w // 2 else 0.8 for i in range(w * h)]

    def interior_swing(amp):
        noisy = [v + (amp if (i // w + i % w) % 2 == 0 else -amp)
                 for i, v in enumerate(step)]
        out = guided_filter(noisy, noisy, w, h, 4, eps)
        left = [out[y * w + x] for y in range(4, h - 4) for x in range(4, w // 2 - 6)]
        right = [out[y * w + x] for y in range(4, h - 4)
                 for x in range(w // 2 + 6, w - 4)]
        swing = max(max(left) - min(left), max(right) - min(right))
        edge = sum(right) / len(right) - sum(left) / len(left)
        return swing, edge, out

    quiet_amp = threshold / 4
    swing, edge, out = interior_swing(quiet_amp)
    check(swing < 2 * quiet_amp * 0.35,
          f"noise well under sqrt(eps) was kept: {swing:.4f} of {2 * quiet_amp:.4f}")
    check(edge > 0.6 * 0.8, f"guided filter smeared the step: {edge:.3f} of 0.6")
    # No overshoot — the whole reason this is an affine model and not a bilateral.
    check(min(out) > 0.2 - 0.02 and max(out) < 0.8 + 0.02,
          f"guided filter overshot: [{min(out):.3f}, {max(out):.3f}]")

    loud_amp = threshold * 3.5
    swing, edge, _ = interior_swing(loud_amp)
    check(swing > 2 * loud_amp * 0.5,
          f"detail well over sqrt(eps) was smoothed away: {swing:.4f} of {2 * loud_amp:.4f}")
    check(edge > 0.6 * 0.8, f"guided filter smeared the step under load: {edge:.3f}")

    # --- the blob reference gate ------------------------------------------
    good = "blob:xxh64:0123456789abcdef"
    check(blob_filename(good) == "xxh64-0123456789abcdef.blob", "a valid ref was refused")
    hostile = [
        "blob:xxh64:../../../etc/pas",     # right length, path characters
        "blob:xxh64:0123456789ABCDEF",     # uppercase
        "blob:xxh64:0123456789abcde",      # short
        "blob:xxh64:0123456789abcdef0",    # long
        "blob:sha256:0123456789abcdef",    # wrong algorithm
        "blob:xxh64:0123456789abcde/",
        "blob:xxh64:../a/../b/../c/x",
        "file:xxh64:0123456789abcdef",
        "blob:xxh64:",
        "blob:xxh64",
        "",
        "blob:xxh64:0123456789abcde\n",
        "blob:xxh64:zzzzzzzzzzzzzzzz",
        "blob:xxh64:\uff10\uff11\uff12\uff13\uff14\uff15\uff16\uff17"
        "\uff18\uff19\uff41\uff42\uff43\uff44\uff45\uff46",   # fullwidth hex
        "../../blob:xxh64:0123456789abcdef",
    ]
    for ref in hostile:
        name = blob_filename(ref)
        check(name is None,
              f"hostile blob ref accepted: {ref!r} -> {name!r}")
        if name is not None:
            continue
    # Nothing that survives can contain a path separator or a dot-segment.
    check(all(("/" not in n and "\\\\" not in n and ".." not in n)
              for n in [blob_filename(good)]),
          "an accepted ref carried path syntax")

    # --- the export subfolder must not escape the chosen directory ---------
    def sanitize_subfolder(sub):
        out = []
        for component in sub.split("/"):
            cleaned = component.replace(":", "-").strip()
            if not cleaned or cleaned in (".", ".."):
                continue
            out.append(cleaned)
        return out

    for hostile in ("../../..", "..", "./../etc", "a/../../b", "/etc/passwd",
                    "//..//..//", "  ..  /x"):
        parts = sanitize_subfolder(hostile)
        check(all(p not in (".", "..") and "/" not in p for p in parts),
              f"subfolder {hostile!r} survived sanitizing as {parts}")
    check(sanitize_subfolder("Web/2026") == ["Web", "2026"],
          "an ordinary subfolder was mangled")

    print("  constant fixed point, edge preservation, no overshoot, hostile refs refused")


# ---------------------------------------------------------------------------
# OKLab and Lumen UCS — the foundation every colour tool sits on
#
#   Perceptual.swift <-> oklab_* / ucs_*
#
# Three invariants are stated in that file's own comments. All three are the
# kind that quietly stop holding and take every downstream stage with them.
# ---------------------------------------------------------------------------

def mat_mul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)]
            for i in range(3)]


def mat_apply(m, v):
    return tuple(sum(m[i][j] * v[j] for j in range(3)) for i in range(3))


def mat_inverse(m):
    (a, b, c), (d, e, f), (g, h, i) = m
    det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
    return [[(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det],
            [(f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det],
            [(d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det]]


def rgb_to_xyz(red, green, blue, white):
    def xyz_of(ch):
        x, y = ch
        return (x / y, 1.0, (1 - x - y) / y)
    r, g, b = xyz_of(red), xyz_of(green), xyz_of(blue)
    m = [[r[0], g[0], b[0]], [r[1], g[1], b[1]], [r[2], g[2], b[2]]]
    wx, wy = white
    w = (wx / wy, 1.0, (1 - wx - wy) / wy)
    s = mat_apply(mat_inverse(m), w)
    return [[m[i][j] * s[j] for j in range(3)] for i in range(3)]


XYZ_TO_LMS = [[0.8189330101, 0.3618667424, -0.1288597137],
              [0.0329845436, 0.9293118715, 0.0361456387],
              [0.0482003018, 0.2643662691, 0.6338517070]]
LMS_TO_LAB = [[0.2104542553, 0.7936177850, -0.0040720468],
              [1.9779984951, -2.4285922050, 0.4505937099],
              [0.0259040371, 0.7827717662, -0.8086757660]]
# The published b row sums to +3.73e-8 rather than zero, so an achromatic input —
# whose three nonlinear LMS values are equal — picks up that much chroma from the
# constants alone. Force both chroma rows to sum to zero, as the Swift does.
for _row in (1, 2):
    _share = sum(LMS_TO_LAB[_row]) / 3
    LMS_TO_LAB[_row] = [v - _share for v in LMS_TO_LAB[_row]]

_REC2020_TO_XYZ = rgb_to_xyz((0.708, 0.292), (0.170, 0.797), (0.131, 0.046),
                             (0.3127, 0.3290))
_RGB_TO_LMS = mat_mul(XYZ_TO_LMS, _REC2020_TO_XYZ)
_WHITE_LMS = mat_apply(_RGB_TO_LMS, (1.0, 1.0, 1.0))
# The white normalization the Swift applies, for the reason its comment gives.
_RGB_TO_LMS = [[_RGB_TO_LMS[i][j] / _WHITE_LMS[i] for j in range(3)] for i in range(3)]
_LMS_TO_RGB = mat_inverse(_RGB_TO_LMS)
_LAB_TO_LMS = mat_inverse(LMS_TO_LAB)


def spow(x, e):
    return math.copysign(abs(x) ** e, x)


def oklab_from_rgb(c):
    lms = mat_apply(_RGB_TO_LMS, c)
    n = tuple(spow(v, 1 / 3) for v in lms)
    return mat_apply(LMS_TO_LAB, n)


def oklab_to_rgb(lab):
    n = mat_apply(_LAB_TO_LMS, lab)
    return mat_apply(_LMS_TO_RGB, tuple(v ** 3 for v in n))


def oklch_from_rgb(c):
    L, a, b = oklab_from_rgb(c)
    return L, math.hypot(a, b), math.degrees(math.atan2(b, a)) % 360.0


def oklch_to_rgb(L, C, h):
    t = math.radians(h)
    return oklab_to_rgb((L, C * math.cos(t), C * math.sin(t)))


K_BR = 0.2717 * (6.469 + 6.362 * 160.0 ** 0.4495) / (6.469 + 160.0 ** 0.4495)


def hk_q(hue_deg):
    t = math.radians(hue_deg % 360.0)
    return (-0.01585 - 0.03017 * math.cos(t) - 0.04556 * math.cos(2 * t)
            - 0.04256 * math.cos(3 * t) - 0.00295 * math.cos(4 * t)
            + 0.14592 * math.sin(t) + 0.05084 * math.sin(2 * t)
            - 0.01900 * math.sin(3 * t) - 0.00764 * math.sin(4 * t))


def hk_factor(chroma, hue):
    s = max(0.0, chroma) * 4.0
    return 1 + (-0.1340 * hk_q(hue) + 0.0872 * K_BR) * s * 0.1


def ucs_from_rgb(c):
    L, C, h = oklch_from_rgb(c)
    return L * hk_factor(C, h), C, h


def ucs_to_rgb(J, C, h):
    f = hk_factor(C, h)
    return oklch_to_rgb(J if f == 0 else J / f, C, h)


def ucs_scale_chroma(c, factor):
    J, C, h = ucs_from_rgb(c)
    return ucs_to_rgb(J, max(0.0, C * factor), h)


def ucs_scale_brightness(c, factor):
    J, C, h = ucs_from_rgb(c)
    if J == 0:
        return c
    return ucs_to_rgb(J * factor, C * (factor if factor > 0 else 0), h)


def gen_perceptual_checks():
    print("OKLab + Lumen UCS invariants ...")

    # 1. A neutral has EXACTLY zero chroma. The file normalizes the LMS matrix for
    #    this, because Rec.2020's white and the matrix's own D65 differ in the
    #    fourth decimal and every colour stage would inherit the error.
    for v in (1e-4, 0.01, 0.18, 0.5, 1.0, 4.0, 40.0):
        _, C, _ = oklch_from_rgb((v, v, v))
        check(C < 1e-12, f"a neutral at {v} carried chroma {C:.3e}")
    check(hk_factor(0.0, 123.0) == 1.0, "a neutral got an H-K brightness boost")

    # 2. Round trip, including well above display white — this is scene-referred.
    for c in [(0.18, 0.18, 0.18), (0.9, 0.2, 0.05), (0.02, 0.3, 0.11),
              (3.2, 1.1, 0.4), (0.001, 0.002, 0.004), (12.0, 9.0, 7.0)]:
        back = oklab_to_rgb(oklab_from_rgb(c))
        check(max(abs(x - y) for x, y in zip(back, c)) < 1e-9,
              f"OKLab round trip lost {c} -> {back}")

    # 3. The two invariants the colour tools rely on:
    #    a chroma move must not change perceived brightness,
    #    a brightness move must keep the chroma RATIO (no wash-out).
    for c in [(0.9, 0.2, 0.05), (0.15, 0.4, 0.2), (0.3, 0.3, 0.9),
              (2.4, 1.2, 0.6), (0.05, 0.06, 0.05)]:
        J0, C0, _ = ucs_from_rgb(c)
        for factor in (0.25, 0.5, 1.5, 3.0):
            J1, _, _ = ucs_from_rgb(ucs_scale_chroma(c, factor))
            check(abs(J1 - J0) < 1e-9,
                  f"scaling chroma by {factor} moved brightness {J0:.6f} -> {J1:.6f}")

            J2, C2, _ = ucs_from_rgb(ucs_scale_brightness(c, factor))
            check(abs(J2 - J0 * factor) < 1e-9,
                  f"scaling brightness by {factor} gave {J2:.6f}, wanted {J0 * factor:.6f}")
            if C0 > 1e-9:
                check(abs(C2 / J2 - C0 / J0) < 1e-9,
                      f"brightness by {factor} changed the chroma ratio "
                      f"{C0 / J0:.6f} -> {C2 / J2:.6f}")

    # 4. Hue is untouched by either move — a saturation slider that rotates hue is
    #    the classic way this construction goes wrong.
    for c in [(0.9, 0.2, 0.05), (0.2, 0.5, 0.9), (0.4, 0.6, 0.2)]:
        _, _, h0 = ucs_from_rgb(c)
        for factor in (0.3, 2.5):
            _, _, h1 = ucs_from_rgb(ucs_scale_chroma(c, factor))
            _, _, h2 = ucs_from_rgb(ucs_scale_brightness(c, factor))
            for got, what in ((h1, "chroma"), (h2, "brightness")):
                d = min(abs(got - h0), 360 - abs(got - h0))
                check(d < 1e-6, f"{what} by {factor} rotated hue by {d:.4f} deg")

    # 5. Scene-referred means unbounded: none of this may fall over above white.
    for v in (1.0, 8.0, 64.0, 512.0):
        out = ucs_scale_chroma((v, v * 0.6, v * 0.3), 1.4)
        check(all(math.isfinite(x) for x in out), f"UCS produced a non-finite at {v}")

    print("  neutrals exact, round trip clean, brightness/chroma/hue invariants hold")


# ---------------------------------------------------------------------------
# White balance: the temperature locus and the eyedropper's inverse
#
#   ColorSpaces.swift <-> locus / wb_chromaticity / temperature_and_tint
# ---------------------------------------------------------------------------

MIN_KELVIN, MAX_KELVIN = 2000.0, 50000.0
TINT_UNIT_IN_V = 0.05 / 150.0


def xy_to_uv(x, y):
    d = -2 * x + 12 * y + 3
    return (0.0, 0.0) if d == 0 else (4 * x / d, 6 * y / d)


def uv_to_xy(u, v):
    d = 2 * u - 8 * v + 4
    return (0.0, 0.0) if d == 0 else (3 * u / d, 2 * v / d)


def planck_x(t):
    if t <= 4000:
        return (-0.2661239e9 / t ** 3 - 0.2343589e6 / t ** 2
                + 0.8776956e3 / t + 0.179910)
    return (-3.0258469e9 / t ** 3 + 2.1070379e6 / t ** 2
            + 0.2226347e3 / t + 0.240390)


def planckian_locus(kelvin):
    t = max(kelvin, 1667.0)
    x = planck_x(t)
    if t <= 2222:
        y = -1.1063814 * x ** 3 - 1.34811020 * x ** 2 + 2.18555832 * x - 0.20219683
    else:
        y = -0.9549476 * x ** 3 - 1.37418593 * x ** 2 + 2.09137015 * x - 0.16748867
    return (x, y)


def daylight_locus(kelvin):
    t = max(kelvin, 1000.0)
    if t <= 7000:
        x = 0.244063 + 0.09911e3 / t + 2.9678e6 / t ** 2 - 4.6070e9 / t ** 3
    else:
        x = 0.237040 + 0.24748e3 / t + 1.9018e6 / t ** 2 - 2.0064e9 / t ** 3
    return (x, -3.000 * x * x + 2.870 * x - 0.275)


def locus(kelvin):
    t = min(max(kelvin, 1000.0), 100000.0)
    if t <= 3500:
        return planckian_locus(t)
    if t >= 4500:
        return daylight_locus(t)
    w = smoothstep(3500, 4500, t)
    p, d = planckian_locus(t), daylight_locus(t)
    return (p[0] + (d[0] - p[0]) * w, p[1] + (d[1] - p[1]) * w)


def wb_chromaticity(kelvin, tint):
    base = locus(kelvin)
    if tint == 0:
        return base
    u, v = xy_to_uv(*base)
    return uv_to_xy(u, v + tint * TINT_UNIT_IN_V)


def temperature_and_tint(chroma):
    u, v = xy_to_uv(*chroma)
    min_mired, max_mired = 1e6 / MAX_KELVIN, 1e6 / MIN_KELVIN

    def u_error(m):
        return abs(xy_to_uv(*locus(1e6 / m))[0] - u)

    best_mired, best = 1e6 / 5500, float("inf")
    m = min_mired
    while m <= max_mired:
        e = u_error(m)
        if e < best:
            best, best_mired = e, m
        m += 0.5
    step = 0.25
    for _ in range(12):
        lo, hi = max(min_mired, best_mired - step), min(max_mired, best_mired + step)
        a, b = u_error(lo), u_error(hi)
        if a < best:
            best, best_mired = a, lo
        if b < best:
            best, best_mired = b, hi
        step /= 2
    kelvin = 1e6 / best_mired
    tint = (v - xy_to_uv(*locus(kelvin))[1]) / TINT_UNIT_IN_V
    return (min(max(kelvin, MIN_KELVIN), MAX_KELVIN), min(max(tint, -300.0), 300.0))


def gen_white_balance_checks():
    print("white balance locus + eyedropper inverse ...")

    # The locus must be smooth and monotone across the crossfade. The two loci
    # disagree by ~0.007 in y where they meet, so a hard switch would put a
    # visible tint step in the middle of the temperature slider.
    prev_u = None
    k = 2000.0
    while k <= 50000:
        x, y = locus(k)
        u, _ = xy_to_uv(x, y)
        check(math.isfinite(u), f"locus non-finite at {k} K")
        if prev_u is not None:
            check(u < prev_u + 1e-12, f"locus u reversed at {k} K")
            check(prev_u - u < 0.004, f"locus stepped at {k} K: du={prev_u - u:.5f}")
        prev_u = u
        k *= 1.01

    # No kink at either crossfade boundary.
    for edge in (3500.0, 4500.0):
        h = 1.0
        before = xy_to_uv(*locus(edge - h))[0] - xy_to_uv(*locus(edge - 2 * h))[0]
        after = xy_to_uv(*locus(edge + 2 * h))[0] - xy_to_uv(*locus(edge + h))[0]
        check(abs(after - before) < 2e-6,
              f"locus has a kink at {edge} K: {before:.3e} vs {after:.3e}")

    # The eyedropper's inverse must be EXACTLY the inverse of the forward map.
    # Nearest-point-on-locus looks equivalent and is not: the locus is curved, so
    # a colour far off it in v is closest to a different temperature than the one
    # it came from. At 5500 K / tint -80 that error used to be 2850 K.
    worst_k, worst_t, where = 0.0, 0.0, ""
    k = 2500.0
    while k <= 20000:
        for tint in (-120.0, -80.0, -40.0, 0.0, 40.0, 80.0, 120.0):
            chroma = wb_chromaticity(k, tint)
            got_k, got_t = temperature_and_tint(chroma)
            dk, dt = abs(got_k - k) / k, abs(got_t - tint)
            if dk > worst_k:
                worst_k, where = dk, f"{k:.0f} K / tint {tint:.0f}"
            worst_t = max(worst_t, dt)
        k *= 1.5
    check(worst_k < 0.01, f"eyedropper recovered the wrong temperature: "
                          f"{worst_k:.2%} off at {where}")
    check(worst_t < 1.0, f"eyedropper recovered the wrong tint: {worst_t:.3f} units off")

    # And the failure mode that motivated the rewrite, called out by name.
    chroma = wb_chromaticity(5500, -80)
    got_k, got_t = temperature_and_tint(chroma)
    check(abs(got_k - 5500) < 200,
          f"the 5500 K / tint -80 case came back as {got_k:.0f} K")
    check(abs(got_t + 80) < 1.0, f"...with tint {got_t:.1f}")

    print("  locus smooth and monotone, eyedropper inverts its own forward map")


# ---------------------------------------------------------------------------
# The six-slider tone contract (D6), and the composed picture end to end
#
#   ToneEngine.swift <-> ToneEngine
# ---------------------------------------------------------------------------

HL_SH_RANGE_EV = 2.0
WHITE_BLACK_RANGE_EV = 1.5
DEFAULT_WHITE_ANCHOR_EV = 5.0
DEFAULT_BLACK_ANCHOR_EV = -9.0


def raised_cosine(t):
    u = min(max(t, 0.0), 1.0)
    return 0.5 * (1 - math.cos(math.pi * u))


class ToneEngine:
    def __init__(self, exposure=0.0, contrast=0.0, pivot=0.0, highlights=0.0,
                 shadows=0.0, whites=0.0, blacks=0.0):
        self.exposure = min(max(exposure, -10.0), 10.0)
        self.contrast = contrast
        self.pivot = pivot
        self.highlights = min(max(highlights, -100.0), 100.0) / 100
        self.shadows = min(max(shadows, -100.0), 100.0) / 100
        w = min(max(whites, -100.0), 100.0) / 100
        b = min(max(blacks, -100.0), 100.0) / 100
        self.white_anchor_ev = DEFAULT_WHITE_ANCHOR_EV - WHITE_BLACK_RANGE_EV * w
        self.black_anchor_ev = DEFAULT_BLACK_ANCHOR_EV - WHITE_BLACK_RANGE_EV * b
        self.zonal_scale = self._solve_zonal_scale()

    def _zonal_stops(self, t):
        s = 0.0
        if self.highlights != 0:
            s += self.highlights * HL_SH_RANGE_EV * self.highlight_weight(t)
        if self.shadows != 0:
            s += self.shadows * HL_SH_RANGE_EV * self.shadow_weight(t)
        return s

    def _solve_zonal_scale(self):
        if self.highlights == 0 and self.shadows == 0:
            return 1.0
        step, margin, scale = 0.02, 0.02, 1.0
        t = self.black_anchor_ev
        while t <= self.white_anchor_ev:
            a = t + step
            fixed = (contrast_mapped(a, self.contrast, self.pivot)
                     - contrast_mapped(t, self.contrast, self.pivot)) / step
            zonal = (self._zonal_stops(a) - self._zonal_stops(t)) / step
            if zonal < 0:
                scale = min(scale, max((fixed - margin) / -zonal, 0.0))
            t += step
        return min(max(scale, 0.0), 1.0)

    @property
    def exposure_gain(self):
        return 2.0 ** self.exposure

    def highlight_weight(self, t):
        hi = self.white_anchor_ev
        if hi <= 0 or t <= 0 or t >= hi:
            return 0.0
        return raised_cosine(math.sin(math.pi * (t / hi)))

    def shadow_weight(self, t):
        lo = self.black_anchor_ev
        if lo >= 0 or t >= 0 or t <= lo:
            return 0.0
        return raised_cosine(math.sin(math.pi * (t / lo)))

    def stops(self, t):
        s = self._zonal_stops(t) * self.zonal_scale
        s += contrast_mapped(t, self.contrast, self.pivot) - t
        return s

    def gain(self, t):
        return 2.0 ** self.stops(t)


def gen_tone_checks():
    print("the six-slider tone contract + the composed picture ...")

    # Mid-grey is the fixed point of Highlights and Shadows: both windows are zero
    # there, which is what makes them zonal rather than global brightness.
    for h in (-100, -50, 50, 100):
        for s in (-100, -50, 50, 100):
            e = ToneEngine(highlights=h, shadows=s)
            check(abs(e.stops(0.0)) < 1e-12,
                  f"highlights {h} / shadows {s} moved mid-grey by {e.stops(0.0)}")

    # Each window vanishes at its own anchor, so Highlights cannot touch the
    # shadows and Shadows cannot touch the highlights.
    e = ToneEngine(highlights=100, shadows=-100)
    check(abs(e.highlight_weight(e.white_anchor_ev)) < 1e-12, "highlights reach the white anchor")
    check(abs(e.shadow_weight(e.black_anchor_ev)) < 1e-12, "shadows reach the black anchor")
    for t in (-8.0, -5.0, -2.0):
        check(e.highlight_weight(t) == 0.0, f"highlights leaked into the shadows at {t} EV")
    for t in (2.0, 4.0, 4.9):
        check(e.shadow_weight(t) == 0.0, f"shadows leaked into the highlights at {t} EV")

    # Whites and Blacks move the display transform's ANCHORS rather than adding
    # gain — that is how "Whites owns the white point" is geometry, not a rule.
    plain = ToneEngine()
    lifted = ToneEngine(whites=100)
    check(abs(lifted.white_anchor_ev - (DEFAULT_WHITE_ANCHOR_EV - WHITE_BLACK_RANGE_EV))
          < 1e-12, "Whites did not move the white anchor")
    check(abs(lifted.stops(0.0) - plain.stops(0.0)) < 1e-12,
          "Whites added gain at mid-grey instead of moving the anchor")

    # Exposure is an honest gain and nothing else.
    check(abs(ToneEngine(exposure=1).exposure_gain - 2.0) < 1e-12, "exposure +1 is not 2x")
    check(abs(ToneEngine(exposure=-2).exposure_gain - 0.25) < 1e-12, "exposure -2 is not 0.25x")

    # The whole S7 response must be monotone in the input at every setting, or a
    # brighter part of the scene renders darker than a dimmer one.
    for contrast in (-100, -60, -50, 0, 50, 60, 85, 100):
        for h in (-100, -80, -40, 0, 40, 80, 100):
            for s in (-100, -80, 0, 80, 100):
                e = ToneEngine(contrast=contrast, highlights=h, shadows=s)
                prev, t = -1e18, -13.0
                while t <= 13:
                    # Output EV = input + the stops S7 adds there.
                    out = t + e.stops(t)
                    check(out >= prev - 1e-9,
                          f"tone inverted at {t} EV (contrast {contrast}, "
                          f"hi {h}, sh {s}): {out:.5f} after {prev:.5f}")
                    prev = out
                    t += 0.05

    # --- the composed picture ---------------------------------------------
    # Shaper domain -> tone -> display transform. This is the closest thing to
    # "the picture is right" that runs without a GPU.
    for contrast in (-60, 0, 60):
        for h, s in ((0, 0), (-80, 80), (80, -80)):
            tone = ToneEngine(contrast=contrast, highlights=h, shadows=s)
            dt = DisplayTransform(white_anchor_ev=tone.white_anchor_ev,
                                  black_anchor_ev=tone.black_anchor_ev)
            prev, ev = -1e18, -12.0
            while ev <= 12:
                scene = MID_GREY * 2 ** ev
                out = dt.tone(scene * tone.gain(ev))
                check(math.isfinite(out), f"composed render non-finite at {ev} EV")
                check(dt.black - 1e-9 <= out <= dt.white + 1e-9,
                      f"composed render left the display range at {ev} EV: {out}")
                check(out >= prev - 1e-9,
                      f"composed render inverted at {ev} EV (contrast {contrast}, "
                      f"hi {h}, sh {s})")
                prev = out
                ev += 0.05
            # Mid-grey survives the whole chain when nothing asks it to move.
            if contrast == 0 and h == 0 and s == 0:
                check(abs(dt.tone(MID_GREY * tone.gain(0.0)) - MID_GREY) < 2e-3,
                      "a default recipe did not land mid-grey on 0.18")

    print("  zonal fixed points, anchor geometry, and a monotone composed picture")


# ---------------------------------------------------------------------------
# Vibrance / Saturation — the stage `lumSatRolloff` actually feeds
#
#   ColorEngine.swift <-> vibrance_saturation
#
# Mirrored with protectSkin = 0 so the skin gate stays out of it; the gate is a
# multiplier on both amounts and is tested by its own fixtures.
# ---------------------------------------------------------------------------

SAT_KNEE_CHROMA, SAT_CEILING_CHROMA = 0.18, 0.34
LOW_CHROMA_LO, LOW_CHROMA_HI = 0.05, 0.25
DENSITY_GAMMA_RANGE = 1.0


def sat_compress(chroma):
    if chroma <= SAT_KNEE_CHROMA:
        return chroma
    room = SAT_CEILING_CHROMA - SAT_KNEE_CHROMA
    return SAT_CEILING_CHROMA - room * math.exp(-(chroma - SAT_KNEE_CHROMA) / room)


def low_chroma(chroma):
    return 1 - smoothstep(LOW_CHROMA_LO, LOW_CHROMA_HI, chroma)


def shaped_chroma_scale(c, gain):
    J, C, h = ucs_from_rgb(c)
    base = max(0.0, C)
    g = max(0.0, gain)
    reference = sat_compress(base)
    new_c = sat_compress(base * g) * base / reference if reference > 1e-12 else base * g
    return ucs_to_rgb(J, max(0.0, new_c), h)


def subtractive_push(c, amount):
    if amount <= 0:
        return c
    norm = max(c)
    if norm <= 1e-9 or not math.isfinite(norm):
        return c
    gamma = 1 + amount * DENSITY_GAMMA_RANGE
    return tuple(spow(v / norm, gamma) * norm for v in c)


def vibrance_saturation(c, vibrance=0.0, saturation=0.0, density=50.0):
    vib = min(max(vibrance, -100.0), 100.0) / 100
    sat = min(max(saturation, -100.0), 100.0) / 100
    if vib == 0 and sat == 0:
        return c
    J, C, _ = ucs_from_rgb(c)
    rolloff = lum_sat_rolloff(J)
    vib_amount = (vib * rolloff if vib >= 0 else vib) * low_chroma(C)
    sat_amount = sat * rolloff if sat >= 0 else sat

    mid = shaped_chroma_scale(c, 1 + vib_amount) if vib_amount != 0 else c
    if sat_amount == 0:
        return mid
    additive = shaped_chroma_scale(mid, 1 + sat_amount)
    if sat_amount <= 0:
        return additive
    d = min(max(density, 0.0), 100.0) / 100
    if d <= 0:
        return additive
    sub = subtractive_push(mid, sat_amount)
    return tuple(a + (s - a) * d for a, s in zip(additive, sub))


def gen_colour_stage_checks():
    print("vibrance / saturation over the exposure range ...")

    samples = [(0.9, 0.2, 0.05), (0.2, 0.5, 0.9), (0.45, 0.40, 0.30),
               (0.30, 0.31, 0.29), (0.7, 0.7, 0.1)]

    # Doing nothing must do NOTHING — bit-exact, at every brightness.
    for c in samples:
        for ev in (-6.0, 0.0, 3.0, 8.0):
            scaled = tuple(v * 2 ** ev for v in c)
            out = vibrance_saturation(scaled, 0, 0)
            check(max(abs(a - b) for a, b in zip(out, scaled)) == 0,
                  f"an identity colour stage moved {scaled}")

    # Saturation −100 must reach a true neutral everywhere, including the
    # highlights the rolloff used to switch off in. The negative side is
    # deliberately NOT tapered, which is what makes B&W reachable.
    for c in samples:
        for ev in (-4.0, 0.0, 2.5, 6.0):
            scaled = tuple(v * 2 ** ev for v in c)
            _, C, _ = oklch_from_rgb(vibrance_saturation(scaled, 0, -100))
            check(C < 1e-6, f"saturation −100 left {C:.2e} of chroma at {ev} EV")

    # The fix from earlier today, in the stage that actually uses it: a push must
    # still do something above display white, where the rolloff used to be zero.
    for ev in (0.0, 2.5, 4.0, 6.0):
        c = tuple(v * 2 ** ev for v in (0.45, 0.34, 0.22))
        _, before, _ = oklch_from_rgb(c)
        _, after, _ = oklch_from_rgb(vibrance_saturation(c, 0, 60))
        check(after > before * 1.05,
              f"saturation +60 barely moved chroma at {ev} EV: "
              f"{before:.4f} -> {after:.4f}")

    # Monotone in the slider, at every brightness.
    for ev in (-3.0, 0.0, 3.0):
        c = tuple(v * 2 ** ev for v in (0.45, 0.34, 0.22))
        prev = -1.0
        for value in range(-100, 101, 5):
            _, C, _ = oklch_from_rgb(vibrance_saturation(c, 0, float(value)))
            check(C >= prev - 1e-9,
                  f"saturation {value} gave less chroma than {value - 5} at {ev} EV")
            prev = C

    # ...and smooth in exposure. This is the property the display-referred
    # threshold broke: a stage that changes behaviour at a particular brightness
    # puts an edge across a gradient.
    for sat in (30.0, 60.0, 100.0):
        unit = (0.45, 0.34, 0.22)
        prev = None
        ev = -5.0
        while ev <= 8.0:
            scale = 2 ** ev
            out = vibrance_saturation(tuple(v * scale for v in unit), 0, sat)
            response = tuple(v / scale for v in out)
            if prev is not None:
                step = max(abs(a - b) for a, b in zip(response, prev))
                check(step < 0.02,
                      f"saturation {sat} stepped at {ev} EV: {step:.4f}")
            prev = response
            ev += 0.05

    # An untouched colour is still an exact fixed point, and a colour already past
    # the compression knee still resists a push — the two properties the increment
    # form was written for, which the ratio form has to keep.
    for c in samples:
        out = shaped_chroma_scale(c, 1.0)
        check(max(abs(a - b) for a, b in zip(out, c)) < 1e-12,
              f"gain 1 moved {c}")
    _, saturated, _ = oklch_from_rgb((0.95, 0.05, 0.02))
    _, pushed, _ = oklch_from_rgb(shaped_chroma_scale((0.95, 0.05, 0.02), 4.0))
    check(pushed < saturated * 1.5,
          f"an already-saturated colour did not resist: {saturated:.3f} -> {pushed:.3f}")
    check(pushed > saturated, "an already-saturated colour could not be pushed at all")

    # Vibrance is chroma-weighted: it must move a muted colour more than a
    # saturated one. That is the whole difference from Saturation.
    muted, vivid = (0.31, 0.30, 0.29), (0.9, 0.15, 0.05)
    for c, name in ((muted, "muted"), (vivid, "vivid")):
        _, before, _ = oklch_from_rgb(c)
        _, after, _ = oklch_from_rgb(vibrance_saturation(c, 80, 0))
        rel = (after - before) / max(before, 1e-9)
        if name == "muted":
            check(rel > 0.3, f"vibrance barely moved a muted colour: {rel:.1%}")
        else:
            check(rel < 0.05, f"vibrance treated a vivid colour like saturation: {rel:.1%}")

    # Nothing may fall over on unbounded input.
    for v in (1.0, 32.0, 1024.0):
        out = vibrance_saturation((v, v * 0.6, v * 0.3), 50, 50)
        check(all(math.isfinite(x) for x in out), f"colour stage non-finite at {v}")

    print("  identity exact, B&W reachable, pushes survive the highlights, no steps")


# ---------------------------------------------------------------------------
# The grading wheels' zone windows
#
#   GradeEngine.swift <-> ZoneWindows / solve_lum_scale
# ---------------------------------------------------------------------------

LUM_RANGE_STOPS = 0.5
NOMINAL_HALF_WIDTH_EV = 1.5
MINIMUM_HALF_WIDTH_EV = 0.05
MINIMUM_PIVOT_GAP = 0.02
BALANCE_RANGE_EV = 2.0


class ZoneWindows:
    def __init__(self, pivots=(0.33, 0.67), blending=50.0, balance=0.0,
                 white_anchor_ev=5.0, black_anchor_ev=-9.0):
        span = max(white_anchor_ev - black_anchor_ev, 1e-3)
        self.span_ev = span
        p0, p1 = sorted((min(max(pivots[0], 0.0), 1.0), min(max(pivots[1], 0.0), 1.0)))
        if p1 - p0 < MINIMUM_PIVOT_GAP:
            c = (p0 + p1) / 2
            p0, p1 = c - MINIMUM_PIVOT_GAP / 2, c + MINIMUM_PIVOT_GAP / 2
        shift = (min(max(balance, -100.0), 100.0) / 100) * BALANCE_RANGE_EV / span
        ps, ph = p0 + shift, p1 + shift
        max_half = (ph - ps) / 2
        requested = NOMINAL_HALF_WIDTH_EV * (min(max(blending, 0.0), 100.0) / 50) / span
        floor_half = min(MINIMUM_HALF_WIDTH_EV / span, max_half)
        half = min(max(requested, floor_half), max_half)
        self.half_width = half
        self.shadow_crossfade = [ps - half, ps + half]
        self.highlight_crossfade = [ph - half, ph + half]

    def weights(self, x):
        xs = min(max(x, 0.0), 1.0)
        s = zone_weights(xs, self.shadow_crossfade)[0]
        h = zone_weights(xs, self.highlight_crossfade)[1]
        return s, max(0.0, 1 - s - h), h


def solve_lum_scale(windows, shadows, mid, high):
    if shadows == 0 and mid == 0 and high == 0:
        return 1.0
    # Step from the narrowest feature: a fixed step walks over a narrow crossfade
    # and reports a gentler slope than the real peak, producing a scale that still
    # inverts. That is exactly what this first did.
    span = windows.span_ev
    step = min(max(windows.half_width / 8, 1e-4), 0.01)
    margin, scale = 0.05, 1.0

    def stops(p):
        s, m, h = windows.weights(p)
        return s * shadows + m * mid + h * high

    x = 0.0
    while x < 1:
        a = min(x + step, 1.0)
        slope = (stops(a) - stops(x)) / ((a - x) * span)
        if slope < 0:
            scale = min(scale, max((1 - margin) / -slope, 0.0))
        x = a
    return min(max(scale, 0.0), 1.0)


def gen_grade_checks():
    print("grading wheels: zone windows and monotonicity ...")

    # Weights are a partition of unity everywhere, never negative.
    for blending in (0.0, 25.0, 50.0, 100.0):
        for balance in (-100.0, 0.0, 100.0):
            w = ZoneWindows(blending=blending, balance=balance)
            x = 0.0
            while x <= 1.0:
                s, m, h = w.weights(x)
                check(min(s, m, h) >= -1e-12,
                      f"negative zone weight at x={x:.3f} (blend {blending}, bal {balance})")
                check(abs(s + m + h - 1) < 1e-9,
                      f"zone weights sum to {s + m + h:.6f} at x={x:.3f}")
                x += 0.002

    # The failure this found: at Blending 0 the crossfade collapses to the 0.05 EV
    # floor, and a shadow wheel at +1 against a highlight wheel at −1 asks brightness
    # to fall a full stop across a tenth of a stop of input.
    hard = ZoneWindows(blending=0.0)
    unscaled = solve_lum_scale(hard, LUM_RANGE_STOPS, 0.0, -LUM_RANGE_STOPS)
    check(unscaled < 0.2,
          f"the hard-crossover case did not need scaling ({unscaled:.3f}) — "
          "the test no longer covers what it was written for")

    # With the scale applied, the composed response is monotone at every setting.
    for blending in (0.0, 10.0, 50.0, 100.0):
        for sh_lum, mid_lum, hi_lum in ((1.0, 0.0, -1.0), (-1.0, 0.0, 1.0),
                                        (1.0, -1.0, 1.0), (0.6, 0.0, -0.6)):
            w = ZoneWindows(blending=blending)
            sh, md, hi = (LUM_RANGE_STOPS * sh_lum, LUM_RANGE_STOPS * mid_lum,
                          LUM_RANGE_STOPS * hi_lum)
            scale = solve_lum_scale(w, sh, md, hi)
            prev, x = -1e18, 0.0
            while x <= 1.0:
                t = -9.0 + x * w.span_ev
                s_w, m_w, h_w = w.weights(x)
                out = t + (s_w * sh + m_w * md + h_w * hi) * scale
                check(out >= prev - 1e-9,
                      f"grade inverted at x={x:.3f} (blend {blending}, "
                      f"wheels {sh_lum}/{mid_lum}/{hi_lum}, scale {scale:.3f})")
                prev = out
                x += 0.002

    # And the default settings must not be scaled at all, or the fix has quietly
    # weakened the control everywhere instead of only where it had to.
    default = ZoneWindows()
    for sh_lum, hi_lum in ((0.5, -0.5), (1.0, 0.0), (0.0, -1.0)):
        scale = solve_lum_scale(default, LUM_RANGE_STOPS * sh_lum, 0.0,
                                LUM_RANGE_STOPS * hi_lum)
        check(scale > 0.999,
              f"default blending scaled wheels {sh_lum}/{hi_lum} to {scale:.3f}")

    print("  partition of unity, and no grade setting can invert the tone response")


# ---------------------------------------------------------------------------
# The Film Lab chain (Sources/LumenCore/Engine/FilmLab.swift), on the grey axis.
#
# Why this is here. Two engines shipped with the same latent bug: a gain applied
# through a tonal WINDOW out-runs the underlying slope inside that window, and the
# ramp turns over — a brighter subject renders darker. ToneEngine's Highlights and
# GradeEngine's colour wheels each did it, independently, and each is now solved
# against its own slope. Film has windowed gains too — the crossover tints, weighted
# by a smoothstep of tonal position, plus push/pull steepening the gammas with
# per-channel divergence — and nothing couples any of them to the curve.
#
# Analysis said film is safe by a wide margin: the tints are hundredths of a density
# unit against a negative spanning two. Analysis is what said the other two were fine.
# So the chain is mirrored here and the ramp is walked.
# ---------------------------------------------------------------------------

MID_GREY_ANCHOR = 0.7447274948966939      # = −log10(0.18)
FILM_PUSH_DIVERGENCE = (0.03, 0.0, -0.03)
FILM_LUMA = tuple(_REC2020_TO_XYZ[1])     # the Y row: Rec.2020 luminance weights


class FilmStage:
    """One characteristic curve with its per-channel constants resolved."""

    def __init__(self, gamma, d_min, d_max, log_offset, rising, anchor):
        self.d_min = list(d_min)
        self.d_max = list(d_max)
        self.delta = [max(d_max[i] - d_min[i], 1e-6) for i in range(3)]
        self.k = [max(gamma[i], 0.02) / (0.25 * self.delta[i]) for i in range(3)]
        self.offset = [log_offset[i] + anchor for i in range(3)]
        self.rising = rising
        self.white_t = [10.0 ** -d_min[i] for i in range(3)]
        self.black_t = [10.0 ** -d_max[i] for i in range(3)]

    def response(self, e):
        """(density, tone) — tone is the sigmoid itself, which rises with exposure
        for a negative and for a transparency alike, so the crossover weights read
        the same way on both."""
        density, tone = [0.0] * 3, [0.0] * 3
        for i in range(3):
            x = clamp(self.k[i] * (math.log10(max(e[i], 1e-12)) + self.offset[i]),
                      -60, 60)
            s = 1.0 / (1.0 + math.exp(-x))
            tone[i] = s
            density[i] = self.d_min[i] + self.delta[i] * (s if self.rising else 1.0 - s)
        return density, tone


def film_coupling_matrix(interlayer, coupler):
    """DIR inhibition + masking-coupler residue as one 3×3. Unit row sums, so a
    neutral density triple survives exactly and the grey calibration cannot be
    disturbed by colour couplers."""
    a = clamp(interlayer, 0, 0.6)
    b = clamp(coupler, -0.5, 0.5)
    third = 1.0 / 3.0
    diagonal = 1.0 + a * (1.0 - third)
    off = -a * third
    k = b * 0.5
    return [[diagonal, off - k, off + k],
            [off + k, diagonal, off - k],
            [off - k, off + k, diagonal]]


class SolvedFilmChain:
    pass


def film_render(scene, s, white):
    """Negative → couplers → crossover → transmittance → print → paper white.
    Grain is omitted: it enters in density from a plate the chain does not own, and
    is zero on every path this file checks."""
    e = [max(scene[i], 0.0) for i in range(3)]
    if s.monochrome:
        y = sum(FILM_LUMA[i] * e[i] for i in range(3))
        e = [max(y, 0.0)] * 3
    e = [e[i] * s.film_gain[i] for i in range(3)]

    density, tone_triple = s.negative.response(e)
    d = mat_apply(s.coupling, density)

    tone = sum(tone_triple) / 3.0
    shadow_weight = 1.0 - smoothstep(0.0, 0.6, tone)
    highlight_weight = smoothstep(0.4, 1.0, tone)
    d = [d[i] + s.shadow_tint[i] * shadow_weight
         + s.highlight_tint[i] * highlight_weight for i in range(3)]

    t = [10.0 ** -d[i] for i in range(3)]

    if s.print_stage is not None:
        print_exposure = [t[i] * s.print_gain[i] for i in range(3)]
        print_density, _ = s.print_stage.response(print_exposure)
        final_t = [10.0 ** -print_density[i] for i in range(3)]
        last = s.print_stage
    else:
        final_t = t
        last = s.negative

    out = [0.0] * 3
    for i in range(3):
        span = last.white_t[i] - last.black_t[i]
        v = 0.0 if abs(span) < 1e-12 else (final_t[i] - last.black_t[i]) / span
        out[i] = clamp(v, 0, 1) * white
    return out


def film_bisect(target, lo, hi, steps, f):
    a, b = lo, hi
    fa, fb = f(a), f(b)
    if not (math.isfinite(fa) and math.isfinite(fb)):
        return 0.0
    increasing = fb >= fa
    if increasing:
        if target <= fa:
            return a
        if target >= fb:
            return b
    else:
        if target >= fa:
            return a
        if target <= fb:
            return b
    for _ in range(steps):
        m = 0.5 * (a + b)
        fm = f(m)
        if not math.isfinite(fm):
            return m
        if (increasing and fm < target) or (not increasing and fm > target):
            a = m
        else:
            b = m
    return 0.5 * (a + b)


def film_solve_gains(s, white):
    """Per-channel calibration gain so scene mid-grey lands on display mid-grey in
    every channel. The print gain is downstream of every channel-mixing step so one
    sweep is exact; a transparency's gain is scene-side and the couplers mix after
    it, so the sweeps iterate."""
    grey = [0.18, 0.18, 0.18]
    target = 0.18 * white
    use_print = s.print_stage is not None
    for _ in range(6):
        for i in range(3):
            def probe(log_gain, i=i):
                g = 2.0 ** log_gain
                saved = list(s.print_gain), list(s.film_gain)
                if use_print:
                    s.print_gain[i] = g
                else:
                    s.film_gain[i] = g
                out = film_render(grey, s, white)[i]
                s.print_gain, s.film_gain = saved
                return out
            g = 2.0 ** film_bisect(target, -14, 14, 52, probe)
            if use_print:
                s.print_gain[i] = g
            else:
                s.film_gain[i] = g
    return s


def film_chain(stock, push=0.0, white=1.0):
    push = clamp(push, -1, 2)
    gamma = [max(stock["gamma"][i] * (1.0 + 0.18 * push * (1.0 + FILM_PUSH_DIVERGENCE[i])),
                 0.02) for i in range(3)]

    s = SolvedFilmChain()
    s.negative = FilmStage(gamma, stock["dMin"], stock["dMax"], stock["logOffset"],
                           stock["kind"] == "negative", MID_GREY_ANCHOR)
    # The print's own log-exposure origin is absorbed by the calibration gain, so its
    # anchor is 0 and only its gamma and density span carry character.
    s.print_stage = (None if stock["print"] is None
                     else FilmStage(stock["print"]["gamma"], stock["print"]["dMin"],
                                    stock["print"]["dMax"], (0.0, 0.0, 0.0), True, 0.0))
    s.coupling = film_coupling_matrix(stock["interlayer"], stock["coupler"])
    s.shadow_tint = [stock["shadowTint"][i] + stock["pushTint"][i] * push
                     for i in range(3)]
    s.highlight_tint = list(stock["highlightTint"])
    s.film_gain = [1.0, 1.0, 1.0]
    s.print_gain = [1.0, 1.0, 1.0]
    s.monochrome = stock["monochrome"]
    return film_solve_gains(s, white)


# The launch six, transcribed from FilmStock.all.
FILM_STOCKS = {
    "lumen/portra400": dict(
        kind="negative", monochrome=False,
        gamma=(0.545, 0.550, 0.560), dMin=(0.06, 0.14, 0.22), dMax=(2.06, 2.14, 2.22),
        logOffset=(0.000, 0.000, -0.010),
        print=dict(gamma=(2.48, 2.48, 2.48), dMin=(0.05, 0.06, 0.07),
                   dMax=(2.15, 2.20, 2.25)),
        shadowTint=(0.015, 0.005, -0.015), highlightTint=(-0.005, 0.000, 0.010),
        pushTint=(-0.020, 0.010, 0.025), interlayer=0.14, coupler=0.05),
    "lumen/gold200": dict(
        kind="negative", monochrome=False,
        gamma=(0.605, 0.590, 0.578), dMin=(0.06, 0.14, 0.22), dMax=(2.06, 2.14, 2.22),
        logOffset=(0.012, 0.000, -0.016),
        print=dict(gamma=(2.52, 2.50, 2.48), dMin=(0.05, 0.06, 0.07),
                   dMax=(2.10, 2.15, 2.20)),
        shadowTint=(0.020, 0.006, -0.022), highlightTint=(0.022, 0.010, -0.020),
        pushTint=(-0.018, 0.012, 0.026), interlayer=0.18, coupler=0.09),
    "lumen/ektar100": dict(
        kind="negative", monochrome=False,
        gamma=(0.665, 0.665, 0.670), dMin=(0.06, 0.14, 0.22), dMax=(2.06, 2.14, 2.22),
        logOffset=(-0.006, 0.000, 0.006),
        print=dict(gamma=(2.50, 2.50, 2.50), dMin=(0.05, 0.05, 0.06),
                   dMax=(2.20, 2.24, 2.28)),
        shadowTint=(-0.008, 0.000, 0.012), highlightTint=(0.004, 0.000, 0.002),
        pushTint=(-0.015, 0.008, 0.020), interlayer=0.26, coupler=0.06),
    "lumen/trix400": dict(
        kind="negative", monochrome=True,
        gamma=(0.620, 0.620, 0.620), dMin=(0.10, 0.10, 0.10), dMax=(2.10, 2.10, 2.10),
        logOffset=(0.0, 0.0, 0.0),
        print=dict(gamma=(2.35, 2.35, 2.35), dMin=(0.06, 0.06, 0.06),
                   dMax=(2.20, 2.20, 2.20)),
        shadowTint=(0.0, 0.0, 0.0), highlightTint=(0.0, 0.0, 0.0),
        pushTint=(0.0, 0.0, 0.0), interlayer=0.0, coupler=0.0),
    "lumen/velvia50": dict(
        kind="reversal", monochrome=False,
        gamma=(1.720, 1.750, 1.800), dMin=(0.12, 0.14, 0.16), dMax=(3.40, 3.45, 3.50),
        logOffset=(0.004, 0.000, -0.004),
        print=None,
        shadowTint=(0.020, 0.000, -0.020), highlightTint=(-0.008, 0.000, 0.006),
        pushTint=(0.014, -0.004, -0.012), interlayer=0.30, coupler=0.04),
    "lumen/cine250d": dict(
        kind="negative", monochrome=False,
        gamma=(0.500, 0.505, 0.510), dMin=(0.10, 0.20, 0.30), dMax=(2.00, 2.10, 2.20),
        logOffset=(0.000, 0.000, 0.008),
        print=dict(gamma=(2.62, 2.62, 2.62), dMin=(0.06, 0.06, 0.07),
                   dMax=(2.60, 2.65, 2.70)),
        shadowTint=(-0.010, 0.000, 0.014), highlightTint=(0.008, 0.004, -0.006),
        pushTint=(-0.016, 0.010, 0.024), interlayer=0.20, coupler=0.07),
}

FILM_PUSH_SETTINGS = (-1.0, -0.5, 0.0, 1.0, 2.0)
FILM_EXPOSURE_SETTINGS = (-2.0, 0.0, 1.5, 3.0)


def gen_film_checks():
    print("film chain: mid-grey anchor and monotonicity ...")

    for name, stock in sorted(FILM_STOCKS.items()):
        for push in FILM_PUSH_SETTINGS:
            chain = film_chain(stock, push=push)

            # Mid-grey lands on mid-grey in every channel, by construction rather
            # than by tuning — that is what the gain solve is for.
            anchor = film_render([0.18, 0.18, 0.18], chain, 1.0)
            for i in range(3):
                check(abs(anchor[i] - 0.18) < 1e-6,
                      f"{name} at push {push} put mid-grey at {anchor[i]:.9f} "
                      f"in channel {i}")

            for exposure in FILM_EXPOSURE_SETTINGS:
                gain = 2.0 ** exposure
                previous = [-1e30] * 3
                for step in range(91):
                    ev = -10 + step * 0.2
                    scene = [0.18 * (2.0 ** ev) * gain] * 3
                    out = film_render(scene, chain, 1.0)
                    for i in range(3):
                        check(out[i] >= previous[i] - 1e-9,
                              f"{name} inverted in channel {i} at {ev:+.1f} EV "
                              f"(push {push}, film exposure {exposure}): "
                              f"{previous[i]:.12f} → {out[i]:.12f}")
                    previous = out

    # The ramp has to actually move, or "monotone" is satisfied by a flat line and
    # the sweep above proves nothing. Measured across the stock's own useful range,
    # not the clipped ends.
    for name, stock in sorted(FILM_STOCKS.items()):
        chain = film_chain(stock)
        low = film_render([0.18 * 2 ** -3] * 3, chain, 1.0)
        high = film_render([0.18 * 2 ** 2] * 3, chain, 1.0)
        check(high[1] - low[1] > 0.3,
              f"{name} spans only {high[1] - low[1]:.4f} from −3 to +2 EV")

    # Crossover is supposed to be a colour, not a tone: it must not be strong enough
    # to matter to the shape of the curve. This is the margin the analysis claimed,
    # asserted rather than assumed — if a stock is ever authored with tints an order
    # of magnitude larger, the monotonicity sweep above may still pass while the
    # chain has stopped being safe by construction.
    for name, stock in sorted(FILM_STOCKS.items()):
        span = max(stock["dMax"][i] - stock["dMin"][i] for i in range(3))
        for push in FILM_PUSH_SETTINGS:
            swing = max(abs(stock["shadowTint"][i] + stock["pushTint"][i] * push)
                        + abs(stock["highlightTint"][i]) for i in range(3))
            check(swing < 0.05 * span,
                  f"{name} crossover swings {swing:.4f} density at push {push}, "
                  f"which is {swing / span:.1%} of its {span:.2f} span")

    print("  6 stocks × 5 push settings × 4 film exposures: "
          "grey anchored, no inversion")


# ---------------------------------------------------------------------------

def gen_enginemath_fixture():
    """Sampled outputs of every engine mirror above, for the Swift to replay.

    The checks in this file execute the ALGORITHMS. This ties them to the Swift:
    without it, a mirror and its implementation can drift apart silently and the
    green Linux lane becomes a reassurance rather than a check. A failure here
    means the two have diverged — fix whichever one is wrong, and say which in
    the commit.
    """
    print("enginemath.json ...")

    shaper = [{"x": x, "y": lumen_log_encode(x)}
              for x in [0.0, 1e-6, LINEAR_CUT * 0.5, LINEAR_CUT, 0.001, 0.01,
                        0.18, 1.0, 8.0, 100.0, 700.0]]

    rolloff = [{"brightness": b, "value": lum_sat_rolloff(b)}
               for b in [0.0, 0.01, 0.02, 0.1, 0.2, 0.5, 0.86, 1.0, 1.5, 3.0, 20.0]]

    contrast = []
    for c in (-100.0, -50.0, 0.0, 50.0, 100.0):
        for t in (-12.0, -8.0, -4.0, -1.0, 0.0, 1.0, 4.0, 8.0, 12.0):
            contrast.append({"contrast": c, "t": t, "mapped": contrast_mapped(t, c)})

    display = []
    for kw in ({}, {"contrast": 2.2, "skew": -0.3}, {"white_target": 400.0}):
        t = DisplayTransform(**kw)
        for ev in (-9.0, -6.0, -3.0, 0.0, 2.0, 5.0):
            display.append({
                "contrast": kw.get("contrast", 1.5),
                "skew": kw.get("skew", 0.0),
                "whiteTarget": kw.get("white_target", 100.0),
                "ev": ev,
                "out": t.tone(MID_GREY * 2 ** ev),
            })

    tone = []
    for h, sh, c in ((0.0, 0.0, 0.0), (-80.0, 80.0, 0.0), (-100.0, 100.0, 60.0),
                     (50.0, -50.0, -40.0)):
        e = ToneEngine(highlights=h, shadows=sh, contrast=c)
        entry = {"highlights": h, "shadows": sh, "contrast": c,
                 "zonalScale": e.zonal_scale, "stops": []}
        for t in (-8.0, -4.0, -1.0, 0.0, 1.0, 3.0, 5.0):
            entry["stops"].append({"t": t, "value": e.stops(t)})
        tone.append(entry)

    chroma = []
    for c in ((0.9, 0.2, 0.05), (0.45, 0.34, 0.22), (0.31, 0.30, 0.29)):
        for gain in (0.0, 0.5, 1.0, 1.6, 3.0):
            chroma.append({"rgb": list(c), "gain": gain,
                           "out": list(shaped_chroma_scale(c, gain))})

    white_balance = []
    for k in (2500.0, 4000.0, 5500.0, 8000.0, 20000.0):
        for tint in (-80.0, 0.0, 80.0):
            x, y = wb_chromaticity(k, tint)
            got_k, got_t = temperature_and_tint((x, y))
            white_balance.append({"kelvin": k, "tint": tint, "x": x, "y": y,
                                  "recoveredKelvin": got_k, "recoveredTint": got_t})

    perceptual = []
    for c in ((0.18, 0.18, 0.18), (0.9, 0.2, 0.05), (2.4, 1.2, 0.6)):
        L, C, hh = oklch_from_rgb(c)
        perceptual.append({"rgb": list(c), "L": L, "C": C, "h": hh})

    # Film: the grey ramp through every stock at its default push, plus the two push
    # extremes on one colour stock and one transparency, since push is where the
    # per-channel divergence lives.
    film = []
    for name in sorted(FILM_STOCKS):
        pushes = [0.0]
        if name in ("lumen/gold200", "lumen/velvia50"):
            pushes = [-1.0, 0.0, 2.0]
        for push in pushes:
            chain = film_chain(FILM_STOCKS[name], push=push)
            samples = []
            for ev in (-8.0, -5.0, -3.0, -1.0, 0.0, 1.0, 2.5, 4.0, 6.0):
                out = film_render([0.18 * 2.0 ** ev] * 3, chain, 1.0)
                samples.append({"ev": ev, "out": out})
            film.append({"stock": name, "push": push, "samples": samples})

    payload = {
        "_comment": "Generated by scripts/gen-fixtures.py. The Swift replays these; "
                    "a mismatch means the implementation and its executable mirror "
                    "have drifted.",
        "film": film,
        "shaper": shaper,
        "saturationRolloff": rolloff,
        "contrast": contrast,
        "displayTransform": display,
        "tone": tone,
        "shapedChromaScale": chroma,
        "whiteBalance": white_balance,
        "perceptual": perceptual,
    }
    with open(os.path.join(FIXTURES, "enginemath.json"), "w") as f:
        json.dump(payload, f, indent=2, sort_keys=True)
        f.write("\n")
    total = (len(shaper) + len(rolloff) + len(contrast) + len(display)
             + sum(len(t["stops"]) for t in tone) + len(chroma)
             + len(white_balance) + len(perceptual)
             + sum(len(f["samples"]) for f in film))
    print(f"  {total} sampled values across nine engine surfaces")


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
    gen_spatial_primitive_checks()
    gen_perceptual_checks()
    gen_white_balance_checks()
    gen_tone_checks()
    gen_colour_stage_checks()
    gen_grade_checks()
    gen_film_checks()
    gen_enginemath_fixture()
    if FAILURES:
        print(f"\n{len(FAILURES)} verification failure(s)")
        sys.exit(1)
    print("\nAll fixtures generated; all Linux-side verifications passed.")


if __name__ == "__main__":
    main()
