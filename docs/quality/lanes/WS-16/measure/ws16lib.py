"""WS-16 measurement helpers. Self-contained: reads only corpus/, the release lumen-render,
and the ws16probe stage probe in ./probe.

  render()   full pipeline (ReferenceRenderer) -> 8-bit sRGB PNG -> uint8 array (cached; the
             cache key includes the lumen-render binary's size and mtime, so a rebuild
             re-renders)
  stage()    S9 alone (ColorEngine Double and ExactColorStage Float twin) via ws16probe
  check()    prints one acceptance line:  "<ID> PASS|FAIL  <value>  (threshold ...)"

Environment: LUMEN_RENDER (default <repo>/.build/release/lumen-render),
WS16_PROBE (default ./probe/.build/release/ws16probe), WS16_OUT (default /tmp/ws16-measure).
"""
import hashlib
import json
import os
import subprocess
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", "..", "..", ".."))
SYN = os.path.join(REPO, "corpus", "synthetic")
LFI = os.path.join(REPO, "corpus", "lfi")
BIN = os.environ.get("LUMEN_RENDER", os.path.join(REPO, ".build", "release", "lumen-render"))
PROBE = os.environ.get("WS16_PROBE", os.path.join(HERE, "probe", ".build", "release", "ws16probe"))
OUT = os.environ.get("WS16_OUT", "/tmp/ws16-measure")
os.makedirs(os.path.join(OUT, "renders"), exist_ok=True)

RESULTS = []

# Real photos used by the output lines (A7 IV = 6929, GX85 = 2545).
PHOTOS = ["6929_sony-ilce-7m4", "2545_panasonic-dmc-gx85", "2242_panasonic-dc-gx850",
          "4694_canon-eos-r5", "1346_canon-eos-5d", "8559_nikon-z-fc"]


def check(sid, ok, value, threshold, note=""):
    line = f"{sid:8s} {'PASS' if ok else 'FAIL'}  {value}   (threshold: {threshold})" + (f"  {note}" if note else "")
    print(line, flush=True)
    RESULTS.append((sid, ok))
    return ok


# ---------------------------------------------------------------- full pipeline

def _bin_tag():
    st = os.stat(BIN)
    return f"{st.st_size}-{int(st.st_mtime)}"


def photo_path(pid):
    if os.path.exists(pid):
        return pid
    for d in (SYN, LFI):
        p = os.path.join(d, pid + ".lfi")
        if os.path.exists(p):
            return p
    import glob
    hits = glob.glob(os.path.join(LFI, pid + "*.lfi"))
    if hits:
        return hits[0]
    raise FileNotFoundError(pid)


def hint(path):
    j = json.load(open(path[:-4] + ".json"))
    h = j.get("recipe_hint", {})
    return h.get("asShotKelvin", 6503.7072), h.get("asShotTint", 9.77), h.get("captureISO")


def render_args(inp, sets=(), long_edge=None):
    inp = photo_path(inp)
    k, t, iso = hint(inp)
    args = [BIN, "render", "--input", inp, "--as-shot-kelvin", str(k), "--as-shot-tint", str(t), "--no-dither"]
    if iso:
        args += ["--iso", str(int(iso))]
    if long_edge:
        args += ["--long-edge", str(long_edge)]
    for s in sets:
        args += ["--set", s]
    return args


def render(inp, sets=(), long_edge=None):
    """sets: iterable of 'key=value'. Returns uint8 HxWx3."""
    args = render_args(inp, sets, long_edge)
    tag = hashlib.md5((" ".join(args) + _bin_tag()).encode()).hexdigest()[:12]
    out = os.path.join(OUT, "renders", f"{os.path.basename(args[3])[:-4]}_{tag}.png")
    if not os.path.exists(out):
        r = subprocess.run(args + ["--out", out], capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(r.stderr + r.stdout)
    return np.asarray(Image.open(out).convert("RGB"))


def default_of(key):
    """Default value of a recipe key as `lumen-render keys` reports it."""
    r = subprocess.run([BIN, "keys"], capture_output=True, text=True, check=True)
    for line in r.stdout.splitlines():
        p = line.split()
        if p and p[0] == key:
            return float(p[1])
    raise KeyError(key)


def srgb_to_linear(u8):
    v = u8.astype(np.float64) / 255.0
    return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)


_M1 = np.array([[0.4122214708, 0.5363325363, 0.0514459929],
                [0.2119034982, 0.6806995451, 0.1073969566],
                [0.0883024619, 0.2817188376, 0.6299787005]])
_M2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468],
                [1.9779984951, -2.4285922050, 0.4505937099],
                [0.0259040371, 0.7827717662, -0.8086757660]])


def lin_to_oklab(lin):
    return np.cbrt(lin @ _M1.T) @ _M2.T


def oklab(u8):
    """Standard (Ottosson) OKLab of 8-bit sRGB."""
    return lin_to_oklab(srgb_to_linear(u8))


def lch(lab):
    return lab[..., 0], np.hypot(lab[..., 1], lab[..., 2]), np.degrees(np.arctan2(lab[..., 2], lab[..., 1])) % 360


def hd(a, b):
    return (b - a + 180) % 360 - 180


def patches(frame):
    return json.load(open(os.path.join(SYN, frame + ".json")))["truth"]["patches"]


def patch_lab(img, rect, margin=20):
    x, y, w, h = rect
    sub = img[y + margin:y + h - margin, x + margin:x + w - margin].reshape(-1, 3)
    return lin_to_oklab(srgb_to_linear(sub).mean(axis=0)[None, :])[0], sub.mean(axis=0)


def clipped_fraction(u8):
    f = u8.reshape(-1, 3)
    return ((f == 0) | (f == 255)).any(1).mean()


# ---------------------------------------------------------------- stage probe

LUMA2020 = np.array([0.26270021201126703, 0.6779980715188708, 0.05930171646986196])  # Rec.2020 Y (D65)


def stage(pts, vib=0, sat=0, dens=50, prot=70, bw=None):
    """pts: list of (L, C, h) in the working OKLCh, or ('rgb', r, g, b).
    Returns dict: rgb (input), eng/twin (L,C,h of output), engRGB/twRGB (output RGB), identity (stderr)."""
    if not os.path.exists(PROBE):
        sys.exit(f"stage probe missing: build it with (cd {os.path.join(HERE, 'probe')} && swift build -c release)")
    args = [PROBE, "stage", str(vib), str(sat), str(dens), str(prot)]
    if bw is not None:
        args.append(",".join(str(b) for b in bw))
    lines = "\n".join(("rgb %.17g %.17g %.17g" % tuple(float(x) for x in p[1:4])) if p[0] == "rgb"
                      else ("%.17g %.17g %.17g" % tuple(float(x) for x in p[0:3])) for p in pts) + "\n"
    r = subprocess.run(args, input=lines, capture_output=True, text=True, check=True)
    a = np.array([[float(x) for x in l.split()] for l in r.stdout.strip().split("\n")])
    return dict(rgb=a[:, 0:3], eng=a[:, 3:6], twin=a[:, 6:9], engRGB=a[:, 9:12], twRGB=a[:, 12:15],
                identity=r.stderr.strip())


def grid(Ls=(0.3, 0.45, 0.6, 0.75, 0.9),
         Cs=(0.01, 0.02, 0.03, 0.04, 0.06, 0.08, 0.1, 0.13, 0.16, 0.2, 0.25, 0.3), dh=5):
    return [(L, C, float(h)) for L in Ls for C in Cs for h in np.arange(0, 360, dh)]


def in_gamut(res, tol=0.0):
    return (res["rgb"] >= -tol).all(1)


def boundary_chroma(Lh, cmax=0.6, n=600):
    """For each (L, h): the largest working-OKLab chroma still inside Rec.2020 (no negative
    channel), to cmax/n resolution. Returns an array aligned with Lh."""
    Cs = np.linspace(0, cmax, n + 1)[1:]
    pts = [(L, c, h) for (L, h) in Lh for c in Cs]
    r = stage(pts, sat=0)
    ok = (r["rgb"] >= 0).all(1).reshape(len(Lh), n)
    first_bad = np.where(ok.all(1), n, np.argmax(~ok, axis=1))
    return np.where(first_bad > 0, Cs[np.maximum(first_bad - 1, 0)], 0.0)


def skin_patches(min_chroma=0.015):
    """(name, rec2020_linear) of every skin patch: ColorChecker light/dark skin and MST 1-10,
    keeping those whose working chroma is >= min_chroma (MST 10 is C 0.011)."""
    cc = patches("colorchecker")
    sk = patches("skin_tones")
    P = [(p["name"], p["rec2020_linear"]) for p in cc if p["name"] in ("dark skin", "light skin")]
    P += [(p["name"], p["rec2020_linear"]) for p in sk if p["name"].startswith("MST")]
    b = stage([("rgb",) + tuple(v) for _, v in P])
    return [(n, v, tuple(b["twin"][i])) for i, (n, v) in enumerate(P) if b["twin"][i, 1] >= min_chroma]


def cc_patch(name):
    for p in patches("colorchecker"):
        if p["name"] == name:
            return p["rec2020_linear"]
    raise KeyError(name)


def summary():
    n = len(RESULTS)
    f = sum(1 for _, ok in RESULTS if not ok)
    print(f"-- {n - f}/{n} PASS" + (f"; FAIL: {' '.join(s for s, ok in RESULTS if not ok)}" if f else ""))
