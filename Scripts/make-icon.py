"""Draws the app icon (a card silhouette on a gradient) as a PPM; sips turns it into PNG."""
import math, subprocess, sys, tempfile, os

size = 1024
out = sys.argv[1]
rows = []
for y in range(size):
    row = bytearray()
    for x in range(size):
        t = (x + y) / (2 * size)
        r, g, b = int(20 + 30 * t), int(28 + 60 * t), int(60 + 120 * t)
        # Card: a rounded 63:88 rectangle, slightly rotated.
        cx, cy = x - size / 2, y - size / 2
        a = math.radians(-12)
        u = cx * math.cos(a) - cy * math.sin(a)
        v = cx * math.sin(a) + cy * math.cos(a)
        w, h, rad = 270, 377, 36
        dx, dy = abs(u) - (w - rad), abs(v) - (h - rad)
        d = math.hypot(max(dx, 0), max(dy, 0)) + min(max(dx, dy), 0) - rad
        if d < 0:
            inner = 0.78 if abs(u) < w - 46 and abs(v) < h - 46 else 1.0
            art = abs(u) < w - 60 and -h + 60 < v < -h + 330
            if art:
                r, g, b = int(220 - 60 * (v + h) / 330), int(140 + 60 * (u + w) / (2 * w)), 80
            else:
                r, g, b = int(245 * inner), int(236 * inner), int(222 * inner)
        elif d < 6:
            r, g, b = 10, 10, 14
        row += bytes((max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b))))
    rows.append(bytes(row))
with tempfile.NamedTemporaryFile(suffix=".ppm", delete=False) as f:
    f.write(b"P6\n%d %d\n255\n" % (size, size))
    for row in rows:
        f.write(row)
    ppm = f.name
subprocess.run(["sips", "-s", "format", "png", ppm, "--out", out], check=True, capture_output=True)
os.unlink(ppm)
print("wrote", out)
