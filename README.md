<div align="center">
  <img src="docs/images/mac-xcloud-logo.png" width="180" alt="Mac Xcloud logo">

  <h1>Mac Xcloud</h1>

  <p><strong>A native-feeling Xbox Cloud Gaming experience for macOS.</strong></p>

  <p>
    <a href="https://github.com/arunyagoojar/Mac-XCloud/releases/latest"><strong>Download</strong></a>
    ·
    <a href="https://github.com/arunyagoojar/Mac-XCloud/releases"><strong>Releases</strong></a>
  </p>

  <p><em>Free and open source · macOS 12+ · Not affiliated with Microsoft</em></p>
</div>

<br>

<div align="center">
  <img src="docs/images/xcloud-home.png" alt="Mac Xcloud showing Xbox Cloud Gaming" width="960">
</div>

## About

Mac Xcloud is a lightweight macOS app for Xbox Cloud Gaming.

It wraps the existing Xbox Cloud Gaming web experience in a dedicated Mac application, while adding native macOS controls, controller tools, input presets, and stream settings.

You still need the Xbox/Game Pass access required to use Xbox Cloud Gaming.

## Features

### Native macOS experience

* Dedicated macOS application
* Native window and fullscreen support
* macOS menu bar controls
* Persistent Microsoft sign-in
* Automatic cursor hiding while using a controller
* Unified native Settings window
* Xbox-style startup animation
* Persistent connection and loading states

### Stream & picture settings

* 720p and 1080p resolution options
* Bitrate controls
* Default, Low, Normal, and High quality presets
* Sharpness and image-processing options
* FSR, WebGL, and WebGPU processing options
* Frame-rate and renderer controls
* H.264 codec support
* Live stream information
* Region latency testing

### Controller tools

* DualSense adaptive triggers
* 21 built-in adaptive-trigger modes
* Custom trigger presets
* Haptic feedback controls
* Controller LED controls
* Touchpad gestures and mappings
* Controller testing
* Stick and trigger calibration
* Controller shortcuts
* Finite macros
* Controller reconnect recovery
* Native/browser controller mismatch diagnostics

<div align="center">
  <img src="docs/images/settings-controller.png" alt="Controller settings" width="48%">
  <img src="docs/images/controller-tools.png" alt="Controller Tools" width="48%">
</div>

### Input presets

Save and switch between different controller and input configurations.

* Custom input presets
* Adaptive-trigger presets
* Controller, keyboard, and mouse settings
* Shortcut and macro configurations
* Create, edit, duplicate, rename, and delete presets
* Protected Default preset
* Local JSON-based storage

<div align="center">
  <img src="docs/images/input-presets.png" alt="Input presets" width="820">
</div>

### Mouse & keyboard

* Mouse and keyboard support through Better xCloud
* Virtual controller profiles
* Keyboard shortcut profiles
* Controller customization profiles
* Portable input preset capture

### Remote Play

* Remote Play resolution controls
* IPv6 preference
* Remote server and console status diagnostics
* Native-controller versus browser-Gamepad status
* Safe controller rescan and focus recovery
* Better xCloud's Remote Play input restrictions remain unchanged

A Mac controller must be exposed by WebKit as a browser Gamepad for Xbox to receive its input. The app never fabricates or replaces browser Gamepad objects.

### Diagnostics

Built-in live diagnostics for:

* Resolution
* FPS
* Bitrate
* Ping
* Packet loss
* Dropped frames
* Decode time
* Jitter
* Region
* Remote Play status
* Native controller status
* Browser Gamepad status

<div align="center">
  <img src="docs/images/settings-stream.png" alt="Stream settings" width="48%">
  <img src="docs/images/triggers-haptics.png" alt="Adaptive triggers and haptics" width="48%">
</div>

## Support the project

If Mac Xcloud is useful to you, you can support development through
[Ko-fi](https://ko-fi.com/arunyagoojar).

## Download

1. Go to the [latest release](https://github.com/arunyagoojar/Mac-XCloud/releases/latest).
2. Download `MacXcloud.zip`.
3. Unzip it and move **Mac Xcloud.app** to `/Applications`.
4. On first launch, right-click the app → **Open** → confirm the macOS warning.

Mac Xcloud is not notarized, so macOS may show a Gatekeeper warning on first launch.

## Build from source

Requires **macOS 12+** and Xcode.

```bash
git clone https://github.com/arunyagoojar/Mac-XCloud.git
cd Mac-XCloud
open "Mac XCloud.xcodeproj"
```

In Xcode:

1. Select the **Mac XCloud** scheme.
2. Select **My Mac** as the destination.
3. Build with `⌘B`.

Or build from Terminal:

```bash
xcodebuild -project "Mac XCloud.xcodeproj" \
  -scheme "Mac XCloud" \
  -configuration Release \
  -destination "platform=macOS" \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=NO \
  build
```

## Automatic updates

Every push to `main` builds and publishes a signed GitHub Release through GitHub Actions. Installed copies check for updates through Sparkle automatically.

## Credits

Mac Xcloud uses [Better xCloud](https://github.com/redphx/better-xcloud) by redphx under the MIT License.

Xbox Cloud Gaming is a Microsoft service. Mac Xcloud is an independent project and is not affiliated with or endorsed by Microsoft.

Game artwork shown in screenshots belongs to its respective publishers.
