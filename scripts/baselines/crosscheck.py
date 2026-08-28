#!/usr/bin/env python3
"""Cross-implementation baselines for the tone pipeline, on Linux.

The owner's question, verbatim: "If I push the exposure up to 1.80 ... It seems
fake ... can you prove that it is correct?" A Lumen-only test can prove internal
consistency; it cannot prove the field would render the same picture. This script
asks the two open-source implementations that run headless — RawTherapee 5.10 and
darktable 4.6 — the same two questions AccuracyProbeTests asks Lumen, so the
answers are comparable numbers rather than opinions:

  exposure   Is Exposure a pure scene-linear gain of exactly 2^EV?
             (RawTherapee: neutral profile + [Exposure] Compensation.)

  bleach     Does an overexposed colour bleach toward display white, and on what
             slope? Residual chroma (max-min)/max of a sunset-orange patch,
             RGB(1.0, 0.72, 0.42), pushed +0..+5 EV.
             (RawTherapee: neutral & Standard Film Curve profiles; darktable:
             sigmoid module in per-channel and RGB-ratio modes, driven through a
             hand-packed XMP because dt params are binary structs.)

Method notes, honestly stated:
  · RT runs use 16-bit sRGB-encoded TIFF in and out, so the only transfer curve
    in the chain is the IEC 61966-2-1 one both ends share; values are decoded
    back to linear before measuring. Patches for the exposure question stay
    unclipped (max 0.36 x 2 = 0.72).
  · darktable runs feed scene-linear float PFM (values above 1.0 carry the
    push), so no exposure module is needed and the sigmoid sees the same scene
    values Lumen's probe uses.
  · Chroma is measured in each tool's own output RGB. Primaries differ between
    working spaces, so the comparison is of SHAPE (does chroma collapse to ~0,
    how fast), not of third-decimal equality. The one thing shape settles
    conclusively: a transform where chroma NEVER collapses is outside the field.
  · The darktable sigmoid param struct is packed by hand
    (<ffffif: contrast, skew, white target, black target, method, hue). If a
    darktable upgrade reshapes the struct the module silently drops out and the
    output degenerates to a hard clip - the run detects that by asserting the
    +0 EV patch is NOT at clip (R < 0.999).

Measured 2026-08-27, this script's own output (recorded with interpretation in
docs/26-tone-baselines.md):
  RT exposure +1 EV -> linear ratio 2.0000 +/- 2e-4 on every patch and channel.
  Bleach, residual chroma at +0/+2/+3/+5 EV:
    Lumen before path-to-white   0.612  0.597  0.587  0.587   <- the outlier
    Lumen after  path-to-white   0.553  0.214  0.036  0.000
    dt sigmoid per-channel       0.398  0.095  0.037  0.005
    dt sigmoid RGB-ratio         0.551  0.158  0.061  0.008
    RT Standard Film Curve       0.222  0.000  0.000  0.000
    RT neutral (hard clip)       0.580  0.000  0.000  0.000
  Every implementation in the field collapses to ~0 by +5 EV; the pre-fix
  transform is the only one that never does. The post-fix curve tracks dt's
  RGB-ratio mode - the gentlest member of the consensus - within a few
  hundredths at every step.

Usage:  python3 scripts/baselines/crosscheck.py   (runs everything, prints the
        tables; exits non-zero if a tool is missing or a sanity check fails)
        Subsequent additions (2026-08-28): shrecovery (RT Shadows&Highlights at
        full deflection, per-patch EV shift — the field's answer to Lumen's
        hard-partitioned ±2.0 EV zones) and dehaze (RT Haze Removal and
        darktable hazeremoval on a synthetic veiled scene with known airlight —
        far-ground contrast recovery and veil drop). The Lumen columns for both
        print from AccuracyProbeTests (TONEBASE) and EngineIntegrationTests
        (HAZEBASE) on the Linux lane, so every number in docs/26 §4–5 is
        re-measurable on both sides.
Deps:   apt install rawtherapee darktable; pip install numpy tifffile
"""
import os
import shutil
import struct
import subprocess
import sys
import tempfile

import numpy as np
import tifffile

SIZE = 64
GREYS = [0.02, 0.05, 0.09, 0.18, 0.36]
ORANGE = np.array([1.0, 0.72, 0.42])


def srgb_encode(x):
    x = np.clip(x, 0.0, 1.0)
    return np.where(x <= 0.0031308, 12.92 * x, 1.055 * np.power(x, 1 / 2.4) - 0.055)


def srgb_decode(y):
    y = np.clip(y, 0.0, 1.0)
    return np.where(y <= 0.04045, y / 12.92, np.power((y + 0.055) / 1.055, 2.4))


def write_srgb16(path, patches):
    row = np.zeros((SIZE, SIZE * len(patches), 3))
    for i, rgb in enumerate(patches):
        row[:, i * SIZE:(i + 1) * SIZE, :] = rgb
    tifffile.imwrite(path, np.round(srgb_encode(row) * 65535.0).astype(np.uint16))


def write_pfm(path, patches):
    img = np.zeros((SIZE, SIZE * len(patches), 3), dtype=np.float32)
    for i, rgb in enumerate(patches):
        img[:, i * SIZE:(i + 1) * SIZE, :] = rgb
    with open(path, 'wb') as f:
        f.write(b'PF\n%d %d\n-1.0\n' % (img.shape[1], img.shape[0]))
        f.write(img[::-1].tobytes())  # PFM rows are bottom-up


def read_patches_linear(path, count):
    img = tifffile.imread(path).astype(np.float64) / 65535.0
    out = []
    for i in range(count):
        cx = i * SIZE + SIZE // 2
        block = img[SIZE // 2 - 8:SIZE // 2 + 8, cx - 8:cx + 8, :3]
        out.append(srgb_decode(block.mean(axis=(0, 1))))
    return out


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"FAILED ({r.returncode}): {' '.join(cmd)}\n{r.stderr[-2000:]}")


def chroma(rgb):
    return (rgb.max() - rgb.min()) / max(rgb.max(), 1e-9)


# ---------------------------------------------------------------- RawTherapee

def rt_exposure_gain(work):
    inp = os.path.join(work, 'grey.tif')
    write_srgb16(inp, [(g, g, g) for g in GREYS] + [ORANGE * 0.5])
    pp3 = os.path.join(work, 'exp1.pp3')
    open(pp3, 'w').write('[Exposure]\nAuto=false\nCompensation=1.0\n')
    out = os.path.join(work, 'rt_exp1.tif')
    run(['rawtherapee-cli', '-t', '-b16', '-Y', '-o', out, '-p', pp3, '-c', inp])
    ins = [np.array([g, g, g]) for g in GREYS] + [ORANGE * 0.5]
    print('RawTherapee, Exposure Compensation +1.0 (expect linear ratio 2.0):')
    worst = 0.0
    for i, o in zip(ins, read_patches_linear(out, len(ins))):
        r = o / i
        worst = max(worst, float(np.abs(r - 2.0).max()))
        print(f'  in {i[0]:.3f}/{i[1]:.3f}/{i[2]:.3f} -> ratio '
              f'{r[0]:.4f}/{r[1]:.4f}/{r[2]:.4f}')
    if worst > 5e-3:
        sys.exit(f'RT exposure deviated from pure gain by {worst:.4f} — '
                 'the baseline itself changed; re-measure before citing it.')


def rt_bleach(work):
    inp = os.path.join(work, 'orange.tif')
    write_srgb16(inp, [ORANGE * 0.5])  # one stop of file headroom; pushes go via the slider
    film = '/usr/share/rawtherapee/profiles/Standard Film Curve - ISO Low.pp3'
    rows = {}
    for label, extra in (('neutral', []), ('film', ['-p', film])):
        vals = []
        for ev in range(6):
            pp3 = os.path.join(work, f'p{ev}.pp3')
            # +1 first re-aligns the half-scale patch with the probe's base level.
            open(pp3, 'w').write(f'[Exposure]\nAuto=false\nCompensation={ev + 1}\n')
            out = os.path.join(work, f'rt_{label}_{ev}.tif')
            cmd = ['rawtherapee-cli', '-t', '-b16', '-Y', '-o', out]
            cmd += extra + ['-p', pp3, '-c', inp]
            run(cmd)
            vals.append(chroma(read_patches_linear(out, 1)[0]))
        rows[label] = vals
    return rows



def rt_sh_recovery(work):
    """RT 5.10 Shadows/Highlights at full deflection: per-patch EV shift.

    Comparable SHAPE questions, not slider-unit equality (RT's S&H is a
    display-referred tool with its own tonal widths): how many EV does full
    Highlights pull the top patches down, full Shadows lift the bottom ones,
    and does mid-grey hold still. Lumen's answers (TONEBASE print, and the
    endpoint contract test): highlights/shadows own +-2.0 EV zones, hard-
    partitioned at mid-grey, mid-grey exactly unmoved.
    """
    evs = [-5.0, -3.0, -1.0, 0.0, 1.0, 2.0, 2.32]
    patches = [np.full(3, 0.18 * (2.0 ** e)) for e in evs]
    inp = os.path.join(work, 'shsteps.tif')
    write_srgb16(inp, patches)

    rows = {}
    for label, hi, sh in (('Highlights 100', 100, 0), ('Shadows 100', 0, 100)):
        pp3 = os.path.join(work, f'sh_{hi}_{sh}.pp3')
        open(pp3, 'w').write(
            '[Shadows & Highlights]\nEnabled=true\n'
            f'Highlights={hi}\nShadows={sh}\n')
        out = os.path.join(work, f'rt_sh_{hi}_{sh}.tif')
        run(['rawtherapee-cli', '-t', '-b16', '-Y', '-o', out, '-p', pp3,
             '-c', inp])
        outs = read_patches_linear(out, len(evs))
        shifts = [float(np.log2(max(o.mean(), 1e-6) / p.mean()))
                  for o, p in zip(outs, patches)]
        rows[label] = shifts

    print('RawTherapee 5.10 Shadows&Highlights, full deflection: EV shift per '
          'scene patch')
    print('  scene EV        ' + '  '.join(f'{e:+5.2f}' for e in evs))
    for label, shifts in rows.items():
        print(f'  {label:15s} ' + '  '.join(f'{v:+5.2f}' for v in shifts))
    mid = rows['Highlights 100'][3]
    if abs(mid) > 0.5:
        sys.exit(f'RT Highlights moved mid-grey by {mid:+.2f} EV — re-check '
                 'the pp3 keys before citing this table.')
    return rows


def hazy_scene():
    """A veiled scene with known ground truth, the shape of Lumen's own
    ProofFrames.hazySky: textured dark ground under a sky gradient, veiled by
    airlight (0.55, 0.62, 0.78) with transmission falling toward the top."""
    h = w = 128
    img = np.zeros((h, w, 3), dtype=np.float64)
    air = np.array([0.55, 0.62, 0.78])
    for y in range(h):
        v = y / (h - 1.0)
        for x in range(w):
            if v < 0.6:
                clear = np.array([0.10 + 0.05 * v, 0.16 + 0.08 * v,
                                  0.34 + 0.10 * v])
            else:
                t = 1.0 + 0.25 * np.sin(2 * np.pi * x / 5.0)
                clear = np.array([0.13 * t, 0.11 * t, 0.08 * t])
            trans = 0.25 + 0.65 * v
            img[y, x] = clear * trans + air * (1.0 - trans)
    return img


def ground_contrast(img):
    """RMS contrast of the textured ground band (the region dehaze must
    recover), on the luminance plane."""
    band = img[int(img.shape[0] * 0.8):, :, :]
    lum = band @ np.array([0.2627, 0.6780, 0.0593])
    return float(lum.std() / max(lum.mean(), 1e-9))


def write_scene_srgb16(path, img):
    tifffile.imwrite(path, np.round(srgb_encode(img) * 65535.0).astype(np.uint16))


def read_scene_linear(path):
    img = tifffile.imread(path).astype(np.float64) / 65535.0
    return srgb_decode(img[..., :3])


def rt_dehaze(work):
    inp = os.path.join(work, 'hazy.tif')
    scene = hazy_scene()
    write_scene_srgb16(inp, scene)
    base = ground_contrast(scene)
    rows = {}
    for strength in (50, 100):
        pp3 = os.path.join(work, f'dehaze{strength}.pp3')
        open(pp3, 'w').write(f'[Dehaze]\nEnabled=true\nStrength={strength}\n')
        out = os.path.join(work, f'rt_dehaze{strength}.tif')
        run(['rawtherapee-cli', '-t', '-b16', '-Y', '-o', out, '-p', pp3,
             '-c', inp])
        recovered = read_scene_linear(out)
        rows[f'RT Strength {strength}'] = (
            ground_contrast(recovered) / base,
            float(recovered[:8, :, :].mean() / scene[:8, :, :].mean()))
    return base, rows


def dt_dehaze(work):
    # DT_XMP is defined in the darktable section below; swap the operation in.
    haze_xmp = DT_XMP.replace('darktable:operation="sigmoid"',
                              'darktable:operation="hazeremoval"')
    inp = os.path.join(work, 'hazy.pfm')
    scene = hazy_scene()
    img = scene.astype(np.float32)
    with open(inp, 'wb') as f:
        f.write(b'PF\n%d %d\n-1.0\n' % (img.shape[1], img.shape[0]))
        f.write(img[::-1].tobytes())
    base = ground_contrast(scene)
    rows = {}
    for strength in (0.5, 1.0):
        params = struct.pack('<ff', strength, 0.75).hex()
        xmp = os.path.join(work, f'haze{strength}.xmp')
        open(xmp, 'w').write(haze_xmp.format(params=params))
        out = os.path.join(work, f'dt_haze{strength}.tif')
        run(['darktable-cli', inp, xmp, out, '--core',
             '--conf', 'plugins/imageio/format/tiff/bpp=16',
             '--configdir', os.path.join(work, f'dtcfg-haze{strength}')])
        recovered = read_scene_linear(out)
        gain = ground_contrast(recovered) / base
        rows[f'dt strength {strength}'] = (
            gain, float(recovered[:8, :, :].mean() / scene[:8, :, :].mean()))
    # Struct tripwire: a dropped module renders the veil untouched.
    if abs(rows['dt strength 1.0'][0] - 1.0) < 0.02:
        sys.exit('darktable hazeremoval changed nothing at strength 1.0 — the '
                 'param struct no longer matches this darktable; fix dt_dehaze '
                 'before citing numbers.')
    return rows


# ------------------------------------------------------------------ darktable

DT_XMP = '''<?xml version="1.0" encoding="UTF-8"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="XMP Core 4.4.0-Exiv2">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:xmp="http://ns.adobe.com/xap/1.0/"
    xmlns:darktable="http://darktable.sf.net/"
    xmp:Rating="1"
    darktable:xmp_version="5"
    darktable:raw_params="0"
    darktable:auto_presets_applied="1"
    darktable:history_end="1"
    darktable:iop_order_version="1">
   <darktable:masks_history>
    <rdf:Seq/>
   </darktable:masks_history>
   <darktable:history>
    <rdf:Seq>
     <rdf:li
      darktable:num="0"
      darktable:operation="sigmoid"
      darktable:enabled="1"
      darktable:modversion="1"
      darktable:params="{params}"
      darktable:multi_name=""
      darktable:multi_priority="0"
      darktable:blendop_version="13"/>
    </rdf:Seq>
   </darktable:history>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
'''


def dt_sigmoid_params(contrast=1.5, skew=0.0, white=100.0, black=0.0152,
                      method=0, hue=100.0):
    return struct.pack('<ffffif', contrast, skew, white, black, method, hue).hex()


def dt_contrast_slope(work):
    """Realized log-log slope of dt's sigmoid at mid-grey, dial at 1.5.

    Lumen's contrast is a calibrated slope (1.5 -> measured 1.5, by
    construction); dt's dial turned out to be a steepness knob whose realized
    slope at 1.5 measures ~1.23 (docs/26 §3). Kept here so the number in the
    docs stays re-measurable rather than remembered.
    """
    deltas = [-0.4, -0.2, 0.0, 0.2, 0.4]
    pfm = os.path.join(work, 'greys.pfm')
    write_pfm(pfm, [np.full(3, 0.18 * (2.0 ** d)) for d in deltas])
    xmp = os.path.join(work, 'contrast.xmp')
    open(xmp, 'w').write(DT_XMP.format(params=dt_sigmoid_params()))
    out = os.path.join(work, 'dt_greys.tif')
    run(['darktable-cli', pfm, xmp, out, '--core',
         '--conf', 'plugins/imageio/format/tiff/bpp=16',
         '--configdir', os.path.join(work, 'dtcfg-contrast')])
    lums = [float(p.mean()) for p in read_patches_linear(out, len(deltas))]
    slope = (np.log2(lums[3]) - np.log2(lums[1])) / 0.4
    print(f'darktable sigmoid contrast dial 1.5: mid-grey -> {lums[2]:.4f}, '
          f'realized log-log slope {slope:.3f} '
          f'(Lumen 1.5 realizes 1.5 by construction)')


def dt_bleach(work):
    pfm = os.path.join(work, 'push.pfm')
    write_pfm(pfm, [ORANGE * (2.0 ** k) for k in range(6)])
    rows = {}
    for label, method, hue in (('per-channel hp100', 0, 100.0),
                               ('per-channel hp66', 0, 66.0),
                               ('rgb-ratio', 1, 0.0)):
        xmp = os.path.join(work, f'{label}.xmp'.replace(' ', '_'))
        open(xmp, 'w').write(DT_XMP.format(
            params=dt_sigmoid_params(method=method, hue=hue)))
        out = os.path.join(work, f'dt_{label}.tif'.replace(' ', '_'))
        run(['darktable-cli', pfm, xmp, out, '--core',
             '--conf', 'plugins/imageio/format/tiff/bpp=16',
             '--configdir', os.path.join(work, 'dtcfg')])
        vals = [chroma(p) for p in read_patches_linear(out, 6)]
        # The struct-layout tripwire: a dropped module degenerates to a hard
        # clip, whose +0 EV patch holds full input chroma with R at clip.
        raw = read_patches_linear(out, 1)[0]
        if raw.max() > 0.999 and abs(vals[0] - 0.58) < 0.01:
            sys.exit(f'darktable run "{label}" looks like a hard clip — the '
                     'sigmoid param struct no longer matches this darktable; '
                     'fix dt_sigmoid_params before citing numbers.')
        rows[label] = vals
    return rows


def main():
    for tool in ('rawtherapee-cli', 'darktable-cli'):
        if not shutil.which(tool):
            sys.exit(f'{tool} not on PATH — apt install it first')
    with tempfile.TemporaryDirectory() as work:
        rt_exposure_gain(work)
        print()
        rt_sh_recovery(work)
        print()
        base, haze = rt_dehaze(work)
        haze.update(dt_dehaze(work))
        print('Dehaze on the synthetic veiled scene (known airlight '
              '0.55/0.62/0.78; ground-truth clear ground contrast recovery):')
        print(f'  hazy input ground contrast {base:.3f} (clear scene: ~0.19)')
        for label, (gain, veil) in haze.items():
            print(f'  {label:18s} ground contrast x{gain:.2f}   '
                  f'far-veil luminance x{veil:.2f}')
        print()
        print('Residual chroma of RGB(1.0, 0.72, 0.42) pushed +0..+5 EV')
        print('(Lumen probe PATHTOWHITE prints the same experiment):')
        for label, vals in {**rt_bleach(work), **dt_bleach(work)}.items():
            print(f'  {label:22s} ' +
                  '  '.join(f'+{k}EV {c:.3f}' for k, c in enumerate(vals)))
        print()
        dt_contrast_slope(work)


if __name__ == '__main__':
    main()
