# Revision 5 — trackpad aiming, adaptive filtering and flick shifting

## Behavior

Touch aiming now behaves like a laptop trackpad: finger movement turns the camera, a stationary finger stops turning, and lifting/repositioning does not move the camera. Touchpad sensitivity is adjustable. The final output remains an Xbox right stick, so game-specific stick dead zones, acceleration and maximum turn speed still apply; it is not native mouse input.

Tilt mode is removed from the UI and no longer affects input. Its old optional stored field is retained only for compatibility with exported profiles. New Flick shifting emits an 80 ms vertical stick pulse, then suppresses the opposite return stroke. It rearms after returning near the starting orientation and settling for 150 ms. Enable it for gear shifting, with Only while holding L2 off. Keep it off for continuous shooter gyro aiming. Hold still briefly when enabling it; Center Gyro resets the resting reference.

Gyro and touch velocity use speed-adaptive filtering: stronger smoothing for steady small inputs, less smoothing for fast movement. Zero input and lift still release immediately; no filter tail is added to a release. The physical-right-stick and touch-over-gyro priority rules remain, as does gesture blocking during touch aiming.

## Native touch input

A read-only IOHID input-report reader now supports standard DualSense and DualSense Edge full USB/Bluetooth reports. It does not seize the controller, send output reports, change rumble or replace the normal gamepad. It activates with touch aiming and accepts input only when one relevant HID device and one native controller are present. Actual finger-contact bits replace inactivity-based lift guesses when raw reports are available.

Finger velocity uses the interval between received hardware reports. Re-reading a report does not create an artificial zero-speed sample. Source changes recenter safely; stale raw reports release aiming. If direct reports are unavailable, the existing native GameController path remains; its coordinate-only fallback still cannot know contact state as accurately as full touch reports. Unsupported/short/malformed packet layouts are rejected.

## Research

- [Casiez, Roussel and Vogel: 1€ filter](https://gery.casiez.net/1euro/) describes adaptive cutoff filtering and the jitter/lag trade-off. This build implements the algorithm in Swift with application-specific parameters; no third-party filter library was bundled.
- [SDL DualSense driver](https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/SDL_hidapi_ps5.c) documents full report layouts, packed coordinates and explicit contact flags. The app's small read-only decoder was written for these fields; SDL itself was not added as a second controller backend.

## Live hardware evidence

With the user's connected controller, a read-only probe opened one Sony gamepad and received 1,047 Bluetooth reports (report ID 49 / 0x31, 78 bytes), including 627 reports with the first finger marked down. Median report interval was 15.005 ms; p95 was 16.499 ms. An earlier window contained 1,044 reports and no finger-down reports.

The command-line GameController probe exposed zero controllers, so these results verify HID report delivery/contact flags, not native gyro filtering or Xbox gameplay. GameController works in the application as established by the user's prior test. These measurements are sensor-report intervals, not end-to-end latency.

## Validation

Release build; 64 controller/model checks including flick return suppression, delayed-return suppression, rearming, filter noise reduction/fast response, trackpad stop behavior, USB/Bluetooth decoding and malformed reports; 17 profile compatibility checks; browser input/priority/regression checks. Live subjective smoothness and in-game flick behavior still require testing the new build.

## Direct mouse option

The optional **Send as mouse (supported games)** setting bypasses right-stick conversion. It uses Xbox's `queueMouseInput` path already present in the bundled Better xCloud native mouse handler and requests relative mouse input from the stream session. It requires the title to advertise mouse/keyboard support and the necessary session APIs to exist. It sends movement only: it does not bind touch gestures, clicks or keyboard keys. Mouse input in the game's settings controls sensitivity/bindings; this is not a new named touchpad device.

Cumulative mouse displacement preserves movement across coalesced bridge updates, retains fractional pixels and avoids repeated packets for unchanged data. Repositioning and output-mode changes do not produce a jump. Mouse status appears in Last stream delivery; unsupported games are reported, with no silent stick fallback. Turning this option off retains laptop-style movement translated to the right stick. Configuring mouse input does not change the stream's keyboard/touch flags. Some games reject mixed controller/mouse input; this app cannot override that rule.

[Official Xbox mouse-and-keyboard cloud game list](https://www.xbox.com/en-us/play/gallery/mouse-and-keyboard). [Better xCloud native mouse documentation](https://better-xcloud.github.io/native-mouse-and-keyboard/).

The direct mouse route passes mocked channel tests for capability gating, cumulative displacement, fractional retention, no duplicate movement, mode reset and hidden-page release. It has **not** been verified in a live Xbox game on this Mac; “Native mouse output ready” indicates successful local configuration, not remote-game acknowledgement.
