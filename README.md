<div align="center">
  <img src="docs/images/mac-xcloud-logo.png" width="160" alt="Mac Xcloud logo">
  <h1>Mac Xcloud</h1>
  <p><strong>Xbox Cloud Gaming and Xbox Remote Play in a dedicated native Mac app.</strong></p>
  <p>
    <a href="https://github.com/arunyagoojar/Mac-XCloud/releases/latest"><img src="https://img.shields.io/github/v/release/arunyagoojar/Mac-XCloud?label=Latest%20Release&color=107C10" alt="Latest Release"></a>
    <img src="https://img.shields.io/badge/Platform-macOS%2012%2B-000000?logo=apple" alt="macOS 12+">
    <img src="https://img.shields.io/badge/Architecture-Universal%20(Apple%20Silicon%20%26%20Intel)-informational" alt="Universal Binary">
    <a href="https://ko-fi.com/arunyagoojar"><img src="https://img.shields.io/badge/Support-Ko--fi-ff5e5b?logo=kofi" alt="Support on Ko-fi"></a>
  </p>
  <p>
    <a href="#key-features">Key Features</a> · 
    <a href="#screenshots">Screenshots</a> · 
    <a href="#dualsense-adaptive-trigger-modes">Adaptive Triggers</a> · 
    <a href="#motion-steering-gyro-aiming--flick-shifting">Motion & Steering</a> · 
    <a href="#deep-links">Deep Links</a> · 
    <a href="#app-shortcuts">Shortcuts</a> · 
    <a href="#installation--requirements">Download</a> · 
    <a href="#building-from-source">Build from Source</a>
  </p>
</div>

---

**Mac Xcloud** combines the Xbox web ecosystem and [Better xCloud](https://github.com/redphx/better-xcloud) with native macOS APIs, delivering an edge-to-edge desktop experience for **Xbox Cloud Gaming** and **Xbox Remote Play**.

Running in Apple's native `WKWebView`, stream video benefits from custom WebKit compatibility shims and optional WebGL/WebGPU clarity pipelines, while controller input, DualSense adaptive triggers, motion steering, and live diagnostics are handled directly by native macOS frameworks (`GameController`, `CoreHaptics`).

> [!NOTE]
> You need an active Xbox Game Pass Ultimate subscription, account, and region access required by Xbox to stream cloud titles. Remote Play connects directly to your own configured Xbox console. This open-source project is independent of and not endorsed by Microsoft or Sony.

---

## Screenshots

<div align="center">
  <img src="docs/images/xcloud-home.png" width="850" alt="Mac Xcloud Main Interface">
  <p><em>Edge-to-edge cloud gaming interface with custom window drag controls and native HUD.</em></p>
</div>

<br>

| Stream & Video Settings | Controller Calibration & Visualizer |
| :---: | :---: |
| <img src="docs/images/settings-stream.png" width="420" alt="Stream Settings"> | <img src="docs/images/controller-tools.png" width="420" alt="Controller Calibration"> |

| DualSense Adaptive Triggers & Haptics | Per-Game Profile Auto-Switching |
| :---: | :---: |
| <img src="docs/images/triggers-haptics.png" width="420" alt="DualSense Trigger Settings"> | <img src="docs/images/input-presets.png" width="420" alt="Input Presets and Game Profiles"> |

---

## Key Features

### 🖥️ Native macOS Experience
- **Edge-to-Edge Chromeless Window**: Custom drag strip under floating macOS traffic lights with zoom/fullscreen support. The main window remembers its size and position on each display.
- **Boot Animation**: The Mac Xcloud launch animation plays over the loading page while WebKit prepares the stream; the page loads in the background the whole time.
- **Keep-Awake While Running**: The Mac's display and system sleep are suppressed while the app is open, so long sessions aren't interrupted.
- **Quit Confirmation**: Quitting during an active stream asks for confirmation first.
- **Persistent Microsoft Authentication**: Dedicated cookie and local storage isolation keeps you signed in between launches.
- **Settings Search**: Filter every cloud, video, overlay, and appearance setting from the settings header.
- **Background Menu Bar Companion**: Quick menu bar status item with instant access to settings, trigger presets, and stream actions.
- **Automatic Updates**: Built-in [Sparkle](https://sparkle-project.org/) framework delivers seamless background checks with detailed, versioned release notes.
- **Deep Links**: `macxcloud://play/<game-id>` launches a game directly, `macxcloud://resume` reopens your last game, and `macxcloud://home` returns to the start page. Works from the Terminal (`open "macxcloud://…"`), Raycast, Alfred, Shortcuts, or browser links. The current game's ID is shown in the Diagnostics panel with a copy button.

### 🎮 Controller Suite & DualSense Support
- **Hardware Calibration**: Live stick center, range calibration, customizable dead zones, and response curves (Linear, Precise Center, Quick Response, S-Curve).
- **DualSense Adaptive Triggers**: Full implementation using macOS 10-zone resistance arrays with presets matching the popular DualSenseX catalog (GameCube digital click, bow draw, machine gun recoil, staged resistance).
- **CoreHaptics & Rumble Routing**: Real-time translation of stream rumble telemetry to native body and trigger haptics with customizable rumble exponent and gain curves.
- **Trigger Lock & Stop Emulation**: Software-defined trigger stops with resistance thresholds.
- **Lightbar & Battery**: Controller battery levels mirrored into the stream status bar and the menu bar. Customizable lightbar colors, with a battery policy that dims, reddens, or switches off the light when the controller is low.
- **Low Battery Alert**: A macOS notification fires once per discharge cycle when the controller drops to about 20%.
- **"Game Ready" Alert**: When a queued game finally connects, you get a macOS notification plus three light-green lightbar pulses with a controller rumble each — so you can browse elsewhere and still know when to hop back in.

### 🏎️ Motion Steering, Gyro Aiming & Flick Shifting
- **Virtual Steering Wheel (left stick)**: You hold the controller facing you and rotate it left and right like a wheel. The app reads the controller's motion sensors to track its rotation angle and writes that angle to the **left analog stick**, so the game sees normal stick steering — no wheel driver or in-game wheel support needed. The full-turn angle, response curve, and smoothing are adjustable. While game rumble or adaptive-trigger vibration is active, steering rides on gyroscope motion instead of reading the shaking sensors, so holding the throttle doesn't pull your line.
- **Flick Shifting (right stick)**: A quick upward or downward flick of the controller sends a right-stick up/down pulse for gear changes; the return movement is ignored so one flick is one shift. **This requires mapping upshift to Right Stick Up and downshift to Right Stick Down in the game's control settings** (most racing games support this, e.g. Forza Horizon 5).
- **Touchpad Aiming (DualSense)**: The touchpad can act as a right-stick aim input. It works, but it is the least polished of the motion features — give it a try if it suits you.
- **Touchpad Gestures**: Configurable swipe and tap gestures on the DualSense touchpad mapped to app actions (toggle stats, fullscreen, screenshot, and more).
- **Gyro Aiming (right stick)**: Tilting the controller maps angular motion to the right stick for fine aiming. It is usable today, though there are known issues that will be worked on over time.
- **Gyro-Assisted Tracking**: Reduces accelerometer jolts while preserving fine corrections and held turns.

### 📊 Native Performance HUD & Diagnostics
- **Pill HUD Overlay**: Lightweight macOS material overlay rendering FPS, network ping, bitrate (Mbps), decode time, packet loss, and dropped frames.
- **Customizable Appearance**: Selectable screen positions, font sizes, opacity, background blur, and conditional green/yellow/red latency coloring.
- **Quick Glance**: Momentarily summon stream metrics via controller shortcut without keeping the HUD permanently on screen.
- **Diagnostics Panel (`⇧⌘D`)**: Live inspection of WebRTC connections, Gamepad API status, bridge message latency, and hardware detection, plus the current game's ID with a copy button for deep links.

### ⚡ Stream Optimization & Video Clarity
- **1080p HQ Unlocked**: WebKit SDP shims negotiate H.264 High Profile (`profile-level-id=64001f`), preventing automatic resolution drops.
- **Clarity Pipelines**: Choose between WebGPU or WebGL2 AMD CAS and Unsharp Mask passes, applied live, with customizable sharpness and contrast.
- **Renderer Selection**: Choose between WebGL2 and WebGPU processing backends.
- **Audio & Video Customization**: Aspect ratio adjustment, video position, brightness, contrast, saturation, and volume boosting.

### 📂 Per-Game Profiles & Macros
- **Automatic Game Switching**: Automatically switches profiles based on active Xbox game IDs (with title fallback), restoring settings when leaving a stream.
- **Multi-Step Macro Engine**: Create up to 16-step timed macros with button presses, delays, native actions, and haptic pulses.
- **Hold-to-Fire (Rapid Fire)**: Repeatable trigger firing with configurable rate (2–15 pulses/sec).
- **Profile Export/Import**: Export profiles as portable JSON files to share between Macs.
- **Full Settings Backup**: Export or import all app settings and every profile as a single JSON file (Settings ▸ Backup & Restore).

### 🛡️ Connection Handling
- **Offline Detection**: If the internet drops, the app says so and reloads the page automatically once the connection returns.
- **Recovery Screens**: Load failures and stuck pages surface a Retry screen instead of hanging.

### 🏠 Xbox Remote Play
- **Direct Console Streaming**: Stream directly from your home Xbox Series X/S or Xbox One console.
- **Console List Refresh**: Automatically updates console power and connection state on open.

---

## DualSense Adaptive Trigger Modes

Mac Xcloud features a DualSenseX-inspired trigger preset catalog. Each mode maps to the physical DualSense hardware effect primitives (10 positional zones, 8 strength steps, frequency modulations):

| Mode | Behavior & Simulated Sensation |
| :--- | :--- |
| **Normal Trigger** | Standard controller resistance; keeps physical spring action. |
| **Custom Trigger Value** | User-defined parameters (mode, position, strengths, amplitude, frequency). |
| **GameCube Trigger** | Smooth initial pull followed by a hard digital wall near 78% travel with a release click. |
| **Resistance Trigger** | Continuous uniform 50% resistance from start of pull. |
| **Bow Trigger** | Progressive string drawing tension that suddenly snaps release at 78% travel. |
| **Galloping Trigger** | Alternating rhythmic pulses approximating galloping hooves. |
| **Semi Automatic Gun** | Realistic trigger wall that breaks once per pull at 44% travel with release reset. |
| **Automatic Gun** | Sustained high-frequency vibration simulating automatic rifle recoil. |
| **Machine Trigger** | Heavy, mechanical, slower-cycling vibration combined with handle haptics. |
| **Choppy Trigger** | Stepped resistance alternating across the ten hardware feedback zones. |
| **Very Soft → Hardest** | Continuous resistance ramp selectable across a 25% to 88% range. |
| **Rigid Trigger** | Maximum resistance from rest; travel is fully blocked. |
| **Calibrate Trigger** | Continuous linear ramp sweeping from zero to full force across the entire stroke. |
| **Vibrate Trigger Pulse** | Deep, rhythmic vibration pulses. |
| **Vibrate 10 Intensity** | Subtle, gentle vibration feedback. |

> [!TIP]
> Adaptive resistance requires a Sony PlayStation DualSense or DualSense Edge controller. 10-zone positional resistance is supported on macOS 12.3+ (with continuous feedback fallback on 12.0–12.2). Trigger effects are local physical simulations, not direct in-game weapon telemetry from Xbox servers.

---

## Input Focus & Keyboard/Mouse Support

Mac Xcloud is purpose-built for **gamepad play, motion steering, and haptics**. 

* **Game Controllers**: Full support for PlayStation DualSense / DualSense Edge, Xbox Wireless Controllers, Nintendo Switch Pro Controllers, and MFi gamepads via Apple's `GameController` framework.
* **Mouse & Keyboard**: For app controls, window management, web navigation, and Microsoft account sign-in. Virtual mouse-to-stick emulation was deliberately removed to avoid pointer-lock conflicts in Apple's `WKWebView`; game input is gamepad-focused.

---

## Forza Horizon 5: Suggested Steering Setup

When using **Motion Steering**, the app translates controller rotation into a native left-stick axis. Configure the game's gamepad settings (not steering wheel force-feedback menus):

| Mac Xcloud Steering Setting | Recommended Baseline |
| :--- | :--- |
| **Full Turn Angle** | 45° per side (adjust to 50–55° if overly sensitive) |
| **Response Exponent** | 1.0 (Linear) |
| **Smoothing** | 0.35 (~70 ms filter window) |
| **Center Dead Zone** | 0° |
| **Game Dead-Zone Compensation** | 0 |
| **Maximum Output** | 100% |
| **Invert Direction** | Off |

*Inside Forza Horizon 5*:
- Steering: **Normal** (adds standard gamepad assistance; switch to Simulation once accustomed).
- Steering Linearity: Neutral **50** (or `0.5`).
- Inside / Outside Steering Deadzones: **0 / 100**.
- Shifting: Enable manual gears and use **Flick Shifting** (map Right Stick Up to Upshift and Right Stick Down to Downshift).

---

## App Shortcuts

| Action | Shortcut |
| :--- | :--- |
| **Back in website history** | `⌘[` or `Backspace` |
| **Forward in website history** | `⌘]` |
| **Xbox Home (`xbox.com/play`)** | `⇧⌘L` |
| **Open Settings** | `⌘,` |
| **Reload Page** | `⌘R` |
| **Toggle Fullscreen** | `⌃⌘F` |
| **Toggle Diagnostics Overlay** | `⇧⌘D` |
| **Settings Home** | `⇧⌘H` *(inside Settings)* |

---

## Deep Links

Mac Xcloud registers the `macxcloud://` URL scheme, so external tools can open the app at a specific spot:

| Link | Action |
| :--- | :--- |
| `macxcloud://play/<game-id>` | Starts streaming the game with that Xbox product ID (e.g. `9NPDN9R45JX4`) |
| `macxcloud://resume` | Reopens the game you played last |
| `macxcloud://home` | Opens the Xbox home page |

From the Terminal:

```bash
open "macxcloud://resume"
```

The same links work in Raycast, Alfred, Shortcuts, or any web page. To find a game's ID, start the game once and open the Diagnostics panel (`⇧⌘D`) — the current game's ID is listed there with a copy button.

---

## Installation & Requirements

### Requirements
* **macOS 12.0 (Monterey) or newer**
* Compatible with both **Apple Silicon** (M1/M2/M3/M4) and **Intel** Macs.
* A supported gamepad (DualSense recommended for adaptive triggers and gyro features).
* Xbox Game Pass Ultimate subscription (for cloud gaming) or an Xbox console (for Remote Play).

### Quick Install
1. Download **`MacXcloud.zip`** from the [Latest Release](https://github.com/arunyagoojar/Mac-XCloud/releases/latest).
2. Unzip and drag **`Mac Xcloud.app`** into your **Applications** folder.
3. Open the app and sign in with your Microsoft account.

> [!NOTE]
> Releases are ad-hoc signed. If macOS Gatekeeper displays an unidentified developer prompt, go to **System Settings → Privacy & Security** and click **Open Anyway**.

---

## Building from Source

### Prerequisites
* Mac running macOS 14+ or newer.
* **Xcode 16+** (with macOS SDK).

### Build Instructions

```bash
# Clone the repository
git clone https://github.com/arunyagoojar/Mac-XCloud.git
cd Mac-XCloud

# Build the universal release application
xcodebuild -project "Mac XCloud.xcodeproj" \
  -scheme "Mac XCloud" \
  -configuration Release \
  -destination "platform=macOS" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES \
  build
```

The compiled application bundle will be located in `build/Build/Products/Release/Mac Xcloud.app`.

### Running Contract Tests

Automated regression and validation suites verify trigger math, profile encoding, and bridge compatibility:

```bash
# Run controller mathematical contract suite
./Tests/run-controller-contracts.sh

# Run preset store encoding contracts
./Tests/run-preset-store-contracts.sh
```

---

## Credits & Acknowledgements

* Built upon the open-source userscript [Better xCloud](https://github.com/redphx/better-xcloud) created by [redphx](https://github.com/redphx).
* Automatic updates powered by the [Sparkle Project](https://sparkle-project.org/).
* AMD FidelityFX CAS (Contrast-Adaptive Sharpening) licensed under MIT by Advanced Micro Devices, Inc.

### Support Development
If you enjoy using Mac Xcloud, consider [supporting ongoing development on Ko-fi](https://ko-fi.com/arunyagoojar).

---

## License & Legal Disclaimer

This project is licensed under the open-source MIT License.

*Xbox, Xbox Cloud Gaming, Xbox Remote Play, and related logos and trademarks belong to Microsoft Corporation.*  
*PlayStation, DualSense, and DualSense Edge are registered trademarks of Sony Interactive Entertainment Inc.*  
*Mac Xcloud is an independent third-party open-source project and is not affiliated with, endorsed by, or sponsored by Microsoft, Sony, or any game publisher.*
