# Mac XCloud — revision 2 testing build

6 September 2026. This revision addresses your first hands-on test results. The application has been built in **Release**, with Swift optimization, rather than the previous Debug preview. Actual game FPS and controller behavior still need a repeat test on your setup.

## What changed

| Your finding | Change |
|---|---|
| Gyro and touchpad did not reach Xbox | Removed the modification hook buried in Better xCloud's controller-customization patch. The final input-channel sender now merges adjustments into copies of real outgoing controller samples. Native motion can trigger a send even without a new stick/button event. |
| Gyro orientation felt inactive | Horizontal motion now uses rotation projected onto gravity, accommodating both flat and upright controller positions. Added explicit sensor-update subscription, live readings, sensor status, and optional compensation for the game's own stick dead zone. |
| Touchpad aim ignored native input | An exposed but empty browser touch API no longer masks native contact coordinates. Native touch positions come from the tracked contact, and primary finger assignment is deterministic. |
| Swipes failed while long press worked | Swipes are detected once movement crosses the threshold. Finger lift no longer replaces the last valid position with potentially reset coordinates. Touchpad aim no longer suppresses every configured gesture. |
| Settings caused slowdown after returning to play | Live controller views update only while Settings owns the controller. Updates are capped at 30 Hz for testing and 4 Hz elsewhere. Ordinary gameplay no longer continuously republishes controller snapshots into Settings. |
| Unnecessary work during gameplay | Native input polling is 60 Hz, disabled features send no repeated bridge updates, native sends are rate-limited, and webpage UI cleanup is debounced. |
| Rumble caused repeated output work | Stream rumble now updates a continuous haptic player's intensity instead of creating a new pattern for every packet. Diagnostic publication is limited. Unchanged effects are not constantly resent. |
| Rumble amplification seemed ineffective | Removed the hidden Normal-mode cap that prevented haptic gain above 1×. Added a 25%-strength test using the actual stream-rumble curve and gain path. Already-saturated effects cannot become stronger than the hardware maximum. |
| Stats looked frozen | Native collection is serialized, bounded by a timeout, and separated from profile application. A temporary stats failure no longer pretends the game ended. The native HUD shows “Updating…” when measurements are stale. |
| Overlay touched the screen edge | The replacement native HUD has 3-point insets (macOS logical pixels) from the selected corner. |
| Overlay should be native and blurred | The stats HUD is now SwiftUI with an AppKit NSVisualEffectView using within-window HUD blur. The old web stats renderer is disabled. |

The new HUD keeps the existing choices for items, top-left/center/right position, text size, opacity, background strength, conditional colors, and PS/Xbox-button Quick Glance. Larger stat selections wrap into rows. The web player remains responsible for decoding Xbox video and supplying its stream measurements; the overlay itself is native.

The sender uses the existing Xbox channel and an actual physical-controller sample. It does not register a second controller or replace `navigator.getGamepads()`. It keeps an untouched baseline, expires native modifiers after 200 ms without updates, and sends the baseline once when modifiers expire. Multiple controllers and virtual mouse/keyboard samples are excluded from native adjustment. This still depends on the site's exposed input channel and needs a live session check.

## Trigger modes

The menu now contains **Off**, your retained **Acceleration** and **Heartbeat**, and six new choices:

- **Precision Break:** a short take-up followed by resistance and a clean release.
- **Two-stage Wall:** a light first stage followed by a stronger sustained second stage.
- **Clutch Bite:** resistance builds toward a bite point and relaxes afterward.
- **Bow Draw & Let-off:** rising draw resistance followed by a lighter hold near full travel.
- **Hydraulic Brake:** increasingly strong resistance toward the end of travel.
- **Ratchet Detents:** several resistance peaks separated by lighter zones.

These use native weapon feedback or ten positional resistance zones. They are deliberate mechanical-feel designs, not renamed constant vibrations or game telemetry. Their feel still requires your evaluation. Saved custom profiles remain intact; older built-in modes are retained only for compatibility with existing saved selections and no longer fill the main menu.

Apple documents the physical capabilities and limits of the native weapon and positional-feedback modes. Those APIs guided the designs. [Apple adaptive trigger controls](https://developer.apple.com/documentation/gamecontroller/gcdualsenseadaptivetrigger/setmodeweaponwithstartposition(_:endposition:resistivestrength:))

## Open-source Mac gyro research

### Best native reference: ds4macos

[marcowindt/ds4macos](https://github.com/marcowindt/ds4macos) is a Swift macOS motion server for Dolphin. Its README reports DualShock 4 and DualSense testing. I downloaded the repository and inspected `DSUController.swift` at commit `f95fe7c92c03af095534585f8383f4de03f6fe9d`. It explicitly enables `sensorsActive`, subscribes to `motion.valueChangedHandler`, and reads native `rotationRate`.

This is direct evidence of an existing native Mac implementation using the same Apple sensor API. It does not itself output Xbox right-stick input. This revision uses explicit motion-update monitoring and live diagnostics to distinguish failed sensor delivery from failed Xbox delivery. No DSU server or Dolphin dependency was added.

### Alternative sensor backend: DS5 Mapper

[MathiasMl/ds5-mapper](https://github.com/MathiasMl/ds5-mapper) is an MIT-licensed macOS/Windows DualSense mapper. I inspected `mapper.py` at commit `5f0ff7f52354535e1258f7a77544cedeb92c214c`. It enables SDL's gyro sensor, calibrates bias, checks stale readings, and maps motion to the mouse with smoothing. Its repository documents SDL handling the controller initialization.

This is a useful fallback if your Mac's native motion readings remain unavailable. It outputs OS keyboard/mouse events, so installing it is not a direct substitute for Xbox right-stick delivery. An SDL fallback would need to be integrated as a sensor backend, with controller identity and USB/Bluetooth behavior checked. It has not been bundled in this revision.

### Motion processing reference: GamepadMotionHelpers

[JibbSmart/GamepadMotionHelpers](https://github.com/JibbSmart/GamepadMotionHelpers) is an MIT-licensed library for calibration, sensor fusion, and gravity-aware motion conversion. It expects a separate input reader and uses degrees/second, whereas Apple's native rotation rate uses radians/second. It supports the idea of gravity-aware yaw and offers a possible later replacement for more advanced calibration. It is not a Mac driver or an Xbox transport, and has not been bundled here.

Recommendation: test the native sensor status and outgoing-input path first. If native motion reports arrive, changing to SDL would add another backend without fixing the Xbox delivery problem. If native reports remain absent on your controller while an SDL mapper reads them, an SDL sensor fallback becomes justified. No repository establishes guaranteed compatibility for your exact OS, firmware, and connection without testing.

## Please test in this order

1. Quit the older build. Open this **revision 2 Release preview** with one DualSense connected. Start a game, open Settings once, then return to it. Compare motion smoothness and FPS with Settings open in the background and fully closed.
2. Enable gyro under **Touchpad → Gyro Aim**. Check **Sensor status** and **Live gyro** while rotating the controller. Keep it still and use **Center Gyro**. For initial gameplay testing, turn **Only while holding L2** off.
3. If readings change but aiming does not, run **Test → Test Aim in 3s**, immediately return focus to the game, and watch for a brief rightward movement. Then use **Check Web Support** and export diagnostics. Record whether `inputHookInstalled` is true, whether physical baseline samples exist, and whether `mergedSamples` increases.
4. If aiming works only with large rotations, raise **Game dead-zone compensation** slightly. Set it to zero if you have already removed the in-game stick dead zone. A nonzero floor can make slow aiming less smooth, so use the lowest effective value.
5. Test touchpad aiming separately from gyro. Check the live touch coordinates. Then test your configured swipe and long-press actions. Gestures can now operate while touchpad aim is enabled; a swipe can therefore both move the camera and invoke its assigned action.
6. Toggle the stats HUD repeatedly, including via swipe. Confirm numbers keep changing and stale measurements show “Updating…”. Verify the native blur, 3-point corner inset, text size, and placement settings.
7. In Triggers & Haptics, use **Test Rumble Curve** first with global gain 0, then 1, then 2. The same weak test signal should become silent, normal, and stronger. Test the new trigger catalog slowly and report which effects feel distinct and useful.
8. Repeat the input tests over Bluetooth after USB. If problems remain, include the macOS version, connection type, game, sensor status, and exported diagnostics.

## Verified here / still pending

Verified: Release compilation; controller/model contracts; isolated profile storage/import tests; JavaScript tests covering the final input sender with motion-only changes, stable physical baselines, no cumulative gyro, expiry/release, idle behavior, browser/native touch fallback, and existing settings behavior.

Pending: your controller's motor feel, live Xbox delivery, measured CPU/GPU usage during streaming, and recovery to 60 FPS. The FPS issue may include a device, renderer, stream, or network limitation in addition to the concrete application overhead removed here.
