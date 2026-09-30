#!/usr/bin/env python3
"""Compose the iStore/LuCI app icon for tailscale-updater.

Takes a base image (square) and stamps a circular "update" badge (a rotating
arrow) in the lower-right corner, then writes a 256x256 PNG suitable for
  /www/luci-static/resources/app-icons/tailscale-updater.png

Usage: make-icon.py <base.png> <out.png>
"""
import math
import sys

from PIL import Image, ImageDraw

SIZE = 256


def polar(cx, cy, r, deg):
    a = math.radians(deg)
    return cx + r * math.cos(a), cy + r * math.sin(a)


def main():
    src, out = sys.argv[1], sys.argv[2]
    im = Image.open(src).convert("RGBA").resize((SIZE, SIZE), Image.LANCZOS)

    # gentle rounded background so it looks intentional on any theme
    bg = Image.new("RGBA", (SIZE, SIZE), (245, 246, 248, 255))
    bg.paste(im, (0, 0), im)
    im = bg

    d = ImageDraw.Draw(im)

    # ---- badge: circular arrow ("update") ----
    cx, cy = 190, 190
    rb = 62
    d.ellipse([cx - rb, cy - rb, cx + rb, cy + rb],
              fill=(25, 118, 210, 255), outline=(255, 255, 255, 255), width=8)

    R = 33
    width = 12
    start, end = 58, 302
    d.arc([cx - R, cy - R, cx + R, cy + R],
          start=start, end=end, fill=(255, 255, 255, 255), width=width)

    # arrowhead at the "end" angle, pointing along the clockwise tangent
    a = math.radians(end)
    tx, ty = -math.sin(a), math.cos(a)          # tangent (increasing angle)
    px, py = -ty, tx                            # perpendicular
    ex, ey = polar(cx, cy, R, end)
    tip = (ex + tx * 26, ey + ty * 26)
    b1 = (ex + px * 15 - tx * 4, ey + py * 15 - ty * 4)
    b2 = (ex - px * 15 - tx * 4, ey - py * 15 - ty * 4)
    d.polygon([tip, b1, b2], fill=(255, 255, 255, 255))

    im.save(out)
    print("wrote", out, im.size)


if __name__ == "__main__":
    main()
