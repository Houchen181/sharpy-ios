"""Draws Sharpy's app icon: a freshly sharpened pencil tip with a spark, on indigo.

    python tools/make_icon.py Sharpy/Assets.xcassets/AppIcon.appiconset/icon-1024.png
"""
import math
import sys

from PIL import Image, ImageDraw, ImageFilter

S = 4096  # draw large, downsample for smooth edges


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def background():
    top, bottom = (104, 92, 255), (52, 34, 168)
    n = 256  # paint a small gradient and scale it up; it's smooth either way
    img = Image.new("RGB", (n, n))
    px = img.load()
    for y in range(n):
        for x in range(n):
            px[x, y] = lerp(top, bottom, (x * 0.35 + y * 0.65) / n)
    return img.resize((S, S), Image.BILINEAR)


def rotate_points(points, angle_deg, cx, cy):
    a = math.radians(angle_deg)
    ca, sa = math.cos(a), math.sin(a)
    return [(cx + x * ca - y * sa, cy + x * sa + y * ca) for x, y in points]


def main(out):
    img = background().convert("RGBA")
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    # Pencil drawn pointing up in local coordinates (origin = icon centre), then tilted.
    angle = 45  # tip towards the upper right
    cx, cy = S * 0.47, S * 0.55
    half = 420           # half-width of the pencil body
    collar = 380         # y where the sharpened cone meets the body
    tip = -1250          # y of the very tip
    lead = -720          # y where the graphite starts
    bottom = 3000        # body runs off the canvas

    def poly(points, fill):
        d.polygon(rotate_points(points, angle, cx, cy), fill=fill)

    # Body: three facets.
    poly([(-half, collar), (-half / 3, collar), (-half / 3, bottom), (-half, bottom)], (236, 233, 255))
    poly([(-half / 3, collar), (half / 3, collar), (half / 3, bottom), (-half / 3, bottom)], (255, 255, 255))
    poly([(half / 3, collar), (half, collar), (half, bottom), (half / 3, bottom)], (214, 209, 250))

    # Sharpened wood cone.
    poly([(-half, collar), (half, collar), (0, tip)], (255, 229, 196))
    # Scalloped edge where the blade cut the paint.
    n = 6
    for i in range(n):
        x0 = -half + i * (2 * half / n)
        x1 = x0 + 2 * half / n
        poly([(x0, collar), (x1, collar), ((x0 + x1) / 2, collar - 120)], (255, 229, 196))
    # Graphite tip.
    w = half * (lead - tip) / (collar - tip)
    poly([(-w, lead), (w, lead), (0, tip)], (40, 33, 92))

    # Soft shadow under the pencil.
    shadow = layer.split()[3].filter(ImageFilter.GaussianBlur(60))
    shadow_img = Image.new("RGBA", (S, S), (20, 10, 70, 0))
    shadow_img.putalpha(shadow.point(lambda a: int(a * 0.35)))
    img.alpha_composite(shadow_img, (40, 80))
    img.alpha_composite(layer)

    # Four-point spark just beyond the tip.
    sx, sy = rotate_points([(0, tip - 520)], angle, cx, cy)[0]
    spark = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sd = ImageDraw.Draw(spark)
    r_long, r_short = 330, 85
    pts = []
    for k in range(8):
        r = r_long if k % 2 == 0 else r_short
        a = math.radians(k * 45 - 90)
        pts.append((sx + r * math.cos(a), sy + r * math.sin(a)))
    sd.polygon(pts, fill=(255, 196, 61))
    glow = spark.split()[3].filter(ImageFilter.GaussianBlur(90))
    glow_img = Image.new("RGBA", (S, S), (255, 200, 80, 0))
    glow_img.putalpha(glow.point(lambda a: int(a * 0.6)))
    img.alpha_composite(glow_img)
    img.alpha_composite(spark)

    img.convert("RGB").resize((1024, 1024), Image.LANCZOS).save(out)


if __name__ == "__main__":
    main(sys.argv[1])
