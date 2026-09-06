# Revision 3: compact overlay and controller aiming route

The native overlay is now a single capsule with 9–11 point text, tighter gaps and padding, with its existing native blur and 3-point screen inset.

Gyro/touch aiming now enters the standard browser gamepad readings before Better xCloud/Xbox captures the polling function. It preserves the physical controller, buttons and rumble actuator. Motion updates the gamepad timestamp, even without a physical stick/button change. This removes the dependency on capturing an internal Xbox input-channel baseline and matching an Xbox player number to a browser device index. The internal channel no longer applies aiming again. Input expires after 200 ms; physical values are restored. Multiple controllers and hidden/paused pages suppress aiming.

Native touch aiming polls contact state directly when available, rather than relying solely on callbacks that another controller consumer can replace. Polling continues in the common run-loop modes. Gesture actions are blocked centrally while touch aiming is enabled, including delayed taps. Gesture controls are disabled and shown off; saved mappings remain available when aiming is switched off.

Last stream delivery now reports a missing browser connection or JavaScript error instead of silently ignoring it. “Browser input updated” means the browser accepted values, not proof the remote game consumed them.

## Test on your controller

1. Quit the old app and open this build. Start a game using one DualSense.
2. Enable gyro. For the first check, turn off “Only while holding L2”. Rotate the controller: confirm Live gyro values change. Return focus to the game and check aiming.
3. Enable touchpad aiming and move a finger away from the centre. Check aiming and lifting to stop. Swipe, tap and hold: no gesture should open the overlay/settings while touch aiming is on.
4. Turn touchpad aiming off. Your configured gestures should work again.
5. If aiming fails, check Live gyro/Live touch and Last stream delivery. In the Test page, use Test Aim in 3s and return focus to the stream before the countdown ends; this sends a brief synthetic turn without relying on sensors. Export diagnostics after reproducing the failure. Include USB/Bluetooth connection type.

Validation: Release build, controller contracts, browser polling contracts and bridge contracts. The polling test models an Xbox-style timestamp filter, nonzero browser controller slot, no internal input channel, touch release, expiry, identity/actuator preservation and prevention of duplicate aiming. Native HUD was rendered and inspected. A live DualSense/Xbox session has not been verified by the developer; no guarantee of sensor delivery or frame rate is made.
