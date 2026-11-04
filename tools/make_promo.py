#!/usr/bin/env python3
"""Render "Sharpen", Sharpy's 2-minute animated promo film (1920x1080, 30 fps).

    python tools/make_promo.py --tour <dir with raw.mp4, marks.txt, rec_start.txt> \
        --icon Sharpy/Assets.xcassets/AppIcon.appiconset/icon-1024.png \
        --out marketing/sharpy-promo-1920x1080.mp4

The story is marketing/sharpy-promo-film-script.md, told without actors: a top-down
world of flat objects (the white pencil from the app icon, phones, a meeting table, a
living room), speech bubbles for dialogue and on-screen narration instead of a voice.
The three phone inserts are real footage from the CI tour, as in the intro video.
Music and sound effects are synthesized by tools/promo_audio.py.

    --still 12.5,40   renders single frames as PNGs next to --out instead.

Requires Pillow and numpy; ffmpeg from $FFMPEG, imageio-ffmpeg, or PATH.
"""
import argparse
import functools
import math
import os
import subprocess
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_intro as mi  # noqa: E402
import promo_audio  # noqa: E402
from make_intro import FPS, H, W, ease, ease_back, font, put, text_layer, wrap  # noqa: E402

INK = (32, 28, 50)
WHITE = (255, 255, 255)
GOLD = (255, 196, 61)
FACETS = [(236, 233, 255), (255, 255, 255), (214, 209, 250)]   # the icon pencil's three faces
SS = 3                                                          # supersampling for drawn shapes

# Scene lengths in seconds; they add up to 2:00. Comments give the script's shot names.
SCENES = [
    ("s1", 4.0),      # the sharp pencil
    ("s2", 5.5),      # breakfast
    ("s3", 5.5),      # work things
    ("s4", 8.0),      # weeks go by
    ("s5", 7.0),      # the question
    ("s6", 3.0),      # under the table
    ("s7", 7.0),      # confidently wrong
    ("s8", 7.0),      # why is the sky blue?
    ("s9", 4.5),      # "you don't know?"
    ("s10", 6.0),     # 1 a.m.
    ("s11", 5.0),     # dull
    ("s12", 4.0),     # today's trap
    ("ins_a", 4.0),   # app: your field
    ("s13", 3.5),     # the reflex
    ("s14", 5.0),     # sharpen
    ("ins_b", 8.0),   # app: the trap she fell for
    ("s15", 6.0),     # days, again
    ("ins_c", 3.5),   # app: streak
    ("s16", 7.0),     # the mirror
    ("s17", 7.0),     # the sky
    ("s18", 4.5),     # sharp, into the icon
    ("end", 5.0),
]
STARTS = {}
_t = 0.0
for _name, _d in SCENES:
    STARTS[_name] = _t
    _t += _d
TOTAL = _t

# Chat traffic in "weeks go by": (seconds into the shot, prompt). Faster and faster.
S4_PROMPTS = [
    (0.5, "Reply to Sam for me"), (1.4, "What's 15% of 80?"), (2.18, "Plan my weekend"),
    (2.84, "Is this a good idea?"), (3.4, "Summarize this book"), (3.88, "What should I text him?"),
    (4.3, "Write my bio"), (4.66, "Explain it like I'm five"), (4.98, "Which one is right?"),
    (5.26, "Just tell me the answer"), (6.0, "What do I think about this?"),
]
NOTES_S15 = [
    "Fed: 1913, not the 1930s", "Plasma cells make antibodies", "Fed goals: jobs, prices, rates",
    "Antibiotics don't kill viruses", "Holevo bound", "Sky: air scatters blue",
]
FED_NOTES = ("ECON 201 · Lecture 4", "The Fed", "- Federal Reserve Act, 1913", "- after the Panic of 1907",
             "- dual mandate: max employment", "   + stable prices")

# Sound cues: (seconds into the scene, kind, params). promo_audio turns them into sound.
CUES = {
    "s1": [(0.8, "whoosh", {}), (2.0, "chime", {"notes": (83, 90)})],
    "s2": [(0.3, "taps", {"dur": 1.2}), (1.65, "pop", {}), (2.9, "ping", {})],
    "s3": [(0.2, "taps", {"dur": 0.7}), (1.0, "pop", {}), (2.0, "ping", {}), (3.1, "pop", {})],
    "s4": [c for at, _ in S4_PROMPTS for c in ((at, "pop", {}), (at + 0.22, "ping", {"pitch": 84 + int(at * 1.3)}))],
    "s5": [(0.4, "pop", {}), (3.0, "pop", {"gain": 0.6})] + [(2.6 + k, "tick", {"high": k % 2 == 0}) for k in range(5)],
    "s6": [(0.0, "taps", {"dur": 0.8, "rate": 16}), (0.9, "pop", {})] + [(0.6 + k, "tick", {"high": k % 2 == 1}) for k in range(3)],
    "s7": [(0.2, "pop", {}), (0.6, "tick", {"high": True}), (1.6, "tick", {"high": False}),
           (2.6, "tick", {"high": True}), (2.75, "pop", {}), (2.8, "thud", {}), (3.3, "scribble", {"dur": 0.5})],
    "s8": [(0.4, "pop", {}), (2.4, "whoosh", {}), (3.5, "click", {}), (4.4, "click", {})],
    "s9": [(0.35, "pop", {}), (2.1, "pop", {})],
    "s10": [(0.6, "whoosh", {"dur": 0.8})],
    "s11": [(0.7, "puff", {})],
    "s12": [(0.3, "buzz", {"dur": 0.6}), (0.85, "chime", {"notes": (79, 86)}), (1.25, "buzz", {"dur": 0.4})],
    "ins_a": [(0.2, "taps", {"dur": 2.2, "rate": 9})],
    "s13": [(0.15, "taps", {"dur": 1.3}), (2.0, "taps", {"dur": 0.7, "rate": 20})],
    "s14": [(0.0, "whoosh", {"dur": 0.5}), (0.6, "grind", {"dur": 2.4}), (3.0, "whoosh", {"dur": 0.45}),
            (3.7, "sparkle", {})],
    "ins_b": [(3.9, "correct", {})],
    "s15": [c for k in range(6) for c in ((k + 0.05, "whoosh", {"dur": 0.3, "gain": 0.35}),
                                         (k + 0.3, "scribble", {"dur": 0.55, "seed": k}))],
    "ins_c": [(0.25, "chime", {"notes": (88, 95)})],
    "s16": [(0.3, "pop", {}), (2.4, "pop", {}), (4.7, "pop", {})],
    "s17": [(0.3, "scribble", {"dur": 4.3, "seed": 9}), (0.5, "pop", {}), (4.8, "pop", {}), (4.85, "sparkle", {})],
    "s18": [(1.4, "sparkle", {}), (3.55, "whoosh", {"dur": 0.6})],
}


# ---------- small helpers ----------

def clamp(x, lo=0.0, hi=1.0):
    return lo if x < lo else hi if x > hi else x


def prog(t, a, b):
    return clamp((t - a) / (b - a))


def smooth(x):
    x = clamp(x)
    return x * x * (3 - 2 * x)


def mix(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def hand(size):
    return ImageFont.truetype(os.path.join(mi.FONT_DIR, "Inkfree.ttf"), size)


def drawn(w, h, fn):
    """Draw at SS x and downsample: antialiasing for Pillow's hard-edged shapes.
    fn(draw, k) gets the scale k to multiply its coordinates by."""
    big = Image.new("RGBA", (max(1, round(w * SS)), max(1, round(h * SS))), (0, 0, 0, 0))
    fn(ImageDraw.Draw(big), SS)
    return big.resize((max(1, round(w)), max(1, round(h))), Image.LANCZOS)


def drop_shadow(alpha, dx=10, dy=16, blur=16, strength=0.42):
    pad = blur * 2 + max(abs(dx), abs(dy))
    m = Image.new("L", (alpha.width + 2 * pad, alpha.height + 2 * pad), 0)
    m.paste(alpha.point(lambda v: int(v * strength)), (pad + dx, pad + dy))
    img = Image.new("RGBA", m.size, (26, 16, 8, 0))
    img.putalpha(m.filter(ImageFilter.GaussianBlur(blur)))
    return img, pad


class Sprite:
    """An object image with its soft drop shadow, drawn by its centre."""

    def __init__(self, img, shadow=(10, 16, 16, 0.42)):
        self.w, self.h = img.size
        if shadow:
            sh, pad = drop_shadow(img.getchannel("A"), *shadow)
            sh.alpha_composite(img, (pad, pad))
            self.img = sh
        else:
            self.img = img

    def draw(self, canvas, cx, cy, alpha=1.0, scale=1.0):
        img = self.img
        if abs(scale - 1) > 0.002:
            img = img.resize((max(1, round(img.width * scale)), max(1, round(img.height * scale))), Image.BICUBIC)
        put(canvas, img, cx - img.width / 2, cy - img.height / 2, alpha)


def zoom(img, z, cx=W / 2, cy=H / 2):
    if z <= 1.0005:
        return img
    w, h = W / z, H / z
    x0 = min(max(cx - w / 2, 0), W - w)
    y0 = min(max(cy - h / 2, 0), H - h)
    return img.resize((W, H), Image.BICUBIC, box=(x0, y0, x0 + w, y0 + h))


_BLUE = Image.new("RGB", (W, H), (58, 78, 120))
_AMBER = Image.new("RGB", (W, H), (255, 184, 96))


def grade(img, cold=0.0, warm=0.0):
    """Act 2 drains colour toward a cold blue-grey; act 3 warms it."""
    if cold > 0.002:
        img = ImageEnhance.Color(img).enhance(1 - 0.6 * cold)
        img = Image.blend(img, _BLUE, 0.15 * cold)
        img = ImageEnhance.Brightness(img).enhance(1 - 0.1 * cold)
    if warm > 0.002:
        img = Image.blend(img, _AMBER, 0.06 * warm)
        img = ImageEnhance.Color(img).enhance(1 + 0.12 * warm)
    return img


@functools.lru_cache(maxsize=None)
def vignette_mask(strength):
    g = Image.radial_gradient("L").resize((W, H), Image.BILINEAR)
    return g.point(lambda v: int(clamp((v - 70) / 185) ** 1.6 * 255 * strength))


def vignette(img, strength):
    img.paste((0, 0, 0), (0, 0), vignette_mask(round(strength, 2)))
    return img


@functools.lru_cache(maxsize=None)
def glow_img(r, color):
    g = Image.radial_gradient("L").resize((2 * r, 2 * r), Image.BILINEAR)
    img = Image.new("RGBA", (2 * r, 2 * r), color + (0,))
    img.putalpha(g.point(lambda v: int((max(0, 255 - v) / 255) ** 2 * 255)))
    return img


def glow(canvas, cx, cy, r, color, alpha):
    if alpha > 0.004:
        put(canvas, glow_img(int(r), color), cx - int(r), cy - int(r), alpha)


@functools.lru_cache(maxsize=None)
def beam_mask():
    m = Image.new("L", (W * 2, H), 0)
    slant = H * 0.55
    ImageDraw.Draw(m).polygon([(W - 230, 0), (W + 230, 0), (W + 230 - slant, H), (W - 230 - slant, H)], fill=255)
    return m.filter(ImageFilter.GaussianBlur(110))


def sunbeam(canvas, pos, strength, color=(255, 240, 205)):
    """A soft diagonal shaft of light; pos 0..1 slides it across the frame."""
    if strength <= 0.01:
        return
    x0 = int(W - (300 + pos * 1600))
    m = beam_mask().crop((x0, 0, x0 + W, H)).point(lambda v: int(v * strength * 0.3))
    canvas.paste(color, (0, 0), m)


MOTES = np.random.default_rng(11).random((46, 4))


def motes(canvas, t, pos, strength):
    """Dust motes that glint only inside the sunbeam."""
    bm = beam_mask()
    x0 = int(W - (300 + pos * 1600))
    for a, b, c, e in MOTES:
        x = (a * W + 30 * math.sin(t * 0.4 + 6 * c)) % W
        y = (b * H - t * (8 + 14 * e)) % H
        inside = bm.getpixel((int(x + x0), int(y))) / 255
        alpha = inside * strength * (0.55 + 0.45 * math.sin(3 * t + 9 * c))
        if alpha > 0.03:
            glow(canvas, x, y, 4 + int(4 * e), (255, 248, 228), alpha)


def wood(w, h, base, seed, contrast=0.1, vertical=False, plank=0):
    if vertical:
        return wood(h, w, base, seed, contrast, False, plank).transpose(Image.ROTATE_90)
    rng = np.random.default_rng(seed)

    def field(rows, cols):
        a = (rng.random((rows, cols)) * 255).astype(np.uint8)
        return np.asarray(Image.fromarray(a, "L").resize((w, h), Image.BICUBIC), np.float32) / 255 - 0.5

    low, fine = field(max(2, h // 7), 8), field(max(2, h // 2), 30)
    y = np.arange(h, dtype=np.float32)[:, None]
    v = 0.8 * low + 0.45 * fine + 0.3 * np.sin(y * 0.09 + low * 10)
    if plank:
        v = v - 0.9 * ((np.arange(h)[:, None] % plank) < 3)
    rgb = np.array(base, np.float32)[None, None, :] * (1 + contrast * v[..., None])
    return Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8), "RGB")


def carpet(base, seed):
    n = np.random.default_rng(seed).normal(0, 1, (H, W))
    n = np.asarray(Image.fromarray(np.clip(n * 40 + 128, 0, 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(0.8)),
                   np.float32) / 255 - 0.5
    rgb = np.array(base, np.float32)[None, None, :] * (1 + 0.16 * n[..., None])
    return Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8), "RGB")


def lines_layer(lines, fnt, fill, align="left", spacing=1.18):
    probe = ImageDraw.Draw(Image.new("L", (1, 1)))
    lh = round(fnt.size * spacing)
    widths = [probe.textlength(l, font=fnt) for l in lines]
    img = Image.new("RGBA", (int(max(widths)) + 8, lh * len(lines) + round(fnt.size * 0.35)), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    for i, (l, w) in enumerate(zip(lines, widths)):
        x = (img.width - w) / 2 if align == "center" else 0
        d.text((x, i * lh), l, font=fnt, fill=fill)
    return img


# ---------- objects ----------

@functools.lru_cache(maxsize=96)
def pencil_flat(L, T, state="sharp", dust=0.0, phase=0.0):
    """Sharpy's white hexagonal pencil from above, tip to the right. "broken" snaps the
    point off; dust greys it; phase turns it (for the sharpener)."""
    C = T * 1.3
    lead = C * 0.3
    be = L - C
    j, f = int(phase * 3) % 3, (phase * 3) % 1
    cols = [mix(FACETS[(i + j) % 3], FACETS[(i + j + 1) % 3], f) for i in range(3)]
    tip_x = L if state == "sharp" else L - lead * 1.15
    hw = (L - tip_x) / C * T / 2

    def fn(d, k):
        for i in range(3):
            d.rectangle((0, T * i / 3 * k, be * k, T * (i + 1) / 3 * k), fill=cols[i] + (255,))
        d.rectangle((0, 0, 4 * k, T * k), fill=(198, 194, 226, 255))
        d.polygon([(be * k, 0), (tip_x * k, (T / 2 - hw) * k), (tip_x * k, T / 2 * k), (be * k, T / 2 * k)],
                  fill=(255, 228, 194, 255))
        d.polygon([(be * k, T / 2 * k), (tip_x * k, T / 2 * k), (tip_x * k, (T / 2 + hw) * k), (be * k, T * k)],
                  fill=(238, 204, 164, 255))
        for i in range(3):
            y0, y1 = T * i / 3, T * (i + 1) / 3
            d.polygon([(be * k, y0 * k), (be * k, y1 * k), ((be + C * 0.2) * k, (y0 + y1) / 2 * k)], fill=cols[i] + (255,))
        if state == "sharp":
            lx, lw = L - lead, lead / C * T / 2
            d.polygon([(lx * k, (T / 2 - lw) * k), (L * k, T / 2 * k), (lx * k, T / 2 * k)], fill=(100, 98, 116, 255))
            d.polygon([(lx * k, T / 2 * k), (L * k, T / 2 * k), (lx * k, (T / 2 + lw) * k)], fill=(56, 54, 68, 255))
        else:
            d.polygon([(tip_x * k, (T / 2 - hw) * k), ((tip_x + hw * 0.4) * k, (T / 2 - hw * 0.5) * k),
                       ((tip_x + hw * 0.1) * k, (T / 2 - hw * 0.05) * k), ((tip_x + hw * 0.45) * k, (T / 2 + hw * 0.35) * k),
                       (tip_x * k, (T / 2 + hw) * k)], fill=(246, 214, 178, 255))
            r0, r1 = hw * 0.32, hw * 0.48
            d.ellipse(((tip_x + 0.1 * hw - r0) * k, (T / 2 - r1) * k, (tip_x + 0.1 * hw + r0) * k, (T / 2 + r1) * k),
                      fill=(60, 58, 72, 255))

    img = drawn(L, T, fn)
    return dusty(img, dust) if dust > 0 else img


@functools.lru_cache(maxsize=8)
def speck_field(w, h):
    return np.random.default_rng(5).random((h, w)).astype(np.float32)


def dusty(img, amount):
    a = np.asarray(img.getchannel("A"), np.float32) / 255
    speck = (speck_field(img.width, img.height) < 0.10 * amount).astype(np.float32)
    film = np.clip(a * 0.45 * amount + speck * a * 0.9, 0, 1)
    layer = Image.new("RGBA", img.size, (168, 164, 158, 0))
    layer.putalpha(Image.fromarray((film * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(0.6)))
    out = img.copy()
    out.alpha_composite(layer)
    return out


@functools.lru_cache(maxsize=160)
def pencil(L, T, angle, state="sharp", dust=0.0, phase=0.0):
    """(Sprite, (dx, dy) from the sprite's centre to the tip). angle in degrees, CCW."""
    flat = pencil_flat(L, T, state, round(dust * 20) / 20, round(phase * 24) / 24)
    rot = flat.rotate(angle, resample=Image.BICUBIC, expand=True) if angle else flat
    tip_x = L if state == "sharp" else L - T * 1.3 * 0.3 * 1.15
    a = math.radians(angle)
    dx = tip_x - L / 2
    sh = (max(4, T // 6), max(6, T // 4), max(6, T // 5), 0.45)
    return Sprite(rot, sh), (dx * math.cos(a), -dx * math.sin(a))


@functools.lru_cache(maxsize=None)
def spark_base(size=400):
    def fn(d, k):
        c, R = size * k / 2, size * k * 0.46
        d.polygon([(c + (R if i % 2 == 0 else R * 0.2) * math.cos(math.pi / 4 * i),
                    c - (R if i % 2 == 0 else R * 0.2) * math.sin(math.pi / 4 * i)) for i in range(8)], fill=GOLD + (255,))
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.alpha_composite(glow_img(size // 2, (255, 214, 120)))
    out.alpha_composite(drawn(size, size, fn))
    return out


def spark(canvas, x, y, size, alpha=1.0, rot=0.0):
    if size < 3:
        return
    img = spark_base().resize((round(size), round(size)), Image.BICUBIC)
    if rot:
        img = img.rotate(rot, resample=Image.BICUBIC)
    put(canvas, img, x - size / 2, y - size / 2, alpha)


class Handset:
    """A phone seen from above; the screen image is supplied per frame."""

    def __init__(self, w):
        self.w, self.h = w, round(w * 2.05)
        self.m = max(3, round(w * 0.042))
        self.sw, self.sh = self.w - 2 * self.m, self.h - 2 * self.m
        r = w * 0.16

        def body(d, k):
            d.rounded_rectangle((0, 0, self.w * k - 1, self.h * k - 1), radius=r * k, fill=(24, 24, 30, 255))
            d.rounded_rectangle((1.5 * k, 1.5 * k, (self.w - 1.5) * k, (self.h - 1.5) * k), radius=(r - 1.5) * k,
                                outline=(96, 96, 112, 255), width=max(1, round(1.6 * k)))

        def hole(d, k):
            d.rounded_rectangle((0, 0, self.sw * k - 1, self.sh * k - 1), radius=(r - self.m) * k, fill=(255, 255, 255, 255))

        self.body = drawn(self.w, self.h, body)
        self.mask = drawn(self.sw, self.sh, hole).getchannel("A")
        g = np.linspace(1, 0, self.sh)[:, None] * np.linspace(1, 0.2, self.sw)[None, :]
        self.sheen = Image.new("RGBA", (self.sw, self.sh), (255, 255, 255, 0))
        self.sheen.putalpha(Image.fromarray((np.clip(g, 0, 1) * 20).astype(np.uint8)))
        self.shadows = {}

    def image(self, screen):
        if screen.size != (self.sw, self.sh):
            screen = screen.resize((self.sw, self.sh), Image.LANCZOS)
        scr = screen.convert("RGBA")
        scr.alpha_composite(self.sheen)
        img = self.body.copy()
        img.paste(scr, (self.m, self.m), self.mask)
        return img

    def draw(self, canvas, screen, cx, cy, angle=0.0, scale=1.0, alpha=1.0):
        img = self.image(screen)
        if abs(scale - 1) > 0.002:
            img = img.resize((round(img.width * scale), round(img.height * scale)), Image.LANCZOS)
        if abs(angle) > 0.01:
            img = img.rotate(angle, resample=Image.BICUBIC, expand=True)
        key = (round(angle * 2) / 2, round(scale, 2))
        if key not in self.shadows:
            self.shadows[key] = drop_shadow(img.getchannel("A"), 12, 20, 20, 0.5)
        sh, pad = self.shadows[key]
        put(canvas, sh, cx - img.width / 2 - pad, cy - img.height / 2 - pad, alpha)
        put(canvas, img, cx - img.width / 2, cy - img.height / 2, alpha)


def phone_back(w):
    h, r = round(w * 2.05), w * 0.16

    def fn(d, k):
        d.rounded_rectangle((0, 0, w * k - 1, h * k - 1), radius=r * k, fill=(48, 48, 56, 255))
        d.rounded_rectangle((1.5 * k, 1.5 * k, (w - 1.5) * k, (h - 1.5) * k), radius=(r - 1.5) * k,
                            outline=(100, 100, 114, 255), width=max(1, round(1.6 * k)))
        b, x0 = w * 0.42, w * 0.08
        d.rounded_rectangle((x0 * k, x0 * k, (x0 + b) * k, (x0 + b) * k), radius=b * 0.28 * k, fill=(36, 36, 42, 255))
        for u, v in [(0.3, 0.3), (0.3, 0.72), (0.72, 0.5)]:
            cx, cy, rr = (x0 + b * u) * k, (x0 + b * v) * k, b * 0.17 * k
            d.ellipse((cx - rr, cy - rr, cx + rr, cy + rr), fill=(84, 84, 96, 255))
            d.ellipse((cx - rr * 0.62, cy - rr * 0.62, cx + rr * 0.62, cy + rr * 0.62), fill=(14, 14, 18, 255))

    return Sprite(drawn(w, h, fn), (8, 12, 12, 0.45))


def dark_screen(w, h, battery=0.0):
    img = Image.new("RGB", (w, h), (9, 9, 12))
    if battery > 0.01:
        bw, bh = w * 0.36, w * 0.18

        def fn(d, k):
            x0, y0 = (w - bw) / 2, (h - bh) / 2
            d.rounded_rectangle((x0 * k, y0 * k, (x0 + bw) * k, (y0 + bh) * k), radius=bh * 0.22 * k,
                                outline=(235, 235, 240, 255), width=round(w * 0.012 * k))
            d.rounded_rectangle(((x0 + bw) * k, (y0 + bh * 0.3) * k, (x0 + bw + w * 0.025) * k, (y0 + bh * 0.7) * k),
                                radius=w * 0.01 * k, fill=(235, 235, 240, 255))
            d.rounded_rectangle(((x0 + w * 0.03) * k, (y0 + w * 0.03) * k, (x0 + w * 0.07) * k, (y0 + bh - w * 0.03) * k),
                                radius=w * 0.006 * k, fill=(240, 58, 58, 255))

        put(img, drawn(w, h, fn), 0, 0, battery)
    return img


class Chat:
    """A generic AI assistant's chat screen (deliberately no real product's look)."""
    BG = (246, 247, 250)

    def __init__(self, w, h):
        self.w, self.h, self.u = w, h, w / 420
        u = self.u
        self.f_msg = font("regular", round(25 * u))
        self.f_title = font("bold", round(24 * u))
        self.f_input = font("regular", round(23 * u))
        self.f_status = font("semibold", round(15 * u))
        self.base = self._base()
        self.cache = {}
        self.dots_base = drawn(76 * u, 44 * u, lambda d, k: d.rounded_rectangle(
            (0, 0, 76 * u * k - 1, 44 * u * k - 1), radius=20 * u * k, fill=(255, 255, 255, 255),
            outline=(224, 226, 232, 255), width=round(1.2 * u * k)))

    def orb(self, s, dim=0.0):
        g = mi.gradient(s, s, mix((96, 214, 236), (120, 124, 136), dim), mix((138, 92, 246), (90, 92, 104), dim))
        m = drawn(s, s, lambda d, k: d.ellipse((0, 0, s * k - 1, s * k - 1), fill=(255, 255, 255, 255))).getchannel("A")
        g = g.convert("RGBA")
        g.putalpha(m)
        return g

    def _base(self):
        u = self.u
        img = Image.new("RGB", (self.w, self.h), self.BG)
        d = ImageDraw.Draw(img)
        d.text((30 * u, 13 * u), "9:41", font=self.f_status, fill=(20, 20, 24))
        d.rounded_rectangle((self.w / 2 - 52 * u, 10 * u, self.w / 2 + 52 * u, 38 * u), radius=14 * u, fill=(0, 0, 0))
        bx = self.w - 58 * u
        d.rounded_rectangle((bx, 17 * u, bx + 26 * u, 30 * u), radius=3 * u, outline=(20, 20, 24), width=max(1, round(1.5 * u)))
        d.rectangle((bx + 3 * u, 20 * u, bx + 19 * u, 27 * u), fill=(20, 20, 24))
        for i in range(4):
            d.rectangle((bx - 36 * u + i * 6 * u, 29 * u - (i + 1) * 3 * u, bx - 32 * u + i * 6 * u, 29 * u), fill=(20, 20, 24))
        orb = self.orb(round(38 * u))
        img.paste(orb, (round(24 * u), round(60 * u)), orb)
        d.text((74 * u, 64 * u), "Assistant", font=self.f_title, fill=(24, 26, 34))
        d.line((0, 112 * u, self.w, 112 * u), fill=(226, 228, 234), width=max(1, round(u)))
        return img

    def bubble(self, role, text):
        key = (role, text)
        if key in self.cache:
            return self.cache[key]
        u = self.u
        padx, pady, maxw = 17 * u, 12 * u, 320 * u
        user = role == "user"
        fill = (52, 64, 84, 255) if user else (255, 255, 255, 255)
        ink = (255, 255, 255) if user else (28, 30, 38)
        line = (224, 226, 232, 255)
        if text.startswith("[[bars:"):
            n = int(text[7:-2])
            bw, bh = maxw, pady * 2 + n * 20 * u - 6 * u
            img = drawn(bw, bh, lambda d, k: d.rounded_rectangle((0, 0, bw * k - 1, bh * k - 1), radius=18 * u * k,
                                                                    fill=fill, outline=line, width=round(1.2 * u * k)))
            d = ImageDraw.Draw(img)
            for i, f in enumerate([0.92, 0.8, 0.88, 0.62, 0.86, 0.7][:n]):
                y = pady + i * 20 * u
                d.rounded_rectangle((padx, y, padx + (bw - 2 * padx) * f, y + 9 * u), radius=4 * u, fill=(214, 218, 226))
        elif text.startswith("[[doc:"):
            name = text[6:-2]
            bw, bh = 250 * u, 64 * u
            img = drawn(bw, bh, lambda d, k: d.rounded_rectangle((0, 0, bw * k - 1, bh * k - 1), radius=18 * u * k, fill=fill))
            d = ImageDraw.Draw(img)
            d.rounded_rectangle((14 * u, 12 * u, 46 * u, 52 * u), radius=5 * u, fill=(236, 240, 246))
            d.rectangle((20 * u, 22 * u, 40 * u, 25 * u), fill=(220, 72, 72))
            for i in range(3):
                d.rectangle((20 * u, (31 + i * 6) * u, 40 * u, (33 + i * 6) * u), fill=(170, 176, 190))
            d.text((58 * u, 11 * u), name, font=font("semibold", round(19 * u)), fill=WHITE)
            d.text((58 * u, 35 * u), "PDF · 14 pages", font=font("regular", round(15 * u)), fill=(190, 198, 214))
        elif text.startswith("[[emoji:"):
            ch = text[8:-2]
            s = round(54 * u)
            img = Image.new("RGBA", (s + 8, s + 12), (0, 0, 0, 0))
            ImageDraw.Draw(img).text((2, 0), ch, font=font("emoji", round(44 * u)), embedded_color=True)
        else:
            lines = wrap(text, self.f_msg, maxw - 2 * padx)
            probe = ImageDraw.Draw(Image.new("L", (1, 1)))
            lh = 33 * u
            bw = max(probe.textlength(l, font=self.f_msg) for l in lines) + 2 * padx
            bh = len(lines) * lh + 2 * pady
            img = drawn(bw, bh, lambda d, k: d.rounded_rectangle((0, 0, bw * k - 1, bh * k - 1), radius=18 * u * k,
                                                                    fill=fill, outline=None if user else line,
                                                                    width=round(1.2 * u * k)))
            d = ImageDraw.Draw(img)
            for i, l in enumerate(lines):
                d.text((padx, pady - 2 * u + i * lh), l, font=self.f_msg, fill=ink)
        self.cache[key] = img
        return img

    def dots(self, now):
        img = self.dots_base.copy()
        d = ImageDraw.Draw(img)
        u = self.u
        for i in range(3):
            ph = 0.5 + 0.5 * math.sin(now * 7.5 - i * 0.9)
            r = (4.0 + 1.6 * ph) * u
            cx, cy = (22 + i * 16) * u, 22 * u - ph * 3 * u
            d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=mix((204, 208, 216), (116, 122, 136), ph))
        return img

    def render(self, msgs, now, typed="", caret=False, dim=0.0):
        """msgs: (role, text, appear_at[, gone_at]); "[[dots]]" is the typing indicator."""
        u = self.u
        img = self.base.copy()
        items = []
        for m in msgs:
            role, text, t0 = m[0], m[1], m[2]
            if now < t0 or (len(m) > 3 and now >= m[3]):
                continue
            p = ease((now - t0) / 0.22)
            items.append((self.dots(now) if text == "[[dots]]" else self.bubble(role, text), role, p))
        y = self.h - 104 * u
        for bimg, role, p in reversed(items):
            y -= bimg.height * p
            if y + bimg.height < 100 * u:
                break
            x = self.w - 16 * u - bimg.width if role == "user" else 16 * u
            put(img, bimg, x, y, p)
            y -= 10 * u * p
        img.paste(self.base.crop((0, 0, self.w, round(113 * u))), (0, 0))
        if dim:
            d = ImageDraw.Draw(img)
            orb = self.orb(round(38 * u), dim)
            d.rectangle((20 * u, 56 * u, 66 * u, 102 * u), fill=self.BG)
            img.paste(orb, (round(24 * u), round(60 * u)), orb)
        self._input(img, typed, caret, now)
        return img

    def _input(self, img, text, caret, now):
        u = self.u
        d = ImageDraw.Draw(img)
        y0, y1 = self.h - 92 * u, self.h - 40 * u
        d.rounded_rectangle((16 * u, y0, self.w - 70 * u, y1), radius=26 * u, fill=(255, 255, 255),
                            outline=(222, 224, 230), width=max(1, round(1.2 * u)))
        shown, color = (text, (24, 26, 34)) if text else ("Ask anything", (160, 164, 174))
        maxw = self.w - 70 * u - 50 * u
        while d.textlength(shown, font=self.f_input) > maxw and len(shown) > 1:
            shown = shown[1:]
        d.text((34 * u, y0 + 13 * u), shown, font=self.f_input, fill=color)
        if caret and (now * 1.8) % 1 < 0.6:
            x = 34 * u + (d.textlength(shown, font=self.f_input) if text else 0) + 2 * u
            d.rectangle((x, y0 + 14 * u, x + 2.4 * u, y1 - 14 * u), fill=(60, 110, 240))
        cx, cy, r = self.w - 40 * u, (y0 + y1) / 2, 22 * u
        d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(52, 64, 84) if text else (204, 208, 216))
        d.polygon([(cx, cy - 10 * u), (cx - 8 * u, cy - 1 * u), (cx + 8 * u, cy - 1 * u)], fill=WHITE)
        d.rectangle((cx - 2 * u, cy - 3 * u, cx + 2 * u, cy + 10 * u), fill=WHITE)


def mug(kind="full", s=1.0):
    def fn(d, k):
        q = s * k
        d.rounded_rectangle((110 * q, 50 * q, 166 * q, 80 * q), radius=13 * q, outline=(236, 234, 230, 255), width=round(11 * q))
        d.ellipse((5 * q, 5 * q, 125 * q, 125 * q), fill=(244, 242, 238, 255))
        d.ellipse((13 * q, 13 * q, 117 * q, 117 * q), fill=(224, 220, 214, 255))
        if kind == "full":
            d.ellipse((20 * q, 20 * q, 110 * q, 110 * q), fill=(98, 62, 40, 255))
            d.ellipse((36 * q, 32 * q, 64 * q, 46 * q), fill=(146, 104, 74, 255))
        else:
            d.ellipse((20 * q, 20 * q, 110 * q, 110 * q), fill=(236, 230, 222, 255))
            d.ellipse((30 * q, 34 * q, 104 * q, 108 * q), outline=(176, 136, 104, 255), width=round(4 * q))

    return Sprite(drawn(172 * s, 130 * s, fn), (6, 10, 10, 0.4))


@functools.lru_cache(maxsize=None)
def calendar(day, month):
    w, h = 176, 196

    def fn(d, k):
        d.rounded_rectangle((0, 0, w * k - 1, h * k - 1), radius=16 * k, fill=(252, 252, 250, 255))
        d.rounded_rectangle((0, 0, w * k - 1, 58 * k), radius=16 * k, fill=(226, 74, 70, 255))
        d.rectangle((0, 36 * k, w * k - 1, 58 * k), fill=(226, 74, 70, 255))

    img = drawn(w, h, fn)
    d = ImageDraw.Draw(img)
    f1, f2 = font("bold", 26), font("black", 88)
    d.text(((w - d.textlength(month, font=f1)) / 2, 12), month, font=f1, fill=WHITE)
    d.text(((w - d.textlength(str(day), font=f2)) / 2, 62), str(day), font=f2, fill=(40, 38, 52))
    return Sprite(img, (6, 10, 10, 0.38))


@functools.lru_cache(maxsize=None)
def notebook_img(lines, graph=False, checks=False, w=660, h=470):
    def fn(d, k):
        d.rounded_rectangle((0, 18 * k, w * k - 1, h * k - 1), radius=10 * k, fill=(251, 248, 238, 255))
        for y in range(84, h - 10, 38):
            d.line((14 * k, y * k, (w - 14) * k, y * k), fill=(188, 205, 232, 255), width=round(1.6 * k))
        d.line((78 * k, 30 * k, 78 * k, (h - 6) * k), fill=(232, 150, 150, 255), width=round(1.8 * k))
        for i in range(15):
            x = 34 + i * (w - 68) / 14
            d.ellipse(((x - 7) * k, 26 * k, (x + 7) * k, 40 * k), fill=(70, 66, 60, 255))
            d.rounded_rectangle(((x - 4) * k, 0, (x + 4) * k, 36 * k), radius=4 * k, fill=(152, 154, 164, 255))

    img = drawn(w, h, fn)
    d = ImageDraw.Draw(img)
    f = hand(30)
    for i, line in enumerate(lines):
        d.text((96, 54 + i * 38), line, font=f, fill=(62, 64, 84))
        if checks and i > 0:
            x = 104 + d.textlength(line, font=f)
            y = 54 + i * 38 + 18
            d.line((x, y, x + 8, y + 9, x + 24, y - 10), fill=(40, 150, 90), width=4)
    if graph:
        gx, gy, c = w - 214, 112, (70, 72, 92)
        d.line((gx, gy, gx, gy + 150, gx + 172, gy + 150), fill=c, width=3)
        d.line((gx + 14, gy + 18, gx + 160, gy + 138), fill=c, width=3)
        d.line((gx + 14, gy + 138, gx + 160, gy + 18), fill=c, width=3)
        d.text((gx + 164, gy - 6), "S", font=hand(26), fill=c)
        d.text((gx + 164, gy + 118), "D", font=hand(26), fill=c)
    return img


@functools.lru_cache(maxsize=None)
def notebook(lines, graph=False, checks=False):
    return Sprite(notebook_img(lines, graph, checks), (8, 14, 16, 0.4))


def report():
    w, h = 360, 470

    def sheet(d, k, ox, oy):
        d.rectangle((ox * k, oy * k, (ox + w) * k, (oy + h) * k), fill=(250, 250, 248, 255))

    img = drawn(w + 16, h + 16, lambda d, k: (sheet(d, k, 14, 14), sheet(d, k, 0, 0)))
    d = ImageDraw.Draw(img)
    d.text((30, 30), "Q3 Market Report", font=font("bold", 28), fill=(36, 36, 48))
    d.text((30, 70), "Prepared for: Maya", font=font("regular", 18), fill=(120, 120, 132))
    for i, v in enumerate([0.4, 0.62, 0.5, 0.86]):
        d.rectangle((40 + i * 46, 230 - 110 * v, 72 + i * 46, 230), fill=(120, 128, 200))
    d.line((30, 232, 230, 232), fill=(150, 150, 160), width=2)
    for i in range(7):
        d.rectangle((30, 262 + i * 26, 30 + (300 if i % 3 else 250), 272 + i * 26), fill=(214, 216, 222))
    return Sprite(img.rotate(-5, resample=Image.BICUBIC, expand=True), (8, 12, 14, 0.38))


def sticky(text, angle):
    s = 150
    img = drawn(s, s, lambda d, k: d.rectangle((0, 0, s * k, s * k), fill=(255, 226, 104, 255)))
    d = ImageDraw.Draw(img)
    f = hand(34)
    lines = wrap(text, f, s - 24)
    for i, l in enumerate(lines):
        d.text(((s - d.textlength(l, font=f)) / 2, 40 + i * 38), l, font=f, fill=(60, 60, 80))
    return Sprite(img.rotate(angle, resample=Image.BICUBIC, expand=True), (4, 8, 8, 0.32))


def tablet():
    w, h = 840, 570
    rng = np.random.default_rng(4)
    heads = [(226, 88, 76), (78, 130, 220), (70, 170, 120), (240, 170, 60), (140, 100, 210), (120, 128, 140)]

    def fn(d, k):
        d.rounded_rectangle((0, 0, w * k, h * k), radius=36 * k, fill=(16, 16, 20, 255))
        d.rounded_rectangle((22 * k, 22 * k, (w - 22) * k, (h - 22) * k), radius=16 * k, fill=(22, 28, 46, 255))
        cw, chh = (w - 44 - 7 * 12) / 6, (h - 44 - 54 - 5 * 12) / 4
        for r in range(4):
            for c in range(6):
                x, y = 22 + 12 + c * (cw + 12), 22 + 54 + 12 + r * (chh + 12)
                d.rounded_rectangle((x * k, y * k, (x + cw) * k, (y + chh) * k), radius=8 * k, fill=(226, 232, 242, 255))
                d.rounded_rectangle((x * k, y * k, (x + cw) * k, (y + 18) * k), radius=8 * k,
                                    fill=heads[int(rng.integers(len(heads)))] + (255,))
                for i in range(3):
                    d.rectangle(((x + 10) * k, (y + 32 + i * 16) * k, (x + cw * (0.5 + 0.4 * rng.random())) * k,
                                 (y + 38 + i * 16) * k), fill=(176, 184, 198, 255))

    img = drawn(w, h, fn)
    d = ImageDraw.Draw(img)
    d.text((48, 36), "47 tabs", font=font("semibold", 24), fill=(200, 212, 236))
    d.text((w - 200, 36), "· · ·", font=font("bold", 24), fill=(120, 132, 160))
    return Sprite(img, (10, 16, 18, 0.5))


def sharpener():
    w, h = 360, 230

    def fn(d, k):
        d.rounded_rectangle((0, 0, w * k, h * k), radius=26 * k, fill=(176, 180, 190, 255))
        d.rounded_rectangle((6 * k, 6 * k, (w - 6) * k, (h * 0.55) * k), radius=22 * k, fill=(206, 210, 218, 255))
        d.rounded_rectangle((6 * k, 6 * k, (w - 6) * k, 26 * k), radius=12 * k, fill=(226, 229, 235, 255))
        d.ellipse((-56 * k, (h / 2 - 56) * k, 56 * k, (h / 2 + 56) * k), fill=(36, 38, 46, 255))
        d.polygon([(120 * k, 62 * k), (300 * k, 40 * k), (306 * k, 66 * k), (126 * k, 88 * k)], fill=(112, 116, 128, 255))
        d.line((122 * k, 88 * k, 306 * k, 66 * k), fill=(40, 42, 50, 255), width=round(3 * k))
        d.line((122 * k, 64 * k, 300 * k, 42 * k), fill=(236, 238, 244, 255), width=round(2 * k))
        d.ellipse((236 * k, 40 * k, 262 * k, 66 * k), fill=(150, 154, 164, 255))
        d.line((240 * k, 53 * k, 258 * k, 53 * k), fill=(90, 92, 102, 255), width=round(3 * k))

    return Sprite(drawn(w, h, fn), (10, 16, 16, 0.45))


SHAVING_TURNS = 2 * 2 * math.pi + 1.5 * math.pi      # ends pointing down, into the blade


def shaving_point(th, c):
    r = 6 + 6.5 * th
    return c + r * math.cos(th), c - r * math.sin(th) * 0.86


def shaving(p, size=360):
    """The wood ribbon curling out of the sharpener's blade, grown to p (0..1). It
    appears at its outer end (by the blade) first and curls inward."""
    if p <= 0.01:
        return None
    c = size / 2

    def fn(d, k):
        lo = SHAVING_TURNS * (1 - p)
        n = max(2, int(180 * p))
        pts = [(*shaving_point(lo + (SHAVING_TURNS - lo) * i / n, c), lo + (SHAVING_TURNS - lo) * i / n)
               for i in range(n + 1)]
        for x, y, th in pts:
            w = 4 + 0.85 * th
            d.ellipse(((x - w) * k, (y - w) * k, (x + w) * k, (y + w) * k), fill=(255, 224, 186, 255))
        for (x0, y0, a0), (x1, y1, _) in zip(pts, pts[1:]):
            w = 4 + 0.85 * a0
            nx, ny = math.cos(a0), -math.sin(a0) * 0.86
            d.line(((x0 + nx * w) * k, (y0 + ny * w) * k, (x1 + nx * w) * k, (y1 + ny * w) * k),
                   fill=(232, 228, 255, 255), width=round(4 * k))
            d.line(((x0 - nx * w) * k, (y0 - ny * w) * k, (x1 - nx * w) * k, (y1 - ny * w) * k),
                   fill=(204, 164, 124, 255), width=round(2.5 * k))

    return Sprite(drawn(size, size, fn), (5, 8, 8, 0.35))


@functools.lru_cache(maxsize=None)
def clock(steps):
    size = 250

    def fn(d, k):
        c, r = size * k / 2, size * k / 2 - 8 * k
        d.ellipse((c - r, c - r, c + r, c + r), fill=(250, 250, 248, 255), outline=(44, 44, 54, 255), width=round(11 * k))
        for i in range(60):
            a = math.radians(i * 6)
            r0 = r - (30 if i % 5 == 0 else 18) * k
            r1 = r - 14 * k
            d.line((c + r0 * math.sin(a), c - r0 * math.cos(a), c + r1 * math.sin(a), c - r1 * math.cos(a)),
                   fill=(44, 44, 54, 255), width=round((5 if i % 5 == 0 else 2) * k))

        def arm(deg, length, width, color):
            a = math.radians(deg)
            d.line((c - 0.12 * length * math.sin(a), c + 0.12 * length * math.cos(a),
                    c + length * math.sin(a), c - length * math.cos(a)), fill=color, width=round(width * k))

        arm(64, r * 0.5, 9, (44, 44, 54, 255))
        arm(54, r * 0.74, 6, (44, 44, 54, 255))
        arm(steps * 6, r * 0.82, 3, (220, 60, 60, 255))
        d.ellipse((c - 9 * k, c - 9 * k, c + 9 * k, c + 9 * k), fill=(220, 60, 60, 255))

    return Sprite(drawn(size, size, fn), (8, 12, 14, 0.4))


SKIN = {"maya": (198, 150, 120), "manager": (232, 196, 170), "client": (240, 208, 186),
        "colleague": (176, 122, 92), "intern": (150, 104, 78), "niece": (204, 156, 124)}


@functools.lru_cache(maxsize=None)
def person(who, clothes, hair, style, facing="down", scale=1.0, nod=0):
    """Head and shoulders from above, leaning toward +y ("down") or -y ("up")."""
    w, h = 240, 210
    skin = SKIN[who]

    def fn(d, k):
        dark = mix(clothes, (0, 0, 0), 0.2)
        for x in (40, 200):
            d.ellipse(((x - 26) * k, 70 * k, (x + 26) * k, 172 * k), fill=dark + (255,))
            d.ellipse(((x - 15) * k, 160 * k, (x + 15) * k, 190 * k), fill=skin + (255,))
        d.ellipse((22 * k, 26 * k, 218 * k, 128 * k), fill=clothes + (255,))
        hx, hy = 120, 96 + nod

        def circ(x, y, r, c):
            d.ellipse(((x - r) * k, (y - r) * k, (x + r) * k, (y + r) * k), fill=c + (255,))

        if style == "wavy":
            for i in range(14):
                a = i / 14 * 2 * math.pi
                circ(hx + 40 * math.cos(a), hy + 40 * math.sin(a), 13, hair)
            circ(hx, hy, 44, hair)
            circ(hx - 10, hy - 12, 14, mix(hair, (255, 255, 255), 0.12))
        elif style == "curly":
            for i in range(18):
                a = i / 18 * 2 * math.pi
                circ(hx + 36 * math.cos(a), hy + 36 * math.sin(a), 12, hair)
            circ(hx, hy, 38, hair)
        elif style == "bob":
            circ(hx, hy, 50, hair)
            d.line((hx * k, (hy - 50) * k, hx * k, (hy + 6) * k), fill=mix(hair, (0, 0, 0), 0.18) + (255,), width=round(3 * k))
        elif style == "bun":
            circ(hx, hy - 46, 20, hair)
            circ(hx, hy, 44, hair)
        elif style == "messy":
            for i in range(9):
                a = i / 9 * 2 * math.pi
                d.polygon([((hx + 36 * math.cos(a - 0.3)) * k, (hy + 36 * math.sin(a - 0.3)) * k),
                           ((hx + 56 * math.cos(a)) * k, (hy + 56 * math.sin(a)) * k),
                           ((hx + 36 * math.cos(a + 0.3)) * k, (hy + 36 * math.sin(a + 0.3)) * k)], fill=hair + (255,))
            circ(hx, hy, 43, hair)
        else:
            circ(hx, hy, 42, hair)
            circ(hx, hy - 6, 22, mix(hair, (255, 255, 255), 0.1))

    img = drawn(w, h, fn)
    if scale != 1:
        img = img.resize((round(w * scale), round(h * scale)), Image.LANCZOS)
    if facing == "up":
        img = img.rotate(180)
    return Sprite(img, (6, 12, 14, 0.42))


def tent(name):
    w, h = 170, 52
    img = drawn(w, h, lambda d, k: (d.rounded_rectangle((0, 0, w * k, h * k), radius=6 * k, fill=(250, 250, 252, 255)),
                                    d.line((0, h / 2 * k, w * k, h / 2 * k), fill=(226, 226, 234, 255), width=round(2 * k))))
    d = ImageDraw.Draw(img)
    f = font("bold", 22)
    d.text(((w - d.textlength(name, font=f)) / 2, 10), name, font=f, fill=(44, 40, 60))
    return Sprite(img, (3, 6, 6, 0.3))


def laptop(facing="down"):
    w, h = 250, 172

    def fn(d, k):
        d.rounded_rectangle((0, 0, w * k, 136 * k), radius=10 * k, fill=(206, 209, 215, 255))
        d.rounded_rectangle((18 * k, 14 * k, (w - 18) * k, 92 * k), radius=6 * k, fill=(72, 74, 82, 255))
        for r in range(4):
            for c in range(12):
                x, y = 24 + c * 17.4, 20 + r * 18
                d.rounded_rectangle((x * k, y * k, (x + 14) * k, (y + 14) * k), radius=2 * k, fill=(96, 98, 108, 255))
        d.rounded_rectangle((90 * k, 102 * k, 160 * k, 128 * k), radius=4 * k, fill=(190, 193, 200, 255))
        d.rounded_rectangle((6 * k, 136 * k, (w - 6) * k, h * k), radius=8 * k, fill=(176, 180, 188, 255))

    img = drawn(w, h, fn)
    return Sprite(img if facing == "down" else img.rotate(180), (6, 10, 12, 0.4))


def legal_pad():
    w, h = 180, 230

    def fn(d, k):
        d.rectangle((0, 0, w * k, h * k), fill=(250, 236, 140, 255))
        d.rectangle((0, 0, w * k, 24 * k), fill=(126, 42, 42, 255))
        for y in range(44, h, 18):
            d.line((0, y * k, w * k, y * k), fill=(150, 180, 220, 255), width=round(1.4 * k))
        d.line((30 * k, 24 * k, 30 * k, h * k), fill=(220, 120, 120, 255), width=round(1.4 * k))

    return Sprite(drawn(w, h, fn).rotate(4, resample=Image.BICUBIC, expand=True), (5, 8, 10, 0.35))


def pen_sprite():
    w, h = 170, 16

    def fn(d, k):
        d.rounded_rectangle((0, 0, (w - 20) * k, h * k), radius=8 * k, fill=(40, 52, 120, 255))
        d.polygon([((w - 22) * k, 1 * k), (w * k, h / 2 * k), ((w - 22) * k, (h - 1) * k)], fill=(200, 200, 208, 255))
        d.rectangle((20 * k, -2 * k, 70 * k, 3 * k), fill=(200, 200, 210, 255))

    return Sprite(drawn(w, h, fn).rotate(140, resample=Image.BICUBIC, expand=True), (4, 8, 8, 0.4))


@functools.lru_cache(maxsize=512)
def speech(text, name="", accent=INK, shown=-1, tail="down", tail_at=0.2, size=34, maxw=620, strike=0.0, faded=0.0):
    """A speech bubble Sprite and the tail tip's position inside the sprite image."""
    f = font("semibold", size)
    lines = wrap(text, f, maxw - 64)
    probe = ImageDraw.Draw(Image.new("L", (1, 1)))
    lh = round(size * 1.3)
    tw = max(probe.textlength(l, font=f) for l in lines)
    label = text_layer([name.upper()], font("bold", 19), accent + (255,), tracking=2) if name else None
    nh = 30 if name else 0
    bw = int(max(tw, label.width if label else 0) + 64)
    bh = int(nh + len(lines) * lh + 34)
    th = 26
    oy = th if tail == "up" else 0
    tx = bw * tail_at

    def fn(d, k):
        d.rounded_rectangle((0, oy * k, bw * k - 1, (oy + bh) * k - 1), radius=30 * k, fill=(255, 255, 255, 255))
        if tail == "down":
            d.polygon([((tx - 20) * k, (bh - 4) * k), ((tx + 18) * k, (bh - 4) * k), ((tx - 8) * k, (bh + th) * k)],
                      fill=(255, 255, 255, 255))
        else:
            d.polygon([((tx - 20) * k, (oy + 4) * k), ((tx + 18) * k, (oy + 4) * k), ((tx - 8) * k, 0)],
                      fill=(255, 255, 255, 255))

    img = drawn(bw, bh + th, fn)
    d = ImageDraw.Draw(img)
    y = oy + 18
    if label:
        img.alpha_composite(label, (32, y))
        y += nh
    left = len(text) if shown < 0 else shown
    ink = mix(INK, (160, 160, 172), faded)
    for l in lines:
        part = l[:max(0, left)]
        left -= len(l) + 1
        if part:
            d.text((32, y), part, font=f, fill=ink + (255,))
        if strike > 0:
            ym = y + size * 0.66
            x1 = 32 + probe.textlength(l, font=f) + 6
            d.line((26, ym, 26 + (x1 - 26) * strike, ym), fill=(222, 56, 64, 255), width=5)
        y += lh
    sp = Sprite(img, (0, 10, 16, 0.3))
    tip = (tx - 8, bh + th if tail == "down" else 0)
    return sp, tip


def say(canvas, text, tip_xy, appear, t, name="", accent=INK, reveal=0.0, **kw):
    """Draws a speech bubble whose tail points at tip_xy; it pops in at `appear` and
    types its text out over `reveal` seconds."""
    if t < appear:
        return
    shown = -1 if reveal <= 0 else int(len(text) * clamp((t - appear) / reveal))
    if shown >= len(text):
        shown = -1
    sp, (tx, ty) = speech(text, name, accent, shown, **kw)
    p = clamp((t - appear) / 0.28)
    scale = 0.86 + 0.14 * ease_back(p)
    cx = tip_xy[0] - (tx - sp.w / 2) * scale
    cy = tip_xy[1] - (ty - sp.h / 2) * scale
    sp.draw(canvas, cx, cy, min(1.0, p * 2.5), scale)


def narration(canvas, text, t, t_in, t_out=None, where="topright", dark=True):
    if t < t_in:
        return
    p = ease((t - t_in) / 0.6)
    q = 1 - ease((t - (t_out - 0.4)) / 0.4) if t_out is not None else 1.0
    color = (INK if dark else WHITE) + (255,)
    if where == "topright":
        f = font("bold", 60)
        img = lines_layer(wrap(text, f, 780), f, color)
        x, y = 1040, 120 + (1 - p) * 22
    else:
        f = font("bold", 54)
        img = lines_layer(wrap(text, f, 1500), f, color, align="center")
        x, y = (W - img.width) / 2, 952 - img.height / 2 + (1 - p) * 20
        if not dark:
            band = narration_band()
            put(canvas, band, 0, H - band.height, p * q)
    put(canvas, img, x, y, p * q)


@functools.lru_cache(maxsize=None)
def narration_band():
    a = (np.linspace(0, 1, 330) ** 1.6 * 170).astype(np.uint8)
    band = Image.new("RGBA", (W, 330), (6, 8, 16, 0))
    band.putalpha(Image.fromarray(np.repeat(a[:, None], W, axis=1)))
    return band


class Clip:
    """Tour frames at phone-screen size, read forward only: segs [(src_a, src_b), ...]
    play back to back at `speed`."""

    def __init__(self, path, segs, speed=1.0):
        self.path, self.segs, self.speed = path, segs, speed
        self.cur, self.proc, self.idx, self.buf = None, None, -1, None

    def _open(self, i):
        if self.proc:
            self.proc.kill()
        a, b = self.segs[i]
        self.proc = subprocess.Popen([mi.FFMPEG, "-v", "quiet", "-ss", f"{a:.3f}", "-t", f"{b - a + 0.3:.3f}", "-i",
                                      self.path, "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], stdout=subprocess.PIPE)
        self.cur, self.idx = i, -1

    def frame(self, t):
        k = t * self.speed
        i = 0
        for i, (a, b) in enumerate(self.segs):
            if k < b - a or i == len(self.segs) - 1:
                break
            k -= b - a
        if self.cur != i:
            self._open(i)
        want = int(k * FPS)
        n = mi.SCREEN_W * mi.SCREEN_H * 3
        while self.idx < want:
            buf = self.proc.stdout.read(n)
            if len(buf) < n:
                break
            self.buf, self.idx = buf, self.idx + 1
        return Image.frombuffer("RGB", (mi.SCREEN_W, mi.SCREEN_H), self.buf, "raw", "RGB", 0, 1)

    def close(self):
        if self.proc:
            self.proc.kill()


# ---------- the film ----------

TABLE = (430, 300, 1490, 790)
SEAT = {"manager": (760, 200), "client": (1160, 200), "left": (700, 885), "maya": (1120, 885)}


class Film:
    def __init__(self, icon_path, cfr, rel):
        self.cards = mi.Cards(icon_path)
        self.frame_phone = mi.Phone()
        self.clips = {
            "ins_a": Clip(cfr, [(rel["level"] - 10.6, rel["level"] - 3.6)], speed=1.75),
            "ins_b": Clip(cfr, [(rel["q_spot"] + 1.0, rel["q_spot"] + 4.0), (rel["q_spot"] + 6.5, rel["q_spot"] + 11.5)]),
            "ins_c": Clip(cfr, [(rel["summary"] + 0.3, rel["summary"] + 3.9)]),
        }
        home = Clip(cfr, [(rel["home_done"] + 1.6, rel["home_done"] + 2.0)])
        self.home_still = home.frame(0).copy()
        home.close()

        self.desk = wood(W, H, (216, 180, 134), seed=3)
        self.night = ImageEnhance.Brightness(wood(W, H, (70, 74, 90), seed=5, contrast=0.13)).enhance(0.85)
        self.night_macro = self.night.resize((W * 2, H * 2), Image.BICUBIC).crop((W // 2, H // 2, W // 2 + W, H // 2 + H)) \
            .filter(ImageFilter.GaussianBlur(5))
        self.desk_macro = self.desk.resize((W * 2, H * 2), Image.BICUBIC).crop((W // 2, H // 2, W // 2 + W, H // 2 + H)) \
            .filter(ImageFilter.GaussianBlur(4))

        self.hero = Handset(430)
        self.hero_chat = Chat(self.hero.sw, self.hero.sh)
        self.big = Handset(460)
        self.big_chat = Chat(self.big.sw, self.big.sh)
        self.small = Handset(300)
        self.lock_phone = Handset(380)
        self.sofa_phone = Handset(104)
        self.desk_phone = Handset(170)
        self.back_small = phone_back(104)
        self.back_table = phone_back(130)

        self.mug_full, self.mug_empty = mug("full"), mug("empty")
        self.report = report()
        self.stickies = [sticky("call Sam", -8), sticky("gym?", 6), sticky("Q3 deck!!", -4)]
        self.tablet = tablet()
        self.sharpener = sharpener()
        self.legal, self.pen = legal_pad(), pen_sprite()
        self.lap_down, self.lap_up = laptop("down"), laptop("up")
        self.tents = {n: tent(n) for n in ("Manager", "Client", "Colleague", "Intern", "Maya")}
        self.meeting_fog = self._meeting(False)
        self.meeting_sharp = self._meeting(True)
        self.living_fog = self._living(False)
        self.living_sharp = self._living(True)
        self.notif = self.cards._notification("Can you spot today's trap?",
                                              "Sharpy hid a convincing wrong statement in today's set.", "now")

    # --- shared sets ---

    def _meeting(self, sharp):
        img = carpet((82, 88, 104), 2)
        x0, y0, x1, y1 = TABLE
        top = wood(x1 - x0, y1 - y0, (128, 86, 58), seed=8, contrast=0.12).convert("RGBA")
        m = drawn(x1 - x0, y1 - y0, lambda d, k: d.rounded_rectangle((0, 0, (x1 - x0) * k, (y1 - y0) * k), radius=60 * k,
                                                                      fill=(255, 255, 255, 255))).getchannel("A")
        top.putalpha(m)
        for (cx, cy), down in [(SEAT["manager"], True), (SEAT["client"], True), (SEAT["left"], False), (SEAT["maya"], False)]:
            chair = drawn(210, 190, lambda d, k: (
                d.rounded_rectangle((10 * k, 30 * k, 200 * k, 180 * k), radius=30 * k, fill=(52, 54, 64, 255)),
                d.rounded_rectangle((0, 0, 210 * k, 40 * k), radius=18 * k, fill=(40, 42, 50, 255))))
            Sprite(chair if down else chair.rotate(180), (6, 10, 12, 0.4)).draw(img, cx, cy - 30 if down else cy + 30)
        Sprite(top, (14, 22, 26, 0.5)).draw(img, (x0 + x1) / 2, (y0 + y1) / 2)
        self.lap_down.draw(img, 760, 392)
        self.lap_down.draw(img, 1160, 392)
        self.mug_full.draw(img, 560, 470)
        self.mug_full.draw(img, 1350, 470)
        self.tents["Manager"].draw(img, 590, 342)
        self.tents["Client"].draw(img, 1330, 342)
        self.tents["Intern" if sharp else "Colleague"].draw(img, 525, 735)
        self.tents["Maya"].draw(img, 1310, 735)
        if sharp:
            self.lap_up.draw(img, 700, 690)
            notebook(FED_NOTES[:3]).draw(img, 1130, 690, scale=0.4)
            self.back_table.draw(img, 960, 690)
            sp, _ = pencil(240, 30, 20)
            sp.draw(img, 1180, 700)
        else:
            self.legal.draw(img, 700, 680)
            Sprite(drawn(210, 160, lambda d, k: (
                d.rounded_rectangle((0, 0, 210 * k, 160 * k), radius=8 * k, fill=(40, 60, 110, 255)),
                d.rectangle((0, 0, 16 * k, 160 * k), fill=(30, 46, 86, 255)))), (6, 10, 12, 0.4)).draw(img, 1130, 690)
        return img

    def _living(self, sharp):
        img = wood(W, H, (186, 140, 98), seed=12, contrast=0.12, vertical=True, plank=170)

        def rug(d, k):
            for inset, c in [(0, (150, 74, 62)), (24, (234, 208, 166)), (52, (178, 92, 76)), (110, (240, 222, 184)),
                             (150, (126, 86, 126)), (210, (236, 214, 170))]:
                d.ellipse((inset * k, inset * 0.55 * k, (1200 - inset) * k, (660 - inset * 0.55) * k), fill=c + (255,))

        Sprite(drawn(1200, 660, rug), (0, 6, 10, 0.3)).draw(img, 960, 700)

        def sofa(d, k):
            d.rounded_rectangle((0, 0, 960 * k, 280 * k), radius=40 * k, fill=(84, 104, 138, 255))
            d.rounded_rectangle((90 * k, 76 * k, 870 * k, 270 * k), radius=26 * k, fill=(104, 126, 160, 255))
            for x in (350, 610):
                d.line((x * k, 80 * k, x * k, 266 * k), fill=(84, 104, 138, 255), width=round(4 * k))

        Sprite(drawn(960, 280, sofa), (10, 16, 20, 0.45)).draw(img, 960, 165)
        Sprite(drawn(120, 120, lambda d, k: d.rounded_rectangle((0, 0, 120 * k, 120 * k), radius=20 * k,
                                                                fill=(232, 196, 104, 255))).rotate(18, expand=True,
                                                                                                   resample=Image.BICUBIC),
               (5, 8, 10, 0.35)).draw(img, 600, 160)
        Sprite(drawn(200, 200, lambda d, k: d.ellipse((0, 0, 200 * k, 200 * k), fill=(118, 86, 62, 255))),
               (8, 12, 14, 0.4)).draw(img, 230, 170)
        Sprite(drawn(150, 150, lambda d, k: (d.ellipse((0, 0, 150 * k, 150 * k), fill=(246, 236, 208, 255)),
                                             d.ellipse((50 * k, 50 * k, 100 * k, 100 * k), fill=(226, 212, 176, 255)))),
               (6, 14, 14, 0.35)).draw(img, 230, 170)
        dino = Image.new("RGBA", (180, 180), (0, 0, 0, 0))
        ImageDraw.Draw(dino).text((10, 0), "\U0001F995", font=font("emoji", 130), embedded_color=True)
        Sprite(dino.rotate(-14, resample=Image.BICUBIC, expand=True), (5, 8, 10, 0.35)).draw(img, 1330, 860)
        for i, c in enumerate([(60, 110, 220), (220, 70, 70), (240, 190, 50)]):
            Sprite(drawn(110, 20, lambda d, k, c=c: d.rounded_rectangle((0, 0, 110 * k, 20 * k), radius=8 * k,
                                                                         fill=c + (255,))).rotate(10 + i * 25, expand=True,
                                                                                                   resample=Image.BICUBIC),
                   (3, 5, 6, 0.3)).draw(img, 560 + i * 40, 960 - i * 18)
        if sharp:
            Sprite(drawn(320, 220, self._picture_book).rotate(14, expand=True, resample=Image.BICUBIC),
                   (6, 10, 12, 0.4)).draw(img, 1660, 960)
            self.back_small.draw(img, 1230, 200)
        else:
            Sprite(drawn(320, 220, self._picture_book).rotate(-6, expand=True, resample=Image.BICUBIC),
                   (6, 10, 12, 0.4)).draw(img, 1030, 800)
        return img

    @staticmethod
    def _picture_book(d, k):
        d.rounded_rectangle((0, 0, 320 * k, 220 * k), radius=8 * k, fill=(220, 90, 70, 255))
        d.rectangle((8 * k, 8 * k, 158 * k, 212 * k), fill=(126, 188, 240, 255))
        d.rectangle((162 * k, 8 * k, 312 * k, 212 * k), fill=(250, 246, 236, 255))
        d.ellipse((96 * k, 30 * k, 140 * k, 74 * k), fill=(255, 210, 70, 255))
        for x, y, r in [(46, 110, 22), (70, 102, 26), (96, 112, 20)]:
            d.ellipse(((x - r) * k, (y - r) * k, (x + r) * k, (y + r) * k), fill=(255, 255, 255, 255))
        d.rectangle((8 * k, 170 * k, 158 * k, 212 * k), fill=(110, 180, 100, 255))
        for i in range(6):
            d.rectangle((180 * k, (40 + i * 24) * k, (180 + (110 if i % 3 else 80)) * k, (48 + i * 24) * k),
                        fill=(190, 186, 176, 255))

    # --- act 1 ---

    def desk_props(self, c, t, report=False):
        self.mug_full.draw(c, 1700, 470)
        if report:
            self.report.draw(c, 1310, 650)

    def s1(self, t, d):
        c = self.desk.copy()
        sunbeam(c, 0.2, 1.0)
        light = ease(prog(t, 2.0, 2.4))
        sp, _ = pencil(620, 66, 45)
        sp.draw(c, 820, 560)
        x = 2150 - 860 * ease(prog(t, 0.6, 1.5))
        screen = mi.gradient(self.small.sw, self.small.sh, mix((10, 10, 14), (70, 96, 200), light),
                             mix((10, 10, 14), (24, 30, 80), light))
        if light > 0:
            glow(c, x, 560, 520, (90, 130, 255), 0.4 * light)
        self.small.draw(c, screen, x, 560, angle=-8)
        motes(c, t, 0.2, 1.0)
        c = zoom(c, 1 + 0.04 * t / d, 900, 560)
        return vignette(grade(c, warm=0.6), 0.35)

    def chat_scene(self, c, t, msgs, typed="", caret=False):
        screen = self.hero_chat.render(msgs, t, typed, caret)
        self.hero.draw(c, screen, 560, 540)

    S2_MSGS = [("user", "What should I have for breakfast?", 1.65), ("ai", "[[dots]]", 1.85, 2.9),
               ("ai", "Overnight oats with berries. Ready in two minutes!", 2.9)]
    S3_MSGS = [("user", "[[doc:Q3_report.pdf]]", 1.0), ("user", "Summarize this for me", 1.05),
               ("ai", "[[dots]]", 1.25, 2.0), ("ai", "[[bars:5]]", 2.0), ("user", "[[emoji:\U0001F44D]]", 3.1)]

    def s2(self, t, d):
        c = self.desk.copy()
        sunbeam(c, 0.35, 0.8)
        self.desk_props(c, t)
        sp, _ = pencil(420, 46, 35)
        sp.draw(c, 1640, 880)
        q = "What should I have for breakfast?"
        typed = q[:int(len(q) * prog(t, 0.3, 1.5))] if t < 1.65 else ""
        self.chat_scene(c, t, self.S2_MSGS, typed, caret=t < 1.65)
        narration(c, "It started with the little things.", t, 1.0)
        return vignette(grade(c, warm=0.5), 0.3)

    def s3(self, t, d):
        c = self.desk.copy()
        sunbeam(c, 0.45, 0.8)
        self.desk_props(c, t, report=True)
        sp, _ = pencil(420, 46, 35)
        sp.draw(c, 1640, 880)
        msgs = [(r, x, a - 10) for r, x, a, *g in self.S2_MSGS if x != "[[dots]]"] + self.S3_MSGS
        q = "Summarize this for me"
        typed = q[:int(len(q) * prog(t, 0.2, 0.9))] if t < 1.0 else ""
        self.chat_scene(c, t, msgs, typed, caret=t < 1.0)
        narration(c, "Then the work things.", t, 0.8)
        return vignette(grade(c, warm=0.5), 0.3)

    def s4(self, t, d):
        c = self.desk.copy()
        sent = [at for at, _ in S4_PROMPTS if at <= t]
        n = len(sent)
        # Each prompt is another day: the light sweeps once per day.
        times = [0.0] + [at for at, _ in S4_PROMPTS] + [d + 0.4]
        k = max(i for i, x in enumerate(times) if x <= t)
        frac = (t - times[k]) / max(0.05, times[k + 1] - times[k])
        sunbeam(c, frac, 0.8)
        self.desk_props(c, t, report=True)
        for x, y in [(1530, 400), (900, 230), (980, 1000)][:min(3, n // 3)]:
            self.mug_empty.draw(c, x, y)
        calendar(3 + n, "OCT").draw(c, 1790, 640)
        for i, (at, sx, sy) in enumerate([(2.18, 960, 520), (3.88, 1000, 820), (4.98, 1200, 960)]):
            if t > at:
                life = t - at
                fall = prog(life, 1.6, 2.3)
                self.stickies[i].draw(c, sx, sy + 30 * fall, alpha=ease(life / 0.2) * (1 - fall))
        dust = prog(t, 0.5, 6.0)
        sp, _ = pencil(420, 46, 35, dust=dust)
        sp.draw(c, 1640, 880)
        msgs = []
        for i, (at, text) in enumerate(S4_PROMPTS):
            msgs.append(("user", text, at))
            if i < len(S4_PROMPTS) - 1:
                msgs.append(("ai", "[[bars:2]]", at + 0.22))
            else:
                msgs.append(("ai", "[[dots]]", at + 0.3))
        self.chat_scene(c, t, msgs)
        narration(c, "Then… pretty much everything.", t, 1.0)
        night = 0.5 - 0.5 * math.cos(2 * math.pi * frac)
        c = Image.blend(c, Image.new("RGB", (W, H), (20, 22, 34)), 0.12 * (1 - night) * prog(t, 0.4, 1.0))
        cold = smooth(prog(t, 1.2, 7.6))
        return vignette(grade(c, cold=cold, warm=0.5 * (1 - cold)), 0.3 + 0.2 * cold)

    # --- act 2 ---

    def table(self, c, sharp, nod=0, maya_down=0):
        clothes = (226, 168, 58) if sharp else (124, 128, 138)
        person("manager", (150, 190, 226), (150, 150, 156), "short", "down", 1.0, nod).draw(c, *SEAT["manager"])
        person("client", (40, 52, 92), (206, 206, 214), "bob", "down").draw(c, *SEAT["client"])
        if sharp:
            person("intern", (226, 118, 58), (30, 28, 30), "messy", "up").draw(c, *SEAT["left"])
        else:
            person("colleague", (70, 130, 96), (150, 70, 40), "bun", "up").draw(c, *SEAT["left"])
        mx, my = SEAT["maya"]
        person("maya", clothes, (58, 40, 32), "wavy", "up").draw(c, mx, my + maya_down)

    def clock_inset(self, c, t_scene, first_tick, n_before=0):
        steps = n_before + (int(t_scene - first_tick) + 1 if t_scene >= first_tick else 0)
        clock(steps % 60).draw(c, 1740, 190)

    def s5(self, t, d):
        c = self.meeting_fog.copy()
        self.table(c, False, maya_down=8 * ease(prog(t, 3.6, 4.4)))
        self.clock_inset(c, t, 2.6)
        c = grade(c, cold=1.0)
        c = zoom(c, 1 + 0.07 * smooth(t / d), 1080, 760)
        say(c, "Maya, quick one. Why was the Fed set up in the first place?", (790, 300), 0.4, t,
            name="Manager", accent=(70, 110, 170), reveal=1.9, tail="up", tail_at=0.16)
        if t > 3.0:
            dots = "." * (1 + int((t - 3.0) * 2.5) % 3)
            say(c, dots + "   ", (1110, 760), 3.0, t, name="Maya", accent=(150, 110, 40), tail="down", tail_at=0.3)
        return vignette(c, 0.5)

    def s6(self, t, d):
        c = Image.new("RGB", (W, H), (14, 16, 24))
        glow(c, 960, 520, 700, (60, 90, 170), 0.35)
        for x in (520, 1400):
            Sprite(drawn(520, 360, lambda dd, k: dd.ellipse((0, 0, 520 * k, 360 * k), fill=(30, 34, 46, 255))), None) \
                .draw(c, x, 1060)
        c.paste((22, 18, 18), (0, 0, W, 70))
        q = "why was the fed created"
        typed = q[:int(len(q) * prog(t, 0.0, 0.8))] if t < 0.9 else ""
        msgs = [("user", q, 0.9), ("ai", "[[dots]]", 1.05)]
        screen = self.big_chat.render(msgs, t, typed, caret=t < 0.9)
        jx, jy = 3 * math.sin(t * 37), 2 * math.sin(t * 29)
        self.big.draw(c, screen, 960 + jx, 560 + jy, angle=-7)
        return vignette(grade(c, cold=0.6), 0.6)

    def s7(self, t, d):
        c = self.meeting_fog.copy()
        self.table(c, False, maya_down=8 + 8 * ease(prog(t, 4.3, 5.0)))
        # The colleague's pen writes until the correction, then stops.
        stop = min(t, 2.75)
        ink = Image.new("RGBA", (180, 230), (0, 0, 0, 0))
        dd = ImageDraw.Draw(ink)
        pts = [(36 + (x % 130) * 1.0, 64 + 18 * (x // 130) + 4 * math.sin(x * 0.4)) for x in range(int(stop * 90))]
        if len(pts) > 1:
            dd.line(pts, fill=(40, 52, 120, 255), width=3)
        put(c, ink, 610, 565)
        px, py = pts[-1] if pts else (36, 64)
        self.pen.draw(c, 610 + px + 50, 565 + py - 40)
        self.clock_inset(c, min(t, 2.7), 0.6, n_before=8)
        c = grade(c, cold=1.0)
        c = zoom(c, 1.07, 1080, 760)
        cut = 2.75
        strike = round(prog(t, 3.3, 3.8) * 20) / 20
        faded = round(prog(t, 3.9, 4.3) * 10) / 10
        say(c, "It was created in the 1930s, after the Great Depression, to—", (1110, 760), 0.2, t,
            name="Maya", accent=(150, 110, 40), reveal=2.2, tail="down", tail_at=0.3, strike=strike, faded=faded)
        say(c, "Nineteen-thirteen, actually.", (1190, 300), cut, t, name="Client", accent=(70, 80, 140),
            tail="up", tail_at=0.7, size=38)
        return vignette(c, 0.5)

    def living(self, c, sharp, maya_down=0):
        if sharp:
            person("maya", (226, 168, 58), (58, 40, 32), "wavy", "up").draw(c, 1150, 830)
            person("niece", (96, 172, 112), (70, 45, 30), "curly", "up", 0.74).draw(c, 770, 840)
        else:
            person("maya", (124, 128, 138), (58, 40, 32), "wavy", "down").draw(c, 1000, 175 + maya_down)
            person("niece", (96, 172, 112), (70, 45, 30), "curly", "up", 0.74).draw(c, 770, 830)

    def s8(self, t, d):
        c = self.living_fog.copy()
        self.living(c, False)
        pick = ease(prog(t, 2.4, 3.1))
        x, y = 1230 + (1000 - 1230) * pick, 205 + (390 - 205) * pick
        battery = 0.0
        if 4.6 <= t < 5.9:
            battery = 1.0 if (t - 4.6) % 0.5 < 0.3 else 0.25
        screen = dark_screen(self.sofa_phone.sw, self.sofa_phone.sh, battery)
        self.sofa_phone.draw(c, screen, x, y, angle=12 * (1 - pick), scale=1 + 0.45 * pick)
        for press in (3.5, 4.4):
            if press <= t < press + 0.4:
                r = 20 + 60 * (t - press) / 0.4
                ring = drawn(2 * r + 8, 2 * r + 8, lambda dd, k: dd.ellipse((4 * k, 4 * k, (2 * r + 4) * k, (2 * r + 4) * k),
                                                                         outline=(255, 255, 255, 200), width=round(4 * k)))
                put(c, ring, x + 95 - r - 4, y - 40 - r - 4, 1 - (t - press) / 0.4)
        glow(c, 230, 170, 520, (255, 200, 120), 0.45)
        c = grade(c, cold=0.85)
        say(c, "Aunt Maya, why is the sky blue?", (760, 750), 0.4, t, name="Niece", accent=(60, 140, 80),
            reveal=1.2, tail="down", tail_at=0.2)
        return vignette(c, 0.5)

    def s9(self, t, d):
        c = self.living_fog.copy()
        self.living(c, False, maya_down=10 * ease(prog(t, 2.8, 3.5)))
        screen = dark_screen(self.sofa_phone.sw, self.sofa_phone.sh)
        self.sofa_phone.draw(c, screen, 1000, 390, scale=1.45)
        glow(c, 230, 170, 520, (255, 200, 120), 0.45)
        c = grade(c, cold=0.85)
        c = zoom(c, 1 + 0.25 * ease(prog(t, 0, 1.2)), 1000, 330)
        say(c, "I… used to know this.", (1070, 175), 0.35, t, name="Maya", accent=(150, 110, 40),
            reveal=1.0, tail="down", tail_at=0.12)
        say(c, "You don't know?", (430, 1080), 2.1, t, name="Niece", accent=(60, 140, 80), tail="down", tail_at=0.3)
        return vignette(c, 0.55)

    def night_props(self, c, notebook_y=None, pencil_at=(1700, 900)):
        self.tablet.draw(c, 620, 380)
        glow(c, 620, 380, 760, (80, 120, 255), 0.33)
        self.desk_phone.draw(c, dark_screen(self.desk_phone.sw, self.desk_phone.sh), 1380, 240, angle=-10)
        self.mug_empty.draw(c, 1760, 360)
        sp, _ = pencil(430, 48, 30, "broken", 1.0)
        sp.draw(c, *pencil_at)

    def s10(self, t, d):
        c = self.night.copy()
        self.night_props(c)
        y = 1350 + (700 - 1350) * ease(prog(t, 0.6, 1.4))
        notebook(FED_NOTES, graph=True).draw(c, 1210, y)
        c = grade(c, cold=0.5)
        c = zoom(c, 1 + 0.16 * smooth(prog(t, 2.2, 6.0)), 1100, 640)
        narration(c, "Every answer, one tap away.", t, 1.2, where="bottom", dark=False)
        return vignette(c, 0.6)

    def s11(self, t, d):
        c = self.night_macro.copy()
        dust = 1.0 - 0.75 * ease(prog(t, 0.7, 1.5))
        sp, (tx, ty) = pencil(1500, 150, 28, "broken", dust)
        cx, cy = 860, 640
        sp.draw(c, cx, cy)
        rng = np.random.default_rng(3)
        for i in range(160):
            u = rng.uniform(-0.45, 0.42)
            bx, by = cx + tx * 2 * u, cy + ty * 2 * u + rng.uniform(-40, 40)
            life = t - 0.7 - rng.uniform(0, 0.25)
            if life <= 0 or life > 1.6:
                continue
            vx, vy = rng.uniform(260, 620), rng.uniform(-520, -160)
            x, y = bx + vx * life, by + vy * life + 120 * life * life
            r = rng.uniform(2.0, 5.0)
            dot = drawn(2 * r, 2 * r, lambda dd, k: dd.ellipse((0, 0, 2 * r * k, 2 * r * k), fill=(196, 192, 186, 255)))
            put(c, dot, x - r, y - r, 0.9 * (1 - life / 1.6))
        for i, (ox, oy, r) in enumerate([(30, 40, 6), (52, 18, 4), (-20, 54, 5), (70, 60, 3)]):
            ex, ey = cx + tx + ox, cy + ty + oy
            put(c, drawn(2 * r, 2 * r, lambda dd, k, r=r: dd.ellipse((0, 0, 2 * r * k, 2 * r * k),
                                                                     fill=(52, 50, 62, 255))), ex - r, ey - r)
        # The snapped-off point, lying by the pencil.
        lead = drawn(70, 40, lambda dd, k: (dd.polygon([(0, 4 * k), (70 * k, 20 * k), (0, 36 * k)], fill=(70, 68, 84, 255)),
                                            dd.polygon([(0, 4 * k), (70 * k, 20 * k), (0, 20 * k)], fill=(104, 102, 120, 255))))
        Sprite(lead.rotate(-35, expand=True, resample=Image.BICUBIC), (3, 6, 6, 0.5)).draw(c, cx + tx + 110, cy + ty + 90)
        glow(c, cx + tx, cy + ty, 380, (90, 130, 255), 0.22)
        c = grade(c, cold=0.5)
        c = zoom(c, 1 + 0.14 * smooth(t / d), cx + tx * 0.8, cy + ty * 0.8)
        narration(c, "And somewhere along the way, we got dull.", t, 1.5, where="bottom", dark=False)
        return vignette(c, 0.6)

    def s12(self, t, d):
        c = self.night.copy()
        self.tablet.draw(c, 380, 260, alpha=0.9)
        self.mug_empty.draw(c, 1620, 300)
        sp, _ = pencil(520, 56, 30, "broken", 0.25)
        sp.draw(c, 1440, 820)
        notebook(FED_NOTES, graph=True).draw(c, 470, 860)
        on = ease(prog(t, 0.3, 0.5))
        lock = self.cards.lock.copy()
        p = ease(prog(t, 0.85, 1.3))
        if p > 0:
            put(lock, self.notif, 14, 330 - (1 - p) * 40, p)
        screen = Image.blend(Image.new("RGB", lock.size, (9, 9, 12)), lock.convert("RGB"), on)
        buzz = (0.3 <= t < 0.9) or (1.25 <= t < 1.65)
        jx = 6 * math.sin(2 * math.pi * 31 * t) if buzz else 0
        if on > 0:
            glow(c, 960, 540, 640, (110, 120, 255), 0.3 * on)
        self.lock_phone.draw(c, screen, 960 + jx, 540, angle=-6 + (0.8 * math.sin(t * 90) if buzz else 0))
        if buzz:
            for side in (-1, 1):
                arc = drawn(80, 220, lambda dd, k: [dd.arc((i * 22 * k, 0, (80 + i * 40) * k, 220 * k), 150, 210,
                                                           fill=(220, 225, 255, 200), width=round(4 * k)) for i in range(2)])
                if side > 0:
                    arc = arc.transpose(Image.FLIP_LEFT_RIGHT)
                put(c, arc, 960 + side * 270 - 40, 430, 0.8)
        c = grade(c, cold=0.45)
        c = zoom(c, 1 + 0.06 * smooth(t / d), 960, 540)
        return vignette(c, 0.6)

    # --- inserts (real app footage) ---

    def insert(self, name, t, d, label, head, sub=None, sub_at=0.0):
        c = self.cards.bg.copy()
        self.frame_phone.compose(c, self.clips[name].frame(t), ease(t / 0.3), dy=(1 - ease(t / 0.5)) * 30)
        lab = text_layer([label.upper()], font("semibold", 26), GOLD + (255,), tracking=3)
        hf = font("bold", 66)
        head_img = text_layer(wrap(head, hf, 800), hf, WHITE + (255,), spacing=1.12)
        sub_img = None
        if sub:
            sf = font("regular", 38)
            sub_img = text_layer(wrap(sub, sf, 760), sf, WHITE + (220,), spacing=1.3)
        total = lab.height + 18 + head_img.height + (28 + sub_img.height if sub_img else 0)
        top = (H - total) // 2
        a = ease((t - 0.1) / 0.5)
        put(c, lab, mi.TEXT_X, top + (1 - a) * 26, a)
        b = ease((t - 0.22) / 0.5)
        put(c, head_img, mi.TEXT_X, top + lab.height + 18 + (1 - b) * 26, b)
        if sub_img:
            s = ease((t - sub_at) / 0.5)
            put(c, sub_img, mi.TEXT_X, top + lab.height + 18 + head_img.height + 28 + (1 - s) * 22, s)
        return c

    def ins_a(self, t, d):
        return self.insert("ins_a", t, d, "Sharpy", "A few questions a day, in your own field.")

    def ins_b(self, t, d):
        return self.insert("ins_b", t, d, "Spot the trap", "Some are traps: confident, convincing, and wrong.",
                           "Catch them, and see the source behind every answer.", 3.4)

    def ins_c(self, t, d):
        return self.insert("ins_c", t, d, "Every day", "Keep the thinking for yourself.")

    # --- act 3 ---

    def s13(self, t, d):
        c = self.night_macro.copy()
        warm = ease(prog(t, 2.6, 3.5))
        glow(c, 1500, 200, 900, (255, 190, 110), 0.35 * warm)
        q = "which statement is wrong? the fed was created in"
        n = len(q)
        if t < 1.45:
            typed = q[:int(n * prog(t, 0.15, 1.45))]
        elif t < 2.0:
            typed = q
        else:
            typed = q[:int(n * (1 - prog(t, 2.0, 2.7)))]
        screen = self.big_chat.render([], t, typed, caret=True, dim=prog(t, 2.6, 3.2))
        self.big.draw(c, screen, 960, 540, angle=-4)
        c = grade(c, cold=0.5 * (1 - warm), warm=0.4 * warm)
        return vignette(c, 0.55)

    def s14(self, t, d):
        warm = smooth(prog(t, 0.6, 3.2))
        c = Image.blend(self.night_macro, self.desk_macro, warm)
        glow(c, 1500, 160, 1000, (255, 196, 120), 0.45 * warm)
        L, T = 1100, 120
        if t < 3.0:
            tip = 900 + 160 * ease(prog(t, 0.0, 0.6))
            state, phase = "broken", ((t - 0.6) * 2.2) % 1 if t > 0.6 else 0.0
        else:
            tip = 1060 - 200 * ease(prog(t, 3.0, 3.6))
            state, phase = "sharp", 0.0
        sp, (tx, ty) = pencil(L, T, 0, state, 0.0, phase)
        sp.draw(c, tip - tx, 560)
        self.sharpener.draw(c, 1180, 540)
        curl = shaving(ease(prog(t, 0.7, 3.0)))
        if curl:
            # Pin the ribbon's outer end to the middle of the blade.
            ox, oy = shaving_point(SHAVING_TURNS, 180)
            curl.draw(c, 1215 - (ox - 180), 492 - (oy - 180))
        if t >= 3.65:
            g = t - 3.65
            size = 220 * ease_back(min(1.0, g / 0.45)) * (0.75 + 0.25 * math.cos(g * 3))
            spark(c, tip + 18, 560, size, rot=g * 30)
        c = grade(c, cold=0.5 * (1 - warm), warm=warm)
        c = zoom(c, 1.22 + 0.06 * smooth(t / d), 1060, 470)
        return vignette(c, 0.45)

    def s15(self, t, d):
        c = self.desk.copy()
        day = min(5, int(t))
        frac = t - int(t)
        sunbeam(c, frac, 0.9)
        motes(c, t, frac, 0.8)
        self.hero.draw(c, self.home_still, 560, 540)
        lines = ("Sharpy notes",) + tuple(NOTES_S15[:day + (1 if frac > 0.3 else 0)])
        notebook(lines, checks=True).draw(c, 1300, 640, scale=0.92)
        sp, _ = pencil(420 - day * 26, 46, 35)
        sp.draw(c, 1620, 900)
        calendar(6 + day, "NOV").draw(c, 1770, 360)
        badge = Image.new("RGBA", (260, 110), (0, 0, 0, 0))
        bd = ImageDraw.Draw(badge)
        bd.rounded_rectangle((0, 0, 259, 109), radius=55, fill=(255, 255, 255, 235))
        bd.text((26, 8), "\U0001F525", font=font("emoji", 66), embedded_color=True)
        bd.text((120, 12), str(7 + day), font=font("black", 70), fill=(232, 120, 40))
        Sprite(badge, (4, 8, 10, 0.3)).draw(c, 1500, 360)
        narration(c, "A few minutes a day. Let AI do the busywork.", t, 0.4)
        return vignette(grade(c, warm=1.0), 0.3)

    def s16(self, t, d):
        c = self.meeting_sharp.copy()
        nod = int(8 * math.sin(prog(t, 4.7, 5.5) * math.pi * 2)) if 4.7 < t < 5.5 else 0
        self.table(c, True, nod=nod)
        sunbeam(c, 0.55, 0.9)
        c = grade(c, warm=1.0)
        say(c, "…since the Fed was created after the Great Depression—", (690, 770), 0.3, t,
            name="Intern", accent=(200, 100, 40), reveal=1.7, tail="down", tail_at=0.35, maxw=560,
            faded=round(prog(t, 2.6, 3.0) * 10) / 10)
        say(c, "Nineteen-thirteen, actually. After a string of bank panics.", (1130, 770), 2.4, t,
            name="Maya", accent=(170, 120, 30), reveal=1.6, tail="down", tail_at=0.25, maxw=560)
        say(c, "Good catch.", (790, 300), 4.7, t, name="Manager", accent=(70, 110, 170), tail="up", tail_at=0.2)
        return vignette(c, 0.35)

    SKY = [  # strokes on the paper, in paper coordinates, drawn in order
        ("circle", (110, 200, 46)),
        ("rays", (110, 200)),
        ("line", [(170, 200), (560, 200)]), ("label", ("red", 470, 160)),
        ("dots", [(330, 200), (345, 186), (322, 214), (352, 210)]),
        ("line", [(338, 200), (300, 70)]), ("line", [(338, 200), (470, 92)]),
        ("line", [(338, 200), (440, 330)]), ("line", [(338, 200), (230, 330)]),
        ("label", ("blue", 210, 60)), ("label", ("blue", 470, 300)),
    ]

    def sky_drawing(self, p):
        w, h = 620, 420
        img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        steps = len(self.SKY)
        done = p * steps
        tip = None
        col = (66, 66, 84, 255)
        for i, (kind, data) in enumerate(self.SKY):
            q = clamp(done - i)
            if q <= 0:
                break
            if kind == "circle":
                cx, cy, r = data
                pts = [(cx + r * math.cos(a / 40 * 2 * math.pi * q), cy + r * math.sin(a / 40 * 2 * math.pi * q))
                       for a in range(41)]
                d.line(pts, fill=col, width=4)
                tip = pts[-1]
            elif kind == "rays":
                cx, cy = data
                for j in range(int(8 * q)):
                    a = j / 8 * 2 * math.pi
                    d.line((cx + 58 * math.cos(a), cy + 58 * math.sin(a), cx + 80 * math.cos(a), cy + 80 * math.sin(a)),
                           fill=col, width=4)
                tip = (cx + 80, cy)
            elif kind == "line":
                (x0, y0), (x1, y1) = data
                x, y = x0 + (x1 - x0) * q, y0 + (y1 - y0) * q
                d.line((x0, y0, x, y), fill=col, width=4)
                if q > 0.85:
                    a = math.atan2(y1 - y0, x1 - x0)
                    for s in (-1, 1):
                        d.line((x1, y1, x1 - 18 * math.cos(a + s * 0.5), y1 - 18 * math.sin(a + s * 0.5)), fill=col, width=4)
                tip = (x, y)
            elif kind == "dots":
                for x, y in data[:max(1, int(len(data) * q))]:
                    d.ellipse((x - 6, y - 6, x + 6, y + 6), fill=col)
                tip = data[-1]
            else:
                text, x, y = data
                f = hand(40)
                n = max(1, int(len(text) * q))
                d.text((x, y), text[:n], font=f, fill=(60, 90, 200, 255) if text == "blue" else (190, 60, 60, 255))
                tip = (x + d.textlength(text[:n], font=f), y + 30)
        return img, tip

    def s17(self, t, d):
        c = self.living_sharp.copy()
        paper = Sprite(Image.new("RGBA", (620, 420), (252, 251, 247, 255)), (6, 10, 12, 0.35))
        px, py = 900, 495
        paper.draw(c, px, py)
        art, tip = self.sky_drawing(prog(t, 0.3, 4.6))
        put(c, art, px - 310, py - 210)
        self.living(c, True)
        sp, (tx, ty) = pencil(300, 34, 135)
        if tip and t < 4.7:
            sp.draw(c, px - 310 + tip[0] - tx, py - 210 + tip[1] - ty)
        else:
            sp.draw(c, 1300, 520)
        glow(c, 230, 170, 520, (255, 200, 120), 0.35)
        c = grade(c, warm=1.0)
        say(c, "The air scatters blue light much more than red, so blue comes at you from all over the sky.",
            (1215, 780), 0.5, t, name="Maya", accent=(170, 120, 30), reveal=2.7, tail="down", tail_at=0.06, maxw=600)
        say(c, "Whoa.", (760, 770), 4.8, t, name="Niece", accent=(60, 140, 80), tail="down", tail_at=0.35, size=40)
        if t > 4.85:
            spark(c, 640, 580, 70 * ease_back(min(1, (t - 4.85) / 0.4)), rot=(t - 4.85) * 40)
        return vignette(c, 0.3)

    def s18(self, t, d):
        c = self.desk.copy()
        sunbeam(c, 0.2, 1.0)
        sp, (tx, ty) = pencil(340, 66, 45)
        cx, cy = 900, 600
        sp.draw(c, cx, cy)
        motes(c, t, 0.2, 1.0)
        sx, sy = cx + tx + 22, cy + ty - 22
        if t > 1.3:
            g = t - 1.3
            size = 170 * ease_back(min(1, g / 0.5)) + 260 * ease(prog(t, 2.6, 3.4))
            spark(c, sx, sy, size, rot=g * 25)
        c = grade(c, warm=0.8)
        z = 1 + 0.45 * smooth(prog(t, 0, 3.4))
        c = zoom(c, z, sx, sy)
        narration(c, "AI can answer anything. Sharpy makes sure you still can.", t, 0.2, 2.9, where="bottom")
        # Where the spark sits on screen after the zoom.
        zx = W / 2 + (sx - min(max(sx, W / 2 / z), W - W / 2 / z)) * z
        zy = H / 2 + (sy - min(max(sy, H / 2 / z), H - H / 2 / z)) * z
        w = ease(prog(t, 3.1, 3.9))
        if w > 0:
            end = self.cards.bg.copy()
            r = 40 + 2300 * w
            m = Image.new("L", (W, H), 0)
            ImageDraw.Draw(m).ellipse((zx - r, zy - r, zx + r, zy + r), fill=255)
            mv = ease(prog(t, 3.3, 4.3))
            size = round(110 + 80 * mv)
            icon = self.cards.icon_small.resize((size, size), Image.LANCZOS)
            ix, iy = zx + (W / 2 - zx) * mv, zy + (300 - zy) * mv
            put(end, icon, ix - size / 2, iy - size / 2, ease(prog(t, 3.2, 3.5)))
            c.paste(end, (0, 0), m)
        return vignette(c, 0.3 * (1 - w)) if w < 1 else c

    def end(self, t, d):
        cards = self.cards
        c = cards.bg.copy()
        put(c, cards.icon_small, W / 2 - 95, 300 - 95)
        a = ease(t / 0.6)
        put(c, cards.title, W / 2 - cards.title.width / 2, 420 + (1 - a) * 30, a)
        b = ease((t - 0.5) / 0.6)
        put(c, cards.outro_tag, W / 2 - cards.outro_tag.width / 2, 590 + (1 - b) * 24, b)
        q = ease((t - 1.1) / 0.6)
        put(c, cards.pill, W / 2 - cards.pill.width / 2, 700 + (1 - q) * 20, q)
        out = ease((t - (d - 1.2)) / 1.2)
        if out > 0:
            c = Image.blend(c, Image.new("RGB", (W, H), (0, 0, 0)), out)
        return c

    def frame(self, t):
        for name, dur in SCENES:
            if t < STARTS[name] + dur or name == SCENES[-1][0]:
                return getattr(self, name)(t - STARTS[name], dur)


def cue_list():
    cues = []
    for name, items in CUES.items():
        for at, kind, params in items:
            cues.append((STARTS[name] + at, kind, params))
    return sorted(cues, key=lambda c: c[0])


SECTIONS = {
    "tape": STARTS["s4"] + 6.2, "act2": STARTS["s5"], "dark": STARTS["s10"], "dark_end": STARTS["s12"],
    "act3": STARTS["s14"], "note": STARTS["s14"] + 3.7, "arp": STARTS["ins_b"], "strings": STARTS["ins_b"] + 4.0,
    "kick": STARTS["s15"], "claps": STARTS["s16"], "resolve": STARTS["end"],
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tour", required=True)
    ap.add_argument("--icon", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--work")
    ap.add_argument("--still", help="comma-separated seconds: write PNG frames instead of the film")
    ap.add_argument("--audio-only", action="store_true", help="redo the soundtrack on the last rendered picture")
    a = ap.parse_args()
    work = a.work or os.path.join(os.path.dirname(os.path.abspath(a.out)), "work")
    os.makedirs(work, exist_ok=True)

    marks = mi.load_marks(a.tour)
    cfr, t0, _ = mi.tour_cfr(a.tour, work, marks)
    rel = {k: v - t0 for k, v in marks.items()}
    film = Film(a.icon, cfr, rel)

    if a.still:
        base = os.path.splitext(a.out)[0]
        for s in a.still.split(","):
            t = float(s)
            name = next(n for n, d in SCENES if t < STARTS[n] + d)
            if name.startswith("ins"):
                film.clips[name] = Clip(film.clips[name].path, film.clips[name].segs, film.clips[name].speed)
            path = f"{base}-{t:06.2f}.png"
            film.frame(t).save(path)
            print("wrote", path)
        return

    silent = os.path.join(work, "promo-video.mp4")
    if not a.audio_only:
        writer = subprocess.Popen([mi.FFMPEG, "-y", "-v", "error", "-f", "rawvideo", "-pix_fmt", "rgb24",
                                   "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-", "-c:v", "libx264", "-preset", "medium",
                                   "-crf", "17", "-pix_fmt", "yuv420p", "-movflags", "+faststart", silent],
                                  stdin=subprocess.PIPE)
        current = None
        for f in range(int(round(TOTAL * FPS))):
            t = f / FPS
            writer.stdin.write(film.frame(t).convert("RGB").tobytes())
            name = next(n for n, d in SCENES if t < STARTS[n] + d or n == SCENES[-1][0])
            if name != current:
                current = name
                print(f"  {name} at {t:6.2f}s", flush=True)
        writer.stdin.close()
        writer.wait()
    for clip in film.clips.values():
        clip.close()

    audio = os.path.join(work, "promo-audio.wav")
    promo_audio.render(cue_list(), SECTIONS, TOTAL, audio)
    mi.run(["-y", "-v", "error", "-i", silent, "-i", audio, "-map", "0:v", "-map", "1:a", "-c:v", "copy",
            "-c:a", "aac", "-b:a", "192k", "-t", f"{TOTAL:.3f}", "-movflags", "+faststart", a.out])
    sheet = os.path.splitext(a.out)[0] + "-contact.png"
    mi.run(["-y", "-v", "error", "-i", a.out, "-vf", "fps=1/4,scale=384:-2,tile=6x5:padding=6:margin=6:color=white",
            "-frames:v", "1", sheet])
    print(f"done: {a.out} ({TOTAL:.1f}s), contact sheet {sheet}")


if __name__ == "__main__":
    main()
