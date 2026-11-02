"""Synthesizes a calm background track for the intro video: a soft chord pad,
a low bass and a quiet plucked arpeggio. Original audio, so no licensing.

    python tools/make_music.py out.wav --seconds 180
"""
import argparse
import wave

import numpy as np

RATE = 44100
BPM = 84
# Cmaj9 - Am7 - Fmaj7 - Gsus2, two bars each.
CHORDS = [
    [48, 55, 59, 62, 64],
    [45, 52, 55, 60, 64],
    [41, 48, 52, 57, 60],
    [43, 50, 55, 57, 62],
]


def hz(midi):
    return 440.0 * 2 ** ((midi - 69) / 12)


def envelope(n, attack, release):
    env = np.ones(n)
    a, r = int(attack * RATE), int(release * RATE)
    env[:a] = np.linspace(0, 1, a) ** 2
    env[-r:] *= np.linspace(1, 0, r) ** 2
    return env


def pad_note(freq, seconds, rng):
    t = np.arange(int(seconds * RATE)) / RATE
    sig = np.zeros_like(t)
    for detune in (-0.0018, 0.0, 0.0021):   # three slightly detuned voices for width
        phase = rng.uniform(0, 2 * np.pi)
        f = freq * (1 + detune)
        sig += np.sin(2 * np.pi * f * t + phase) + 0.18 * np.sin(4 * np.pi * f * t + phase)
    # Slow tremolo keeps the pad breathing.
    sig *= 1 + 0.08 * np.sin(2 * np.pi * 0.17 * t + rng.uniform(0, 6))
    return sig / 3


def pluck(freq, seconds):
    t = np.arange(int(seconds * RATE)) / RATE
    sig = np.sin(2 * np.pi * freq * t) + 0.3 * np.sin(4 * np.pi * freq * t) + 0.1 * np.sin(6 * np.pi * freq * t)
    return sig * np.exp(-t * 3.2) * envelope(len(t), 0.004, 0.05)


def lowpass(x, cutoff):
    alpha = 1 - np.exp(-2 * np.pi * cutoff / RATE)
    y = np.empty_like(x)
    acc = 0.0
    for i in range(0, len(x), 4096):          # block-wise to keep it quick enough
        block = x[i:i + 4096]
        out = np.empty_like(block)
        for j, v in enumerate(block):
            acc += alpha * (v - acc)
            out[j] = acc
        y[i:i + 4096] = out
    return y


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--seconds", type=float, default=180)
    a = ap.parse_args()
    rng = np.random.default_rng(7)

    total = int(a.seconds * RATE)
    left = np.zeros(total + RATE * 8)
    right = np.zeros_like(left)
    beat = 60 / BPM
    chord_len = 8 * beat                          # two bars of 4/4
    overlap = 1.6

    t, k = 0.0, 0
    while t < a.seconds:
        chord = CHORDS[k % len(CHORDS)]
        start = int(t * RATE)
        dur = chord_len + overlap
        for i, note in enumerate(chord):
            voice = pad_note(hz(note + 12), dur, rng) * envelope(int(dur * RATE), 1.4, 1.8) * 0.055
            pan = 0.3 + 0.4 * (i / (len(chord) - 1))
            left[start:start + len(voice)] += voice * (1 - pan)
            right[start:start + len(voice)] += voice * pan
        bass = pad_note(hz(chord[0] - 12), dur, rng) * envelope(int(dur * RATE), 0.8, 1.8) * 0.06
        left[start:start + len(bass)] += bass
        right[start:start + len(bass)] += bass
        # Arpeggio in eighth notes, entering after the intro and resting every fourth chord.
        if t >= 6 and k % 4 != 3:
            pattern = [0, 2, 3, 4, 3, 2, 1, 2] * 2
            for step, idx in enumerate(pattern):
                when = int((t + step * beat / 2) * RATE)
                note = pluck(hz(chord[idx] + 24), beat * 1.5) * 0.028 * (0.8 + 0.2 * rng.random())
                pan = 0.35 + 0.3 * ((step % 4) / 3)
                left[when:when + len(note)] += note * (1 - pan)
                right[when:when + len(note)] += note * pan
        t += chord_len
        k += 1

    left, right = left[:total], right[:total]
    left, right = lowpass(left, 5200), lowpass(right, 5200)
    fade = np.ones(total)
    fade[: int(2.5 * RATE)] = np.linspace(0, 1, int(2.5 * RATE))
    fade[-int(5 * RATE):] = np.linspace(1, 0, int(5 * RATE)) ** 1.5
    stereo = np.stack([left * fade, right * fade], axis=1)
    stereo *= 0.35 / np.max(np.abs(stereo))        # gentle level under the visuals
    pcm = (stereo * 32767).astype("<i2")
    with wave.open(a.out, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm.tobytes())
    print(f"wrote {a.out} ({a.seconds:.0f}s)")


if __name__ == "__main__":
    main()
