#!/usr/bin/env python3
# ==============================================================================
# Omarchy WSL: Tokyo Night Toast Icon Generator
# tools/generate-notify-icons.py
# ==============================================================================
# Renders the PNG app-logo icons used by bin/omarchy-notify for Windows toast
# notifications. Toast <image> elements accept PNG/JPG/GIF (not ICO/SVG), so
# the icons are rasterised here with the standard library only (zlib + struct),
# keeping the build reproducible and dependency-free.
#
#   python3 tools/generate-notify-icons.py [output-dir]   (default: assets/notify)
# ==============================================================================

import os
import struct
import sys
import zlib

SIZE = 128
SUPERSAMPLE = 4

BACKGROUND = (0x1A, 0x1B, 0x26)
FOREGROUND = (0xC0, 0xCA, 0xF5)
LEVELS = {
    "info": (0x7A, 0xA2, 0xF7),     # blue
    "success": (0x9E, 0xCE, 0x6A),  # green
    "warning": (0xE0, 0xAF, 0x68),  # yellow
    "error": (0xF7, 0x76, 0x8E),    # red
}


def seg_dist(px, py, ax, ay, bx, by):
    """Distance from point P to segment AB."""
    abx, aby = bx - ax, by - ay
    t = ((px - ax) * abx + (py - ay) * aby) / (abx * abx + aby * aby)
    t = max(0.0, min(1.0, t))
    dx, dy = px - (ax + t * abx), py - (ay + t * aby)
    return (dx * dx + dy * dy) ** 0.5


def sample(x, y, accent):
    """Return (r, g, b, a) for a point in a unit (0..1) coordinate system."""
    cx, cy = x - 0.5, y - 0.5
    r = (cx * cx + cy * cy) ** 0.5
    if r > 0.5:
        return (0, 0, 0, 0)
    color = BACKGROUND
    # Accent ring.
    if 0.40 <= r <= 0.48:
        color = accent
    # Terminal prompt chevron ">".
    if seg_dist(x, y, 0.30, 0.34, 0.47, 0.50) <= 0.045 or seg_dist(x, y, 0.47, 0.50, 0.30, 0.66) <= 0.045:
        color = FOREGROUND
    # Cursor underscore in the accent colour.
    if 0.52 <= x <= 0.72 and 0.61 <= y <= 0.68:
        color = accent
    return (*color, 255)


def render(accent):
    rows = []
    n = SUPERSAMPLE
    for py in range(SIZE):
        row = bytearray([0])  # PNG filter type 0
        for px in range(SIZE):
            acc = [0, 0, 0, 0]
            for sy in range(n):
                for sx in range(n):
                    rgba = sample((px + (sx + 0.5) / n) / SIZE, (py + (sy + 0.5) / n) / SIZE, accent)
                    a = rgba[3]
                    acc[0] += rgba[0] * a
                    acc[1] += rgba[1] * a
                    acc[2] += rgba[2] * a
                    acc[3] += a
            alpha = acc[3]
            if alpha:
                row += bytes((acc[0] // alpha, acc[1] // alpha, acc[2] // alpha, alpha // (n * n)))
            else:
                row += b"\x00\x00\x00\x00"
        rows.append(bytes(row))
    return b"".join(rows)


def png(raw):
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0)  # 8-bit RGBA
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "assets", "notify")
    os.makedirs(out, exist_ok=True)
    for level, accent in LEVELS.items():
        path = os.path.join(out, f"omarchy-{level}.png")
        with open(path, "wb") as fh:
            fh.write(png(render(accent)))
        print(path)


if __name__ == "__main__":
    main()
