# Revision 12 — steering refinement on the user's working revision 11

## Review and scope

Preserved the user's essential fixes: acceleration fallback when macOS provides no separated gravity; absolute wheel angle and a persistent saved center; direct left-stick delivery through the native/web bridge; touch restricted to the right stick during steering; outgoing input diagnostics and synthetic test release handling. Gyro aiming and touch servo algorithms, the web input bridge, polling rates, and stream rendering are unchanged.

The previous wheel sampler immediately returned unavailable for a single rejected acceleration report or a nearly flat grip, resetting its timing. A fast reversal can produce acceleration outside the accepted magnitude range. This is a plausible cause of the reported interruption, not a hardware-confirmed diagnosis.

## Algorithm decision

Keep the existing single-axis complementary filter, improving its handling of disturbances rather than replacing the working sensor orientation with a full orientation library. Gyro prediction supplies fast changes; absolute gravity/acceleration anchors the held angle. This follows the established principle of reducing accelerometer influence during acceleration disturbances, described by [x-io Fusion](https://github.com/xioTechnologies/Fusion) and [the complementary-filter documentation](https://ahrs.readthedocs.io/en/stable/filters/complementary.html). No external library was added, and this is not claimed to be the full Fusion algorithm.

- Weight acceleration correction by how close its magnitude is to gravity; limit sudden correction steps.
- Predict through up to 200 ms without a trusted angle anchor, using the gyro and last trusted vector. Sustained invalid data releases steering; reconnecting or recovering does not erase the saved center.
- Apply gyro prediction to separated gravity as well as acceleration, retain actual elapsed sample time, and ignore out-of-order timestamps.
- Preserve indefinitely held angles while valid reports continue. There is no timed auto-center.

A single accelerometer cannot distinguish every linear acceleration from tilt; horizontal/flat grips also make this wheel-angle projection poorly conditioned. Hold the controller face toward you. Cloud transport and the game's stick steering response still affect perceived response. No zero-latency or guaranteed accuracy claim is made.

## Settings

Separate Touchpad, Gyro, and Steering Wheel pages using existing native settings styling. Wheel settings include 10–120° full-lock angle per side (20–240° total travel), smoothing, optional center dead zone, response exponent, reverse direction, game dead-zone compensation, center action, and live input status. Existing profile defaults remain 40° per side, proportional response, zero center dead zone, and 0.30 game dead-zone compensation. New fields are optional and saved per profile.

Turning angle adjusts controller travel to maximum stick input. Actual vehicle turning radius is controlled by the game and cannot be specified through an Xbox stick. For the most proportional steering, set the game's inner steering dead zone and app compensation to zero; use compensation when a game dead zone remains. Excess compensation can amplify tiny center movements.

## Validation

Release Xcode build succeeded. 120 controller/model checks and 17 isolated preset-store checks passed. All gamepad polling, native bridge and settings-manager JavaScript contract suites passed.

New deterministic tests cover rapid reversals with three missing angle samples at each turnaround (no unavailable frames and less than 0.001 rad error), ten simulated minutes of held angle, timestamp disorder, sustained invalid data, absent gyro, extended wheel travel, center dead zone, response/inversion and settings round trips. These are synthetic model checks, not measurements of physical-controller latency or in-game accuracy.

## Quick controller test

Open Settings → Controller → Steering Wheel, enable the wheel and press Center Wheel while holding your normal straight-ahead position. Start with your existing settings. Hold a left turn, rapidly reverse right, then hold the same angle for 30 seconds. Repeat at small angles. Watch live steering for any unavailable message. If near-center steering jumps, match app compensation to the game's inner dead zone, preferably zero for both. Raise smoothing only if visible angle jitter remains. Touch and gyro aiming should feel unchanged from revision 11.
