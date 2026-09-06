# Steering, trigger modes and tester follow-up

## Steering
Raw accelerometer readings now use complementary angle fusion. Rotation rate predicts the next turn; absolute acceleration corrects the estimate with a 180 ms time constant. The correction is not a hard dead zone: slow turns still register, and a held angle remains anchored indefinitely. This reduces the immediate steering jump caused by moving the controller sideways. Apple-provided separated gravity remains authoritative. The existing final stick smoothing, response settings, gyro aiming, touchpad and flick code remain unchanged.

This is a targeted complementary-filter implementation, informed by the separation of gyro prediction and gravity correction in [GamepadMotionHelpers](https://github.com/JibbSmart/GamepadMotionHelpers). It is not a port of that library or a claim of identical performance. Synthetic tests cover ten-minute holds, correct-sign slow turns, rapid reversals, brief sensor loss, and an accelerometer spike. Controller testing is still required: translation can resemble gravity over longer intervals, and a nearly horizontal grip remains poorly observable. Center the controller in your normal face-toward-you driving grip. Keep game dead-zone compensation at zero unless the game actually needs it.

## Trigger modes
The default picker now offers the twelve requested designs plus Off. Old saved designs remain loadable as Previous selections; custom presets are preserved. Acceleration uses a 10–65% linear ramp (following the requested formula); brake uses an 8–78% quadratic ramp; bow uses an 8–78% cubic ramp. Pistols have two resistance stages, separate break and release pulses. Rifle/automatic modes add periodic recoil, and the remaining designs use their own pressure thresholds and haptic envelopes.

Resistance uses the DualSense ten-position API. Handle haptics layer independently; this does not stack two mutually exclusive trigger hardware modes. Requested continuous curves are therefore approximated by hardware zones. Resistance spikes are capped at 100%; pulse timing is quantized by the input polling interval and macOS scheduling. These effects infer actions from trigger travel, not Xbox weapon/fire telemetry. Rifle, chainsaw, shield and motor rhythms are local approximations; no exact mechanical force calibration or native PS5 parity is claimed. Haptics respect the existing intensity setting and Off switch. Trigger locks/custom effects take priority.

Reference: [Apple adaptive trigger API](https://developer.apple.com/documentation/gamecontroller/gcdualsenseadaptivetrigger).

## Settings and navigation
OLED now updates a dedicated live stylesheet. Global preferences also display the existing reload-needed indication, matching Better xCloud's page-load settings behavior. This matters for animation, layout, connection and other initialization-only preferences. Every exposed non-native setting ID was checked against the bundled script; this is not a live verification of every server/game-dependent setting. Native Back and Home buttons are available while browsing, hidden during streaming.

## Remote play / Intel
The tester demonstrated working remote play on both Macs after manually powering on the Xbox. The current project and release workflow already request both architectures. The workflow now fails before publishing if the main executable lacks either arm64 or x86_64. This does not replace testing on actual Monterey hardware.

The bundled console manager considered an undefined list ready and cached console states indefinitely. Readiness now requires an array and reopening an expired console list refreshes it. No new authentication scopes or guessed wake endpoint were introduced. Standby waking is **not confirmed fixed**. Greenlight's inspected stream launch uses an authenticated home-session request; the inspected console-list path uses a separate Xbox Web API client. A dependable explicit wake feature needs the appropriate authenticated command path and testing against a real sleeping console. The tester should verify console remote features and sleep/power settings, compare the official Xbox remote-play page, and capture whether the console list says Standby or Off before launch.

Sources: [Better xCloud remote-play setup](https://better-xcloud.github.io/remote-play/), [Greenlight stream launch](https://github.com/unknownskl/greenlight/blob/main-v2/packages/desktop/main/helpers/xcloudapi.ts), [Greenlight console API](https://github.com/unknownskl/greenlight/blob/main-v2/packages/platform/src/controller/smartglass.ts).

Source-only changes; no release or downloadable app generated.
