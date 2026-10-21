#!/usr/bin/env python3
"""decode_raw.py -- a Linux stand-in for AppleRawSource's FLAT decode.

Decodes a camera RAW with LibRaw (rawpy) into the exact input convention that
LumenCore's `ReferenceRenderer.render(_:plan:)` and the GPU RenderGraph receive from
`AppleRawSource.decode` on macOS, and writes it as an `.lfi` file plus a sidecar
`.json` carrying what `RenderPlan(recipe:asShotKelvin:asShotTint:captureISO:)` needs.

INPUT CONVENTION (what the pixels in the .lfi mean)
====================================================
Read from Sources/LumenPipeline/AppleRawSource.swift, Sources/LumenCore/Engine/
WhiteBalanceEngine.swift, RenderPlan.swift, ReferenceRenderer.swift and docs/14 §1.3,
§2.1.4, §4:

1. Working space: LINEAR Rec.2020 primaries, D65 white (Lumen's `RGBColorSpace.rec2020`;
   docs/14 §1.3 "the working format between stages is always linear Rec.2020").
   Unbounded float; values may exceed 1.0 or (rarely, out-of-gamut camera colours) go
   slightly negative. No transfer function, no tone curve, no gamut mapping.

2. White balance: PRE-APPLIED AT THE AS-SHOT NEUTRAL ("camera reference WB").
   AppleRawSource sets `neutralTemperature/neutralTint` to the file's own as-shot pair,
   so a surface the camera judged neutral arrives as RGB(k,k,k) -- WhiteBalanceEngine's
   header: "The decode always runs at camera-reference WB, so a neutral surface arrives
   as RGB(1,1,1)". Lumen's CAT16 at S6 then adapts from the as-shot neutral to the
   recipe's Kelvin/Tint; when the recipe's `raw.temp`/`raw.tint` are nil ("as shot")
   that matrix is exactly identity. Here: LibRaw's camera multipliers (`use_camera_wb`)
   are applied to the mosaic, then a camera->Rec.2020 matrix whose rows are normalised
   so camera (1,1,1) maps to Rec.2020 (1,1,1) -- i.e. the as-shot neutral lands on D65
   white, exactly as on the Apple path.

3. As-shot neutral metadata: the sidecar's `as_shot.kelvin` / `as_shot.tint` are in the
   DNG SDK convention (Robertson isotemperature table, kTintScale -3000), because that
   is what `CIRAWFilter.neutralTemperature/neutralTint` report and what AppleRawSource
   hands RenderPlan (see `DNGTemperature.swift`). Pass them as `asShotKelvin` /
   `asShotTint`. They are derived here from the camera multipliers through LibRaw's
   single (D65) Adobe ColorMatrix, so they are an APPROXIMATION of Apple's number
   (Apple interpolates dual-illuminant matrices); expect agreement to a few hundred K.
   With temp/tint nil in the recipe the value only matters for UI display, not pixels.

4. Exposure normalisation: black subtracted (LibRaw per-channel black, nothing extra --
   AppleRawSource sets `shadowBias = 0`), scaled so the sensor white level of the
   least-amplified WB channel (green) is 1.0; no auto-brightness, no `adjust_maximum`
   (`adjust_maximum_thr=0`, so the scale does not depend on image content). Then a
   baseline-exposure gain 2^EV: `--baseline-ev auto` (default) uses the DNG
   BaselineExposure tag for .dng files and 0 EV otherwise; a number overrides it.
   KNOWN GAP: Apple's flat decode applies its own per-camera baseline exposure for
   proprietary raws. RawCorpusTests R-7c records "Apple/LibRaw green differs 1.14-1.35x
   with baseline exposure", i.e. Apple's decode is +0.19..+0.43 EV brighter than this
   one. Do not rely on absolute level to better than ~0.5 EV; mid-grey checks should
   normalise or use Lumen's own auto-exposure.

5. Geometry: the file's default crop is applied (LibRaw `raw_inset_crops[0]`, which is
   the DNG DefaultCrop / Sony crop / Panasonic 0x2f-0x32 tags -- the same frame Apple
   delivers, e.g. A7 IV 7008x4672, GX85 4:3 4592x3448), then the EXIF orientation is
   applied so the image is UPRIGHT (CIRAWFilter delivers upright pixels). Rows are
   top-to-bottom (ImageBuffer convention: origin top-left).

6. Optional `--long-edge N` (default 2400; 0 = native): exact AREA downsample (box
   integration with fractional pixel coverage, separable), done in linear light.

7. Determinism: LibRaw runs single-threaded (OMP_NUM_THREADS=1, set below) because its
   threaded X-Trans path is not reproducible. Same file + same script = same bytes.

OUTPUT FORMAT (.lfi)
====================
  bytes 0..3   magic b"LFI1"
  bytes 4..15  uint32 LE width, height, channels (=3)
  then         width*height*3 float32 LE, RGB interleaved, row-major, top row first.
No alpha (ImageBuffer is RGBA; a loader sets A=1).

HOW THIS DIFFERS FROM APPLE'S DECODE (honestly)
================================================
* Demosaic: LibRaw AHD for Bayer, LibRaw's 3-pass Markesteijn-style X-Trans
  interpolation for Fujifilm; Apple's demosaic is proprietary and generally cleaner
  (less zipper/maze, better fine detail). Fine-texture/moire measurements will differ.
* Highlights: LibRaw "clip" -- each channel is clipped at its white level after WB, so
  blown regions go to flat neutral white (1,1,1)*2^EV with no reconstruction. Apple
  runs highlight recovery (`isHighlightRecoveryEnabled`), which rebuilds some colour and
  detail above the first clipped channel. Highlight-rolloff tests will see harder
  clipping here. The sidecar's `clipped_fraction` reports how much is affected.
* Lens corrections: NONE. Apple applies the file's embedded profile (distortion,
  vignetting, lateral CA) when `geometry.lens.profile` is on -- significant for
  Panasonic/Olympus/Fujifilm/Sony bodies whose raws REQUIRE it (barrel distortion,
  dark corners). Geometry and corner brightness will differ.
* Capture sharpening: NONE. Apple applies its at-demosaic sharpener scaled by
  `detail.capture.strengthFraction` (default on). Expect this decode to look softer.
* Noise reduction: NONE here. On the Apple path NR is also zero for Off/Classic
  (Lumen's own Tier-1 denoise runs in the graph), so this matches for those modes;
  only the `.ai` stand-in would differ.
* Colour: single D65 Adobe ColorMatrix (LibRaw's table) with a von-Kries WB in camera
  space; Apple uses its own per-camera profiles, dual-illuminant interpolation and
  DNG-style forward matrices. R-7c measured Apple vs LibRaw R/G, B/G means agreeing
  within ln 0.028 on four makes -- close, not identical.
* Exposure: see 4 (Apple +0.19..+0.43 EV on proprietary raws).
* Black level: LibRaw per-channel black; Apple with shadowBias=0 subtracts its own
  reading of the black. Should agree; deep shadows (< -8 EV) may differ slightly.

Usage:  decode_raw.py INPUT OUTPUT.lfi [--long-edge 2400] [--baseline-ev auto|EV]
        [--sidecar PATH] [--demosaic AHD|AAHD|DHT|LINEAR|VNG|PPG|DCB]
"""

import argparse
import hashlib
import json
import os
import struct
import sys

# DETERMINISM. LibRaw 0.22's OpenMP X-Trans interpolation races: two decodes of the
# same RAF differed in 0.16 % of pixels (up to 0.043) with threads, and were
# byte-identical single-threaded. Bayer AHD was deterministic either way. A proof
# corpus whose inputs change run to run is not a corpus, so force one thread before
# libgomp initialises (i.e. before rawpy is imported).
os.environ["OMP_NUM_THREADS"] = "1"

import numpy as np  # noqa: E402
import rawpy  # noqa: E402

DECODER_VERSION = "lumen-proof-decode/1"

# ---------------------------------------------------------------------------
# Colour constants

def _rgb_to_xyz(prim, white):
    """RGB->XYZ for primaries [(x,y)*3] and white (x,y), the standard derivation."""
    m = np.array([[x / y, 1.0, (1 - x - y) / y] for x, y in prim]).T
    wx, wy = white
    w = np.array([wx / wy, 1.0, (1 - wx - wy) / wy])
    s = np.linalg.solve(m, w)
    return m * s

D65 = (0.3127, 0.3290)
REC2020_TO_XYZ = _rgb_to_xyz([(0.708, 0.292), (0.170, 0.797), (0.131, 0.046)], D65)
XYZ_TO_REC2020 = np.linalg.inv(REC2020_TO_XYZ)
SRGB_TO_XYZ = _rgb_to_xyz([(0.64, 0.33), (0.30, 0.60), (0.15, 0.06)], D65)

# ---------------------------------------------------------------------------
# DNG temperature/tint: a port of LumenCore/Color/DNGTemperature.swift
# (dng_temperature.cpp Set_xy_coord), so the sidecar speaks Apple's convention.

_TEMP_TABLE = [
    (0, 0.18006, 0.26352, -0.24341), (10, 0.18066, 0.26589, -0.25479),
    (20, 0.18133, 0.26846, -0.26876), (30, 0.18208, 0.27119, -0.28539),
    (40, 0.18293, 0.27407, -0.30470), (50, 0.18388, 0.27709, -0.32675),
    (60, 0.18494, 0.28021, -0.35156), (70, 0.18611, 0.28342, -0.37915),
    (80, 0.18740, 0.28668, -0.40955), (90, 0.18880, 0.28997, -0.44278),
    (100, 0.19032, 0.29326, -0.47888), (125, 0.19462, 0.30141, -0.58204),
    (150, 0.19962, 0.30921, -0.70471), (175, 0.20525, 0.31647, -0.84901),
    (200, 0.21142, 0.32312, -1.0182), (225, 0.21807, 0.32909, -1.2168),
    (250, 0.22511, 0.33439, -1.4512), (275, 0.23247, 0.33904, -1.7298),
    (300, 0.24010, 0.34308, -2.0637), (325, 0.24702, 0.34655, -2.4681),
    (350, 0.25591, 0.34951, -2.9641), (375, 0.26400, 0.35200, -3.5814),
    (400, 0.27218, 0.35407, -4.3633), (425, 0.28039, 0.35577, -5.3762),
    (450, 0.28863, 0.35714, -6.7262), (475, 0.29685, 0.35823, -8.5955),
    (500, 0.30505, 0.35907, -11.324), (525, 0.31320, 0.35968, -15.628),
    (550, 0.32129, 0.36011, -23.325), (575, 0.32931, 0.36038, -40.770),
    (600, 0.33724, 0.36051, -116.45),
]
_TINT_SCALE = -3000.0


def dng_temperature_tint(x, y):
    """CIE xy -> (kelvin, tint) in the DNG SDK convention (Set_xy_coord)."""
    den = 1.5 - x + 6.0 * y
    u = 2.0 * x / den
    v = 3.0 * y / den
    last_dt = last_du = last_dv = 0.0
    final = len(_TEMP_TABLE) - 1
    for index in range(1, final + 1):
        r, ru, rv, rt = _TEMP_TABLE[index]
        ln = (1.0 + rt * rt) ** 0.5
        du, dv = 1.0 / ln, rt / ln
        uu, vv = u - ru, v - rv
        dt = -uu * dv + vv * du
        if dt <= 0.0 or index == final:
            if dt > 0.0:
                dt = 0.0
            dt = -dt
            f = 0.0 if index == 1 else dt / (last_dt + dt)
            pr, pu, pv, _ = _TEMP_TABLE[index - 1]
            kelvin = 1.0e6 / (pr * f + r * (1.0 - f))
            uu = u - (pu * f + ru * (1.0 - f))
            vv = v - (pv * f + rv * (1.0 - f))
            iu = du * (1.0 - f) + last_du * f
            iv = dv * (1.0 - f) + last_dv * f
            il = (iu * iu + iv * iv) ** 0.5
            return kelvin, (uu * iu / il + vv * iv / il) * _TINT_SCALE
        last_dt, last_du, last_dv = dt, du, dv
    return float("nan"), float("nan")

# ---------------------------------------------------------------------------
# LFI I/O (shared with gen_synthetic.py)

def write_lfi(path, rgb):
    rgb = np.ascontiguousarray(rgb, dtype="<f4")
    h, w, c = rgb.shape
    assert c == 3
    tmp = path + ".part"
    with open(tmp, "wb") as f:
        f.write(b"LFI1")
        f.write(struct.pack("<III", w, h, c))
        f.write(rgb.tobytes())
    os.replace(tmp, path)


def read_lfi(path):
    with open(path, "rb") as f:
        magic = f.read(4)
        if magic != b"LFI1":
            raise ValueError("%s: not an LFI1 file" % path)
        w, h, c = struct.unpack("<III", f.read(12))
        data = np.frombuffer(f.read(w * h * c * 4), dtype="<f4")
    return data.reshape(h, w, c)

# ---------------------------------------------------------------------------
# Area resampling

def _area_weights(n_in, n_out):
    """(n_out, n_in) matrix: each output pixel's exact coverage of input pixels."""
    scale = n_in / n_out
    w = np.zeros((n_out, n_in), dtype=np.float64)
    for o in range(n_out):
        a, b = o * scale, (o + 1) * scale
        i0, i1 = int(np.floor(a)), min(int(np.ceil(b)), n_in)
        for i in range(i0, i1):
            w[o, i] = min(b, i + 1) - max(a, i)
        w[o] /= w[o].sum()
    return w


def area_downsample(img, long_edge):
    h, w, _ = img.shape
    if long_edge <= 0 or max(h, w) <= long_edge:
        return img
    s = long_edge / max(h, w)
    nh, nw = max(1, round(h * s)), max(1, round(w * s))
    wy = _area_weights(h, nh).astype(np.float32)
    wx = _area_weights(w, nw).astype(np.float32)
    tmp = (wy @ img.reshape(h, w * 3)).reshape(nh, w, 3)
    out = np.einsum("ow,hwc->hoc", wx, tmp, optimize=True)
    return out.astype(np.float32)

# ---------------------------------------------------------------------------
# Orientation (LibRaw/dcraw `flip`: 0 none, 3 180, 5 90 CCW, 6 90 CW)

def apply_flip(img, flip):
    if flip == 0:
        return img
    if flip == 3:
        return img[::-1, ::-1]
    if flip == 5:
        return np.rot90(img, 1)       # 90 CCW
    if flip == 6:
        return np.rot90(img, -1)      # 90 CW
    # Rare mirrored codes, dcraw bit semantics: 4 = transpose, 2 = vflip, 1 = hflip.
    if flip & 4:
        img = img.transpose(1, 0, 2)
    if flip & 2:
        img = img[::-1]
    if flip & 1:
        img = img[:, ::-1]
    return img

# ---------------------------------------------------------------------------
# DNG BaselineExposure (tag 50730) from IFD0, without extra dependencies.

def dng_baseline_exposure(path):
    try:
        with open(path, "rb") as f:
            head = f.read(8)
            if head[:2] == b"II":
                e = "<"
            elif head[:2] == b"MM":
                e = ">"
            else:
                return None
            off = struct.unpack(e + "I", head[4:8])[0]
            f.seek(off)
            n = struct.unpack(e + "H", f.read(2))[0]
            for _ in range(n):
                tag, typ, cnt, val = struct.unpack(e + "HHI4s", f.read(12))
                if tag == 50730 and typ == 10:
                    voff = struct.unpack(e + "I", val)[0]
                    pos = f.tell()
                    f.seek(voff)
                    num, den = struct.unpack(e + "ii", f.read(8))
                    f.seek(pos)
                    return num / den if den else None
    except (OSError, struct.error):
        return None
    return None

# ---------------------------------------------------------------------------

DEMOSAIC = {
    "AHD": rawpy.DemosaicAlgorithm.AHD, "AAHD": rawpy.DemosaicAlgorithm.AAHD,
    "DHT": rawpy.DemosaicAlgorithm.DHT, "LINEAR": rawpy.DemosaicAlgorithm.LINEAR,
    "VNG": rawpy.DemosaicAlgorithm.VNG, "PPG": rawpy.DemosaicAlgorithm.PPG,
    "DCB": rawpy.DemosaicAlgorithm.DCB,
}


def camera_to_rec2020(raw):
    """Camera (WB'd) RGB -> linear Rec.2020, normalised so (1,1,1) -> (1,1,1).

    dcraw/LibRaw's own construction (cam_xyz_coeff) with the output space swapped
    from sRGB to Rec.2020: cam_rec = ColorMatrix(XYZ->cam) . Rec2020->XYZ, rows
    normalised to sum 1 (so the WB'd neutral maps to the space's white), inverted.
    """
    cam_xyz = np.array(raw.rgb_xyz_matrix, dtype=np.float64)[:3]
    if np.abs(cam_xyz).sum() > 0:
        cam_rec = cam_xyz @ REC2020_TO_XYZ
        cam_rec /= cam_rec.sum(axis=1, keepdims=True)
        return np.linalg.inv(cam_rec), "adobe-colormatrix", cam_xyz
    # No ColorMatrix: fall back to LibRaw's rgb_cam (cam->sRGB), then sRGB->Rec2020.
    rgb_cam = np.array(raw.color_matrix, dtype=np.float64)[:, :3]
    if np.abs(rgb_cam).sum() == 0:
        rgb_cam = np.eye(3)
        source = "identity (no camera matrix known!)"
    else:
        source = "libraw-rgb_cam"
    return XYZ_TO_REC2020 @ SRGB_TO_XYZ @ rgb_cam, source, None


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def decode(path, long_edge=2400, baseline_ev="auto", demosaic="AHD"):
    raw = rawpy.imread(path)
    sizes = raw.sizes
    flip = sizes.flip
    if raw.num_colors != 3:
        raise SystemExit("%s: %d-colour sensor (%s) is not supported"
                         % (path, raw.num_colors, raw.color_desc))
    wb = [float(v) for v in raw.camera_whitebalance]
    if not any(wb[:3]):
        raise SystemExit("%s: file carries no as-shot white balance" % path)

    rgb16 = raw.postprocess(
        demosaic_algorithm=DEMOSAIC[demosaic],
        use_camera_wb=True, use_auto_wb=False,
        output_color=rawpy.ColorSpace.raw,
        gamma=(1, 1), no_auto_bright=True, output_bps=16,
        highlight_mode=rawpy.HighlightMode.Clip,
        adjust_maximum_thr=0.0, user_flip=0,
        fbdd_noise_reduction=rawpy.FBDDNoiseReductionMode.Off,
        median_filter_passes=0,
    )
    cam = rgb16.astype(np.float32) / 65535.0
    clipped = float(np.mean(np.any(rgb16 >= 65535, axis=2)))
    del rgb16

    # Default crop, in pre-flip visible-area coordinates.
    crop = None
    cl, ct, cw, ch = (sizes.crop_left_margin, sizes.crop_top_margin,
                      sizes.crop_width, sizes.crop_height)
    h0, w0 = cam.shape[:2]
    if cw > 0 and ch > 0 and cl + cw <= w0 and ct + ch <= h0 and (cw, ch) != (w0, h0):
        cam = cam[ct:ct + ch, cl:cl + cw]
        crop = dict(left=int(cl), top=int(ct), width=int(cw), height=int(ch))

    m, matrix_source, cam_xyz = camera_to_rec2020(raw)
    rec = np.einsum("ij,hwj->hwi", m.astype(np.float32), cam, optimize=True)
    del cam

    is_dng = path.lower().endswith(".dng")
    file_be = dng_baseline_exposure(path) if is_dng else None
    if baseline_ev == "auto":
        ev = file_be if file_be is not None else 0.0
        ev_source = "DNG BaselineExposure" if file_be is not None else "none (0 EV)"
    else:
        ev = float(baseline_ev)
        ev_source = "command line"
    if ev:
        rec *= np.float32(2.0 ** ev)

    rec = apply_flip(rec, flip)
    full_h, full_w = rec.shape[:2]
    rec = area_downsample(np.ascontiguousarray(rec), long_edge)

    # As-shot neutral -> xy -> DNG temperature/tint.
    neutral_cam = np.array([1.0 / wb[0], 1.0 / wb[1], 1.0 / wb[2]])
    neutral_cam /= neutral_cam[1]
    as_shot = None
    if cam_xyz is not None:
        xyz = np.linalg.solve(cam_xyz, neutral_cam)
        x, y = xyz[0] / xyz.sum(), xyz[1] / xyz.sum()
        k, t = dng_temperature_tint(x, y)
        as_shot = dict(kelvin=round(k, 3), tint=round(t, 4), x=round(x, 6), y=round(y, 6),
                       convention="DNG SDK (Robertson, kTintScale -3000) = "
                                  "CIRAWFilter.neutralTemperature/neutralTint",
                       derived_from="camera WB multipliers via LibRaw's single D65 "
                                    "Adobe ColorMatrix (approximation of Apple's value)")

    o = raw.other
    meta = dict(
        format="LFI1", decoder=DECODER_VERSION,
        libraw=".".join(map(str, rawpy.libraw_version)), rawpy=rawpy.__version__,
        source=os.path.basename(path), source_sha256=sha256_file(path),
        width=int(rec.shape[1]), height=int(rec.shape[0]), channels=3,
        decoded_full_size=dict(width=int(full_w), height=int(full_h)),
        long_edge=int(long_edge),
        working_space="linear Rec.2020 (D65), scene-referred, unbounded float32",
        white_balance="pre-applied at the as-shot neutral (camera reference): "
                      "neutral -> RGB(1,1,1)*2^baseline_ev; recipe temp/tint nil = identity",
        as_shot=as_shot,
        camera_wb_multipliers=wb, daylight_wb_multipliers=[float(v) for v in raw.daylight_whitebalance],
        as_shot_neutral_camera=[round(float(v), 6) for v in neutral_cam],
        black_level_per_channel=[int(v) for v in raw.black_level_per_channel],
        white_level=int(raw.white_level),
        exposure=dict(normalisation="black subtracted; green sensor white = 1.0 before "
                                    "baseline; adjust_maximum off; no auto-bright",
                      baseline_ev=ev, baseline_source=ev_source,
                      clip_level=2.0 ** ev,
                      apple_gap_note="Apple's flat decode is ~+0.19..+0.43 EV brighter on "
                                     "proprietary raws (RawCorpusTests R-7c)"),
        clipped_fraction=round(clipped, 6),
        camera_to_rec2020=[[round(float(v), 6) for v in row] for row in m],
        matrix_source=matrix_source,
        demosaic=demosaic if raw.raw_pattern is not None and raw.raw_pattern.shape == (2, 2)
        else "LibRaw X-Trans (3-pass)",
        highlights="clip (no reconstruction)", lens_corrections="none",
        capture_sharpening="none", noise_reduction="none",
        orientation_flip=int(flip), oriented="upright", default_crop=crop,
        camera=dict(make=raw_make(raw, path), iso=float(o.iso_speed),
                    shutter_s=float(o.shutter_speed), aperture=float(o.aperture),
                    focal_length_mm=float(o.focal_length),
                    timestamp=o.timestamp.isoformat() if o.timestamp else None,
                    lens=raw.lens.model or None),
        recipe_hint=dict(asShotKelvin=as_shot["kelvin"] if as_shot else 5500.0,
                         asShotTint=as_shot["tint"] if as_shot else 0.0,
                         captureISO=float(o.iso_speed)),
    )
    raw.close()
    return rec, meta


def raw_make(raw, path):
    # rawpy exposes no make/model string; the manifest carries the camera name.
    return None


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("input")
    ap.add_argument("output", help="output .lfi path")
    ap.add_argument("--long-edge", type=int, default=2400,
                    help="area-downsample so the long edge is N px (0 = native)")
    ap.add_argument("--baseline-ev", default="auto",
                    help="'auto' (DNG BaselineExposure, else 0) or an EV number")
    ap.add_argument("--sidecar", default=None, help="sidecar JSON (default OUTPUT.json)")
    ap.add_argument("--demosaic", default="AHD", choices=sorted(DEMOSAIC))
    a = ap.parse_args(argv)
    rec, meta = decode(a.input, a.long_edge, a.baseline_ev, a.demosaic)
    write_lfi(a.output, rec)
    side = a.sidecar or os.path.splitext(a.output)[0] + ".json"
    with open(side, "w") as f:
        json.dump(meta, f, indent=2)
        f.write("\n")
    print("%s -> %s %dx%d  as-shot %s  clipped %.4f%%"
          % (a.input, a.output, meta["width"], meta["height"],
             "%.0fK/%+.1f" % (meta["as_shot"]["kelvin"], meta["as_shot"]["tint"])
             if meta["as_shot"] else "n/a", 100 * meta["clipped_fraction"]))


if __name__ == "__main__":
    sys.exit(main())
