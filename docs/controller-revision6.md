# Revision 6 — precision gyro, touch sensitivity and stick selection

## Changes

- Gyro and touchpad each have a simple Left stick / Right stick selector, defaulting to Right stick. Selections save with profiles. Mouse mode ignores the touchpad stick selector.
- Gyro blends with the selected physical stick rather than switching off when that stick moves. Game-dead-zone compensation fades into fine correction as the physical stick moves farther, avoiding an abrupt gain change at the old threshold.
- Touch retains physical-stick priority. Touch only suppresses gyro when both target the same stick; different stick targets can operate independently. Mouse touch suppresses right-stick gyro during contact to avoid competing camera inputs. Gesture exclusion remains.
- Raw gyro rates are filtered before noise gating. The old default 0.025 rad/s dead zone becomes a 0.003 rad/s precision threshold; explicitly customized old values remain unless changed with the new slider. A hysteresis gate and per-axis noise suppression stabilize slow direction changes. Sensor rest releases immediately.
- Default game-dead-zone compensation is now 0.12 when no explicit value is saved. Explicit saved settings, including zero, remain. This lets small detected motion clear common game stick dead zones. It is adjustable because game dead zones differ. With the physical stick in use, compensation fades out while fine gyro correction remains.
- Touch sensitivity now uses a gradual saturation curve instead of clipping many swipe speeds to the same full-stick value. Changing sensitivity resets the affected filter state. Laptop-style motion and direct HID contact/report timing remain.
- Native mouse setup now matches the bundled Better xCloud native handler's full mouse/keyboard/relative-input configuration. Status distinguishes configuration, queued motion and missing support. Exported diagnostics include mouse packet count, last movement and advertised input types. Queueing packets is not confirmation that the game receives them.
- Exported diagnostics include average and maximum native-to-browser call turnaround. These are not end-to-end gameplay latency measurements. No controller update-rate increase or high-frequency UI publication was added.

## Quick test

1. Quit the previous build and open Revision 6. Both selectors should initially be Right stick unless you change them.
2. Keep Flick shifting off for shooter aiming. Start with the noise threshold at 0.003 and sensitivity at its saved value. Slowly turn left/right; then combine gyro with the physical stick. Use Center Gyro while completely still if there is drift.
3. If slow motion is detected but a game ignores it, match Game dead-zone compensation to that game's stick dead zone. If you previously saved zero compensation, it stays zero. Lower the compensation if it makes small movement too abrupt.
4. Swipe at similar speeds with touch sensitivity near 0.05 and near 1. The response should now differ clearly. Test touch on Left stick and gyro on Right stick, then reverse them.
5. For mouse mode, read Last stream delivery after swiping. If movement is queued but there is no response, export diagnostics and report the game name. A game's mouse setting alone does not prove its cloud session negotiated mouse support.

## Validation and limits

Release build; 73 controller/model checks; 17 profile tests; browser routing and native mouse checks. Tests cover slow motion below the old cutoff, stable sensor rest, orthogonal-axis noise, sensitivity differences, independent saved targets, both routing directions, simultaneous physical-stick/gyro input, release and expiry.

Live subjective smoothness and mouse reception in the user's game have not been verified for this build. The earlier hardware test established roughly 15 ms Bluetooth touch-report intervals; this build does not claim a newly measured end-to-end latency improvement.

The mouse configuration follows the local bundled NativeMkbHandler implementation. [Better xCloud native mouse documentation](https://better-xcloud.github.io/native-mouse-and-keyboard/) describes platform/game prerequisites; [Xbox's official cloud mouse/keyboard collection](https://www.xbox.com/en-us/play/gallery/mouse-and-keyboard) lists supported cloud games. The filter work continues to use the [1€ speed-adaptive filtering approach](https://gery.casiez.net/1euro/).
