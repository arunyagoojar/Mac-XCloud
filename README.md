<div align="center">
  <img src="docs/images/mac-xcloud-logo.png" width="160" alt="Mac Xcloud logo">
  <h1>Mac Xcloud</h1>
  <p><strong>Xbox Cloud Gaming and Xbox Remote Play in a dedicated Mac app.</strong></p>
  <p><a href="https://github.com/arunyagoojar/Mac-XCloud/releases/latest">Download</a> · <a href="docs/releases/1.3.7.md">What's new in 1.3.7</a> · <a href="https://ko-fi.com/arunyagoojar">Support development</a></p>
  <p>Free and open source · macOS 12+ · Intel and Apple Silicon</p>
</div>

Mac Xcloud combines the Xbox website and [Better xCloud](https://github.com/redphx/better-xcloud) with native SwiftUI/AppKit settings, controller tools and a compact macOS performance overlay. Web content runs in Apple's WKWebView; motion sensing, controller feedback and the app interface use native macOS APIs.

You need the account, subscription and region access required by Xbox for the games you stream. Remote Play uses your own configured Xbox console. This project is independent of Microsoft.

## What's new in 1.3.7

- More usable motion steering: gyro-assisted tracking reduces accelerometer jolts while preserving small corrections and held turns.
- DualSenseX-style adaptive-trigger menu: GameCube, Resistance, Bow, Galloping, gun modes, Choppy, a Very Soft–Rigid resistance ladder, Calibrate and the Vibrate presets, with pressure-driven haptics and release/recoil effects.
- Live OLED background updates and clearer reload requirements for settings.
- A clean play area: browsing uses shortcuts instead of permanent Back/Home buttons.
- Fresh console status when reopening Remote Play, plus a release check for both Mac architectures.
- Accurate release notes in GitHub releases and Sparkle update dialogs.

See the [full release notes](docs/releases/1.3.7.md). Xbox waking from standby remains unresolved.

## Features

### Native Mac interface

- Dedicated window, fullscreen, menu-bar actions and persistent Microsoft sign-in.
- Native settings with five main groups: Play & Streaming, Controller, Motion & Steering, Profiles & Shortcuts, and App.
- Automatic settings saving, descriptive help, suggested settings and collapsible advanced controls/diagnostics.
- Xbox-style startup animation, loading/connection states, retry controls and controller reconnect recovery.
- Cursor hiding during controller use; normal mouse navigation and text entry remain available.
- Native browsing and app shortcuts, without permanent navigation buttons covering the website.
- Sparkle automatic updates with readable, version-specific release notes.

### Cloud streaming, video and sound

- Resolution, visual-quality/H.264 profile and maximum bitrate choices; optional prevention of resolution drops.
- Region selection, region latency testing, preferred language and IPv6 preferences.
- FSR upscaling and available WebGL/WebGPU processing choices, sharpening, renderer preferences and frame-rate limits.
- Aspect ratio, video position, brightness, contrast and saturation controls.
- Volume adjustment/boost, microphone-on-launch preference and optional combined audio/video streams.
- Filtered screenshots and screenshot actions.
- Better xCloud options including console-version Fortnite and local co-op where supported.

Available resolutions, codecs and processing backends depend on Xbox, the game, your Mac and WebKit. Selecting an option cannot unlock an unsupported service capability. Region/stream initialization changes may need a new session; global appearance and other startup preferences may need **Reload to Apply**.

### Native performance overlay

- Compact pill-shaped HUD with macOS material blur and edge spacing.
- Selectable FPS, ping, bitrate, decode time, packet loss and dropped-frame statistics.
- Position, font size, opacity, background strength and conditional colors.
- Quick Glance behavior and controller shortcut/gesture activation.
- Additional stream, region, controller and motion diagnostics in Settings.

### Controller calibration and customization

- Stick-center, full-range and trigger calibration, plus live input testing.
- Gameplay dead zones, independent left/right trigger start offsets and stick response curves with previews.
- Controller remapping and controller shortcut profiles.
- Haptic intensity, sharpness and supported locality controls; controller LED options.
- Global rumble gain and profile-specific rumble response shaping.
- Independent left/right trigger lock emulation, subject to hardware support.
- Controller detection, native/browser mismatch diagnostics and reconnect/focus recovery.

### Motion steering, gyro and touchpad

- **Steering wheel:** rotate a motion-capable controller to drive the virtual left stick. A held physical angle holds the steering input.
- Full-turn angle per side, response curve, smoothing, center dead zone, game dead-zone compensation, inversion, maximum output and recentering.
- **Gyro aiming:** rotation-rate aiming on the right stick, with sensitivity, activation and response controls.
- **Flick shifting:** upward/downward flicks produce right-stick shift inputs while suppressing the return stroke. Enable manual gears and map **right-stick up to upshift** and **right-stick down to downshift** inside the game.
- **Touchpad aiming:** relative touch movement with sensitivity adjustment and left/right stick selection.
- Touchpad gesture actions, including swipe/hold options. Aiming takes priority so gestures do not compete with it.
- Motion diagnostics showing sensor availability and delivered input.

These are controller-to-stick translations, not a system-wide virtual steering-wheel driver. Forza receives a gamepad axis, not a force-feedback wheel. DualSense is the main tested controller; other devices depend on the motion/touch features macOS exposes. Gyro aiming, steering and flick shifting are separate selectable modes.

### Adaptive triggers

The default menu mirrors the DualSenseX trigger list. "Custom Trigger Value" applies your custom editor settings; every named mode maps to the controller's documented effect primitives (positions ×9 zones, strengths ×8, frequencies ÷255):

| Mode | Mapped effect |
| --- | --- |
| Normal Trigger | Off; the trigger keeps its physical spring |
| Custom Trigger Value | Your custom editor values (mode, positions, strengths, amplitude, speed) |
| GameCube Trigger | Light pull, then a hard digital wall near 78% travel with a release click |
| Resistance Trigger | Continuous resistance (50%) from rest |
| Bow Trigger | Draw resistance that snaps at 78% |
| Galloping Trigger | Slow rhythmic vibration approximating the two-foot gallop |
| Semi Automatic Gun | Resistance that breaks once per pull at 44% |
| Automatic Gun | Full-amplitude vibration at DualSenseX's documented rate 15 |
| Machine Trigger | Full-amplitude slow vibration with a mechanical handle-haptic rhythm |
| Choppy Trigger | Stepped resistance alternating across the ten hardware zones |
| Very Soft → Hardest | Continuous resistance from 25% to 88% |
| Rigid Trigger | Full resistance from rest; travel is fully blocked |
| Calibrate Trigger | Resistance sweeping from none to full across the whole pull |
| Vibrate Trigger Pulse | Slow, strong vibration pulses |
| Vibrate Trigger 10 Intensity | Gentle vibration (DualSenseX intensity 10 ≈ 3/8 amplitude) |
| Vibrate Trigger Custom Intensity | Vibration using your custom amplitude and speed |

- Independent effects for left and right triggers, also selectable from the Mac menus.
- Custom constant, break/release, slope, smooth curve, staged, detent and vibration/ramp designs.
- Editable strengths, travel positions, vibration amplitude/frequency and curve previews.
- Saved custom-trigger library; older saved designs — including the previous twelve-design default menu — remain loadable as previous selections.
- Resistance remains active while independent handle haptics provide local feedback. Locks and custom effects take priority.

Adaptive resistance requires a supported DualSense. Positional resistance uses ten hardware zones on macOS 12.3+, with simpler fallback on 12.0–12.2. Effects approximate the intended feel; percentages are API strengths, not calibrated physical forces. These are **local simulations**, not Xbox weapon telemetry, and cannot automatically identify the gun you equip. The app does not promise native PS5 force-feedback parity.

### Profiles, shortcuts and macros

- Named profiles: create, duplicate, rename, switch and delete, with a protected Default profile.
- **Remember settings per game:** game IDs are preferred, with website-title fallback. Newly encountered games get separate profiles; leaving a stream restores the general profile.
- Saves controller, motion, touch, triggers, remapping/shortcuts and selected picture/audio values. App appearance, connection choices and hardware calibration remain global.
- Import/export profiles as JSON files for sharing between Macs, with validation and portable custom-effect snapshots.
- Controller button/chord bindings with press, release, hold and double-press activation.
- Editable macros with presses/releases, waits, haptics and app actions; up to 16 steps and two seconds per macro.
- Hold-to-fire with adjustable repetition rate.

Choosing the same profile for multiple games deliberately shares it. Title fallback depends on the website supplying a meaningful game title.

### Xbox Remote Play

- Stream from your own Xbox, including on your home network, through Better xCloud's Remote Play support.
- Remote resolution/HQ and IPv6 preferences, console status and input diagnostics.
- Stale console lists refresh when reopened.
- Physical controllers work when WebKit exposes them to the browser Gamepad API.

Remote Play still needs Xbox authentication and console remote-feature setup; it is not an offline LAN protocol. Testers have reported working console streaming on Apple Silicon and an Intel Mac. **Automatic waking from standby is not confirmed fixed:** some consoles still need to be powered on manually. See [Better xCloud's setup guide](https://better-xcloud.github.io/remote-play/).

### Website appearance and behavior

- OLED black background, reduced animation, scrollbar visibility and controller-friendly layout.
- Controller connection toasts, simplified stream menu and feedback-dialog suppression.
- Loading artwork, rocket animation, queue estimates and game-card wait times.
- Home-section visibility, website image quality, layout and optional analytics/feature blocking.

## Why keyboard/mouse gaming was removed

Mac Xcloud uses **WKWebView, Apple's native WebKit browser view—the same browser engine family as Safari**. It does not embed Chrome or Edge. The browser APIs needed for reliable keyboard/mouse gaming and pointer capture are more limited in this environment, and Better xCloud's Chromium behavior could not simply be carried over.

Making native mouse gaming and keyboard-to-controller emulation reliable became disproportionately time-consuming. I chose to remove them instead of shipping a half-finished experience. Normal typing, clicking, scrolling and app shortcuts still work. Controller shortcuts and macros remain supported. The bundled Better xCloud engine retains upstream code, but its removed gaming modes are disabled by the native bridge.

## App shortcuts

Also listed in **Settings → App → About → App shortcuts**.

| Action | Shortcut |
| --- | --- |
| Back in website history | ⌘[ or Backspace |
| Forward | ⌘] |
| Xbox home | ⇧⌘L |
| Open Settings | ⌘, |
| Reload | ⌘R |
| Fullscreen | ⌃⌘F |

Backspace navigation is disabled while typing, composing text or playing a stream. Settings has its own history controls. Configure controller actions under **Profiles & Shortcuts**.

## Forza Horizon 5: relaxed cruising setup

This is a suggested starting point, not a universal best tune. The app sends a **left-stick axis**, so configure the game's controller input rather than its wheel force-feedback options.

| Mac Xcloud steering setting | Start here |
| --- | --- |
| Full turn | 45° each side |
| Response exponent | 1.0 / linear |
| Smoothing | 0.35, about 72 ms |
| Center dead zone | 0° |
| Game dead-zone compensation | 0 |
| Maximum steering | 100% |
| Invert | Off, unless your direction is reversed |

Center the controller while holding it comfortably facing you. In FH5, start with **Normal steering**, **ABS on**, **traction control on**, and **automatic shifting** while learning. Use steering dead zones **inside 0 / outside 100** and leave steering linearity at its neutral **50** (or **0.5** if presented as a normalized value), where available. Wheel-only options do not apply to this input path.

If it is twitchy, increase full turn to 50–55° first. If corrections feel delayed, lower app smoothing to 0.2 before adding sensitivity. Change one setting at a time and save it in your Forza profile. Do not reduce maximum steering to cure center sensitivity: that also limits available steering at low speed.

Slow down before tight corners. More steering input cannot overcome tire grip, and Normal steering adds gamepad assistance. Start with a moderate-power car and gentle roads before working on drifting or rapid countersteering. [Forza's own tuning guide](https://support.forzamotorsport.net/hc/en-us/articles/4409761195923-FH5-Wheel-Setup-and-Tuning) explains Normal/Simulation behavior and the neutral linearity value; the numbers above are this project's suggested motion-controller baseline.

## Download and requirements

1. Download `MacXcloud.zip` from the [latest release](https://github.com/arunyagoojar/Mac-XCloud/releases/latest).
2. Extract and move **Mac Xcloud.app** to Applications.
3. Open the app and sign in to Xbox.

The deployment target is **macOS 12.0+**, with a universal Intel/Apple Silicon executable. Some controller and renderer features require newer macOS or supported hardware. Releases are ad-hoc signed, not Apple-notarized; macOS may require approval in Privacy & Security. Use releases from this repository.

## Build from source

Building requires **Xcode 26 or newer** and a Mac capable of running it. That is separate from the app's macOS 12 deployment target.

```bash
git clone https://github.com/arunyagoojar/Mac-XCloud.git
cd Mac-XCloud
xcodebuild -project "Mac XCloud.xcodeproj" \
  -scheme "Mac XCloud" -configuration Release \
  -destination "generic/platform=macOS" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO build
```

Or open the project in Xcode and run the **Mac XCloud** scheme. Automated contracts live in `Tests/`; controller feel, network behavior and OS compatibility still need real hardware testing.

## Releases and updates

Pushes to `main` trigger the release workflow. The project version selects `docs/releases/<version>.md`; the workflow uses that file for both GitHub and Sparkle release notes. Add the versioned notes whenever bumping the version. Publishing fails if the notes are missing or the executable lacks Intel or Apple Silicon support.

Sparkle verifies the update archive with a separate EdDSA signature. This is not Developer ID signing or notarization.

## Credits and support

Built on [Better xCloud](https://github.com/redphx/better-xcloud) by redphx and [Sparkle](https://sparkle-project.org/). Motion research references and implementation limits are documented in [steering reliability](docs/steering-reliability.md).

If the app helps you, consider [supporting development](https://ko-fi.com/arunyagoojar). When reporting a problem, include macOS/app version, Mac architecture, controller/connection type, cloud versus Remote Play, and the relevant settings. Do not include account tokens.

Xbox and game artwork belong to their respective owners. Mac Xcloud is not affiliated with or endorsed by Microsoft, Sony or the game publishers.
