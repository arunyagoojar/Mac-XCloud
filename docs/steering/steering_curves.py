#!/usr/bin/env python3
"""Exact Python replica of Mac Xcloud's steering pipeline (MotionInputEngine.swift),
used to explain and visualise how every setting shapes the wheel -> stick value.
Generates docs/steering/steering-explained.png"""
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from math import pi, exp

DEG = pi / 180

# ---------- 1€ filter (OneEuroFilter.swift) ----------
def one_euro_alpha(cutoff, dt):
    tau = 1.0 / (2.0 * pi * max(cutoff, 1e-4))
    return 1.0 / (1.0 + tau / dt)

def one_euro(samples, dt, minimum_cutoff, beta=20.0, derivative_cutoff=4.0):
    out, value, raw, deriv, primed = [], 0.0, 0.0, 0.0, False
    for s in samples:
        if not primed:
            primed, raw, value, deriv = True, s, s, 0.0
            out.append(value); continue
        rate = (s - raw) / dt
        deriv += one_euro_alpha(derivative_cutoff, dt) * (rate - deriv)
        raw = s
        cutoff = minimum_cutoff + beta * abs(deriv)
        value += one_euro_alpha(cutoff, dt) * (s - value)
        out.append(value)
    return np.array(out)

def steering_cutoff(smoothing):          # makeFilter()
    return 8.0 * (0.1 ** min(max(smoothing, 0.0), 1.0))

# ---------- response (SteeringResponse) ----------
GENTLEST = 1.4
def compensation_onset_span(span):       # compensationOnset()
    return min(max(span * 0.06, 1 * DEG), 3 * DEG)

def shaper_curve(x, exponent):           # StickShaper.curve (power side)
    e = min(max(exponent, 0.3), 3.0)
    knee = 0.04
    if e == 1: return x
    return np.where(x >= knee, x ** e, (knee ** e) * (x / knee))

def steering_curve(x, exponent):         # SteeringResponse.curve
    if exponent <= 1: return shaper_curve(x, exponent)
    k = 0.7 * min((exponent - 1.0) / (GENTLEST - 1.0), 1.0)
    return (1 - k) * x + k * x * x

def lifted(shaped, anti_deadzone, onset=1.0):   # StickShaper.lifted
    floor = np.clip(anti_deadzone, 0, 0.5) * np.clip(onset, 0, 1)
    return np.minimum(floor + (1 - floor) * shaped, 1.0)

def steering_output(angle_deg, full_lock=40, exponent=1.0, anti_deadzone=0.0,
                    deadzone_deg=0.0, maximum=1.0):
    """Full chain after the filter: angle (deg, +right) -> stick -1..+1."""
    span = max(full_lock * DEG, 5 * DEG)
    dz = min(max(deadzone_deg * DEG, 0), span * 0.2)
    travel = np.maximum(np.abs(angle_deg * DEG) - dz, 0)
    demand = np.minimum(travel / max(span - dz, 1e-4), 1.0)
    onset = 1 - np.exp(-travel / compensation_onset_span(span))
    mag = lifted(steering_curve(demand, exponent), anti_deadzone, onset)
    return np.sign(angle_deg) * mag * np.clip(maximum, 0.1, 1.0)

def full_pipeline(angle_deg_series, dt, smoothing=0.2, **p):
    """bank -> OneEuro -> response, as SteeringWheelEngine.update does."""
    cutoff = steering_cutoff(smoothing)
    filtered = one_euro(np.asarray(angle_deg_series), dt, cutoff)
    return filtered, steering_output(filtered, **p)

ANG = np.linspace(-90, 90, 1801)          # physical wheel angle, degrees
plt.rcParams.update({"figure.facecolor": "white", "font.size": 9})
fig, axes = plt.subplots(3, 2, figsize=(12.5, 13))
fig.suptitle("Mac Xcloud steering: how every setting shapes the stick value\n"
             "(exact replica of MotionInputEngine.swift — bank → 1€ filter → response)", fontsize=12)

# --- A. overall curve, defaults ---
ax = axes[0, 0]
for lock, style in [(25, "--"), (40, "-"), (60, "-."), (90, ":")]:
    ax.plot(ANG, steering_output(ANG, full_lock=lock), style, label=f"range {lock}°")
ax.set_title("A. Full response — default curve (linear),\n'turn X° of the wheel → this stick value'")
ax.set_xlabel("physical wheel angle (deg)"); ax.set_ylabel("left stick X (-1 … +1)")
ax.axvline(0, color="k", lw=.3); ax.axhline(0, color="k", lw=.3); ax.legend(); ax.grid(alpha=.3)

# --- B. Center response (exponent) ---
ax = axes[0, 1]
for e, lbl in [(1.4, "0 = gentlest (exponent 1.4)"), (1.2, ""), (1.0, "middle ≈ linear (1.0)"), (0.7, ""), (0.5, "1 = quick (0.5)")]:
    ax.plot(ANG, steering_output(ANG, exponent=e), lw=2.2 if abs(e - 1) < .01 else 1.4, label=lbl)
ax.set_title("B. 'Center response' slider (0 gentle … 1 quick)\nexponent ≤1: power curve w/ linear knee; >1: gentle blend")
ax.set_xlabel("physical wheel angle (deg)"); ax.set_ylabel("stick X")
ax.axvline(0, color="k", lw=.3); ax.legend(fontsize=7.5); ax.grid(alpha=.3)

# --- C. Center boost (anti-deadzone) ---
ax = axes[0, 2 - 1] if False else axes[1, 0]
for adz in [0.0, 0.1, 0.2, 0.3]:
    ax.plot(ANG, steering_output(ANG, anti_deadzone=adz), label=f"boost {adz:.1f}")
ax.set_title("C. 'Center boost' (anti-dead-zone)\nlifts output so the game's own dead zone starts moving at once\n(fades in over the first 1–3°, so center never jumps)")
ax.set_xlabel("physical wheel angle (deg)"); ax.set_ylabel("stick X")
ax.legend(); ax.grid(alpha=.3); ax.axvline(0, color="k", lw=.3)

# --- D. Physical deadzone + Maximum ---
ax = axes[1, 1]
for dz in [0, 3, 6, 10]:
    ax.plot(ANG, steering_output(ANG, deadzone_deg=dz), label=f"dead zone {dz}°")
ax.set_title("D. 'Physical dead zone' — hand movement ignored near center\n(never steers until past the band)")
ax.set_xlabel("physical wheel angle (deg)"); ax.set_ylabel("stick X")
ax.legend(); ax.grid(alpha=.3)

# --- E. Maximum steering ---
ax = axes[2, 0]
for m in [0.2, 0.5, 0.8, 1.0]:
    ax.plot(ANG, steering_output(ANG, maximum=m), label=f"max {m:.1f}")
ax.set_title("E. 'Maximum steering' — scale of full lock\n(0.5 → the wheel never asks for more than half stick)")
ax.set_xlabel("physical wheel angle (deg)"); ax.set_ylabel("stick X")
ax.legend(); ax.grid(alpha=.3)

# --- F. Smoothing: holding a steady turn with 9 Hz hand tremor (the jitter suspect) ---
ax = axes[2, 1]
dt = 1 / 120.0
t = np.arange(0, 1.5, dt)
truth = np.full(t.size, 20.0)                                  # wheel held at 20°
rng = np.random.default_rng(7)
tremor = 0.9 * np.sin(2 * pi * 9 * t) * 0.6 + rng.normal(0, 0.25, t.size)  # hand tremor + sensor noise
noisy = truth + tremor
styles = [(0.0, ":"), (0.2, "-"), (0.5, "--"), (1.0, "-.")]
for s, style in styles:
    _, out = full_pipeline(noisy, dt, smoothing=s)
    steps = np.abs(np.diff(out)) * 2 ** 7            # frame-to-frame change in 8-bit axis steps
    ax.plot(t, out, style, lw=1.2,
            label=f"smoothing {s:.1f} (cutoff {steering_cutoff(s):.1f} Hz, worst frame step ≈ {steps.max():.1f} × 1/128 stick)")
ax.axhline(steering_output(np.array([20.0]))[0], color="k", lw=2.2, alpha=.5, label="perfectly still hand")
ax.set_title("F. Holding a steady 20° turn with 9 Hz hand tremor —\nthe vertical jitter between frames IS the wheel jitter you see")
ax.set_xlabel("time (s)"); ax.set_ylabel("stick X")
ax.legend(fontsize=7); ax.grid(alpha=.3)

fig.tight_layout(rect=[0, 0.01, 1, 0.94])
fig.savefig("docs/steering/steering-explained.png", dpi=130)
print("saved docs/steering/steering-explained.png")

# ---- bonus: quantisation demo (why a wheel can look 'packet-y') ----
fig2, ax = plt.subplots(figsize=(11, 4))
dt = 1 / 60.0
t = np.arange(0, 2.0, dt)
rate = 20 * DEG          # steady 20 deg/s turn
angle = rate * t
ideal = steering_output(angle)
for bits, style, lbl in [(8, "-", "8-bit axis (0.0078 steps)"), (16, "--", "16-bit axis")]:
    q = np.round(ideal * (2 ** (bits - 1))) / (2 ** (bits - 1))
    ax.plot(t, q, style, lw=1.2, label=lbl)
ax.plot(t, ideal, "k", lw=2.6, alpha=.45, label="ideal (analog)")
ax.set_title("What 'turning in packets' looks like: if the axis is quantised (8-bit),\n"
             "a steady turn advances in visible steps — the wheel graphic jumps between them")
ax.set_xlabel("time (s)"); ax.set_ylabel("stick X during a steady 20°/s turn")
ax.legend(); ax.grid(alpha=.3)
fig2.tight_layout()
fig2.savefig("docs/steering/steering-quantisation.png", dpi=130)
print("saved docs/steering/steering-quantisation.png")
