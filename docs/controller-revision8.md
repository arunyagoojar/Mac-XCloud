# Revision 8 — steering that holds, linear touch, faster flick rearm

## Changes

- **Steering (gyro on Left stick):** the held-tilt output now carries a dedicated steering dead-zone compensation defaulting to 0.30 (slider 0–0.6). The previous build reused the aiming compensation default of 0.12, which sits inside Forza's large inner stick dead zone — slow tilts produced nothing and held angles flickered around the game's dead-zone edge, reading as constant recentering. A new Steering range slider (10–60°, default 30°) sets the tilt that reaches full lock, so cruising precision can be tuned per game. The neutral band (≈1.2°) is wider than gravity-vector noise, so a held angle no longer flickers across the gate, and the steering filter no longer restarts whenever the target passes through neutral.
- **Gyro aiming symmetry:** the precision gyro no longer hard-resets its filters whenever motion dips below half the noise threshold. Output still releases immediately at rest, but the filter state decays instead of being dumped, so the return stroke after a direction change responds as fast as the stroke that entered the turn. Filters reset only after 0.3 s of sustained rest. For games with a nonlinear stick curve, the settings note now recommends the game's Linear response curve; a standard game curve exaggerates fast strokes over slow returns and no local change can undo that.
- **Flick shifting:** rearming no longer requires returning to the neutral tilt plus a 150 ms settle. The gate reopens 50 ms after the gesture decays, so repeated downshifts while drifting work at roughly 3 shifts per second. A stroke moving back toward neutral is still never treated as a shift — a deliberate opposite flick crosses neutral while still fast and fires there.
- **Touchpad:** the double saturation curve is gone. Filtered finger velocity now maps linearly onto the stick (ceiling = full stick), and the game dead-zone compensation applies while moving. Previously every swipe above a modest speed saturated near the same output, which is why the sensitivity slider appeared to do nothing. The 0.05–3 slider now changes slow-glide and fast-flick speed proportionally.
- **Cleanup:** removed the dead `mouseMode` branch from the browser polling adapter; the touchpad-to-mouse path is now fully gone from native code, UI, and injected scripts.

## Quick test

1. Forza, gyro stick = Left: hold the controller face angled toward you, press Center Gyro while level, then tilt a few degrees. Slow tilts should now turn the car (raise Steering dead-zone compensation if not; set Forza's own steering dead zone to 0 if possible). Hold a tilt: the wheel must stay there with no recentering.
2. CoD, gyro stick = Right: set the game's response curve to Linear, raise "Game dead-zone compensation" until slow motion registers, and lower sensitivity until fast flicks no longer feel clipped. Move right then retrace left by the same angle: the view should return to its starting point.
3. Flick shifting: upshift, then immediately downshift repeatedly without returning fully to neutral — each deliberate flick should shift; the return stroke should not.
4. Touchpad aiming: swipe slowly, then fast, at one sensitivity; the outputs should be clearly proportional. Raise/lower sensitivity and confirm the change is now obvious.

## Validation and limits

Release build succeeded. 86 controller/model contract checks pass, including: rapid repeated downshifts without a full return to neutral, return-stroke suppression after rearming, a deliberate opposite flick crossing neutral, reversed gyro keeping full response across a turnaround pause, slow cruising tilt clearing a 0.30 dead zone, the steering filter holding an angle for ten seconds without restart, and linear touch output (half finger speed = half output). Browser polling, bridge, and preset-store contracts pass.

Live Forza/CoD verification on the controller is still pending. The steering hold is still subject to the game's own steering assist and response curve, and gyro aiming through a stick remains subject to the game's maximum turn speed — linearity claims apply to the input path, not the game's curve.
