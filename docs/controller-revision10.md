# Revision 10 — steering gets its own delivery channel

## Root cause of the dead left stick

Steering was delivered on the gyro channel, which the injected browser script treats as an *additive* contribution to the selected stick. Two things could erase it before Xbox ever read the axes:

1. **Touch-aiming release zeroing.** When Touchpad aiming is enabled, its block overwrites the target stick's axes every update — writing 0 when no finger is down — and it runs before the gyro contribution. With the Touchpad stick selector set to Left (left over from earlier cross-testing), the left stick was zeroed every frame: steering gone, and even the physical left stick dead in-game, while right-stick aiming on different axes kept working.
2. **Touch ownership suppression.** While a finger was down on the pad, the same-stick ownership rule skipped the gyro contribution entirely.

The settings panel still showed steering output because the app computes it before the browser applies it — the readout could not show the suppression.

## Changes

- **Steering now drives the left stick on a dedicated channel** (`LeftThumbXAxis`/`LeftThumbYAxis`, the same channel the browser applies unconditionally for stream calibration). The steering value is combined with the live physical left stick, so the thumbstick stays usable underneath the wheel, and no touch release, ownership rule, or physical-magnitude gate can zero it. The gyro keys are not sent in steering mode, so nothing can double-apply.
- **Touchpad aiming cannot target the left stick while steering mode is active** — it always drives the right stick then, and the Touchpad stick picker is disabled with a note while steering is selected.
- **New "Test Steering in 3s"** in Controller Tools → Web Controller Support: it drives the left stick left for ~1.5 s through the exact channel steering uses, with sensors bypassed. If the car turns, delivery and the game are fine and any remaining fault is in the steering settings; if it does not turn, the fault is between the browser and the game — export diagnostics and report the game name.
- **Sensor status shows the active mode and target** (e.g. "Receiving motion reports · Steering wheel → Left stick"), so a preset recall or a mode that did not stick is visible immediately.
- Fixed the Gyro mode picker silently doing nothing when the profile had never stored enhancements.

## Quick test

1. Controller Tools → **Test Steering in 3s**, return to the game: the car must hold left for about 1.5 s. This isolates delivery from sensors.
2. Gyro mode → Steering wheel, Center Gyro while driving straight, tilt a few degrees: the car should now turn and hold.
3. Check Sensor status shows "· Steering wheel → Left stick". If it ever shows Aiming in-game, a preset recall changed the mode — reselect it.
4. If the car turns with Test Steering but not with tilts, raise Steering push (the game's own dead zone is eating small outputs); set Forza's steering dead zone (inside) to zero and lower the push for the finest control.

## Validation and limits

Release build succeeded; 95 controller/model checks, browser polling/bridge contracts, and 17 preset-store checks pass. The delivery-channel change is Swift-side only; the injected script is unchanged and its contracts still pass. Live verification on the controller is pending. Steering remains subject to the game's own dead zone and response curve; the Test Steering button exists precisely to separate that from any app-side fault.
