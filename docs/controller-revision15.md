# Steering linearity — source-only update

## Diagnosis and limits

The saved Default profile inspected for this report used approximately 50.13° per side, response exponent 1.003, zero game compensation, 0.096° center dead zone, and maximum smoothing. These settings do not introduce a 30–50% switch. The user reports midpoint (0.5) Forza linearity and feels the sudden response in the car. This does not establish a fault in app output or exclude game assists, outer dead-zone mapping, vehicle behavior, or a real sensor disturbance.

The prior spring has an eased step response: movement accelerates and then decelerates toward a changed target. Its unclamped differential equation is linear in the mathematical sense; that does not mean its step transition moves in equal increments over time. The new implementation targets the user's request for even temporal increments. It is not a proven fix for the remaining in-car behavior.

## Research

- [Moving-average filtering and step response, Steven W. Smith](https://www.dspguide.com/ch15/2.htm): equal weighting provides smoothing with a finite transition window. Implemented a time-weighted rectangular average of recent final steering targets, using elapsed durations rather than a fixed count of packets.
- [Gyro steering controller for Xbox Cloud Gaming](https://github.com/pygarv/gyro-steering-controller): another project using Gamepad API injection for nonstandard steering input. Its architecture does not establish native wheel support or remove game-side mapping. No code or dependency was imported.
- [Forza's official FH5 steering guidance](https://support.forza.net/hc/en-us/articles/4409761195923-FH5-Wheel-Setup-and-Tuning): Normal steering includes multiple assistance layers; the document identifies steering linearity 50 as the linear mapping. Wheel-specific options in that article should not be assumed available to this gamepad-based cloud session. The user already reports the midpoint setting, so changing it is not presented as the solution.

## Implementation

Replaced spring output smoothing with a time-weighted moving average. A held step ramps evenly over 30–150 ms and reaches its final value at the end of that window, with no spring velocity, overshoot or amplitude-dependent acceleration. Small and large targets use the same weights. History contains only the last 150 ms and merges adjacent equal targets. Resets and long gaps discard it. Polling frequency, sensor selection, gyro aiming and touchpad behavior remain unchanged.

The existing smoothing setting is retained, but its label now means the full held-step transition time rather than the old 90% response time. A 150 ms transition from 0° to a 15° equivalent target advances approximately 1.67° per 60 Hz update until it reaches 15°. This does not mean a live game receives every intermediate value or that its car follows a linear wheel angle.

Added a native response preview against a proportional reference and Reset to Linear, which sets exponent 1, center dead zone 0 and compensation 0 only when clicked. Turning range, smoothing, inversion and other features are retained. Saved settings were not silently changed. Game-side dead zones remain separate.

## Validation

Xcode Release compilation succeeded; no downloadable application was packaged. All 163 controller/model checks and the gamepad polling, native bridge and settings-manager JavaScript suites passed.

New coverage includes equal temporal increments for targets ±10%, ±30%, ±40%, ±50%, ±80% and ±100%; mathematical superposition across changing targets and reversals; every 1% angle-to-target increment across the full range; and all 201 steering levels through the extracted actual app adapter and outgoing-channel wrapper. The latter models standard gamepad-to-Xbox conversion; it is not a live test of every Better xCloud configuration or server acknowledgement.

Moving-average filtering has different noise rejection than the spring. The deterministic alternating-noise check now requires over 86% attenuation at the midpoint setting instead of the spring's tighter bound. Tests also confirm tiny held inputs, settled angles, timestamp handling, short sensor rejection, resets, intermediate values and exact finite-window completion.

## Next verification

Run from Xcode. Reset to Linear only if a strictly proportional app mapping is desired. Watch Angle, Target and Smoothed around the reported 30–50% region. A 50% held angle should settle to 50% output. If those remain steady while the car suddenly changes direction, capture the in-game steering outer dead zone and assist setting, plus the app's existing controller diagnostics. Do not keep changing filters to compensate for an unmeasured game-side effect.
