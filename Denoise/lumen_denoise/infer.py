"""RAW -> denoised DNG.

python -m lumen_denoise.infer IN.ARW [IN2.RW2 ...] --out DIR [--strength 1.0] [--weights W.pt]
Prints one JSON line per file on stdout (in input order); a failed file prints {"file","out","error"}
on stderr instead, so the app never mistakes it for a result. Times: denoise_s = load + denoise,
total_s = denoise_s + write (each phase timed itself, so batch prefetch queueing is not counted).
"""
import argparse, copy, json, os, sys, time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import numpy as np
import torch
from . import raw as rawio, noise, dng
from .model import Denoiser
from .prepare import to_rggb, from_rggb
from .train import NoiseTable, std_map

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_WEIGHTS = ROOT / "weights" / "lumen_denoise.pt"
DEFAULT_CALIB = ROOT / "weights" / "calib.json"
DEV = "mps" if torch.backends.mps.is_available() else "cpu"
OFFLOAD = "/Volumes/Offload Drive"  # user's read-only archive


def guard_output(path):
    """Refuse any path on the Offload Drive (case-insensitive, symlinks and '..' resolved)."""
    p = Path(os.path.realpath(path)).parts
    root = Path(os.path.realpath(OFFLOAD)).parts
    if [s.casefold() for s in p[:len(root)]] == [s.casefold() for s in root]:
        raise PermissionError(f"refusing to write onto the Offload Drive: {path}")


def check_strength(s):
    if not 0 <= s <= 1:
        raise ValueError(f"strength must be in [0, 1], got {s}")
    return s


def default_noise(iso):
    # Sony A7 IV calibration slope, mild on purpose (under-denoise rather than smear)
    iso = iso if iso and np.isfinite(iso) and iso > 0 else 800.0
    return 1.65e-7 * iso, 1.3e-7


def mean_preserve(p, d, sigma=24.0):
    """Restore the input's large-scale level: noise is zero-mean, so blur(p) is an unbiased level
    estimate and blur(p - d) is the denoiser's own bias (L1-trained nets shift dark areas by
    ~10-20 DN of 14-bit; the release gate's low-ISO check requires <= 1). sigma in packed px;
    0 disables. At sigma 24 the noise leaking back costs < 0.01 dB."""
    if not sigma:
        return d
    import cv2
    diff = (p - d).astype(np.float32)
    return d + np.stack([cv2.GaussianBlur(c, (0, 0), sigma, borderType=cv2.BORDER_REFLECT) for c in diff])


def _weights(t, a0, n, ov):
    """1-D blend weights for a tile [a0, a0+t) of an axis of length n: at interior tile edges the
    outer ov//4 px get weight 0 (UNet zero-padding artifacts), then a linear ramp; image edges 1."""
    d = ov // 4
    r = np.clip((np.arange(t, dtype=np.float32) - d + 1) / max(ov - d, 1), 0, 1)
    w = np.ones(t, np.float32)
    if a0 > 0: w = np.minimum(w, r)
    if a0 + t < n: w = np.minimum(w, r[::-1])
    return w


def _starts(n, tile, step):
    if n <= tile:
        return [0]
    return list(range(0, n - tile, step)) + [n - tile]


class Engine:
    def __init__(self, weights=DEFAULT_WEIGHTS, calib=DEFAULT_CALIB, net=None, dev=DEV, tile=1024, ov=64, mp_sigma=24.0):
        if net is None:
            net = Denoiser.from_state_dict(torch.load(weights, map_location="cpu"))
        assert tile > 2 * ov and tile % 16 == 0, (tile, ov)
        self.dev, self.half = dev, dev != "cpu"  # fp16 only on GPU; half conv on CPU is slow
        self.net = net.eval().to(dev)
        if self.half:
            self.net.half()
        self._net32 = None
        self.mp_sigma = mp_sigma
        self.table = NoiseTable(calib) if calib and Path(calib).exists() else None
        self.tile, self.ov = tile, ov

    def noise_params(self, r, packed):
        """-> (K, read_var, source) with source in calib | estimated | default."""
        iso = float(r.iso or 0)
        if self.table and r.model in self.table.t and np.isfinite(iso) and iso > 0:
            lo, hi = self.table.iso_range(r.model)
            return (*self.table.params(r.model, float(np.clip(iso, lo, hi))), "calib")
        try:  # unknown camera: measure from the image itself
            K, rv = noise.estimate(packed)
            if np.isfinite(K) and np.isfinite(rv) and (K > 1e-8 or rv > 1e-10):  # both at floor = no fit
                return K, rv, "estimated"
        except (IndexError, ValueError, np.linalg.LinAlgError):
            pass
        return (*default_noise(iso), "default")

    def _run_net(self, x, sm, fp32=False):
        net = self.net
        if fp32 and self.half:
            if self._net32 is None:
                self._net32 = copy.deepcopy(self.net).float()
            net = self._net32
        dt = torch.float16 if self.half and not fp32 else torch.float32
        if getattr(net, "residual", False):
            return net.net(torch.cat([x, sm], 1).to(self.dev, dt))
        return net(x.to(self.dev, dt), sm.to(self.dev, dt))

    @torch.inference_mode()
    def denoise_packed(self, p, K, rv):
        """p: (4,h,w) float32 RGGB normalized -> same shape, denoised. Feathered tiles.
        Std map and residual scale s are computed once on the whole image in fp32, so tiles agree."""
        tile, ov = self.tile, self.ov
        _, h, w = p.shape
        pt = torch.from_numpy(np.ascontiguousarray(p, np.float32))[None]
        sm = std_map(pt, K, rv)
        res = getattr(self.net, "residual", False)
        s = max(float(sm.double().mean()), 1e-5) if res else 1.0
        out = np.zeros_like(p, np.float32); wsum = np.zeros((1, h, w), np.float32)
        for y0 in _starts(h, tile, tile - 2 * ov):
            for x0 in _starts(w, tile, tile - 2 * ov):
                t, st = pt[..., y0:y0 + tile, x0:x0 + tile], sm[..., y0:y0 + tile, x0:x0 + tile]
                th, tw = t.shape[2:]
                x, xs = t / s, st / s
                ph, pw = (-th) % 16, (-tw) % 16
                if ph or pw:  # only when the image is smaller than a tile
                    x = torch.from_numpy(np.pad(x.numpy(), ((0, 0), (0, 0), (0, ph), (0, pw)), mode="reflect"))
                    xs = torch.from_numpy(np.pad(xs.numpy(), ((0, 0), (0, 0), (0, ph), (0, pw)), mode="reflect"))
                o = self._run_net(x, xs)
                if not torch.isfinite(o).all():  # fp16 overflow: redo this tile in fp32
                    o = self._run_net(x, xs, fp32=True)
                o = o.float().cpu()[0, :, :th, :tw]
                o = (t[0] + s * o if res else o).numpy()
                wt = _weights(th, y0, h, ov)[:, None] * _weights(tw, x0, w, ov)[None, :]
                out[:, y0:y0 + th, x0:x0 + tw] += o * wt
                wsum[:, y0:y0 + th, x0:x0 + tw] += wt
        return out / wsum

    def _load(self, src, out_path):
        guard_output(out_path)
        t0 = time.time()
        r = rawio.load(src)
        pending = dng.start(src)
        return r, pending, time.time() - t0

    def _denoise(self, src, out_path, r, load_s, strength):
        """-> (uint16 CFA in source raw space, result dict, seconds so far)."""
        t1 = time.time()
        cfa = r.cfa
        H, W = cfa.shape
        if H % 2 or W % 2:  # reflect keeps Bayer parity, so the last row/col gets denoised too
            cfa = np.pad(cfa, ((0, H % 2), (0, W % 2)), mode="reflect")
        p = to_rggb(rawio.pack(cfa), r.pattern)
        K, rv, src_n = self.noise_params(r, p)
        d = mean_preserve(p, self.denoise_packed(p, K, rv), self.mp_sigma)
        d = strength * d + (1 - strength) * p
        dn = rawio.denormalize(r, rawio.unpack(from_rggb(d, r.pattern))[:H, :W])
        iso = int(r.iso) if float(r.iso).is_integer() else r.iso
        el = load_s + time.time() - t1
        return dn, {"file": str(src), "out": str(out_path), "iso": iso, "model": r.model, "noise": src_n,
                    "K": K, "read_sd": rv ** 0.5, "denoise_s": round(el, 2)}, el

    def _write(self, src, out_path, dn, r, pending, info, el):
        t2 = time.time()
        dng.write_cfa_dng(src, dn, out_path, orig=r.raw, black=list(r.black_levels), pending=pending)
        info["total_s"] = round(el + time.time() - t2, 2)
        return info

    def denoise_file(self, src, out_path, strength=1.0):
        check_strength(strength)
        r, pending, load_s = self._load(src, out_path)
        try:
            dn, info, el = self._denoise(src, out_path, r, load_s, strength)
        except BaseException:
            _cancel(pending); raise
        return self._write(src, out_path, dn, r, pending, info, el)

    def run(self, files, out_dir, strength=1.0, emit=None):
        """Batch: decode file N+1 and write file N-1 while file N is on the GPU. At most one
        prefetched and one pending write (memory on 16 GB). Returns the number of failures."""
        check_strength(strength)
        emit = emit or (lambda d: print(json.dumps(d), file=sys.stderr if "error" in d else sys.stdout, flush=True))
        guard_output(out_dir)
        os.makedirs(out_dir, exist_ok=True)
        jobs, used = [], set()
        for f in files:  # same file name from two folders: -2, -3 ... never overwrite within a batch
            stem, n = Path(f).stem + "-Denoised", 1
            name = stem + ".dng"
            while name.casefold() in used:  # macOS volumes are case-insensitive
                n += 1; name = f"{stem}-{n}.dng"
            used.add(name.casefold())
            jobs.append((str(f), Path(out_dir) / name))
        failed = 0

        def err(job, e):
            nonlocal failed
            failed += 1
            emit({"file": job[0], "out": str(job[1]), "error": f"{type(e).__name__}: {e}"})

        def flush(pend):
            if pend:
                fut, job = pend
                try:
                    emit(fut.result())
                except Exception as e:
                    err(job, e)

        with ThreadPoolExecutor(1) as rd, ThreadPoolExecutor(1) as wr:
            nxt = rd.submit(self._load, *jobs[0]) if jobs else None
            pend = None
            for i, job in enumerate(jobs):
                cur = nxt
                try:
                    r, pending, load_s = cur.result()
                except Exception as e:
                    nxt = rd.submit(self._load, *jobs[i + 1]) if i + 1 < len(jobs) else None
                    flush(pend); pend = None
                    err(job, e)
                    continue
                nxt = rd.submit(self._load, *jobs[i + 1]) if i + 1 < len(jobs) else None
                try:
                    dn, info, el = self._denoise(*job, r, load_s, strength)
                except Exception as e:
                    _cancel(pending)
                    flush(pend); pend = None
                    err(job, e)
                    continue
                r.cfa = None  # the writer only needs r.raw / r.black_levels
                flush(pend)
                pend = (wr.submit(self._write, *job, dn, r, pending, info, el), job)
            flush(pend)
        return failed


def _cancel(pending):
    f = getattr(dng, "cancel", None)
    if pending is not None and f:
        f(pending)


def _strength(v):
    try:
        return check_strength(float(v))
    except ValueError as e:
        raise argparse.ArgumentTypeError(str(e))


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("inputs", nargs="+"); ap.add_argument("--out", required=True)
    ap.add_argument("--strength", type=_strength, default=1.0)
    ap.add_argument("--weights", default=str(DEFAULT_WEIGHTS)); ap.add_argument("--calib", default=str(DEFAULT_CALIB))
    a = ap.parse_args(argv)
    try:
        guard_output(a.out)
    except PermissionError as e:
        raise SystemExit(str(e))
    eng = Engine(a.weights, a.calib)
    sys.exit(1 if eng.run(a.inputs, a.out, a.strength) else 0)


if __name__ == "__main__":
    main()
