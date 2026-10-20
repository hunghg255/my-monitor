#!/usr/bin/env python3
"""Draws mymonitor's icon: a dark rounded square holding a 13 x 9 grid of
dots, green columns of the CPU's load rising from the bottom over faint
gray ones. Writes assets/icon.png (512 px), assets/icon.ico (16-256 px,
the .exe's and the window's), and beside the code, which embeds them,
src/tray.png (the tray's, dots alone) and src/logo.svg (drawn in the
app). Needs Pillow.
Usage: python tools/make-icon.py"""
import os
from PIL import Image, ImageDraw

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = os.path.join(ROOT, "assets")
SRC = os.path.join(ROOT, "src")
COLS, ROWS = 13, 9
# Green dots in each column, from the bottom.
HEIGHTS = [3, 4, 3, 3, 3, 1, 8, 3, 3, 5, 4, 3, 3]
GREEN = (0x34, 0xc7, 0x59)
GRAY = (0x3b, 0x3e, 0x44)
TOP, BOTTOM = (0x2b, 0x2e, 0x34), (0x17, 0x19, 0x1d)


def grid(size, pad, radius_frac):
    """The dots' centers and radius in a `size` square, `pad` from its sides."""
    pitch = (size - 2 * pad) / (COLS - 1)
    y0 = (size - (ROWS - 1) * pitch) / 2 + pitch * 0.15
    for c in range(COLS):
        for r in range(ROWS):
            level = ROWS - 1 - r
            yield pad + c * pitch, y0 + r * pitch, pitch * radius_frac, level < HEIGHTS[c]


def icon(size):
    s = size * 4  # drawn large, then scaled down smooth
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    m = s * 0.06
    box = (m, m, s - m, s - m)
    mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, s * 0.21, fill=255)
    fill = Image.new("RGBA", (s, s))
    fd = ImageDraw.Draw(fill)
    for y in range(s):
        t = min(1, max(0, (y - m) / (s - 2 * m)))
        fd.line([(0, y), (s, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(TOP, BOTTOM)) + (255,))
    img.paste(fill, (0, 0), mask)
    d = ImageDraw.Draw(img)
    for x, y, r, on in grid(s, s * 0.2, 0.36):
        d.ellipse((x - r, y - r, x + r, y + r), fill=(GREEN if on else GRAY) + (255,))
    return img.resize((size, size), Image.LANCZOS)


def tray(size):
    """The tray's: fewer, larger dots on nothing, green over gray."""
    s = size * 4
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    heights = [2, 3, 2, 5, 3]
    cols, rows = len(heights), 5
    pitch = s / cols
    for c in range(cols):
        for r in range(rows):
            level = rows - 1 - r
            x, y, rad = (c + 0.5) * pitch, (r + 0.5) * pitch, pitch * 0.36
            on = level < heights[c]
            d.ellipse((x - rad, y - rad, x + rad, y + rad), fill=(GREEN + (255,)) if on else (0x9a, 0x9a, 0x9a, 150))
    return img.resize((size, size), Image.LANCZOS)


def svg():
    s = 512
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {s} {s}" width="{s}" height="{s}">',
           '<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1">'
           f'<stop offset="0" stop-color="#{TOP[0]:02x}{TOP[1]:02x}{TOP[2]:02x}"/>'
           f'<stop offset="1" stop-color="#{BOTTOM[0]:02x}{BOTTOM[1]:02x}{BOTTOM[2]:02x}"/></linearGradient></defs>',
           f'<rect x="{s*0.06:.1f}" y="{s*0.06:.1f}" width="{s*0.88:.1f}" height="{s*0.88:.1f}" rx="{s*0.21:.1f}" fill="url(#g)"/>']
    for x, y, r, on in grid(s, s * 0.2, 0.36):
        color = GREEN if on else GRAY
        out.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r:.1f}" fill="#{color[0]:02x}{color[1]:02x}{color[2]:02x}"/>')
    out.append("</svg>")
    return "".join(out)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    big = icon(512)
    big.save(os.path.join(OUT, "icon.png"))
    sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
    icon(256).save(os.path.join(OUT, "icon.ico"), sizes=[(n, n) for n in sizes])
    tray(64).save(os.path.join(SRC, "tray.png"))
    with open(os.path.join(SRC, "logo.svg"), "w") as f:
        f.write(svg())
    print("wrote", ", ".join(["icon.png", "icon.ico", "tray.png", "logo.svg"]))
