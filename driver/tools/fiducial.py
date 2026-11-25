#!/usr/bin/env python3
"""Locate the fiducial fixture in a screenshot: where the image is on screen and at
what scale, from pixels alone. The app's own idea of its geometry is not consulted.

    fiducial.py SCREENSHOT.png --map fiducial.json [--roi x,y,w,h]

As a module: locate(rgb, meta, roi=None) -> dict or None.

The fixture (make_fiducial.py) is a grid of flat cells in seven colours whose every
3x3 block is unique. Each channel of each cell is either low or high, so a cell's
identity survives tone mapping, and a grid line is where some channel flips along a
whole row or column of the view.

Needs numpy; Pillow for the command line.
"""
import json
import sys

import numpy as np

CODE = {4: "R", 2: "G", 1: "B", 3: "C", 5: "M", 6: "Y", 7: "W"}


def _thresholds(a):
    """Per-channel midpoint between the low and high cell levels as they appear here."""
    lit = a.max(axis=2) > 80
    if lit.sum() < 400:
        return None
    out = []
    for c in range(3):
        values = a[..., c][lit]
        lo, hi = np.percentile(values, [8, 92])
        if hi - lo < 40:
            return None
        out.append((lo + hi) / 2)
    return out


def _lines(bits, lit, axis):
    """Positions (float, in pixels) of grid lines crossing `axis` (1: vertical lines)."""
    if axis == 0:
        bits = bits.transpose(1, 0, 2)
        lit = lit.T
    flips = (bits[:, 1:, :] != bits[:, :-1, :]).any(axis=2)
    either = lit[:, 1:] | lit[:, :-1]
    rows = np.maximum(either.sum(axis=0), 1)
    score = flips.sum(axis=0) / rows
    # A column only counts if the image covers a fair share of it.
    score[either.sum(axis=0) < 0.25 * lit.shape[0]] = 0
    # A blurred edge spreads its flips over neighbouring columns.
    wide = np.convolve(score, np.ones(3), mode="same")
    found = []
    x = 0
    n = len(wide)
    while x < n:
        if wide[x] > 0.6:
            end = x
            while end + 1 < n and wide[end + 1] > 0.3:
                end += 1
            w = score[x:end + 1]
            if w.sum() > 0:
                # A flip at index i lies between pixels i and i + 1: edge coordinate i + 1.
                found.append(float((np.arange(x, end + 1) * w).sum() / w.sum()) + 1.0)
            x = end + 1
        else:
            x += 1
    return found


def _lattice(lines, pitch_hint=None):
    """Fit lines to origin + pitch * n. Returns (origin, pitch, indices, rms) or None."""
    lines = sorted(lines)
    if len(lines) >= 2:
        gaps = np.diff(lines)
        pitch = float(np.median(gaps))
        # Missing lines make some gaps a multiple; the smallest cluster is the pitch.
        small = gaps[gaps < 1.5 * gaps.min()]
        if len(small) >= 1:
            pitch = float(np.median(small))
    elif len(lines) == 1 and pitch_hint:
        pitch = pitch_hint
    else:
        return None
    if pitch < 3:
        return None
    xs = np.array(lines)
    origin = lines[0]
    if len(lines) >= 3:
        # The pitch near the first guess that the whole set of lines agrees on: the
        # peak of their periodogram. Robust to a missing or a spurious line.
        trial = np.linspace(0.85 * pitch, 1.15 * pitch, 2401)
        power = np.abs(np.exp(2j * np.pi * xs[None, :] / trial[:, None]).sum(axis=1))
        pitch = float(trial[power.argmax()])
        phase = np.angle(np.exp(2j * np.pi * xs / pitch).sum())
        origin = float(phase / (2 * np.pi) * pitch)
    for _ in range(4):
        idx = np.round((xs - origin) / pitch)
        ok = np.abs(xs - origin - idx * pitch) < max(0.15 * pitch, 1.5)
        if ok.sum() < 2 or len(set(idx[ok])) < 2:
            break
        p, o = np.polyfit(idx[ok], xs[ok], 1)
        pitch, origin = float(p), float(o)
    idx = np.round((np.array(lines) - origin) / pitch)
    resid = np.array(lines) - origin - idx * pitch
    ok = np.abs(resid) < max(0.2 * pitch, 2.0)
    rms = float(np.sqrt((resid[ok] ** 2).mean())) if ok.any() else 0.0
    return origin, pitch, int(ok.sum()), rms


def locate(rgb, meta, roi=None):
    """rgb: HxWx3 uint8. roi: (x, y, w, h) in pixels to search, e.g. the viewer.

    Returns None when the fixture cannot be placed, else a dict:
      scale      screen pixels per image pixel
      ox, oy     screen pixel position of the image's top-left corner
      rect       [x, y, w, h] of the whole image on screen (may exceed the view)
      lines      grid lines used [vertical, horizontal]
      rms        residual of the line fit, pixels
      match      share of sampled cells agreeing with the map at the chosen placement
      method     "grid", or "extent" when only the picture's outline could be used
    """
    h_all, w_all = rgb.shape[:2]
    x0, y0, w, h = (0, 0, w_all, h_all) if roi is None else [int(round(v)) for v in roi]
    x0, y0 = max(x0, 0), max(y0, 0)
    a = rgb[y0:min(y0 + h, h_all), x0:min(x0 + w, w_all), :3].astype(np.float32)
    if a.shape[0] < 8 or a.shape[1] < 8:
        return None
    t = _thresholds(a)
    if t is None:
        return None
    bits = np.stack([a[..., c] > t[c] for c in range(3)], axis=2)
    lit = bits.any(axis=2)
    code = bits[..., 0] * 4 + bits[..., 1] * 2 + bits[..., 2] * 1

    vertical = _lines(bits, lit, 1)
    horizontal = _lines(bits, lit, 0)
    fx = _lattice(vertical)
    fy = _lattice(horizontal, pitch_hint=fx[1] if fx else None)
    if fx is None and fy is not None:
        fx = _lattice(vertical, pitch_hint=fy[1])
    if fx is None or fy is None:
        return _extent(lit, meta, x0, y0)
    ax, px, nx, rx = fx
    ay, py, ny, ry = fy

    # Sample the colour at the middle of every lattice cell that is at least partly in view.
    H, W = code.shape
    i_lo, i_hi = int(np.floor((0 - ax) / px)), int(np.ceil((W - ax) / px))
    j_lo, j_hi = int(np.floor((0 - ay) / py)), int(np.ceil((H - ay) / py))
    seen = {}
    for j in range(j_lo, j_hi):
        ya, yb = max(ay + j * py, 0), min(ay + (j + 1) * py, H)
        if yb - ya < 5:
            continue
        for i in range(i_lo, i_hi):
            xa, xb = max(ax + i * px, 0), min(ax + (i + 1) * px, W)
            if xb - xa < 5:
                continue
            cx, cy = int((xa + xb) / 2), int((ya + yb) / 2)
            patch = code[max(cy - 1, 0):cy + 2, max(cx - 1, 0):cx + 2].ravel()
            seen[(i, j)] = int(np.bincount(patch, minlength=8).argmax())
    if len(seen) < 4:
        return _extent(lit, meta, x0, y0)

    grid, cols, rows = meta["grid"], meta["cols"], meta["rows"]
    best, second, where = -1.0, -1.0, None
    for dj in range(-j_hi, rows - j_lo + 1):
        for di in range(-i_hi, cols - i_lo + 1):
            hit = total = inside = 0
            for (i, j), value in seen.items():
                gi, gj = i + di, j + dj
                if 0 <= gi < cols and 0 <= gj < rows:
                    if value == 0:
                        continue  # covered by a HUD or a panel: no evidence either way
                    total += 1
                    inside += 1
                    hit += CODE.get(value) == grid[gj][gi]
                else:
                    total += 1
                    hit += value == 0
            if inside < 4:
                continue
            s = hit / total
            if s > best:
                best, second, where = s, best, (di, dj)
            elif s > second:
                second = s
    if where is None or best < 0.85 or best - second < 0.08:
        return _extent(lit, meta, x0, y0)
    di, dj = where
    cell = meta["cell"]
    sx, sy = px / cell, py / cell
    ox = x0 + ax - di * px
    oy = y0 + ay - dj * py
    return {
        "method": "grid",
        "scale": (sx + sy) / 2, "sx": sx, "sy": sy, "ox": ox, "oy": oy,
        "rect": [ox, oy, sx * meta["width"], sy * meta["height"]],
        "lines": [nx, ny], "rms": max(rx, ry), "match": best,
    }


def _extent(lit, meta, x0, y0):
    """Fallback when the cells cannot be resolved (the picture is drawn very small):
    the lit block's bounding box, if the whole picture is inside the view with surround
    on every side and has the fixture's shape. Good to about a pixel; says nothing
    about which part of the image is where."""
    cols, rows = lit.sum(axis=0), lit.sum(axis=1)
    if cols.max() < 8 or rows.max() < 8:
        return None
    xs = np.nonzero(cols >= 0.5 * cols.max())[0]
    ys = np.nonzero(rows >= 0.5 * rows.max())[0]
    left, right, top, bottom = xs[0], xs[-1] + 1, ys[0], ys[-1] + 1
    H, W = lit.shape
    if left <= 0 or top <= 0 or right >= W or bottom >= H:
        return None
    w, h = right - left, bottom - top
    if abs(w / h - meta["width"] / meta["height"]) > 0.03 * meta["width"] / meta["height"]:
        return None
    if lit[top:bottom, left:right].mean() < 0.9:
        return None
    sx, sy = w / meta["width"], h / meta["height"]
    return {
        "method": "extent",
        "scale": (sx + sy) / 2, "sx": sx, "sy": sy, "ox": float(x0 + left), "oy": float(y0 + top),
        "rect": [float(x0 + left), float(y0 + top), float(w), float(h)],
        "lines": [0, 0], "rms": 1.0, "match": 0.0,
    }


def image_point(place, x, y):
    """Image pixel under screen pixel (x, y)."""
    return (x - place["ox"]) / place["sx"], (y - place["oy"]) / place["sy"]


def screen_point(place, u, v):
    """Screen pixel showing image pixel (u, v)."""
    return place["ox"] + u * place["sx"], place["oy"] + v * place["sy"]


def main():
    import argparse
    from PIL import Image
    parser = argparse.ArgumentParser()
    parser.add_argument("screenshot")
    parser.add_argument("--map", required=True)
    parser.add_argument("--roi")
    args = parser.parse_args()
    meta = json.load(open(args.map))
    rgb = np.asarray(Image.open(args.screenshot).convert("RGB"))
    roi = [float(v) for v in args.roi.split(",")] if args.roi else None
    print(json.dumps(locate(rgb, meta, roi), indent=1))


if __name__ == "__main__":
    sys.exit(main())
