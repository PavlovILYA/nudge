#!/usr/bin/env python3
"""Generate Nudge's original mono PCM CAF assets (Python stdlib + macOS afconvert).
No recordings or third-party material. Keep this recipe with the generated assets.
"""
import array
import math
from pathlib import Path
import subprocess
import sys
import tempfile
import wave

RATE = 44100
OUTPUT = Path(__file__).resolve().parents[1] / 'Nudge' / 'Sounds'


def bell(t, frequency, decay):
    if t < 0:
        return 0.0
    attack = min(t / 0.008, 1.0)
    return attack * math.exp(-t / decay) * (
        math.sin(2 * math.pi * frequency * t)
        + 0.2 * math.sin(2 * math.pi * frequency * 2 * t)
    ) / 1.2


def render(filename, duration, sample):
    count = int(duration * RATE)
    values = array.array('h')
    for index in range(count):
        t = index / RATE
        # Short fade-out avoids a boundary click, including for the silent asset.
        fade = min((count - 1 - index) / (RATE * 0.02), 1.0)
        value = sample(t) * fade
        assert abs(value) <= 1
        values.append(round(value * 32767))
    if sys.byteorder != 'little':
        values.byteswap()
    with tempfile.TemporaryDirectory() as directory:
        source = Path(directory) / 'source.wav'
        with wave.open(str(source), 'wb') as wav:
            wav.setparams((1, 2, RATE, count, 'NONE', 'not compressed'))
            wav.writeframes(values.tobytes())
        subprocess.run(['afconvert', '-f', 'caff', '-d', 'LEI16@44100',
                        '-c', '1', str(source), str(OUTPUT / filename)], check=True)


if __name__ == '__main__':
    OUTPUT.mkdir(parents=True, exist_ok=True)
    render('nudge-soft.caf', 1.8, lambda t: 0.22 * bell(t, 523.25, 0.36))
    render('nudge-prominent.caf', 2.4, lambda t: 0.55 * sum(
        bell(t - start, frequency, 0.14)
        for start, frequency in [(0, 880), (0.4, 1174.66), (0.8, 880)]))
    render('nudge-silent.caf', 2.0, lambda t: 0)
