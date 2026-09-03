# Mac XCloud

A native macOS app for Xbox Cloud Gaming. Mac Xcloud wraps xbox.com/play in a
chrome-less native window and layers on native macOS features:

- Persistent Microsoft/Xbox sign-in (WKWebsiteDataStore)
- Native Settings window (stream quality, stats overlay, region picker, MKB)
- DualSense support: adaptive triggers (21 modes), haptics, LED, touchpad,
  calibration, shortcuts, and macros
- Custom full input presets with a protected Default preset, stored locally in
  `~/Library/Application Support/Xbox Cloud data/`
- Menu-bar status (ping, FPS, bitrate, packet loss) with quick actions and
  direct Left/Right adaptive-trigger mode switching
- Xbox boot animation splash and clarity pipeline (FSR/CAS/USM)

## Building

Requires Xcode with the macOS 15.7 SDK or newer:

```bash
xcodebuild -project "Mac XCloud.xcodeproj" -scheme "Mac XCloud" \
  -configuration Release -destination "platform=macOS" build
```

The app is sandboxed and needs no special account to build or run. Sign in with
your Microsoft account inside the app on first launch.

## Controller notes

- Adaptive-trigger effects are approximations using Apple's GameController
  APIs; xCloud does not transmit the original DualSense effect data.
- Momentary controller dropouts, if any, are related to macOS
  GameController/WebKit gamepad handling, not the network stream. Prefer a
  wired connection if your Bluetooth link is unstable.

## Credits

- [Better xCloud](https://github.com/redphx/better-xcloud) by redphx — bundled
  engine (v6.7.12), MIT License. © redphx and Better xCloud contributors.
- Xbox Cloud Gaming is a service of Microsoft. This project is an independent
  native wrapper and is not affiliated with or endorsed by Microsoft.
