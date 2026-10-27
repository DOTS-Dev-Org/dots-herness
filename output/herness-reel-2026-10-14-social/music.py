#!/usr/bin/env python3
"""Synthesize the 120 BPM score for the reel. Stdlib only. Usage: music.py out.wav [seconds]"""
import math, random, struct, sys, wave

SR, BPM = 44100, 120
SECONDS = int(sys.argv[2]) if len(sys.argv) > 2 else 20
BEAT = 60 / BPM
N = SR * SECONDS
# Am F C G, one bar each
CHORDS = [(220.0, 261.63, 329.63), (174.61, 220.0, 261.63), (261.63, 329.63, 392.0), (196.0, 246.94, 293.66)]
random.seed(7)
out = [0.0] * N
TAU = 2 * math.pi

for i in range(N):
    t = i / SR
    beat = t / BEAT
    bar = int(beat // 4)
    chord = CHORDS[bar % 4]
    bt = (beat % 1) * BEAT              # time since last beat
    duck = min(1.0, bt / 0.18) if bar >= 1 else 1.0   # sidechain
    s = 0.0
    # pad
    for f in chord:
        s += 0.05 * duck * (math.sin(TAU * f * t) + math.sin(TAU * f * 1.006 * t))
    # bass, eighth notes
    et = (beat * 2 % 1) * BEAT / 2
    fb = chord[0] / 2
    s += 0.22 * duck * math.exp(-et * 7) * math.tanh(2.5 * math.sin(TAU * fb * t))
    # arp, sixteenths, from bar 2
    if bar >= 2:
        step = int(beat * 4)
        st = (beat * 4 % 1) * BEAT / 4
        fa = chord[step % 3] * (2 if step % 4 < 2 else 4)
        s += 0.09 * math.exp(-st * 22) * math.sin(TAU * fa * t)
    if bar >= 1:
        # kick: pitch sweep 130 -> 45 Hz
        s += 0.75 * math.exp(-bt * 9) * math.sin(TAU * (45 * bt + 85 / 28 * (1 - math.exp(-bt * 28))))
        # offbeat hat
        ht = ((beat + 0.5) % 1) * BEAT
        s += 0.07 * math.exp(-ht * 70) * random.uniform(-1, 1)
    out[i] = s * min(1.0, t / 0.05, (SECONDS - t) / 1.2)

peak = max(abs(x) for x in out)
with wave.open(sys.argv[1], "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes(struct.pack(f"<{N}h", *(int(x / peak * 30000) for x in out)))
