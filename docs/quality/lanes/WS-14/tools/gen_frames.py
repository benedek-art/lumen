"""WS-14 probe frames (scene-linear Rec.2020, D65, neutral = R=G=B, 0.18 = mid grey), LFI format.

usage: python3 gen_frames.py OUTDIR [name ...]        (default: all)

All frames that probe full-resolution (24 MP) behaviour are 6000 px STRIPS: their long edge is
6000 px, so every long-edge-denominated radius in the renderer is exactly the 24 MP radius, but
they cost 1/4 to 1/7 of a 6000x4000 render. Rendering them with --long-edge 1600/3200 gives the
preview-size version through the renderer's own area downsample.

  pink_6000   6000x1000 isotropic 1/f log-luminance noise, std 0.25 EV (scale-invariant spectrum,
              so it carries the same content per cycle-per-image at every render size)
  steps_6000  6000x1000, five 200-row strips with a vertical step at x=3000 of 0.5/1/2/3/6 EV,
              centred on 0.18 (dark left, bright right), noise-free
  ramp_tex    2400x800 log ramp -8..+4 EV along x times 1/f texture of 0.10 EV
  ramp_tex0   ramp_tex with pixel (0,0) = 0 (one black pixel; tests global-range dependence)
  ramp_lo     2400x600 log ramp -7..+3.5 EV with LOW 1/f texture 0.03 EV (posterisation probe)
  blobs_6000  6000x1000 eight smooth Gaussian blobs (soft gradients, bokeh-like) on 0.18: sigma
              15/30/60/120 px (0.25/0.5/1/2 % of the long edge) x amplitude +1 / -1 EV, centres
              x = 375 + 750 k, y = 500 (k = 0..7: (15,+1) (15,-1) (30,+1) (30,-1) (60,+1) ...)
  strands_6000  6000x1200 ORIENTED fine detail at normal contrast (amendment S9): six 200-row bands.
              Rows 0-599: random-position hair/grass-like strokes (dark, Gaussian cross-section
              sigma 1.5 px, length 80-300 px, angle within +-20 deg of vertical, ~35 % cover),
              stroke depth 0.1 / 0.2 / 0.3 EV. Rows 600-1199: a vertical sinusoidal grating of
              period 10 px at 6000 (600 cpi; 3.4 px when rendered at 2048), amplitude 0.1 / 0.2 /
              0.3 EV. Bands are separated by nothing: each band is analysed on its middle 160 rows.
  glyphs_6000  6000x1000 twelve hard-edged shapes 360-440 px (square, L, T, +, text-like E, nested
              squares) on 0.18 at +1 / +2 / -1 / -2 EV (amendment H8: convex corners and junctions vs straight edges)
  g2probe_*   4096x64 (tex) / 4096x256 (clar) strips for the GPU-probe content check (amendment G2b): `g2probe_x20_tex` /
              `g2probe_x20_clar` = the CURRENT TextureSpectrumProbe content (x-only, +-20 % linear)
              at the band centre (750 cpi = 5.46 px, 60 cpi = 68.3 px at 4096); `g2probe_2d05_tex` /
              `g2probe_2d05_clar` = proposed content: 2-D product of sinusoids, 0.05 EV, same periods
  noise_6000  6000x600 flat 0.18 with per-pixel Gaussian luminance noise, sigma 4 % of signal
  skin_6000   6000x1200 skin strip (MST-5 tone): large shading, mid-scale mottling (40-200 px
              periods, 0.08 EV), ~110k pores (Gaussian dips, sigma 1-3 px, -0.25 EV) i.e. 2-8 px
              features at 24 MP, fine 1/f noise 0.03 EV, 25 vertical lashes (3 px, -1.5 EV) in
              x 4100..4850 y 100..600, and a 1 EV lip edge (4 px soft) at y=900, x>=4000.
"""
import sys, os
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wslib import write_lfi, SRGB_TO_REC2020, STEPS_EV, SKIN, BLOBS, STRANDS_EV


def pink(h, w, std, seed):
    r = np.random.default_rng(seed)
    F = np.fft.rfft2(r.standard_normal((h, w)))
    f = np.hypot(np.fft.rfftfreq(w)[None, :], np.fft.fftfreq(h)[:, None])
    f[0, 0] = 1
    F = F / f
    F[0, 0] = 0
    x = np.fft.irfft2(F, s=(h, w))
    return (x / x.std() * std).astype(np.float32)


def bandnoise(h, w, std, pmin, pmax, seed):
    """isotropic noise with periods between pmin and pmax px"""
    r = np.random.default_rng(seed)
    F = np.fft.rfft2(r.standard_normal((h, w)))
    f = np.hypot(np.fft.rfftfreq(w)[None, :], np.fft.fftfreq(h)[:, None])
    F = F * ((f >= 1.0 / pmax) & (f <= 1.0 / pmin))
    x = np.fft.irfft2(F, s=(h, w))
    return (x / x.std() * std).astype(np.float32)


def grey(v):
    return np.repeat(v[..., None], 3, -1).astype(np.float32)


def gen(out, which):
    if "pink_6000" in which:
        write_lfi(f"{out}/pink_6000.lfi", grey(0.18 * 2.0 ** pink(1000, 6000, 0.25, seed=1)))
    if "steps_6000" in which:
        h, w = 1000, 6000
        img = np.empty((h, w), np.float32)
        sh = h // len(STEPS_EV)
        for i, s in enumerate(STEPS_EV):
            img[i * sh:(i + 1) * sh, :w // 2] = 0.18 * 2 ** (-s / 2)
            img[i * sh:(i + 1) * sh, w // 2:] = 0.18 * 2 ** (s / 2)
        write_lfi(f"{out}/steps_6000.lfi", grey(img))
    if "ramp_tex" in which or "ramp_tex0" in which:
        h, w = 800, 2400
        ev = -8 + 12 * (np.arange(w) + 0.5) / w
        img = 0.18 * 2.0 ** (ev[None, :] + pink(h, w, 0.10, seed=3))
        write_lfi(f"{out}/ramp_tex.lfi", grey(img))
        img0 = img.copy(); img0[0, 0] = 0.0
        write_lfi(f"{out}/ramp_tex0.lfi", grey(img0))
    if "ramp_lo" in which:
        h, w = 600, 2400
        ev = -7 + 10.5 * (np.arange(w) + 0.5) / w
        img = 0.18 * 2.0 ** (ev[None, :] + pink(h, w, 0.03, seed=4))
        write_lfi(f"{out}/ramp_lo.lfi", grey(img))
    if "blobs_6000" in which:
        h, w = 1000, 6000
        yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
        ev = np.zeros((h, w), np.float32)
        for k, (sig, amp) in enumerate(BLOBS):
            cx = 375 + 750 * k
            ev += amp * np.exp(-((xx - cx) ** 2 + (yy - 500) ** 2) / (2 * sig * sig))
        write_lfi(f"{out}/blobs_6000.lfi", grey(0.18 * 2.0 ** ev))
    if "strands_6000" in which:
        h, w = 1200, 6000
        ev = np.zeros((h, w), np.float32)
        r = np.random.default_rng(11)
        for b, amp in enumerate(STRANDS_EV):
            y0 = b * 200
            acc = np.zeros((200 + 400, w), np.float32)      # strokes overhang the band, cropped
            n = int(0.6 * w * 200 / (190 * 4.0))             # ~35 % cover by ~4 px wide strokes (overlaps)
            for _ in range(n):
                L = r.uniform(80, 300); th = np.radians(r.uniform(-20, 20))
                cx, cy = r.uniform(0, w), r.uniform(0, 600)
                t = np.arange(-L / 2, L / 2, 0.5)
                xs, ys = cx + t * np.sin(th), cy + t * np.cos(th)
                ix, iy = np.rint(xs).astype(int), np.rint(ys).astype(int)
                m = (ix >= 0) & (ix < w) & (iy >= 0) & (iy < 600)
                np.maximum.at(acc, (iy[m], ix[m]), 1.0)
            F = np.fft.rfft2(acc)
            fy = np.fft.fftfreq(600)[:, None]; fx = np.fft.rfftfreq(w)[None, :]
            sg = 1.5
            prof = np.fft.irfft2(F * np.exp(-2 * np.pi ** 2 * sg * sg * (fx ** 2 + fy ** 2)), s=(600, w))
            prof = np.clip(prof / prof.max() * 2.5, 0, 1)                  # flat-topped strokes
            ev[y0:y0 + 200] = -amp * prof[200:400]
        x = np.arange(w)[None, :]
        for b, amp in enumerate(STRANDS_EV):
            ev[600 + b * 200:800 + b * 200] = amp * np.sin(2 * np.pi * x / 10.0)
        write_lfi(f"{out}/strands_6000.lfi", grey(0.18 * 2.0 ** ev))
    if "glyphs_6000" in which:
        h, w = 1000, 6000
        ev = np.zeros((h, w), np.float32)
        amps = (1.0, 2.0, -1.0, -2.0)
        for k in range(12):                      # 12 cells of 500 px, one shape each
            cx, cy = 250 + 500 * k, 500
            a = amps[k % 4]; kind = k % 6
            if kind == 0:      # square
                ev[cy - 180:cy + 180, cx - 180:cx + 180] += a
            elif kind == 1:    # L
                ev[cy - 180:cy + 180, cx - 180:cx - 90] += a; ev[cy + 90:cy + 180, cx - 90:cx + 180] += a
            elif kind == 2:    # T
                ev[cy - 180:cy - 90, cx - 180:cx + 180] += a; ev[cy - 90:cy + 180, cx - 45:cx + 45] += a
            elif kind == 3:    # +
                ev[cy - 45:cy + 45, cx - 210:cx + 210] += a; ev[cy - 210:cy + 210, cx - 45:cx + 45] += a
            elif kind == 4:    # text-like 'E' with 36 px strokes
                ev[cy - 180:cy + 180, cx - 120:cx - 84] += a
                for y_ in (cy - 180, cy - 18, cy + 144):
                    ev[y_:y_ + 36, cx - 120:cx + 120] += a
            else:              # nested squares
                ev[cy - 220:cy + 220, cx - 220:cx + 220] += a / 2; ev[cy - 90:cy + 90, cx - 90:cx + 90] += a / 2
        write_lfi(f"{out}/glyphs_6000.lfi", grey(0.18 * 2.0 ** ev))
    if "g2probe" in which:
        w = 4096
        for tag, per, h in (("tex", w / 750.0, 64), ("clar", w / 60.0, 256)):
            yy, xx = np.mgrid[0:h, 0:w].astype(np.float64)
            write_lfi(f"{out}/g2probe_x20_{tag}.lfi", grey(0.18 * (1 + 0.2 * np.sin(2 * np.pi * xx / per))))
            ev = 0.05 * np.sin(2 * np.pi * xx / per) * np.sin(2 * np.pi * yy / per + 0.7)
            write_lfi(f"{out}/g2probe_2d05_{tag}.lfi", grey(0.18 * 2.0 ** ev))
    if "noise_6000" in which:
        r = np.random.default_rng(7)
        img = 0.18 * (1 + 0.04 * r.standard_normal((600, 6000)))
        write_lfi(f"{out}/noise_6000.lfi", grey(img))
    if "skin_6000" in which:
        W, H = SKIN["W"], SKIN["H"]
        v = np.array([0xd7, 0xbd, 0x96]) / 255.0
        linv = np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)
        base = SRGB_TO_REC2020 @ linv
        yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
        ev = -0.5 * (xx / W) - 0.3 * ((yy - H / 2) / H) ** 2              # large shading
        ev += bandnoise(H, W, 0.08, 40, 200, seed=8)                       # mottling
        ev += pink(H, W, 0.03, seed=6)                                     # fine noise
        r = np.random.default_rng(5)
        n = int(15600 * W * H / 1e6)
        pores = np.zeros((H, W), np.float32)
        fy = np.fft.fftfreq(H)[:, None]; fx = np.fft.rfftfreq(W)[None, :]
        for sig in (1.0, 1.5, 2.0, 2.5, 3.0):                              # 5 size classes
            imp = np.zeros((H, W), np.float32)
            np.add.at(imp, (r.integers(0, H, n // 5), r.integers(0, W, n // 5)), 1.0)
            # Gaussian of peak 1 -> transfer 2*pi*sig^2 * exp(-2 pi^2 sig^2 f^2)
            T = 2 * np.pi * sig * sig * np.exp(-2 * np.pi ** 2 * sig * sig * (fx ** 2 + fy ** 2))
            pores += np.fft.irfft2(np.fft.rfft2(imp) * T, s=(H, W)).astype(np.float32)
        ev -= 0.25 * pores
        y0, y1 = SKIN["lash_y"]
        for i in range(SKIN["lash_n"]):
            x = SKIN["lash_x0"] + i * SKIN["lash_pitch"]
            ev[y0:y1, x:x + SKIN["lash_w"]] -= 1.5
        lip = np.clip((yy - SKIN["lip_y"]) / 4.0 + 0.5, 0, 1) * (xx >= SKIN["lip_x"][0])
        ev -= 1.0 * lip
        img = (2.0 ** ev)[..., None] * base[None, None, :] * 1.6
        write_lfi(f"{out}/skin_6000.lfi", img.astype(np.float32))


if __name__ == "__main__":
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    allf = ["pink_6000", "steps_6000", "ramp_tex", "ramp_lo", "blobs_6000", "noise_6000", "skin_6000",
            "strands_6000", "glyphs_6000", "g2probe"]
    gen(out, sys.argv[2:] or allf)
    print("frames ->", out)
