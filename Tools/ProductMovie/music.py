"""Generate a quiet original soundtrack without samples or interface beeps."""

import array
import math
import sys
import wave

RATE = 44100
duration = float(sys.argv[2])
samples = array.array("f", [0]) * int(RATE * duration)


def tone(start, frequency, length, level):
    offset = int(start * RATE)
    count = min(int(length * RATE), len(samples) - offset)
    for index in range(count):
        time = index / RATE
        attack = min(1, time / 0.35)
        release = min(1, (length - time) / 1.2)
        envelope = math.sin(attack * math.pi / 2) ** 2 * release**2
        envelope *= math.exp(-time * 0.25)
        phase = 2 * math.pi * frequency * time
        samples[offset + index] += level * envelope * (
            math.sin(phase) + 0.10 * math.sin(2 * phase) + 0.025 * math.sin(3 * phase)
        )


chords = [
    (146.83, 185.00, 220.00, 329.63),
    (110.00, 164.81, 277.18, 329.63),
    (123.47, 185.00, 220.00, 293.66),
    (98.00, 146.83, 185.00, 220.00),
    (146.83, 220.00, 293.66, 369.99),
]
for index, chord in enumerate(chords):
    for frequency in chord:
        tone(index * 4.8, frequency, 5.8, 0.026)

pcm = array.array("h")
peak = 0
largest_step = 0
previous = 0
for index, sample in enumerate(samples):
    time = index / RATE
    fade = min(1, time / 0.5, (duration - time) / 1.8)
    value = sample * max(0, fade)
    peak = max(peak, abs(value))
    largest_step = max(largest_step, abs(value - previous))
    previous = value
    pcm.append(round(value * 32767))
assert peak < 0.95, "Soundtrack clips"
assert largest_step < 0.02, "Soundtrack contains an abrupt sample jump"
if sys.byteorder != "little":
    pcm.byteswap()
with wave.open(sys.argv[1], "wb") as handle:
    handle.setnchannels(1)
    handle.setsampwidth(2)
    handle.setframerate(RATE)
    handle.writeframes(pcm.tobytes())
print("OK: original soundtrack; no clipping or abrupt sample jumps")
