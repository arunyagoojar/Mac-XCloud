# Revision 11 — steering sensor selection and absolute wheel angle

## What was wrong

Steering read the controller's `gravity` vector without checking whether the
controller supplies one. Apple's `GCMotion` documentation requires falling back
to `acceleration` when `hasGravityAndUserAcceleration` is false; a controller in
that state reported no usable gravity, so the steering angle was never valid
while the gyro readout (which uses `rotationRate`) kept moving. This matches the
reported symptom: live gyro values changed, but the wheel did nothing.

## Changes

- **Automatic sensor selection** (`ControllerWheelMotion.select`): prefers
  separated gravity when present and plausible (length 0.5–1.5 g); otherwise
  builds the wheel angle from `acceleration`; returns "unavailable" only when
  neither is usable, so a missing sensor can no longer masquerade as a valid
  zero angle.
- **Absolute wheel angle** (`ControllerWheelState`): the measured angle is
  filtered and anchored, so holding the controller still holds the wheel — even
  in the acceleration-only path where a raw accelerometer reading wobbles. In
  that path, gyro rotation rate predicts the angle between accelerometer
  updates, giving a fast-turn response without filter lag (0.25 s vs 25 ms
  time constants respectively).
- **Proportional steering response**: removed the hard 1.15° neutral gate and
  the power curve, so minute wheel changes register and left/right are exactly
  symmetric. Optional game dead-zone compensation fades across the first half
  degree instead of stepping.
- **Live steering readout** now computes while Settings is open (it previously
  displayed the last gameplay value) and reports the angle in degrees, the
  stick output, and the selected sensor source. It is also included in exported
  diagnostics.
- **Safer synthetic tests** (Test Aim / Test Steering in 3s): one cancellable
  task per test, cancelled on focus loss, controller-count change, navigation,
  or page stop, with an explicit neutral release and a reported failure reason.
- **Browser diagnostics**: the polling adapter now records all four patched
  axes (`lastAllAxes`), and combined adapter+outgoing-channel contracts cover a
  direct left-stick payload through both delivery paths.

## Quick test

1. Open the r11 build, Gyro mode → Steering wheel.
2. Hold the controller face toward you like a wheel. **Live steering** should
   show the sensor source ("Gravity" or "Accelerometer + gyro") and an angle
   that tracks your rotation. If it shows "No gravity or acceleration data",
   export diagnostics and report it.
3. Press **Center Gyro** while level. Tilt slightly: the angle should follow
   minute changes; hold the tilt: the wheel stays there.
4. In-game: **Test Steering in 3s** must hold the car left for ~1.5 s.
5. Drive: cruising should respond to small tilts; racing turns should hold
   through the corner and re-centre when you straighten the controller.

## Validation and limits

Release build succeeded. 110 controller/model contract checks pass, including
acceleration-fallback selection, zero-gravity non-silence, ten-second held
angles with zero rotation rate, a 0.057° adjustment registering, non-flat-pitch
grips, jitter attenuation, and proportional symmetric response; browser
polling/bridge contracts (including the combined steering channel test) and 17
preset-store checks pass. What remains unverified is the live feel in Forza and
which sensor source the user's controller reports; the Live steering readout
and exported diagnostics now make both visible.
