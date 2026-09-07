#!/usr/bin/env python3
"""
Sili-Tubig Clash - procedural audio generator
F.I.R.E.S DEV / University of La Salette

Synthesises every footstep and sound effect in the game from scratch using
numpy + scipy. Nothing here is sampled, recorded, or downloaded, so all output
is original work owned by the team - see CREDITS.md.

Run from the project root:

    python3 tools/generate_audio.py

Writes 16-bit 44.1kHz mono WAVs into:
    assets/audio/footsteps/<surface>/{walk,run}_NN.wav
    assets/audio/sfx/*.wav

Re-running is safe; it overwrites in place. Open the project in Godot
afterwards so the new files get imported.
"""

import os
import numpy as np
from scipy import signal
from scipy.io import wavfile

SR = 44100
RNG = np.random.default_rng(20260906)  # fixed seed => reproducible builds

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FOOTSTEP_DIR = os.path.join(ROOT, "assets", "audio", "footsteps")
SFX_DIR = os.path.join(ROOT, "assets", "audio", "sfx")


# ---------------------------------------------------------------- primitives

def noise(dur):
    return RNG.normal(0.0, 1.0, int(SR * dur))


def silence(dur):
    return np.zeros(int(SR * dur))


def band(x, lo, hi, order=4):
    """Butterworth band-pass. lo/hi in Hz; either may be None for shelf-only."""
    nyq = SR / 2.0
    if lo and hi:
        sos = signal.butter(order, [lo / nyq, min(hi, nyq * 0.99) / nyq],
                            btype="band", output="sos")
    elif hi:
        sos = signal.butter(order, min(hi, nyq * 0.99) / nyq,
                            btype="low", output="sos")
    else:
        sos = signal.butter(order, lo / nyq, btype="high", output="sos")
    return signal.sosfilt(sos, x)


def env(n, attack=0.002, decay=0.08, curve=2.5):
    """Percussive envelope: near-instant attack, exponential-ish decay."""
    a = int(SR * attack)
    d = n - a
    out = np.ones(n)
    if a > 0:
        out[:a] = np.linspace(0.0, 1.0, a)
    if d > 0:
        t = np.linspace(0.0, 1.0, d)
        out[a:] = np.exp(-curve * 4.0 * t) * (1.0 - t) ** 0.5
    return out


def tone(freq, dur, decay=6.0, wave="sine"):
    t = np.linspace(0.0, dur, int(SR * dur), endpoint=False)
    if wave == "sine":
        x = np.sin(2 * np.pi * freq * t)
    elif wave == "tri":
        x = signal.sawtooth(2 * np.pi * freq * t, 0.5)
    else:
        x = signal.square(2 * np.pi * freq * t, 0.35)
    return x * np.exp(-decay * t)


def sweep(f0, f1, dur, decay=4.0):
    t = np.linspace(0.0, dur, int(SR * dur), endpoint=False)
    return signal.chirp(t, f0, dur, f1, method="logarithmic") * np.exp(-decay * t)


def pad(x, n):
    if len(x) >= n:
        return x[:n]
    return np.concatenate([x, np.zeros(n - len(x))])


def mix(*parts):
    n = max(len(p) for p in parts)
    out = np.zeros(n)
    for p in parts:
        out += pad(p, n)
    return out


def normalise(x, peak=0.9):
    m = np.max(np.abs(x))
    return x * (peak / m) if m > 1e-9 else x


def declick(x, ms=3.0):
    """Fade the head and tail so no sample starts or ends on a discontinuity."""
    n = int(SR * ms / 1000.0)
    n = min(n, len(x) // 2)
    if n <= 0:
        return x
    x = x.copy()
    x[:n] *= np.linspace(0.0, 1.0, n)
    x[-n:] *= np.linspace(1.0, 0.0, n)
    return x


def write(path, x, peak=0.9):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    x = declick(normalise(x, peak))
    wavfile.write(path, SR, (np.clip(x, -1.0, 1.0) * 32767).astype(np.int16))
    print("  %-52s %5.0f ms" % (os.path.relpath(path, ROOT), 1000 * len(x) / SR))


# ---------------------------------------------------------------- footsteps
# Each surface is a recipe. Variants differ by pitch, level and grain so four
# samples per gait already read as natural instead of a machine-gun loop.

def step_sand(run, k):
    dur = 0.16 if run else 0.13
    n = int(SR * dur)
    grain = band(noise(dur), 180, 1900 + 220 * k)
    body = grain * env(n, 0.003, dur, curve=2.2 if run else 2.8)
    thud = tone(70 + 6 * k, dur * 0.6, decay=26) * (0.45 if run else 0.28)
    return mix(body * (1.0 if run else 0.72), thud)


def step_grass(run, k):
    dur = 0.19 if run else 0.16
    n = int(SR * dur)
    swish = band(noise(dur), 900, 6500 + 400 * k) * env(n, 0.004, dur, curve=2.0)
    # A couple of dry blade-crackles scattered through the tail.
    crack = np.zeros(n)
    for _ in range(3 if run else 2):
        at = RNG.integers(int(n * 0.05), int(n * 0.6))
        ln = int(SR * 0.006)
        seg = band(noise(0.006), 2500, 9000) * env(ln, 0.0005, 0.006, curve=5.0)
        crack[at:at + len(seg)] += seg[:max(0, n - at)] * 0.5
    soft = tone(110, dur * 0.4, decay=30) * 0.2
    return mix(swish * (1.0 if run else 0.7), crack, soft)


def step_road(run, k):
    dur = 0.12 if run else 0.10
    n = int(SR * dur)
    click = band(noise(dur), 700, 5200 + 300 * k) * env(n, 0.0008, dur, curve=4.5)
    slap = tone(190 + 12 * k, 0.05, decay=45, wave="tri") * 0.35
    low = tone(85, 0.07, decay=34) * (0.5 if run else 0.3)
    return mix(click * (1.0 if run else 0.66), slap, low)


def step_stairs(run, k):
    """Hollow wooden tread: a click plus three resonant modes."""
    dur = 0.20 if run else 0.17
    n = int(SR * dur)
    knock = band(noise(0.012), 900, 7000) * env(int(SR * 0.012), 0.0005, 0.012, 6.0)
    modes = mix(
        tone(178 + 9 * k, dur, decay=17) * 0.55,
        tone(415 + 18 * k, dur, decay=23) * 0.32,
        tone(902 + 30 * k, dur * 0.7, decay=31) * 0.16,
    )
    return mix(knock * 0.8, modes * (1.0 if run else 0.68))


def step_water(run, k):
    """Shallow surf splash: broadband burst that darkens as it decays."""
    dur = 0.30 if run else 0.25
    n = int(SR * dur)
    raw = noise(dur)
    # Four bands with staggered decays approximate a moving low-pass.
    sp = mix(
        band(raw, 2500, 9000) * env(n, 0.001, dur, curve=6.0) * 0.9,
        band(raw, 900, 2500) * env(n, 0.003, dur, curve=3.6) * 0.8,
        band(raw, 300, 900) * env(n, 0.006, dur, curve=2.2) * 0.6,
        band(raw, None, 300) * env(n, 0.010, dur, curve=1.6) * 0.4,
    )
    drop = tone(1400 + 180 * k, 0.05, decay=48) * (0.22 if run else 0.14)
    return mix(sp * (1.0 if run else 0.68), drop)


SURFACES = {
    "sand": step_sand,
    "grass": step_grass,
    "road": step_road,
    "stairs": step_stairs,
    "water": step_water,
}

VARIANTS = 4


def build_footsteps():
    print("Footsteps")
    for surface, recipe in SURFACES.items():
        for gait in ("walk", "run"):
            run = gait == "run"
            for i in range(VARIANTS):
                x = recipe(run, i)
                # Per-variant pitch drift keeps repeats from sounding identical.
                shift = 1.0 + (i - 1.5) * 0.035
                idx = np.clip((np.arange(len(x)) * shift).astype(int), 0, len(x) - 1)
                x = x[idx]
                path = os.path.join(FOOTSTEP_DIR, surface, "%s_%02d.wav" % (gait, i + 1))
                write(path, x, peak=0.82 if run else 0.62)


# ---------------------------------------------------------------------- sfx

def sfx_tag():
    """The Sili lands a tag: chilli sizzle over a hard low hit."""
    hit = mix(
        tone(120, 0.28, decay=13) * 0.9,
        tone(61, 0.34, decay=9) * 0.7,
        band(noise(0.05), 300, 4000) * env(int(SR * 0.05), 0.0005, 0.05, 5.0),
    )
    sizzle = band(noise(0.55), 2200, 11000) * env(int(SR * 0.55), 0.01, 0.55, 1.4) * 0.5
    fall = sweep(900, 190, 0.34, decay=7.0) * 0.35
    return mix(hit, sizzle, fall)


def sfx_burn_loop_tick():
    """Soft recurring ember tick while a Tubig is burning."""
    return mix(
        band(noise(0.09), 1800, 8000) * env(int(SR * 0.09), 0.004, 0.09, 3.0) * 0.6,
        tone(330, 0.09, decay=30) * 0.25,
    )


def sfx_rescue_start():
    return mix(
        tone(392, 0.14, decay=14) * 0.5,
        band(noise(0.10), 600, 3000) * env(int(SR * 0.10), 0.01, 0.10, 3.0) * 0.25,
    )


def sfx_rescue_complete():
    """Water rushing in, then a bright two-note lift (G -> C)."""
    splash = mix(
        band(noise(0.30), 700, 6500) * env(int(SR * 0.30), 0.005, 0.30, 2.4) * 0.55,
        band(noise(0.30), 150, 700) * env(int(SR * 0.30), 0.010, 0.30, 1.8) * 0.35,
    )
    n1 = pad(tone(392.0, 0.22, decay=9), int(SR * 0.42)) * 0.45
    n2 = np.concatenate([silence(0.12), tone(523.25, 0.30, decay=7) * 0.5])
    n3 = np.concatenate([silence(0.12), tone(783.99, 0.30, decay=8) * 0.22])
    return mix(splash, n1, n2, n3)


def sfx_tunnel():
    """Diving into a tunnel mouth: downward whoosh with a puff of grit."""
    air = band(noise(0.42), 200, 5200) * env(int(SR * 0.42), 0.02, 0.42, 1.8)
    dive = sweep(1500, 260, 0.40, decay=3.4) * 0.5
    return mix(air * 0.7, dive)


def sfx_countdown():
    return tone(880.0, 0.11, decay=22) * 0.8


def sfx_countdown_go():
    return mix(tone(1318.5, 0.32, decay=8) * 0.8, tone(659.25, 0.32, decay=9) * 0.4)


def sfx_match_win():
    """Rising C-E-G-C fanfare."""
    out = np.zeros(int(SR * 1.25))
    for i, f in enumerate([523.25, 659.25, 783.99, 1046.5]):
        seg = mix(tone(f, 0.55, decay=5.0), tone(f * 2, 0.5, decay=7.0) * 0.28)
        at = int(SR * 0.11 * i)
        out[at:at + len(seg)] += pad(seg, min(len(seg), len(out) - at)) * 0.45
    return out


def sfx_match_lose():
    """Falling minor line."""
    out = np.zeros(int(SR * 1.35))
    for i, f in enumerate([440.0, 392.0, 329.63, 261.63]):
        seg = mix(tone(f, 0.6, decay=4.2, wave="tri") * 0.5, tone(f / 2, 0.6, decay=5.0) * 0.3)
        at = int(SR * 0.16 * i)
        out[at:at + len(seg)] += pad(seg, min(len(seg), len(out) - at)) * 0.45
    return out


def sfx_eliminated():
    """A Tubig's burn times out - hollow, final."""
    return mix(
        tone(196.0, 0.75, decay=4.0) * 0.6,
        tone(98.0, 0.85, decay=3.2) * 0.5,
        sweep(600, 120, 0.5, decay=5.0) * 0.25,
    )


def sfx_spotted():
    """Two-note sting when the team first sees the Sili."""
    return mix(
        tone(1046.5, 0.16, decay=16) * 0.6,
        np.concatenate([silence(0.08), tone(1396.9, 0.20, decay=13) * 0.5]),
    )


SFX = {
    "tag": sfx_tag,
    "burn_tick": sfx_burn_loop_tick,
    "rescue_start": sfx_rescue_start,
    "rescue_complete": sfx_rescue_complete,
    "tunnel": sfx_tunnel,
    "countdown": sfx_countdown,
    "countdown_go": sfx_countdown_go,
    "match_win": sfx_match_win,
    "match_lose": sfx_match_lose,
    "eliminated": sfx_eliminated,
    "spotted": sfx_spotted,
}


def build_sfx():
    print("SFX")
    for name, recipe in SFX.items():
        write(os.path.join(SFX_DIR, "%s.wav" % name), recipe(), peak=0.88)


if __name__ == "__main__":
    build_footsteps()
    build_sfx()
    print("\nDone. Open the project in Godot so the new WAVs are imported.")
