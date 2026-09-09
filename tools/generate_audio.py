#!/usr/bin/env python3
"""Synthesises footstep samples for game/assets/audio/footsteps/<surface>/.

Original work, not sourced: every sample is built from noise + a handful of
decaying sine partials, shaped and mixed with numpy/scipy. A fixed RNG seed
per (surface, gait, variant) makes the output reproducible - re-running this
script regenerates byte-identical files.

IMPORTANT: this rewrite only knows the recipe for the "plank" surface. The
original script that produced sand/grass/road/stairs/water was lost before
this copy was written, and those five folders already have real, working
samples checked into the repo - so SURFACES below deliberately does not list
them, and this script will never touch their files. Add a recipe here (and
list it in SURFACES) before relying on this to (re)generate anything else.

Usage:
    python3 tools/generate_audio.py
"""

import hashlib
import math
import os
import struct
import wave

import numpy as np
from scipy.signal import butter, sosfilt

SAMPLE_RATE = 44100
VARIANTS_PER_GAIT = 4
OUT_ROOT = os.path.join(os.path.dirname(__file__), "..", "game", "assets", "audio", "footsteps")


def _bandpass_noise(duration_s: float, low_hz: float, high_hz: float, rng: np.random.Generator) -> np.ndarray:
    n = int(duration_s * SAMPLE_RATE)
    noise = rng.standard_normal(n)
    sos = butter(4, [low_hz, high_hz], btype="bandpass", fs=SAMPLE_RATE, output="sos")
    return sosfilt(sos, noise)


def _decaying_partial(duration_s: float, freq_hz: float, decay: float, phase: float = 0.0) -> np.ndarray:
    t = np.arange(int(duration_s * SAMPLE_RATE)) / SAMPLE_RATE
    return np.sin(2 * math.pi * freq_hz * t + phase) * np.exp(-t / decay)


def _fit(a: np.ndarray, n: int) -> np.ndarray:
    if len(a) >= n:
        return a[:n]
    return np.pad(a, (0, n - len(a)))


def _normalize(x: np.ndarray, peak: float = 0.9) -> np.ndarray:
    m = np.max(np.abs(x))
    if m < 1e-9:
        return x
    return x * (peak / m)


def _write_wav(path: str, samples: np.ndarray) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    clipped = np.clip(samples, -1.0, 1.0)
    ints = (clipped * 32767.0).astype("<h")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(struct.pack("<%dh" % len(ints), *ints))


## --- Surface recipes -------------------------------------------------------

def _plank_step(rng: np.random.Generator, running: bool) -> np.ndarray:
    """A boardwalk plank: a hollow wooden knock, not the tighter tap of an
    indoor stair tread. Built from a short bandpassed-noise contact transient
    (the foot meeting the board) plus two decaying low partials (the board
    itself resonating and settling), which is what actually reads as
    "hollow" rather than just "wood" - a single tone sounds like a xylophone,
    two close, slightly-detuned ones sound like a physical plank.
    """
    duration = 0.16 if running else 0.19

    # The contact click: a fast, wood-band noise burst, louder and a touch
    # brighter on a run because a harder footfall drives more high content.
    click = _bandpass_noise(duration, 900, 4200, rng)
    click_env = np.exp(-np.arange(len(click)) / SAMPLE_RATE / (0.012 if running else 0.018))
    click = click * click_env

    # The board resonance: two partials a few Hz apart around a low wooden
    # fundamental, with independent slight detune per call so no two
    # variants ring at exactly the same pitch.
    base_freq = rng.uniform(150.0, 190.0)
    detune = rng.uniform(6.0, 14.0)
    decay = rng.uniform(0.05, 0.075)
    body = _decaying_partial(duration, base_freq, decay)
    body += 0.6 * _decaying_partial(duration, base_freq + detune, decay * 0.85, phase=rng.uniform(0, math.pi))
    # A faint high partial - the creak of the board settling back.
    body += 0.18 * _decaying_partial(duration, base_freq * 5.3, decay * 0.4)

    n = int(duration * SAMPLE_RATE)
    mix = 0.55 * _fit(click, n) + 0.75 * _fit(body, n)

    # A light low-passed noise tail under everything - the dock/boardwalk
    # creaking on its supports for a beat after the footfall - so the sample
    # doesn't cut off abruptly.
    tail = _bandpass_noise(duration, 60, 500, rng)
    tail_env = np.exp(-np.arange(len(tail)) / SAMPLE_RATE / 0.09)
    mix += 0.12 * _fit(tail * tail_env, n)

    peak = 0.95 if running else 0.85
    return _normalize(mix, peak)


SURFACES = {
    "plank": _plank_step,
}


def _stable_seed(*parts: str) -> int:
    """Python's built-in hash() salts strings per-process (PYTHONHASHSEED),
    so it produces a different number on every run and would break the
    byte-for-byte reproducibility this whole script exists for. hashlib is
    not salted, which is exactly what a *seed* needs to be here.
    """
    digest = hashlib.sha256("|".join(parts).encode("utf-8")).digest()
    return int.from_bytes(digest[:4], "big")


def main() -> None:
    for surface, recipe in SURFACES.items():
        for gait in ("walk", "run"):
            running = gait == "run"
            for i in range(1, VARIANTS_PER_GAIT + 1):
                # Seed keyed by surface/gait/variant, not by call order, so
                # adding a variant later can't shift every sample after it.
                seed = _stable_seed(surface, gait, str(i))
                rng = np.random.default_rng(seed)
                samples = recipe(rng, running)
                path = os.path.join(OUT_ROOT, surface, "%s_%02d.wav" % (gait, i))
                _write_wav(path, samples)
                print("wrote", path)


if __name__ == "__main__":
    main()
