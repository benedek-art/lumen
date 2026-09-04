#!/usr/bin/env python3
"""Render Lumen's app icon to an .iconset, from geometry rather than from a file.

THE MARK. A slanted white field with an upright cross cut out of it, reaching the
field's bottom edge. The slant is the same lean the app's own wordmark has; the cross
sits dead centre horizontally and is NOT slanted, which is the whole tension of the
thing — an upright figure standing in a leaning frame.

WHY THIS IS A SCRIPT AND NOT A PNG SOMEBODY EXPORTED. An icon committed as pixels is a
file nobody can correct: the day the mark needs to be a hair larger, or the ground needs
to stop being pure black, the only recourse is to open a paint program and hope. Here the
shape is fourteen numbers and every size is rendered from them, so the 16 px version is
the same geometry as the 1024 px one rather than a resample of it — which matters most at
16, where a resampled cross turns to mush.

Everything is analytic: exact horizontal coverage per sub-scanline, four sub-scanlines
per pixel row. No supersampled bitmap, no dependencies, and the antialiasing is the same
at every size. Pure standard library, because this runs on the Linux side where there is
no PIL, no cairo and no rsvg.

    python3 scripts/make-appicon.py            # writes resources/Lumen.iconset/
    scripts/build-app.sh                       # turns it into AppIcon.icns on macOS
"""

import os
import struct
import zlib

# --- the geometry, in units of the 1024-pt canvas -------------------------------------

CANVAS = 1024.0

# Apple's macOS icon grid: the rounded rectangle is 824 wide inside a 1024 canvas, with a
# 185 corner radius. The source artwork was a full-bleed square, which on a Mac would sit
# among rounded neighbours looking like a misprint — this is the "format it correctly"
# the owner asked for, and it is the only liberty taken with the design.
GROUND_INSET = 100.0
GROUND_RADIUS = 185.0

# The parallelogram. Horizontal top and bottom edges; both side edges lean the same way,
# so opposite sides stay parallel and the figure reads as one stroke of a pen.
MARK_H = 400.0          # top edge to bottom edge
MARK_W = 310.0          # length of the top (and bottom) edge
MARK_SLANT = 118.0      # how far the TOP edge sits to the right of the bottom edge

# The cross, measured from the field's top-left, upright and horizontally centred.
CROSS_STEM_W = 51.0
CROSS_STEM_TOP = 190.0      # below the field's top edge; it runs to the bottom edge
CROSS_ARM_W = 148.0
CROSS_ARM_TOP = 244.0       # below the field's top edge
CROSS_ARM_H = 40.0

WHITE = (250, 250, 249)     # not pure white: a hair warm, so it does not buzz on black
BLACK = (10, 10, 11)        # not pure black either, for the same reason in reverse

SUB = 4                     # sub-scanlines per pixel row


def _overlap(a0, a1, b0, b1):
    """Length of the intersection of two intervals, never negative."""
    lo = a0 if a0 > b0 else b0
    hi = a1 if a1 < b1 else b1
    return hi - lo if hi > lo else 0.0


def _add_span(row, x0, x1, weight, width):
    """Accumulate coverage for the horizontal span [x0, x1) into a float row."""
    if x1 <= x0:
        return
    if x0 < 0.0:
        x0 = 0.0
    if x1 > width:
        x1 = float(width)
    if x1 <= x0:
        return
    first = int(x0)
    last = int(x1 - 1e-9)
    if first == last:
        row[first] += (x1 - x0) * weight
        return
    row[first] += (first + 1 - x0) * weight
    for x in range(first + 1, last):
        row[x] += weight
    row[last] += (x1 - last) * weight


def _rounded_rect_span(y, inset, radius, size):
    """Horizontal extent of the rounded square at height y, or None above/below it."""
    top = inset
    bottom = size - inset
    if y < top or y >= bottom:
        return None
    left = inset
    right = size - inset
    # Inside the corner arcs the edge pulls in by the circle's own horizontal offset.
    dy = 0.0
    if y < top + radius:
        dy = (top + radius) - y
    elif y > bottom - radius:
        dy = y - (bottom - radius)
    if dy > 0.0:
        r2 = radius * radius - dy * dy
        inward = radius - (r2 ** 0.5 if r2 > 0.0 else 0.0)
        left += inward
        right -= inward
    return left, right


def render(size):
    """One RGBA image, as a list of bytearrays, rendered at `size` pixels square."""
    k = size / CANVAS
    inset = GROUND_INSET * k
    radius = GROUND_RADIUS * k

    mark_h = MARK_H * k
    mark_w = MARK_W * k
    slant = MARK_SLANT * k
    bbox_w = mark_w + slant

    # Centre the mark's bounding box on the canvas.
    top = (size - mark_h) / 2.0
    bottom = top + mark_h
    bbox_left = (size - bbox_w) / 2.0
    bottom_left = bbox_left
    top_left = bbox_left + slant

    stem_w = CROSS_STEM_W * k
    stem_top = top + CROSS_STEM_TOP * k
    stem_x0 = size / 2.0 - stem_w / 2.0
    stem_x1 = stem_x0 + stem_w
    arm_w = CROSS_ARM_W * k
    arm_x0 = size / 2.0 - arm_w / 2.0
    arm_x1 = arm_x0 + arm_w
    arm_y0 = top + CROSS_ARM_TOP * k
    arm_y1 = arm_y0 + CROSS_ARM_H * k

    weight = 1.0 / SUB
    rows = []
    for py in range(size):
        ground = [0.0] * size
        mark = [0.0] * size
        for s in range(SUB):
            y = py + (s + 0.5) * weight

            span = _rounded_rect_span(y, inset, radius, size)
            if span is not None:
                _add_span(ground, span[0], span[1], weight, size)

            if top <= y < bottom:
                # The field's left edge slides right as it RISES, so the top sits to
                # the right of the bottom and the figure leans like a forward slash.
                t = (y - top) / mark_h             # 0 at the top edge, 1 at the bottom
                left = top_left - slant * t
                _add_span(mark, left, left + mark_w, weight, size)
                # Punch the cross back out. Subtracting a span from the same row is
                # exact here because the cross lies wholly inside the field at every
                # height it occupies — asserted below.
                if y >= stem_top:
                    _add_span(mark, stem_x0, stem_x1, -weight, size)
                if arm_y0 <= y < arm_y1:
                    # The arm minus the stem, so the overlap is not subtracted twice.
                    _add_span(mark, arm_x0, stem_x0, -weight, size)
                    _add_span(mark, stem_x1, arm_x1, -weight, size)

        row = bytearray(size * 4)
        for x in range(size):
            a = ground[x]
            if a <= 0.0:
                continue
            if a > 1.0:
                a = 1.0
            m = mark[x]
            if m < 0.0:
                m = 0.0
            elif m > 1.0:
                m = 1.0
            i = x * 4
            row[i] = int(BLACK[0] + (WHITE[0] - BLACK[0]) * m + 0.5)
            row[i + 1] = int(BLACK[1] + (WHITE[1] - BLACK[1]) * m + 0.5)
            row[i + 2] = int(BLACK[2] + (WHITE[2] - BLACK[2]) * m + 0.5)
            row[i + 3] = int(a * 255.0 + 0.5)
        rows.append(row)
    return rows


def write_png(path, rows, size):
    raw = bytearray()
    for row in rows:
        raw.append(0)              # filter type 0, none
        raw.extend(row)

    def chunk(tag, data):
        out = struct.pack(">I", len(data)) + tag + data
        return out + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def check_geometry():
    """The cross must lie wholly inside the field, or the punch-out leaves a notch in
    the field's edge instead of a cross in its middle. Checked rather than eyeballed,
    because at 16 px a two-pixel notch and a two-pixel cross look identical."""
    top, bottom = 0.0, MARK_H
    bottom_left = 0.0
    top_left = MARK_SLANT

    def left_at(y):
        return top_left - MARK_SLANT * ((y - top) / MARK_H)

    centre = MARK_SLANT / 2.0 + MARK_W / 2.0   # bbox centre, where the cross is centred
    worst = None
    for name, y0, y1, half in (
        ("stem", CROSS_STEM_TOP, MARK_H, CROSS_STEM_W / 2.0),
        ("arm", CROSS_ARM_TOP, CROSS_ARM_TOP + CROSS_ARM_H, CROSS_ARM_W / 2.0),
    ):
        y = y0
        while y <= y1:
            left = left_at(y)
            margin = min(centre - half - left, (left + MARK_W) - (centre + half))
            if worst is None or margin < worst[0]:
                worst = (margin, name, y)
            y += 0.5
    assert worst[0] > 0, (
        "the cross leaves the field at y=%.1f (%s), margin %.2f — it would cut a notch "
        "in the edge rather than a cross in the middle" % (worst[2], worst[1], worst[0])
    )
    return worst


SIZES = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = os.path.join(root, "resources", "Lumen.iconset")
    os.makedirs(out, exist_ok=True)

    margin, where, at = check_geometry()
    print("geometry ok — the cross clears the field's edge by %.1f pt at its tightest "
          "(%s, y=%.0f)" % (margin, where, at))

    cache = {}
    for size, name in SIZES:
        if size not in cache:
            cache[size] = render(size)
            print("  rendered %d px" % size)
        write_png(os.path.join(out, name), cache[size], size)
    print("wrote %d files to resources/Lumen.iconset" % len(SIZES))


if __name__ == "__main__":
    main()
