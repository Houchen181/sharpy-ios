#!/usr/bin/env python3
"""Edit the recorded simulator tour into Sharpy's 3-minute intro video (1920x1080).

    python tools/make_intro.py --tour <dir with raw.mp4, marks.txt, rec_start.txt> \
        --icon Sharpy/Assets.xcassets/AppIcon.appiconset/icon-1024.png \
        --music music.wav --out marketing/sharpy-intro-1920x1080.mp4

The tour comes from CI (Actions -> iOS -> Run workflow -> video). Title and
explainer cards are drawn here; footage sits in a phone frame on the right with
captions on the left. Still stretches in the footage (XCTest waiting, or long
reading pauses) are cut down to a hold length chosen so the whole video lands on
exactly --seconds. Music comes from tools/make_music.py.

Requires Pillow and numpy; ffmpeg from $FFMPEG, imageio-ffmpeg, or PATH.
"""
import argparse
import math
import os
import re
import subprocess

from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H, FPS = 1920, 1080, 30
TOP, BOTTOM = (104, 92, 255), (36, 22, 128)
AMBER = (255, 196, 61)
WHITE = (255, 255, 255)

# Phone frame: screen keeps the simulator's 1320x2868 aspect.
SCREEN_H = 970
SCREEN_W = 446
BEZEL = 15
FRAME_X, FRAME_Y = 1150, (H - SCREEN_H - 2 * BEZEL) // 2
SCREEN_X, SCREEN_Y = FRAME_X + BEZEL, FRAME_Y + BEZEL
TEXT_X, TEXT_W = 150, 800

FONT_DIR = "C:/Windows/Fonts" if os.name == "nt" else "/System/Library/Fonts/Supplemental"
FONTS = {
    "black": "seguibl.ttf", "bold": "segoeuib.ttf", "semibold": "seguisb.ttf",
    "regular": "segoeui.ttf", "emoji": "seguiemj.ttf",
}

# (mark, seconds after mark, label, headline, subline). A caption shows until the
# next one starts. Offsets > 0 anchor on the visible change nearest that moment.
CAPTIONS = [
    ("welcome", 0, "Get started", "Start with what you know", "Or with something you've always wanted to learn."),
    ("topics", 0, "Your topics", "Pick up to five topics", "Your field, a hobby, anything. Sharpy builds questions for each one."),
    ("level", 0, "Your level", "Choose how deep to go", "From curious beginner to working professional."),
    ("goal", 0, "Daily goal", "Keep it small and steady", "Five, ten or fifteen questions a day."),
    ("reminder", 0, "Reminders", "Pick a time to be nudged", "One reminder a day. Nothing else."),
    ("home", 0, "Train", "Your daily workout", "A ring for today's goal, and a streak worth protecting."),
    ("start", 0, "Fresh questions", "Researched from trusted sources",
     "Claude searches encyclopedias, journals and official sites, then double-checks every answer."),
    ("q_true_false", 0, "True or false", "Some statements are traps", "They sound right, but one detail is wrong. Can you catch it?"),
    ("q_true_false", 3.6, "Cited", "Every answer shows its source", "The exact sentence it came from, one tap from the full page."),
    ("q_single", 0, "Pick one", "Single-answer questions", "With distractors built from real misconceptions."),
    ("q_single", 3.1, "Learn from misses", "Wrong answers teach too", "Sharpy names the misconception that fooled you."),
    ("q_select_all", 0, "Select all that apply", "Multi-choice questions", "Tick every correct option. Partly right doesn't count."),
    ("q_spot", 0, "Spot the error", "One sentence is wrong", "Read closely. The mistake is a single detail."),
    ("q_last", 0, "Spaced review", "Misses come back", "Right before you'd forget them, so they stick."),
    ("summary", 0, "Streak", "Goal met, streak extended", "XP, accuracy and traps caught for every session."),
    ("home_done", 0, "Done for today", "Five minutes well spent", "Your own thinking got a real workout."),
    ("discover", 0, "Discover", "Learn something new every day", "A field of the day, history, space and great science writing."),
    ("discover_check", 0, "Check yourself", "Every card ends with a question", "Quick recall makes new ideas stick."),
    ("papers", 0, "New in your fields", "Fresh research, in plain words",
     "Recent papers summarized from their abstracts. Preprints are clearly labelled."),
    ("profile", 0, "Progress", "Watch your streak grow", "Accuracy, XP and traps caught, all in one place."),
    ("about", 4.2, "Transparency", "Honest about how it works", "See exactly where questions come from and how they're checked."),
]

# Footage parts (start mark, end mark) with the cards around them.
PARTS = [("welcome", "home"), ("home", "profile"), ("profile", "end")]
CARD_SECONDS = {"intro": 6.5, "problem": 11.0, "later": 3.0, "nudges": 7.0, "how": 15.0, "outro": 7.5}

# Relative hold per tour step: how long a still screen may stay, before scaling to
# fit. Waiting and typing get little; reading an answer's explanation gets the most.
HOLDS = {
    "welcome": 3.0, "topics": 0.7, "level": 1.0, "goal": 1.0, "reminder": 1.1, "home": 2.4, "start": 1.6,
    "question": 1.9, "feedback": 4.2, "summary": 2.6, "home_done": 1.8,
    "discover": 2.0, "discover_check": 2.0, "papers": 2.2, "profile": 1.8, "about": 3.2,
}
# Seconds after a question's mark when the learner answers (the tour's reading pause).
ANSWER_AT = {"q_true_false": 3.4, "q_single": 2.9, "q_select_all": 6.2, "q_spot": 4.4, "q_last": 2.9}
FADE = 0.45


# ---------- helpers ----------

def ffmpeg_exe():
    if os.environ.get("FFMPEG"):
        return os.environ["FFMPEG"]
    try:
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    except ImportError:
        return "ffmpeg"


FFMPEG = ffmpeg_exe()


def run(args, capture=False):
    print("+ ffmpeg", " ".join(args[:12]), "…" if len(args) > 12 else "", flush=True)
    r = subprocess.run([FFMPEG, *args], check=True, capture_output=capture, text=capture,
                       encoding="utf-8" if capture else None, errors="replace" if capture else None)
    return r.stderr if capture else None


def font(kind, size):
    return ImageFont.truetype(os.path.join(FONT_DIR, FONTS[kind]), size)


def ease(x):
    x = min(1.0, max(0.0, x))
    return 1 - (1 - x) ** 3


def ease_back(x):
    x = min(1.0, max(0.0, x))
    c = 1.4
    return 1 + (c + 1) * (x - 1) ** 3 + c * (x - 1) ** 2


def gradient(w, h, top=TOP, bottom=BOTTOM):
    small = Image.new("RGB", (64, 64))
    px = small.load()
    for y in range(64):
        for x in range(64):
            t = min(1.0, (x * 0.35 + y * 0.65) / 63)
            px[x, y] = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    return small.resize((w, h), Image.BILINEAR)


def wrap(text, fnt, max_w):
    draw = ImageDraw.Draw(Image.new("L", (1, 1)))
    lines, line = [], ""
    for word in text.split():
        trial = f"{line} {word}".strip()
        if draw.textlength(trial, font=fnt) <= max_w or not line:
            line = trial
        else:
            lines.append(line)
            line = word
    if line:
        lines.append(line)
    return lines


def text_layer(lines, fnt, fill, spacing=1.22, tracking=0):
    """A tight RGBA image of left-aligned lines."""
    draw = ImageDraw.Draw(Image.new("L", (1, 1)))
    lh = round(fnt.size * spacing)
    width = max(draw.textlength(l, font=fnt) + tracking * len(l) for l in lines) + 8
    img = Image.new("RGBA", (int(width), lh * len(lines) + round(fnt.size * 0.35)), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    for i, l in enumerate(lines):
        if tracking:
            x = 0.0
            for ch in l:
                d.text((x, i * lh), ch, font=fnt, fill=fill)
                x += d.textlength(ch, font=fnt) + tracking
        else:
            d.text((0, i * lh), l, font=fnt, fill=fill)
    return img


def with_alpha(img, a):
    if a >= 0.999:
        return img
    out = img.copy()
    out.putalpha(img.getchannel("A").point(lambda v: int(v * max(0.0, a))))
    return out


def put(canvas, img, x, y, alpha=1.0):
    if alpha <= 0.001:
        return
    layer = with_alpha(img, alpha)
    canvas.paste(layer, (int(round(x)), int(round(y))), layer)


def rounded_mask(w, h, r):
    m = Image.new("L", (w, h), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, w - 1, h - 1), radius=r, fill=255)
    return m


def rounded_icon(path, size):
    icon = Image.open(path).convert("RGBA").resize((size, size), Image.LANCZOS)
    icon.putalpha(rounded_mask(size, size, round(size * 0.225)))
    return icon


def shadow_for(img, blur=26, alpha=110, spread=0):
    pad = blur * 3
    sh = Image.new("RGBA", (img.width + 2 * pad, img.height + 2 * pad), (0, 0, 0, 0))
    sil = Image.new("RGBA", img.size, (12, 6, 50, alpha))
    sh.paste(sil, (pad, pad), img.getchannel("A"))
    return sh.filter(ImageFilter.GaussianBlur(blur)), pad


# ---------- phone frame ----------

def phone_parts():
    fw, fh = SCREEN_W + 2 * BEZEL, SCREEN_H + 2 * BEZEL
    frame = Image.new("RGBA", (fw, fh), (0, 0, 0, 0))
    d = ImageDraw.Draw(frame)
    d.rounded_rectangle((0, 0, fw - 1, fh - 1), radius=72, fill=(18, 16, 30, 255))
    d.rounded_rectangle((3, 3, fw - 4, fh - 4), radius=69, outline=(70, 66, 96, 255), width=2)
    hole = rounded_mask(SCREEN_W, SCREEN_H, 56)
    alpha = frame.getchannel("A")
    alpha.paste(0, (BEZEL, BEZEL), hole)
    frame.putalpha(alpha)
    shadow, pad = shadow_for(Image.new("RGBA", (fw, fh), (0, 0, 0, 255)).copy(), blur=34, alpha=150)
    full_shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    full_shadow.paste(shadow, (FRAME_X - pad, FRAME_Y - pad + 22), shadow)
    return frame, hole, full_shadow


# ---------- captions ----------

def caption_art(label, headline, sub):
    lab = text_layer([label.upper()], font("semibold", 26), AMBER + (255,), tracking=3)
    head = text_layer(wrap(headline, font("bold", 66), TEXT_W), font("bold", 66), WHITE + (255,), spacing=1.12)
    body = text_layer(wrap(sub, font("regular", 34), TEXT_W - 40), font("regular", 34), WHITE + (215,), spacing=1.35)
    gap1, gap2 = 18, 26
    total = lab.height + gap1 + head.height + gap2 + body.height
    top = (H - total) // 2
    return [(lab, top), (head, top + lab.height + gap1), (body, top + lab.height + gap1 + head.height + gap2)]


def draw_caption(canvas, art, t_in, t_out, t):
    """Each line fades and rises in, staggered; all fade out together."""
    out = 1 - ease((t - (t_out - 0.35)) / 0.35) if t > t_out - 0.35 else 1.0
    for i, (img, y) in enumerate(art):
        p = ease((t - t_in - i * 0.12) / 0.5)
        put(canvas, img, TEXT_X, y + (1 - p) * 26, p * out)


# ---------- cards ----------

class Cards:
    def __init__(self, icon_path):
        self.bg = gradient(W, H)
        self.icon_path = icon_path
        self.icon_big = rounded_icon(icon_path, 250)
        self.icon_shadow = shadow_for(self.icon_big, blur=30, alpha=120)
        self.icon_small = rounded_icon(icon_path, 190)
        self.icon_tiny = rounded_icon(icon_path, 40)
        self.title = text_layer(["Sharpy"], font("black", 128), WHITE + (255,))
        self.tag = text_layer(["Stay sharp in the age of AI."], font("semibold", 48), WHITE + (230,))
        self.outro_tag = text_layer(["Think for yourself. Every day."], font("semibold", 48), WHITE + (230,))
        pill_font = font("semibold", 34)
        label = "Coming soon to the App Store"
        pw = int(ImageDraw.Draw(Image.new("L", (1, 1))).textlength(label, font=pill_font)) + 80
        self.pill = Image.new("RGBA", (pw, 84), (0, 0, 0, 0))
        pd = ImageDraw.Draw(self.pill)
        pd.rounded_rectangle((0, 0, pw - 1, 83), radius=42, fill=WHITE + (255,))
        pd.text((40, 18), label, font=pill_font, fill=(66, 52, 200, 255))

        self.problem_label = text_layer(["WHY SHARPY"], font("semibold", 28), AMBER + (255,), tracking=4)
        self.problem_lines = [
            text_layer(wrap("AI can answer almost anything, instantly.", font("bold", 72), 1500), font("bold", 72), WHITE + (255,)),
            text_layer(wrap("That's useful. It also makes it easy to stop thinking for yourself.", font("regular", 46), 1400),
                       font("regular", 46), WHITE + (225,), spacing=1.3),
            text_layer(wrap("Sharpy is a few minutes a day of real thinking: questions you answer yourself, "
                            "with convincing traps mixed in.", font("semibold", 46), 1400),
                       font("semibold", 46), AMBER + (255,), spacing=1.3),
        ]

        self.later = text_layer(["12 days later"], font("black", 96), WHITE + (255,))
        self.later_sub = text_layer(["One small habit, every day."], font("regular", 42), WHITE + (220,))
        self.flame = Image.new("RGBA", (150, 150), (0, 0, 0, 0))
        ImageDraw.Draw(self.flame).text((8, 0), "\U0001F525", font=font("emoji", 110), embedded_color=True)

        self.how_label = text_layer(["HOW SHARPY STAYS HONEST"], font("semibold", 28), AMBER + (255,), tracking=4)
        steps = [
            ("Research", "Claude searches only trusted sources: encyclopedias, peer-reviewed journals, "
                         "government and university sites, and official documentation."),
            ("Write", "Questions are written from facts that carry a citation, including the deliberate traps."),
            ("Check", "An independent pass answers every question from the cited text alone. "
                      "If it disagrees, the question is thrown out."),
        ]
        self.how_steps = []
        for i, (title, desc) in enumerate(steps):
            num = Image.new("RGBA", (84, 84), (0, 0, 0, 0))
            nd = ImageDraw.Draw(num)
            nd.ellipse((0, 0, 83, 83), fill=AMBER + (255,))
            nf = font("black", 44)
            tw = nd.textlength(str(i + 1), font=nf)
            nd.text(((84 - tw) / 2, 10), str(i + 1), font=nf, fill=(40, 26, 140, 255))
            t_img = text_layer([title], font("bold", 52), WHITE + (255,))
            d_img = text_layer(wrap(desc, font("regular", 34), 1280), font("regular", 34), WHITE + (220,), spacing=1.32)
            self.how_steps.append((num, t_img, d_img))
        self.how_footer = text_layer(["Spot a problem? Two reports remove a question for everyone."],
                                     font("semibold", 34), AMBER + (255,))

        self.nudge_caption = caption_art("Reminders", "A nudge, not a nag",
                                         "One reminder a day, plus an evening nudge only when your streak is at risk.")
        self.lock = self._lock_screen()
        self.notes = [
            self._notification("Can you spot today's trap?", "Sharpy hid a convincing wrong statement in today's set.", "12h ago"),
            self._notification("\U0001F525 Your 13-day streak is on the line", "One quick set keeps it alive.", "now"),
        ]

    # Lock screen and notifications are drawn at screen resolution for the phone frame.
    def _lock_screen(self):
        img = gradient(SCREEN_W, SCREEN_H, (50, 40, 150), (14, 10, 52)).convert("RGBA")
        d = ImageDraw.Draw(img)
        date = "Monday, November 2"
        df = font("semibold", 20)
        d.text(((SCREEN_W - d.textlength(date, font=df)) / 2, 92), date, font=df, fill=WHITE + (220,))
        tf = font("semibold", 96)
        d.text(((SCREEN_W - d.textlength("8:30", font=tf)) / 2, 108), "8:30", font=tf, fill=WHITE + (245,))
        island = (SCREEN_W // 2 - 62, 16, SCREEN_W // 2 + 62, 52)
        d.rounded_rectangle(island, radius=18, fill=(0, 0, 0, 255))
        return img

    def _notification(self, title, body, when):
        w = SCREEN_W - 28
        title_f, body_f, small_f = font("bold", 19), font("regular", 18), font("regular", 15)
        body_lines = wrap(body, body_f, w - 86)
        title_lines = wrap(title, title_f, w - 86)
        h = 34 + 24 * len(title_lines) + 23 * len(body_lines) + 14
        card = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        d = ImageDraw.Draw(card)
        d.rounded_rectangle((0, 0, w - 1, h - 1), radius=24, fill=(245, 243, 255, 215))
        card.paste(self.icon_tiny, (14, 16), self.icon_tiny)
        d.text((66, 12), "Sharpy", font=font("semibold", 15), fill=(60, 56, 80, 255))
        d.text((w - 16 - d.textlength(when, font=small_f), 12), when, font=small_f, fill=(90, 86, 110, 255))
        y = 32
        for line in title_lines:
            if line.startswith("\U0001F525"):
                d.text((66, y + 1), "\U0001F525", font=font("emoji", 16), embedded_color=True)
                d.text((66 + 26, y), line[1:].strip(), font=title_f, fill=(20, 18, 30, 255))
            else:
                d.text((66, y), line, font=title_f, fill=(20, 18, 30, 255))
            y += 24
        for line in body_lines:
            d.text((66, y), line, font=body_f, fill=(40, 38, 54, 255))
            y += 23
        return card

    def intro(self, t, dur):
        c = self.bg.copy()
        out = 1 - ease((t - (dur - FADE)) / FADE)
        p = ease_back(t / 0.7)
        size = max(8, int(250 * (0.55 + 0.45 * p)))
        icon = self.icon_big.resize((size, size), Image.LANCZOS)
        cy = 330
        sh, pad = self.icon_shadow
        put(c, sh, W / 2 - 125 - pad, cy - 125 - pad + 18, min(1, t / 0.6) * out)
        put(c, icon, W / 2 - size / 2, cy - size / 2, min(1, t / 0.35) * out)
        a = ease((t - 0.5) / 0.6)
        put(c, self.title, W / 2 - self.title.width / 2, 500 + (1 - a) * 30, a * out)
        b = ease((t - 1.1) / 0.6)
        put(c, self.tag, W / 2 - self.tag.width / 2, 670 + (1 - b) * 24, b * out)
        return c

    def problem(self, t, dur):
        c = self.bg.copy()
        out = 1 - ease((t - (dur - FADE)) / FADE)
        x = 200
        put(c, self.problem_label, x, 380, ease(t / 0.5) * out)
        ys, starts = [440, 560, 700], [0.4, 3.4, 6.8]
        for img, y, s in zip(self.problem_lines, ys, starts):
            p = ease((t - s) / 0.7)
            put(c, img, x, y + (1 - p) * 30, p * out)
        return c

    def later_card(self, t, dur):
        c = self.bg.copy()
        a = ease(t / 0.4) * (1 - ease((t - (dur - 0.4)) / 0.4))
        put(c, self.flame, W / 2 - self.flame.width / 2 - 8, 300 + (1 - ease(t / 0.6)) * 20, a)
        put(c, self.later, W / 2 - self.later.width / 2, 470, a)
        put(c, self.later_sub, W / 2 - self.later_sub.width / 2, 610, a)
        return c

    def nudges(self, t, dur, phone):
        c = self.bg.copy()
        out = 1 - ease((t - (dur - FADE)) / FADE)
        screen = self.lock.copy()
        for i, (note, start) in enumerate(zip(self.notes, [0.8, 2.6])):
            p = ease((t - start) / 0.5)
            if p > 0:
                y = 330 + i * (self.notes[0].height + 12)
                put(screen, note, 14, y - (1 - p) * 40, p)
        a = ease(t / FADE) * out
        phone.compose(c, screen.convert("RGB"), a)
        draw_caption(c, self.nudge_caption, 0.2, dur, t)
        if out < 1:
            c = Image.blend(self.bg, c, max(0.0, out))
        return c

    def how(self, t, dur):
        c = self.bg.copy()
        out = 1 - ease((t - (dur - FADE)) / FADE)
        x = 200
        put(c, self.how_label, x, 150, ease(t / 0.5) * out)
        y = 230
        for i, (num, title, desc) in enumerate(self.how_steps):
            p = ease((t - (0.6 + i * 3.6)) / 0.6)
            dy = (1 - p) * 26
            put(c, num, x, y + dy, p * out)
            put(c, title, x + 120, y - 6 + dy, p * out)
            put(c, desc, x + 120, y + 64 + dy, p * out)
            y += 90 + desc.height + 50
        f = ease((t - 11.5) / 0.6)
        put(c, self.how_footer, x, 900 + (1 - f) * 16, f * out)
        return c

    def outro(self, t, dur):
        c = self.bg.copy()
        p = ease_back(t / 0.7)
        size = max(8, int(190 * (0.6 + 0.4 * p)))
        icon = self.icon_small.resize((size, size), Image.LANCZOS)
        put(c, icon, W / 2 - size / 2, 300 - size / 2, min(1, t / 0.35))
        a = ease((t - 0.4) / 0.6)
        put(c, self.title, W / 2 - self.title.width / 2, 420 + (1 - a) * 30, a)
        b = ease((t - 0.9) / 0.6)
        put(c, self.outro_tag, W / 2 - self.outro_tag.width / 2, 590 + (1 - b) * 24, b)
        q = ease((t - 1.6) / 0.6)
        put(c, self.pill, W / 2 - self.pill.width / 2, 700 + (1 - q) * 20, q)
        end = ease((t - (dur - 1.2)) / 1.2)          # fade to black at the very end
        if end > 0:
            c = Image.blend(c, Image.new("RGB", (W, H), (0, 0, 0)), end)
        return c


class Phone:
    def __init__(self):
        self.frame, self.hole, self.shadow = phone_parts()

    def compose(self, canvas, screen_rgb, alpha=1.0, dy=0.0):
        """Draws the phone with `screen_rgb` (SCREEN_W x SCREEN_H) onto canvas."""
        if alpha <= 0.001:
            return
        layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        layer.alpha_composite(self.shadow, (0, int(dy)))
        screen = screen_rgb.convert("RGBA")
        screen.putalpha(self.hole)
        layer.alpha_composite(screen, (SCREEN_X, SCREEN_Y + int(dy)))
        layer.alpha_composite(self.frame, (FRAME_X, FRAME_Y + int(dy)))
        if alpha < 0.999:
            layer.putalpha(layer.getchannel("A").point(lambda v: int(v * alpha)))
        canvas.paste(layer, (0, 0), layer)


# ---------- footage timeline ----------

def detect_freezes(video, duration):
    log = run(["-hide_banner", "-i", video, "-vf", "scale=207:-2,freezedetect=n=0.0003:d=0.4", "-f", "null", "-"],
              capture=True)
    starts = [float(x) for x in re.findall(r"freeze_start: ([\d.]+)", log)]
    ends = [float(x) for x in re.findall(r"freeze_end: ([\d.]+)", log)]
    ends += [duration] * (len(starts) - len(ends))
    return list(zip(starts, ends))


def scene_changes(video, threshold=0.05):
    log = run(["-hide_banner", "-i", video, "-vf", f"scale=207:-2,select='gt(scene,{threshold})',showinfo",
               "-f", "null", "-"], capture=True)
    return sorted(float(x) for x in re.findall(r"pts_time:([\d.]+)", log))


def keep_intervals(freezes, a, b, hold):
    """Parts of [a, b) to keep: each still stretch is cut to at most hold(start) seconds."""
    keeps, cursor = [], a
    for s, e in freezes:
        s, e = max(s, a), min(e, b)
        h = hold(s)
        if e - s > h:
            keeps.append((cursor, s + h))
            cursor = e
    keeps.append((cursor, b))
    return [(x, y) for x, y in keeps if y - x > 0.02]


def kept_length(keeps):
    return sum(y - x for x, y in keeps)


def to_kept(keeps, t):
    return sum(max(0.0, min(y, t) - x) for x, y in keeps)


def load_marks(tour):
    """TOURMARK name -> seconds from the start of raw.mp4."""
    rec_start = float(open(os.path.join(tour, "rec_start.txt")).read().strip())
    marks = {}
    for line in open(os.path.join(tour, "marks.txt"), encoding="utf-8", errors="replace"):
        parts = line.split()
        if "TOURMARK" in parts:
            i = parts.index("TOURMARK")
            if i + 2 < len(parts):
                marks.setdefault(parts[i + 1], float(parts[i + 2]) - rec_start)
    return marks


def tour_cfr(tour, work, marks):
    """Constant-frame-rate, phone-sized copy of the tour from just before "welcome"
    (simctl records variable frame rate, so convert the whole file before trimming).
    Returns (path, start in raw.mp4, duration)."""
    t0 = max(0.0, marks["welcome"] - 0.3)
    t1 = marks["end"] + 0.6
    cfr = os.path.join(work, "tour-cfr.mp4")
    if not os.path.exists(cfr):
        run(["-y", "-i", os.path.join(tour, "raw.mp4"), "-vf",
             f"fps={FPS},trim=start={t0:.3f}:end={t1:.3f},setpts=PTS-STARTPTS,scale={SCREEN_W}:{SCREEN_H}:flags=lanczos",
             "-an", "-c:v", "libx264", "-preset", "fast", "-crf", "12", cfr])
    return cfr, t0, t1 - t0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tour", required=True)
    ap.add_argument("--icon", required=True)
    ap.add_argument("--music")
    ap.add_argument("--out", required=True)
    ap.add_argument("--seconds", type=float, default=180.0)
    ap.add_argument("--work")
    a = ap.parse_args()
    work = a.work or os.path.join(os.path.dirname(os.path.abspath(a.out)), "work")
    os.makedirs(work, exist_ok=True)

    marks = load_marks(a.tour)
    missing = [m for m in {p for pair in PARTS for p in pair} if m not in marks]
    if missing:
        raise SystemExit(f"tour is missing marks: {missing}")

    # 1. Phone-sized, constant-frame-rate copy of the tour.
    cfr, t0, dur = tour_cfr(a.tour, work, marks)
    rel = {k: v - t0 for k, v in marks.items()}
    freezes = detect_freezes(cfr, dur)
    cuts = scene_changes(cfr)

    # 2. Scale the per-step holds so the footage fills the time left after the cards.
    budget = a.seconds - sum(CARD_SECONDS.values())

    # Trim each part to open on its own screen: the tour taps the You tab right after
    # the "profile" mark (once Discover stops scrolling, ~4.5 s), and closes the About
    # sheet about a second before "end".
    START_SHIFT = {"welcome": -0.25, "profile": 4.4}
    END_SHIFT = {"end": -1.2}
    spans = [(rel[s] + START_SHIFT.get(s, 0.0), rel[e] + END_SHIFT.get(e, 0.0)) for s, e in PARTS]

    order = sorted((t, name) for name, t in rel.items())

    def base_hold(t):
        step = next((name for mt, name in reversed(order) if mt <= t + 0.05), "welcome")
        if step in ANSWER_AT:
            return HOLDS["feedback"] if t >= rel[step] + ANSWER_AT[step] else HOLDS["question"]
        return HOLDS.get(step, 1.5)

    def total_for(k):
        return sum(kept_length(keep_intervals(freezes, x, y, lambda t: base_hold(t) * k)) for x, y in spans)

    lo, hi = 0.2, 4.0
    if total_for(lo) > budget:
        hold = lo
    elif total_for(hi) < budget:
        hold = hi
    else:
        for _ in range(40):
            mid = (lo + hi) / 2
            lo, hi = (mid, hi) if total_for(mid) < budget else (lo, mid)
        hold = lo
    part_keeps = [keep_intervals(freezes, x, y, lambda t: base_hold(t) * hold) for x, y in spans]
    footage = sum(kept_length(k) for k in part_keeps)
    speed = max(1.0, footage / budget)
    footage_out = footage / speed
    # Any slack (footage shorter than the budget) goes to the cards, proportionally.
    scale = (a.seconds - footage_out) / sum(CARD_SECONDS.values())
    cards_d = {k: v * scale for k, v in CARD_SECONDS.items()}
    print(f"footage {footage:.1f}s (holds x{hold:.2f}, speed x{speed:.3f}), cards x{scale:.3f}")

    # 3. Caption windows per part, in output seconds from the part's start.
    def snap(t, back=1.6, fwd=1.4):
        near = [c for c in cuts if t - back <= c <= t + fwd]
        return min(near, key=lambda c: abs(c - t)) if near else t

    part_caps = [[] for _ in PARTS]
    for mark, offset, label, head, sub in CAPTIONS:
        if mark not in rel:
            continue
        t = snap(rel[mark] + offset, back=0.4 if offset else 1.6, fwd=2.0 if offset else 1.4)
        # A caption landing in a trimmed gap between parts opens the next part.
        for pi, (x, y) in enumerate(spans):
            if t < y:
                t_out = to_kept(part_keeps[pi], max(t, x)) / speed
                part_caps[pi].append([max(0.0, t_out - 0.1), caption_art(label, head, sub)])
                break
    for pi, caps in enumerate(part_caps):
        caps.sort(key=lambda c: c[0])
        if caps:
            caps[0][0] = 0.0
        for i in range(1, len(caps)):
            caps[i][0] = max(caps[i][0], caps[i - 1][0] + 1.5)
    for pi, caps in enumerate(part_caps):
        seg = kept_length(part_keeps[pi]) / speed
        print(f"  part {pi} ({seg:.1f}s): " + ", ".join(f"{c[0]:.1f}" for c in caps))

    # 4. Render.
    cards = Cards(a.icon)
    phone = Phone()
    bg = cards.bg
    timeline = [
        ("card", "intro"), ("card", "problem"), ("part", 0), ("card", "later"),
        ("part", 1), ("card", "nudges"), ("part", 2), ("card", "how"), ("card", "outro"),
    ]
    total_frames = int(round(a.seconds * FPS))

    reader = subprocess.Popen([FFMPEG, "-v", "error", "-i", cfr, "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                              stdout=subprocess.PIPE)
    frame_bytes = SCREEN_W * SCREEN_H * 3
    state = {"idx": -1, "img": None}

    def frame_at(t):
        """Screen image at source time t (frames are read forward only)."""
        want = min(int(t * FPS), int(dur * FPS) - 1)
        while state["idx"] < want:
            buf = reader.stdout.read(frame_bytes)
            if len(buf) < frame_bytes:
                break
            state["idx"] += 1
            state["img"] = buf
        return Image.frombuffer("RGB", (SCREEN_W, SCREEN_H), state["img"], "raw", "RGB", 0, 1)

    silent = os.path.join(work, "intro-video.mp4")
    writer = subprocess.Popen([FFMPEG, "-y", "-v", "error", "-f", "rawvideo", "-pix_fmt", "rgb24",
                               "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-", "-c:v", "libx264", "-preset", "medium",
                               "-crf", "17", "-pix_fmt", "yuv420p", "-movflags", "+faststart", silent],
                              stdin=subprocess.PIPE)

    written = 0
    for kind, what in timeline:
        if kind == "card":
            seg = cards_d[what]
            fn = {"intro": cards.intro, "problem": cards.problem, "later": cards.later_card,
                  "how": cards.how, "outro": cards.outro}.get(what)
            n = int(round(seg * FPS))
            for f in range(n):
                t = f / FPS
                img = cards.nudges(t, seg, phone) if what == "nudges" else fn(t, seg)
                writer.stdin.write(img.tobytes())
            written += n
        else:
            keeps = part_keeps[what]
            seg = kept_length(keeps) / speed
            if what == len(PARTS) - 1:
                seg = max(0.0, (total_frames - written) / FPS - cards_d["how"] - cards_d["outro"])
            n = int(round(seg * FPS))
            caps = part_caps[what]
            for f in range(n):
                t = f / FPS
                # Output time -> kept time -> source time.
                k = t * speed
                src, acc = keeps[-1][1] - 1 / FPS, 0.0
                for x, y in keeps:
                    if acc + (y - x) > k:
                        src = x + (k - acc)
                        break
                    acc += y - x
                img = bg.copy()
                fade = ease(t / FADE) * (1 - ease((t - (seg - FADE)) / FADE))
                phone.compose(img, frame_at(src), fade, dy=(1 - ease(t / 0.6)) * 30)
                for i, (start, art) in enumerate(caps):
                    end = caps[i + 1][0] if i + 1 < len(caps) else seg
                    if start - 0.05 <= t < end:
                        draw_caption(img, art, start, end, t)
                writer.stdin.write(img.tobytes())
            written += n
        print(f"  {kind} {what}: until {written / FPS:6.1f}s", flush=True)

    writer.stdin.close()
    writer.wait()
    reader.kill()

    if a.music:
        run(["-y", "-v", "error", "-i", silent, "-i", a.music, "-map", "0:v", "-map", "1:a", "-c:v", "copy",
             "-c:a", "aac", "-b:a", "192k", "-af", f"volume=4dB,afade=t=out:st={a.seconds - 3:.2f}:d=3",
             "-t", f"{a.seconds:.3f}", "-movflags", "+faststart", a.out])
    else:
        os.replace(silent, a.out)
    sheet = os.path.splitext(a.out)[0] + "-contact.png"
    run(["-y", "-v", "error", "-i", a.out, "-vf", "fps=1/6,scale=384:-2,tile=6x5:padding=6:margin=6:color=white",
         "-frames:v", "1", sheet])
    print(f"done: {a.out} ({written / FPS:.1f}s), contact sheet {sheet}")


if __name__ == "__main__":
    main()
