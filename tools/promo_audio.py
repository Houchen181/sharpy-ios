"""Score and sound effects for the promo film (tools/make_promo.py), synthesized with
numpy, so there is nothing to license.

render(cues, sections, seconds, path) writes a 44.1 kHz stereo WAV:
- cues are (time, kind, params) sound effects: pops, ticks, the sharpener...
- sections are the times the score follows. Act 1 is a light marimba groove that
  slows to a stop like a tape; act 2 is a low drone under the clock; act 3 starts on
  one piano note and builds to a warm resolve under the end card.
"""
import wave

import numpy as np

RATE = 44100
BEAT = 0.6                      # 100 BPM
rng = np.random.default_rng(23)


def hz(m):
    return 440.0 * 2 ** ((m - 69) / 12)


def axis(sec):
    return np.arange(int(sec * RATE)) / RATE


def filt(x, lo=None, hi=None, order=2):
    """Gentle FFT band filter (Butterworth-shaped magnitude)."""
    n = len(x)
    if n < 4:
        return x
    f = np.fft.rfftfreq(n, 1 / RATE)
    g = np.ones_like(f)
    if hi:
        g /= 1 + (f / hi) ** (2 * order)
    if lo:
        g /= 1 + (lo / np.maximum(f, 1e-3)) ** (2 * order)
    return np.fft.irfft(np.fft.rfft(x) * g, n)


def env(n, a=0.005, r=0.05):
    e = np.ones(n)
    ai, ri = min(n, max(1, int(a * RATE))), min(n, max(1, int(r * RATE)))
    e[:ai] = np.linspace(0, 1, ai)
    e[n - ri:] *= np.linspace(1, 0, ri)
    return e


def noise(sec):
    return rng.normal(0, 1, int(sec * RATE))


# ---------- instruments ----------

def marimba(f, dur=0.7):
    t = axis(dur)
    s = (np.sin(2 * np.pi * f * t) * np.exp(-t * 7) + 0.35 * np.sin(2 * np.pi * 4 * f * t) * np.exp(-t * 28)
         + 0.12 * np.sin(2 * np.pi * 10 * f * t) * np.exp(-t * 60))
    return s * env(len(t), 0.002, 0.03)


def piano(f, dur=2.8, vel=1.0):
    t = axis(dur)
    s = np.zeros_like(t)
    for k in range(1, 9):
        fk = f * k * (1 + 0.0004 * k * k)
        s += k ** -1.4 * np.sin(2 * np.pi * fk * t + k) * np.exp(-t * (0.8 + 0.55 * k))
    s += filt(rng.normal(0, 1, len(t)), hi=3000) * np.exp(-t * 120) * 0.06
    return s * env(len(t), 0.003, 0.3) * vel


def pad(notes, dur, bright=1100):
    t = axis(dur)
    s = np.zeros_like(t)
    for m in notes:
        for det in (-0.003, 0.0, 0.0031):
            f, ph = hz(m) * (1 + det), rng.uniform(0, 6.28)
            for k in range(1, 8):
                s += np.sin(2 * np.pi * f * k * t + ph * k) / k
    return filt(s, hi=bright) / (len(notes) * 3 * 2.6) * env(len(t), 0.8, 1.0)


def drone(dur, root=45):
    t = axis(dur)
    s = np.zeros_like(t)
    for m, a in [(root, 1.0), (root + 7, 0.55), (root + 12, 0.35), (root + 15, 0.18)]:
        for det in (-0.004, 0.004):
            s += a * np.sin(2 * np.pi * hz(m) * (1 + det) * t + rng.uniform(0, 6))
    s *= 0.65 + 0.35 * np.sin(2 * np.pi * 0.07 * t)
    return filt(s, hi=420) / 4


def kick():
    t = axis(0.45)
    f = 45 + 80 * np.exp(-t * 18)
    return np.sin(2 * np.pi * np.cumsum(f) / RATE) * np.exp(-t * 7) + filt(noise(0.45), lo=2000) * np.exp(-t * 200) * 0.12


def clap():
    t = axis(0.25)
    e = sum(np.exp(-np.maximum(t - d, 0) * 60) * (t >= d) for d in (0, 0.011, 0.022)) + 0.4 * np.exp(-t * 14)
    return filt(noise(0.25), lo=900, hi=4000) * e * 0.45


def shaker():
    t = axis(0.06)
    return filt(noise(0.06), lo=5000) * np.exp(-t * 70) * 0.22


# ---------- sound effects ----------

def tick(high=True):
    t = axis(0.05)
    return (filt(noise(0.05), lo=3000) * np.exp(-t * 500) * 0.22
            + np.sin(2 * np.pi * (2600 if high else 2000) * t) * np.exp(-t * 160) * 0.2)


def pop(gain=1.0):
    t = axis(0.12)
    f = 520 + 520 * np.minimum(t / 0.05, 1)
    return np.sin(2 * np.pi * np.cumsum(f) / RATE) * np.exp(-t * 38) * env(len(t), 0.002, 0.02) * 0.55 * gain


def chime(notes=(88, 95), gap=0.09, dur=0.9):
    out = np.zeros(int((dur + gap * len(notes)) * RATE))
    for i, m in enumerate(notes):
        t = axis(dur)
        f = hz(m)
        s = (np.sin(2 * np.pi * f * t) + 0.25 * np.sin(2 * np.pi * 2.01 * f * t) + 0.1 * np.sin(2 * np.pi * 3 * f * t)) \
            * np.exp(-t * 5) * env(len(t), 0.002, 0.1)
        st = int(i * gap * RATE)
        out[st:st + len(s)] += s
    return out * 0.3


def ping(pitch=84):
    t = axis(0.35)
    f = hz(pitch)
    return (np.sin(2 * np.pi * f * t) + 0.2 * np.sin(2 * np.pi * 2 * f * t)) * np.exp(-t * 12) * env(len(t), 0.002, 0.05) * 0.22


def taps(dur, rate=12.0, seed=0):
    r = np.random.default_rng(seed + 100)
    out = np.zeros(int((dur + 0.1) * RATE))
    t = 0.0
    n = int(0.012 * RATE)
    decay = np.exp(-np.arange(n) / RATE * 400)
    while t < dur:
        s = int(t * RATE)
        out[s:s + n] += filt(r.normal(0, 1, n), lo=1800, hi=6000) * decay * r.uniform(0.5, 1.0) * 0.45
        t += r.uniform(0.6, 1.4) / rate
    return out


def buzz(dur):
    t = axis(dur)
    s = filt(np.sign(np.sin(2 * np.pi * 155 * t)) * 0.5 + np.sin(2 * np.pi * 310 * t) * 0.2, hi=900)
    rattle = filt(noise(dur), lo=200, hi=1500) * (0.5 + 0.5 * np.sign(np.sin(2 * np.pi * 155 * t))) * 0.15
    return (s + rattle) * env(len(t), 0.01, 0.03) * 0.5


def whoosh(dur=0.5, gain=1.0):
    t = axis(dur)
    return filt(noise(dur), lo=300, hi=2500) * np.sin(np.pi * t / dur) ** 2 * 0.22 * gain


def puff(dur=0.7):
    t = axis(dur)
    return filt(noise(dur), lo=150, hi=1400) * np.minimum(t / 0.05, 1) * np.exp(-t * 5) * 0.4


def grind(dur):
    t = axis(dur)
    am = 0.55 + 0.45 * np.abs(np.sin(2 * np.pi * 3.2 * t))
    crackle = (rng.random(len(t)) < 0.004) * rng.normal(0, 3, len(t))
    s = filt(noise(dur) + crackle, lo=1400, hi=6500) * am + filt(noise(dur), lo=80, hi=300) * 0.3 * am
    return s * env(len(t), 0.03, 0.08) * 0.2


def scribble(dur, seed=1):
    r = np.random.default_rng(seed + 200)
    t = axis(dur)
    k = max(2, int(dur * 7))
    strokes = np.interp(t, np.linspace(0, dur, k), r.uniform(0.1, 1, k))
    return filt(r.normal(0, 1, len(t)), lo=2500, hi=8000) * strokes * env(len(t), 0.02, 0.05) * 0.1


def thud():
    t = axis(0.6)
    f = 60 + 30 * np.exp(-t * 10)
    return np.sin(2 * np.pi * np.cumsum(f) / RATE) * np.exp(-t * 6) * 0.4


def sparkle(dur=0.9):
    t = axis(dur)
    out = np.zeros_like(t)
    for i in range(7):
        st, f = i * 0.07, rng.uniform(2200, 5200)
        tt = np.maximum(t - st, 0)
        out += np.sin(2 * np.pi * f * tt) * np.exp(-tt * 9) * (t >= st) * 0.1
    return out


def click():
    t = axis(0.03)
    return filt(noise(0.03), lo=500, hi=4000) * np.exp(-t * 300) * 0.4 + np.sin(2 * np.pi * 900 * t) * np.exp(-t * 200) * 0.3


def correct():
    return chime(notes=(84, 88, 91), gap=0.07, dur=0.8)


SFX = {"tick": tick, "pop": pop, "chime": chime, "ping": ping, "taps": taps, "buzz": buzz, "whoosh": whoosh,
       "puff": puff, "grind": grind, "scribble": scribble, "thud": thud, "sparkle": sparkle, "click": click,
       "correct": correct}
PAN = {"tick": 0.45, "taps": -0.15, "ping": -0.25, "scribble": 0.2, "grind": 0.25}


def reverb(x, seconds=1.8, wet=0.25):
    n = int(seconds * RATE)
    t = np.arange(n) / RATE
    ir = filt(rng.normal(0, 1, n) * np.exp(-t * 3.0), hi=5000)
    ir /= np.sqrt(np.sum(ir ** 2))
    size = 1 << int(np.ceil(np.log2(len(x) + n)))
    return x + wet * np.fft.irfft(np.fft.rfft(x, size) * np.fft.rfft(ir, size), size)[:len(x)]


def tape_stop(x, ts, te):
    """Slow the recording down to a halt between ts and te, like stopping a tape."""
    s, e = int(ts * RATE), int(te * RATE)
    pos = s + np.cumsum(np.linspace(1, 0, e - s) ** 1.3)
    y = x.copy()
    y[s:e] = np.interp(pos, np.arange(len(x)), x) * np.linspace(1, 0, e - s) ** 0.6
    y[e:] = 0
    return y


# ---------- score ----------

C, G, AM, F = [60, 64, 67], [55, 59, 62], [57, 60, 64], [53, 57, 60]


def score(seconds, S):
    total = int((seconds + 1) * RATE)
    act1, mid, act3 = np.zeros(total), np.zeros(total), np.zeros(total)

    def add(buf, sig, at, gain=1.0):
        s = int(at * RATE)
        if s >= total:
            return
        e = min(total, s + len(sig))
        buf[s:e] += sig[:e - s] * gain

    # Act 1: bright marimba groove, I-vi-IV-V, until the tape stops.
    t, bar = 0.4, 0
    while t < S["act2"]:
        chord = [C, AM, F, G][bar % 4]
        for step, idx in enumerate([0, 1, 2, 1, 2, 1, 0, 1]):
            add(act1, marimba(hz(chord[idx] + 12)), t + step * BEAT / 2, 0.24 * (0.85 + 0.15 * rng.random()))
            if bar > 0 and step % 2 == 1:
                add(act1, shaker(), t + step * BEAT / 2, 0.7)
        for beat in (0, 2):
            add(act1, marimba(hz(chord[0] - 12), 1.0), t + beat * BEAT, 0.32)
        t += 4 * BEAT
        bar += 1
    act1 *= np.clip(np.arange(total) / RATE / 1.2, 0, 1)
    act1 = tape_stop(act1, S["tape"], S["act2"])

    # Act 2: a low drone under the clock, darker at 1 a.m.
    d0, d1 = S["act2"], S["act3"] + 2.5
    dr = drone(d1 - d0) * env(int((d1 - d0) * RATE), 2.0, 2.5)
    add(mid, dr, d0, 0.34)
    dark = drone(S["dark_end"] - S["dark"] + 2, root=33) * env(int((S["dark_end"] - S["dark"] + 2) * RATE), 2.5, 2.0)
    add(mid, dark, S["dark"], 0.4)

    # Act 3: one clear note at the sharpener, then a warm build to the resolve.
    add(act3, piano(hz(72), 4.0) + piano(hz(60), 4.0) * 0.6, S["note"], 0.32)
    t, bar = S["arp"], 0
    while t < S["resolve"] - 0.01:
        chord = [C, G, AM, F][bar % 4]
        grow = min(1.0, 0.45 + (t - S["arp"]) / (S["resolve"] - S["arp"]) * 0.7)
        for step, idx in enumerate([0, 2, 1, 2, 0, 2, 1, 2]):
            add(act3, piano(hz(chord[idx] + 12), 1.6), t + step * BEAT / 2, 0.11 * grow)
        add(act3, piano(hz(chord[0] - 12), 2.6), t, 0.2 * grow)
        if t >= S["strings"]:
            add(act3, pad([m + 12 for m in chord], 4 * BEAT + 0.6), t, 0.55 * grow)
        for beat in range(4):
            bt = t + beat * BEAT
            if bt >= S["kick"]:
                add(act3, kick(), bt, 0.3 * grow)
            if bt >= S["claps"] and beat in (1, 3):
                add(act3, clap(), bt, 0.32)
            if bt >= S["claps"]:
                add(act3, shaker(), bt + BEAT / 2, 0.8)
        t += 4 * BEAT
        bar += 1
    tail = seconds - S["resolve"]
    for m in C + [48, 72]:
        add(act3, piano(hz(m), tail + 0.5), S["resolve"], 0.16)
    add(act3, pad([m + 12 for m in C], tail + 0.5, bright=1400), S["resolve"], 0.7)
    act3 = reverb(act3, wet=0.3)
    music = act1 + mid + act3
    fade = np.ones(total)
    fs = int((seconds - 3.0) * RATE)
    fade[fs:] = np.linspace(1, 0, total - fs).clip(0) ** 1.5
    return music * fade


def render(cues, sections, seconds, path):
    total = int((seconds + 1) * RATE)
    music = score(seconds, sections)
    left, right = music * 0.95, music * 0.95
    fx_l, fx_r = np.zeros(total), np.zeros(total)
    for at, kind, params in cues:
        sig = SFX[kind](**params)
        pan = PAN.get(kind, 0.0)
        s = int(at * RATE)
        e = min(total, s + len(sig))
        fx_l[s:e] += sig[:e - s] * np.cos((pan + 1) * np.pi / 4) * 1.41
        fx_r[s:e] += sig[:e - s] * np.sin((pan + 1) * np.pi / 4) * 1.41
    fx_l, fx_r = reverb(fx_l, 1.0, 0.12), reverb(fx_r, 1.0, 0.12)
    left, right = left + fx_l, right + fx_r
    n = int(seconds * RATE)
    stereo = np.stack([left[:n], right[:n]], axis=1)
    # Bring the mix to about -19 dBFS RMS, then soft-limit the few peaks above the knee.
    rms = np.sqrt(np.mean(stereo ** 2))
    stereo *= min(10 ** (-19 / 20) / rms, 2.0 / np.max(np.abs(stereo)))
    stereo = limit(stereo)
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes((stereo * 32767).astype("<i2").tobytes())
    print(f"wrote {path} ({seconds:.0f}s, {20 * np.log10(np.sqrt(np.mean(stereo ** 2))):.1f} dBFS RMS)")


def limit(x, knee=0.6, ceil=0.95):
    a = np.abs(x)
    over = a > knee
    y = x.copy()
    y[over] = np.sign(x[over]) * (knee + (ceil - knee) * np.tanh((a[over] - knee) / (ceil - knee)))
    return y
