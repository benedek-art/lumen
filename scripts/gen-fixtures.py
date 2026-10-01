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
import struct
import sys
import xml.etree.ElementTree as ET

import xxhash

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES = os.path.join(ROOT, "Tests", "LumenCoreTests", "Fixtures")
os.makedirs(FIXTURES, exist_ok=True)

FAILURES = []

# --check compares against the committed fixtures instead of overwriting them.
CHECK_ONLY = "--check" in sys.argv[1:]

# Tolerance for the comparison in --check mode.
#
# `git diff --exit-code` used to be the gate, which made it a bit-exactness test of
# double arithmetic across machines — and nothing guarantees that. glibc dispatches
# exp/log/pow to FMA-using variants when the CPU has FMA, so the same glibc on two
# different runners returns results a few ulp apart. The CI lane failed on 163 values
# in enginemath.json that differed only in their last two or three digits, the worst
# by 8e-15 relative: noise from a machine, not a change to the engine.
#
# 1e-9 relative sits six orders of magnitude above that noise and six below anything a
# real change produces — perturbing any engine constant moves these values in the
# third decimal or beyond, not the fifteenth. The absolute floor matters for the
# values that are legitimately zero-ish (an achromatic sample's chroma lands around
# 1e-16, and its *sign* is arbitrary); it is the same 1e-12 the Swift suite uses when
# it asserts those quantities.
CHECK_RTOL = 1e-9
CHECK_ATOL = 1e-12


def check(cond, msg):
    if not cond:
        FAILURES.append(msg)
        print(f"  FAIL: {msg}")


def _compare(want, got, path):
    """Structure exactly, numbers within tolerance. Returns a list of differences."""
    if isinstance(want, bool) or isinstance(got, bool):
        # bool before int: `True == 1` in Python and that is not a match here.
        if want is not got:
            return [f"{path}: committed {want!r}, regenerated {got!r}"]
        return []
    if isinstance(want, (int, float)) and isinstance(got, (int, float)):
        if want == got:
            return []
        if math.isnan(want) and math.isnan(got):
            return []
        delta = abs(want - got)
        if delta <= CHECK_ATOL + CHECK_RTOL * abs(want):
            return []
        rel = delta / abs(want) if want else float("inf")
        return [f"{path}: committed {want!r}, regenerated {got!r} (rel {rel:.3e})"]
    if isinstance(want, dict) and isinstance(got, dict):
        out = []
        for key in sorted(set(want) | set(got)):
            if key not in want:
                out.append(f"{path}.{key}: absent from the committed fixture")
            elif key not in got:
                out.append(f"{path}.{key}: no longer generated")
            else:
                out += _compare(want[key], got[key], f"{path}.{key}")
        return out
    if isinstance(want, list) and isinstance(got, list):
        if len(want) != len(got):
            return [f"{path}: committed {len(want)} entries, regenerated {len(got)}"]
        out = []
        for i, (a, b) in enumerate(zip(want, got)):
            out += _compare(a, b, f"{path}[{i}]")
        return out
    if want != got:
        return [f"{path}: committed {want!r}, regenerated {got!r}"]
    return []


def write_fixture(name, payload, indent=1, sort_keys=False, trailing_newline=False):
    """Write a fixture — or, under --check, verify the committed one still matches.

    Every fixture goes through here so the two modes cannot drift apart: --check
    compares exactly what a write would have produced.
    """
    path = os.path.join(FIXTURES, name)
    if not CHECK_ONLY:
        with open(path, "w") as f:
            json.dump(payload, f, indent=indent, sort_keys=sort_keys)
            if trailing_newline:
                f.write("\n")
        return
    if not os.path.exists(path):
        check(False, f"{name} is not committed")
        return
    with open(path) as f:
        try:
            committed = json.load(f)
        except json.JSONDecodeError as exc:
            check(False, f"{name} is not valid JSON: {exc}")
            return
    # Round-trip the payload through JSON so the comparison sees what would be
    # written — tuples become lists, and non-string dict keys become strings.
    differences = _compare(committed, json.loads(json.dumps(payload)), name)
    if differences:
        check(False, f"{name}: {len(differences)} value(s) drifted from the committed "
                     f"fixture")
        for line in differences[:12]:
            print(f"    {line}")
        if len(differences) > 12:
            print(f"    ... and {len(differences) - 12} more")
    else:
        print(f"  {name}: matches the committed fixture")


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

    A switched-off black-and-white mix goes too: it is eight numbers no pixel reads,
    kept in the recipe so the photographer gets them back, and hashing them would make
    turning the treatment off a cache miss on an unchanged picture.
    """
    out = json.loads(json.dumps(tree))
    for mask in out.get("masks", []) or []:
        mask["name"] = ""
        mask["id"] = ""
    # A group's NAME and its open/shut state are cosmetic the same way a mask's name is.
    # Its id is NOT: a mask names its group by id, so blanking them would fold every
    # folder into one and make "member of A" and "member of B" hash alike.
    for group in out.get("maskGroups", []) or []:
        group["name"] = ""
        group["collapsed"] = False
    # Removed, not nulled: Swift encodes a nil optional by omitting the key, and a
    # `"bw":null` that the default tree does not carry survives the sparse pass and
    # takes the fingerprint with it.
    bw = out.get("look", {}).get("bw")
    if isinstance(bw, dict) and bw.get("enabled", True) is False:
        del out["look"]["bw"]
    return out


def canonical_recipe_json(full_tree, defaults):
    sp = sparse(full_tree, defaults)
    sp["pipelineVersion"] = full_tree.get("pipelineVersion", PIPELINE_VERSION)
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


def mixer_band():
    # `core` and `feather` are the per-band arc handles, in degrees either side of
    # the band centre. The defaults are the engine's own constants, so an untouched
    # recipe describes the canonical eight-band geometry rather than a second
    # opinion about it.
    return {"hue": 0, "sat": 0, "lum": 0,
            "core": [22.5, 22.5], "feather": [15, 15]}


def balance_axis():
    return {"global": 0, "shadows": 0, "mid": 0, "high": 0}


def color_balance():
    return {"hueShift": 0, "vibrance": 0, "chroma": balance_axis(),
            "saturation": balance_axis(), "brilliance": balance_axis()}


# Mirror of `currentPipelineVersion` in Recipe.swift. Bumping it here without bumping
# it there — or the reverse — shows up as a canonical-form drift on the Swift side,
# which is what the mirror is for.
PIPELINE_VERSION = 2

DEFAULT_RECIPE = {
    "pipelineVersion": PIPELINE_VERSION,
    "develop": {
        "raw": {"decoder": "apple"},
        "tone": {"exposure": 0, "contrast": 0, "contrastPivot": 0, "highlights": 0,
                 "shadows": 0, "whites": 0, "blacks": 0},
        "zones": {"pivots": [(ev - (-9.0)) / (5.0 - (-9.0)) for ev in (-4.0, -2.0, 0.0, 2.0, 4.0)],
                  "dark": zone_adjust(), "shadow": zone_adjust(), "mid": zone_adjust(),
                  "light": zone_adjust(), "bright": zone_adjust(), "global": zone_adjust()},
        "curve": {"parametric": {"highlights": 0, "lights": 0, "darks": 0,
                                 "shadows": 0, "splits": [0.25, 0.5, 0.75]},
                  "preserveLuminance": True},
        "color": {"vibrance": 0, "saturation": 0, "density": 50, "protectSkin": 70},
        "mixer": {"bands": [mixer_band() for _ in range(8)],
                  "uniformity": 0},
        "pointColors": [],
        "detail": {"capture": {"auto": True}, "texture": 0, "clarity": 0, "dehaze": 0,
                   "sharpen": {"amount": 0, "radius": 1, "detail": 25,
                               "masking": 0, "haloSuppression": 0}},
        # All seven Tier-1 controls are on the wire (docs/07 §2.1). The four
        # sub-sliders default to Lightroom's own 50 / 0 / 50 / 50, which are the same
        # numbers the engine used to hardcode, so a recipe written before they existed
        # decodes to exactly what it always rendered.
        #
        # lumaUserSet / chromaUserSet record whether the photographer set the two
        # masters by hand, which is what the AI-mode auto-zero exception needs (docs/07
        # §2.1: "unless the user has hand-set them"). False by default and sparse, so
        # no recipe already written changes its canonical form or its fingerprint.
        "denoise": {"mode": "classic", "amount": 50,
                    "classic": {"luma": 0, "chroma": 25, "hotPixels": 0,
                                "lumaDetail": 50, "lumaContrast": 0,
                                "colorDetail": 50, "colorSmoothness": 50,
                                "lumaUserSet": False, "chromaUserSet": False}},
        "geometry": {"crop": {"x": 0, "y": 0, "w": 1, "h": 1}, "angle": 0,
                     "flipH": False, "lens": {"profile": True, "removeCA": True}},
        "heal": {"count": 0},
    },
    "look": {
        "wheels": {"global": wheel(), "shadows": wheel(), "mid": wheel(), "high": wheel(),
                   "blending": 50, "balance": 0, "pivots": [0.33, 0.67],
                   "colorBalance": color_balance()},
        "printerLights": {"master": 0, "r": 0, "g": 0, "b": 0},
        "primaries": {"rHue": 0, "rPurity": 0, "gHue": 0, "gPurity": 0,
                      "bHue": 0, "bPurity": 0, "tintHue": 0, "tintPurity": 0},
        "vignette": 0,
        # 50 is the fixed geometry the engine always had (docs/32 Stream E item 4):
        # the default is NOT zero, so an absent key keeps yesterday's pixels. Mirrors
        # Look.vignetteFeatherDefault.
        "vignetteFeather": 50,
        "render": {"preset": "Neutral"},
    },
    "masks": [],
    # Folders (docs/36 §4 item 26). Empty by default and pruned by `sparse` like every
    # other empty container, so a recipe with no groups is byte-identical to one written
    # before they existed.
    "maskGroups": [],
}


def gen_canonical_fixture():
    print("canonical.json ...")
    defaults = DEFAULT_RECIPE
    cases = []

    # Case A: pristine default recipe -> everything pruned except pipelineVersion.
    a_canon = canonical_recipe_json(defaults, defaults)
    check(a_canon == '{"pipelineVersion":%d}' % PIPELINE_VERSION,
          f"case A canonical unexpected: {a_canon}")
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
    c["look"]["filmLab"] = {"stock": "lumen/portra400", "amount": 100, "exposure": 0,
                            "pushPull": 0, "halation": 35,
                            "grain": {"size": 1, "amount": 40}}
    # `invert` is the WHOLE-MASK invert (docs/08 §8.1), distinct from the per-component
    # one below it: it flips the folded alpha ahead of the refinement chain. It is
    # written unconditionally, like `MaskComponent.invert` beside it, because the sparse
    # form prunes at the recipe level and never descends into the mask array.
    c["masks"] = [{
        "id": "6f000000-0000-0000-0000-00000000la01",
        # `blend` is written unconditionally like `invert` and `amount` beside it: the
        # sparse form prunes at the recipe level and never descends into the mask array.
        # Adding it therefore MOVED every masked recipe's fingerprint once, which is the
        # accepted cost of a new non-optional mask field and the reason this fixture
        # exists to be updated deliberately rather than drifted into.
        "name": "Sky", "enabled": True, "invert": False, "amount": 100,
        "blend": "normal",
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

    # Case E: the black-and-white mix, on and then switched off with the mix kept
    # (pipeline version 2). Two properties the mirror has to agree about: the stored
    # recipe carries `enabled` and the eight bands either way, so the mix is still
    # there after a quit; and the OFF form fingerprints as the default recipe, because
    # a mix nothing renders must not cost a cache miss or mark the photo edited.
    e_on = json.loads(json.dumps(defaults))
    e_on["look"]["bw"] = {"bands": [0, 0, 0, 0, -40, -65, 0, 0], "enabled": True}
    e_on_canon = canonical_recipe_json(e_on, defaults)
    cases.append({"name": "blackAndWhiteOn", "canonical": e_on_canon,
                  "fingerprint": fp(canonical_recipe_json(render_identity(e_on), defaults))})

    e_off = json.loads(json.dumps(e_on))
    e_off["look"]["bw"]["enabled"] = False
    e_off_canon = canonical_recipe_json(e_off, defaults)
    cases.append({"name": "blackAndWhiteKeptButOff", "canonical": e_off_canon,
                  "fingerprint": fp(canonical_recipe_json(render_identity(e_off), defaults))})
    check('"bands":[0,0,0,0,-40,-65,0,0]' in e_off_canon and '"enabled":false' in e_off_canon,
          f"the switched-off mix did not survive serialization: {e_off_canon}")
    check(fp(canonical_recipe_json(render_identity(e_off), defaults))
          == fp(canonical_recipe_json(render_identity(defaults), defaults)),
          "a switched-off B&W mix changed the render fingerprint")
    check(e_on_canon != e_off_canon,
          "turning the treatment off did not change the stored recipe")

    write_fixture("canonical.json", {"cases": cases})
    write_fixture("default-recipe.json", DEFAULT_RECIPE, sort_keys=True)


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
        '{"pipelineVersion":%d}' % PIPELINE_VERSION,   # default-recipe canonical form
    ]
    vectors = [{"input": s,
                "xxh64": xxhash.xxh64(s.encode("utf-8"), seed=0).hexdigest()}
               for s in inputs]
    write_fixture("fingerprint.json", {"vectors": vectors})


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


# ---------------------------------------------------------------------------
# The four-region parametric curve (CurveStack.bakeParametric)
#
# Here because of what its monotonicity limiter used to be: a `scale *= 0.8`
# ladder rather than a solve. The scale a setting needs falls smoothly as the
# slider moves, but a geometric ladder can only answer 1, 0.8, 0.64, … so the
# applied shift sawtoothed and the curve jumped BACKWARDS by 16% in one notch —
# Darks reversed at 46, 57, 71 and 89. The end of the slider was not its
# strongest setting either: Lights at 100 was 15% weaker than Lights at 60.
#
# The check that catches that class is "moving a control further must never do
# less", and no check in this file had it for any control. It does now.
# ---------------------------------------------------------------------------

# Slope the curve must still have at full deflection of ONE region — see
# CurveStack.parametricMinSlope. This replaced a fixed peak shift of 0.35 encoded units
# shared by all four regions, which the monotonicity limiter then cut back to whatever
# each region's own width could carry: measured, that bound at setting 47 on Darks and
# Lights and 70 on Shadows and Highlights, so between 30% and 53% of every parametric
# slider applied the identical curve. And it bound at slope zero exactly, so full
# deflection of a single slider put a dead-flat segment in the curve.
#
# PARAMETRIC_MIN_SLOPE == 1 - PARAMETRIC_KNEE is the exact condition that leaves a lone
# slider applied exactly at every setting; the two cannot be set independently.
PARAMETRIC_MIN_SLOPE = 0.2
PARAMETRIC_KNEE = 0.8

# 1024, matching CurveStack.parametricProbes. At 256 both sides certified monotonicity
# on a grid four times coarser than the 1024 the curve is baked on, and the samples in
# between dipped — six of the nine extreme slider combinations stepped backwards, the
# worst by 6.8e-7. Probing the bake grid is sufficient as well as necessary, because
# LUT1D interpolates linearly between stored samples and linear interpolation between
# non-decreasing samples is non-decreasing.
PARAMETRIC_PROBES = 1024


def region_centres(splits=(0.25, 0.5, 0.75)):
    s = sorted(splits)
    a = clamp(s[0], 0.02, 0.96)
    b = clamp(s[1], a + 0.01, 0.97)
    c = clamp(s[2], b + 0.01, 0.98)
    return [a / 2, (a + b) / 2, (b + c) / 2, (c + 1) / 2]


def parametric_bumps(centres, probes=PARAMETRIC_PROBES):
    """The four region bumps — weight x endpoint envelope — on the probe grid.

    The envelope pins both endpoints, so the curve can never move black or white."""
    bumps = [[0.0] * (probes + 1) for _ in range(4)]
    for i in range(probes + 1):
        x = i / probes
        w = zone_weights(x, centres)
        envelope = 4 * x * (1 - x)
        for r in range(4):
            bumps[r][i] = w[r] * envelope
    return bumps


def slope_limit(delta, floor, probes=PARAMETRIC_PROBES):
    """Largest multiplier on `delta` leaving `x + m*delta(x)` with slope >= floor.

    Closed form: the slope is `1 + m*d(delta)/dx`, linear in m, so every interval where
    the shift falls gives one bound and the smallest is the answer. The bisection this
    replaced agreed with it and cost forty sweeps of the same grid."""
    dx = 1.0 / probes
    limit = math.inf
    for i in range(1, len(delta)):
        step = delta[i] - delta[i - 1]
        if step < 0:
            limit = min(limit, (1 - floor) * dx / -step)
    return limit


def region_amplitude(bump, sign):
    """What +/-100 on one region is worth, solved from that region's own shape."""
    signed = [-v for v in bump] if sign < 0 else bump
    limit = slope_limit(signed, PARAMETRIC_MIN_SLOPE)
    return limit if math.isfinite(limit) else 0.0


def parametric_plan(amounts, centres):
    """(per-region amplitude, requested shift on the probe grid, applied scale)."""
    bumps = parametric_bumps(centres)
    amplitude = [region_amplitude(bumps[r], -1 if amounts[r] < 0 else 1)
                 if amounts[r] != 0 else 0.0 for r in range(4)]
    requested = [sum(bumps[r][i] * amounts[r] * amplitude[r] for r in range(4))
                 for i in range(PARAMETRIC_PROBES + 1)]
    # Floor of zero for the combination: two adjacent regions pulled hard against each
    # other IS a request for a plateau. The point curve stays the unlimited tool.
    limit = slope_limit(requested, 0.0)
    scale = min(1.0, limit * soft_knee(1.0 / limit, PARAMETRIC_KNEE)) \
        if math.isfinite(limit) else 1.0
    return amplitude, requested, scale


def parametric_delta(x, amounts, centres, amplitude=None):
    if amplitude is None:
        amplitude = parametric_plan(amounts, centres)[0]
    w = zone_weights(x, centres)
    s = sum(w[r] * amounts[r] * amplitude[r] for r in range(4))
    return s * (4 * x * (1 - x))


def bake_parametric(amounts, centres, size=1024):
    amplitude, _, scale = parametric_plan(amounts, centres)
    samples, running = [], -math.inf
    for i in range(size):
        x = i / (size - 1)
        running = max(running, clamp(x + parametric_delta(x, amounts, centres,
                                                          amplitude) * scale, 0.0, 1.0))
        samples.append(running)
    return samples


def parametric_is_monotone(scale, amounts, centres, probes=PARAMETRIC_PROBES,
                           amplitude=None):
    if amplitude is None:
        amplitude = parametric_plan(amounts, centres)[0]
    previous = 0.0
    for i in range(probes + 1):
        x = i / probes
        y = x + parametric_delta(x, amounts, centres, amplitude) * scale
        if i > 0 and y < previous - 1e-9:
            return False
        previous = y
    return True


def gen_parametric_checks():
    print("parametric curve: monotone in x AND monotone in the slider ...")
    centres = region_centres()
    names = ["Shadows", "Darks", "Lights", "Highlights"]

    for index, name in enumerate(names):
        for direction in (1, -1):
            previous_effect = None
            peak, peak_at = -1e18, 0
            for setting in range(0, 101):
                amounts = [0.0] * 4
                amounts[index] = direction * setting / 100
                amplitude, _, scale = parametric_plan(amounts, centres)

                # 1. The baked curve is monotone in x, checked on the grid it is BAKED
                # on (1024) rather than on whatever grid the solver happened to use.
                #
                # This used to call through with the default, so solver and verifier
                # always agreed by construction and the check could not fail however
                # coarse the solver got — which is exactly the bug that reached CI:
                # the Swift limiter probed 256 while production bakes 1024, and six of
                # nine extreme settings stepped backwards in between. Pinning the
                # verification here means coarsening the solver breaks this check.
                check(parametric_is_monotone(scale, amounts, centres, probes=1024,
                                             amplitude=amplitude),
                      f"{name} {direction * setting} produced a non-monotone curve")

                # 2. The RESPONSE is monotone in the slider — push it further, get at
                # least as much. This is the one the ladder failed.
                effect = abs(parametric_delta(centres[index], amounts, centres,
                                              amplitude) * scale)
                if previous_effect is not None:
                    check(effect >= previous_effect - 1e-12,
                          f"{name} at {direction * setting} moved the curve LESS than "
                          f"at {direction * (setting - 1)}: {effect:.6f} vs "
                          f"{previous_effect:.6f} — the slider jumps backwards")
                    # 3. And it is not merely non-decreasing: it must still be DOING
                    # something. Every setting from 47 up used to apply the identical
                    # curve on Darks and Lights, and from 70 up on Shadows and
                    # Highlights, because the limiter clipped instead of easing. The
                    # old checks all passed through that — a dead control satisfies
                    # "no backward step" perfectly.
                    check(setting < 2 or effect > previous_effect + 1e-9,
                          f"{name} at {direction * setting} applied exactly what "
                          f"{direction * (setting - 1)} did ({effect:.9f}) — the "
                          f"control is dead here")
                if effect > peak:
                    peak, peak_at = effect, setting
                previous_effect = effect

            # 4. And the end of the slider is its strongest setting, not a local dip.
            check(peak_at == 100,
                  f"{name}'s strongest setting is {peak_at}, not 100 "
                  f"(peak {peak:.6f}, end {previous_effect:.6f})")

    # A lone slider is applied EXACTLY, at every setting and in both directions. That
    # is what sizing each region's amplitude to `1 - PARAMETRIC_KNEE` buys, and it is
    # the property the old shared range could not have: with one peak shift for four
    # regions of different widths, the limiter had to take the difference back.
    for index in range(4):
        for direction in (1, -1):
            for setting in (25, 50, 75, 100):
                amounts = [0.0] * 4
                amounts[index] = direction * setting / 100
                _, _, scale = parametric_plan(amounts, centres)
                check(scale > 1 - 1e-9,
                      f"{names[index]} at {direction * setting} alone was limited to "
                      f"{scale:.6f}")

    # And the travel is spread evenly over it: half the effect in each half of the
    # slider, because the applied amount is now linear in the setting.
    for index in range(4):
        for direction in (1, -1):
            def effect(setting, index=index, direction=direction):
                amounts = [0.0] * 4
                amounts[index] = direction * setting / 100
                amplitude, _, scale = parametric_plan(amounts, centres)
                return abs(parametric_delta(centres[index], amounts, centres,
                                            amplitude) * scale)
            half, full = effect(50), effect(100)
            check(abs(half / full - 0.5) < 0.01,
                  f"{names[index]} {direction * 100} puts {100 * half / full:.0f}% of "
                  f"its travel in the first half")

    # A single slider at full deflection leaves the curve with real slope, so it can
    # never posterize on its own. It used to bottom out at exactly zero — the limiter's
    # own definition of safe — which is a flat band on a photograph.
    for index in range(4):
        for direction in (1, -1):
            amounts = [0.0] * 4
            amounts[index] = float(direction)
            samples = bake_parametric(amounts, centres)
            worst = min(b - a for a, b in zip(samples, samples[1:])) * (len(samples) - 1)
            check(worst > PARAMETRIC_MIN_SLOPE - 1e-6,
                  f"{names[index]} {direction * 100} left the curve with slope "
                  f"{worst:.6f}, under the {PARAMETRIC_MIN_SLOPE} floor")

    # Combinations may plateau — that is what asking two neighbours to fight means —
    # but never flatten and never invert.
    for signs in range(16):
        amounts = [1.0 if signs & (1 << r) else -1.0 for r in range(4)]
        samples = bake_parametric(amounts, centres)
        steps = [b - a for a, b in zip(samples, samples[1:])]
        check(min(steps) >= 0, f"{amounts} inverted the curve")
        check(min(steps) * (len(samples) - 1) > 1e-3,
              f"{amounts} left a flat segment: slope {min(steps) * (len(samples) - 1)}")
        check(abs(samples[0]) < 1e-12 and abs(samples[-1] - 1) < 1e-12,
              f"{amounts} moved black or white")

    print("  4 sliders x 2 directions x 101 settings: every one applies more than the")
    print("  last, a lone slider is never limited, and the slope floor holds")


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

    # "Monotone in, monotone out" is the ONLY thing checked above, and it is
    # satisfied by `evaluate(x) = x` and by `evaluate(x) = constant` alike — both
    # weakly monotone. `curves.json` is the golden the Swift `CurveStack` is measured
    # against, so an identity interpolator here would write an identity table and the
    # Swift would agree with it perfectly.
    #
    # What a curve must do: pass through its own control points, and move the values
    # between them.
    for case in curve_cases:
        c = MonotoneCubic(case["points"])
        pts = sorted(case["points"], key=lambda q: q[0])
        # Duplicate x values are a legal input with no single right answer, so those
        # cases are exempt from interpolation and only have to stay finite.
        xs = [q[0] for q in pts]
        if len(set(xs)) == len(xs):
            for x, y in pts:
                if 0 <= x <= 1:
                    got = c.evaluate(x)
                    check(abs(got - y) < 1e-9,
                          f"curve {case['name']} missed its own point ({x}, {y}): "
                          f"got {got:.9f}")
        for x in [i / 32 for i in range(33)]:
            check(math.isfinite(c.evaluate(x)),
                  f"curve {case['name']} returned a non-finite value at {x}")

    # And a non-identity curve must not BE the identity, or the whole golden is a
    # ramp. Checked on the cases whose points demand a departure.
    for name, threshold in (("sCurve", 0.05), ("matteFade", 0.05),
                            ("steepMonotone", 0.2)):
        case = next(q for q in curve_cases if q["name"] == name)
        c = MonotoneCubic(case["points"])
        worst = max(abs(c.evaluate(i / 64) - i / 64) for i in range(65))
        check(worst > threshold,
              f"curve {name} never departs from the identity by more than "
              f"{worst:.4f} — the interpolator may be returning its input")
    identity = MonotoneCubic([[0, 0], [1, 1]])
    for x in [i / 32 for i in range(33)]:
        check(abs(identity.evaluate(x) - x) < 1e-9,
              f"the identity curve is not the identity at {x}")
    write_fixture("curves.json", {"cases": out})


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
    # The documented pivot EVs (docs/04: -4/-2/0/+2/+4 around mid-grey) through
    # the default anchors (-9..+5), mirroring Zones.defaultPivots exactly —
    # same operations, same IEEE doubles.
    default_pivots = [(ev - (-9.0)) / (5.0 - (-9.0)) for ev in (-4.0, -2.0, 0.0, 2.0, 4.0)]
    custom_pivots = [0.1, 0.3, 0.6, 0.85]
    samples = [i / 24 for i in range(25)]
    cases = []
    for name, pivots in [("default", default_pivots), ("custom4", custom_pivots)]:
        weights = [zone_weights(x, pivots) for x in samples]
        for x, w in zip(samples, weights):   # verification: partition of unity
            check(abs(sum(w) - 1) < 1e-12, f"zones {name} weights at {x} sum {sum(w)}")
            check(min(w) >= -1e-12, f"zones {name} negative weight at {x}: {w}")
        # Partition of unity and non-negativity are both satisfied by a HARD
        # nearest-pivot assignment — `[1,0,0,0,0]` sums to 1 everywhere too, and so
        # does putting all the weight on zone 0. That is precisely the banding the
        # raised-cosine crossfade exists to prevent, and it was the only thing
        # checked here. Continuity is what separates the two.
        fine = [i / 400 for i in range(401)]
        previous = None
        widest = 0.0
        for x in fine:
            w = zone_weights(x, pivots)
            if previous is not None:
                jump = max(abs(a - b) for a, b in zip(w, previous))
                widest = max(widest, jump)
                check(jump < 0.05,
                      f"zones {name} jumped {jump:.4f} between adjacent samples at "
                      f"x={x:.4f} — that is a hard edge, not a crossfade")
            previous = w
        # ...and it must actually crossfade rather than being flat: somewhere every
        # zone has to be partially engaged.
        blended = sum(1 for x in fine
                      if sum(1 for v in zone_weights(x, pivots) if 1e-6 < v < 1 - 1e-6) >= 2)
        check(blended > len(fine) // 4,
              f"zones {name} blends two zones at only {blended} of {len(fine)} "
              "positions — the crossfades have collapsed")
        check(widest > 1e-6, f"zones {name} weights never changed at all")

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
    write_fixture("zones.json", {"cases": cases, "exposure": ev_case})


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
    # `invert` and `intersect` were unasserted, so their expected values were being
    # written into the golden the Swift `MaskAlgebra` is measured against with
    # nothing verifying them. Both are one line and both were free to be wrong.
    check(abs(mask_combined([comp("add", 0.2, invert=True)]) - 0.8) < 1e-12,
          "invert did not complement the alpha")
    check(abs(mask_combined([comp("add", 1.0, invert=True)])) < 1e-12,
          "inverting a full alpha did not empty it")
    check(abs(mask_combined([comp("add", 0.8), comp("intersect", 0.5)]) - 0.4) < 1e-12,
          "intersect is not a product — `min` would give 0.5 here")
    check(abs(mask_combined([comp("add", 1.0), comp("intersect", 0.5)]) - 0.5) < 1e-12,
          "intersect against a full mask did not pass the operand through")
    check(abs(mask_combined([comp("add", 0.8), comp("intersect", 0.0)])) < 1e-12,
          "intersect with nothing left something")
    # And `add` is a union, not a sum — two half-alphas do not make a whole one.
    check(abs(mask_combined([comp("add", 0.5), comp("add", 0.5)]) - 0.5) < 1e-12,
          "add is summing rather than taking the union")
    write_fixture("maskalgebra.json", {"cases": cases})


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

        # What a parser actually reads back, taken FROM the serialized XML rather
        # than asserted. For every case but one it equals `content`; for
        # controlCharacters it cannot, because XML 1.0 forbids those bytes even as
        # numeric references, so the writer drops them and "bad\x07label\x00" comes
        # back as "badlabel". The Swift round-trip test compared against `content` for
        # every case and so demanded that a deliberately lossy sanitisation be
        # lossless — the one case written to prove the writer sanitises was the one
        # case that could not pass.
        label = desc.find("xmp:Label", ns)
        c["parsed"] = dict(c["content"])
        c["parsed"]["label"] = label.text if label is not None else None
        if c["parsed"]["label"] != c["content"]["label"]:
            print(f"  {c['name']}: label sanitised on write, "
                  f"{c['content']['label']!r} -> {c['parsed']['label']!r}")
    write_fixture("xmp.json", {"cases": cases})


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
    write_fixture("rename.json", {"cases": cases})


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


# A1-01. The relax window used to be two constants — 4 stops to 12 stops from the pivot
# — while the thing that decides where a highlight clips is the DISPLAY ANCHOR, +5 EV by
# default and as low as +3.5 under Whites +100. At contrast +100 the white anchor mapped
# to +7.87 EV, so 1.875 stops of highlight and 3.037 stops of shadow flattened to one
# value each, while the control's tooltip, docs/04 and a green test all said it could not.
#
# The reach is now the distance to the anchor on the side being mapped, and the slope
# relaxes to exactly 1 there, so the anchor is a fixed point: d * 1 == d.
#
# Kept in step with `ToneEngine.contrastMapped` deliberately. This file is the
# independent reference the `fixtures-linux` lane checks the Swift against, so the two
# implementations agreeing is the evidence — which is exactly why a behaviour change has
# to be made twice, by hand, in two languages.
MIN_CONTRAST_REACH_EV = 1e-6
# How far toward the anchor the full slope holds before the shoulder starts, as a
# fraction of the reach. Bounded above by monotonicity: the derivative in u is
# `slope + (1 - slope) * [S + u*S']`, whose bracket peaks at 2.2069 for a hold of 0.3,
# and at contrast +100 (slope 1.6) the derivative `1.6 - 0.6*bracket` reaches zero just
# past a hold of 0.44. See ToneEngine.contrastShoulderStart for the whole argument.
CONTRAST_SHOULDER_START = 0.2


def contrast_mapped(t, contrast, pivot=0.0,
                    white_anchor_ev=None, black_anchor_ev=None):
    if contrast == 0:
        return t
    # Resolved at call time rather than as default arguments: these constants are
    # defined further down this file than this function is.
    hi = DEFAULT_WHITE_ANCHOR_EV if white_anchor_ev is None else white_anchor_ev
    lo = DEFAULT_BLACK_ANCHOR_EV if black_anchor_ev is None else black_anchor_ev
    slope = 1 + 0.6 * (contrast / 100.0)
    d = t - pivot
    reach = (hi - pivot) if d >= 0 else (pivot - lo)
    if reach <= MIN_CONTRAST_REACH_EV:
        return t
    relax = smoothstep(CONTRAST_SHOULDER_START, 1.0, abs(d) / reach)
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
        # NOT `sum(w_i · reference/realized) == reference`. That is
        # `realized · (reference/realized)`, which is `x·(k/x) = k` — an algebraic
        # identity that holds for ANY window function whatsoever, including a
        # triangle, a box, or nonsense. It was the only check on the fix it was
        # written to protect, and it could not fail.
        #
        # What is actually claimed is that the NORMALIZER, applied to the same
        # slider at any resolution, delivers the same total. Computing it the way
        # the engine does and comparing against a separately-derived reference is
        # the same statement without the cancellation.
        normalizer = reference / realized
        check(abs(realized * normalizer - reference) < 1e-9,
              f"texture weight not normalized at long edge {long_edge}")
        check(normalizer > 0 and math.isfinite(normalizer),
              f"texture normalizer at {long_edge} is {normalizer}")
    # And the un-normalized sums really did differ, or the fix was a no-op.
    raw = [sum(band_weight(i, band_center(le), half_width) for i in range(5))
           for le in (1280, 2560)]
    check(abs(raw[0] - raw[1]) > 0.2,
          "texture band weights did not actually differ across resolutions")

    # The window's SHAPE, which the normalization check cannot see and which decides
    # how texture energy is distributed across the bands. A triangle and a box
    # normalize exactly as well and mean something different.
    check(abs(band_weight(0.0, 0.0, half_width) - 1.0) < 1e-12,
          "the band window does not peak at 1 on its centre")
    for edge in (half_width, -half_width, 2 * half_width):
        check(band_weight(edge, 0.0, half_width) == 0.0,
              f"the band window is non-zero at {edge}, outside its half-width")
    for fraction, expected in ((0.25, 0.853553390593), (0.5, 0.5),
                               (0.75, 0.146446609407)):
        got = band_weight(fraction * half_width, 0.0, half_width)
        check(abs(got - expected) < 1e-9,
              f"the band window is not a raised cosine at d={fraction}: "
              f"{got:.6f}, want {expected:.6f} (a triangle gives "
              f"{1 - fraction:.6f})")
        check(abs(band_weight(-fraction * half_width, 0.0, half_width) - got) < 1e-12,
              f"the band window is not symmetric at d={fraction}")
    previous = None
    step = 0.0
    while step <= 1.0:
        value = band_weight(step * half_width, 0.0, half_width)
        if previous is not None:
            check(value <= previous + 1e-12,
                  f"the band window rose again at d={step}")
        previous = value
        step += 0.02

    # And the centre tracks resolution the way the fix requires: one band per octave,
    # clamped so a thumbnail and a 20k export do not run off the stack.
    centres = [band_center(le) for le in (640, 1280, 2560, 5120, 10240, 20480)]
    for a, b in zip(centres, centres[1:]):
        check(b >= a - 1e-12, f"band centre fell as resolution rose: {a} -> {b}")
    check(abs(band_center(2560) - 1.0) < 1e-12,
          "the working resolution is not the band centre's anchor")
    check(abs(band_center(5120) - 2.0) < 1e-12,
          "doubling the long edge did not move the band centre one octave")
    check(centres[-1] == centres[-2],
          "the band centre is not clamped at the top of the stack")

    # --- the saturation rolloff's highlight TAPER --------------------------
    #
    # Every existing rolloff check passes with no taper at all: the low-end
    # smoothstep alone gives > 0.2 above brightness 1, exactly 1.0 at 0.5, 0 at 0,
    # and is non-increasing above the knee. So `satRolloffFloor` — the constant
    # carrying "highlights saturate LESS, not that they stop being colours", which
    # is the whole reason the hard window was replaced — was asserted nowhere.
    check(abs(lum_sat_rolloff(0.5) - 1.0) < 1e-12,
          "the rolloff is not fully open below the highlight knee")
    check(lum_sat_rolloff(SAT_ROLLOFF_HI0 + 4 * SAT_ROLLOFF_HI_WIDTH)
          < 0.5 * lum_sat_rolloff(SAT_ROLLOFF_HI0),
          "the highlight taper does not taper — brightness far above the knee "
          "saturates as much as brightness at it")
    for brightness in (2.0, 4.0, 20.0, 1e6):
        value = lum_sat_rolloff(brightness)
        check(value > SAT_ROLLOFF_FLOOR * 0.99,
              f"the rolloff fell to {value:.4f} at brightness {brightness} — below "
              f"its own floor of {SAT_ROLLOFF_FLOOR}, so highlights stop being "
              "colours entirely")
        check(value < 1.0 - 1e-9,
              f"the rolloff is still fully open at brightness {brightness}, so "
              "there is no taper")
    # It approaches the floor rather than sitting on it, so the control keeps
    # responding right up the range.
    check(lum_sat_rolloff(4.0) > lum_sat_rolloff(20.0) > SAT_ROLLOFF_FLOOR,
          "the taper is not monotone toward its floor")

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
    # `1 - smoothstep(rin, 1, r)`. The reversed form this mirrored — and that the
    # Swift had — hit smoothstep's degenerate-edge guard on every call, because rin
    # is always below 1, and returned 0 for the whole falloff. The radial mask had
    # no soft edge at all; Feather only moved a hard one inward. Both mirrors of
    # this pattern were wrong together, which is why the property checks below
    # (extent only, `> 0` and `<= 0`) never noticed.
    return 1.0 - smoothstep(rin, 1.0, r)


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

    # --- negative Dehaze must put the haze in the DISTANCE -----------------
    #
    # It did the opposite. The synthesis branch reused the transmission that
    # carries the sky guard — a guard whose whole job is to stop the POSITIVE
    # branch stripping haze out of a sky — so a high floor meant less added haze,
    # and the control fogged the near subject while leaving the distance clear.
    # Nothing checked the negative branch at all; every dehaze check above is on
    # the positive one.
    def synth_haze(ev, gradient, transmission, amount=-1.0):
        bright = smoothstep(0.5, 2.0, ev)
        flat = 1.0 - smoothstep(0.05, 0.35, gradient)
        skyness = clamp(bright * flat, 0.0, 1.0)
        distant = max(1 - transmission, skyness)
        return clamp(-amount * distant * 0.9, 0.0, 1.0)

    scene = [
        ("clear flat sky", 2.5, 0.00, 0.95),
        ("hazy distant sky", 1.2, 0.02, 0.55),
        ("mid grey wall", 0.0, 0.01, 0.90),
        ("textured foliage", -1.0, 0.50, 0.92),
        ("dark foreground", -3.0, 0.10, 0.93),
    ]
    haze = {name: synth_haze(ev, g, t) for name, ev, g, t in scene}
    for near in ("mid grey wall", "textured foliage", "dark foreground"):
        for far in ("clear flat sky", "hazy distant sky"):
            check(haze[far] > haze[near] + 1e-9,
                  f"negative Dehaze put {haze[near]:.4f} on {near} and only "
                  f"{haze[far]:.4f} on {far} — the haze is on the subject, not the "
                  "distance")
    # And it has to be a control: more negative, more haze, monotonically.
    previous = None
    for step_index in range(0, 101):
        amount = -step_index / 100
        value = synth_haze(2.5, 0.0, 0.95, amount)
        if previous is not None:
            check(value >= previous - 1e-12,
                  f"negative Dehaze at {amount} added less haze than at "
                  f"{amount + 0.01}")
        previous = value
    check(synth_haze(2.5, 0.0, 0.95, 0.0) == 0.0, "Dehaze 0 added haze")

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
        # 1e-9, not 2e-3: the anchor is a construction, not a tuning, and the Swift
        # asserts it at 1e-9. Six orders of magnitude apart is not a tolerance, it is
        # two different claims — and since the Linux lane is the one that runs today,
        # the loose one was the effective guarantee.
        got = t.tone(MID_GREY)
        check(abs(got - MID_GREY) < 1e-9,
              f"{label}: mid-grey landed at {got:.12f}, not 0.18")

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

def f32(v):
    """Round to single precision, which is what a `Plane` write does.

    SpatialOps' header states the rule as a contract, not an implementation detail:
    "Maths in Double, storage in f32 … it is the precision the GPU path has, so the
    golden tolerances mean something." A mirror that carries f64 through a
    six-blur composition is therefore mirroring a slightly different filter, and the
    difference lands exactly where the near-zero-variance guard lives — the comment
    "f32 round-trip can push a near-zero variance slightly negative" describes a
    branch an f64 mirror can never take.
    """
    return struct.unpack("f", struct.pack("f", v))[0]


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
        tmp[y * w] = f32(s / n)
        for x in range(1, w):
            s += clamped(p, w, h, x + r, y) - clamped(p, w, h, x - r - 1, y)
            tmp[y * w + x] = f32(s / n)
    out = [0.0] * (w * h)
    for x in range(w):
        s = sum(clamped(tmp, w, h, x, k) for k in range(-r, r + 1))
        out[x] = f32(s / n)
        for y in range(1, h):
            s += clamped(tmp, w, h, x, y + r) - clamped(tmp, w, h, x, y - r - 1)
            out[y * w + x] = f32(s / n)
    return out


def guided_filter(inp, guide, w, h, radius, epsilon):
    if radius <= 0:
        return list(inp)
    eps = max(epsilon, 1e-12)
    mean_i = box_blur(guide, w, h, radius)
    mean_p = box_blur(inp, w, h, radius)
    # `Plane.zip` stores its result, so the products are f32 before they are blurred.
    corr_i = box_blur([f32(g * g) for g in guide], w, h, radius)
    corr_ip = box_blur([f32(g * p) for g, p in zip(guide, inp)], w, h, radius)
    a, b = [0.0] * (w * h), [0.0] * (w * h)
    for i in range(w * h):
        var_i = max(corr_i[i] - mean_i[i] * mean_i[i], 0.0)
        cov = corr_ip[i] - mean_i[i] * mean_p[i]
        av = cov / (var_i + eps)
        a[i] = f32(av)
        b[i] = f32(mean_p[i] - av * mean_i[i])
    mean_a = box_blur(a, w, h, radius)
    mean_b = box_blur(b, w, h, radius)
    return [f32(mean_a[i] * guide[i] + mean_b[i]) for i in range(w * h)]


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
    #
    # "Exactly" is against the value a `Plane` can hold, not against the decimal
    # literal: 0.37 has no exact f32 representation, so a plane filled with it
    # already holds f32(0.37) before any blur runs. Comparing the output to 0.37
    # measures the storage format, not the filter.
    constant = f32(0.37)
    for radius in (1, 3, 8, 40):
        flat = [constant] * (w * h)
        out = box_blur(flat, w, h, radius)
        check(max(abs(v - constant) for v in out) == 0.0,
              f"constant plane did not blur to itself at radius {radius}")

    # A constant plane is a fixed point of the guided filter too. Not bit-exact here:
    # cov is 0/(0+eps) through a division, so the affine model reassembles the value
    # rather than passing it through.
    flat = [constant] * (w * h)
    gf = guided_filter(flat, flat, w, h, 4, 0.01)
    check(max(abs(v - constant) for v in gf) < 1e-7,
          "guided filter moved a constant plane")

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
    # Mirror of `ExportRecipe.sanitizedSubfolderComponents`, which now lives in
    # LumenCore precisely so it can be tested. Until it moved there this function
    # mirrored NOTHING: the real logic was inline in `AppStateActions.destination`,
    # in a target with no test target, and the export sheet's preview built its own
    # path by concatenation with no sanitizing at all — so the preview and the
    # written path disagreed for exactly the inputs this exists to catch.
    def sanitize_subfolder(sub):
        out = []
        for component in re.split(r"[/\\]", sub or ""):
            cleaned = component.replace(":", "-").strip()
            if not cleaned or cleaned in (".", ".."):
                continue
            out.append(cleaned)
        return out

    for hostile in ("../../..", "..", "./../etc", "a/../../b", "/etc/passwd",
                    "//..//..//", "  ..  /x", "..\\..\\Windows", "C:/Users",
                    ".", "", "/"):
        parts = sanitize_subfolder(hostile)
        check(all(p not in (".", "..") and "/" not in p and "\\" not in p
                  for p in parts),
              f"subfolder {hostile!r} survived sanitizing as {parts}")
    check(sanitize_subfolder("Web/2026") == ["Web", "2026"],
          "an ordinary subfolder was mangled")
    check(sanitize_subfolder("") == [] and sanitize_subfolder(None) == [],
          "an absent subfolder produced components")

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
MIN_TINT, MAX_TINT = -150.0, 150.0
TINT_UNIT_IN_V = 0.05 / 150.0

# CAT16 cone response matrix (CAM16, Li et al. 2017) — mirrors
# ChromaticAdaptation.cat16. Present here only because the magenta guard below is
# defined in terms of the cone responses adaptation divides by.
CAT16 = [[0.401288, 0.650173, -0.051461],
         [-0.250268, 1.204414, 0.045854],
         [-0.002079, 0.048952, 0.953127]]


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


# How much of a physical illuminant's cone response the magenta guard insists
# survives. Mirrors ColorTemperature.tintConeFloor.
#
# The defect it exists for: chromatic adaptation divides by the cone response of the
# illuminant it adapts FROM. Push tint far enough toward magenta and the S response
# falls through zero, and the adaptation comes out the far side with a negative blue
# gain — the picture inverts rather than going magenta. The S cone crossed zero at
# tint +45 at 2000 K and +80 at 2750 K, both inside the slider's own travel.
TINT_CONE_FLOOR = 0.15


def _unguarded_cone_response(kelvin, tint):
    """CAT16 cone response of the chromaticity a (K, tint) pair asks for, before the
    guard — the quantity the guard is defined in terms of, so it must not call
    wb_chromaticity."""
    base = locus(kelvin)
    if tint == 0:
        c = base
    else:
        u, v = xy_to_uv(*base)
        c = uv_to_xy(u, v + tint * TINT_UNIT_IN_V)
    x, y = c
    return mat_apply(CAT16, (x / y, 1.0, (1 - x - y) / y))


def _cone_floor_limit(kelvin):
    """Largest magenta tint at this temperature that still describes a colour a light
    source could be. Only magenta is bounded; green moves toward the interior of the
    plane where every cone response grows."""
    base = _unguarded_cone_response(kelvin, 0.0)
    if min(base) <= 0:
        return MAX_TINT

    def admissible(t):
        c = _unguarded_cone_response(kelvin, t)
        return all(c[i] >= TINT_CONE_FLOOR * base[i] for i in range(3))

    ceiling = 300.0
    if admissible(ceiling):
        return ceiling
    lo, hi = 0.0, ceiling
    for _ in range(40):
        mid = (lo + hi) / 2
        if admissible(mid):
            lo = mid
        else:
            hi = mid
    return lo


# The neutral the magenta bound is measured against: the daylight reference a file
# that records no camera neutral adapts from.
MAGENTA_REFERENCE_KELVIN = 5500.0

_REC2020_FROM_XYZ = mat_inverse(_REC2020_TO_XYZ)


def _von_kries(source_xy, destination_xy, cone):
    """XYZ(source white) -> XYZ(destination white), by scaling cone responses."""
    def xyz(ch):
        x, y = ch
        return (x / y, 1.0, (1 - x - y) / y)
    s = mat_apply(cone, xyz(source_xy))
    d = mat_apply(cone, xyz(destination_xy))
    gains = [[d[0] / s[0], 0.0, 0.0], [0.0, d[1] / s[1], 0.0], [0.0, 0.0, d[2] / s[2]]]
    return mat_mul(mat_mul(mat_inverse(cone), gains), cone)


def _rendered_magenta(kelvin, tint):
    """Where a mid-grey neutral lands on OKLab's green<->magenta axis once it has been
    adapted from the (K, tint) illuminant to the reference neutral — or None when it
    lands somewhere that is not a colour.

    The cone floor above bounds the ILLUMINANT. This bounds the PICTURE, which is not
    the same statement once the temperature move and the tint move compose: at as-shot
    5500 K, target 2800 K, tint +80 — inside the cone floor's own +69.80 — the render
    is (0.0967, -0.0872, 3.1857), a negative green channel, and its OKLab `a` is
    -0.089 against -0.038 untinted, so the magenta slider moved the picture toward
    green. OKLab rather than a linear-RGB opponent because the runaway is a
    CHROMATICITY move: the linear `(r+b)/2 - g` goes on rising straight through the
    reversal purely because blue is exploding.
    """
    base = locus(kelvin)
    if tint == 0:
        source = base
    else:
        u, v = xy_to_uv(*base)
        source = uv_to_xy(u, v + tint * TINT_UNIT_IN_V)
    adaptation = _von_kries(source, locus(MAGENTA_REFERENCE_KELVIN), CAT16)
    m = mat_mul(mat_mul(_REC2020_FROM_XYZ, adaptation), _REC2020_TO_XYZ)
    out = mat_apply(m, (0.18, 0.18, 0.18))
    if not all(math.isfinite(c) for c in out) or min(out) < 0:
        return None
    return oklab_from_rgb(out)[1]


def _magenta_monotone_limit(kelvin, ceiling):
    """Largest magenta tint at which the rendered neutral is still MOVING toward
    magenta, and still a colour.

    A quarter of a tint unit is the probe: the finite difference across it is ~1e-5 of
    `a` near the turn, ten orders of magnitude above double noise, and a twentieth of
    the smallest step the slider can be dragged. Both halves of the predicate are
    downward-closed on [0, ceiling] — the deflection is unimodal below the pole and the
    channels fail once and stay failed — so a bisection lands on the boundary.
    """
    if ceiling <= 0:
        return ceiling
    probe = 0.25

    def admissible(t):
        here = _rendered_magenta(kelvin, t)
        if here is None:
            return False
        ahead = _rendered_magenta(kelvin, t + probe)
        return ahead is not None and ahead >= here

    if admissible(ceiling):
        return ceiling
    lo, hi = 0.0, ceiling
    for _ in range(40):
        mid = (lo + hi) / 2
        if admissible(mid):
            lo = mid
        else:
            hi = mid
    return lo


def tint_limit(kelvin):
    """The largest magenta tint the render will honour: the smaller of the two bounds
    above. The illuminant must still be a colour a light source could be, AND the
    picture must still be going the way the slider says."""
    physical = _cone_floor_limit(kelvin)
    return min(physical, _magenta_monotone_limit(kelvin, physical))


def clamped_tint(kelvin, tint):
    """What a tint is actually worth once physics has had its say."""
    if tint <= 0:
        return tint
    return min(tint, tint_limit(kelvin))


def wb_chromaticity(kelvin, tint):
    base = locus(kelvin)
    guarded = clamped_tint(kelvin, tint)
    if guarded == 0:
        return base
    u, v = xy_to_uv(*base)
    return uv_to_xy(u, v + guarded * TINT_UNIT_IN_V)


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
    kelvin = min(max(kelvin, MIN_KELVIN), MAX_KELVIN)
    tint = (v - xy_to_uv(*locus(kelvin))[1]) / TINT_UNIT_IN_V
    return (kelvin, clamped_tint(kelvin, min(max(tint, -300.0), 300.0)))


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
            # Against the GUARDED tint: past the magenta bound the forward map is
            # deliberately not injective, and an inverse that recovered the number it
            # was handed rather than the one that was rendered would be lying.
            dk = abs(got_k - k) / k
            dt = abs(got_t - clamped_tint(k, tint))
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
HIGHLIGHT_SHELF_END = 1.0
SHADOW_SHELF_END = 0.5
END_SHELF_START = 0.20
END_SHELF_END = 0.80
BLACK_SHELF_START = 0.15
BLACK_SHELF_END = 0.62
WHITE_TONE_EV = 1.3
BLACK_TONE_EV = 2.2
DEFAULT_WHITE_ANCHOR_EV = 5.0
DEFAULT_BLACK_ANCHOR_EV = -9.0


ZONAL_KNEE = 0.8
MONOTONE_STEP_EV = 0.05
SEARCH_CEILING = 4.0


def soft_knee(u, knee=0.8):
    """Mirror of Num.softKnee: identity below `knee`, then a C1 power tail toward 1.

    A power tail, not an exponential one: the exponential reaches exactly 1.0 in
    double precision by u ~ 8, and the grading wheels' deflection reaches 16x the
    cap at Blending 0 — so it would be dead again at the far end."""
    if not math.isfinite(u) or u <= 0:
        return 0.0
    k = min(max(knee, 0.01), 0.99)
    if u <= k:
        return u
    return 1 - (1 - k) * (k / u) ** (k / (1 - k))


def soft_limit(amount, cap, knee=0.8):
    """Mirror of Num.softLimit."""
    if not math.isfinite(amount) or not math.isfinite(cap) or cap <= 0:
        return 0.0
    if cap >= 1:
        return amount
    eased = soft_knee(abs(amount) / cap, knee) * cap
    return -eased if amount < 0 else eased


def soft_limited(amount, cap):
    """Exact below ZONAL_KNEE x cap, then approaching cap without reaching it —
    strictly increasing in `amount`, which the hard clip was not."""
    if not math.isfinite(amount):
        return 0.0
    if cap >= 1:
        return amount
    if cap <= 0:
        return 0.0
    u = abs(amount) / cap
    if u <= ZONAL_KNEE:
        return amount
    return soft_limit(amount, cap, ZONAL_KNEE)


def eased_scale(limit):
    """A limit, eased so the top of every slider still moves.

    A hard limit is a dead control: the limit is inversely proportional to the request,
    so `scale * request` is constant the moment it binds. `limit * soft_knee(1 / limit)`
    is exact while the request is under `ZONAL_KNEE * limit` and approaches the limit
    without reaching it after."""
    if limit <= 0:
        return 0.0
    return min(1.0, limit * soft_knee(1.0 / limit, ZONAL_KNEE))


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
        self.whites = w
        self.blacks = b
        self.white_anchor_ev = DEFAULT_WHITE_ANCHOR_EV - WHITE_BLACK_RANGE_EV * w
        self.black_anchor_ev = DEFAULT_BLACK_ANCHOR_EV - WHITE_BLACK_RANGE_EV * b
        self._solve_zonal_scales()

    # -- the four zonal windows, as data -------------------------------------
    #
    # Written as a table rather than as four branches because every claim the solve
    # rests on is a property of the table, and a table can be inspected:
    #
    #   HALF   which side of mid-grey the shelf lives on. `smoothstep` saturates its
    #          argument, so `highlight_weight` and `white_weight` return 0.0 EXACTLY for
    #          every t <= 0 and `shadow_weight` / `black_weight` return 0.0 EXACTLY for
    #          every t >= 0. Not small — zero. So the two halves never share an interval
    #          and can be solved apart with nothing lost.
    #
    #   FALLS  whether this window pulls the mapping downhill, which is a fact about the
    #          SIGN of the slider and not about t. Each window is one monotone shelf
    #          times one scalar, so its slope has one sign over the whole range. The
    #          upper shelves ascend with t, so they fall when their slider is negative;
    #          the lower shelves ascend toward the black anchor, so they fall in t when
    #          their slider is POSITIVE. A window that cannot fall cannot invert
    #          anything, so it is never eased and its whole contribution is slack for
    #          the ones that can.
    def _windows(self):
        return (
            ("upper", self.highlights, HL_SH_RANGE_EV, self.highlight_weight,
             self.highlights < 0),
            ("upper", self.whites, WHITE_TONE_EV, self.white_weight, self.whites < 0),
            ("lower", self.shadows, HL_SH_RANGE_EV, self.shadow_weight,
             self.shadows > 0),
            ("lower", self.blacks, BLACK_TONE_EV, self.black_weight, self.blacks > 0),
        )

    def _applied(self):
        """Slider value -> amount actually applied, per window."""
        out = {}
        for half, amount, _, weight, falls in self._windows():
            scale = self.scales[half] if falls else 1.0
            out[weight.__name__] = amount * scale
        return out

    def _zonal_stops(self, t):
        s = 0.0
        for half, amount, ev, weight, falls in self._windows():
            if amount == 0:
                continue
            s += amount * (self.scales[half] if falls else 1.0) * ev * weight(t)
        return s

    def _force_scales(self, upper, lower):
        self.scales = {"upper": upper, "lower": lower}
        applied = self._applied()
        self.effective_highlights = applied["highlight_weight"]
        self.effective_shadows = applied["shadow_weight"]
        self.effective_whites = applied["white_weight"]
        self.effective_blacks = applied["black_weight"]
        eased = 1.0
        for half, amount, _, _, falls in self._windows():
            if amount != 0 and falls:
                eased = min(eased, self.scales[half])
        self.zonal_scale = eased

    def _solve_zonal_scales(self):
        """TWO scales, one per half of the range, closed form, then eased onto the limit.

        See ToneEngine.solveZonalLimits. One scale over the whole zonal SUM was the
        previous answer and it coupled windows whose weights are exactly zero where the
        other one acts: at contrast -100 with shadows/whites/blacks at -100, moving
        Highlights from -100 to +40 lightened -2 EV by 24.4 code values, where
        `highlight_weight` is 0. Solving each half against its own intervals removes
        that; not easing a window that cannot fall removes the second one, where pushing
        Highlights took away the help Whites was giving it and the applied amount peaked
        at -90.

        `mapped(t) = contrast_mapped(t) + rising(t) + scale * falling(t)` is linear in
        `scale`, so "mapped never falls" is one inequality per interval and the smallest
        ratio over the intervals where the falling part falls IS the limit. The knee then
        keeps the top of the slider alive."""
        self.zonal_limits = {
            "upper": self._half_limit("upper", 0.0, self.white_anchor_ev + 2),
            "lower": self._half_limit("lower", self.black_anchor_ev - 2, 0.0),
        }
        self._force_scales(*(eased_scale(self.zonal_limits[h])
                             for h in ("upper", "lower")))

    def _half_limit(self, half, t0, t1):
        """Largest scale on this half's falling windows that keeps `mapped` rising.

        Both sweeps end at mid-grey, where all four weights are exactly zero, so no
        interval ever straddles the halves and neither sweep can be charged for the
        other's inversion."""
        live = [w for w in self._windows() if w[0] == half and w[1] != 0]
        if not any(w[4] for w in live):
            return SEARCH_CEILING

        def parts(t):
            fall = sum(a * ev * wt(t) for _, a, ev, wt, f in live if f)
            rise = sum(a * ev * wt(t) for _, a, ev, wt, f in live if not f)
            return fall, rise

        t = t0
        p_fall, p_rise = parts(t)
        p_fixed = contrast_mapped(t, self.contrast, self.pivot,
                                  self.white_anchor_ev, self.black_anchor_ev)
        limit = SEARCH_CEILING
        while t < t1:
            t = min(t + MONOTONE_STEP_EV, t1)
            fall, rise = parts(t)
            fixed = contrast_mapped(t, self.contrast, self.pivot,
                                    self.white_anchor_ev, self.black_anchor_ev)
            d_fall = fall - p_fall
            if d_fall < 0:
                slack = (fixed - p_fixed) + (rise - p_rise)
                limit = min(limit, max(slack / -d_fall, 0.0))
            p_fall, p_rise, p_fixed = fall, rise, fixed
        return limit

    @property
    def exposure_gain(self):
        return 2.0 ** self.exposure

    def highlight_weight(self, t):
        # SHELVES, not bumps. See ToneEngine.highlightWeight: a bump returns to zero at
        # the anchor, so Highlights -100 did nothing to the brightest values, and its
        # steep slope forced the monotonicity cap that put 79% of the slider's travel in
        # its first half and made its strength vary 3.6x with Contrast.
        hi = self.white_anchor_ev
        if hi <= 0:
            return 0.0
        return smoothstep(0.0, hi * HIGHLIGHT_SHELF_END, t)

    def white_weight(self, t):
        hi = self.white_anchor_ev
        if hi <= 0:
            return 0.0
        return smoothstep(hi * END_SHELF_START, hi * END_SHELF_END, t)

    def black_weight(self, t):
        lo = self.black_anchor_ev
        if lo >= 0:
            return 0.0
        return smoothstep(-lo * BLACK_SHELF_START, -lo * BLACK_SHELF_END, -t)

    def shadow_weight(self, t):
        lo = self.black_anchor_ev
        if lo >= 0:
            return 0.0
        return smoothstep(0.0, -lo * SHADOW_SHELF_END, -t)

    def _unused_shadow_weight(self, t):
        lo = self.black_anchor_ev
        if lo >= 0 or t >= 0 or t <= lo:
            return 0.0
        return raised_cosine(math.sin(math.pi * (t / lo)))

    def stops(self, t):
        s = self._zonal_stops(t)   # already carries the solved amounts
        s += contrast_mapped(t, self.contrast, self.pivot,
                         self.white_anchor_ev, self.black_anchor_ev) - t
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

    # Each window vanishes at MID-GREY, so Highlights cannot touch the shadows and
    # Shadows cannot touch the highlights. It used to be asserted the other way round —
    # that each vanishes at its own ANCHOR — and that was the bump shape, which meant
    # Highlights -100 did nothing at all to the brightest values. A shelf reaches full
    # strength at its far end, which is what makes highlight recovery recover anything.
    e = ToneEngine(highlights=100, shadows=-100)
    check(abs(e.highlight_weight(0.0)) < 1e-12, "highlights leak into mid-grey")
    check(abs(e.shadow_weight(0.0)) < 1e-12, "shadows leak into mid-grey")
    check(e.highlight_weight(e.white_anchor_ev) > 0.99, "highlights do not reach the white point")
    check(e.shadow_weight(e.black_anchor_ev * SHADOW_SHELF_END) > 0.99,
          "shadows do not reach full strength where the toe still has room")
    # Whites and Blacks now carry real authority instead of only moving the endpoint.
    check(ToneEngine(whites=100).stops(3.5) > 0.4, "Whites has no reach into the highlights")
    check(ToneEngine(blacks=100).stops(-4.0) > 0.4, "Blacks has no reach into the shadows")
    check(abs(ToneEngine(whites=100, blacks=100).stops(0.0)) < 1e-12,
          "Whites/Blacks moved mid-grey")
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
    # Whites and Blacks are in this sweep because they carry tonal shelves now. While
    # they only moved the anchors they could not invert anything, so leaving them out
    # was correct; the moment they gained a shelf, the setting that inverts hardest
    # (Contrast -100 with Highlights -100, Shadows +100, Whites -100, Blacks +100) sat
    # entirely outside what was being checked.
    for contrast in (-100, -50, 0, 50, 100):
        for h in (-100, -40, 0, 40, 100):
            for s in (-100, -40, 0, 40, 100):
                for w in (-100, 0, 100):
                    for b in (-100, 0, 100):
                        e = ToneEngine(contrast=contrast, highlights=h, shadows=s,
                                       whites=w, blacks=b)
                        prev, t = -1e18, -13.0
                        while t <= 13:
                            # Output EV = input + the stops S7 adds there.
                            out = t + e.stops(t)
                            check(out >= prev - 1e-9,
                                  f"tone inverted at {t} EV (contrast {contrast}, "
                                  f"hi {h}, sh {s}, w {w}, b {b}): {out:.5f} after "
                                  f"{prev:.5f}")
                            prev = out
                            t += 0.05

    # --- the composed picture ---------------------------------------------
    # Shaper domain -> tone -> display transform. This is the closest thing to
    # "the picture is right" that runs without a GPU.
    for contrast in (-60, 0, 60):
        for h, s, w, b in ((0, 0, 0, 0), (-80, 80, 0, 0), (80, -80, 0, 0),
                           (0, 0, -100, 100), (0, 0, 100, -100),
                           (-100, 100, -100, 100), (-45, 35, 15, -15)):
            tone = ToneEngine(contrast=contrast, highlights=h, shadows=s,
                              whites=w, blacks=b)
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
                      f"hi {h}, sh {s}, w {w}, b {b})")
                prev = out
                ev += 0.05
            # Mid-grey survives the whole chain when nothing asks it to move.
            if contrast == 0 and h == 0 and s == 0 and w == 0 and b == 0:
                check(abs(dt.tone(MID_GREY * tone.gain(0.0)) - MID_GREY) < 2e-3,
                      "a default recipe did not land mid-grey on 0.18")

    # --- the sliders must keep doing more, and must not move each other ------
    #
    # Neither property was checked, and both were false. A single scale over the
    # whole zonal SUM coupled two disjoint windows, so Highlights at -100 cut a
    # Shadows setting of +60 down to an effective +33.8; and capping hard left
    # Highlights 57..100 all applying one identical value, dead over the top 43%
    # of the control. Every assertion above passes for a Highlights slider that
    # returns zero always, which is why neither showed up.
    #
    # This loop then swept ONE slider against Contrast, which is the one shape of the
    # parameter space where the applied amount cannot run backwards: with nothing else
    # in the zonal sum the limit is inversely proportional to the request, so
    # `scale * request` rises by construction. Put a window that HELPS in the sum and it
    # stops being true — at contrast -100 with whites +20 the applied Highlights amount
    # peaked at -90 and fell back over the last ten settings. So the other four sliders
    # now come along, through the region where they help and where they fight.
    binding = 0
    swept = 0
    for slider in ("highlights", "shadows"):
        for direction in (1, -1):
            for contrast in (0.0, -100.0, -60.0, 60.0):
                for whites in (-100.0, 0.0, 20.0, 100.0):
                    for partner in (-100.0, 0.0, 100.0):
                        previous = None
                        for setting in range(0, 101):
                            kw = {slider: direction * setting, "contrast": contrast,
                                  "whites": whites, "blacks": partner,
                                  "shadows" if slider == "highlights" else "highlights":
                                      partner}
                            e = ToneEngine(**kw)
                            swept += 1
                            if e.zonal_scale < 1 - 1e-12:
                                binding += 1
                            applied = abs(e.effective_highlights
                                          if slider == "highlights"
                                          else e.effective_shadows)
                            where = (f"contrast {contrast} whites {whites} "
                                     f"partner {partner}")
                            if previous is not None:
                                check(applied >= previous - 1e-12,
                                      f"{slider} at {direction * setting} ({where}) "
                                      f"applied LESS than at "
                                      f"{direction * (setting - 1)}: "
                                      f"{applied:.9f} vs {previous:.9f}")
                                check(setting < 2 or applied > previous + 1e-12,
                                      f"{slider} at {direction * setting} ({where}) "
                                      f"applied exactly what "
                                      f"{direction * (setting - 1)} did "
                                      f"({applied:.9f}) — the control is dead here")
                            previous = applied
    check(binding > swept // 20,
          f"only {binding} of {swept} settings bound the limiter — this sweep never "
          f"reaches the region where the applied amount can run backwards")

    # A window that cannot pull the mapping downhill is never eased. Whites above zero
    # RISES everywhere its shelf acts, so it can no more invert the response than a
    # window with no amount at all, and taking it down alongside Highlights was what
    # made the applied Highlights amount fall back at the top of the slider.
    helper_bound = 0
    for contrast in (-100.0, -60.0, 0.0):
        for whites in (20.0, 100.0):
            e = ToneEngine(contrast=contrast, highlights=-100, whites=whites)
            if e.zonal_scale < 1 - 1e-12:
                helper_bound += 1
            check(abs(e.effective_whites - whites / 100) < 1e-12,
                  f"Whites {whites} rises everywhere it acts but was eased to "
                  f"{e.effective_whites:.9f} at contrast {contrast}")
    check(helper_bound > 0,
          "Highlights -100 alongside Whites never bound the limiter, so nothing above "
          "was measured under easing")

    # Whites and Blacks are held to the same bar, now that the engine reports what they
    # apply. They carry a tonal shelf and are eased by the same solve, and nothing
    # anywhere asked whether the amount they end up applying rises with the slider. On
    # the shared scale it did not: sweeping Whites at contrast -100 with Highlights -100
    # and Shadows -100 handed back 0.00125 of applied amount between +97 and +98.
    for slider in ("whites", "blacks"):
        for direction in (1, -1):
            for contrast in (-100.0, -60.0, 0.0):
                for highlights in (-100.0, 0.0):
                    for shadows in (-100.0, 0.0, 100.0):
                        previous = None
                        for setting in range(0, 101):
                            kw = {slider: direction * setting, "contrast": contrast,
                                  "highlights": highlights, "shadows": shadows}
                            e = ToneEngine(**kw)
                            applied = abs(e.effective_whites if slider == "whites"
                                          else e.effective_blacks)
                            where = (f"contrast {contrast} highlights {highlights} "
                                     f"shadows {shadows}")
                            if previous is not None:
                                check(setting < 2 or applied > previous + 1e-15,
                                      f"{slider} at {direction * setting} ({where}) "
                                      f"applied no more than "
                                      f"{direction * (setting - 1)} did: "
                                      f"{applied:.12f} vs {previous:.12f}")
                            previous = applied

    # Moving one must not move the other. Their windows are disjoint — both weights
    # return 0.0 EXACTLY on the other's side of mid-grey — so there is no tone at which
    # one can reach the other, at any setting.
    #
    # This ran at contrast 0/60/100 and skipped every case where the scale was below 1,
    # which is the only place they were ever able to reach each other: with one scale
    # over the whole sum, Highlights -100 against contrast -100 cut Shadows -100 and
    # Blacks -100 down by 58%, worth 24.4 code values at -2 EV. The guard is inverted
    # now and the binding count is asserted.
    bound = 0
    for contrast in (0.0, -100.0, -60.0, 60.0):
        for whites in (-100.0, 0.0, 20.0, 100.0):
            for blacks in (-100.0, 0.0, 100.0):
                alone = ToneEngine(shadows=60, contrast=contrast, whites=whites,
                                   blacks=blacks)
                for h in (-100.0, -50.0, 50.0, 100.0):
                    e = ToneEngine(shadows=60, highlights=h, contrast=contrast,
                                   whites=whites, blacks=blacks)
                    if e.zonal_scale < 1 - 1e-12:
                        bound += 1
                    check(abs(e.effective_shadows - alone.effective_shadows) < 1e-12,
                          f"Highlights {h} moved Shadows +60 from "
                          f"{alone.effective_shadows:.9f} to "
                          f"{e.effective_shadows:.9f} (contrast {contrast}, whites "
                          f"{whites}, blacks {blacks})")
                    check(abs(e.effective_blacks - alone.effective_blacks) < 1e-12,
                          f"Highlights {h} moved Blacks {blacks} from "
                          f"{alone.effective_blacks:.9f} to "
                          f"{e.effective_blacks:.9f} (contrast {contrast}, whites "
                          f"{whites})")
    check(bound > 0, "the independence sweep never bound the limiter, so it is back to "
                     "proving nothing")

    # Contrast steepens the slope through the middle and eases it to 1 at the anchors
    # (A1-01), so unlike the old fixed 4→12 stop window it does not prop the slope up
    # across the whole scale. Out near an anchor the four windows can therefore ask for
    # more than the slope has, and the limiter binds — which is the limiter doing its job
    # rather than a regression: it solves for the LARGEST scale that keeps the composed
    # map monotone, and the "as little as it can" probe below shows the response stops
    # rising just above the limit it picked.
    #
    # What must hold is HOW MUCH it binds, and the honest way to state that is per case
    # rather than as one floor over a corner sweep, because the two cases are read very
    # differently by anyone holding a mouse.
    #
    # One tone control at its end, against contrast at its end: this is reachable — hard
    # contrast with the highlights pulled back is an ordinary look — and it must still
    # deliver most of its travel. The binding pairs are Highlights −100 against contrast
    # +100 (0.8460) and Shadows +100 against contrast −100 (0.6192). Both sit above 0.60
    # at ToneEngine.contrastShoulderStart = 0.2 and the second crosses it at about 0.225,
    # so this floor is what stops the hold being raised for more contrast authority.
    for contrast in (100.0, -100.0):
        for name in ("highlights", "shadows", "whites", "blacks"):
            for v in (-100.0, 100.0):
                e = ToneEngine(contrast=contrast, **{name: v})
                check(e.zonal_scale >= 0.60,
                      f"{name} {v} against contrast {contrast} scaled to "
                      f"{e.zonal_scale:.4f}: one tone control paired with contrast has "
                      f"to keep most of its travel")

    # All four windows pulling the same way at once with contrast pinned: not a setting
    # so much as a corner, so the floor is lower — but it is a floor, in the way of a
    # change that quietly halves these controls.
    worst_scale = 1.0
    for contrast in (80.0, 100.0):
        for h in (-100.0, 0.0, 100.0):
            for sh in (-100.0, 0.0, 100.0):
                for w in (-100.0, 100.0):
                    for b in (-100.0, 100.0):
                        e = ToneEngine(contrast=contrast, highlights=h, shadows=sh,
                                       whites=w, blacks=b)
                        worst_scale = min(worst_scale, e.zonal_scale)
                        check(e.zonal_scale >= 0.62,
                              f"contrast {contrast} h{h} s{sh} w{w} b{b} scaled to "
                              f"{e.zonal_scale:.4f}, past the floor the limiter is "
                              f"allowed to take from these four controls")
    check(worst_scale < 1 - 1e-12,
          "the positive-contrast sweep never bound the limiter, so this floor is "
          "proving nothing — if contrast stopped relaxing at the anchors, say so here")

    # Daily-use range: five sliders inside ±60 (±40 for the end points) is a strong edit,
    # and it is applied EXACTLY. Where it does bind, it is because contrast has been
    # flattened, and it costs at most a few percent.
    worst, worst_at = 1.0, None
    for c in range(-60, 61, 20):
        for h in range(-60, 61, 20):
            for sh in range(-60, 61, 20):
                for w in range(-40, 41, 20):
                    for b in range(-40, 41, 20):
                        e = ToneEngine(contrast=c, highlights=h, shadows=sh,
                                       whites=w, blacks=b)
                        if e.zonal_scale < worst:
                            worst, worst_at = e.zonal_scale, (c, h, sh, w, b)
                        check(e.zonal_scale >= 1 - 1e-12 or c < 0,
                              f"moderate edit c{c} h{h} s{sh} w{w} b{b} scaled to "
                              f"{e.zonal_scale:.4f} without negative contrast")
    check(worst > 0.93, f"a moderate edit lost {(1 - worst) * 100:.1f}% at {worst_at}")

    # The limiter takes as LITTLE as possible: at the solved limit the response is still
    # non-decreasing, and 2% above it is not. Without this the whole thing could be
    # passing every other check by being timid.
    for c, h, sh, w, b in ((-100, -100, 100, -100, 100), (-100, 0, 0, 0, 100),
                           (-60, -60, 60, 0, 40), (0, -100, 100, -100, 100)):
        e = ToneEngine(contrast=c, highlights=h, shadows=sh, whites=w, blacks=b)
        limits = dict(e.zonal_limits)
        check(min(limits.values()) < SEARCH_CEILING,
              f"c{c} h{h} s{sh} w{w} b{b} was expected to bind and did not")

        def mapped_falls(upper, lower, e=e):
            e._force_scales(upper, lower)
            t, worst_drop = e.black_anchor_ev - 2, 0.0
            previous = t + e.stops(t)
            while t < e.white_anchor_ev + 2:
                t += MONOTONE_STEP_EV
                m = t + e.stops(t)
                worst_drop = min(worst_drop, m - previous)
                previous = m
            return worst_drop

        # AT both limits the response still rises. Each half is then pushed 2% past its
        # own limit alone, with the other left at its limit, so a break belongs to the
        # half that moved rather than to whichever half was weaker.
        check(mapped_falls(limits["upper"], limits["lower"]) >= -1e-9,
              f"c{c} h{h} s{sh} w{w} b{b} already falls AT its limits {limits}")
        for half in ("upper", "lower"):
            if limits[half] >= SEARCH_CEILING:
                continue
            pushed = dict(limits)
            pushed[half] = limits[half] * 1.02
            check(mapped_falls(pushed["upper"], pushed["lower"]) < -1e-9,
                  f"c{c} h{h} s{sh} w{w} b{b} is still monotone 2% above the {half} "
                  f"limit {limits[half]:.6f} — the limiter is being timid")
            check(eased_scale(limits[half]) < limits[half],
                  f"c{c} h{h} s{sh} w{w} b{b} applies the {half} limit exactly, so the "
                  f"top of the slider is dead")
        e._solve_zonal_scales()

    print("  zonal fixed points, anchor geometry, and a monotone composed picture")
    print("  every setting of Highlights and Shadows applies more than the last, "
          "and neither moves the other")


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
# Stops of scene luminance realised per stop of requested perceptual brightness.
# The wheels' Luminance scales UCS brightness J; J tracks OKLab L, and L is the cube
# root of linear luminance, so the realised tone response is `1 + 3·scale·slope` —
# GradeEngine.realisedStopsPerJStop, mirrored (docs/31 round two §1).
REALISED_STOPS_PER_J_STOP = 3.0
NOMINAL_HALF_WIDTH_EV = 1.5
MINIMUM_HALF_WIDTH_EV = 0.05
BLENDING_KNEE = 0.8
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
        # Eased onto the ceiling, not clipped at it. See ZoneWindows: a hard
        # min(requested, max_half) bound at Blending 79.3 on the default pivots, so
        # every setting from 80 to 100 rendered byte-identical.
        eased = (max_half * soft_knee(requested / max_half, BLENDING_KNEE)
                 if max_half > 0 else 0.0)
        half = min(max(eased, floor_half), max_half)
        self.half_width = half
        self.shadow_half_width = half
        self.shadow_pivot = ps
        self.highlight_pivot = ph
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
    margin, scale = 0.05, math.inf

    def stops(p):
        s, m, h = windows.weights(p)
        return s * shadows + m * mid + h * high

    x = 0.0
    while x < 1:
        a = min(x + step, 1.0)
        # REALISED, not requested: the J-stops the wheels ask for come out of the
        # picture three times over (L cubes back to light), so the monotonicity bound
        # applies to three times the measured slope.
        slope = ((stops(a) - stops(x)) / ((a - x) * span)
                 * REALISED_STOPS_PER_J_STOP)
        if slope < 0:
            scale = min(scale, max((1 - margin) / -slope, 0.0))
        x = a
    if not math.isfinite(scale) or scale <= 0:
        return 1.0
    # Ease onto the cap rather than clip at it — see GradeEngine.solveLumScale. The
    # cap is inversely proportional to the deflection, so clipping left the Luminance
    # ring applying one identical value over 80% of its travel at Blending 0.
    normalized = 1 / scale
    return min(soft_knee(normalized) / normalized, 1.0)


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

    # Blending is alive over its WHOLE travel. A hard `min(requested, max_half)` bound
    # at 79.3 on the default pivots, so every setting from 80 to 100 produced identical
    # zone windows — measured on a colour chart, a byte-identical render. Every
    # assertion above passed through that: a partition of unity is still a partition of
    # unity when the control has stopped responding.
    for balance in (-100.0, 0.0, 100.0):
        previous = None
        for step in range(0, 101):
            half = ZoneWindows(blending=float(step), balance=balance).shadow_half_width
            if previous is not None and step >= 2:
                check(half > previous + 1e-12,
                      f"Blending {step} (balance {balance}) produced the same window as "
                      f"{step - 1}: half-width {half:.12f} — the control is dead here")
            previous = half
    # And it still cannot reach the ceiling, because past it the mid zone goes negative.
    top = ZoneWindows(blending=100.0)
    ceiling = (top.highlight_pivot - top.shadow_pivot) / 2
    check(top.shadow_half_width < ceiling,
          f"Blending 100 reached the half-width ceiling exactly ({ceiling:.6f})")

    # The failure this found: at Blending 0 the crossfade collapses to the 0.05 EV
    # floor, and a shadow wheel at +1 against a highlight wheel at −1 asks brightness
    # to fall a full stop across a tenth of a stop of input.
    hard = ZoneWindows(blending=0.0)
    unscaled = solve_lum_scale(hard, LUM_RANGE_STOPS, 0.0, -LUM_RANGE_STOPS)
    check(unscaled < 0.2,
          f"the hard-crossover case did not need scaling ({unscaled:.3f}) — "
          "the test no longer covers what it was written for")

    # With the scale applied, the REALISED response is monotone at every setting. The
    # response the photograph shows is `t + 3·(zone stops)·scale` — the wheels' stops
    # are gains on UCS brightness J and L cubes back to light — and checking the
    # requested stops instead is exactly the blind spot that let 345 of 810 sampled
    # combinations invert behind a green check (docs/31 round two §1). Midtones against
    # Highlights is in the set because it is the audit's own reproduction.
    for blending in (0.0, 10.0, 50.0, 100.0):
        for sh_lum, mid_lum, hi_lum in ((1.0, 0.0, -1.0), (-1.0, 0.0, 1.0),
                                        (1.0, -1.0, 1.0), (0.6, 0.0, -0.6),
                                        (0.0, 1.0, -1.0)):
            w = ZoneWindows(blending=blending)
            sh, md, hi = (LUM_RANGE_STOPS * sh_lum, LUM_RANGE_STOPS * mid_lum,
                          LUM_RANGE_STOPS * hi_lum)
            scale = solve_lum_scale(w, sh, md, hi)
            prev, x = -1e18, 0.0
            while x <= 1.0:
                t = -9.0 + x * w.span_ev
                s_w, m_w, h_w = w.weights(x)
                out = t + REALISED_STOPS_PER_J_STOP * (
                    s_w * sh + m_w * md + h_w * hi) * scale
                check(out >= prev - 1e-9,
                      f"grade inverted at x={x:.3f} (blend {blending}, "
                      f"wheels {sh_lum}/{mid_lum}/{hi_lum}, scale {scale:.3f})")
                prev = out
                x += 0.002

    # And the default settings keep effectively all of their strength, or the fix has
    # quietly weakened the control everywhere instead of only where it had to. Not
    # `> 0.999` any more: under the realised (3×) slope a FULL-deflection wheel at the
    # default Blending genuinely sits just past the knee — the eased limit takes about
    # a quarter of one percent, which no display can show — while gentle settings stay
    # exactly at 1.
    default = ZoneWindows()
    for sh_lum, hi_lum in ((0.5, -0.5), (1.0, 0.0), (0.0, -1.0)):
        scale = solve_lum_scale(default, LUM_RANGE_STOPS * sh_lum, 0.0,
                                LUM_RANGE_STOPS * hi_lum)
        check(scale > 0.99,
              f"default blending scaled wheels {sh_lum}/{hi_lum} to {scale:.3f}")
    check(solve_lum_scale(default, LUM_RANGE_STOPS * 0.3, 0.0, 0.0) == 1.0,
          "a gentle lone wheel at default blending must be exactly unlimited")

    # --- the Luminance ring must keep doing more, at every Blending ----------
    #
    # It did not. Capping hard at the monotonicity limit left the ring applying
    # ONE identical value over most of its travel: at Blending 0, lum +-0.20,
    # +-0.50 and +-1.00 all produced 0.060681385, equal to 1e-12. Eighty percent
    # of the control, dead. The check above tests `scale > 0.999` at DEFAULT
    # blending only — the one setting where nothing was wrong.
    # The tolerance is 1e-12, down from 1e-9: under the realised (3×) slope the
    # blending-0 cap sits three times lower, so a full-deflection ring runs ~48× past
    # it and the knee's power tail gains ~1e-9 per step out there — still strictly
    # increasing, exactly representable in a double, and all the geometry can afford
    # when the whole crossfade is a tenth of a stop wide.
    for blending in (0.0, 5.0, 10.0, 20.0, 50.0, 100.0):
        w = ZoneWindows(blending=blending)
        previous = None
        for step_index in range(1, 41):
            lum = step_index / 40
            scale = solve_lum_scale(w, LUM_RANGE_STOPS * lum, 0.0,
                                    -LUM_RANGE_STOPS * lum)
            applied = LUM_RANGE_STOPS * lum * scale
            if previous is not None:
                check(applied > previous + 1e-12,
                      f"the Luminance ring at {lum:.3f} (blending {blending}) applied "
                      f"{applied:.9f}, no more than {previous:.9f} at "
                      f"{(step_index - 1) / 40:.3f} — the control is dead here")
            previous = applied

    print("  partition of unity, and no grade setting can invert the tone response")
    print("  and the Luminance ring keeps doing more at every Blending")


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

    # Push/pull is swept above, but every assertion there — anchored, monotone,
    # spans its range, crossover bounded — holds for a chain that DISCARDS it. So
    # the sweep proved the chain survives push, never that push does anything.
    for name, stock in sorted(FILM_STOCKS.items()):
        previous = None
        for push in (-1.0, -0.5, 0.0, 0.5, 1.0, 1.5, 2.0):
            chain = film_chain(stock, push=push)
            # Measured well below mid-grey, where a steeper gamma shows most.
            value = film_render([0.18 * 2 ** -3] * 3, chain, 1.0)[1]
            if previous is not None:
                check(abs(value - previous) > 1e-6,
                      f"{name} rendered identically at push {push} and "
                      f"{push - 0.5} ({value:.9f}) — push/pull is being ignored")
                check(value < previous + 1e-12,
                      f"{name} got BRIGHTER in the shadows at push {push}, which is "
                      "backwards: pushing steepens the curve")
            previous = value
        # Film exposure likewise: it is swept for safety and never for effect.
        base = film_render([0.18] * 3, film_chain(stock), 1.0)[1]
        for exposure in (-2.0, -1.0, 1.0, 3.0):
            chain = film_chain(stock)
            shifted = film_render([0.18 * 2 ** exposure] * 3, chain, 1.0)[1]
            check(abs(shifted - base) > 1e-6,
                  f"{name} rendered identically at film exposure {exposure}")

    print("  6 stocks × 5 push settings × 4 film exposures: "
          "grey anchored, no inversion, and push/pull actually moves the picture")


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

    # The anchor geometry is varied here as well as contrast and skew, because the
    # anchors are exactly what Whites and Blacks manipulate (`ToneEngine.applyAnchors`)
    # and they were cross-checked at a single point: one black target, one white
    # anchor, one black anchor, in every row.
    display = []
    for kw in ({},
               {"contrast": 2.2, "skew": -0.3},
               {"white_target": 400.0},
               {"black_target": 0.8},
               {"white_anchor_ev": 3.5, "black_anchor_ev": -11.0},
               {"white_anchor_ev": 6.5, "black_anchor_ev": -6.0, "contrast": 2.0}):
        t = DisplayTransform(**kw)
        for ev in (-9.0, -6.0, -3.0, 0.0, 2.0, 5.0):
            display.append({
                "contrast": kw.get("contrast", 1.5),
                "skew": kw.get("skew", 0.0),
                "whiteTarget": kw.get("white_target", 100.0),
                "blackTarget": kw.get("black_target", 0.0152),
                "whiteAnchorEV": kw.get("white_anchor_ev", 5.0),
                "blackAnchorEV": kw.get("black_anchor_ev", -9.0),
                "ev": ev,
                "out": t.tone(MID_GREY * 2 ** ev),
            })

    # The parametric curve had no cross-language fixture at all: `curves.json` covers
    # MonotoneCubic, which is the POINT curve, and nothing covered the four-region bake.
    # Both sides could have drifted apart silently, and when the whole limiter was
    # replaced neither fixture noticed.
    centres = region_centres()
    parametric = []
    for shadows, darks, lights, highlights in (
            (100, 0, 0, 0), (0, -100, 0, 0), (0, 0, 55, 0), (0, 0, 0, -40),
            (100, -100, 0, 0), (-60, 40, -40, 60), (100, 100, 100, 100),
            (-100, 100, -100, 100)):
        amounts = [shadows / 100, darks / 100, lights / 100, highlights / 100]
        amplitude, _, scale = parametric_plan(amounts, centres)
        samples = bake_parametric(amounts, centres)
        parametric.append({
            "shadows": float(shadows), "darks": float(darks),
            "lights": float(lights), "highlights": float(highlights),
            "amplitude": amplitude, "scale": scale,
            # Sampled AT stored indices, so `x` lands exactly on a LUT sample and the
            # Swift side reads the stored value instead of interpolating between two.
            # Sampling at i/16 instead made every row differ in the fourth decimal —
            # a real mismatch, and entirely the fixture's fault.
            "curve": [{"x": round(i * 1023 / 16) / 1023,
                       "y": samples[round(i * 1023 / 16)]} for i in range(17)],
        })

    tone = []
    # The last four bind the zonal limiter — one slider, or four at once, against a
    # flattened contrast curve. Without them this fixture came out byte-identical when
    # the whole solve was replaced, which means it was covering the arithmetic and not
    # the decision.
    for h, sh, c, w, b in ((0.0, 0.0, 0.0, 0.0, 0.0), (-80.0, 80.0, 0.0, 0.0, 0.0),
                           (-100.0, 100.0, 60.0, 0.0, 0.0), (50.0, -50.0, -40.0, 0.0, 0.0),
                           (0.0, 0.0, 0.0, 100.0, -100.0), (-40.0, 30.0, 20.0, 15.0, -25.0),
                           (0.0, 0.0, -100.0, 0.0, 100.0),
                           (-100.0, 100.0, -100.0, -100.0, 100.0)):
        e = ToneEngine(highlights=h, shadows=sh, contrast=c, whites=w, blacks=b)
        entry = {"highlights": h, "shadows": sh, "contrast": c, "whites": w, "blacks": b,
                 "zonalScale": e.zonal_scale,
                 "effectiveHighlights": e.effective_highlights,
                 "effectiveShadows": e.effective_shadows, "stops": []}
        for t in (-8.0, -4.0, -1.0, 0.0, 1.0, 3.0, 5.0):
            entry["stops"].append({"t": t, "value": e.stops(t)})
        tone.append(entry)

    chroma = []
    for c in ((0.9, 0.2, 0.05), (0.45, 0.34, 0.22), (0.31, 0.30, 0.29)):
        for gain in (0.0, 0.5, 1.0, 1.6, 3.0):
            chroma.append({"rgb": list(c), "gain": gain,
                           "out": list(shaped_chroma_scale(c, gain))})

    # The same colours through the PUBLIC path — Saturation, including the brightness
    # rolloff — rather than through the bare chroma scale.
    #
    # Without this the Swift replay had to skip every row with gain > 1, because
    # `ColorEngine.apply` attenuates a push by the rolloff and `shaped_chroma_scale`
    # does not. Six of fifteen rows were skipped in silence, and of the nine left, three
    # were an identity compared against an identity — so `sat_compress`'s knee and
    # ceiling, the only interesting mathematics in the function, were cross-checked
    # nowhere. Density is 0 so the subtractive blend stays out of it; that path has its
    # own checks.
    chroma_push = []
    for c in ((0.9, 0.2, 0.05), (0.2, 0.5, 0.9), (0.45, 0.40, 0.30),
              (0.30, 0.31, 0.29), (2.4, 1.2, 0.6)):
        for saturation in (-100.0, -60.0, -20.0, 20.0, 60.0, 100.0):
            chroma_push.append({
                "rgb": list(c),
                "saturation": saturation,
                "out": list(vibrance_saturation(c, 0.0, saturation, density=0.0)),
            })

    # The radial mask on a 3:2 frame at several rotations — the case the long-edge-units
    # fix was made for. The Swift test that covers this uses a 32×32 frame at rotation 0,
    # where the bug is arithmetically absent: a 45° ellipse rendered at 33.7° with the
    # wrong eccentricity only on a non-square frame. So the fix has been verified here
    # and nowhere on the Swift side.
    radial = []
    for rotation in (0.0, 30.0, 45.0, 90.0, 135.0):
        for feather in (30.0, 60.0, 100.0):
            samples = []
            for y in range(1, 32, 3):
                for x in range(1, 48, 3):
                    samples.append({"x": x, "y": y,
                                    "alpha": radial_alpha(48, 32, 0.5, 0.5, 0.3, 0.18,
                                                          rotation, feather, x, y)})
            # A grid of nothing but 0 and 1 would compare two step functions and never
            # reach the falloff, which is where the rotation actually shows.
            partial = sum(1 for s in samples if 1e-6 < s["alpha"] < 1 - 1e-6)
            # A narrow feather genuinely lands fewer pixels in the band, so the floor
            # is set for the narrowest case here (feather 30 gives 12–18).
            check(partial >= 10,
                  f"radial grid at rotation {rotation}, feather {feather} has only "
                  f"{partial} partially-covered samples — it does not test the falloff")
            radial.append({"width": 48, "height": 32,
                           "center": [0.5, 0.5], "radii": [0.3, 0.18],
                           "rotation": rotation, "feather": feather,
                           "samples": samples})

    # And the rotations must actually differ from one another, or the fixture pins a
    # function that ignores its rotation argument — which is exactly the bug class the
    # long-edge-units fix belongs to.
    for feather in (30.0, 60.0, 100.0):
        rows = [r for r in radial if r["feather"] == feather]
        base = [s["alpha"] for s in rows[0]["samples"]]
        for other in rows[1:]:
            moved = sum(1 for a, s in zip(base, other["samples"])
                        if abs(a - s["alpha"]) > 1e-6)
            check(moved >= 10,
                  f"rotating to {other['rotation']}° at feather {feather} moved only "
                  f"{moved} samples — the ellipse is not rotating")

    white_balance = []
    # 5000 and 6500 are here because they are the two the Swift suite anchors against
    # published chromaticities (D50 and D65). Tying exactly those points to the mirror
    # means the two sides agree about the same numbers the external check names.
    for k in (2500.0, 4000.0, 5000.0, 5500.0, 6500.0, 8000.0, 20000.0):
        for tint in (-80.0, 0.0, 80.0):
            x, y = wb_chromaticity(k, tint)
            got_k, got_t = temperature_and_tint((x, y))
            white_balance.append({"kelvin": k, "tint": tint, "x": x, "y": y,
                                  "recoveredKelvin": got_k, "recoveredTint": got_t})

    perceptual = []
    for c in ((0.18, 0.18, 0.18), (0.9, 0.2, 0.05), (2.4, 1.2, 0.6)):
        L, C, hh = oklch_from_rgb(c)
        # Hue is atan2 of the two chroma axes, so at C ~ 0 it is the angle between two
        # quantities that are both rounding error — for the neutral grey here it landed
        # on 296.57 on one machine and 334.01 on another, from a chroma of 1e-16. The
        # Swift guards its hue assertion with the same C > 1e-9 test and never reads
        # this field for such a row; recording a number there stored noise as if it
        # were a golden value.
        write_hue = hh if C > 1e-9 else None
        perceptual.append({"rgb": list(c), "L": L, "C": C, "h": write_hue})

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

    # Grade: the zone geometry and the second monotonicity solve. `solve_lum_scale` is
    # the sibling of ToneEngine's zonal solve and was wrong twice before it was right,
    # so it is worth as much of a tie to the Swift as the tone one already has.
    grade = []
    for blending in (0.0, 10.0, 50.0, 100.0):
        for balance in (-100.0, 0.0, 60.0):
            for shadows_lum, mid_lum, high_lum in ((0.0, 0.0, 0.0),
                                                   (1.0, 0.0, -1.0),
                                                   (-1.0, 0.0, 1.0),
                                                   (0.6, -0.3, 0.6)):
                w = ZoneWindows(blending=blending, balance=balance)
                scale = solve_lum_scale(w, LUM_RANGE_STOPS * shadows_lum,
                                        LUM_RANGE_STOPS * mid_lum,
                                        LUM_RANGE_STOPS * high_lum)
                weights = []
                for x in (0.0, 0.15, 0.3, 0.33, 0.45, 0.5, 0.62, 0.67, 0.8, 1.0):
                    s, m, h = w.weights(x)
                    weights.append({"x": x, "shadows": s, "mid": m, "high": h})
                grade.append({
                    "blending": blending,
                    "balance": balance,
                    "shadowsLum": shadows_lum,
                    "midLum": mid_lum,
                    "highLum": high_lum,
                    "halfWidth": w.half_width,
                    "shadowPivot": sum(w.shadow_crossfade) / 2,
                    "highlightPivot": sum(w.highlight_crossfade) / 2,
                    "lumScale": scale,
                    "weights": weights,
                })

    payload = {
        "_comment": "Generated by scripts/gen-fixtures.py. The Swift replays these; "
                    "a mismatch means the implementation and its executable mirror "
                    "have drifted.",
        "film": film,
        "grade": grade,
        "shaper": shaper,
        "saturationRolloff": rolloff,
        "contrast": contrast,
        "displayTransform": display,
        "tone": tone,
        "parametric": parametric,
        "shapedChromaScale": chroma,
        "shapedChromaScalePush": chroma_push,
        "whiteBalance": white_balance,
        "perceptual": perceptual,
        "radialAlpha": radial,
    }
    write_fixture("enginemath.json", payload, indent=2, sort_keys=True,
                  trailing_newline=True)
    total = (len(shaper) + len(rolloff) + len(contrast) + len(display)
             + sum(len(t["stops"]) for t in tone) + len(chroma)
             + len(white_balance) + len(perceptual)
             + sum(len(f["samples"]) for f in film)
             + sum(len(g["weights"]) + 1 for g in grade) + len(chroma_push)
             + sum(len(r["samples"]) for r in radial))
    print(f"  {total} sampled values across ten engine surfaces")


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
    gen_parametric_checks()
    gen_film_checks()
    gen_enginemath_fixture()
    if FAILURES:
        print(f"\n{len(FAILURES)} verification failure(s)")
        sys.exit(1)
    if CHECK_ONLY:
        print("\nAll fixtures match the committed state; all Linux-side "
              "verifications passed.")
    else:
        print("\nAll fixtures generated; all Linux-side verifications passed.")


if __name__ == "__main__":
    main()
