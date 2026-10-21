"""Tiny PIL line plotter (no matplotlib on this box)."""
from PIL import Image, ImageDraw


def plot(series, path, size=(640, 640), xr=(0, 1), yr=(0, 255), title='', grid=10, labels=None):
    W, H = size
    m = 40
    im = Image.new('RGB', (W, H), (255, 255, 255))
    d = ImageDraw.Draw(im)
    def tx(x): return m + (x - xr[0]) / (xr[1] - xr[0]) * (W - 2 * m)
    def ty(y): return H - m - (y - yr[0]) / (yr[1] - yr[0]) * (H - 2 * m)
    for i in range(grid + 1):
        gx = xr[0] + (xr[1] - xr[0]) * i / grid
        gy = yr[0] + (yr[1] - yr[0]) * i / grid
        d.line([(tx(gx), ty(yr[0])), (tx(gx), ty(yr[1]))], fill=(225, 225, 225))
        d.line([(tx(xr[0]), ty(gy)), (tx(xr[1]), ty(gy))], fill=(225, 225, 225))
        d.text((tx(gx) - 8, H - m + 4), f'{gx:.2g}', fill=(0, 0, 0))
        d.text((2, ty(gy) - 5), f'{gy:.3g}', fill=(0, 0, 0))
    d.rectangle([m, m, W - m, H - m], outline=(0, 0, 0))
    for k, (xs, ys, col) in enumerate(series):
        pts = [(tx(a), ty(b)) for a, b in zip(xs, ys)]
        d.line(pts, fill=col, width=2)
        if labels and k < len(labels):
            d.text((m + 6, m + 6 + 14 * k), labels[k], fill=col)
    d.text((m, 8), title, fill=(0, 0, 0))
    im.save(path)
