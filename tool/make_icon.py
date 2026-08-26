#!/usr/bin/env python3
"""Generates the application icon: a camera iris on a dark rounded square.

Drawn geometrically rather than traced, so it stays crisp at every size and can
be regenerated after a palette change. Rendered at 8x and downsampled, which is
cheaper than hinting each size by hand and gives clean antialiased edges.

    python3 tool/make_icon.py

Writes assets/icon/app_icon_{16,24,32,48,64,128,256,512}.png
"""

import math
import os

from PIL import Image, ImageDraw

OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "assets", "icon")
SIZES = [16, 24, 32, 48, 64, 128, 256, 512]

SS = 8           # supersampling factor
BASE = 512
N = BASE * SS

# Matches the app chrome: dark surface, iOS-ish blue accent.
BG_TOP = (44, 44, 48, 255)
BG_BOTTOM = (20, 20, 22, 255)
BLADE = (10, 132, 255, 255)
BLADE_DARK = (7, 104, 205, 255)
APERTURE = (12, 12, 14, 255)
RIM = (255, 255, 255, 26)

BLADES = 6


def rounded_rect_mask(n, radius):
    mask = Image.new("L", (n, n), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, n - 1, n - 1], radius=radius,
                                           fill=255)
    return mask


def vertical_gradient(n, top, bottom):
    grad = Image.new("RGBA", (1, n))
    px = grad.load()
    for y in range(n):
        t = y / (n - 1)
        px[0, y] = tuple(round(a + (b - a) * t) for a, b in zip(top, bottom))
    return grad.resize((n, n))


def unit(angle):
    return math.cos(angle), math.sin(angle)


def build():
    img = vertical_gradient(N, BG_TOP, BG_BOTTOM)
    draw = ImageDraw.Draw(img)

    cx = cy = N / 2
    r_outer = N * 0.335        # iris outer edge
    r_open = N * 0.135         # the opening in the middle
    # Rotated so a blade edge is not perfectly horizontal — reads better small.
    phase = math.radians(-12)

    # Iris body.
    draw.ellipse([cx - r_outer, cy - r_outer, cx + r_outer, cy + r_outer],
                 fill=BLADE)

    # Alternate every other blade slightly darker so the blades read as
    # separate plates rather than one flat disc.
    for i in range(BLADES):
        if i % 2:
            continue
        a0 = phase + i * 2 * math.pi / BLADES
        a1 = a0 + 2 * math.pi / BLADES
        pts = [(cx, cy)]
        steps = 24
        for s in range(steps + 1):
            a = a0 + (a1 - a0) * s / steps
            ux, uy = unit(a)
            pts.append((cx + r_outer * ux, cy + r_outer * uy))
        draw.polygon(pts, fill=BLADE_DARK)

    # The hexagonal opening.
    hexagon = []
    for i in range(BLADES):
        a = phase + i * 2 * math.pi / BLADES
        ux, uy = unit(a)
        hexagon.append((cx + r_open * ux, cy + r_open * uy))
    draw.polygon(hexagon, fill=APERTURE)

    # Blade separations: from each opening vertex, continue the hexagon edge
    # outward to the rim. This is what makes it read as an iris rather than a
    # cog — the lines are tangential, not radial.
    #
    # Drawn on their own layer and masked to the iris disc: the lines have to
    # overshoot to reach the rim at every angle, and would otherwise streak
    # across the background.
    sep = max(2, int(N * 0.012))
    lines = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ldraw = ImageDraw.Draw(lines)
    for i in range(BLADES):
        vx, vy = hexagon[i]
        px, py = hexagon[(i - 1) % BLADES]
        dx, dy = vx - px, vy - py
        length = math.hypot(dx, dy)
        dx, dy = dx / length, dy / length
        ldraw.line([(vx, vy), (vx + dx * r_outer * 1.6, vy + dy * r_outer * 1.6)],
                   fill=APERTURE, width=sep)

    disc = Image.new("L", (N, N), 0)
    ImageDraw.Draw(disc).ellipse(
        [cx - r_outer, cy - r_outer, cx + r_outer, cy + r_outer], fill=255)
    img.paste(lines, (0, 0), Image.composite(
        lines.getchannel("A"), Image.new("L", (N, N), 0), disc))

    # Re-punch the opening: the separators cut across it.
    draw.polygon(hexagon, fill=APERTURE)

    # Faint outer rim, so the iris has an edge against the background.
    draw.ellipse([cx - r_outer, cy - r_outer, cx + r_outer, cy + r_outer],
                 outline=RIM, width=max(2, int(N * 0.006)))

    img.putalpha(rounded_rect_mask(N, int(N * 0.18)))
    return img


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    master = build()
    for size in SIZES:
        out = master.resize((size, size), Image.LANCZOS)
        path = os.path.join(OUT_DIR, f"app_icon_{size}.png")
        out.save(path)
        print(f"wrote {path}")


if __name__ == "__main__":
    main()
